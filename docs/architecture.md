# Architecture

```text
LAN clients
    │
    ├── SOCKS5h :7890 ──┐
    └── HTTP proxy :10809 ─┤
                           ▼
                     Xray inbound
                           │ sniff HTTP/TLS/QUIC
                           ▼
                    routing rules
              ┌────────────┼────────────┐
              ▼            ▼            ▼
           proxy     proxy-selected   direct/block
        fixed route    xc current       local rules
                           │
                  VLESS REALITY or
                  local Naive SOCKS
```

`xc` never edits the node numbering. It renders a candidate configuration, runs `xray run -test`, atomically replaces `/etc/xc/config.json`, restarts `xc-xray`, waits for the SOCKS listener, and requests the health URL. Any failed step restores `config.previous` and `current.previous`.

The DNS DoH request is assigned the `dns-proxy` tag and routed to `proxy-selected`. No dnsmasq rule, port 53 rule, or router-wide DNS redirect is required by this project.
