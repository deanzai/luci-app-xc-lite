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

echo "=== 测试 1: 原先报错的路径 /upload/xray?type=xray ==="
RES1=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/root/xray/xray" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload/xray?type=xray")
echo "Result 1: $RES1"

echo "=== 测试 2: 规范路径 /upload?type=xray ==="
RES2=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/root/xray/xray" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload?type=xray")
echo "Result 2: $RES2"

echo "=== 检查 /etc/xc/bin/xray 状态 ==="
ls -lh /etc/xc/bin/xray
/etc/xc/bin/xray version | head -n 1

echo "=== 检查系统日志 ==="
logread | grep 'xc-upload' | tail -n 5

rm -f /tmp/luci_cookies.txt
REMOTE_SCRIPT
