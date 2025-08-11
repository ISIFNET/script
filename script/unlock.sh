#!/usr/bin/env bash
# set-dns.sh — Lightweight, polite, bilingual DNS setter ✨
# Works with Debian/Ubuntu, RHEL/CentOS/Rocky, Arch, NixOS (with systemd-resolved), etc.

set -euo pipefail

# ===== Defaults (env or CLI can override) =====
DNS_SERVERS_CSV="${DNS_SERVERS_CSV:-151.240.12.10}"
TEST_DOMAIN="${TEST_DOMAIN:-unlock.isif.net}"
EXPECT_IP="${EXPECT_IP:-1.1.1.1}"
LANG_CHOICE="${LANG_CHOICE:-auto}"   # auto|zh|en
FORCE_METHOD="${FORCE_METHOD:-auto}" # auto|resolved|nm|resolv
DRY_RUN="${DRY_RUN:-0}"              # 1 to simulate
QUIET="${QUIET:-0}"                  # 1 for minimal output
ONLY_IPV4="${ONLY_IPV4:-0}"          # 1 to keep only IPv4 DNSes
ONLY_IPV6="${ONLY_IPV6:-0}"          # 1 to keep only IPv6 DNSes

# ===== i18n =====
pick_lang() {
  case "$LANG_CHOICE" in
    zh|ZH|cn|CN|zh_CN|zh_TW) echo zh ;;
    en|EN|us|US|en_US|en_GB) echo en ;;
    auto|Auto|AUTO|*)
      case "${LANG:-}" in zh*|ZH*) echo zh ;; *) echo en ;; esac ;;
  esac
}
LANG_USE="$(pick_lang)"

say_zh() {
  case "$1" in
    need_root) echo "请使用 root 运行（sudo $0）。";;
    start) echo "开始设置 DNS（优雅模式）。";;
    parsed_args) echo "参数就绪：准备出发 🚀";;
    using_resolved) echo "检测到 systemd-resolved，采用 drop-in 方式设置。";;
    using_nm) echo "检测到 NetworkManager，按活动连接设置手动 DNS。";;
    using_resolv) echo "未检测到前两者，直接写入 /etc/resolv.conf（已备份）。";;
    backed_up) echo "已备份 /etc/resolv.conf ->";;
    flush_cache) echo "刷新 DNS 缓存中…";;
    testing) echo "正在解析域名：";;
    hits) echo "解析结果如下：";;
    success) echo "设置成功 ✅：命中期望 IP";;
    fail) echo "可能尚未生效 ❗：未命中期望 IP，请稍后重试或检查网络管理器。";;
    dryrun) echo "演练模式（不会真的修改系统），下面只是预览动作：";;
    done) echo "全部完成，祝你网络清清爽爽 🌊";;
    no_active_nm) echo "未发现活动的 NetworkManager 连接，跳过 nm 配置。";;
    restored) echo "已尝试还原最近的 resolv.conf 备份。";;
    installing) echo "正在安装为 /usr/local/bin/set-dns …";;
    installed) echo "安装完成：现在可以直接运行 set-dns";;
    usage)
      cat <<'EOF'
用法：
  sudo ./set-dns.sh [选项]

选项：
  --dns <CSV>           要设置的 DNS，逗号分隔（默认: 1.1.1.1,2606:4700:4700::1111）
  --domain <域名>       测试解析的域名（默认: unlock.isif.net）
  --expect <IP>         期望命中的 IP（默认: 1.1.1.1）
  --lang <auto|zh|en>   语言（默认: auto）
  --method <auto|resolved|nm|resolv>  强制方式（默认: auto）
  --only-ipv4           仅使用 IPv4 DNS
  --only-ipv6           仅使用 IPv6 DNS
  --dry-run             演练，不修改系统
  --quiet               安静输出
  --restore             还原最近的 /etc/resolv.conf 备份
  --install             安装为 /usr/local/bin/set-dns
  -h,--help             显示帮助
EOF
      ;;
  esac
}

