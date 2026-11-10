#!/usr/bin/env bash
# LXC network diagnostics and optional runtime tuning.
# No arguments run the full interactive mode; --json is read-only.

set -u

SCRIPT_NAME="$(basename "$0")"
TRY_ENABLE=0
TUNE=0
OPTIMIZE=0
JSON=0
ALL_MODE=0
ORIGINAL_ARGC=$#

usage() {
    cat <<EOF
用法: $SCRIPT_NAME [选项]

选项:
  --try-enable  测试容器是否允许修改 BBR/fq 和 32 MiB TCP 缓冲区
  --tune       询问带宽/RTT，按合理范围调整 TCP 缓冲区
  --optimize   先确认，再询问带宽并执行一键运行时优化
  --all        一键执行检测、询问带宽并运行全部优化
  --json       输出 JSON 检测结果（不适合交互式 --tune/--optimize）
  -h, --help   显示帮助

说明:
  不带参数时默认执行全功能交互优化；会先确认再修改。
  所有修改仅作用于当前运行时，不自动写入 sysctl 配置文件。
  LXC 不能修改的宿主机参数会显示为“被拒绝”，需要到宿主机调整。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --try-enable) TRY_ENABLE=1 ;;
        --tune) TUNE=1 ;;
        --optimize|--all) OPTIMIZE=1; TUNE=1; TRY_ENABLE=1; ALL_MODE=1 ;;
        --json) JSON=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "错误: 未知选项: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# No arguments means full interactive mode; --json remains read-only unless an
# explicit optimization option is supplied.
if [ "$ORIGINAL_ARGC" -eq 0 ]; then
    OPTIMIZE=1
    TUNE=1
    TRY_ENABLE=1
    ALL_MODE=1
fi

ROOT=0
[ "$(id -u)" -eq 0 ] && ROOT=1

get_value() {
    local key="$1" value
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "unavailable"
}

has_token() {
    printf '%s\n' "$1" | tr ' ' '\n' | grep -Fxq "$2"
}

write_sysctl() {
    local key="$1" value="$2"
    [ "$ROOT" -eq 1 ] && sysctl -w "$key=$value" >/dev/null 2>&1
}

result=""
record() {
    result="${result}${1}: ${2}\n"
}

iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
[ -z "$iface" ] && iface="eth0"

available="$(get_value net.ipv4.tcp_available_congestion_control)"
active="$(get_value net.ipv4.tcp_congestion_control)"
default_qdisc="$(get_value net.core.default_qdisc)"
tcp_rmem="$(get_value net.ipv4.tcp_rmem)"
tcp_wmem="$(get_value net.ipv4.tcp_wmem)"
rmem_max="$(get_value net.core.rmem_max)"
wmem_max="$(get_value net.core.wmem_max)"
optmem_max="$(get_value net.core.optmem_max)"
backlog="$(get_value net.core.netdev_max_backlog)"
somaxconn="$(get_value net.core.somaxconn)"
syn_backlog="$(get_value net.ipv4.tcp_max_syn_backlog)"
fastopen="$(get_value net.ipv4.tcp_fastopen)"
conntrack_count="$(get_value net.netfilter.nf_conntrack_count)"
conntrack_max="$(get_value net.netfilter.nf_conntrack_max)"
mtu="$(ip link show dev "$iface" 2>/dev/null | sed -n 's/.* mtu \([0-9][0-9]*\).*/\1/p' | head -n1)"
[ -z "$mtu" ] && mtu="unavailable"
link_stats="$(ip -s link show dev "$iface" 2>/dev/null | tail -n +2 | tr '\n' ' ' | sed 's/  */ /g')"
fd_limit="$(ulimit -n 2>/dev/null || echo unavailable)"

auto_bbr="否"; has_token "$available" bbr && auto_bbr="是"
bbr_active="否"; [ "$active" = bbr ] && bbr_active="是"

