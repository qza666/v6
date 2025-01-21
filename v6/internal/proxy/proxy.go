package proxy

import (
	"crypto/rand"
	"log"
	"math/big"
	"net"
	"net/http"
	"strings"

	"github.com/elazarl/goproxy"
	"github.com/qza666/v6/internal/config"
	"github.com/qza666/v6/internal/dns"
)

// 生成随机IPv6地址，限制在/48子网内
func generateRandomIPv6(prefix string) (string, error) {
	// 确保CIDR是/48
	if !strings.HasSuffix(prefix, "/48") {
		prefix = prefix[:strings.LastIndex(prefix, "/")] + "/48"
	}

	_, ipNet, err := net.ParseCIDR(prefix)
	if err != nil {
		return "", err
	}

	// 固定前缀长度为48位
	prefixLen := 48
	randomBits := 128 - prefixLen

	// 生成随机数
	max := new(big.Int).Lsh(big.NewInt(1), uint(randomBits))
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}

	// 获取网络前缀
	ip := ipNet.IP.To16()

	// 将随机数转换为字节
	randomBytes := n.Bytes()
	
	// 创建新的IPv6地址
	newIP := make(net.IP, 16)
	copy(newIP, ip)

	// 从后向前填充随机字节，保持前48位不变
	for i := len(randomBytes) - 1; i >= 0; i-- {
		pos := 15 - (len(randomBytes) - 1 - i)
		if pos >= 6 { // 6 bytes = 48 bits
			newIP[pos] = randomBytes[i]
		}
	}

	return newIP.String(), nil
}

func NewProxyServer(cfg *config.Config) *goproxy.ProxyHttpServer {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = cfg.Verbose

	// 仅允许通过IPv4+端口连接代理服务器
	proxy.OnRequest().DoFunc(
		func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
			// 获取客户端IP
			clientIP := strings.Split(ctx.Req.RemoteAddr, ":")[0]
			
			// 检查是否为IPv4地址
			ip := net.ParseIP(clientIP)
			if ip == nil || ip.To4() == nil {
				return req, goproxy.NewResponse(req,
					goproxy.ContentTypeText,
					http.StatusForbidden,
					"仅支持IPv4客户端连接")
			}

			host := req.URL.Hostname()
			
			// 解析目标域名
			var targetIP string
			var err error
			if cfg.UseDOH {
				targetIP, err = dns.ResolveDNSOverHTTPS(host)
			} else {
				targetIP, err = dns.ResolveDNSOverTLS(host)
			}

			if err != nil {
				log.Printf("DNS解析失败: %v", err)
				return req, goproxy.NewResponse(req,
					goproxy.ContentTypeText,
					http.StatusBadGateway,
					"DNS解析失败")
			}

			// 确保目标是IPv6地址
			if net.ParseIP(targetIP).To4() != nil {
				return req, goproxy.NewResponse(req,
					goproxy.ContentTypeText,
					http.StatusForbidden,
					"仅支持访问IPv6网站")
			}

			// 为每个请求生成随机IPv6地址
			randomIP, err := generateRandomIPv6(cfg.CIDR)
			if err != nil {
				log.Printf("生成随机IPv6地址失败: %v", err)
				return req, goproxy.NewResponse(req,
					goproxy.ContentTypeText,
					http.StatusInternalServerError,
					"生成IPv6地址失败")
			}

			// 设置源IP地址
			dialer := &net.Dialer{
				LocalAddr: &net.TCPAddr{
					IP: net.ParseIP(randomIP),
				},
			}

			transport := &http.Transport{
				Dial: dialer.Dial,
				DialContext: dialer.DialContext,
			}

			ctx.RoundTripper = &TransportAdapter{
				Transport: transport,
			}

			// 清理请求头
			cleanHeaders(req)

			if cfg.Verbose {
				log.Printf("使用IPv6地址 %s 访问 %s", randomIP, host)
			}

			return req, nil
		})

	return proxy
}

