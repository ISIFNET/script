#!/usr/bin/env bash
# Guided Proxmox VE 8 -> 9 upgrade.
# Default mode is read-only preflight.  Use --prepare or --upgrade explicitly.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BACKUP_ROOT="/var/backups/pve8-to-pve9"

MODE='check'
YES=0
DRY_RUN=0
REBOOT=0
SKIP_CHECK=0
ALLOW_CLUSTER=0
BACKUP_DIR=''

usage() {
  cat <<'EOF'
用法：
  sudo ./pve8-to-pve9.sh                 # 只做升级前检查
  sudo ./pve8-to-pve9.sh --prepare       # 备份并把 Debian/PVE 源切到 trixie
  sudo ./pve8-to-pve9.sh --upgrade       # 执行完整升级（会询问确认）

选项：
  --prepare              只准备 PVE 9 软件源，不执行 full-upgrade
  --upgrade              执行检查、PVE 8 更新、切源和 PVE 9 full-upgrade
  --yes                  跳过升级确认（仅与 --upgrade 一起使用）
  --reboot               升级完成且检测到 PVE 9 后重启
  --dry-run              预览 --prepare 的文件修改
  --skip-check           不运行 pve8to9 检查（不建议）
  --allow-cluster        允许在集群节点上运行；集群必须按官方顺序逐节点升级
  -h, --help             显示帮助

说明：
  脚本不会自动处理 Ceph 大版本切换或第三方源。pve8to9 检查发现问题时，
  应先修复问题再升级。升级前请确认有可用的节点控制台和备份。
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
      --allow-cluster) ALLOW_CLUSTER=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ "$MODE" == 'upgrade' ]] || { (( REBOOT == 0 )) || die '--reboot 只能与 --upgrade 一起使用。'; }
  [[ "$MODE" != 'upgrade' || "$DRY_RUN" -eq 0 ]] || die '--dry-run 只能与默认检查或 --prepare 一起使用。'
}

pve_major() {
  local version=''
  if command -v pveversion >/dev/null 2>&1; then
    version="$(pveversion 2>/dev/null | sed -nE 's#.*pve-manager/([0-9]+).*#\1#p' | head -n1)"
  fi
  if [[ -z "$version" ]] && command -v dpkg-query >/dev/null 2>&1; then
    version="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null | sed -nE 's#^([0-9]+).*#\1#p')"
  fi
  [[ "$version" =~ ^[0-9]+$ ]] || die '未检测到 pve-manager。请在 PVE 8 主机上运行。'
  printf '%s\n' "$version"
}

os_codename() {
  local value=''
  [[ -r /etc/os-release ]] && value="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
  printf '%s\n' "$value"
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

check_environment() {
  local major codename free_kb held cluster_status
  major="$(pve_major)"
  (( major == 8 )) || die "当前 PVE 主版本是 $major；此脚本只接受 PVE 8。"
  codename="$(os_codename)"
  [[ -z "$codename" || "$codename" == 'bookworm' ]] || die "当前 Debian suite 是 $codename；预期是 bookworm。"
  command -v apt-get >/dev/null 2>&1 || die '找不到 apt-get。'
  command -v dpkg >/dev/null 2>&1 || die '找不到 dpkg。'

  if (( SKIP_CHECK )); then
    log '已请求跳过 pve8to9 检查。'
  elif command -v pve8to9 >/dev/null 2>&1; then
    log '已找到官方 pve8to9 检查器。'
  else
    die '找不到 pve8to9。请先更新 PVE 8 到最新版本，再重试。'
  fi

  free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 5242880 )); then
    log '警告：根分区可用空间少于 5 GiB。'
  fi

  held="$(apt-mark showhold 2>/dev/null || true)"
  [[ -z "$held" ]] || log "警告：存在 hold 软件包：$(tr '\n' ' ' <<<"$held")"

  cluster_status=''
  if command -v pvecm >/dev/null 2>&1; then
    cluster_status="$(pvecm status 2>/dev/null || true)"
  fi
  if grep -qE '(^|[[:space:]])Quorate[[:space:]]*:' <<<"$cluster_status"; then
    log '检测到集群节点。请逐节点升级，并确保集群版本要求满足官方文档。'
    (( ALLOW_CLUSTER )) || die '集群升级需要显式指定 --allow-cluster。'
  fi
}