write_rmem="未测试"
write_wmem="未测试"
write_rmem_max="未测试"
write_wmem_max="未测试"
write_bbr="未测试"
write_qdisc="未测试"
if [ "$TRY_ENABLE" -eq 1 ] && [ "$OPTIMIZE" -eq 0 ]; then
    if [ "$ROOT" -ne 1 ]; then
        write_rmem="否（需要 root）"; write_wmem="否（需要 root）"
        write_rmem_max="否（需要 root）"; write_wmem_max="否（需要 root）"
        write_bbr="否（需要 root）"; write_qdisc="否（需要 root）"
    else
        write_sysctl net.ipv4.tcp_rmem '4096 131072 33554432' && write_rmem="是" || write_rmem="否（被拒绝）"
        write_sysctl net.ipv4.tcp_wmem '4096 16384 33554432' && write_wmem="是" || write_wmem="否（被拒绝）"
        write_sysctl net.core.rmem_max 33554432 && write_rmem_max="是" || write_rmem_max="否（被拒绝）"
        write_sysctl net.core.wmem_max 33554432 && write_wmem_max="是" || write_wmem_max="否（被拒绝）"
        write_sysctl net.ipv4.tcp_congestion_control bbr && write_bbr="是" || write_bbr="否（被拒绝或不可用）"
        write_sysctl net.core.default_qdisc fq && write_qdisc="是" || write_qdisc="否（被拒绝）"
    fi
fi

# Calculate and apply a bounded buffer from bandwidth and RTT.
tune_status="未执行"
tune_bandwidth_mbps=""
tune_rtt_ms="100"
tune_buffer_bytes=""
tune_rmem=""
tune_wmem=""
run_tune() {
    printf '\n[按带宽调整 TCP 缓冲区]\n' >&2
    if [ "$ROOT" -ne 1 ]; then
        tune_status="失败：需要 root"
        printf '%s\n' '无法调整：需要 root。' >&2
        return
    fi
    printf '%s' '请输入容器带宽（Mbps，例如 100、500、1000）： ' >&2
    read -r tune_bandwidth_mbps
    printf '%s' '请输入 RTT 毫秒（直接回车使用 100）： ' >&2
    read -r tune_rtt_ms
    [ -z "$tune_rtt_ms" ] && tune_rtt_ms=100
    if ! printf '%s' "$tune_bandwidth_mbps" | grep -Eq '^[0-9]+([.][0-9]+)?$' || \
       ! printf '%s' "$tune_rtt_ms" | grep -Eq '^[0-9]+([.][0-9]+)?$' || \
       ! awk "BEGIN { exit !($tune_bandwidth_mbps > 0 && $tune_rtt_ms > 0) }"; then
        tune_status="失败：输入无效"
        printf '%s\n' '输入无效：带宽和 RTT 必须是大于 0 的数字。' >&2
        return
    fi
    tune_buffer_bytes="$(awk -v mbps="$tune_bandwidth_mbps" -v rtt="$tune_rtt_ms" 'BEGIN { b=mbps*1000000/8*(rtt/1000)*4; if (b<4194304) b=4194304; if (b>67108864) b=67108864; printf "%d", b }')"
    tune_rmem="4096 131072 $tune_buffer_bytes"
    tune_wmem="4096 16384 $tune_buffer_bytes"
    if write_sysctl net.ipv4.tcp_rmem "$tune_rmem" && \
       write_sysctl net.ipv4.tcp_wmem "$tune_wmem" && \
       write_sysctl net.core.rmem_max "$tune_buffer_bytes" && \
       write_sysctl net.core.wmem_max "$tune_buffer_bytes"; then
        tune_status="已应用（当前运行时）"
        printf '最大缓冲区：%s bytes（约 %s MiB）\n' "$tune_buffer_bytes" "$(awk -v b="$tune_buffer_bytes" 'BEGIN { printf "%.1f", b/1048576 }')" >&2
    else
        tune_status="失败：LXC 或宿主机拒绝了 sysctl"
        printf '%s\n' '缓冲区调整失败，LXC 或宿主机拒绝了一个或多个 sysctl。' >&2
    fi
}

if [ "$TUNE" -eq 1 ] && [ "$OPTIMIZE" -eq 0 ]; then
    run_tune
fi

