#!/usr/bin/env python3
import sys
import os
import json
import urllib.request
import urllib.error
from typing import Dict, Any, Optional

API_BASE = os.environ.get("XC_API_BASE", "http://127.0.0.1:7891/api")


def api_call(path: str, method: str = "GET", data: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
    url = f"{API_BASE}{path}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json")
    body = json.dumps(data).encode("utf-8") if data else None

    try:
        with urllib.request.urlopen(req, data=body, timeout=20) as resp:
            content = resp.read().decode("utf-8")
            return json.loads(content)
    except Exception:
        return None


def fallback_storage():
    sys.path.insert(0, os.path.dirname(__file__))
    from storage import Storage
    from runtime import RuntimeManager
    from probe import probe_all_nodes, probe_single_node
    st = Storage()
    rt = RuntimeManager(st)
    return st, rt, probe_all_nodes, probe_single_node


def cmd_status():
    res = api_call("/status")
    if not res:
        st, rt, _, _ = fallback_storage()
        res = rt.get_status()

    current_node = res.get("current_node") or {}
    node_name = current_node.get("name", "None")
    node_type = current_node.get("type", "Unknown")
    node_id = res.get("current_id", "?")

    status_str = "RUNNING" if res.get("running") else "STOPPED"
    print(f"XC Service Status: {status_str} (PID: {res.get('pid', 'None')}, Uptime: {res.get('uptime_seconds', 0)}s)")
    print(f"Current Node:     #{node_id} [{node_type}] {node_name}")
    print(f"SOCKS5 Proxy:     0.0.0.0:{res.get('socks_port', 7890)}")
    print(f"HTTP Proxy:       0.0.0.0:{res.get('http_port', 10809)}")
    print(f"Web Dashboard:    http://0.0.0.0:{res.get('web_port', 7891)}")


def cmd_current():
    res = api_call("/status")
    if res and res.get("current_node"):
        c = res["current_node"]
        print(f"#{c.get('id')} [{c.get('type')}] {c.get('name')} ({c.get('server')}:{c.get('port')})")
    else:
        st, _, _, _ = fallback_storage()
        cid = st.get_current_id()
        c = st.get_node_by_id(cid)
        if c:
            print(f"#{c.get('id')} [{c.get('type')}] {c.get('name')} ({c.get('server')}:{c.get('port')})")
        else:
            print("No current node selected")


def cmd_list():
    res = api_call("/nodes")
    current_id = None
    if res:
        nodes = res.get("nodes", [])
        current_id = res.get("current_id")
    else:
        st, _, _, _ = fallback_storage()
        nodes = st.get_nodes()
        current_id = st.get_current_id()

    print(f"{'':2} {'ID':>3}  {'- Type -':<18} {'- Name -':<28} {'- Latency -'}")
    print("-" * 75)
    for n in nodes:
        nid = n.get("id")
        marker = "*" if nid == current_id else " "
        lat = n.get("latency")
        lat_str = f"{lat}ms" if lat is not None else "--"
        print(f"{marker:2} {nid:>3}  [{n.get('type', ''):<16}] {n.get('name', ''):<28} {lat_str}")


def cmd_switch(node_id: int):
    print(f"Switching to node #{node_id}...")
    res = api_call("/switch", method="POST", data={"id": node_id})
    if res:
        if res.get("success"):
            print(f"[OK] {res.get('message')}")
        else:
            print(f"[ERROR] {res.get('message')}")
            sys.exit(1)
    else:
        st, rt, _, _ = fallback_storage()
        ok, msg = rt.switch_node(node_id)
        if ok:
            print(f"[OK] {msg}")
        else:
            print(f"[ERROR] {msg}")
            sys.exit(1)


