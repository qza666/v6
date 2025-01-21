package sysutils

import (
    "os/exec"
)

func SetV6Forwarding() error {
    cmd := exec.Command("sysctl", "-w", "net.ipv6.conf.all.forwarding=1")
    return cmd.Run()
}

func AddV6Route(cidr string) error {
    cmd := exec.Command("ip", "route", "add", cidr, "dev", "eth0")
    return cmd.Run()
}

func SetIpNonLocalBind() error {
    cmd := exec.Command("sysctl", "-w", "net.ipv6.ip_nonlocal_bind=1")
    return cmd.Run()
}
