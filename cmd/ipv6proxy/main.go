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
		log.Fatal("cidr is required")
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

	p := proxy.NewProxyServer(cfg)

	log.Printf("Starting server on %s:%d", cfg.Bind, cfg.Port)
	err := http.ListenAndServe(fmt.Sprintf("%s:%d", cfg.Bind, cfg.Port), p)

	if err != nil {
		log.Fatal(err)
	}
}

