#!/bin/bash

# 设置错误处理
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 全局变量
CONFIGURED_IPV6_CIDR=""

# 日志函数
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] 错误: $1${NC}" >&2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >> install_error.log
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] 警告: $1${NC}"
}

# 错误处理函数
handle_error() {
    error "$1"
    cleanup
    exit 1
}

# 清理函数
cleanup() {
    log "执行清理操作..."
    if [ -f "go1.18.linux-amd64.tar.gz" ]; then
        rm -f go1.18.linux-amd64.tar.gz
    fi
    if [ -d "temp" ]; then
        rm -rf temp
    fi
}

# 设置trap
trap cleanup EXIT
trap 'handle_error "安装过程被中断"' INT TERM

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        handle_error "请以root权限运行此脚本"
    fi
}

# 检查并安装基础工具
install_basic_tools() {
    log "正在检查系统更新..."
    if ! apt update; then
        warn "无法更新软件包列表，继续执行..."
    else
        log "正在更新系统..."
        apt upgrade -y || warn "系统更新失败，继续执行..."
    fi

    log "正在检查并安装必要工具..."
    TOOLS="git build-essential curl wget ufw iproute2 net-tools"
    for tool in $TOOLS; do
        if ! command -v $tool &> /dev/null; then
            log "正在安装 $tool..."
            apt install -y $tool || handle_error "安装 $tool 失败"
        else
            log "$tool 已安装，跳过..."
        fi
    done
}

