#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup.log"
ERROR_LOG_FILE="${SCRIPT_DIR}/setup_error.log"
CLEANUP_NEEDED=false

# 日志函数
log() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[$timestamp] $1${NC}"
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

error() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[$timestamp] 错误: $1${NC}" >&2
    echo "[$timestamp] ERROR: $1" >> "$ERROR_LOG_FILE"
}

warn() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[$timestamp] 警告: $1${NC}"
    echo "[$timestamp] WARNING: $1" >> "$LOG_FILE"
}

# 清理函数
cleanup() {
    if [ "$CLEANUP_NEEDED" = true ]; then
        log "执行清理操作..."
        # 停止所有正在运行的服务
        systemctl stop ipv6proxy &>/dev/null || true
        
        # 清理临时文件
        rm -f /tmp/ipv6proxy_* &>/dev/null || true
        
        # 恢复系统配置
        if [ -f /etc/sysctl.conf.bak ]; then
            mv /etc/sysctl.conf.bak /etc/sysctl.conf
            sysctl -p &>/dev/null || true
        fi
        
        log "清理完成"
    fi
}

# 错误处理函数
handle_error() {
    error "$1"
    CLEANUP_NEEDED=true
    exit 1
}

# 初始化函数
initialize() {
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$ERROR_LOG_FILE")"
    touch "$LOG_FILE" "$ERROR_LOG_FILE"
    
    # 设置trap
    trap cleanup EXIT
    trap 'error "收到中断信号"; CLEANUP_NEEDED=true; exit 1' INT TERM
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        handle_error "请以root权限运行此脚本"
    fi
}