def cmd_rollback():
    print("Initiating rollback to previous configuration...")
    res = api_call("/rollback", method="POST")
    if res:
        if res.get("success"):
            print(f"[OK] {res.get('message')}")
        else:
            print(f"[ERROR] {res.get('message')}")
            sys.exit(1)
    else:
        _, rt, _, _ = fallback_storage()
        ok, msg = rt.rollback()
        if ok:
            print(f"[OK] {msg}")
        else:
            print(f"[ERROR] {msg}")
            sys.exit(1)


def cmd_test():
    print("Testing SOCKS5 and HTTP proxy endpoints...")
    res = api_call("/test", method="POST")
    if not res:
        _, rt, _, _ = fallback_storage()
        res = rt.test_ports()

    s_status = res.get("socks_status", "fail")
    h_status = res.get("http_status", "fail")
    s_port = res.get("socks_port", 7890)
    h_port = res.get("http_port", 10809)
    print(f"socks:{s_port} = {s_status.upper()}")
    print(f"http:{h_port}  = {h_status.upper()}")


def cmd_probe(arg: str = "all"):
    if arg.isdigit():
        target_id = int(arg)
        print(f"Probing node #{target_id}...")
        res = api_call("/probe", method="POST", data={"id": target_id})
        if res and res.get("nodes"):
            node = res["nodes"][0]
            lat = node.get("latency")
            lat_str = f"{lat}ms" if lat is not None else "FAIL"
            print(f"Node #{target_id} [{node.get('name')}]: {lat_str}")
        else:
            st, rt, _, probe_single = fallback_storage()
            n = st.get_node_by_id(target_id)
            if not n:
                print(f"Node #{target_id} not found")
                return
            result = probe_single(n, st.get_settings(), rt.xray_bin)
            lat = result.get("latency")
            lat_str = f"{lat}ms" if lat is not None else "FAIL"
            print(f"Node #{target_id} [{result.get('name')}]: {lat_str}")
    else:
        print("Probing all nodes latency concurrently...")
        res = api_call("/probe", method="POST", data={"all": True})
        nodes = res.get("nodes", []) if res else []
        if not nodes:
            st, rt, probe_all, _ = fallback_storage()
            nodes = probe_all(st.get_nodes(), st.get_settings(), rt.xray_bin)

        for n in nodes:
            lat = n.get("latency")
            lat_str = f"{lat}ms" if lat is not None else "FAIL"
            print(f"  #{n.get('id'):>2} {n.get('name'):<26} : {lat_str}")


def print_help():
    print("""xc - Xray Node & Routing Switcher CLI (Linux Docker Edition)

Usage:
  xc status              Output service running status and current node
  xc list                List all available nodes and latency
  xc <id>                Quick switch to node by ID (e.g. xc 1)
  xc switch <id>         Switch outbound to specified node
  xc current             Display currently active node details
  xc probe [id|all]      Test node latency (default: all nodes)
  xc test                Test SOCKS5 & HTTP inbound connectivity
  xc rollback            Rollback to previous working configuration
  xc help                Display this help message
""")


def main():
    if len(sys.argv) < 2:
        cmd_status()
        return

    arg1 = sys.argv[1].lower()

    if arg1 in ("-h", "--help", "help"):
        print_help()
    elif arg1 in ("status", "info"):
        cmd_status()
    elif arg1 in ("list", "ls"):
        cmd_list()
    elif arg1 == "current":
        cmd_current()
    elif arg1 == "rollback":
        cmd_rollback()
    elif arg1 == "test":
        cmd_test()
    elif arg1 == "probe":
        arg2 = sys.argv[2] if len(sys.argv) > 2 else "all"
        cmd_probe(arg2)
    elif arg1 == "switch":
        if len(sys.argv) < 3 or not sys.argv[2].isdigit():
            print("Error: Please specify valid node ID. Usage: xc switch <id>")
            sys.exit(1)
        cmd_switch(int(sys.argv[2]))
    elif arg1.isdigit():
        cmd_switch(int(arg1))
    else:
        print(f"Unknown command: {arg1}")
        print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