# 验证 IPv4 地址
validate_ipv4() {
    if [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$1"
        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 验证 IPv6 地址
validate_ipv6() {
    if [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Go版本检查和安装
check_go_version() {
    if command -v go &> /dev/null; then
        current_version=$(go version | awk '{print $3}' | sed 's/go//')
        required_version="1.18"
        if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" = "$required_version" ]; then
            log "检测到Go版本 $current_version，符合要求..."
            return 0
        fi
    fi
    return 1
}

install_go() {
    log "正在安装Go 1.18..."
    if [ -f "go1.18.linux-amd64.tar.gz" ]; then
        rm -f go1.18.linux-amd64.tar.gz
    fi
    wget https://go.dev/dl/go1.18.linux-amd64.tar.gz || handle_error "下载Go失败"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf go1.18.linux-amd64.tar.gz || handle_error "解压Go失败"
    rm -f go1.18.linux-amd64.tar.gz

    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
        echo 'export GO111MODULE=on' >> /etc/profile
    fi
    source /etc/profile
    log "Go安装完成，版本信息："
    go version
}

# 配置HE IPv6隧道
configure_he_tunnel() {
    local tunnel_name=$1
    local he_ipv4
    local local_ipv4
    local he_ipv6
    local local_ipv6
    local routed_prefix
    local prefix_choice
    local ping_ipv6
    local prefix_length
    
    log "配置 $tunnel_name"
    
    # 检查隧道是否存在
    if ip link show $tunnel_name &> /dev/null; then
        read -p "隧道 $tunnel_name 已存在。是否删除并重新配置？(y/n): " answer
        if [ "$answer" == "y" ]; then
            ip link set $tunnel_name down 2>/dev/null || true
            ip tunnel del $tunnel_name 2>/dev/null || true
            sed -i "/# HE IPv6 Tunnel.*$tunnel_name/,/# End IPv6 Tunnel/d" /etc/network/interfaces
        else
            log "取消配置 $tunnel_name"
            return 1
        fi
    fi

    # 获取隧道配置信息
    while true; do
        read -p "请输入 HE服务器 IPv4 地址: " he_ipv4
        validate_ipv4 $he_ipv4 && break
        warn "无效的 IPv4 地址，请重新输入"
    done

    while true; do
        read -p "请输入本机 IPv4 地址: " local_ipv4
        validate_ipv4 $local_ipv4 && break
        warn "无效的 IPv4 地址，请重新输入"
    done

    while true; do
        read -p "请输入 HE服务器 IPv6 地址（包括前缀长度，例如 2001:470:1f04:17b::1/64）: " he_ipv6
        if [[ $he_ipv6 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}::1/[0-9]+$ ]]; then
            break
        fi
        warn "无效的 IPv6 地址，必须以::1结尾并包含前缀长度，请重新输入"
    done

    local_ipv6="${he_ipv6%::1}::2/${he_ipv6#*/}"
    log "本机 IPv6 地址已自动设置为: $local_ipv6"

    while true; do
        read -p "请选择 HE 分配给您的前缀类型 (1 - /64, 2 - /48): " prefix_choice
        if [[ "$prefix_choice" == "1" || "$prefix_choice" == "2" ]]; then
            break
        fi
        warn "请输入 1 或 2"
    done

    while true; do
        if [ "$prefix_choice" == "1" ]; then
            read -p "请输入 HE 分配的 /64 前缀 (例如: 2001:470:1f05:17b::/64): " routed_prefix
            prefix_length="64"
        else
            read -p "请输入 HE 分配的 /48 前缀 (例如: 2001:470:8099::/48): " routed_prefix
            prefix_length="48"
        fi
        if [[ $routed_prefix =~ ^([0-9a-fA-F]{0,4}:){1,7}: ]]; then
            break
        fi
        warn "无效的 IPv6 前缀，请重新输入"
    done

    # 设置全局变量供后续使用
    CONFIGURED_IPV6_CIDR="$routed_prefix/$prefix_length"

    # 保存配置
    mkdir -p /etc/he-ipv6
    cat > "/etc/he-ipv6/${tunnel_name}.conf" << EOF
HE_SERVER_IPV4=$he_ipv4
HE_SERVER_IPV6=${he_ipv6%/*}
LOCAL_IPV4=$local_ipv4
LOCAL_IPV6=${local_ipv6%/*}
ROUTED_PREFIX=$routed_prefix
PREFIX_LENGTH=$prefix_length
EOF

    # 配置隧道
    ip tunnel add $tunnel_name mode sit remote $he_ipv4 local $local_ipv4 ttl 255
    ip link set $tunnel_name up
    ip addr add $local_ipv6 dev $tunnel_name
    ip -6 route add $CONFIGURED_IPV6_CIDR dev $tunnel_name
    ip -6 route add ::/0 via ${he_ipv6%/*} dev $tunnel_name metric 1
    ip link set $tunnel_name mtu 1480

    # 添加到网络接口配置
    cat << EOF >> /etc/network/interfaces

# HE IPv6 Tunnel $tunnel_name
auto $tunnel_name
iface $tunnel_name inet6 v4tunnel
    address ${local_ipv6%/*}
    netmask 64
    endpoint $he_ipv4
    local $local_ipv4
    ttl 255
    gateway ${he_ipv6%/*}
    mtu 1480
    up ip -6 route add $CONFIGURED_IPV6_CIDR dev \$IFACE
    up ip -6 route add ::/0 via ${he_ipv6%/*} dev \$IFACE metric 1
# End IPv6 Tunnel
EOF

    log "隧道配置完成"
    
    # 测试连接
    log "正在测试连接..."
    sleep 2
    log "测试 Google IPv6 连通性..."
    ping6 -c 4 ipv6.google.com || true

    return 0
}

# 创建系统服务
create_service() {
    log "创建系统服务..."
    
    # 使用配置的IPv6 CIDR
    local ipv6_cidr=${CONFIGURED_IPV6_CIDR:-"YOUR_IPV6_CIDR"}
    
    cat > /etc/systemd/system/ipv6proxy.service << EOF
[Unit]
Description=IPv6 Proxy Service
After=network.target

[Service]
ExecStart=/usr/local/go/bin/go run /root/v6/cmd/ipv6proxy/main.go -cidr "$ipv6_cidr" -port 33300
Restart=always
User=root
WorkingDirectory=/root/v6
Environment=PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 配置系统环境
configure_system() {
    log "配置系统环境..."
    
    # 系统参数
    SYSCTL_PARAMS=(
        "net.ipv6.conf.all.forwarding=1"
        "net.ipv6.conf.default.forwarding=1"
        "net.ipv4.ip_forward=0"
        "net.ipv6.ip_nonlocal_bind=1"
        "net.ipv6.conf.all.accept_ra=2"
        "net.ipv6.conf.default.accept_ra=2"
        "net.core.somaxconn=1024"
        "net.ipv6.conf.all.disable_ipv6=0"
        "net.ipv6.conf.default.disable_ipv6=0"
        "net.ipv6.conf.lo.disable_ipv6=0"
    )
    
    # 备份并更新sysctl配置
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    for param in "${SYSCTL_PARAMS[@]}"; do
        if ! grep -q "^${param}$" /etc/sysctl.conf; then
            echo "$param" >> /etc/sysctl.conf
        fi
    done
    sysctl -p || warn "部分系统参数可能未成功应用"
}

# 配置防火墙
configure_firewall() {
    log "配置防火墙..."
    
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 33300/tcp comment 'IPv6 Proxy'
    
    ufw --force enable
}

# 主函数
main() {
    log "开始安装 IPv6 Proxy..."
    
    # 检查root权限
    check_root
    
    # 安装基础工具
    install_basic_tools
    
    # 配置HE IPv6隧道
    read -p "是否需要配置HE IPv6隧道？(y/n): " configure_tunnel
    if [[ $configure_tunnel =~ ^[Yy]$ ]]; then
        configure_he_tunnel "he-ipv6-1" || handle_error "配置隧道失败"
    fi
    
    # 安装Go（如果需要）
    if ! check_go_version; then
        install_go
    fi
    
    # 克隆项目
    log "检查项目代码..."
    if [ -d "v6" ]; then
        cd v6
        git pull
    else
        git clone https://github.com/qza666/v6.git
        cd v6
    fi
    
    # 系统配置
    configure_system
    configure_firewall
    create_service
    
    # 显示完成信息和使用说明
    log "安装完成！使用说明："
    if [ -n "$CONFIGURED_IPV6_CIDR" ]; then
        log "已配置的IPv6 CIDR: $CONFIGURED_IPV6_CIDR"
    fi
    
    cat << EOF

使用说明:
1. 系统服务已配置在: /etc/systemd/system/ipv6proxy.service
2. IPv6 CIDR 已自动配置为: ${CONFIGURED_IPV6_CIDR:-"需要手动配置"}
3. 执行以下命令启动服务：
   systemctl daemon-reload
   systemctl start ipv6proxy
   systemctl enable ipv6proxy

可用参数:
-cidr: IPv6 CIDR范围（必需）
-port: 服务端口（默认：33300）
-bind: 绑定地址（默认：0.0.0.0）
-username: 认证用户名
-password: 认证密码
-use-doh: 使用DNS over HTTPS（默认：true）
-verbose: 启用详细日志
-auto-route: 自动添加路由（默认：true）
-auto-forwarding: 自动启用IPv6转发（默认：true）
-auto-ip-nonlocal-bind: 自动启用非本地绑定（默认：true）

如需修改配置，请编辑 /etc/systemd/system/ipv6proxy.service 文件

隧道配置信息:
- 配置文件位置: /etc/he-ipv6/he-ipv6-1.conf
- 网络接口配置: /etc/network/interfaces
EOF

    # 询问是否重启
    read -p "是否现在重启系统来应用所有更改？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "系统将在5秒后重启..."
        sleep 5
        reboot
    else
        warn "请记得稍后手动重启系统以确保所有更改生效。"
    fi
}

# 执行主函数
main