# Conservative one-click runtime tuning. It never changes MTU automatically.
optimize_status="未执行"
optimize_note=""
if [ "$OPTIMIZE" -eq 1 ]; then
    printf '\n[一键优化确认]\n' >&2
    printf '%s\n' '将尝试修改当前容器运行时的 BBR/fq、TCP 队列、Fast Open、缓冲区和网卡 offload。' >&2
    printf '%s' '继续吗？输入 yes 执行： ' >&2
    read -r answer
    if [ "$answer" != "yes" ]; then
        optimize_status="已取消"
    elif [ "$ROOT" -ne 1 ]; then
        optimize_status="失败：需要 root"
    else
        run_tune
        ok=0; fail=0
        write_sysctl net.core.default_qdisc fq || fail=$((fail+1))
        if has_token "$available" bbr; then
            write_sysctl net.ipv4.tcp_congestion_control bbr || fail=$((fail+1))
        fi
        write_sysctl net.ipv4.tcp_fastopen 3 || fail=$((fail+1))
        write_sysctl net.core.netdev_max_backlog 65536 || fail=$((fail+1))
        write_sysctl net.core.somaxconn 65535 || fail=$((fail+1))
        write_sysctl net.ipv4.tcp_max_syn_backlog 65535 || fail=$((fail+1))
        if [ "$conntrack_max" != "unavailable" ]; then
            write_sysctl net.netfilter.nf_conntrack_max 262144 || fail=$((fail+1))
        fi
        if command -v ethtool >/dev/null 2>&1; then
            ethtool -K "$iface" gro on gso on tso on sg on >/dev/null 2>&1 || fail=$((fail+1))
        else
            optimize_note="未找到 ethtool，跳过网卡 offload"
        fi
        if [ "$tune_status" = "已应用（当前运行时）" ]; then ok=1; else fail=$((fail+1)); fi
        if [ "$fail" -eq 0 ] && [ "$ok" -eq 1 ]; then
            optimize_status="已完成"
        else
            optimize_status="部分完成：$fail 项被拒绝或失败"
        fi
    fi
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
if [ "$JSON" -eq 1 ]; then
    printf '{\n'
    printf '  "is_root": %s,\n' "$([ "$ROOT" -eq 1 ] && echo true || echo false)"
    printf '  "interface": "%s",\n' "$(json_escape "$iface")"
    printf '  "bbr_available": %s,\n' "$([ "$auto_bbr" = 是 ] && echo true || echo false)"
    printf '  "bbr_active": %s,\n' "$([ "$bbr_active" = 是 ] && echo true || echo false)"
    printf '  "tcp_congestion_control": "%s",\n' "$(json_escape "$active")"
    printf '  "default_qdisc": "%s",\n' "$(json_escape "$default_qdisc")"
    printf '  "tcp_rmem": "%s",\n' "$(json_escape "$tcp_rmem")"
    printf '  "tcp_wmem": "%s",\n' "$(json_escape "$tcp_wmem")"
    printf '  "rmem_max": "%s",\n' "$(json_escape "$rmem_max")"
    printf '  "wmem_max": "%s",\n' "$(json_escape "$wmem_max")"
    printf '  "mtu": "%s",\n' "$(json_escape "$mtu")"
    printf '  "tcp_fastopen": "%s",\n' "$(json_escape "$fastopen")"
    printf '  "conntrack_count": "%s",\n' "$(json_escape "$conntrack_count")"
    printf '  "conntrack_max": "%s",\n' "$(json_escape "$conntrack_max")"
    printf '  "tune_status": "%s",\n' "$(json_escape "$tune_status")"
    printf '  "optimize_status": "%s"\n' "$(json_escape "$optimize_status")"
    printf '}\n'
    exit 0
fi

