import unittest
import re
from pathlib import Path
from docker.app.generator import generate_xray_config

REPO_ROOT = Path(__file__).resolve().parent.parent

class TestSplitDNSConfiguration(unittest.TestCase):
    def setUp(self):
        self.xc_bin_path = REPO_ROOT / "root" / "usr" / "bin" / "xc"
        self.xc_bin_content = self.xc_bin_path.read_text(encoding="utf-8")

    def test_xc_bin_static_split_dns_syntax(self):
        """Verify root/usr/bin/xc contains dual split DNS and IPIfNonMatch strategy."""
        # 1. Verify domainStrategy is IPIfNonMatch
        self.assertIn('domainStrategy = "IPIfNonMatch"', self.xc_bin_content)
        self.assertNotIn('domainStrategy = "AsIs"', self.xc_bin_content)

        # 2. Verify domestic DNS server
        self.assertIn('address = "223.5.5.5"', self.xc_bin_content)
        self.assertIn('"geosite:cn"', self.xc_bin_content)
        self.assertIn('"geoip:cn"', self.xc_bin_content)

        # 3. Verify foreign DoH server acts as global fallback
        self.assertIn('address = "https://1.1.1.1/dns-query"', self.xc_bin_content)
        self.assertIn('tag = "dns-proxy"', self.xc_bin_content)
        self.assertIn('skipFallback = false', self.xc_bin_content)
        self.assertNotIn('"localhost"', self.xc_bin_content)

        # 4. Verify routing rules for DNS separation
        self.assertIn('ip = {"223.5.5.5", "119.29.29.29"}', self.xc_bin_content)
        self.assertIn('outboundTag = "direct"', self.xc_bin_content)
        self.assertIn('inboundTag = {"dns-proxy"}, outboundTag = "proxy-selected"', self.xc_bin_content)

        # 5. Verify rule order: geosite:cn before geoip:cn
        idx_geosite_cn = self.xc_bin_content.find('domain = {"geosite:cn"}')
        idx_geoip_cn = self.xc_bin_content.find('ip = {"geoip:cn"}')
        self.assertNotEqual(idx_geosite_cn, -1)
        self.assertNotEqual(idx_geoip_cn, -1)
        self.assertLess(idx_geosite_cn, idx_geoip_cn, "geosite:cn must precede geoip:cn in routing rules")

    def test_runtime_generator_split_dns_structure(self):
        """Verify generate_xray_config generates the exact dual split DNS structure."""
        settings = {
            "socks_port": 7890,
            "http_port": 10809,
            "log_level": "warning",
            "fixed_proxy_id": "2"
        }
        nodes_data = {
            "nodes": [
                {
                    "id": "1",
                    "type": "SOCKS5",
                    "server": "127.0.0.1",
                    "port": 45331,
                    "tag": "naive-local"
                },
                {
                    "id": "2",
                    "type": "VLESS REALITY",
                    "server": "104.224.159.174",
                    "port": 443,
                    "uuid": "test-uuid",
                    "flow": "xtls-rprx-vision",
                    "sni": "na95.778688.xyz",
                    "public_key": "pubkey",
                    "short_id": "sid"
                }
            ]
        }
        cfg = generate_xray_config(settings, nodes_data, nodes_data["nodes"][0])

        # Assertions on routing
        self.assertEqual(cfg["routing"]["domainStrategy"], "IPIfNonMatch")
        
        # Assertions on DNS
        dns = cfg["dns"]
        self.assertEqual(dns["queryStrategy"], "UseIPv4")
        self.assertFalse(dns["disableFallback"])
        
        servers = dns["servers"]
        self.assertEqual(len(servers), 2) # 223.5.5.5, 1.1.1.1 (foreign fallback)
        self.assertNotIn("localhost", servers)
        
        # Domestic DNS check
        s_cn = servers[0]
        self.assertEqual(s_cn["address"], "223.5.5.5")
        self.assertEqual(s_cn["port"], 53)
        self.assertIn("geosite:cn", s_cn["domains"])
        self.assertIn("geoip:cn", s_cn["expectIPs"])
        self.assertTrue(s_cn["skipFallback"])

        # Foreign DoH check (acts as global fallback)
        s_foreign = servers[1]
        self.assertEqual(s_foreign["address"], "https://1.1.1.1/dns-query")
        self.assertEqual(s_foreign["tag"], "dns-proxy")
        self.assertFalse(s_foreign["skipFallback"])
        self.assertNotIn("domains", s_foreign)


if __name__ == "__main__":
    unittest.main()
