import re
import json
import base64
import urllib.parse
from typing import Dict, Any, List, Optional


def safe_b64decode(s: str) -> str:
    s = s.strip()
    # Replace URL-safe chars
    s = s.replace("-", "+").replace("_", "/")
    # Add padding
    missing_padding = len(s) % 4
    if missing_padding:
        s += "=" * (4 - missing_padding)
    return base64.b64decode(s).decode("utf-8", errors="ignore")


def parse_vless(uri: str) -> Optional[Dict[str, Any]]:
    # vless://uuid@server:port?params#name
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme.lower() != "vless":
        return None

    uuid = parsed.username or ""
    server = parsed.hostname or ""
    port = parsed.port or 443
    name = urllib.parse.unquote(parsed.fragment or server)

    params = urllib.parse.parse_qs(parsed.query)
    security = params.get("security", ["none"])[0].lower()
    transport = params.get("type", ["tcp"])[0].lower()
    sni = params.get("sni", [""])[0]
    fp = params.get("fp", ["chrome"])[0]
    flow = params.get("flow", [""])[0]

    node: Dict[str, Any] = {
        "name": name,
        "server": server,
        "port": port,
        "uuid": uuid,
        "transport": transport,
        "fingerprint": fp,
        "sni": sni or server
    }

    if flow:
        node["flow"] = flow

    if security == "reality":
        node["type"] = "VLESS REALITY"
        node["public_key"] = params.get("pbk", [""])[0]
        node["short_id"] = params.get("sid", [""])[0]
        node["spider_x"] = params.get("spx", [""])[0]
    elif security == "tls":
        node["type"] = "VLESS TLS"
        node["security"] = "tls"
    else:
        node["type"] = "VLESS"
        node["security"] = "none"

    if transport == "ws":
        node["ws_path"] = params.get("path", ["/"])[0]
        node["ws_host"] = params.get("host", [""])[0]
    elif transport == "grpc":
        node["grpc_service_name"] = params.get("serviceName", [""])[0]

    return node


def parse_vmess(uri: str) -> Optional[Dict[str, Any]]:
    # vmess://base64(json)
    if not uri.lower().startswith("vmess://"):
        return None
    raw = uri[8:].strip()
    try:
        decoded = safe_b64decode(raw)
        data = json.loads(decoded)
    except Exception:
        return None

    server = data.get("add", "")
    port = int(data.get("port", 443))
    uuid = data.get("id", "")
    alter_id = int(data.get("aid", 0))
    name = data.get("ps", server)
    transport = data.get("net", "tcp").lower()
    tls = str(data.get("tls", "")).lower() == "tls"
    sni = data.get("sni", "") or data.get("host", "")

    node: Dict[str, Any] = {
        "name": name,
        "type": "VMess",
        "server": server,
        "port": port,
        "uuid": uuid,
        "alter_id": alter_id,
        "transport": transport,
        "security": "tls" if tls else "none",
        "sni": sni
    }

    if transport == "ws":
        node["ws_path"] = data.get("path", "/")
        node["ws_host"] = data.get("host", "")
    elif transport == "grpc":
        node["grpc_service_name"] = data.get("path", "")

    return node


def parse_trojan(uri: str) -> Optional[Dict[str, Any]]:
    # trojan://password@server:port?params#name
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme.lower() != "trojan":
        return None

    password = parsed.username or ""
    server = parsed.hostname or ""
    port = parsed.port or 443
    name = urllib.parse.unquote(parsed.fragment or server)

    params = urllib.parse.parse_qs(parsed.query)
    sni = params.get("sni", [""])[0]
    transport = params.get("type", ["tcp"])[0].lower()

    node: Dict[str, Any] = {
        "name": name,
        "type": "Trojan",
        "server": server,
        "port": port,
        "password": password,
        "security": "tls",
        "sni": sni or server,
        "transport": transport
    }

    if transport == "ws":
        node["ws_path"] = params.get("path", ["/"])[0]
        node["ws_host"] = params.get("host", [""])[0]
    elif transport == "grpc":
        node["grpc_service_name"] = params.get("serviceName", [""])[0]

    return node


def parse_shadowsocks(uri: str) -> Optional[Dict[str, Any]]:
    # ss://base64(method:password@server:port)#name or ss://base64(method:password)@server:port#name
    if not uri.lower().startswith("ss://"):
        return None

    body = uri[5:]
    fragment = ""
    if "#" in body:
        body, fragment = body.split("#", 1)
        name = urllib.parse.unquote(fragment)
    else:
        name = "Shadowsocks"

    if "@" in body:
        user_info, host_port = body.split("@", 1)
        decoded_user = safe_b64decode(user_info)
        if ":" in decoded_user:
            method, password = decoded_user.split(":", 1)
        else:
            method, password = "aes-256-gcm", decoded_user
        if ":" in host_port:
            server, port = host_port.split(":", 1)
        else:
            server, port = host_port, "8388"
    else:
        decoded = safe_b64decode(body)
        match = re.match(r"^(.+?):(.*)@(.+?):(\d+)$", decoded)
        if not match:
            return None
        method, password, server, port = match.groups()

    return {
        "name": name or server,
        "type": "Shadowsocks",
        "server": server,
        "port": int(port),
        "method": method,
        "password": password
    }


def parse_socks(uri: str) -> Optional[Dict[str, Any]]:
    # socks5://user:pass@server:port#name
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme.lower() not in ("socks", "socks5"):
        return None

    server = parsed.hostname or ""
    port = parsed.port or 1080
    name = urllib.parse.unquote(parsed.fragment or f"SOCKS5-{server}")

    return {
        "name": name,
        "type": "NaiveProxy SOCKS5",
        "server": server,
        "port": port,
        "username": parsed.username or "",
        "password": parsed.password or ""
    }


def parse_single_line(line: str) -> Optional[Dict[str, Any]]:
    line = line.strip()
    if not line:
        return None

    if line.startswith("{") and line.endswith("}"):
        try:
            data = json.loads(line)
            if isinstance(data, dict) and data.get("server"):
                return data
        except Exception:
            pass

    lower = line.lower()
    if lower.startswith("vless://"):
        return parse_vless(line)
    if lower.startswith("vmess://"):
        return parse_vmess(line)
    if lower.startswith("trojan://"):
        return parse_trojan(line)
    if lower.startswith("ss://"):
        return parse_shadowsocks(line)
    if lower.startswith("socks5://") or lower.startswith("socks://"):
        return parse_socks(line)

    return None


def import_nodes_from_text(text: str, start_id: int = 1) -> List[Dict[str, Any]]:
    text = text.strip()
    if not text:
        return []

    # Check if whole text is JSON
    if text.startswith("[") or text.startswith("{"):
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                if "nodes" in data and isinstance(data["nodes"], list):
                    data = data["nodes"]
                else:
                    data = [data]
            if isinstance(data, list):
                result = []
                cur_id = start_id
                for item in data:
                    if isinstance(item, dict) and item.get("server"):
                        node = copy.deepcopy(item)
                        node["id"] = cur_id
                        cur_id += 1
                        result.append(node)
                return result
        except Exception:
            pass

    # Line by line parsing
    lines = text.splitlines()
    result = []
    cur_id = start_id
    for line in lines:
        node = parse_single_line(line)
        if node:
            node["id"] = cur_id
            cur_id += 1
            result.append(node)

    return result
