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
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >> setup_error.log
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
    # 添加清理逻辑
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

# HE IPv6 隧道配置函数
configure_he_tunnel() {
    log "开始配置 HE IPv6 隧道..."

    # 验证 IPv4 地址函数
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

    # 验证 IPv6 地址函数
    validate_ipv6() {
        if [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
            return 0
        else
            return 1
        fi
    }

    # 生成本机IPv6地址函数
    generate_local_ipv6() {
        local he_ipv6=$1
        echo "${he_ipv6%::1}::2"
    }

    # 检查隧道是否存在函数
    check_tunnel_exists() {
        local tunnel_name=$1
        if ip link show $tunnel_name &> /dev/null; then
            return 0
        else
            return 1
        fi
    }

    # 删除现有隧道函数
    remove_tunnel() {
        local tunnel_name=$1
        
        ip link set $tunnel_name down 2>/dev/null || true
        ip tunnel del $tunnel_name 2>/dev/null || true
        
        sed -i "/# HE IPv6 Tunnel.*$tunnel_name/,/# End IPv6 Tunnel/d" /etc/network/interfaces
        
        echo "隧道 $tunnel_name 已删除"
    }

    # 配置单个隧道函数
    configure_single_tunnel() {
        local tunnel_name=$1
        local he_ipv4
        local local_ipv4
        local he_ipv6
        local local_ipv6
        local routed_prefix
        local prefix_choice
        local ping_ipv6
        local prefix_length
        
        echo "配置 $tunnel_name"
        
        if check_tunnel_exists $tunnel_name; then
            read -p "隧道 $tunnel_name 已存在。是否删除并重新配置？(y/n): " answer
            if [ "$answer" == "y" ]; then
                remove_tunnel $tunnel_name
            else
                echo "取消配置 $tunnel_name"
                return 1
            fi
        fi
        
        while true; do
            read -p "请输入 HE服务器 IPv4 地址: " he_ipv4
            validate_ipv4 $he_ipv4 && break
            echo "无效的 IPv4 地址，请重新输入。"
        done

        while true; do
            read -p "请输入本机 IPv4 地址: " local_ipv4
            validate_ipv4 $local_ipv4 && break
            echo "无效的 IPv4 地址，请重新输入。"
        done

        while true; do
            read -p "请输入 HE服务器 IPv6 地址（包括前缀长度，例如 2001:470:1f04:17b::1/64）: " he_ipv6
            if [[ $he_ipv6 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}::1/[0-9]+$ ]]; then
                break
            fi
            echo "无效的 IPv6 地址，必须以::1结尾并包含前缀长度，请重新输入。"
        done

        local_ipv6=$(generate_local_ipv6 "${he_ipv6%/*}")
        local_ipv6="${local_ipv6}/${he_ipv6#*/}"
        echo "本机 IPv6 地址已自动设置为: $local_ipv6"

        while true; do
            read -p "请选择 HE 分配给您的前缀类型 (1 - /64, 2 - /48): " prefix_choice
            if [[ "$prefix_choice" == "1" || "$prefix_choice" == "2" ]]; then
                break
            fi
            echo "请输入 1 或 2"
        done

        prefix_length=""
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
            echo "无效的 IPv6 前缀，请重新输入。"
        done

        routed_prefix=${routed_prefix%/*}

        default_ping_ipv6="${routed_prefix%:*}:1"
        read -p "请输入用于外部ping测试的IPv6地址 [$default_ping_ipv6]: " ping_ipv6
        ping_ipv6=${ping_ipv6:-$default_ping_ipv6}

        echo "正在配置 $tunnel_name..."
        
        local config_file="/etc/he-ipv6/${tunnel_name}.conf"
        mkdir -p /etc/he-ipv6
        cat << EOF > $config_file
HE_SERVER_IPV4=$he_ipv4
HE_SERVER_IPV6=${he_ipv6%/*}
LOCAL_IPV4=$local_ipv4
LOCAL_IPV6=${local_ipv6%/*}
ROUTED_PREFIX=$routed_prefix
PREFIX_LENGTH=$prefix_length
PING_IPV6=$ping_ipv6
EOF

        ip tunnel add $tunnel_name mode sit remote $he_ipv4 local $local_ipv4 ttl 255
        ip link set $tunnel_name up
        ip addr add ${local_ipv6} dev $tunnel_name
        ip addr add ${ping_ipv6}/${prefix_length} dev $tunnel_name
        ip -6 route add ${routed_prefix}/${prefix_length} dev $tunnel_name
        ip -6 route add ::/0 via ${he_ipv6%/*} dev $tunnel_name metric $tunnel_number
        ip link set $tunnel_name mtu 1480

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
    up ip -6 addr add ${ping_ipv6}/${prefix_length} dev \$IFACE
    up ip -6 route add ${routed_prefix}/${prefix_length} dev \$IFACE
    up ip -6 route add ::/0 via ${he_ipv6%/*} dev \$IFACE metric 1
# End IPv6 Tunnel
EOF

        echo "隧道配置完成。"
    }

    # 主隧道配置逻辑
    echo "欢迎使用 HE IPv6 隧道配置脚本"

    while true; do
        read -p "请输入隧道编号 (1-9): " tunnel_number
        if [[ "$tunnel_number" =~ ^[1-9]$ ]]; then
            break
        fi
        echo "请输入 1-9 之间的数字"
    done

    tunnel_name="he-ipv6-$tunnel_number"

    configure_single_tunnel $tunnel_name

    echo "正在测试连接..."
    sleep 2

    echo "测试 Google IPv6 连通性..."
    ping6 -c 4 ipv6.google.com || true

    echo "测试本地IPv6地址..."
    ping6 -c 4 "${ping_ipv6}" || true

    echo "IPv6 隧道配置完成。"
    echo "隧道接口名称: $tunnel_name"
    cat "/etc/he-ipv6/${tunnel_name}.conf"
    echo "配置信息已保存到: /etc/he-ipv6/${tunnel_name}.conf"
    echo "如果遇到问题，请检查系统日志或联系 HE 支持。"
}

# IPv6 代理安装函数
install_ipv6_proxy() {
    log "开始安装 IPv6 代理..."

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

    # 项目结构修复
    fix_project_structure() {
        log "修复项目结构..."
        
        # 创建必要的目录
        mkdir -p internal/{config,dns,proxy,sysutils}
        mkdir -p cmd/ipv6proxy
        
        # 移动源文件
        if [ -f "main.go" ]; then
            mv main.go cmd/ipv6proxy/
        fi
        
        # 移动其他Go文件到internal目录
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
        
        # 创建新的main.go如果不存在
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
        
        # 设置Go环境变量
        export GO111MODULE=on
        export GOPROXY=https://goproxy.cn,direct
        export GOPRIVATE=github.com/qza666
        
        # 清理之前的缓存
        go clean -modcache
        
        # 重新初始化go.mod
        rm -f go.mod go.sum
        go mod init github.com/qza666/v6
        
        # 添加必要的依赖
        go get github.com/miekg/dns@latest
        go get github.com/elazarl/goproxy@latest
        
        # 整理依赖
        if ! go mod tidy; then
            handle_error "依赖安装失败，请检查代码结构和权限"
        fi
        
        # 验证依赖
        if ! go mod verify; then
            handle_error "依赖验证失败"
        fi
        
        log "依赖安装完成"
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
            "net.ipv6.tcp_max_syn_backlog=1024"
        )
        
        # 备份并更新sysctl配置
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
    
        cat > /etc/systemd/system/ipv6proxy.service << EOF
[Unit]
Description=IPv6 Proxy Service
After=network.target

[Service]
ExecStart=/usr/local/go/bin/go run /root/v6/cmd/ipv6proxy/main.go -cidr "YOUR_IPV6_CIDR" -port 33300
Restart=always
User=root
WorkingDirectory=/root/v6
Environment=PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
    }

    # 安装Go
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
    
    # 修复项目结构和源码
    fix_project_structure
    fix_source_code
    
    # 安装依赖
    install_project_dependencies
    
    # 系统配置
    configure_system
    configure_firewall
    create_service
    
    # 显示完成信息
    log "安装完成！使用说明："
    cat << EOF

使用说明:
1. 编辑服务配置: nano /etc/systemd/system/ipv6proxy.service
2. 替换 YOUR_IPV6_CIDR 为实际的IPv6 CIDR
3. 执行以下命令：
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

EOF
}

one_click_setup() {
    log "一键配置 HE IPv6 隧道和 IPv6 代理..."
    configure_he_tunnel
    install_ipv6_proxy
    log "一键配置完成！"
}

# 主菜单函数
main_menu() {
    while true; do
        echo "请选择要执行的操作："
        echo "1. 配置 HE IPv6 隧道"
        echo "2. 安装 IPv6 代理"
        echo "3. 一键配置隧道与代理"
        echo "4. 退出"
        read -p "请输入选项 (1-4): " choice

        case $choice in
            1)
                configure_he_tunnel
                ;;
            2)
                install_ipv6_proxy
                ;;
            3)
                one_click_setup
                ;;
            4)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac
    done
}

# 主函数
main() {
    log "欢迎使用 IPv6 隧道和代理配置脚本"
    check_root
    install_basic_tools
    main_menu
}

# 执行主函数
main

