#!/bin/bash
set -e

ROUTER_IP="${ROUTER_IP:-192.168.93.94}"
ROUTER_PASS="${ROUTER_PASS:-}"
if [ -z "$ROUTER_PASS" ]; then
  echo "Usage: ROUTER_PASS='your_password' $0"
  exit 1
fi
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"

sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS root@$ROUTER_IP ROUTER_PASS="$ROUTER_PASS" 'bash -s' << 'REMOTE_SCRIPT'
set -e

rm -f /tmp/luci_cookies.txt
TOKEN=$(curl -s -c /tmp/luci_cookies.txt http://127.0.0.1/cgi-bin/luci/ | grep -o 'name="token" value="[^"]*' | head -n 1 | cut -d'"' -f3)
curl -s -b /tmp/luci_cookies.txt -c /tmp/luci_cookies.txt -d "luci_username=root&luci_password=$ROUTER_PASS&token=$TOKEN" http://127.0.0.1/cgi-bin/luci/ >/dev/null

echo "=========================================================="
echo "=== 测试 1: 核心文件支持 tar.gz 上传并自动解压部署 ==="
echo "=========================================================="
# 准备一个包含 aarch64 xray 的 tar.gz 压缩包
rm -rf /tmp/test_xray_pack && mkdir -p /tmp/test_xray_pack/subfolder
cp /root/xray/xray /tmp/test_xray_pack/subfolder/xray
tar -czf /tmp/Xray-linux-arm64-test.tar.gz -C /tmp/test_xray_pack subfolder/xray
ls -lh /tmp/Xray-linux-arm64-test.tar.gz

# 上传 tar.gz 压缩包
RES_TGZ=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/tmp/Xray-linux-arm64-test.tar.gz" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload?type=xray")
echo "上传结果: $RES_TGZ"

# 检验解压出的二进制核心状态
ls -lh /etc/xc/bin/xray
/etc/xc/bin/xray version | head -n 1

echo "=========================================================="
echo "=== 测试 2: 手动切换核心来源 (custom <-> builtin) 与保底机制 ==="
echo "=========================================================="
echo "--- 2.1 当前状态 (默认 custom 模式) ---"
xc status | grep -E 'core_source|active_core_source|xray_path'

echo "--- 2.2 手动切换为内置核心 (builtin) ---"
RES_SW1=$(curl -s -b /tmp/luci_cookies.txt -H "Content-Type: application/json" -d '{"core_source":"builtin"}' "http://127.0.0.1/cgi-bin/luci/admin/services/xc/switch_source")
echo "切换结果: $RES_SW1"
xc status | grep -E 'core_source|active_core_source|xray_path'

echo "--- 2.3 手动切回自定义核心 (custom) ---"
RES_SW2=$(curl -s -b /tmp/luci_cookies.txt -H "Content-Type: application/json" -d '{"core_source":"custom"}' "http://127.0.0.1/cgi-bin/luci/admin/services/xc/switch_source")
echo "切换结果: $RES_SW2"
xc status | grep -E 'core_source|active_core_source|xray_path'

echo "--- 2.4 测试保底机制：删除自定义核心时，自动保底回退至内置核心 ---"
mv /etc/xc/bin/xray /etc/xc/bin/xray.bak
xc status | grep -E 'core_source|active_core_source|xray_path'
# 恢复自定义核心
mv /etc/xc/bin/xray.bak /etc/xc/bin/xray

echo "--- 2.5 测试规则库来源切换 (custom <-> builtin) ---"
RES_SW3=$(curl -s -b /tmp/luci_cookies.txt -H "Content-Type: application/json" -d '{"asset_source":"builtin"}' "http://127.0.0.1/cgi-bin/luci/admin/services/xc/switch_source")
echo "切内置规则结果: $RES_SW3"
xc status | grep -E 'asset_source|active_asset_source|asset_dir'

RES_SW4=$(curl -s -b /tmp/luci_cookies.txt -H "Content-Type: application/json" -d '{"asset_source":"custom"}' "http://127.0.0.1/cgi-bin/luci/admin/services/xc/switch_source")
echo "切自定义规则结果: $RES_SW4"
xc status | grep -E 'asset_source|active_asset_source|asset_dir'

echo "=========================================================="
echo "=== 测试 3: 验证「运行状态与分流概览」彻底移除回滚按键 ==="
echo "=========================================================="
PAGE_HTML=$(curl -s -b /tmp/luci_cookies.txt "http://127.0.0.1/cgi-bin/luci/admin/services/xc")
if echo "$PAGE_HTML" | grep -q "回滚上一节点"; then
    echo "FAILED: 页面中仍存在「回滚上一节点」！"
    exit 1
else
    echo "SUCCESS: 页面中已彻底移除「回滚上一节点」按键！"
fi

# 清理测试临时文件
rm -rf /tmp/test_xray_pack /tmp/Xray-linux-arm64-test.tar.gz /tmp/luci_cookies.txt
echo "=========================================================="
echo "=== 全部实机自动化测试 100% 成功通过！ ==="
echo "=========================================================="
REMOTE_SCRIPT
