package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/qza666/v6/internal/config"
	"github.com/qza666/v6/internal/proxy"
	"github.com/qza666/v6/internal/sysutils"
)

func main() {
	log.SetOutput(os.Stdout)
	cfg := config.ParseFlags()
	if cfg.CIDR == "" {
		log.Fatal("CIDR is required")
	}

	if cfg.RealIPv4 == "" {
		log.Fatal("Real IPv4 address is required")
	}

	if cfg.AutoForwarding {
		sysutils.SetV6Forwarding()
	}

	if cfg.AutoRoute {
		sysutils.AddV6Route(cfg.CIDR)
	}

	if cfg.AutoIpNoLocalBind {
		sysutils.SetIpNonLocalBind()
	}

	randomIPv6Proxy := proxy.NewProxyServer(cfg, true)
	realIPv4Proxy := proxy.NewProxyServer(cfg, false)

	go func() {
		log.Printf("Starting random IPv6 proxy server on %s:%d", cfg.Bind, cfg.RandomIPv6Port)
		err := http.ListenAndServe(fmt.Sprintf("%s:%d", cfg.Bind, cfg.RandomIPv6Port), randomIPv6Proxy)
		if err != nil {
			log.Fatal(err)
		}
	}()

	log.Printf("Starting real IPv4 proxy server on %s:%d", cfg.Bind, cfg.RealIPv4Port)
	err := http.ListenAndServe(fmt.Sprintf("%s:%d", cfg.Bind, cfg.RealIPv4Port), realIPv4Proxy)
	if err != nil {
		log.Fatal(err)
	}
}
