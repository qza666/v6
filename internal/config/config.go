package config

import (
	"flag"
)

type Config struct {
	RandomIPv6Port     int
	RealIPv4Port       int
	CIDR               string
	Bind               string
	AutoRoute          bool
	AutoForwarding     bool
	AutoIpNoLocalBind  bool
	UseDOH             bool
	Verbose            bool
	AuthConfig         AuthConfig
	RealIPv4           string
}

type AuthConfig struct {
	Username string
	Password string
}

func ParseFlags() *Config {
	cfg := &Config{}
	flag.IntVar(&cfg.RandomIPv6Port, "random-ipv6-port", 100, "Port for random IPv6 proxy")
	flag.IntVar(&cfg.RealIPv4Port, "real-ipv4-port", 101, "Port for real IPv4 proxy")
	flag.StringVar(&cfg.CIDR, "cidr", "", "IPv6 CIDR is required")
	flag.StringVar(&cfg.AuthConfig.Username, "username", "", "Basic auth username")
	flag.StringVar(&cfg.AuthConfig.Password, "password", "", "Basic auth password")
	flag.StringVar(&cfg.Bind, "bind", "0.0.0.0", "Bind address")
	flag.BoolVar(&cfg.AutoRoute, "auto-route", true, "Auto add route to local network")
	flag.BoolVar(&cfg.AutoForwarding, "auto-forwarding", true, "Auto enable IPv6 forwarding")
	flag.BoolVar(&cfg.AutoIpNoLocalBind, "auto-ip-nonlocal-bind", true, "Auto enable IPv6 non local bind")
	flag.BoolVar(&cfg.UseDOH, "use-doh", true, "Use DNS over HTTPS instead of DNS over TLS")
	flag.BoolVar(&cfg.Verbose, "verbose", false, "Enable verbose logging")
	flag.StringVar(&cfg.RealIPv4, "real-ipv4", "", "Server's real IPv4 address")
	flag.Parse()
	return cfg
}
