#!/usr/bin/env bash
# Switch Proxmox VE 8/9 from the enterprise repository to pve-no-subscription.
#
# The script only changes APT source files.  It does not patch the Proxmox web
# interface and it never installs an untrusted key.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly BACKUP_ROOT="/var/backups/pve-subscription-fix"

DRY_RUN=0
CHECK_ONLY=0
RUN_UPDATE=1
FORCED_MAJOR=""
BACKUP_DIR=""

usage() {
  cat <<'EOF'
用法：
  sudo ./pve-subscription-fix.sh [选项]

作用：
  检测 PVE 8/9，禁用 pve-enterprise，启用对应的 pve-no-subscription。
  修改前会把原始源文件备份到 /var/backups/pve-subscription-fix/。

选项：
  --check             只检查，不修改文件
  --dry-run           预览修改，不写文件、不执行 apt update
  --no-update         修改源后不执行 apt-get update
  --force-version N   在测试或特殊环境中指定 PVE 主版本（8 或 9）
  -h, --help          显示帮助
EOF
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "错误：$*"; exit 1; }
run() {
  if (( DRY_RUN )); then
    printf '+ %q' "$1" >&2
    shift || true
    printf ' %q' "$@" >&2
    printf '\n' >&2
  else
    "$@"
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die '请使用 root 运行。'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --check) CHECK_ONLY=1; RUN_UPDATE=0; shift ;;
      --dry-run) DRY_RUN=1; RUN_UPDATE=0; shift ;;
      --no-update) RUN_UPDATE=0; shift ;;
      --force-version)
        (($# >= 2)) || die '--force-version 需要参数。'
        FORCED_MAJOR="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -z "$FORCED_MAJOR" || "$FORCED_MAJOR" =~ ^[89]$ ]] || die 'PVE 主版本只能是 8 或 9。'
}

pve_major() {
  if [[ -n "$FORCED_MAJOR" ]]; then
    printf '%s\n' "$FORCED_MAJOR"
    return
  fi

  local version=""
  if command -v pveversion >/dev/null 2>&1; then
    version="$(pveversion 2>/dev/null | sed -nE 's#.*pve-manager/([0-9]+).*#\1#p' | head -n1)"
  fi
  if [[ -z "$version" ]] && command -v dpkg-query >/dev/null 2>&1; then
    version="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null | sed -nE 's#^([0-9]+).*#\1#p')"
  fi
  [[ "$version" =~ ^[89]$ ]] || die '未检测到 PVE 8 或 PVE 9（需要在 Proxmox VE 主机上运行）。'
  printf '%s\n' "$version"
}

suite_for_major() {
  case "$1" in
    8) printf 'bookworm\n' ;;
    9) printf 'trixie\n' ;;
    *) die "不支持的 PVE 主版本：$1" ;;
  esac
}

source_files() {
  local file
  shopt -s nullglob
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
  shopt -u nullglob
}

has_enterprise_uri() {
  grep -Eiq 'enterprise\.proxmox\.com[/:]debian/pve' "$1"
}

has_no_subscription_uri() {
  grep -Eiq '(download\.proxmox\.com|enterprise\.proxmox\.com)[/:]debian/pve|pve-no-subscription' "$1"
}

active_source_matches() {
  local pattern="$1" file
  while IFS= read -r file; do
    if grep -Eiq "^[[:space:]]*[^#].*${pattern}" "$file"; then
      return 0
    fi
  done < <(source_files)
  return 1
}

backup_file() {
  local file="$1" target
  (( DRY_RUN )) && return 0
  [[ -n "$BACKUP_DIR" ]] || return 0
  target="$BACKUP_DIR${file}"
  mkdir -p "$(dirname "$target")"
  cp -a -- "$file" "$target"
}

disable_list_file() {
  local file="$1" tmp
  has_enterprise_uri "$file" || return 0
  log "禁用企业源：$file"
  if (( DRY_RUN )); then return 0; fi
  backup_file "$file"
  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    /enterprise\.proxmox\.com[\/:]debian\/pve/ { print "# disabled by pve-subscription-fix.sh: " $0; next }
    { print }
  ' "$file" >"$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f -- "$tmp"
}

