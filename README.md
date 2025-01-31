![image](https://github.com/user-attachments/assets/dc93ec42-2ed9-4bab-ad75-789488f4cc43)


# HE IPv6 隧道与 IPv6 代理配置脚本

这个脚本用于配置 HE（Hurricane Electric）IPv6 隧道以及一个基于 Go 语言的 IPv6 代理服务。它包括从安装必备工具、配置 IPv6 隧道到创建并启用 IPv6 代理服务的完整步骤。
完全傻瓜式的一键安装

## 功能

- **自动配置 HE IPv6 隧道**：通过指定 HE 服务器的 IPv4 和 IPv6 地址，以及本地网络的 IPv4 地址来配置隧道。
- **安装 Go 环境**：如果本地没有安装 Go 语言环境，脚本会自动安装指定版本的 Go（目前为 1.18）。
- **创建并配置 IPv6 代理服务**：安装并启动一个 IPv6 代理服务，该服务通过 HE 隧道将请求转发到实际的 IPv4 地址。

## 系统要求

- **操作系统**：基于 Debian/Ubuntu 的 Linux 系统（推荐Ubuntu 18）
- **系统内存**：至少 512 MB 可用内存
- **root 权限**：需要以 root 用户运行

## 使用说明

### 1. 下载并运行脚本

```bash
git clone https://github.com/qza666/v6.git
cd v6
chmod +x install.sh
sudo ./install.sh
```

### 2. 配置 HE IPv6 隧道

脚本会要求您提供以下信息来配置 HE IPv6 隧道：

- **HE 服务器的 IPv4 地址**
- **本地机器的 IPv4 地址**
- **HE 服务器的 IPv6 地址（包括前缀长度）**
- **HE 分配的 IPv6 前缀（可以是/48）**

### 3. 启动 IPv6 代理服务

配置完成后，您将可以启动 IPv6 代理服务：

```bash
systemctl start ipv6proxy
```

要设置服务开机自启：

```bash
systemctl enable ipv6proxy
```

### 4. 查看服务状态

您可以随时查看 IPv6 代理服务的状态：

```bash
systemctl status ipv6proxy
```

查看服务日志：

```bash
journalctl -u ipv6proxy -f
```

### 5. 手动测试代理

如果您需要手动测试代理，可以在 `/root/v6` 目录下执行以下命令：

```bash
go run cmd/ipv6proxy/main.go -cidr <IPv6_CIDR> -real-ipv4 <Real_IPv4>
```

### 6. 停止服务

如果需要停止 IPv6 代理服务，可以使用：

```bash
systemctl stop ipv6proxy
```

### 配置文件位置

- 隧道配置文件：`/etc/he-ipv6/he-ipv6.conf`
- IPv6 代理服务配置文件：`/etc/systemd/system/ipv6proxy.service`

## 配置文件说明

在脚本运行时，以下配置信息会保存在配置文件中：

- **HE 服务器 IPv4 地址**
- **HE 服务器 IPv6 地址**
- **本地 IPv4 地址**
- **本地 IPv6 地址**
- **HE 分配的 IPv6 前缀**

## 安装日志

安装过程中生成的日志文件存储在：

```
/tmp/he-ipv6-setup/install.log
```

## 常见问题

### Q1: 脚本提示安装失败怎么办？

- 确保系统已连接到互联网，并且具有足够的系统内存（至少 512 MB）。
- 检查安装日志以获取详细错误信息。

### Q2: 如何修改配置？

如果需要修改配置文件，请编辑相应的配置文件，然后重新启动服务：

```bash
systemctl daemon-reload
systemctl restart ipv6proxy
```

## 支持与反馈

如果您遇到任何问题，或者有任何建议，请查看日志文件，或者直接联系项目维护者。
