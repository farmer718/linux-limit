#!/bin/bash
# ====================================================
# 网络限速策略 - 一键安装脚本
# ====================================================
# 使用方式:
# bash <(curl -Ls https://raw.githubusercontent.com/githubzhangfei/linux-limit/main/install.sh)
# ====================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 权限检查
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 权限执行此脚本"
    echo "使用方式: sudo bash <(curl -Ls https://raw.githubusercontent.com/githubzhangfei/linux-limit/main/install.sh)"
    exit 1
fi

log_info "开始部署网络限速策略..."

# 检测包管理器
if [ -x "$(command -v apt-get)" ]; then
    log_info "检测到 Debian/Ubuntu 系统，准备安装依赖..."
    apt-get update -y > /dev/null 2>&1 || log_warn "apt-get update 执行缓慢，继续..."
    apt-get install -y curl jq iproute2 cron awk coreutils > /dev/null 2>&1 || {
        log_error "依赖安装失败，请检查网络连接"
        exit 1
    }
elif [ -x "$(command -v yum)" ]; then
    log_info "检测到 CentOS/RHEL 系统，准备安装依赖..."
    yum install -y curl jq iproute cronie awk coreutils > /dev/null 2>&1 || {
        log_error "依赖安装失败，请检查网络连接"
        exit 1
    }
    systemctl enable crond > /dev/null 2>&1 || true
    systemctl start crond > /dev/null 2>&1 || true
elif [ -x "$(command -v apk)" ]; then
    log_info "检测到 Alpine 系统，准备安装依赖..."
    apk add --no-cache curl jq iproute2 dcron awk coreutils > /dev/null 2>&1 || {
        log_error "依赖安装失败，请检查网络连接"
        exit 1
    }
else
    log_error "不支持的 Linux 发行版，请手动安装依赖: curl, jq, iproute2, awk, coreutils"
    exit 1
fi

log_info "依赖检查完成"

# 核心变量配置
WORKER_SCRIPT="/usr/local/bin/net_limit_agent.sh"
LOG_FILE="/var/log/net_limit_agent.log"
CRON_FILE="/etc/cron.d/net_limit_agent"
REPO_URL="https://raw.githubusercontent.com/githubzhangfei/linux-limit/main"

# 5. 生成核心工作脚本 (Worker)
log_info "生成限速代理脚本..."
cat << 'EOF' > $WORKER_SCRIPT
#!/bin/bash

API_URL="http://zora.dianpingping.top:1024/api/computer/limit"
LOG_PREFIX="$(date '+%Y-%m-%d %H:%M:%S') -"
CACHE_FILE="/tmp/net_limit_last_response.md5"
LOG_FILE="/var/log/net_limit_agent.log"

