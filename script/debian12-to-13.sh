#!/usr/bin/env bash
# Guided Debian 12 (bookworm) -> Debian 13 (trixie) upgrade.
# Default mode is a read-only preflight; use --prepare or --upgrade explicitly.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BACKUP_ROOT='/var/backups/debian12-to-13'
MODE='check'
YES=0
DRY_RUN=0
REBOOT=0
SKIP_CHECK=0
BACKUP_DIR=''

usage() {
  cat <<'EOF'
用法：
  sudo ./debian12-to-13.sh                 # 只做升级前检查
  sudo ./debian12-to-13.sh --prepare       # 备份并把 Debian 官方源切到 trixie
  sudo ./debian12-to-13.sh --upgrade       # 执行完整升级（会询问确认）

选项：
  --prepare              只准备源，不执行 full-upgrade
  --upgrade              执行更新、切源、minimal upgrade 和 full-upgrade
  --yes                  跳过升级确认
  --reboot               升级完成后重启
  --dry-run              预览 --prepare 的修改
  --skip-check           跳过 dpkg/源检查（不建议）
  -h, --help             显示帮助

说明：
  升级前请阅读 Debian 13 Release Notes，准备控制台和完整备份。
  脚本只自动转换 Debian 官方源；第三方源会保留并提示人工检查。
EOF
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "错误：$*"; exit 1; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die '请使用 root 运行。'; }

parse_args() {
  while (($#)); do
    case "$1" in
      --prepare) MODE='prepare'; shift ;;
      --upgrade) MODE='upgrade'; shift ;;
      --yes) YES=1; shift ;;
      --reboot) REBOOT=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --skip-check) SKIP_CHECK=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ "$MODE" == upgrade ]] || { (( REBOOT == 0 )) || die '--reboot 只能与 --upgrade 一起使用。'; }
  [[ "$MODE" != upgrade || "$DRY_RUN" -eq 0 ]] || die '--dry-run 只能与默认检查或 --prepare 一起使用。'
}

os_suite() {
  [[ -r /etc/os-release ]] || die '找不到 /etc/os-release。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian ]] || die "此脚本只接受纯 Debian，当前 ID=${ID:-unknown}。"
  printf '%s\n' "${VERSION_CODENAME:-}"
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

check_system() {
  local suite audit held free_kb
  suite="$(os_suite)"
  [[ "$suite" == bookworm ]] || die "当前 Debian suite 是 $suite；此脚本只接受 bookworm。"
  command -v apt-get >/dev/null 2>&1 || die '找不到 apt-get。'
  command -v dpkg >/dev/null 2>&1 || die '找不到 dpkg。'
  audit="$(dpkg --audit 2>&1 || true)"
  [[ -z "$audit" ]] || die "dpkg 状态不完整，请先修复：$audit"
  held="$(apt-mark showhold 2>/dev/null || true)"
  [[ -z "$held" ]] || log "警告：存在 hold 软件包：$(tr '\n' ' ' <<<"$held")"
  free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 5242880 )); then
    log '警告：根分区可用空间少于 5 GiB。'
  fi
  if grep -RIlE '^[[:space:]]*[^#].*bookworm' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
      | grep -vE 'debian|security' >/dev/null; then
    log '警告：检测到第三方源仍使用 bookworm，升级前请确认是否有 trixie 版本。'
  fi
}

run_repair() {
  local repair="$SCRIPT_DIR/debian-subscription-fix.sh"
  [[ -f "$repair" ]] || die "找不到同目录脚本：$repair"
  if (( DRY_RUN )); then
    "$repair" --dry-run --suite bookworm
  else
    "$repair" --no-update --suite bookworm
  fi
}

rewrite_file() {
  local file="$1" tmp
  grep -Eiq 'debian\.org/debian|security\.debian\.org/debian-security' "$file" || return 0
  grep -Eiq 'bookworm' "$file" || return 0
  log "切换 Debian 源 suite：$file"
  (( DRY_RUN )) && return 0
  backup_file "$file"
  tmp="$(mktemp)"
  sed 's/bookworm/trixie/g' "$file" >"$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f -- "$tmp"
}

prepare_sources() {
  local file
  if (( ! DRY_RUN )); then
    BACKUP_DIR="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$BACKUP_DIR"
    log "源文件备份目录：$BACKUP_DIR"
  fi
  run_repair
  while IFS= read -r file; do rewrite_file "$file"; done < <(source_files)
  log '请在执行升级前检查 /etc/apt/sources.list* 中的第三方源。'
}

save_upgrade_backup() {
  (( DRY_RUN )) && { log '[dry-run] 保存 /etc、dpkg 和 APT 状态备份'; return 0; }
  local stamp="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$stamp"
  tar --xattrs --acls -czf "$stamp/etc.tar.gz" /etc 2>/dev/null || log '警告：/etc 归档未完整完成，请使用现有备份恢复。'
  cp -a /var/lib/dpkg/status "$stamp/dpkg-status"
  cp -a /var/lib/apt/extended_states "$stamp/apt-extended_states" 2>/dev/null || true
  dpkg --get-selections '*' >"$stamp/dpkg-selections"
  log "升级备份：$stamp"
}

apt_update() {
  (( DRY_RUN )) && { log '[dry-run] apt-get update'; return 0; }
  apt-get update
}

minimal_upgrade() {
  (( DRY_RUN )) && { log '[dry-run] apt-get -y upgrade --without-new-pkgs'; return 0; }
  apt-get -y upgrade --without-new-pkgs
}

full_upgrade() {
  (( DRY_RUN )) && { log '[dry-run] apt-get -y full-upgrade'; return 0; }
  apt-get -y full-upgrade
}

confirm_upgrade() {
  (( YES )) && return 0
  printf '即将执行 Debian 12 -> 13 升级，确认请输入 UPGRADE：' >&2
  local answer
  read -r answer
  [[ "$answer" == UPGRADE ]] || die '已取消。'
}

main() {
  parse_args "$@"
  require_root
  check_system

  if [[ "$MODE" == check ]]; then
    log '预检查完成；未修改系统。'
    exit 0
  fi
  if [[ "$MODE" == prepare ]]; then
    prepare_sources
    log '源文件已准备为 trixie；请人工确认后执行 apt-get update && apt-get -y full-upgrade。'
    exit 0
  fi

  confirm_upgrade
  (( SKIP_CHECK )) || log '已完成 dpkg 和 APT 源检查。'
  save_upgrade_backup
  apt_update
  minimal_upgrade
  prepare_sources
  apt_update
  full_upgrade

  local suite
  suite="$(os_suite 2>/dev/null || true)"
  if [[ "$suite" == trixie ]]; then
    log 'Debian 13 升级完成。建议执行 apt autoremove 并检查服务状态。'
    if (( REBOOT )); then
      (( DRY_RUN )) && log '[dry-run] systemctl reboot' || systemctl reboot
    else
      log '未自动重启；Debian 13 升级通常需要重启以使用新内核。'
    fi
  else
    log "升级命令结束，但当前 suite 仍是 ${suite:-未知}。请检查 apt 输出并从控制台恢复。"
    exit 2
  fi
}

main "$@"
