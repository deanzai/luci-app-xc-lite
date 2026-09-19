import copy
from typing import Dict, Any, List, Optional, Tuple

PRESET_ROUTING_RULES = [
    {
        "type": "field",
        "inboundTag": ["dns-proxy"],
        "outboundTag": "proxy-selected"
    },
    {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
    },
    {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
    },
    {
        "type": "field",
        "domain": ["geosite:private"],
        "outboundTag": "direct"
    },
    {
        "type": "field",
        "ip": [
            "192.168.0.0/16",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "127.0.0.0/8"
        ],
        "outboundTag": "direct"
    },
    {
        "type": "field",
        "domain": [
            "geosite:openai",
            "geosite:youtube",
            "geosite:twitter",
            "geosite:telegram",
            "geosite:tiktok",
            "geosite:netflix",
            "geosite:google",
            "geosite:facebook",
            "full:voice.google.com",
            "domain:voice.googleusercontent.com"
        ],
        "outboundTag": "proxy"
    },
    {
        "type": "field",
        "domain": ["geosite:geolocation-!cn"],
        "outboundTag": "proxy-selected"
    },
    {
        "type": "field",
        "ip": ["geoip:cn"],
        "outboundTag": "direct"
    },
    {
        "type": "field",
        "domain": ["geosite:cn"],
        "outboundTag": "direct"
    }
]

DNS_CONFIG = {
    "servers": [
        {
            "queryStrategy": "UseIPv4",
            "skipFallback": True,
            "tag": "dns-proxy",
            "address": "https://1.1.1.1/dns-query"
        }
    ],
    "queryStrategy": "UseIPv4",
    "disableFallback": True
}


def build_stream_settings(node: Dict[str, Any]) -> Dict[str, Any]:
    protocol = node.get("type", "").upper()
    transport = str(node.get("transport", "tcp")).lower()
    security = str(node.get("security", "")).lower()

    if "REALITY" in protocol:
        security = "reality"
    elif "TLS" in protocol:
        security = "tls"

    stream = {
        "network": transport,
        "security": security if security in ("tls", "reality") else "none"
    }

    if transport == "tcp":
        stream["tcpSettings"] = {"header": {"type": "none"}}
    elif transport == "ws":
        ws_settings = {
            "path": node.get("ws_path") or "/"
        }
        if node.get("ws_host") or node.get("sni"):
            ws_settings["headers"] = {"Host": node.get("ws_host") or node.get("sni")}
        stream["wsSettings"] = ws_settings
    elif transport == "grpc":
        stream["grpcSettings"] = {
            "serviceName": node.get("grpc_service_name", "")
        }

    if security == "tls":
        tls_settings = {
            "serverName": node.get("sni") or node.get("server"),
            "allowInsecure": False
        }
        if node.get("fingerprint"):
            tls_settings["fingerprint"] = node.get("fingerprint")
        stream["tlsSettings"] = tls_settings
    elif security == "reality":
        reality_settings = {
            "show": False,
            "serverName": node.get("sni") or node.get("server"),
            "publicKey": node.get("public_key", ""),
            "shortId": node.get("short_id", ""),
            "spiderX": node.get("spider_x") or "/",
            "fingerprint": node.get("fingerprint") or "chrome"
        }
        stream["realitySettings"] = reality_settings

    return stream


