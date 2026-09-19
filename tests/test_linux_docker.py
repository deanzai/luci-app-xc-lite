import os
import sys
import json
import shutil
import tempfile
import unittest

# Add docker/app to sys.path
APP_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "docker", "app"))
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from storage import Storage
from generator import generate_xray_config, build_outbound
from importer import parse_vless, parse_vmess, parse_trojan, parse_shadowsocks, parse_socks, import_nodes_from_text


class TestXCStorage(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="xc_test_")
        self.storage = Storage(data_dir=self.test_dir)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_init_defaults(self):
        settings = self.storage.get_settings()
        self.assertEqual(settings.get("socks_port"), 7890)
        self.assertEqual(settings.get("http_port"), 10809)

        nodes = self.storage.get_nodes()
        self.assertTrue(len(nodes) >= 1)
        self.assertEqual(nodes[0].get("id"), 1)

    def test_update_and_current(self):
        self.storage.set_current_id(42)
        self.assertEqual(self.storage.get_current_id(), 42)

        self.storage.backup_runtime_state()
        self.storage.set_current_id(99)
        self.assertEqual(self.storage.get_current_id(), 99)

        self.storage.rollback_runtime_state()
        self.assertEqual(self.storage.get_current_id(), 42)


class TestXCImporter(unittest.TestCase):
    def test_parse_vless_reality(self):
        uri = "vless://00000000-0000-0000-0000-000000000000@1.2.3.4:443?security=reality&sni=test.com&pbk=synthetic-pbk&sid=a1b2&fp=chrome&flow=xtls-rprx-vision#MyNode"
        node = parse_vless(uri)
        self.assertIsNotNone(node)
        self.assertEqual(node["name"], "MyNode")
        self.assertEqual(node["server"], "1.2.3.4")
        self.assertEqual(node["port"], 443)
        self.assertEqual(node["type"], "VLESS REALITY")
        self.assertEqual(node["public_key"], "synthetic-pbk")
        self.assertEqual(node["short_id"], "a1b2")
        self.assertEqual(node["flow"], "xtls-rprx-vision")

    def test_parse_trojan(self):
        uri = "trojan://mypassword@example.com:443?sni=example.com#TrojanNode"
        node = parse_trojan(uri)
        self.assertIsNotNone(node)
        self.assertEqual(node["name"], "TrojanNode")
        self.assertEqual(node["server"], "example.com")
        self.assertEqual(node["password"], "mypassword")
        self.assertEqual(node["type"], "Trojan")

    def test_batch_import(self):
        text = """
vless://00000000-0000-0000-0000-000000000000@1.2.3.4:443?security=reality&sni=test.com&pbk=key&sid=123#Node1
trojan://pass@trojan.com:443#Node2
socks5://user:pass@127.0.0.1:1080#LocalSocks
"""
        imported = import_nodes_from_text(text, start_id=10)
        self.assertEqual(len(imported), 3)
        self.assertEqual(imported[0]["id"], 10)
        self.assertEqual(imported[1]["id"], 11)
        self.assertEqual(imported[2]["id"], 12)
        self.assertEqual(imported[2]["type"], "NaiveProxy SOCKS5")


class TestXCGenerator(unittest.TestCase):
    def test_generate_config(self):
        settings = {
            "listen_host": "0.0.0.0",
            "socks_port": 7890,
            "http_port": 10809,
            "log_level": "warning"
        }
        nodes_data = {
            "version": 1,
            "fixed_proxy_id": 1,
            "nodes": [
                {
                    "id": 1,
                    "name": "node-1",
                    "type": "VLESS REALITY",
                    "server": "1.1.1.1",
                    "port": 443,
                    "uuid": "00000000-0000-0000-0000-000000000000",
                    "sni": "test.com",
                    "public_key": "pubkey",
                    "short_id": "sid"
                }
            ]
        }
        active_node = nodes_data["nodes"][0]

        cfg = generate_xray_config(settings, nodes_data, active_node)

        # Verify inbounds
        inbound_tags = [ib["tag"] for ib in cfg["inbounds"]]
        self.assertIn("socks-in", inbound_tags)
        self.assertIn("http-in", inbound_tags)
        self.assertIn("socks-in-loopback", inbound_tags)
        self.assertIn("http-in-loopback", inbound_tags)

        # Verify outbounds
        outbound_tags = [ob["tag"] for ob in cfg["outbounds"]]
        self.assertIn("proxy-selected", outbound_tags)
        self.assertIn("proxy", outbound_tags)
        self.assertIn("direct", outbound_tags)
        self.assertIn("block", outbound_tags)

        # Verify routing
        self.assertEqual(cfg["routing"]["domainStrategy"], "IPIfNonMatch")
        self.assertTrue(len(cfg["routing"]["rules"]) > 5)

        # Verify DNS
        self.assertTrue(len(cfg["dns"]["servers"]) >= 3)


class TestXCAPIServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import threading
        from http.server import ThreadingHTTPServer
        import main as srv_main

        cls.test_dir = tempfile.mkdtemp(prefix="xc_api_test_")
        cls.storage = Storage(data_dir=cls.test_dir)
        cls.runtime = srv_main.RuntimeManager(cls.storage)
        srv_main.storage = cls.storage
        srv_main.runtime = cls.runtime

        cls.port = 17891
        cls.server = ThreadingHTTPServer(("127.0.0.1", cls.port), srv_main.XCRequestHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.test_dir, ignore_errors=True)

    def test_api_status_and_nodes(self):
        import urllib.request
        base = f"http://127.0.0.1:{self.port}/api"

        # 1. GET /api/status
        with urllib.request.urlopen(f"{base}/status") as resp:
            data = json.loads(resp.read().decode())
            self.assertIn("version", data)
            self.assertEqual(data["socks_port"], 7890)

        # 2. GET /api/nodes
        with urllib.request.urlopen(f"{base}/nodes") as resp:
            data = json.loads(resp.read().decode())
            self.assertTrue(len(data["nodes"]) >= 1)

        # 3. POST /api/nodes (import)
        req = urllib.request.Request(
            f"{base}/nodes",
            data=json.dumps({"raw": "trojan://pass@example.com:443#TrojanNode"}).encode(),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            self.assertTrue(data["success"])
            self.assertEqual(data["count"], 1)

        # 4. GET /api/settings
        with urllib.request.urlopen(f"{base}/settings") as resp:
            data = json.loads(resp.read().decode())
            self.assertEqual(data["log_level"], "warning")


if __name__ == "__main__":
    unittest.main()

