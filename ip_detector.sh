#!/usr/bin/env bash
# 简单公网 IP 变更检测 + Telegram 通知
# 不依赖 Cloudflare，专门用来监控公网 IP 变化

set -u
set -o pipefail

BASE_DIR="/root/ipwatch"
CONF_FILE="$BASE_DIR/config.env"
CACHE_FILE="$BASE_DIR/cache.env"

LOCK_DIR="$BASE_DIR/.lock"

# -------------------------
# 时间 & 基础工具
# -------------------------
ensure_base_dir() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR" 2>/dev/null || true
}

bj_now() { TZ="Asia/Shanghai" date "+%Y-%m-%d %H:%M:%S"; }

say() { printf "%s\n" "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  local missing=0
  for c in curl; do
    if ! need_cmd "$c"; then
      say "[ERR] 缺少依赖：$c"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

# -------------------------
# 简单锁，避免并发执行
# -------------------------
acquire_lock() {
  ensure_base_dir
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT
    return 0
  else
    say "[WARN] 已有任务在运行（锁：$LOCK_DIR），本次退出。"
    return 1
  fi
}

# -------------------------
# 配置 & 缓存
# -------------------------
# 配置文件格式（手动编辑或交互生成）：
# TELEGRAM_ENABLE="1"
# TELEGRAM_BOT_TOKEN="xxxx"
# TELEGRAM_CHAT_ID="123456"
# ENABLE_IPV4="1"
# ENABLE_IPV6="0"

load_config() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  fi

  TELEGRAM_ENABLE="${TELEGRAM_ENABLE:-0}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

  ENABLE_IPV4="${ENABLE_IPV4:-1}"
  ENABLE_IPV6="${ENABLE_IPV6:-0}"
}

cache_load() {
  if [ -f "$CACHE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CACHE_FILE"
  fi
  LAST_IPV4="${LAST_IPV4:-}"
  LAST_IPV6="${LAST_IPV6:-}"
}

cache_save() {
  ensure_base_dir
  umask 077
  cat > "$CACHE_FILE" <<EOF
LAST_IPV4="${LAST_IPV4}"
LAST_IPV6="${LAST_IPV6}"
EOF
  chmod 600 "$CACHE_FILE" 2>/dev/null || true
}

# -------------------------
# Telegram
# -------------------------
tg_enabled() {
  [ "${TELEGRAM_ENABLE:-0}" = "1" ] && \
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && \
  [ -n "${TELEGRAM_CHAT_ID:-}" ]
}

tg_send() {
  local text="$1"
  if ! tg_enabled; then
    return 0
  fi
  local api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  curl -fsS --max-time 10 -X POST "$api" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "text=${text}" >/dev/null 2>&1 || return 1
  return 0
}

tg_notify_change() {
  # 传入 old4 new4 old6 new6
  local old4="$1" new4="$2" old6="$3" new6="$4"
  local ts msg
  ts="$(bj_now)"

  msg="公网 IP 变更通知
Time(BJ): ${ts}"

  if [ -n "$new4" ]; then
    if [ -n "$old4" ]; then
      msg="${msg}
IPv4: ${old4} -> ${new4}"
    else
      msg="${msg}
IPv4: ${new4} (首次记录)"
    fi
  fi

  if [ -n "$new6" ]; then
    if [ -n "$old6" ]; then
      msg="${msg}
IPv6: ${old6} -> ${new6}"
    else
      msg="${msg}
IPv6: ${new6} (首次记录)"
    fi
  fi

  tg_send "$msg" || true
}

# -------------------------
# IP 获取
# -------------------------
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_ipv6() { [[ "$1" =~ : ]]; }

get_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null | trim || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4 -fsS --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
      | awk -F= '/^ip=/{print $2}' | trim || true)"
  fi
  if [ -n "$ip" ] && valid_ipv4 "$ip"; then echo "$ip"; else echo ""; fi
}

get_ipv6() {
  local ip=""
  ip="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null | trim || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -6 -fsS --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
      | awk -F= '/^ip=/{print $2}' | trim || true)"
  fi
  if [ -n "$ip" ] && valid_ipv6 "$ip"; then echo "$ip"; else echo ""; fi
}

