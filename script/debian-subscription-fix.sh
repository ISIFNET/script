#!/usr/bin/env bash
# Repair common APT source errors on a Debian 12/13 host.
# Debian has no subscription repository.  This script disables only known
# Proxmox enterprise/CD-ROM entries and ensures the official Debian sources
# exist; it does not install keys or remove security updates.

set -Eeuo pipefail
IFS=$'\n\t'

readonly BACKUP_ROOT='/var/backups/debian-subscription-fix'
DRY_RUN=0
CHECK_ONLY=0
RUN_UPDATE=1
FORCED_SUITE=''
BACKUP_DIR=''

usage() {
  cat <<'EOF'
用法：
  sudo ./debian-subscription-fix.sh [选项]

作用：
  修复常见的 Debian APT 源错误：禁用 Proxmox 企业源和失效的 CD-ROM 源，
  确保 Debian 官方仓库（main/contrib/non-free/non-free-firmware）存在。
  Debian 本身没有 Proxmox 式订阅仓库，不会删除 Debian 安全更新源。

选项：
  --check             只检查，不修改
  --dry-run           预览修改，不写文件、不执行 apt update
  --no-update         修改源后不执行 apt-get update
  --suite bookworm|trixie  手动指定 suite
  -h, --help          显示帮助
EOF
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "错误：$*"; exit 1; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die '请使用 root 运行。'; }

parse_args() {
  while (($#)); do
    case "$1" in
      --check) CHECK_ONLY=1; RUN_UPDATE=0; shift ;;
      --dry-run) DRY_RUN=1; RUN_UPDATE=0; shift ;;
      --no-update) RUN_UPDATE=0; shift ;;
      --suite)
        (($# >= 2)) || die '--suite 需要参数。'
        FORCED_SUITE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -z "$FORCED_SUITE" || "$FORCED_SUITE" == bookworm || "$FORCED_SUITE" == trixie ]] || die 'suite 只能是 bookworm 或 trixie。'
}

detect_suite() {
  local id codename
  [[ -r /etc/os-release ]] || die '找不到 /etc/os-release。'
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  codename="${VERSION_CODENAME:-}"
  [[ "$id" == debian || " ${ID_LIKE:-} " == *' debian '* ]] || die "当前系统不是 Debian 系列（ID=$id）。"
  if command -v pveversion >/dev/null 2>&1; then
    die '检测到 pveversion；这是 PVE 主机，请使用 pve-subscription-fix.sh。'
  fi
  [[ -n "$FORCED_SUITE" ]] && { printf '%s\n' "$FORCED_SUITE"; return; }
  [[ "$codename" == bookworm || "$codename" == trixie ]] || die "只支持 Debian 12/13，当前 suite=${codename:-unknown}。"
  printf '%s\n' "$codename"
}

source_files() {
  local file
  shopt -s nullglob
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
  shopt -u nullglob
}

backup_file() {
  local file="$1" target
  (( DRY_RUN )) && return 0
  target="$BACKUP_DIR${file}"
  mkdir -p "$(dirname "$target")"
  cp -a -- "$file" "$target"
}

disable_bad_file() {
  local file="$1" tmp
  grep -Eiq 'enterprise\.proxmox\.com[/:]debian/pve|^[[:space:]]*deb[[:space:]]+cdrom:' "$file" || return 0
  log "禁用失效/企业源：$file"
  (( DRY_RUN )) && return 0
  backup_file "$file"
  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    /enterprise\.proxmox\.com[\/:]debian\/pve/ || /^[[:space:]]*deb[[:space:]]+cdrom:/ {
      print "# disabled by debian-subscription-fix.sh: " $0; next
    }
    { print }
  ' "$file" >"$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f -- "$tmp"
}

disable_bad_sources_stanza() {
  local file="$1" tmp
  grep -Eiq 'enterprise\.proxmox\.com[/:]debian/pve|^[[:space:]]*deb[[:space:]]+cdrom:' "$file" || return 0
  log "禁用失效/企业源 stanza：$file"
  (( DRY_RUN )) && return 0
  backup_file "$file"
  tmp="$(mktemp)"
  awk '
    function flush(    i,n) {
      if (buf == "") return
      if (hit) {
        n = split(buf, lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] != "") print "# disabled by debian-subscription-fix.sh: " lines[i]
      } else printf "%s", buf
      buf = ""; hit = 0
    }
    {
      buf = buf $0 "\n"
      if ($0 ~ /enterprise\.proxmox\.com[\/:]debian\/pve/ || $0 ~ /^[[:space:]]*deb[[:space:]]+cdrom:/) hit = 1
      if ($0 ~ /^[[:space:]]*$/) flush()
    }
    END { flush() }
  ' "$file" >"$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f -- "$tmp"
}

official_source_present() {
  local file
  while IFS= read -r file; do
    if grep -Eiq '^[[:space:]]*(deb[[:space:]]+|URIs:[[:space:]]*)(https?://([^/]+\.)?debian\.org/|https?://deb\.debian\.org/)' "$file"; then
      return 0
    fi
  done < <(source_files)
  return 1
}

write_official_source() {
  local suite="$1" file='/etc/apt/sources.list.d/debian-official.sources'
  official_source_present && { log '已存在 Debian 官方源，不新增重复源。'; return 0; }
  log "写入 Debian 官方源：$suite"
  (( DRY_RUN )) && return 0
  if [[ -e "$file" ]]; then backup_file "$file"; fi
  install -d -m 0755 /etc/apt/sources.list.d
  cat >"$file" <<EOF
# Managed by debian-subscription-fix.sh
Types: deb
URIs: https://deb.debian.org/debian
Suites: $suite $suite-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: $suite-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

report() {
  local file
  while IFS= read -r file; do
    if grep -Eiq 'enterprise\.proxmox\.com[/:]debian/pve|^[[:space:]]*[^#].*deb[[:space:]]+cdrom:' "$file"; then
      printf '  %s\n' "$file" >&2
      grep -Ein 'enterprise\.proxmox\.com[/:]debian/pve|^[[:space:]]*[^#].*deb[[:space:]]+cdrom:' "$file" >&2 || true
    fi
  done < <(source_files)
}

main() {
  parse_args "$@"
  (( CHECK_ONLY || DRY_RUN )) || require_root
  local suite file
  suite="$(detect_suite)"
  log "检测到 Debian suite：$suite。"

  if (( CHECK_ONLY )); then
    report
    official_source_present || { log '检查结果：没有检测到 Debian 官方源。'; exit 2; }
    log '检查完成。'
    exit 0
  fi

  if (( ! DRY_RUN )); then
    BACKUP_DIR="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$BACKUP_DIR"
    log "备份目录：$BACKUP_DIR"
  fi
  while IFS= read -r file; do
    case "$(basename "$file")" in
      *.sources) disable_bad_sources_stanza "$file" ;;
      *) disable_bad_file "$file" ;;
    esac
  done < <(source_files)
  write_official_source "$suite"
  report
  if (( RUN_UPDATE && ! DRY_RUN )); then
    command -v apt-get >/dev/null 2>&1 || die '找不到 apt-get。'
    apt-get update
  fi
  log 'Debian APT 源修复完成。'
}

main "$@"
