package proxy

import (
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/elazarl/goproxy"
	"github.com/qza666/v6/internal/config"
)

func init() {
	rand.Seed(time.Now().UnixNano())
}

func generateRandomIPv6(cidr string) (net.IP, error) {
	_, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, err
	}

	ip := make(net.IP, net.IPv6len)
	copy(ip, ipNet.IP)

	for i := 0; i < net.IPv6len; i++ {
		if i >= len(ipNet.Mask) || ipNet.Mask[i] != 0xff {
			ip[i] = byte(rand.Intn(256))
		}
	}

	return ip, nil
}

func getIPv6Address(domain string) (string, error) {
	ips, err := net.LookupIP(domain)
	if err != nil {
		return "", err
	}

	for _, ip := range ips {
		if ip.To4() == nil {
			return ip.String(), nil
		}
	}

	return "", fmt.Errorf("no IPv6 address found for %s", domain)
}

func NewProxyServer(cfg *config.Config) *goproxy.ProxyHttpServer {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = cfg.Verbose

	proxy.OnRequest().DoFunc(
		func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
			if !checkAuth(cfg.AuthConfig.Username, cfg.AuthConfig.Password, req) {
				return req, goproxy.NewResponse(req, goproxy.ContentTypeText, http.StatusProxyAuthRequired, "Proxy Authentication Required")
			}
			return req, nil
		},
	)

	proxy.OnRequest().HijackConnect(
		func(req *http.Request, client net.Conn, ctx *goproxy.ProxyCtx) {
			if !checkAuth(cfg.AuthConfig.Username, cfg.AuthConfig.Password, req) {
				client.Write([]byte("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Proxy\"\r\n\r\n"))
				client.Close()
				return
			}

			host := req.URL.Hostname()
			targetIP, err := getIPv6Address(host)
			if err != nil {
				log.Printf("Get IPv6 address error: %v", err)
				client.Write([]byte(fmt.Sprintf("%s 500 Internal Server Error\r\n\r\n", req.Proto)))
				client.Close()
				return
			}

			outgoingIP, err := generateRandomIPv6(cfg.CIDR)
			if err != nil {
				log.Printf("Generate random IPv6 error: %v", err)
				client.Write([]byte(fmt.Sprintf("%s 500 Internal Server Error\r\n\r\n", req.Proto)))
				client.Close()
				return
			}

			dialer := &net.Dialer{
				LocalAddr: &net.TCPAddr{IP: outgoingIP, Port: 0},
				Timeout:   30 * time.Second,
			}

			server, err := dialer.Dial("tcp", req.URL.Host)
			if err != nil {
				log.Printf("Failed to connect to %s from %s: %v", req.URL.Host, outgoingIP.String(), err)
				client.Write([]byte(fmt.Sprintf("%s 500 Internal Server Error\r\n\r\n", req.Proto)))
				client.Close()
				return
			}

			log.Printf("CONNECT: %s [%s] from %s", req.URL.Host, targetIP, outgoingIP.String())
			client.Write([]byte(fmt.Sprintf("%s 200 Connection established\r\n\r\n", req.Proto)))

			go copyData(client, server)
			go copyData(server, client)
		},
	)

	proxy.OnRequest().DoFunc(
		func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
			host := req.URL.Hostname()
			targetIP, err := getIPv6Address(host)
			if err != nil {
				log.Printf("Get IPv6 address error: %v", err)
				return req, goproxy.NewResponse(req, goproxy.ContentTypeText, http.StatusBadGateway, "Failed to resolve host")
			}

			outgoingIP, err := generateRandomIPv6(cfg.CIDR)
			if err != nil {
				log.Printf("Generate random IPv6 error: %v", err)
				return req, goproxy.NewResponse(req, goproxy.ContentTypeText, http.StatusInternalServerError, "Failed to generate IPv6 address")
			}

			log.Printf("HTTP: %s [%s] from %s", req.URL.Host, targetIP, outgoingIP.String())

			dialer := &net.Dialer{
				LocalAddr: &net.TCPAddr{IP: outgoingIP, Port: 0},
				Timeout:   30 * time.Second,
			}

			transport := &http.Transport{
				Dial: dialer.Dial,
				DialContext: dialer.DialContext,
			}

			ctx.RoundTripper = goproxy.RoundTripperFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Response, error) {
				return transport.RoundTrip(req)
			})

			return req, nil
		},
	)

	return proxy
}

func checkAuth(username string, password string, req *http.Request) bool {
	if username == "" || password == "" {
		return true
	}

	auth := req.Header.Get("Proxy-Authorization")
	if auth == "" {
		return false
	}

	const prefix = "Basic "
	if !strings.HasPrefix(auth, prefix) {
		return false
	}

	decoded, err := base64.StdEncoding.DecodeString(auth[len(prefix):])
	if err != nil {
		return false
	}

	credentials := strings.SplitN(string(decoded), ":", 2)
	if len(credentials) != 2 {
		return false
	}

	return credentials[0] == username && credentials[1] == password
}

func copyData(dst, src net.Conn) {
	defer dst.Close()
	defer src.Close()
	io.Copy(dst, src)
}