# -------------------------
# Telegram 配置交互（可选）
# -------------------------
env_set_kv() {
  local key="$1" val="$2"
  ensure_base_dir
  touch "$CONF_FILE"
  chmod 600 "$CONF_FILE" 2>/dev/null || true

  local esc
  esc="$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  awk -v k="$key" -v v="$esc" '
    BEGIN{found=0}
    $0 ~ "^"k"=" {
      print k"=\""v"\""
      found=1
      next
    }
    {print}
    END{
      if(found==0) print k"=\""v"\""
    }
  ' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
}

telegram_config_interactive() {
  ensure_base_dir
  umask 077
  load_config

  say "========== Telegram 通知配置 =========="
  say "只影响：TELEGRAM_ENABLE / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / ENABLE_IPV4 / ENABLE_IPV6"
  say ""

  local en token chat
  read -r -p "启用 Telegram 通知？[1=是,0=否]（默认0）: " en
  en="${en:-0}"

  if [ "$en" = "1" ]; then
    read -r -p 'TELEGRAM_BOT_TOKEN="你的Bot Token": ' token
    read -r -p 'TELEGRAM_CHAT_ID="你的Chat ID/群ID": ' chat
    env_set_kv "TELEGRAM_ENABLE" "1"
    env_set_kv "TELEGRAM_BOT_TOKEN" "$token"
    env_set_kv "TELEGRAM_CHAT_ID" "$chat"
  else
    env_set_kv "TELEGRAM_ENABLE" "0"
    env_set_kv "TELEGRAM_BOT_TOKEN" ""
    env_set_kv "TELEGRAM_CHAT_ID" ""
  fi

  say ""
  say "是否监控 IPv4 / IPv6："
  local ipmode
  say "1) 只监控 IPv4"
  say "2) 只监控 IPv6"
  say "3) IPv4 + IPv6"
  read -r -p "请选择 [1/2/3]（默认1）: " ipmode
  ipmode="${ipmode:-1}"

  case "$ipmode" in
    2) env_set_kv "ENABLE_IPV4" "0"; env_set_kv "ENABLE_IPV6" "1" ;;
    3) env_set_kv "ENABLE_IPV4" "1"; env_set_kv "ENABLE_IPV6" "1" ;;
    *) env_set_kv "ENABLE_IPV4" "1"; env_set_kv "ENABLE_IPV6" "0" ;;
  esac

  say "[OK] 配置已写入：$CONF_FILE"
}

telegram_test() {
  ensure_deps || return 1
  load_config

  if ! tg_enabled; then
    say "[ERR] Telegram 未启用或配置不完整。"
    return 1
  fi

  local ts a_local v6_local
  ts="$(bj_now)"

  a_local="(disabled)"
  v6_local="(disabled)"
  if [ "${ENABLE_IPV4:-1}" = "1" ]; then
    a_local="$(get_ipv4)"; [ -z "$a_local" ] && a_local="(get ipv4 fail)"
  fi
  if [ "${ENABLE_IPV6:-0}" = "1" ]; then
    v6_local="$(get_ipv6)"; [ -z "$v6_local" ] && v6_local="(get ipv6 fail)"
  fi

  local msg="IP 监控 Telegram 测试
IPv4 local: ${a_local}
IPv6 local: ${v6_local}
Time(BJ): ${ts}"

  if tg_send "$msg"; then
    say "[OK] Telegram 测试消息已发送。"
    return 0
  else
    say "[ERR] Telegram 测试消息发送失败。"
    return 1
  fi
}