say_en() {
  case "$1" in
    need_root) echo "Please run as root (sudo $0).";;
    start) echo "Starting DNS setup (polite mode).";;
    parsed_args) echo "Args parsed: ready to roll 🚀";;
    using_resolved) echo "systemd-resolved detected, applying drop-in override.";;
    using_nm) echo "NetworkManager detected, setting per active connection.";;
    using_resolv) echo "Fallback: writing /etc/resolv.conf directly (backed up).";;
    backed_up) echo "Backed up /etc/resolv.conf ->";;
    flush_cache) echo "Flushing DNS caches…";;
    testing) echo "Querying domain:";;
    hits) echo "Answers:";;
    success) echo "Success ✅: expected IP matched";;
    fail) echo "May not be applied yet ❗: expected IP not found. Retry later / check network manager.";;
    dryrun) echo "Dry-run mode (no changes). Previewing actions only:";;
    done) echo "All set. May your packets flow smoothly 🌊";;
    no_active_nm) echo "No active NetworkManager connections; skipping nm config.";;
    restored) echo "Attempted to restore the latest resolv.conf backup.";;
    installing) echo "Installing to /usr/local/bin/set-dns …";;
    installed) echo "Installed. Now you can run: set-dns";;
    usage)
      cat <<'EOF'
Usage:
  sudo ./set-dns.sh [options]

Options:
  --dns <CSV>           DNS servers (comma-separated), default: 1.1.1.1,2606:4700:4700::1111
  --domain <name>       Domain to test (default: unlock.isif.net)
  --expect <IP>         Expected IP (default: 1.1.1.1)
  --lang <auto|zh|en>   Language (default: auto)
  --method <auto|resolved|nm|resolv>  Force method (default: auto)
  --only-ipv4           Use IPv4 DNS only
  --only-ipv6           Use IPv6 DNS only
  --dry-run             Simulate only, no system changes
  --quiet               Minimal output
  --restore             Restore the latest /etc/resolv.conf backup
  --install             Install to /usr/local/bin/set-dns
  -h,--help             Show help
EOF
      ;;
  esac
}

_() { if [ "${LANG_USE}" = zh ]; then say_zh "$@"; else say_en "$@"; fi; }
log() { [ "$QUIET" -eq 1 ] || printf "[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# ===== arg parsing =====
RESTORE=0; INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dns) DNS_SERVERS_CSV="$2"; shift 2;;
    --domain) TEST_DOMAIN="$2"; shift 2;;
    --expect) EXPECT_IP="$2"; shift 2;;
    --lang) LANG_CHOICE="$2"; LANG_USE="$(pick_lang)"; shift 2;;
    --method) FORCE_METHOD="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --quiet) QUIET=1; shift;;
    --only-ipv4) ONLY_IPV4=1; shift;;
    --only-ipv6) ONLY_IPV6=1; shift;;
    --restore) RESTORE=1; shift;;
    --install) INSTALL=1; shift;;
    -h|--help) _ usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; _ usage; exit 1;;
  esac
done
[ "$ONLY_IPV4" -eq 1 ] && ONLY_IPV6=0
[ "$ONLY_IPV6" -eq 1 ] && ONLY_IPV4=0

# ===== helpers =====
IFS=',' read -r -a DNS_LIST <<<"$DNS_SERVERS_CSV"

filter_dns_family() {
  local out=()
  for ns in "${DNS_LIST[@]}"; do
    if [ "$ONLY_IPV4" -eq 1 ] && [[ "$ns" != *:* ]]; then out+=("$ns"); fi
    if [ "$ONLY_IPV6" -eq 1 ] && [[ "$ns" == *:* ]]; then out+=("$ns"); fi
    if [ "$ONLY_IPV4" -eq 0 ] && [ "$ONLY_IPV6" -eq 0 ]; then out+=("$ns"); fi
  done
  DNS_LIST=("${out[@]}")
}

join_by() { local IFS="$1"; shift; echo "$*"; }

backup_resolv_conf() {
  local ts="/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)"
  if [ -e /etc/resolv.conf ]; then
    [ "$DRY_RUN" -eq 1 ] || cp -a /etc/resolv.conf "$ts" || true
    log "$(_ backed_up) $ts"
  fi
}

restore_latest_resolv() {
  local latest
  latest="$(ls -1t /etc/resolv.conf.bak.* 2>/dev/null | head -n1 || true)"
  if [ -n "$latest" ]; then
    [ "$DRY_RUN" -eq 1 ] || cp -a "$latest" /etc/resolv.conf
    log "$(_ restored)"
  fi
}

write_resolv_conf() {
  # Handle immutable / symlink
  if have chattr; then [ "$DRY_RUN" -eq 1 ] || chattr -i /etc/resolv.conf 2>/dev/null || true; fi
  [ -L /etc/resolv.conf ] && [ "$DRY_RUN" -eq 0 ] && rm -f /etc/resolv.conf
  [ "$DRY_RUN" -eq 0 ] || return 0

  {
    echo "# Generated by set-dns.sh @ $(date)"
    for ns in "${DNS_LIST[@]}"; do echo "nameserver $ns"; done
    echo "options timeout:2 attempts:2"
  } >/etc/resolv.conf
  log "$(_ using_resolv)"
}

