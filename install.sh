#!/bin/bash

# 启用错误检查
set -e

# 全局变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="/tmp/he-ipv6-setup"
LOG_FILE="$TEMP_DIR/install.log"
GO_VERSION="1.18"
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
REPO_URL="https://github.com/qza666/v6.git"
REPO_DIR="v6"
TUNNEL_NAME="he-ipv6"
CONFIG_DIR="/etc/he-ipv6"
CONFIG_FILE="$CONFIG_DIR/$TUNNEL_NAME.conf"

# 初始化安装环境
init_environment() {
    mkdir -p "$TEMP_DIR" "$CONFIG_DIR"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    echo "安装开始时间: $(date)"
    echo "正在初始化安装环境..."
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误: 请以root权限运行此脚本"
        exit 1
    fi
}

# 网络连接检查
check_network() {
    local test_hosts=("google.com" "github.com" "1.1.1.1")
    local success=0
    
    echo "检查网络连接..."
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 $host &>/dev/null; then
            success=1
            break
        fi
    done
    
    if [ $success -eq 0 ]; then
        echo "警告: 网络连接不稳定，这可能会影响安装过程"
        read -p "是否继续？(y/n): " continue_setup
        if [[ $continue_setup != [yY] ]]; then
            exit 1
        fi
    fi
}

# 检查并安装依赖
install_packages() {
    local packages="$1"
    echo "正在安装: $packages"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages
}


# 安装基本工具
install_basic_tools() {
    echo "检查并安装必要工具..."
    local base_tools="curl wget"
    local dev_tools="build-essential git"
    local net_tools="ufw iproute2 net-tools"
    
    # 首先安装基本工具
    if ! command -v curl &>/dev/null || ! command -v wget &>/dev/null; then
        install_packages "$base_tools"
    fi
    
    # 然后安装开发工具
    if ! command -v git &>/dev/null; then
        install_packages "$dev_tools"
    fi
    
    # 最后安装网络工具
    install_packages "$net_tools"
    
    # 验证关键工具是否安装成功
    local required_tools="git curl wget"
    for tool in $required_tools; do
        if ! command -v $tool &>/dev/null; then
            echo "错误: $tool 安装失败"
            exit 1
        fi
    done
}

# 检查Go版本
check_go_version() {
    if command -v go &>/dev/null; then
        local current_version=$(go version | awk '{print $3}' | sed 's/go//')
        if [ "$(printf '%s\n' "$GO_VERSION" "$current_version" | sort -V | head -n1)" = "$GO_VERSION" ]; then
            echo "检测到Go版本 $current_version，符合要求..."
            return 0
        fi
    fi
    return 1
}

# 安装Go
install_go() {
    if check_go_version; then
        return 0
    fi

    echo "正在安装Go ${GO_VERSION}..."
    
    if [ ! -f "$TEMP_DIR/$GO_TAR" ]; then
        wget -P "$TEMP_DIR" "https://go.dev/dl/$GO_TAR" || {
            echo "错误: 下载Go失败"
            exit 1
        }
    fi
    
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$TEMP_DIR/$GO_TAR" || {
        echo "错误: 解压Go失败"
        exit 1
    }
    
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
        echo 'export GO111MODULE=on' >> /etc/profile
    fi
    source /etc/profile
    
    if ! go version &>/dev/null; then
        echo "错误: Go安装失败"
        exit 1
    fi
}

# 克隆或更新代码仓库
clone_or_update_repo() {
    echo "准备项目代码..."
    if [ -d "$REPO_DIR/.git" ]; then
        echo "更新项目代码..."
        cd $REPO_DIR
        git fetch --depth 1 origin master
        git reset --hard origin/master
        cd ..
    else
        echo "克隆项目代码..."
        git clone --depth 1 $REPO_URL
    fi
}

# 验证IPv4地址
validate_ipv4() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 || ($octet =~ ^0[0-9]+) ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 验证IPv6地址
validate_ipv6() {
    local ip=$1
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    fi
    return 1
}

# 生成本机IPv6地址
generate_local_ipv6() {
    local he_ipv6=$1
    echo "${he_ipv6%::1}::2"
}

# 检查系统内存
check_system_memory() {
    local available_mem=$(free -m | awk '/^Mem:/{print $7}')
    if [ $available_mem -lt 512 ]; then
        echo "警告: 系统可用内存不足 (${available_mem}MB)"
        read -p "是否继续？(y/n): " continue_setup
        if [[ $continue_setup != [yY] ]]; then
            exit 1
        fi
    fi
}

