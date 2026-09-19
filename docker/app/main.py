import os
import sys
import json
import signal
import logging
import mimetypes
from urllib.parse import urlparse, parse_qs
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from typing import Dict, Any, Optional

from storage import Storage
from runtime import RuntimeManager
from probe import probe_all_nodes, probe_single_node
from importer import import_nodes_from_text

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("xc.server")

# Global managers
storage = Storage()
runtime = RuntimeManager(storage)
cached_latencies: Dict[int, int] = {}
recent_logs: list = []


def log_event(msg: str):
    logger.info(msg)
    recent_logs.append(msg)
    if len(recent_logs) > 200:
        recent_logs.pop(0)


class XCRequestHandler(BaseHTTPRequestHandler):
    server_version = "XC-Server/1.0"

    def log_message(self, format, *args):
        # Silence routine static request logging, keep API logs clean
        if "/api/" in args[0]:
            logger.debug(f"{self.client_address[0]} - {format % args}")

    def send_json(self, data: Any, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self) -> Dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0:
                return {}
            raw = self.wfile.read(length) if hasattr(self, "wfile_read") else self.rfile.read(length)
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/status":
            st = runtime.get_status()
            st["version"] = "1.0.18-docker"
            self.send_json(st)
            return

        if path == "/api/nodes":
            nodes_data = storage.get_nodes_data()
            nodes = nodes_data.get("nodes", [])
            for n in nodes:
                nid = n.get("id")
                if nid in cached_latencies:
                    n["latency"] = cached_latencies[nid]
            self.send_json({
                "nodes": nodes,
                "current_id": storage.get_current_id(),
                "fixed_proxy_id": nodes_data.get("fixed_proxy_id", 1)
            })
            return

        if path == "/api/settings":
            self.send_json(storage.get_settings())
            return

        if path == "/api/logs":
            self.send_json({"logs": recent_logs})
            return

        # Static files
        self.serve_static(path)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/switch":
            body = self.read_json_body()
            target_id = body.get("id")
            if not target_id:
                self.send_json({"success": False, "message": "Missing node id"}, status=400)
                return
            ok, msg = runtime.switch_node(int(target_id))
            log_event(f"Switch node #{target_id}: {msg}")
            self.send_json({"success": ok, "message": msg, "current_id": storage.get_current_id()})
            return

        if path == "/api/rollback":
            ok, msg = runtime.rollback()
            log_event(f"Rollback: {msg}")
            self.send_json({"success": ok, "message": msg, "current_id": storage.get_current_id()})
            return

        if path == "/api/test":
            res = runtime.test_ports()
            self.send_json(res)
            return

        if path == "/api/probe":
            body = self.read_json_body()
            nodes = storage.get_nodes()
            settings = storage.get_settings()
            target_id = body.get("id")

            if target_id is not None:
                node = storage.get_node_by_id(int(target_id))
                if not node:
                    self.send_json({"success": False, "message": "Node not found"}, status=404)
                    return
                res = probe_single_node(node, settings, runtime.xray_bin)
                lat = res.get("latency")
                if lat is not None:
                    cached_latencies[int(target_id)] = lat
                self.send_json({"success": True, "nodes": [res]})
            else:
                results = probe_all_nodes(nodes, settings, runtime.xray_bin)
                for r in results:
                    nid = r.get("id")
                    lat = r.get("latency")
                    if lat is not None and nid is not None:
                        cached_latencies[nid] = lat
                self.send_json({"success": True, "nodes": results})
            return

        if path == "/api/nodes":
            body = self.read_json_body()
            raw_text = body.get("raw")
            nodes_data = storage.get_nodes_data()
            existing_nodes = nodes_data.get("nodes", [])

            max_id = max([n.get("id", 0) for n in existing_nodes], default=0)

            if raw_text:
                imported = import_nodes_from_text(raw_text, start_id=max_id + 1)
                if not imported:
                    self.send_json({"success": False, "message": "No valid nodes parsed"}, status=400)
                    return
                existing_nodes.extend(imported)
                nodes_data["nodes"] = existing_nodes
                storage.save_nodes_data(nodes_data)
                log_event(f"Imported {len(imported)} nodes")
                self.send_json({"success": True, "count": len(imported), "nodes": imported})
            elif "server" in body:
                body["id"] = max_id + 1
                existing_nodes.append(body)
                nodes_data["nodes"] = existing_nodes
                storage.save_nodes_data(nodes_data)
                log_event(f"Added node #{body['id']} {body.get('name')}")
                self.send_json({"success": True, "node": body})
            else:
                self.send_json({"success": False, "message": "Invalid request body"}, status=400)
            return

        if path == "/api/settings":
            body = self.read_json_body()
            cur = storage.get_settings()
            cur.update(body)
            storage.save_settings(cur)
            log_event("Settings updated, reloading Xray...")
            runtime.generate_active_config()
            runtime.restart()
            self.send_json({"success": True, "settings": cur})
            return

        if path == "/api/restart":
            ok, msg = runtime.restart()
            self.send_json({"success": ok, "message": msg})
            return

        self.send_json({"error": "Not Found"}, status=404)

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/nodes/"):
            node_id_str = path[len("/api/nodes/"):]
            if node_id_str.isdigit():
                nid = int(node_id_str)
                body = self.read_json_body()
                nodes_data = storage.get_nodes_data()
                nodes = nodes_data.get("nodes", [])
                found = False
                for i, n in enumerate(nodes):
                    if n.get("id") == nid:
                        body["id"] = nid
                        nodes[i] = body
                        found = True
                        break
                if found:
                    nodes_data["nodes"] = nodes
                    storage.save_nodes_data(nodes_data)
                    # If edited active node, reload config
                    if nid == storage.get_current_id():
                        runtime.generate_active_config()
                        runtime.restart()
                    self.send_json({"success": True, "node": body})
                else:
                    self.send_json({"success": False, "message": "Node not found"}, status=404)
                return

        self.send_json({"error": "Not Found"}, status=404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/nodes/"):
            node_id_str = path[len("/api/nodes/"):]
            if node_id_str.isdigit():
                nid = int(node_id_str)
                nodes_data = storage.get_nodes_data()
                nodes = nodes_data.get("nodes", [])
                orig_len = len(nodes)
                nodes = [n for n in nodes if n.get("id") != nid]
                if len(nodes) < orig_len:
                    nodes_data["nodes"] = nodes
                    storage.save_nodes_data(nodes_data)
                    log_event(f"Deleted node #{nid}")
                    # If deleted active node, switch to first available
                    if nid == storage.get_current_id() and nodes:
                        runtime.switch_node(nodes[0]["id"])
                    self.send_json({"success": True, "message": f"Deleted node #{nid}"})
                else:
                    self.send_json({"success": False, "message": "Node not found"}, status=404)
                return

        self.send_json({"error": "Not Found"}, status=404)

    def serve_static(self, path: str):
        static_dir = os.path.join(os.path.dirname(__file__), "static")
        if path in ("/", ""):
            filename = "index.html"
        else:
            filename = path.lstrip("/")
            if filename.startswith("static/"):
                filename = filename[len("static/"):]

        filepath = os.path.abspath(os.path.join(static_dir, filename))
        # Prevent directory traversal
        if not filepath.startswith(static_dir) or not os.path.isfile(filepath):
            # Fallback to index.html for SPA
            filepath = os.path.join(static_dir, "index.html")

        if not os.path.exists(filepath):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Static asset not found")
            return

        mime_type, _ = mimetypes.guess_type(filepath)
        if not mime_type:
            mime_type = "application/octet-stream"

        try:
            with open(filepath, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", mime_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode("utf-8"))


def main():
    settings = storage.get_settings()
    web_port = int(settings.get("web_port", 7891))
    listen_host = settings.get("listen_host", "0.0.0.0")

    log_event(f"Starting XC Linux Service...")
    log_event(f"Data directory: {storage.data_dir}")

    # Launch Xray runtime
    ok, msg = runtime.start()
    if ok:
        log_event(f"Xray core initialized: {msg}")
    else:
        logger.warning(f"Xray core startup warning: {msg}")

    # Handle termination signals
    def handle_signal(sig, frame):
        log_event("Received shutdown signal, terminating Xray...")
        runtime.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    server = ThreadingHTTPServer((listen_host, web_port), XCRequestHandler)
    log_event(f"Web Dashboard listening on http://{listen_host}:{web_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        runtime.stop()


if __name__ == "__main__":
    main()