# 1. 动态获取公网 IP (增加超时防止卡死)
PUBLIC_IP=$(curl -s --connect-timeout 10 https://api4.ipify.org)
if [ -z "$PUBLIC_IP" ]; then
    echo "$LOG_PREFIX ❌ 错误: 无法获取公网 IP，中断本次执行。" >> $LOG_FILE
    exit 1
fi

# 2. 高效获取默认出网网卡
IFACE=$(ip route | awk '/default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
    echo "$LOG_PREFIX ❌ 错误: 无法检测到默认出网网卡，中断本次执行。" >> $LOG_FILE
    exit 1
fi

# 3. 请求外部策略接口
RESPONSE=$(curl -s --connect-timeout 10 "$API_URL?client_ip=$PUBLIC_IP")
if [ -z "$RESPONSE" ]; then
    echo "$LOG_PREFIX ❌ 错误: 接口无响应，中断本次执行。" >> $LOG_FILE
    exit 1
fi

# 4. ================= 核心优化：状态对比与跳过机制 =================
CURRENT_MD5=$(echo "$RESPONSE" | md5sum | awk '{print $1}')

if [ -f "$CACHE_FILE" ]; then
    LAST_MD5=$(cat "$CACHE_FILE")
    # 如果 MD5 未变，直接无损退出，不干预网卡
    if [ "$CURRENT_MD5" = "$LAST_MD5" ]; then
        exit 0
    fi
fi

# 状态发生变化，保存新的状态
echo "$CURRENT_MD5" > "$CACHE_FILE"
echo "$LOG_PREFIX 🔄 策略状态更新，准备重构网卡规则..."
# ==========================================================

# 5. JSON 解析与容错处理
ENABLED=$(echo "$RESPONSE" | jq -r '.enabled // empty')
LIMIT_MBPS=$(echo "$RESPONSE" | jq -r '.limitMbps // 0')
LOSS=$(echo "$RESPONSE" | jq -r '.loss // 0')
DELAY_MS=$(echo "$RESPONSE" | jq -r '.delayMs // 0')
JITTER_MS=$(echo "$RESPONSE" | jq -r '.jitterMs // 0')

# 6. 策略执行逻辑
# 清理现有规则
tc qdisc del dev $IFACE root 2>/dev/null || true

# 判断开关状态：空、null 或 0 均视为禁用
if [ -z "$ENABLED" ] || [ "$ENABLED" = "null" ] || [ "$ENABLED" = "0" ]; then
    echo "$LOG_PREFIX 🟢 策略已禁用，网卡 $IFACE 已恢复无限制状态。" >> $LOG_FILE
    exit 0
fi

echo "$LOG_PREFIX ⚙️ 应用新策略 - IP:$PUBLIC_IP 网卡:$IFACE | 宽带:${LIMIT_MBPS}Mbps 丢包:${LOSS}% 延迟:${DELAY_MS}ms 抖动:${JITTER_MS}ms" >> $LOG_FILE

# A. 使用 HTB 建立根队列管理带宽
tc qdisc add dev $IFACE root handle 1: htb default 10
tc class add dev $IFACE parent 1: classid 1:10 htb rate ${LIMIT_MBPS}mbit

# B. 动态拼接 netem 延迟/丢包参数
NETEM_ARGS=""

if awk "BEGIN {exit !($DELAY_MS > 0)}"; then
    NETEM_ARGS="delay ${DELAY_MS}ms"
    if awk "BEGIN {exit !($JITTER_MS > 0)}"; then
        NETEM_ARGS="$NETEM_ARGS ${JITTER_MS}ms"
    fi
fi

if awk "BEGIN {exit !($LOSS > 0)}"; then
    NETEM_ARGS="$NETEM_ARGS loss ${LOSS}%"
fi

# C. 将 netem 作为子节点挂载到 HTB 下 (级联生效)
if [ -n "$NETEM_ARGS" ]; then
    tc qdisc add dev $IFACE parent 1:10 handle 10: netem $NETEM_ARGS
fi

echo "$LOG_PREFIX ✅ 策略应用成功。" >> $LOG_FILE
EOF

chmod +x $WORKER_SCRIPT
log_info "限速代理脚本已创建: $WORKER_SCRIPT"

# 配置并持久化 Cron 定时任务
log_info "配置定时任务..."
cat > $CRON_FILE << EOF
# 网络限速策略定时执行
*/2 * * * * root $WORKER_SCRIPT 2>&1 | logger -t net_limit_agent
EOF
chmod 644 $CRON_FILE

# 平滑重启计划任务服务
if systemctl list-units --type=service 2>/dev/null | grep -q cron.service; then
    systemctl restart cron 2>/dev/null || true
elif systemctl list-units --type=service 2>/dev/null | grep -q crond.service; then
    systemctl restart crond 2>/dev/null || true
fi

# 初始化日志文件
touch $LOG_FILE
chmod 666 $LOG_FILE

log_info "=================================================="
log_info "🎉 部署完成！"
log_info "=================================================="
echo ""
echo "📄 工作脚本路径:   $WORKER_SCRIPT"
echo "📝 日志文件路径:   $LOG_FILE"
echo "📋 Cron 配置文件:  $CRON_FILE"
echo "⏱️  执行频率:      每 2 分钟一次"
echo "🔍 查看日志:       tail -f $LOG_FILE"
echo ""
log_info "正在进行首次手动触发测试..."
echo ""

# 首次执行
$WORKER_SCRIPT || log_warn "首次执行可能受网络延迟影响，请稍候后查看日志"

# 显示最近日志
if [ -f "$LOG_FILE" ]; then
    echo ""
    echo "📊 最近执行日志:"
    tail -n 3 $LOG_FILE 2>/dev/null || echo "（暂无日志）"
fi

echo ""
log_info "=================================================="
log_info "✅ 安装成功！系统已启用网络限速服务"
log_info "=================================================="
