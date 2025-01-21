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
    TOOLS="git build-essential curl wget ufw"
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

# 主函数
main() {
    log "开始安装 IPv6 Proxy..."
    
    # 检查root权限
    check_root
    
    # 安装基础工具
    install_basic_tools
    
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