# 优化系统配置
optimize_system_config() {
    local sysctl_file="/etc/sysctl.conf"
    local need_reload=0
    
    declare -A params=(
        ["net.ipv4.ip_forward"]="1"
        ["net.ipv6.conf.all.forwarding"]="1"
        ["net.ipv6.conf.all.proxy_ndp"]="1"
        ["net.ipv4.neigh.default.gc_thresh1"]="1024"
        ["net.ipv4.neigh.default.gc_thresh2"]="2048"
        ["net.ipv4.neigh.default.gc_thresh3"]="4096"
        ["net.ipv6.neigh.default.gc_thresh1"]="1024"
        ["net.ipv6.neigh.default.gc_thresh2"]="2048"
        ["net.ipv6.neigh.default.gc_thresh3"]="4096"
    )
    
    for param in "${!params[@]}"; do
        if ! grep -q "^$param = ${params[$param]}$" $sysctl_file; then
            sed -i "/$param/d" $sysctl_file
            echo "$param = ${params[$param]}" >> $sysctl_file
            need_reload=1
        fi
    done
    
    [ $need_reload -eq 1 ] && sysctl -p &>/dev/null
}

# 检查并删除现有隧道
check_and_remove_existing_tunnel() {
    if ip link show $TUNNEL_NAME &>/dev/null; then
        echo "发现现有隧道 $TUNNEL_NAME"
        read -p "是否删除现有隧道？(y/n): " confirm
        if [[ $confirm == [yY] ]]; then
            echo "正在删除现有隧道..."
            ip link set $TUNNEL_NAME down 2>/dev/null || true
            ip tunnel del $TUNNEL_NAME 2>/dev/null || true
            sed -i "/# HE IPv6 Tunnel.*$TUNNEL_NAME/,/# End IPv6 Tunnel/d" /etc/network/interfaces
            echo "现有隧道已删除"
        else
            echo "用户取消操作"
            exit 1
        fi
    fi
}

