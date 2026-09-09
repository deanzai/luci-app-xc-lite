#!/bin/bash
set -e

ROUTER_IP="${ROUTER_IP:-192.168.93.94}"
ROUTER_PASS="${ROUTER_PASS:-}"
if [ -z "$ROUTER_PASS" ]; then
  echo "Usage: ROUTER_PASS='your_password' $0"
  exit 1
fi
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"

echo "=== 1. 执行远程测试脚本 ==="
sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS root@$ROUTER_IP ROUTER_PASS="$ROUTER_PASS" 'bash -s' << 'REMOTE_SCRIPT'
set -e

echo "--- 1.1 检查系统进程与监听端口 ---"
/etc/init.d/xc-xray status || true
netstat -tulpn | grep -E 'xray|7890|10809' || true

echo "--- 1.2 检查 CLI 核心状态 ---"
xc status

echo "--- 1.3 登录 LuCI 获取 Session Cookie ---"
rm -f /tmp/luci_cookies.txt
LOGIN_HTML=$(curl -s -c /tmp/luci_cookies.txt "http://127.0.0.1/cgi-bin/luci/")
TOKEN=$(echo "$LOGIN_HTML" | grep -o 'name="token" value="[^"]*' | head -n 1 | cut -d'"' -f3)

curl -s -b /tmp/luci_cookies.txt -c /tmp/luci_cookies.txt \
  -d "luci_username=root&luci_password=${ROUTER_PASS}&token=$TOKEN" \
  "http://127.0.0.1/cgi-bin/luci/" >/dev/null

echo "Cookie 文件内容:"
cat /tmp/luci_cookies.txt

echo "--- 1.4 测试 Web 页面访问 (HTTP 200) ---"
STATUS_CODE=$(curl -s -o /tmp/xc_page.html -w "%{http_code}" -b /tmp/luci_cookies.txt "http://127.0.0.1/cgi-bin/luci/admin/services/xc")
echo "Web Page HTTP Code: $STATUS_CODE"
if [ "$STATUS_CODE" -eq 200 ]; then
  echo "Web 页面访问成功！"
  grep -o '核心组件与规则文件管理' /tmp/xc_page.html || grep -o 'cbi-map' /tmp/xc_page.html || true
else
  echo "Web 页面访问失败！"
  exit 1
fi

echo "--- 1.5 测试 Status JSON API ---"
API_STATUS=$(curl -s -b /tmp/luci_cookies.txt "http://127.0.0.1/cgi-bin/luci/admin/services/xc/status")
echo "API Response: $API_STATUS"

echo "--- 1.6 测试上传拦截：小于 1MB 的 Xray ---"
echo "toosmall" > /tmp/test_small.bin
RES_SMALL=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/tmp/test_small.bin" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload")
echo "Result: $RES_SMALL"

echo "--- 1.7 测试上传拦截：伪造 ZIP 压缩包 ---"
printf "PK\003\004padding_large_data_to_reach_over_one_megabyte" > /tmp/test_zip.bin
dd if=/dev/zero bs=1M count=1 >> /tmp/test_zip.bin 2>/dev/null
RES_ZIP=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/tmp/test_zip.bin" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload")
echo "Result: $RES_ZIP"

echo "--- 1.8 测试上传拦截：非 ELF 格式 ---"
dd if=/dev/zero of=/tmp/test_nonelf.bin bs=1M count=2 2>/dev/null
RES_NONELF=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/tmp/test_nonelf.bin" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload")
echo "Result: $RES_NONELF"

echo "--- 1.9 测试上传拦截：小于 100KB 的 geosite.dat ---"
echo "small_dat" > /tmp/test_small.dat
RES_SMALL_DAT=$(curl -s -b /tmp/luci_cookies.txt -F "type=geosite" -F "file=@/tmp/test_small.dat" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload")
echo "Result: $RES_SMALL_DAT"

echo "--- 1.10 测试上传合法 geosite.dat 并检验优先级寻址 ---"
# 生成合法的 200KB dat 文件
dd if=/dev/zero of=/tmp/test_geosite.dat bs=1k count=200 2>/dev/null
RES_UPLOAD_OK=$(curl -s -b /tmp/luci_cookies.txt -F "type=geosite" -F "file=@/tmp/test_geosite.dat" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload")
echo "Result: $RES_UPLOAD_OK"
ls -lh /etc/xc/assets/geosite.dat

echo "--- 1.11 校验 CLI status 识别到 /etc/xc/assets/geosite.dat 优先生效 ---"
xc status

echo "--- 1.12 测试通过上传合法的 ARM64 Xray 核心并校验架构兼容性 ---"
# 我们直接使用系统的真实 aarch64 xray 作为测试上传文件
RES_XRAY_REAL=$(curl -s -b /tmp/luci_cookies.txt -F "type=xray" -F "file=@/usr/bin/xray" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload")
echo "Result: $RES_XRAY_REAL"
ls -lh /etc/xc/bin/xray

echo "--- 1.13 校验 CLI status 识别到 /etc/xc/bin/xray 优先生效 ---"
xc status

echo "--- 1.14 查看系统日志 xc/xray 记录 ---"
logread | grep -E 'xc|xray' | tail -n 20

# 清理测试临时文件
rm -f /tmp/test_*.bin /tmp/test_*.dat /tmp/luci_cookies.txt /tmp/xc_page.html

echo "=== 所有远程测试成功执行！ ==="
REMOTE_SCRIPT
