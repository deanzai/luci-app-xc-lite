#!/bin/bash
set -e

ROUTER_IP="${ROUTER_IP:-192.168.93.94}"
ROUTER_PASS="${ROUTER_PASS:-}"
if [ -z "$ROUTER_PASS" ]; then
  echo "Usage: ROUTER_PASS='your_password' $0"
  exit 1
fi
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"

echo "=== 1. 上传 1.0.8-1 IPK 到 192.168.93.94 ==="
sshpass -p "$ROUTER_PASS" scp $SSH_OPTS /mnt/c/Users/Administrator/.gemini/antigravity/scratch/luci-app-xc-lite/luci-app-xc_1.0.8-1_all.ipk root@$ROUTER_IP:/tmp/

echo "=== 2. 安装并测试 ZIP 格式核心上传 ==="
sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS root@$ROUTER_IP ROUTER_PASS="$ROUTER_PASS" 'bash -s' << 'REMOTE_SCRIPT'
set -e

opkg install --force-reinstall --force-overwrite /tmp/luci-app-xc_1.0.8-1_all.ipk
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "--- 生成 zip 压缩包 ---"
cat > /tmp/gen_zip.lua << 'LUA'
local nixio = require("nixio")

local function u16(val)
    return string.char(val % 256, math.floor(val / 256) % 256)
end

local function u32(val)
    local b0 = val % 256
    local b1 = math.floor(val / 256) % 256
    local b2 = math.floor(val / 65536) % 256
    local b3 = math.floor(val / 16777216) % 256
    return string.char(b0, b1, b2, b3)
end

local src = "/root/xray/xray"
local f = assert(io.open(src, "rb"))
local data = f:read("*a")
f:close()

local crc_val = 0
if nixio.bin and nixio.bin.crc32 then
    crc_val = nixio.bin.crc32(data)
end

local filename = "xray"
local fn_len = #filename
local file_len = #data

local out = assert(io.open("/tmp/Xray-arm64-test.zip", "wb"))
out:write("PK\03\04")
out:write(u16(20), u16(0), u16(0), u16(0), u16(0))
out:write(u32(crc_val), u32(file_len), u32(file_len), u16(fn_len), u16(0))
out:write(filename, data)

local c_offset = out:seek()
out:write("PK\01\02")
out:write(u16(20), u16(20), u16(0), u16(0), u16(0), u16(0))
out:write(u32(crc_val), u32(file_len), u32(file_len), u16(fn_len), u16(0), u16(0), u16(0), u16(0), u32(0), u32(0))
out:write(filename)

local c_size = out:seek() - c_offset
out:write("PK\05\06")
out:write(u16(0), u16(0), u16(1), u16(1), u32(c_size), u32(c_offset), u16(0))
out:close()
print("Created zip: " .. tostring(file_len) .. " bytes")
LUA

lua /tmp/gen_zip.lua
unzip -l /tmp/Xray-arm64-test.zip

echo "--- 登录 LuCI ---"
rm -f /tmp/cookies.txt
TOKEN=$(curl -s -c /tmp/cookies.txt http://127.0.0.1/cgi-bin/luci/ | grep -o 'name="token" value="[^"]*' | head -n 1 | cut -d'"' -f3)
curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -d "luci_username=root&luci_password=$ROUTER_PASS&token=$TOKEN" http://127.0.0.1/cgi-bin/luci/ >/dev/null

echo "--- 调用上传接口上传 ZIP 格式核心 ---"
RES=$(curl -s -b /tmp/cookies.txt -F "type=xray" -F "file=@/tmp/Xray-arm64-test.zip" "http://127.0.0.1/cgi-bin/luci/admin/services/xc/upload?type=xray")
echo "上传响应结果: $RES"

echo "--- 检查已部署的 /etc/xc/bin/xray ---"
ls -lh /etc/xc/bin/xray
/etc/xc/bin/xray version | head -n 1

echo "--- 检查核心状态 ---"
xc status | grep -E 'active_core_source|xray_path'

rm -f /tmp/gen_zip.lua /tmp/Xray-arm64-test.zip /tmp/cookies.txt
REMOTE_SCRIPT
