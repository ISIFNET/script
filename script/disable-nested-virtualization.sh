#!/usr/bin/env bash
# Persistently disable KVM nested virtualization on a Proxmox VE host.
# Disable is the default action; --enable is available for an explicit opt-in.

set -Eeuo pipefail
IFS=$'\n\t'

readonly INTEL_CONF='/etc/modprobe.d/kvm-intel.conf'
readonly AMD_CONF='/etc/modprobe.d/kvm-amd.conf'
DRY_RUN=0
ACTION='disable'
STATUS_ONLY=0
BACKUP_DIR=''

usage() {
  cat <<'EOF'
用法：
  sudo ./disable-nested-virtualization.sh                 # 默认关闭
  sudo ./disable-nested-virtualization.sh --status        # 查看配置和当前模块值
  sudo ./disable-nested-virtualization.sh --enable        # 明确开启（需重启或重载模块）

选项：
  --disable             持久关闭嵌套虚拟化（默认）
  --enable              持久开启嵌套虚拟化
  --status              只查看状态，不修改文件
  --dry-run             预览，不写文件
  -h, --help            显示帮助

说明：
  配置对 kvm-intel 和 kvm-amd 都会写入，只有实际加载的 CPU 模块会生效。
  已运行的虚拟机不受脚本强制停止；模块参数通常在主机重启后生效。
EOF
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "错误：$*"; exit 1; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die '请使用 root 运行。'; }

parse_args() {
  while (($#)); do
    case "$1" in
      --disable) ACTION='disable'; shift ;;
      --enable) ACTION='enable'; shift ;;
      --status) STATUS_ONLY=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

backup_if_present() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  (( DRY_RUN )) && return 0
  [[ -n "$BACKUP_DIR" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a -- "$file" "$BACKUP_DIR/$(basename "$file")"
}

write_config() {
  local file="$1" module="$2" value="$3"
  if (( DRY_RUN )); then
    log "[dry-run] 写入 $file：options $module nested=$value"
    return 0
  fi
  backup_if_present "$file"
  install -d -m 0755 /etc/modprobe.d
  cat >"$file" <<EOF
# Managed by disable-nested-virtualization.sh
# Change with: $0 --enable
options $module nested=$value
EOF
  chmod 0644 "$file"
}

active_value() {
  local module="$1" path="/sys/module/$module/parameters/nested"
  if [[ -r "$path" ]]; then
    tr -d '\n' <"$path"
  else
    printf 'not-loaded\n'
  fi
}

show_status() {
  local desired='0'
  [[ "$ACTION" == 'enable' ]] && desired='1'
  printf 'kvm-intel: active=%s, config=%s, desired=%s\n' "$(active_value kvm_intel)" "$INTEL_CONF" "$desired"
  printf 'kvm-amd:   active=%s, config=%s, desired=%s\n' "$(active_value kvm_amd)" "$AMD_CONF" "$desired"
  if [[ -r /proc/cpuinfo ]]; then
    awk -F: '/^vendor_id[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print "cpu-vendor: " $2; exit}' /proc/cpuinfo || true
  fi
}

main() {
  parse_args "$@"
  if (( STATUS_ONLY )); then
    show_status
    exit 0
  fi
  require_root
  if (( ! DRY_RUN )); then
    BACKUP_DIR="/var/backups/disable-nested-virtualization/$(date '+%Y%m%d-%H%M%S')"
  fi
  local value='0'
  [[ "$ACTION" == 'enable' ]] && value='1'
  write_config "$INTEL_CONF" 'kvm-intel' "$value"
  write_config "$AMD_CONF" 'kvm-amd' "$value"
  if [[ "$value" == '0' ]]; then
    log '已将嵌套虚拟化默认设置为关闭。'
  else
    log '已将嵌套虚拟化设置为开启。'
  fi
  (( DRY_RUN )) || log '模块已加载时不会强制卸载；请重启主机后用 --status 验证。'
  (( DRY_RUN )) || [[ ! -d "$BACKUP_DIR" ]] || log "原配置备份：$BACKUP_DIR"
}

main "$@"