def build_outbound(node: Dict[str, Any], tag: str) -> Dict[str, Any]:
    node_type = str(node.get("type", "")).upper()
    server = node.get("server", "127.0.0.1")
    port = int(node.get("port", 443))

    if "SOCKS" in node_type or "NAIVE" in node_type:
        srv = {"address": server, "port": port}
        if node.get("username") or node.get("password"):
            srv["users"] = [{"user": node.get("username", ""), "pass": node.get("password", "")}]
        return {
            "tag": tag,
            "protocol": "socks",
            "settings": {"servers": [srv]}
        }

    if "VLESS" in node_type:
        user = {
            "id": node.get("uuid", ""),
            "encryption": node.get("encryption", "none")
        }
        flow = node.get("flow")
        if flow and flow in ("xtls-rprx-vision", "xtls-rprx-vision-udp443"):
            user["flow"] = flow

        return {
            "tag": tag,
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": server,
                    "port": port,
                    "users": [user]
                }]
            },
            "streamSettings": build_stream_settings(node)
        }

    if "VMESS" in node_type:
        user = {
            "id": node.get("uuid", ""),
            "alterId": int(node.get("alter_id", 0)),
            "security": node.get("security_cipher", "auto")
        }
        return {
            "tag": tag,
            "protocol": "vmess",
            "settings": {
                "vnext": [{
                    "address": server,
                    "port": port,
                    "users": [user]
                }]
            },
            "streamSettings": build_stream_settings(node)
        }

    if "TROJAN" in node_type:
        return {
            "tag": tag,
            "protocol": "trojan",
            "settings": {
                "servers": [{
                    "address": server,
                    "port": port,
                    "password": node.get("password", "")
                }]
            },
            "streamSettings": build_stream_settings(node)
        }

    if "SHADOWSOCKS" in node_type or "SS" in node_type:
        return {
            "tag": tag,
            "protocol": "shadowsocks",
            "settings": {
                "servers": [{
                    "address": server,
                    "port": port,
                    "method": node.get("method", "aes-256-gcm"),
                    "password": node.get("password", "")
                }]
            },
            "streamSettings": build_stream_settings(node)
        }

    # Fallback to direct if unrecognized
    return {"tag": tag, "protocol": "freedom"}


def generate_xray_config(settings: Dict[str, Any], nodes_data: Dict[str, Any], active_node: Dict[str, Any]) -> Dict[str, Any]:
    listen_host = settings.get("listen_host", "0.0.0.0")
    socks_port = int(settings.get("socks_port", 7890))
    http_port = int(settings.get("http_port", 10809))
    log_level = settings.get("log_level", "warning")

    sniffing = {
        "enabled": True,
        "routeOnly": True,
        "destOverride": ["http", "tls", "quic"]
    }

    inbounds = [
        {
            "tag": "socks-in",
            "listen": listen_host,
            "port": socks_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
            "sniffing": sniffing
        },
        {
            "tag": "http-in",
            "listen": listen_host,
            "port": http_port,
            "protocol": "http",
            "sniffing": sniffing
        }
    ]

    # If main listener is bound to a specific non-wildcard IP, also add 127.0.0.1 loopback inbounds
    if listen_host not in ("0.0.0.0", "::", "[::]", "127.0.0.1", "::1", "[::1]"):
        inbounds.extend([
            {
                "tag": "socks-in-loopback",
                "listen": "127.0.0.1",
                "port": socks_port,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
                "sniffing": sniffing
            },
            {
                "tag": "http-in-loopback",
                "listen": "127.0.0.1",
                "port": http_port,
                "protocol": "http",
                "sniffing": sniffing
            }
        ])

    # Outbounds:
    # 1. proxy-selected (current active node)
    # 2. proxy (fixed node for YouTube/OpenAI/etc.)
    # 3. direct
    # 4. block
    outbounds = []
    outbounds.append(build_outbound(active_node, "proxy-selected"))

    fixed_id = nodes_data.get("fixed_proxy_id")
    fixed_node = None
    if fixed_id:
        for n in nodes_data.get("nodes", []):
            if n.get("id") == fixed_id:
                fixed_node = n
                break
    if not fixed_node:
        fixed_node = active_node

    outbounds.append(build_outbound(fixed_node, "proxy"))
    outbounds.append({"tag": "direct", "protocol": "freedom"})
    outbounds.append({"tag": "block", "protocol": "blackhole", "settings": {"response": {"type": "none"}}})

    config = {
        "log": {
            "access": "none",
            "loglevel": log_level,
            "dnsLog": False
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "routing": {
            "domainStrategy": "AsIs",
            "rules": copy.deepcopy(PRESET_ROUTING_RULES)
        },
        "dns": copy.deepcopy(DNS_CONFIG)
    }

    return config