disable_sources_stanza() {
  local file="$1" tmp
  has_enterprise_uri "$file" || return 0
  log "禁用企业源 stanza：$file"
  if (( DRY_RUN )); then return 0; fi
  backup_file "$file"
  tmp="$(mktemp)"
  awk '
    function flush(    i,n,line) {
      if (buf == "") return
      if (hit) {
        n = split(buf, lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] != "") print "# disabled by pve-subscription-fix.sh: " lines[i]
      } else printf "%s", buf
      buf = ""; hit = 0
    }
    {
      buf = buf $0 "\n"
      if ($0 ~ /enterprise\.proxmox\.com[\/:]debian\/pve/) hit = 1
      if ($0 ~ /^[[:space:]]*$/) flush()
    }
    END { flush() }
  ' "$file" >"$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f -- "$tmp"
}

disable_enterprise_sources() {
  local file base
  while IFS= read -r file; do
    [[ -e "$file" ]] || continue
    base="$(basename "$file")"
    case "$base" in
      pve-enterprise.list|pve-enterprise.sources)
        log "禁用企业源文件：$file"
        if (( ! DRY_RUN )); then
          backup_file "$file"
          if [[ -e "$file.disabled" ]]; then
            rm -f -- "$file.disabled"
          fi
          mv -- "$file" "$file.disabled"
        fi
        ;;
      *.sources) disable_sources_stanza "$file" ;;
      *) disable_list_file "$file" ;;
    esac
  done < <(source_files)
}

write_no_subscription_source() {
  local suite="$1" file='/etc/apt/sources.list.d/pve-no-subscription.list'
  log "启用 PVE no-subscription 源：$suite"
  if (( DRY_RUN )); then return 0; fi
  if [[ -e "$file" ]]; then backup_file "$file"; fi
  install -d -m 0755 /etc/apt/sources.list.d
  cat >"$file" <<EOF
# Managed by pve-subscription-fix.sh
# Official community repository for Proxmox VE $suite.
deb https://download.proxmox.com/debian/pve $suite pve-no-subscription
EOF
}

report_sources() {
  local file
  log '当前相关源：'
  while IFS= read -r file; do
    if grep -Eiq 'enterprise\.proxmox\.com[/:]debian/pve|download\.proxmox\.com[/:]debian/pve|pve-no-subscription' "$file"; then
      printf '  %s\n' "$file" >&2
      grep -Ein 'enterprise\.proxmox\.com[/:]debian/pve|download\.proxmox\.com[/:]debian/pve|pve-no-subscription' "$file" >&2 || true
    fi
  done < <(source_files)
}

run_update() {
  (( RUN_UPDATE )) || return 0
  (( DRY_RUN )) && return 0
  command -v apt-get >/dev/null 2>&1 || die '找不到 apt-get。'
  log '刷新 APT 索引。'
  apt-get update
}

main() {
  parse_args "$@"
  [[ "$CHECK_ONLY" -eq 1 || "$DRY_RUN" -eq 1 ]] || require_root

  local major suite
  major="$(pve_major)"
  suite="$(suite_for_major "$major")"
  log "检测到 Proxmox VE $major，目标 suite：$suite。"

  if (( CHECK_ONLY )); then
    report_sources
    if active_source_matches 'enterprise\.proxmox\.com[/:]debian/pve'; then
      log '检查结果：仍有启用的企业源。'
      exit 2
    fi
    if ! active_source_matches 'pve-no-subscription|download\.proxmox\.com[/:]debian/pve'; then
      log '检查结果：没有检测到启用的 no-subscription 源。'
      exit 2
    fi
    log '检查完成。'
    exit 0
  fi

  if (( ! DRY_RUN )); then
    BACKUP_DIR="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$BACKUP_DIR"
    log "备份目录：$BACKUP_DIR"
  fi
  disable_enterprise_sources
  write_no_subscription_source "$suite"
  report_sources
  run_update
  log '已切换到 no-subscription 源。此脚本不会修改 Web UI 的订阅提示。'
}

main "$@"
