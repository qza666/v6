#!/bin/bash

# 设置错误处理
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# HE IPv6 隧道配置函数
configure_he_tunnel() {
    log "开始配置HE IPv6隧道..."

    # 验证IPv4地址函数
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

    # 验证IPv6地址函数
    validate_ipv6() {
        if [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
            return 0
        else
            return 1
        fi
    }

    # 生成本机IPv6地址
    generate_local_ipv6() {
        local he_ipv6=$1
        echo "${he_ipv6%::1}::2"
    }

    # 获取用户输入
    while true; do
        read -p "请输入HE服务器IPv4地址: " he_ipv4
        validate_ipv4 $he_ipv4 && break
        error "无效的IPv4地址，请重新输入。"
    done

    while true; do
        read -p "请输入本机IPv4地址: " local_ipv4
        validate_ipv4 $local_ipv4 && break
        error "无效的IPv4地址，请重新输入。"
    done

    while true; do
        read -p "请输入HE服务器IPv6地址（包括前缀长度，例如 2001:470:1f04:17b::1/64）: " he_ipv6
        if [[ $he_ipv6 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}::1/[0-9]+$ ]]; then
            break
        fi
        error "无效的IPv6地址，必须以::1结尾并包含前缀长度，请重新输入。"
    done

    local_ipv6=$(generate_local_ipv6 "${he_ipv6%/*}")
    local_ipv6="${local_ipv6}/${he_ipv6#*/}"
    log "本机IPv6地址已自动设置为: $local_ipv6"

    while true; do
        read -p "请选择HE分配给您的前缀类型 (1 - /64, 2 - /48): " prefix_choice
        if [[ "$prefix_choice" == "1" || "$prefix_choice" == "2" ]]; then
            break
        fi
        error "请输入1或2"
    done

    if [ "$prefix_choice" == "1" ]; then
        read -p "请输入HE分配的/64前缀 (例如: 2001:470:1f05:17b::/64): " routed_prefix
        prefix_length="64"
    else
        read -p "请输入HE分配的/48前缀 (例如: 2001:470:8099::/48): " routed_prefix
        prefix_length="48"
    fi

    routed_prefix=${routed_prefix%/*}

    # 配置隧道
    log "正在配置HE IPv6隧道..."
    ip tunnel add he-ipv6 mode sit remote $he_ipv4 local $local_ipv4 ttl 255
    ip link set he-ipv6 up
    ip addr add ${local_ipv6} dev he-ipv6
    ip -6 route add ${routed_prefix}/${prefix_length} dev he-ipv6
    ip -6 route add ::/0 via ${he_ipv6%/*} dev he-ipv6
    ip link set he-ipv6 mtu 1480

    # 保存配置到文件
    mkdir -p /etc/he-ipv6
    cat << EOF > /etc/he-ipv6/tunnel.conf
HE_SERVER_IPV4=$he_ipv4
HE_SERVER_IPV6=${he_ipv6%/*}
LOCAL_IPV4=$local_ipv4
LOCAL_IPV6=${local_ipv6%/*}
ROUTED_PREFIX=$routed_prefix
PREFIX_LENGTH=$prefix_length
EOF

    log "HE IPv6隧道配置完成。"
}

# 项目结构修复
fix_project_structure() {
    log "修复项目结构..."
    
    mkdir -p internal/{config,dns,proxy,sysutils}
    mkdir -p cmd/ipv6proxy
    
    if [ -f "main.go" ]; then
        mv main.go cmd/ipv6proxy/
    fi
    
    for file in $(find . -maxdepth 1 -name "*.go" ! -name "main.go"); do
        dir_name=$(basename "$file" .go)
        if [ -d "internal/$dir_name" ]; then
            mv "$file" "internal/$dir_name/"
        else
            mv "$file" "internal/"
        fi
    done
    
    log "项目结构修复完成"
}

# 修复源码导入路径
fix_source_code() {
    log "修复源码导入路径..."
    
    find . -type f -name "*.go" -exec sed -i 's|"github.com/your-project/|"github.com/qza666/v6/internal/|g' {} +
    
    if [ ! -f "cmd/ipv6proxy/main.go" ]; then
        cat > cmd/ipv6proxy/main.go << 'EOF'
package main

import (
    "flag"
    "log"
    
    "github.com/qza666/v6/internal/config"
    "github.com/qza666/v6/internal/proxy"
)

func main() {
    cfg := config.ParseFlags()
    if err := proxy.Start(cfg); err != nil {
        log.Fatal(err)
    }
}
EOF
    fi
    
    log "源码修复完成"
}

# 安装项目依赖
install_project_dependencies() {
    log "安装项目依赖..."
    
    export GO111MODULE=on
    export GOPROXY=https://goproxy.cn,direct
    export GOPRIVATE=github.com/qza666
    
    go clean -modcache
    
    rm -f go.mod go.sum
    go mod init github.com/qza666/v6
    
    go get github.com/miekg/dns@latest
    go get github.com/elazarl/goproxy@latest
    
    if ! go mod tidy; then
        handle_error "依赖安装失败，请检查代码结构和权限"
    fi
    
    if ! go mod verify; then
        handle_error "依赖验证失败"
    fi
    
    log "依赖安装完成"
}

# 配置系统环境
configure_system() {
    log "配置系统环境..."
    
    SYSCTL_PARAMS=(
        "net.ipv6.conf.all.forwarding=1"
        "net.ipv6.conf.default.forwarding=1"
        "net.ipv4.ip_forward=0"
        "net.ipv6.ip_nonlocal_bind=1"
        "net.ipv6.conf.all.accept_ra=2"
        "net.ipv6.conf.default.accept_ra=2"
        "net.core.somaxconn=1024"
        "net.ipv6.tcp_max_syn_backlog=1024"
    )
    
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    for param in "${SYSCTL_PARAMS[@]}"; do
        if ! grep -q "^${param}$" /etc/sysctl.conf; then
            echo "$param" >> /etc/sysctl.conf
        fi
    done
    sysctl -p
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

# 创建系统服务
create_service() {
    log "创建系统服务..."
    
    # 提示用户输入IPv6 CIDR
    read -p "请输入您的IPv6 CIDR（例如：2001:db8::/48）: " ipv6_cidr
    
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

# 主函数
main() {
    log "开始安装IPv6 Proxy..."
    
    check_root
    install_basic_tools
    
    if ! check_go_version; then
        install_go
    fi
    
    configure_he_tunnel
    
    log "检查项目代码..."
    
    if [ -d "v6" ]; then
        cd v6
        git pull
    else
        git clone https://github.com/qza666/v6.git
        cd v6
    fi
    
    fix_project_structure
    fix_source_code
    
    install_project_dependencies
    
    configure_system
    configure_firewall
    create_service
    
    log "安装完成！使用说明："
    cat << EOF

使用说明:
1. IPv6 Proxy服务已配置为系统服务。
2. 您可以使用以下命令来管理服务：
   - 启动服务：systemctl start ipv6proxy
   - 停止服务：systemctl stop ipv6proxy
   - 重启服务：systemctl restart ipv6proxy
   - 查看服务状态：systemctl status ipv6proxy
3. 服务配置文件位于：/etc/systemd/system/ipv6proxy.service
4. 如需修改配置，请编辑该文件并重新加载systemd：
   systemctl daemon-reload

可用参数:
-cidr: IPv6 CIDR范围（已在服务配置中设置）
-port: 服务端口（默认：33300）
-bind: 绑定地址（默认：0.0.0.0）
-username: 认证用户名
-password: 认证密码
-use-doh: 使用DNS over HTTPS（默认：true）
-verbose: 启用详细日志
-auto-route: 自动添加路由（默认：true）
-auto-forwarding: 自动启用IPv6转发（默认：true）
-auto-ip-nonlocal-bind: 自动启用非本地绑定（默认：true）

EOF

    log "是否要现在启动IPv6 Proxy服务？(y/n)"
    read start_service
    if [[ $start_service =~ ^[Yy]$ ]]; then
        systemctl start ipv6proxy
        systemctl enable ipv6proxy
        log "IPv6 Proxy服务已启动并设置为开机自启"
    else
        log "您可以稍后使用 'systemctl start ipv6proxy' 命令启动服务"
    fi

    log "安装和配置已完成。如有问题，请查看系统日志或联系支持。"
}

# 执行主函数
main
