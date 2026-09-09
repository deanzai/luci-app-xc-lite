#!/bin/bash
# ==============================================================================
# luci-app-xc-lite 先验后发质量门禁发布脚本 (release.sh)
#
# 严格流水线:
#   1. 本地代码与安全规范静态自测 (verify.sh --local) -> 失败即阻断
#   2. 自动构建编译 IPK 安装包 (build.sh)
#   3. 单机预发布部署至 Staging 验证机 (192.168.6.1)
#   4. 触发真机全自动化回归验收 (verify.sh --staging) -> 失败即阻断
#   5. 同步部署至生产路由器 (192.168.93.94, 192.168.13.1)
# ==============================================================================
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ROUTER_PASS="ljx@0931"
STAGING_ROUTER="192.168.6.1"
PROD_ROUTERS=("192.168.93.94" "192.168.13.1")

step() {
    echo -e "\n${BOLD}${CYAN}>>> [步骤 $1] $2${NC}"
}

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BOLD}       luci-app-xc-lite 先验后发质量门禁发布流水线 (Release Pipeline)         ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

# ------------------------------------------------------------------------------
# 步骤 1: 强制前置本地自测
# ------------------------------------------------------------------------------
step "1/5" "执行本地规范、语法与沙箱接口自检 (Pre-flight Local Verification)"
if ./scripts/verify.sh --local; then
    echo -e "${GREEN}✓ 本地全项自检通过，允许进入构建打包阶段。${NC}"
else
    echo -e "${RED}✗ 本地自测失败！发布流程已被安全门禁拦截，禁止打包与发布。${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 步骤 2: 编译打包最新安装包
# ------------------------------------------------------------------------------
step "2/5" "编译生成 OpenWrt IPK 与 APK 安装包 (Building Packages)"
bash build.sh

# 获取最新编译生成的 IPK 文件
IPK_PATH=$(ls -t "$PROJECT_DIR"/luci-app-xc_*_all.ipk 2>/dev/null | head -n 1)
if [ ! -f "$IPK_PATH" ]; then
    echo -e "${RED}✗ 未找到编译生成的 IPK 安装包文件！${NC}"
    exit 1
fi
IPK_NAME=$(basename "$IPK_PATH")
echo -e "${GREEN}✓ 最新安装包已就绪: ${BOLD}${IPK_NAME}${NC}"

# ------------------------------------------------------------------------------
# 步骤 3: 仅预发布部署至 Staging 预发布机
# ------------------------------------------------------------------------------
step "3/5" "单机灰度预发布至 Staging 验证机 (${STAGING_ROUTER})"
echo "推送 ${IPK_NAME} 到 ${STAGING_ROUTER}:/tmp/ ..."
sshpass -p "$ROUTER_PASS" scp -o StrictHostKeyChecking=no "$IPK_PATH" "root@${STAGING_ROUTER}:/tmp/"

echo "在 ${STAGING_ROUTER} 执行强制重装并刷新服务..."
sshpass -p "$ROUTER_PASS" ssh -o StrictHostKeyChecking=no "root@${STAGING_ROUTER}" \
    "opkg install --force-reinstall /tmp/${IPK_NAME} && rm -rf /tmp/luci-indexcache /tmp/luci-modulecache* && /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart"
echo -e "${GREEN}✓ Staging 路由器 ${STAGING_ROUTER} 部署安装完毕。${NC}"

# ------------------------------------------------------------------------------
# 步骤 4: 触发真机全自动化回归验收
# ------------------------------------------------------------------------------
step "4/5" "对 Staging 验证机执行真机功能全量验收 (Live Regression Gate)"
sleep 1
if ./scripts/verify.sh --staging; then
    echo -e "${GREEN}✓ Staging 真机回归验收全部通过！质量门禁放行，允许同步至生产环境。${NC}"
else
    echo -e "${RED}✗ Staging 真机回归验收失败！质量门禁紧急拦截，禁止向生产机发布！${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 步骤 5: 同步发布至生产环境路由器
# ------------------------------------------------------------------------------
step "5/5" "全量同步部署至生产环境路由器 (${PROD_ROUTERS[*]})"
for router in "${PROD_ROUTERS[@]}"; do
    echo -e "\n  ${YELLOW}--> 同步发布至生产机: ${router}${NC}"
    ssh_opts="-o StrictHostKeyChecking=no"
    if [ "$router" = "192.168.93.94" ]; then
        ssh_opts="$ssh_opts -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"
    fi

    echo "      推送 ${IPK_NAME} ..."
    sshpass -p "$ROUTER_PASS" scp $ssh_opts "$IPK_PATH" "root@${router}:/tmp/"

    echo "      执行安装并刷新缓存..."
    sshpass -p "$ROUTER_PASS" ssh $ssh_opts "root@${router}" \
        "opkg install --force-reinstall /tmp/${IPK_NAME} && rm -rf /tmp/luci-indexcache /tmp/luci-modulecache* && /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart"

    echo "      验证生产机 ${router} 控制器序列化与 index 就绪..."
    sshpass -p "$ROUTER_PASS" ssh $ssh_opts "root@${router}" \
        "lua -e 'local c = require \"luci.controller.xc\"; local f = loadstring(string.dump(c.index)); local scope = setmetatable({}, {__index = {entry = function() return {} end, template = function() return function() end end, call = function() return function() end end, _ = function(s) return s end, require = require}}); setfenv(f, scope); f()'"
    echo -e "      ${GREEN}✓ 生产机 ${router} 同步发布与质量验证完成${NC}"
done

echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${BOLD}${GREEN}🎉 发布流水线全部成功完成！安装包版本: ${IPK_NAME}${NC}"
echo -e "已通过两道严密质量门禁："
echo -e "  [Gate 1] 本地代码规范、Lua 语法编译与沙箱测试通过"
echo -e "  [Gate 2] Staging 预发布机 (${STAGING_ROUTER}) 真实网络探针与页面防遮挡回归通过"
echo -e "已全量同步到设备: ${STAGING_ROUTER}, ${PROD_ROUTERS[*]}"
echo -e "${GREEN}==============================================================================${NC}\n"