run_official_check() {
  (( SKIP_CHECK )) && { log '已跳过 pve8to9 检查。'; return 0; }
  log '运行官方升级检查：pve8to9 --full。'
  (( DRY_RUN )) && { log '[dry-run] pve8to9 --full'; return 0; }
  pve8to9 --full
}

subscription_script() {
  local file="$SCRIPT_DIR/pve-subscription-fix.sh"
  [[ -x "$file" ]] || [[ -f "$file" ]] || die "找不到同目录脚本：$file"
  printf '%s\n' "$file"
}

rewrite_source_file() {
  local file="$1" tmp
  grep -Eiq 'debian\.org/debian|security\.debian\.org/debian|download\.proxmox\.com/debian/pve' "$file" || return 0
  grep -Eiq 'bookworm' "$file" || return 0
  log "切换软件源 suite：$file"
  if (( DRY_RUN )); then return 0; fi
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

  # Disable enterprise and create the correct PVE 9 no-subscription source
  # before rewriting Debian/PVE suites.
  if (( DRY_RUN )); then
    "$(subscription_script)" --dry-run
  else
    "$(subscription_script)" --no-update
  fi
  while IFS= read -r file; do
    rewrite_source_file "$file"
  done < <(source_files)

  if grep -RIlE '^[[:space:]]*[^#].*bookworm' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
      | grep -vE 'pve-enterprise|ceph' >/dev/null; then
    log '警告：仍有未转换的 bookworm 源，请人工检查后再执行 apt upgrade。'
  fi
}

apt_update() {
  (( DRY_RUN )) && { log '[dry-run] apt-get update'; return 0; }
  log '刷新 trixie APT 索引。'
  apt-get update
}

full_upgrade() {
  (( DRY_RUN )) && { log '[dry-run] apt-get -y full-upgrade'; return 0; }
  log '执行 apt-get -y full-upgrade。配置文件提示会按系统策略处理。'
  apt-get -y full-upgrade
}

confirm_upgrade() {
  (( YES )) && return 0
  printf '即将执行 PVE 8 -> PVE 9 升级，确认请输入 UPGRADE：' >&2
  local answer
  read -r answer
  [[ "$answer" == 'UPGRADE' ]] || die '已取消。'
}

main() {
  parse_args "$@"
  require_root
  check_environment

  if [[ "$MODE" == 'check' ]]; then
    run_official_check
    log '预检查完成；未修改系统。'
    exit 0
  fi

  if [[ "$MODE" == 'prepare' ]]; then
    prepare_sources
    log '源文件已准备为 PVE 9。下一步请人工确认所有源，再执行 apt-get update && apt-get -y full-upgrade。'
    exit 0
  fi

  confirm_upgrade
  run_official_check
  apt_update
  full_upgrade
  run_official_check
  prepare_sources
  apt_update
  full_upgrade

  local after
  after="$(pve_major 2>/dev/null || true)"
  if [[ "$after" == '9' ]]; then
    log 'PVE 9 升级完成。建议检查 pveversion、节点状态和所有虚拟机。'
    if (( REBOOT )); then
      (( DRY_RUN )) && log '[dry-run] systemctl reboot' || systemctl reboot
    else
      log '未自动重启；请在确认业务状态后手动重启。'
    fi
  else
    log "升级命令结束，但当前 pve-manager 主版本仍是 ${after:-未知}。请查看 apt 输出并从控制台检查。"
    exit 2
  fi
}

main "$@"
