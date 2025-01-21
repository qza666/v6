package dns

import (
	"crypto/tls"
	"fmt"
	"github.com/miekg/dns"
)

func ResolveDNSOverTLS(domain string) (string, error) {
	c := new(dns.Client)
	c.Net = "tcp-tls"
	c.TLSConfig = &tls.Config{
		ServerName: "dns.cloudflare.com",
	}

	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(domain), dns.TypeAAAA)
	m.RecursionDesired = true

	r, _, err := c.Exchange(m, "dns.cloudflare.com:853")
	if err != nil {
		return "", err
	}

	if r.Rcode != dns.RcodeSuccess {
		return "", fmt.Errorf("DNS query failed: %v", dns.RcodeToString[r.Rcode])
	}

	for _, answer := range r.Answer {
		if aaaa, ok := answer.(*dns.AAAA); ok {
			return aaaa.AAAA.String(), nil
		}
	}

	return "", fmt.Errorf("no AAAA record found for %s", domain)
}