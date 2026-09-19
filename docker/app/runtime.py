import os
import time
import json
import socket
import logging
import subprocess
import threading
from typing import Dict, Any, List, Optional, Tuple

from storage import Storage
from generator import generate_xray_config

logger = logging.getLogger("xc.runtime")


class RuntimeManager:
    def __init__(self, storage: Storage):
        self.storage = storage
        self.process: Optional[subprocess.Popen] = None
        self.start_time: Optional[float] = None
        self.lock = threading.RLock()
        self.xray_bin = self.find_xray_binary()
        self.asset_dir = self.find_asset_dir()
        logger.info(f"Using Xray binary: {self.xray_bin}, asset dir: {self.asset_dir}")

    def find_xray_binary(self) -> Optional[str]:
        # Priority 1: Custom binary in data_dir/bin/xray
        custom = os.path.join(self.storage.data_dir, "bin", "xray")
        if os.path.isfile(custom) and os.access(custom, os.X_OK):
            return custom

        # Priority 2: System binaries
        for path in ["/usr/local/bin/xray", "/usr/bin/xray"]:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path

        # Priority 3: In PATH
        try:
            res = subprocess.run(["which", "xray"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if res.returncode == 0:
                p = res.stdout.strip()
                if os.path.isfile(p):
                    return p
        except Exception:
            pass

        return None

    def find_asset_dir(self) -> Optional[str]:
        # Priority 1: Custom assets in data_dir/assets
        custom = os.path.join(self.storage.data_dir, "assets")
        if os.path.exists(os.path.join(custom, "geosite.dat")) and os.path.exists(os.path.join(custom, "geoip.dat")):
            return custom

        # Priority 2: System directories
        for d in ["/usr/local/share/xray", "/usr/share/xray", "/usr/share/v2ray"]:
            if os.path.exists(os.path.join(d, "geosite.dat")) and os.path.exists(os.path.join(d, "geoip.dat")):
                return d

        return None

    def is_running(self) -> bool:
        with self.lock:
            if self.process is not None:
                if self.process.poll() is None:
                    return True
                self.process = None
            return False

    def test_config_file(self, config_path: str) -> Tuple[bool, str]:
        if not self.xray_bin:
            return True, "xray binary not found, skipping syntax test"
        try:
            env = os.environ.copy()
            if self.asset_dir:
                env["XRAY_LOCATION_ASSET"] = self.asset_dir

            cmd = [self.xray_bin, "run", "-test", "-c", config_path]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10, env=env)
            if res.returncode == 0:
                return True, "Configuration test passed"
            err = (res.stderr or res.stdout or "Syntax error").strip()
            return False, err
        except Exception as e:
            return False, str(e)

    def generate_active_config(self, node_id: Optional[int] = None) -> Tuple[bool, str]:
        settings = self.storage.get_settings()
        nodes_data = self.storage.get_nodes_data()

        cid = node_id or self.storage.get_current_id()
        active_node = self.storage.get_node_by_id(cid)
        if not active_node:
            nodes = self.storage.get_nodes()
            if nodes:
                active_node = nodes[0]
                cid = active_node.get("id", 1)
            else:
                return False, "No nodes configured"

        config_obj = generate_xray_config(settings, nodes_data, active_node)
        new_tmp = self.storage.config_file + ".new"
        with open(new_tmp, "w", encoding="utf-8") as f:
            json.dump(config_obj, f, indent=2, ensure_ascii=False)

        ok, msg = self.test_config_file(new_tmp)
        if not ok:
            if os.path.exists(new_tmp):
                os.remove(new_tmp)
            return False, f"Xray configuration validation failed: {msg}"

        os.replace(new_tmp, self.storage.config_file)
        self.storage.set_current_id(cid)
        return True, "Config generated successfully"

    def start(self) -> Tuple[bool, str]:
        with self.lock:
            if self.is_running():
                return True, "Already running"

            if not os.path.exists(self.storage.config_file):
                ok, err = self.generate_active_config()
                if not ok:
                    return False, err

            if not self.xray_bin:
                return False, "xray binary not installed"

            env = os.environ.copy()
            if self.asset_dir:
                env["XRAY_LOCATION_ASSET"] = self.asset_dir

            cmd = [self.xray_bin, "run", "-c", self.storage.config_file]
            try:
                self.process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    env=env
                )
                self.start_time = time.time()
                time.sleep(0.5)
                if self.process.poll() is not None:
                    out = self.process.stdout.read() if self.process.stdout else "Process exited immediately"
                    return False, f"Failed to start Xray: {out}"
                return True, "Started Xray process"
            except Exception as e:
                return False, f"Execution failed: {e}"

    def stop(self):
        with self.lock:
            if self.process:
                try:
                    self.process.terminate()
                    self.process.wait(timeout=2)
                except Exception:
                    try:
                        self.process.kill()
                    except Exception:
                        pass
                self.process = None
                self.start_time = None

    def restart(self) -> Tuple[bool, str]:
        with self.lock:
            self.stop()
            return self.start()

    def check_health(self, timeout_sec: int = 15) -> bool:
        settings = self.storage.get_settings()
        proxy_host = settings.get("proxy_host", "127.0.0.1")
        socks_port = int(settings.get("socks_port", 7890))
        health_url = settings.get("health_url", "http://www.gstatic.com/generate_204")

        start = time.time()
        while time.time() - start < timeout_sec:
            # First check if port is open
            try:
                with socket.create_connection((proxy_host, socks_port), timeout=1):
                    pass
            except Exception:
                time.sleep(0.5)
                continue

            # Second test actual proxy connection via curl
            try:
                cmd = [
                    "curl", "--silent", "--show-error",
                    "--max-time", "3",
                    "-o", "/dev/null",
                    "--proxy", f"socks5h://{proxy_host}:{socks_port}",
                    health_url
                ]
                res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)
                if res.returncode == 0:
                    return True
            except Exception:
                pass
            time.sleep(0.5)

        return False

    def switch_node(self, node_id: int) -> Tuple[bool, str]:
        with self.lock:
            node = self.storage.get_node_by_id(node_id)
            if not node:
                return False, f"Node with ID {node_id} not found"

            # 1. Backup runtime state
            self.storage.backup_runtime_state()

            # 2. Generate and test new config
            ok, err = self.generate_active_config(node_id)
            if not ok:
                return False, err

            # 3. Restart process with new config
            ok, err = self.restart()
            if not ok:
                self.rollback()
                return False, f"Restart failed: {err}; rolled back"

            # 4. Check health
            if not self.check_health(timeout_sec=15):
                logger.warning("Health check failed after switch, initiating rollback...")
                self.rollback()
                return False, "Health check failed after switch; rolled back to previous node"

            return True, f"Successfully switched to node #{node_id} ({node.get('name')})"

    def rollback(self) -> Tuple[bool, str]:
        with self.lock:
            if not self.storage.rollback_runtime_state():
                return False, "No previous configuration state available to rollback"

            ok, err = self.restart()
            if not ok:
                return False, f"Failed to restart service during rollback: {err}"

            prev_id = self.storage.get_current_id()
            return True, f"Successfully rolled back to node #{prev_id}"

    def test_ports(self) -> Dict[str, Any]:
        settings = self.storage.get_settings()
        proxy_host = settings.get("proxy_host", "127.0.0.1")
        socks_port = int(settings.get("socks_port", 7890))
        http_port = int(settings.get("http_port", 10809))
        health_url = settings.get("health_url", "http://www.gstatic.com/generate_204")

        socks_ok = False
        http_ok = False

        # Test SOCKS5
        try:
            cmd = [
                "curl", "--silent", "--show-error",
                "--max-time", "5",
                "-o", "/dev/null",
                "--proxy", f"socks5h://{proxy_host}:{socks_port}",
                health_url
            ]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=6)
            socks_ok = (res.returncode == 0)
        except Exception:
            socks_ok = False

        # Test HTTP
        try:
            cmd = [
                "curl", "--silent", "--show-error",
                "--max-time", "5",
                "-o", "/dev/null",
                "--proxy", f"http://{proxy_host}:{http_port}",
                health_url
            ]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=6)
            http_ok = (res.returncode == 0)
        except Exception:
            http_ok = False

        return {
            "socks_port": socks_port,
            "socks_status": "ok" if socks_ok else "fail",
            "http_port": http_port,
            "http_status": "ok" if http_ok else "fail"
        }

    def get_status(self) -> Dict[str, Any]:
        running = self.is_running()
        current_id = self.storage.get_current_id()
        current_node = self.storage.get_node_by_id(current_id)

        uptime = 0
        pid = None
        if running and self.process:
            pid = self.process.pid
            if self.start_time:
                uptime = int(time.time() - self.start_time)

        settings = self.storage.get_settings()

        return {
            "running": running,
            "pid": pid,
            "uptime_seconds": uptime,
            "current_id": current_id,
            "current_node": current_node,
            "socks_port": int(settings.get("socks_port", 7890)),
            "http_port": int(settings.get("http_port", 10809)),
            "web_port": int(settings.get("web_port", 7891)),
            "xray_bin": self.xray_bin,
            "asset_dir": self.asset_dir
        }
