package config

import (
	"flag"
)

type Config struct {
	Port              int
	CIDR              string
	Bind              string
	AutoRoute         bool
	AutoForwarding    bool
	AutoIpNoLocalBind bool
	UseDOH            bool
	Verbose           bool
	AuthConfig        AuthConfig
}

type AuthConfig struct {
	Username string
	Password string
}

func ParseFlags() *Config {
	cfg := &Config{}
	flag.IntVar(&cfg.Port, "port", 33300, "server port")
	flag.StringVar(&cfg.CIDR, "cidr", "", "ipv6 cidr is required")
	flag.StringVar(&cfg.AuthConfig.Username, "username", "", "Basic auth username")
	flag.StringVar(&cfg.AuthConfig.Password, "password", "", "Basic auth password")
	flag.StringVar(&cfg.Bind, "bind", "0.0.0.0", "Bind address")
	flag.BoolVar(&cfg.AutoRoute, "auto-route", true, "Auto add route to local network")
	flag.BoolVar(&cfg.AutoForwarding, "auto-forwarding", true, "Auto enable ipv6 forwarding")
	flag.BoolVar(&cfg.AutoIpNoLocalBind, "auto-ip-nonlocal-bind", true, "Auto enable ipv6 non local bind")
	flag.BoolVar(&cfg.UseDOH, "use-doh", true, "Use DNS over HTTPS instead of DNS over TLS")
	flag.BoolVar(&cfg.Verbose, "verbose", false, "Enable verbose logging")
	flag.Parse()
	return cfg
}