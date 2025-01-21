package dns

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
)

type DoHResponse struct {
	Status   int  `json:"Status"`
	TC       bool `json:"TC"`
	RD       bool `json:"RD"`
	RA       bool `json:"RA"`
	AD       bool `json:"AD"`
	CD       bool `json:"CD"`
	Question []struct {
		Name string `json:"name"`
		Type int    `json:"type"`
	} `json:"Question"`
	Answer []struct {
		Name string `json:"name"`
		Type int    `json:"type"`
		TTL  int    `json:"TTL"`
		Data string `json:"data"`
	} `json:"Answer"`
}

func ResolveDNSOverHTTPS(domain string) (string, error) {
	dohURL := "https://cloudflare-dns.com/dns-query"
	query := url.Values{}
	query.Add("name", domain)
	query.Add("type", "AAAA")

	req, err := http.NewRequest("GET", dohURL, nil)
	if err != nil {
		return "", err
	}

	req.URL.RawQuery = query.Encode()
	req.Header.Add("accept", "application/dns-json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	var dohResp DoHResponse
	err = json.Unmarshal(body, &dohResp)
	if err != nil {
		return "", err
	}

	for _, answer := range dohResp.Answer {
		if answer.Type == 28 { // AAAA record
			return answer.Data, nil
		}
	}

	return "", fmt.Errorf("no AAAA record found for %s", domain)
}