# 检查并安装基础工具
install_basic_tools() {
    log "正在检查系统更新..."
    if ! apt-get update &>/dev/null; then
        warn "无法更新软件包列表，继续执行..."
    fi

    log "正在检查并安装必要工具..."
    TOOLS="git build-essential curl wget ufw iproute2 net-tools"
    for tool in $TOOLS; do
        if ! command -v $tool &>/dev/null; then
            log "正在安装 $tool..."
            if ! apt-get install -y $tool; then
                warn "安装 $tool 失败，继续执行..."
            fi
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
        
        while true; do
            read -p "请输入 HE服务器 IPv4 地址: " he_ipv4
            validate_ipv4 "$he_ipv4" && break
            echo "无效的 IPv4 地址，请重新输入。"
        done

        while true; do
            read -p "请输入本机 IPv4 地址: " local_ipv4
            validate_ipv4 "$local_ipv4" && break
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

        # 配置隧道
        echo "正在配置 $tunnel_name..."
        
        # 创建配置目录
        mkdir -p /etc/he-ipv6
        
        # 保存配置到文件
        local config_file="/etc/he-ipv6/${tunnel_name}.conf"
        cat << EOF > "$config_file"
HE_SERVER_IPV4=$he_ipv4
LOCAL_IPV4=$local_ipv4
HE_SERVER_IPV6=${he_ipv6%/*}
LOCAL_IPV6=${local_ipv6%/*}
ROUTED_PREFIX=$routed_prefix
PREFIX_LENGTH=$prefix_length
EOF

        # 配置网络接口
        ip tunnel add "$tunnel_name" mode sit remote "$he_ipv4" local "$local_ipv4" ttl 255 || return 1
        ip link set "$tunnel_name" up || return 1
        ip addr add "$local_ipv6" dev "$tunnel_name" || return 1
        ip -6 route add "$routed_prefix/$prefix_length" dev "$tunnel_name" || return 1
        ip -6 route add ::/0 via "${he_ipv6%/*}" dev "$tunnel_name" || return 1

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
    up ip -6 route add $routed_prefix/$prefix_length dev \$IFACE
    up ip -6 route add ::/0 via ${he_ipv6%/*} dev \$IFACE
# End IPv6 Tunnel
EOF

        log "隧道 $tunnel_name 配置完成"
        return 0
    }

    # 主隧道配置逻辑
    local tunnel_number
    while true; do
        read -p "请输入隧道编号 (1-9): " tunnel_number
        if [[ "$tunnel_number" =~ ^[1-9]$ ]]; then
            break
        fi
        echo "请输入 1-9 之间的数字"
    done

    local tunnel_name="he-ipv6-$tunnel_number"
    if ! configure_single_tunnel "$tunnel_name"; then
        error "配置隧道 $tunnel_name 失败"
        return 1
    fi

    # 测试连接
    log "正在测试连接..."
    if ! ping6 -c 4 ipv6.google.com &>/dev/null; then
        warn "无法ping通 ipv6.google.com"
    else
        log "IPv6 连接测试成功"
    fi

    return 0
}

# IPv6 代理安装函数
install_ipv6_proxy() {
    log "开始安装 IPv6 代理..."

    # 检查Go版本
    check_go_version() {
        if command -v go &> /dev/null; then
            local current_version=$(go version | awk '{print $3}' | sed 's/go//')
            local required_version="1.18"
            if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" = "$required_version" ]; then
                return 0
            fi
        fi
        return 1
    }

    # 安装Go
    install_go() {
        log "正在安装Go 1.18..."
        local go_tar="go1.18.linux-amd64.tar.gz"
        
        if [ -f "$go_tar" ]; then
            rm -f "$go_tar"
        fi
        
        if ! wget "https://go.dev/dl/$go_tar"; then
            error "下载Go失败"
            return 1
        fi
        
        rm -rf /usr/local/go
        if ! tar -C /usr/local -xzf "$go_tar"; then
            error "解压Go失败"
            rm -f "$go_tar"
            return 1
        fi
        rm -f "$go_tar"

        if ! grep -q "/usr/local/go/bin" /etc/profile; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
            echo 'export GO111MODULE=on' >> /etc/profile
        fi
        
        source /etc/profile
        log "Go安装完成"
        go version
        return 0
    }

    # 安装依赖
    if ! check_go_version; then
        if ! install_go; then
            error "安装Go失败"
            return 1
        fi
    fi

    # 创建工作目录
    local work_dir="/opt/ipv6proxy"
    mkdir -p "$work_dir"
    cd "$work_dir" || return 1

    # 克隆代理代码
    if [ -d ".git" ]; then
        git pull
    else
        if ! git clone https://github.com/qza666/v6.git .; then
            error "克隆代码失败"
            return 1
        fi
    fi

    # 编译安装
    export GO111MODULE=on
    export GOPROXY=https://goproxy.cn,direct
    
    if ! go mod tidy; then
        error "更新依赖失败"
        return 1
    fi

    if ! go build -o ipv6proxy cmd/ipv6proxy/main.go; then
        error "编译失败"
        return 1
    fi

    # 创建服务
    cat > /etc/systemd/system/ipv6proxy.service << EOF
[Unit]
Description=IPv6 Proxy Service
After=network.target

[Service]
ExecStart=/opt/ipv6proxy/ipv6proxy
Restart=always
User=root
WorkingDirectory=/opt/ipv6proxy

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable ipv6proxy
    systemctl start ipv6proxy

    log "IPv6代理安装完成"
    return 0
}

# 一键配置函数
one_click_setup() {
    log "开始一键配置..."
    
    if ! configure_he_tunnel; then
        error "HE IPv6 隧道配置失败"
        return 1
    fi
    
    if ! install_ipv6_proxy; then
        error "IPv6 代理安装失败"
        return 1
    fi
    
    log "一键配置完成！"
    return 0
}

# 主菜单函数
main_menu() {
    while true; do
        echo
        echo "请选择要执行的操作："
        echo "1. 配置 HE IPv6 隧道"
        echo "2. 安装 IPv6 代理"
        echo "3. 一键配置隧道与代理"
        echo "4. 退出"
        
        read -p "请输入选项 (1-4): " choice
        echo

        case $choice in
            1)
                configure_he_tunnel || warn "隧道配置未完成"
                ;;
            2)
                install_ipv6_proxy || warn "代理安装未完成"
                ;;
            3)
                one_click_setup || warn "一键配置未完成"
                ;;
            4)
                log "感谢使用，再见！"
                CLEANUP_NEEDED=false
                exit 0
                ;;
            *)
                warn "无效选项，请重新选择"
                ;;
        esac
    done
}

# 主函数
main() {
    initialize
    log "欢迎使用 IPv6 隧道和代理配置脚本"
    
    check_root
    install_basic_tools
    
    main_menu
}

# 执行主函数
main
