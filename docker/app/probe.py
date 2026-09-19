import os
import json
import time
import socket
import ssl
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, Any, List, Optional, Tuple

from generator import build_outbound


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def tcp_probe(server: str, port: int, timeout: float = 3.0, use_ssl: bool = False, sni: Optional[str] = None) -> Optional[int]:
    start = time.time()
    try:
        sock = socket.create_connection((server, port), timeout=timeout)
        if use_ssl:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(sock, server_hostname=sni or server)
        sock.close()
        elapsed_ms = int((time.time() - start) * 1000)
        return elapsed_ms
    except Exception:
        return None


def probe_node_xray(node: Dict[str, Any], settings: Dict[str, Any], xray_bin: str) -> Optional[int]:
    probe_url = settings.get("probe_url", "http://www.gstatic.com/generate_204")
    timeout = int(settings.get("probe_timeout", 5))

    temp_port = find_free_port()
    probe_config = {
        "log": {"access": "none", "loglevel": "none"},
        "inbounds": [
            {
                "tag": "probe-in",
                "listen": "127.0.0.1",
                "port": temp_port,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": False}
            }
        ],
        "outbounds": [
            build_outbound(node, "proxy"),
            {"tag": "direct", "protocol": "freedom"}
        ]
    }

    tmp_file = None
    proc = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(probe_config, f)
            tmp_file = f.name

        # Launch background xray probe instance
        env = os.environ.copy()
        proc = subprocess.Popen(
            [xray_bin, "run", "-format=json", "-c", tmp_file],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env
        )


        # Wait a fraction for port to listen
        time.sleep(0.3)

        # Run curl test
        cmd = [
            "curl", "--silent", "--show-error",
            "--max-time", str(timeout),
            "-w", "%{time_total}",
            "-o", "/dev/null",
            "--proxy", f"socks5h://127.0.0.1:{temp_port}",
            probe_url
        ]

        start_time = time.time()
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout + 2)
        if res.returncode == 0:
            try:
                seconds = float(res.stdout.strip())
                return int(seconds * 1000)
            except ValueError:
                return int((time.time() - start_time) * 1000)
        return None
    except Exception:
        return None
    finally:
        if proc:
            try:
                proc.terminate()
                proc.wait(timeout=1)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        if tmp_file and os.path.exists(tmp_file):
            try:
                os.remove(tmp_file)
            except Exception:
                pass


def probe_single_node(node: Dict[str, Any], settings: Dict[str, Any], xray_bin: Optional[str] = None) -> Dict[str, Any]:
    node_id = node.get("id")
    # If xray binary exists and is executable, try real full-chain proxy test
    latency = None
    if xray_bin and os.path.isfile(xray_bin) and os.access(xray_bin, os.X_OK):
        latency = probe_node_xray(node, settings, xray_bin)

    # Fallback to direct TCP/TLS probe if Xray probe failed or Xray not present
    if latency is None:
        server = node.get("server")
        port = int(node.get("port", 443))
        node_type = str(node.get("type", "")).upper()
        use_ssl = "TLS" in node_type or "REALITY" in node_type or port == 443
        timeout = float(settings.get("probe_timeout", 3))
        latency = tcp_probe(server, port, timeout=timeout, use_ssl=use_ssl, sni=node.get("sni"))

    return {
        "id": node_id,
        "name": node.get("name"),
        "latency": latency,
        "status": "ok" if latency is not None else "fail"
    }


def probe_all_nodes(nodes: List[Dict[str, Any]], settings: Dict[str, Any], xray_bin: Optional[str] = None) -> List[Dict[str, Any]]:
    concurrency = int(settings.get("probe_concurrency", 5))
    results = {}

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = {executor.submit(probe_single_node, node, settings, xray_bin): node.get("id") for node in nodes}
        for future in as_completed(futures):
            node_id = futures[future]
            try:
                res = future.result()
                results[node_id] = res
            except Exception:
                results[node_id] = {"id": node_id, "latency": None, "status": "fail"}

    # Maintain original order
    ordered = []
    for node in nodes:
        nid = node.get("id")
        if nid in results:
            ordered.append(results[nid])
    return ordered