# -------------------------
# 核心：执行一次检测
# -------------------------
run_once() {
  ensure_base_dir
  ensure_deps || return 1
  load_config
  cache_load
  acquire_lock || return 0

  if [ "${ENABLE_IPV4}" != "1" ] && [ "${ENABLE_IPV6}" != "1" ]; then
    say "[ERR] 配置错误：IPv4/IPv6 都未启用。"
    return 1
  fi

  say "========== 公网 IP 监控（北京时间：$(bj_now)） =========="
  say "[INFO] IPv4: ENABLE=${ENABLE_IPV4}"
  say "[INFO] IPv6: ENABLE=${ENABLE_IPV6}"
  say "[INFO] Telegram: ENABLE=${TELEGRAM_ENABLE}"
  say ""

  local changed=0
  local old4="$LAST_IPV4" old6="$LAST_IPV6"
  local new4="" new6=""

  if [ "${ENABLE_IPV4}" = "1" ]; then
    new4="$(get_ipv4)"
    if [ -n "$new4" ]; then
      say "[INFO] 当前公网 IPv4：$new4"
      if [ "$new4" != "$LAST_IPV4" ]; then
        say "[INFO] IPv4 发生变化：${LAST_IPV4:-<none>} -> $new4"
        LAST_IPV4="$new4"
        changed=1
      else
        say "[INFO] IPv4 未变化。"
      fi
    else
      say "[ERR] 未能获取公网 IPv4。"
    fi
    say ""
  fi

  if [ "${ENABLE_IPV6}" = "1" ]; then
    new6="$(get_ipv6)"
    if [ -n "$new6" ]; then
      say "[INFO] 当前公网 IPv6：$new6"
      if [ "$new6" != "$LAST_IPV6" ]; then
        say "[INFO] IPv6 发生变化：${LAST_IPV6:-<none>} -> $new6"
        LAST_IPV6="$new6"
        changed=1
      else
        say "[INFO] IPv6 未变化。"
      fi
    else
      say "[ERR] 未能获取公网 IPv6。"
    fi
    say ""
  fi

  cache_save

  if [ "$changed" -eq 1 ]; then
    say "[OK] 检测到 IP 变更，准备发送 Telegram 通知（如已启用）。"
    tg_notify_change "$old4" "$LAST_IPV4" "$old6" "$LAST_IPV6"
  else
    say "[OK] 本次未检测到 IP 变更。"
  fi
}

# -------------------------
# cron 安装 / 卸载（可选）
# -------------------------
cron_line() {
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  echo "* * * * * bash \"$script_path\" --run >/dev/null 2>&1 # IP_WATCH"
}

install_cron() {
  ensure_deps || return 1
  local line
  line="$(cron_line)"

  if need_cmd crontab; then
    (crontab -l 2>/dev/null | grep -v ' # IP_WATCH$' ; echo "$line") | crontab -
    say "[OK] 已安装 crontab（每1分钟执行一次）。"
  else
    if [ "$(id -u)" -ne 0 ]; then
      say "[ERR] 修改 /etc/crontabs/root 需要 root。"
      return 1
    fi
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    grep -v ' # IP_WATCH$' /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null || true
    printf "%s\n" "$line" >> /etc/crontabs/root.tmp
    mv -f /etc/crontabs/root.tmp /etc/crontabs/root
    say "[OK] 已写入 /etc/crontabs/root（每1分钟执行一次）。"
  fi
}

uninstall_cron() {
  if need_cmd crontab; then
    (crontab -l 2>/dev/null | grep -v ' # IP_WATCH$') | crontab - 2>/dev/null || true
    say "[OK] 已移除 crontab 中 IP_WATCH 定时任务。"
  else
    if [ "$(id -u)" -ne 0 ]; then
      say "[ERR] 修改 /etc/crontabs/root 需要 root。"
      return 1
    fi
    if [ -f /etc/crontabs/root ]; then
      grep -v ' # IP_WATCH$' /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null || true
      mv -f /etc/crontabs/root.tmp /etc/crontabs/root
      say "[OK] 已移除 /etc/crontabs/root 中 IP_WATCH 定时任务。"
    else
      say "[INFO] 未发现 /etc/crontabs/root。"
    fi
  fi
}

show_paths() {
  say "配置文件：$CONF_FILE"
  say "缓存文件：$CACHE_FILE（保存最近一次检测到的 IPv4/IPv6）"
}

usage() {
  cat <<EOF
用法：
  bash ipwatch.sh --run            # 执行一次检测，如有 IP 变更则发送通知
  bash ipwatch.sh --tg-config      # 交互配置 Telegram 与监控 IPv4/IPv6 选项
  bash ipwatch.sh --telegram-test  # 发送一条 Telegram 测试消息
  bash ipwatch.sh --install-cron   # 安装每 1 分钟执行一次的 cron
  bash ipwatch.sh --uninstall-cron # 移除 cron
  bash ipwatch.sh --show-paths     # 显示配置/缓存路径
EOF
}

# -------------------------
# main
# -------------------------
ensure_base_dir

case "${1:-}" in
  --run ) run_once ;;
  --tg-config|--telegram-config ) telegram_config_interactive ;;
  --telegram-test ) telegram_test ;;
  --install-cron ) install_cron ;;
  --uninstall-cron ) uninstall_cron ;;
  --show-paths ) show_paths ;;
  * ) usage ;;
esac