# 配置HE IPv6隧道
configure_he_tunnel() {
    local he_ipv4
    local local_ipv4
    local he_ipv6
    local local_ipv6
    local routed_prefix
    local prefix_length
    local ping_ipv6

    check_and_remove_existing_tunnel

    # 获取并验证HE服务器IPv4地址
    while true; do
        read -p "请输入HE服务器IPv4地址: " he_ipv4
        if validate_ipv4 "$he_ipv4" && ping -c 1 -W 3 "$he_ipv4" &>/dev/null; then
            break
        fi
        echo "无效的IPv4地址或无法连接到服务器，请重新输入"
    done

    # 获取并验证本机IPv4地址
    while true; do
        read -p "请输入本机IPv4地址: " local_ipv4
        if validate_ipv4 "$local_ipv4" && ip addr | grep -q "$local_ipv4"; then
            break
        fi
        echo "无效的IPv4地址或地址不在本机网卡上，请重新输入"
    done

    # 获取并验证HE服务器IPv6地址
    while true; do
        read -p "请输入HE服务器IPv6地址（包括前缀长度，如 2001:470:1f04:17b::1/64）: " he_ipv6
        if [[ $he_ipv6 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}::1/[0-9]+$ ]]; then
            break
        fi
        echo "无效的IPv6地址格式，请重新输入"
    done

    # 生成本机IPv6地址
    local_ipv6=$(generate_local_ipv6 "${he_ipv6%/*}")
    local_ipv6="${local_ipv6}/${he_ipv6#*/}"
    echo "本机IPv6地址: $local_ipv6"

    # 获取并验证IPv6前缀
    while true; do
        read -p "请输入HE分配的IPv6前缀（如 2001:470:1f05:17b::/64）: " routed_prefix
        if [[ $routed_prefix =~ ^([0-9a-fA-F]{0,4}:){1,7}: ]]; then
            break
        fi
        echo "无效的IPv6前缀格式，请重新输入"
    done

    prefix_length="${routed_prefix#*/}"
    routed_prefix="${routed_prefix%/*}"
    ping_ipv6="${routed_prefix%:*}:1"

    # 配置隧道
    echo "配置隧道..."
    ip tunnel add $TUNNEL_NAME mode sit remote $he_ipv4 local $local_ipv4 ttl 255 || {
        echo "创建隧道失败"
        exit 1
    }

    ip link set $TUNNEL_NAME up
    ip addr add ${local_ipv6} dev $TUNNEL_NAME
    ip addr add ${ping_ipv6}/${prefix_length} dev $TUNNEL_NAME
    ip -6 route add ${routed_prefix}/${prefix_length} dev $TUNNEL_NAME
    ip -6 route add ::/0 via ${he_ipv6%/*} dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME mtu 1480

    # 保存配置
    cat > "$CONFIG_FILE" << EOF
HE_SERVER_IPV4=$he_ipv4
HE_SERVER_IPV6=${he_ipv6%/*}
LOCAL_IPV4=$local_ipv4
LOCAL_IPV6=${local_ipv6%/*}
ROUTED_PREFIX=$routed_prefix
PREFIX_LENGTH=$prefix_length
PING_IPV6=$ping_ipv6
EOF

    # 添加网络接口配置
    cat >> /etc/network/interfaces << EOF

# HE IPv6 Tunnel $TUNNEL_NAME
auto $TUNNEL_NAME
iface $TUNNEL_NAME inet6 v4tunnel
    address ${local_ipv6%/*}
    netmask 64
    endpoint $he_ipv4
    local $local_ipv4
    ttl 255
    gateway ${he_ipv6%/*}
    mtu 1480
    up ip -6 addr add ${ping_ipv6}/${prefix_length} dev \$IFACE
    up ip -6 route add ${routed_prefix}/${prefix_length} dev \$IFACE
    up ip -6 route add ::/0 via ${he_ipv6%/*} dev \$IFACE
# End IPv6 Tunnel
EOF

    # 测试连接
    echo "测试IPv6连接..."
    if ! ping6 -c 3 -I $TUNNEL_NAME ${he_ipv6%/*} &>/dev/null; then
        echo "警告: 无法连接到HE服务器"
        return 1
    fi

    echo "IPv6隧道配置完成"
    return 0
}

# 创建系统服务
create_service() {
    local ipv6_cidr="$1"
    local real_ipv4="$2"
    
    cat > /etc/systemd/system/ipv6proxy.service << EOF
[Unit]
Description=IPv6 Proxy Service
After=network.target

[Service]
ExecStart=/usr/local/go/bin/go run /root/v6/cmd/ipv6proxy/main.go -cidr "$ipv6_cidr" -random-ipv6-port 100 -real-ipv4-port 101 -real-ipv4 "$real_ipv4"
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
    echo "开始安装IPv6 Proxy..."
    
    # 初始化环境
    init_environment
    check_root
    check_network
    
    # 先安装基本工具，不再并行执行
    install_basic_tools
    
    # 安装Go（可以在工具安装完成后并行执行）
    install_go &
    go_pid=$!
    
    # 克隆代码（工具已经安装完成，可以安全执行）
    clone_or_update_repo
    
    # 等待Go安装完成
    wait $go_pid
    
    # 继续其他配置
    check_system_memory
    optimize_system_config
    
    # 配置HE IPv6隧道
    if ! configure_he_tunnel; then
        echo "隧道配置失败"
        exit 1
    fi
    # 从配置文件读取信息
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        ipv6_cidr="${ROUTED_PREFIX}/${PREFIX_LENGTH}"
        real_ipv4="${LOCAL_IPV4}"
    else
        echo "错误：找不到隧道配置文件"
        exit 1
    fi
    
    # 创建并启动服务
    create_service "$ipv6_cidr" "$real_ipv4"
    
    # 显示完成信息
    echo -e "\n安装完成！使用说明："
    cat << EOF

IPv6代理服务已配置完成。服务详情：
- 随机IPv6代理端口：100
- 真实IPv4代理端口：101
- IPv6 CIDR：$ipv6_cidr
- 真实IPv4地址：$real_ipv4

管理命令：
1. 启动服务：
   systemctl start ipv6proxy

2. 设置开机自启：
   systemctl enable ipv6proxy

3. 查看服务状态：
   systemctl status ipv6proxy

4. 查看服务日志：
   journalctl -u ipv6proxy -f

5. 停止服务：
   systemctl stop ipv6proxy

5. 手动测试：
   cd /root/v6
   go run cmd/ipv6proxy/main.go -cidr $ipv6_cidr -real-ipv4 $real_ipv4

配置文件位置：
- 隧道配置：$CONFIG_FILE
- 服务配置：/etc/systemd/system/ipv6proxy.service

如需修改配置，编辑相应文件后请运行：
systemctl daemon-reload
systemctl restart ipv6proxy

EOF

    # 询问是否启动服务
    read -p "是否现在启动服务？(y/n): " start_service
    if [[ $start_service == [yY] ]]; then
        echo "正在启动服务..."
        systemctl start ipv6proxy
        sleep 2
        if systemctl is-active ipv6proxy >/dev/null 2>&1; then
            echo "服务已成功启动"
            systemctl status ipv6proxy
        else
            echo "服务启动失败，请检查日志："
            journalctl -u ipv6proxy -n 50 --no-pager
        fi
    fi

    echo -e "\n安装和配置已完成。请检查上述信息，确保所有配置正确。"
    echo "如有任何问题，请查看系统日志或联系支持。"
    echo "安装日志保存在：$LOG_FILE"
}

# 执行主函数
main