printf '%s\n' '========================================'
printf '%s\n' ' LXC 网络检测与优化结果'
printf '%s\n' '========================================'
printf '检测位置                 : 容器当前网络命名空间\n'
printf '当前用户是 root         : %s\n' "$([ "$ROOT" -eq 1 ] && echo 是 || echo 否)"
printf '默认网卡                 : %s\n' "$iface"
printf '\n[BBR / 队列]\n'
printf '可用拥塞控制算法         : %s\n' "$available"
printf '系统是否提供 BBR         : %s\n' "$auto_bbr"
printf '当前 TCP 拥塞控制        : %s\n' "$active"
printf '当前是否使用 BBR         : %s\n' "$bbr_active"
printf '默认队列算法             : %s\n' "$default_qdisc"
printf '\n[TCP 缓冲区]\n'
printf 'tcp_rmem                 : %s\n' "$tcp_rmem"
printf 'tcp_wmem                 : %s\n' "$tcp_wmem"
printf 'net.core.rmem_max        : %s\n' "$rmem_max"
printf 'net.core.wmem_max         : %s\n' "$wmem_max"
printf 'net.core.optmem_max       : %s\n' "$optmem_max"
printf '\n[队列 / 连接 / Fast Open]\n'
printf 'net.core.netdev_max_backlog: %s\n' "$backlog"
printf 'net.core.somaxconn          : %s\n' "$somaxconn"
printf 'tcp_max_syn_backlog         : %s\n' "$syn_backlog"
printf 'net.ipv4.tcp_fastopen       : %s\n' "$fastopen"
printf 'conntrack count/max          : %s / %s\n' "$conntrack_count" "$conntrack_max"
printf '\n[链路 / 资源]\n'
printf '接口 MTU                  : %s\n' "$mtu"
printf '文件描述符上限            : %s\n' "$fd_limit"
printf '接口统计摘要              : %s\n' "${link_stats:-unavailable}"
printf '\n[建议]\n'
[ "$auto_bbr" = 是 ] || printf '%s\n' 'BBR：容器不可见，需要宿主机内核支持并加载 tcp_bbr。'
[ "$bbr_active" = 是 ] || printf '%s\n' '当前未使用 BBR；可用 --optimize 尝试切换。'
[ "$mtu" != "1500" ] && [ "$mtu" != "unavailable" ] && printf '%s\n' 'MTU：当前不是 1500，请结合隧道/上游链路做 ping -M do 测试，不建议脚本自动修改。'
printf '%s\n' '丢包/重传：可用 ip -s link、ss -s、nstat -az 进一步确认。'
printf '%s\n' '宿主机限速：请检查 Proxmox rate、LXD limits.ingress/egress 或 tc 配置。'

if [ "$TRY_ENABLE" -eq 1 ] && [ "$OPTIMIZE" -eq 0 ]; then
    printf '\n[临时写入测试（目标最大值 32 MiB）]\n'
    printf 'tcp_rmem                 : %s\n' "$write_rmem"
    printf 'tcp_wmem                 : %s\n' "$write_wmem"
    printf 'net.core.rmem_max        : %s\n' "$write_rmem_max"
    printf 'net.core.wmem_max        : %s\n' "$write_wmem_max"
    printf 'tcp_congestion_control=bbr: %s\n' "$write_bbr"
    printf 'net.core.default_qdisc   : %s\n' "$write_qdisc"
    printf '%s\n' '注意：写入测试会改变当前运行时参数，但不会创建持久化配置文件。'
fi
if [ "$TUNE" -eq 1 ]; then
    printf '\n[按带宽调整结果]\n'
    printf '状态                     : %s\n' "$tune_status"
    printf '输入带宽 (Mbps)          : %s\n' "${tune_bandwidth_mbps:-未输入}"
    printf '输入 RTT (ms)             : %s\n' "${tune_rtt_ms:-未输入}"
    printf '目标最大缓冲区 (bytes)   : %s\n' "${tune_buffer_bytes:-未计算}"
    printf '目标 tcp_rmem             : %s\n' "${tune_rmem:-未计算}"
    printf '目标 tcp_wmem             : %s\n' "${tune_wmem:-未计算}"
    printf '%s\n' '规则：4 倍带宽时延积，限制在 4 MiB 至 64 MiB；只修改当前运行时。'
fi
if [ "$OPTIMIZE" -eq 1 ]; then
    printf '\n[一键优化结果]\n'
    printf '状态                     : %s\n' "$optimize_status"
    [ -n "$optimize_note" ] && printf '备注                     : %s\n' "$optimize_note"
    printf '%s\n' '尝试项目：BBR/fq、TCP 缓冲区、TCP Fast Open、连接队列、conntrack、GRO/GSO/TSO/SG。'
fi

printf '\n[常用命令]\n'
printf '只读检测                 : bash %s\n' "$SCRIPT_NAME"
printf '测试写权限               : sudo bash %s --try-enable\n' "$SCRIPT_NAME"
printf '按带宽调整缓存区         : sudo bash %s --tune\n' "$SCRIPT_NAME"
printf '一键运行时优化           : sudo bash %s --optimize\n' "$SCRIPT_NAME"
printf 'JSON 输出                 : sudo bash %s --json\n' "$SCRIPT_NAME"
printf '\n注意：所有脚本修改都是运行时修改，重启后可能恢复；宿主机参数必须在宿主机调整。\n'