set_dns_systemd_resolved() {
  local dir="/etc/systemd/resolved.conf.d"
  local dns_space
  dns_space="$(join_by ' ' "${DNS_LIST[@]}")"
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$dir"
  if [ "$DRY_RUN" -eq 0 ]; then
    {
      echo "[Resolve]"
      echo "DNS=$dns_space"
      echo "FallbackDNS="
    } >"$dir/99-override.conf"
    systemctl restart systemd-resolved
  fi
  log "$(_ using_resolved)"
}

set_dns_nmcli() {
  local dns4=() dns6=()
  for ns in "${DNS_LIST[@]}"; do
    case "$ns" in *:*) dns6+=("$ns");; *) dns4+=("$ns");; esac
  done
  local dns4_csv="$(join_by , "${dns4[@]:-}")"
  local dns6_csv="$(join_by , "${dns6[@]:-}")"

  local active
  active="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2!=""{print $1}')"
  if [ -z "$active" ]; then log "$(_ no_active_nm)"; return 0; fi

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if [ "$DRY_RUN" -eq 0 ]; then
      nmcli connection modify "$name" ipv4.ignore-auto-dns yes || true
      nmcli connection modify "$name" ipv6.ignore-auto-dns yes || true
      [ -n "$dns4_csv" ] && nmcli connection modify "$name" ipv4.dns "$dns4_csv" || true
      [ -n "$dns6_csv" ] && nmcli connection modify "$name" ipv6.dns "$dns6_csv" || true
      nmcli connection up "$name" >/dev/null || true
    fi
    log "nm: $name -> dns4=[${dns4_csv:-∅}] dns6=[${dns6_csv:-∅}]"
  done <<<"$active"
  log "$(_ using_nm)"
}

flush_dns_cache() {
  log "$(_ flush_cache)"
  if have resolvectl; then
    [ "$DRY_RUN" -eq 1 ] || resolvectl flush-caches || true
  elif have systemd-resolve; then
    [ "$DRY_RUN" -eq 1 ] || systemd-resolve --flush-caches || true
  fi
}

test_resolution() {
  log "$(_ testing) $TEST_DOMAIN"
  local hits
  hits="$(getent ahosts "$TEST_DOMAIN" | awk '{print $1}' | sort -u || true)"
  [ "$QUIET" -eq 1 ] || { log "$(_ hits)"; printf "%s\n" "$hits" | sed 's/^/  - /' >&2; }
  if printf "%s\n" "$hits" | grep -q -F -- "$EXPECT_IP"; then
    echo "$(_ success): $TEST_DOMAIN -> $EXPECT_IP"
    return 0
  else
    echo "$(_ fail) ($TEST_DOMAIN -> $EXPECT_IP)"
    return 1
  fi
}

choose_method() {
  case "$FORCE_METHOD" in
    resolved|nm|resolv) echo "$FORCE_METHOD"; return;;
    auto|*)
      if have systemctl && is_active systemd-resolved && have resolvectl; then
        echo resolved
      elif have nmcli && have systemctl && is_active NetworkManager; then
        echo nm
      else
        echo resolv
      fi
      ;;
  esac
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "$(_ need_root)" >&2
    exit 1
  fi
}

install_self() {
  log "$(_ installing)"
  [ "$DRY_RUN" -eq 1 ] && return 0
  install -m 0755 "$0" /usr/local/bin/set-dns
  log "$(_ installed)"
}

main() {
  ensure_root
  filter_dns_family

  [ "$RESTORE" -eq 1 ] && { restore_latest_resolv; exit 0; }
  [ "$INSTALL" -eq 1 ] && { install_self; exit 0; }

  [ "$QUIET" -eq 1 ] || log "$(_ start)"
  [ "$DRY_RUN" -eq 1 ] && log "$(_ dryrun)"
  log "$(_ parsed_args) DNS=[${DNS_LIST[*]}] domain=$TEST_DOMAIN expect=$EXPECT_IP lang=$LANG_USE method=$FORCE_METHOD"

  local method
  method="$(choose_method)"

  case "$method" in
    resolved) backup_resolv_conf; set_dns_systemd_resolved ;;
    nm)       backup_resolv_conf; set_dns_nmcli ;;
    resolv)   backup_resolv_conf; write_resolv_conf ;;
  esac

  flush_dns_cache
  sleep 0.5
  test_resolution
  [ "$QUIET" -eq 1 ] || log "$(_ done)"
}

main
