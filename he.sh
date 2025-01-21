#!/bin/bash

set -e

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以 root 权限运行" 1>&2
   exit 1
fi

# 函数：检查并安装依赖
check_and_install_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 未安装，正在安装..."
        apt-get update
        apt-get install -y $1
        if [ $? -ne 0 ]; then
            echo "安装 $1 失败，请检查您的网络连接和系统设置。"
            exit 1
        fi
    fi
}

# 检查必要的依赖
check_and_install_dependency iproute2
check_and_install_dependency net-tools
check_and_install_dependency curl

# 函数：验证 IPv4 地址
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

# 函数：验证 IPv6 地址
validate_ipv6() {
    if [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 函数：生成本机IPv6地址
generate_local_ipv6() {
    local he_ipv6=$1
    echo "${he_ipv6%::1}::2"
}

# 函数：检查隧道是否存在
check_tunnel_exists() {
    local tunnel_name=$1
    if ip link show $tunnel_name &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 函数：删除现有隧道
remove_tunnel() {
    local tunnel_name=$1
    
    ip link set $tunnel_name down 2>/dev/null || true
    ip tunnel del $tunnel_name 2>/dev/null || true
    
    sed -i "/# HE IPv6 Tunnel.*$tunnel_name/,/# End IPv6 Tunnel/d" /etc/network/interfaces
    
    echo "隧道 $tunnel_name 已删除"
}

# 函数：配置单个隧道
configure_tunnel() {
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

# 主程序
echo "欢迎使用 HE IPv6 隧道配置脚本"

while true; do
    read -p "请输入隧道编号 (1-9): " tunnel_number
    if [[ "$tunnel_number" =~ ^[1-9]$ ]]; then
        break
    fi
    echo "请输入 1-9 之间的数字"
done

tunnel_name="he-ipv6-$tunnel_number"

configure_tunnel $tunnel_name

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

# 执行脚本
echo "脚本执行完毕。"