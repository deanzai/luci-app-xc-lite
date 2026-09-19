import os
import json
import shutil
import threading
from typing import Dict, Any, List, Optional

DEFAULT_SETTINGS = {
    "listen_host": "0.0.0.0",
    "socks_host": "0.0.0.0",
    "socks_port": 7890,
    "http_host": "0.0.0.0",
    "http_port": 10809,
    "web_port": 7891,
    "proxy_host": "127.0.0.1",
    "probe_url": "http://www.gstatic.com/generate_204",
    "health_url": "http://www.gstatic.com/generate_204",
    "probe_timeout": 5,
    "probe_concurrency": 5,
    "log_level": "warning"
}

DEFAULT_NODES = {
    "version": 1,
    "fixed_proxy_id": 1,
    "nodes": [
        {
            "id": 1,
            "name": "example-reality",
            "type": "VLESS REALITY",
            "server": "1.1.1.1",
            "port": 443,
            "uuid": "00000000-0000-0000-0000-000000000000",
            "sni": "www.microsoft.com",
            "public_key": "1111111111111111111111111111111111111111111",
            "short_id": "11111111",
            "fingerprint": "chrome",
            "flow": "xtls-rprx-vision"
        }
    ]
}


class Storage:
    def __init__(self, data_dir: Optional[str] = None):
        if data_dir:
            self.data_dir = data_dir
        else:
            self.data_dir = os.environ.get("XC_DATA_DIR", "/etc/xc")
            # If default /etc/xc is not writable (e.g. running non-root in test), fallback
            if not os.path.exists(self.data_dir):
                try:
                    os.makedirs(self.data_dir, exist_ok=True)
                except OSError:
                    self.data_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data"))
                    os.makedirs(self.data_dir, exist_ok=True)

        self.runtime_dir = os.environ.get("XC_RUNTIME_DIR", os.path.join(self.data_dir, "run"))
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(self.runtime_dir, exist_ok=True)
        os.makedirs(os.path.join(self.data_dir, "bin"), exist_ok=True)
        os.makedirs(os.path.join(self.data_dir, "assets"), exist_ok=True)

        self.nodes_file = os.path.join(self.data_dir, "nodes.json")
        self.settings_file = os.path.join(self.data_dir, "settings.json")
        self.current_file = os.path.join(self.runtime_dir, "current")
        self.config_file = os.path.join(self.runtime_dir, "config.json")
        self.prev_config_file = os.path.join(self.runtime_dir, "config.previous")
        self.prev_current_file = os.path.join(self.runtime_dir, "current.previous")

        self._lock = threading.RLock()
        self.init_defaults()

    def init_defaults(self):
        with self._lock:
            if not os.path.exists(self.settings_file):
                self.save_settings(DEFAULT_SETTINGS)
            if not os.path.exists(self.nodes_file):
                self.save_nodes_data(DEFAULT_NODES)
            if not os.path.exists(self.current_file):
                nodes_data = self.get_nodes_data()
                first_id = nodes_data.get("nodes", [{}])[0].get("id", 1)
                self.set_current_id(first_id)

    def get_settings(self) -> Dict[str, Any]:
        with self._lock:
            try:
                with open(self.settings_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    res = DEFAULT_SETTINGS.copy()
                    res.update(data)
                    return res
            except Exception:
                return DEFAULT_SETTINGS.copy()

    def save_settings(self, settings: Dict[str, Any]):
        with self._lock:
            tmp = self.settings_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(settings, f, indent=2, ensure_ascii=False)
            os.replace(tmp, self.settings_file)

    def get_nodes_data(self) -> Dict[str, Any]:
        with self._lock:
            try:
                with open(self.nodes_file, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return DEFAULT_NODES.copy()

    def save_nodes_data(self, data: Dict[str, Any]):
        with self._lock:
            tmp = self.nodes_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            os.replace(tmp, self.nodes_file)

    def get_nodes(self) -> List[Dict[str, Any]]:
        return self.get_nodes_data().get("nodes", [])

    def get_node_by_id(self, node_id: int) -> Optional[Dict[str, Any]]:
        nodes = self.get_nodes()
        for n in nodes:
            if n.get("id") == node_id:
                return n
        return None

    def get_current_id(self) -> int:
        with self._lock:
            if os.path.exists(self.current_file):
                try:
                    with open(self.current_file, "r", encoding="utf-8") as f:
                        val = f.read().strip()
                        if val.isdigit():
                            return int(val)
                except Exception:
                    pass
            nodes = self.get_nodes()
            return nodes[0].get("id", 1) if nodes else 1

    def set_current_id(self, node_id: int):
        with self._lock:
            with open(self.current_file, "w", encoding="utf-8") as f:
                f.write(f"{node_id}\n")

    def backup_runtime_state(self):
        with self._lock:
            if os.path.exists(self.config_file):
                shutil.copyfile(self.config_file, self.prev_config_file)
            if os.path.exists(self.current_file):
                shutil.copyfile(self.current_file, self.prev_current_file)

    def rollback_runtime_state(self) -> bool:
        with self._lock:
            restored = False
            if os.path.exists(self.prev_config_file):
                shutil.copyfile(self.prev_config_file, self.config_file)
                restored = True
            if os.path.exists(self.prev_current_file):
                shutil.copyfile(self.prev_current_file, self.current_file)
                restored = True
            return restored

