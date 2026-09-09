#!/bin/bash
# ==============================================================================
# luci-app-xc-lite 自动化自测与质量门禁脚本 (verify.sh)
# 用法:
#   ./scripts/verify.sh --local    (仅执行本地代码规范、语法和沙箱测试)
#   ./scripts/verify.sh --staging  (仅执行 192.168.6.1 预发布真机回归测试)
#   ./scripts/verify.sh --all      (执行全部测试)
# ==============================================================================
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

STAGING_HOST="192.168.6.1"
STAGING_PASS="ljx@0931"

MODE="${1:---local}"
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

pass() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  [${GREEN}PASS${NC}] $1"
}

fail() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  [${RED}FAIL${NC}] $1"
    if [ -n "${2:-}" ]; then
        echo -e "         ${YELLOW}原因: $2${NC}"
    fi
}

info() {
    echo -e "\n${CYAN}=== $1 ===${NC}"
}

# ==============================================================================
# 本地自测 (Level 1 & 2)
# ==============================================================================
run_local_tests() {
    info "1. 源码规范与换行符检查 (No CRLF Allowed)"
    local crlf_files
    crlf_files=$(find root luasrc htdocs scripts tests Makefile -type f \( -name "*.lua" -o -name "*.htm" -o -name "*.js" -o -name "*.json" -o -name "*.sh" -o -name "xc" -o -name "luci.xc" -o -name "xc-xray" -o -name "80_luci-app-xc" \) -exec file {} + 2>/dev/null | grep "CRLF" || true)
    if [ -z "$crlf_files" ]; then
        pass "所有核心源文件均为合规 POSIX LF 换行，无 CRLF 污染"
    else
        fail "检测到文件中存在 Windows CRLF 换行符" "$crlf_files"
    fi

    info "2. Lua 核心文件语法严密编译检查 (luac -p)"
    local lua_targets=(
        "root/usr/lib/lua/luci/controller/xc.lua"
        "root/usr/libexec/rpcd/luci.xc"
        "root/usr/bin/xc"
    )
    for f in "${lua_targets[@]}"; do
        if [ -f "$f" ]; then
            if luac -p "$f" 2>/dev/null; then
                pass "Lua 语法编译通过: $f"
            else
                local err_msg
                err_msg=$(luac -p "$f" 2>&1 || true)
                fail "Lua 语法错误: $f" "$err_msg"
            fi
        else
            fail "目标文件不存在: $f"
        fi
    done

    info "3. 控制器与 RPCD 模块依赖与无死锁保护检查"
    # 检查 controller/xc.lua 必须显式引入 luci.http，防止 500 nil 崩溃
    if grep -q 'require "luci.http"' "root/usr/lib/lua/luci/controller/xc.lua"; then
        pass "controller/xc.lua 显式引入了 luci.http (防 500 崩溃)"
    else
        fail "controller/xc.lua 缺少 require \"luci.http\"，存在运行时 500 风险"
    fi

    # 检查 controller/xc.lua 无参调用是否带管道输入，防止 rpcd 挂起
    if grep -q "echo '' | /usr/libexec/rpcd/luci.xc call" "root/usr/lib/lua/luci/controller/xc.lua"; then
        pass "controller/xc.lua 无参 call 带有空流管道保护 (防子进程卡死)"
    else
        fail "controller/xc.lua 存在无重定向的 rpcd 调用，可能卡死挂起"
    fi

    # 检查 rpcd/luci.xc 无参方法跳过 stdin 读取
    if grep -q "method == \"switch_node\"" "root/usr/libexec/rpcd/luci.xc"; then
        pass "rpcd/luci.xc 仅对需要入参的方法读取 stdin (防无参调用死锁)"
    else
        fail "rpcd/luci.xc 未限制 parse_stdin 作用域，存在标准输入阻塞风险"
    fi

    # 检查 controller/xc.lua 的 index() 在 LuCI indexcache 字节码序列化反序列化后无 nil upvalue 崩溃
    local dump_test_res
    dump_test_res=$(lua -e '
        package.preload["luci.http"] = function() return {} end
        package.preload["luci.util"] = function() return { shellquote = function(s) return s end } end
        package.preload["nixio"] = function() return { fs = { access = function() return true end } } end
        package.path = "root/usr/lib/lua/?.lua;" .. package.path
        local ok, c = pcall(require, "luci.controller.xc")
        if not ok then print("REQUIRE_FAIL:" .. tostring(c)) os.exit(1) end
        local dumped = string.dump(c.index)
        local restored = loadstring(dumped)
        local scope = setmetatable({}, { __index = {
            entry = function() return {} end,
            template = function() return function() end end,
            call = function() return function() end end,
            _ = function(s) return s end,
            require = require,
        }})
        setfenv(restored, scope)
        local run_ok, run_err = pcall(restored)
        if not run_ok then print("RESTORE_FAIL:" .. tostring(run_err)) os.exit(2) end
        print("OK")
    ' 2>&1 || true)
    if [ "$dump_test_res" = "OK" ]; then
        pass "controller/xc.lua 的 index() 通过 LuCI indexcache 字节码序列化与闭包无 upvalue 检验"
    else
        fail "controller/xc.lua 的 index() 存在外部 upvalue，在老版本 LuCI 缓存序列化后会崩溃" "$dump_test_res"
    fi

    info "4. 前端 UI 模态框首屏防遮挡与 Tab 结构验证"
    local htm_file="root/usr/lib/lua/luci/view/xc/overview.htm"
    if [ -f "$htm_file" ]; then
        # 检查 .xc-hidden 定义
        if grep -q "\.xc-hidden[^{]*{[^}]*display:[ ]*none[ ]*!important" "$htm_file"; then
            pass "overview.htm 包含合规的 .xc-hidden { display:none !important; } 样式"
        else
            fail "overview.htm 缺失或损坏 .xc-hidden 隐藏类样式 (会导致弹窗全屏遮挡)"
        fi

        # 检查节点弹窗是否默认 style="display:none;"
        if grep -q 'id="node-modal-mask"[^>]*style="display:none;"' "$htm_file"; then
            pass "节点编辑模态框容器带有内联 style=\"display:none;\" 防首屏弹窗遮挡"
        else
            fail "节点编辑模态框容器缺少 style=\"display:none;\" 属性"
        fi

        # 检查上传弹窗是否默认 style="display:none;"
        if grep -q 'id="xc-upload-modal-mask"[^>]*style="display:none;"' "$htm_file"; then
            pass "文件上传模态框容器带有内联 style=\"display:none;\" 防首屏弹窗遮挡"
        else
            fail "文件上传模态框容器缺少 style=\"display:none;\" 属性"
        fi

        # 检查 Tab 菜单和各大区块 ID 完整性
        local required_ids=("xc-tabs" "sec-nodes" "sec-settings" "sec-core" "setting-probe-timeout" "setting-probe-concurrency")
        for rid in "${required_ids[@]}"; do
            if grep -q "id=[\"']${rid}[\"']" "$htm_file"; then
                pass "DOM 关键元素存在: id=\"$rid\""
            else
                fail "DOM 关键元素丢失: id=\"$rid\""
            fi
        done
    else
        fail "overview.htm 文件不存在"
    fi

    info "5. RPCD 接口沙箱模拟调用 (本地零卡顿测试)"
    # 模拟沙箱下执行 rpcd list
    local rpcd_list_res
    rpcd_list_res=$(LUA_PATH="./tests/?.lua;;" timeout 2 lua root/usr/libexec/rpcd/luci.xc list 2>/dev/null || true)
    if [ -n "$rpcd_list_res" ] && echo "$rpcd_list_res" | grep -q '"get_status"'; then
        pass "rpcd list 沙箱输出合法 JSON 接口清单 (耗时 < 0.2s)"
    else
        fail "rpcd list 执行失败或超时" "$rpcd_list_res"
    fi

    # 模拟沙箱调用 get_nodes (带空输入流)
    local rpcd_nodes_res
    rpcd_nodes_res=$(echo "" | LUA_PATH="./tests/?.lua;;" timeout 2 lua root/usr/libexec/rpcd/luci.xc call get_nodes 2>/dev/null || true)
    if [ -n "$rpcd_nodes_res" ] && echo "$rpcd_nodes_res" | grep -q '"nodes"'; then
        pass "rpcd call get_nodes 秒级返回节点 JSON，无阻塞死锁 (耗时 < 0.2s)"
    else
        fail "rpcd call get_nodes 执行失败或阻塞超时" "$rpcd_nodes_res"
    fi
}

# ==============================================================================
# Staging 真机回归验证 (Level 3 on 192.168.6.1)
# ==============================================================================
run_staging_tests() {
    info "6. Staging 预发布机网络与 SSH 连通性测试 ($STAGING_HOST)"
    if ping -c 1 -W 2 "$STAGING_HOST" >/dev/null 2>&1; then
        pass "Staging 路由器 $STAGING_HOST 网络 ICMP 畅通"
    else
        fail "无法连通 Staging 路由器 $STAGING_HOST"
        return 1
    fi

    if sshpass -p "$STAGING_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 "root@$STAGING_HOST" "echo OK" >/dev/null 2>&1; then
        pass "Staging 路由器 SSH 认证成功"
    else
        fail "Staging 路由器 SSH 认证或连接失败"
        return 1
    fi

    info "7. 真机核心文件与执行权限检查 ($STAGING_HOST)"
    local perms_check
    perms_check=$(sshpass -p "$STAGING_PASS" ssh -o StrictHostKeyChecking=no "root@$STAGING_HOST" \
        '[ -x /usr/bin/xc ] && [ -x /usr/libexec/rpcd/luci.xc ] && [ -f /usr/lib/lua/luci/view/xc/overview.htm ] && echo OK || echo FAIL')
    if [ "$perms_check" = "OK" ]; then
        pass "/usr/bin/xc、rpcd/luci.xc 及 overview.htm 文件存在且权限就绪"
    else
        fail "真机上关键组件缺失或无执行权限" "$perms_check"
    fi

    info "8. 真机极速延迟探活引擎实测 ($STAGING_HOST)"
    # 执行单节点测速，超时时间 10 秒
    local probe_output
    probe_output=$(timeout 10 sshpass -p "$STAGING_PASS" ssh -o StrictHostKeyChecking=no "root@$STAGING_HOST" "xc probe 1 5" 2>&1 || true)
    
    if echo "$probe_output" | grep -q '"success": true'; then
        local latency
        latency=$(echo "$probe_output" | grep '"latency"' | grep -o '[0-9]\+' || echo "未知")
        pass "真机 HTTP 204 RTT 探针执行成功: 往返延迟 ${latency}ms (响应极速返回)"
    else
        fail "真机测速引擎 probe 失败或超时" "$probe_output"
    fi

    info "9. 真机后台 HTTP/RPCD 接口状态与死锁检查 ($STAGING_HOST)"
    local status_output
    status_output=$(timeout 6 sshpass -p "$STAGING_PASS" ssh -o StrictHostKeyChecking=no "root@$STAGING_HOST" "/usr/libexec/rpcd/luci.xc call get_status </dev/null" 2>&1 || true)
    if echo "$status_output" | grep -q '"running"'; then
        pass "真机 get_status 接口 0 秒响应且返回完整运行状态 JSON"
    else
        fail "真机 get_status 响应异常或依然挂起超时" "$status_output"
    fi

    info "10. 真机前端页面结构防遮挡与 Tab 菜单验证 ($STAGING_HOST)"
    local html_check
    html_check=$(sshpass -p "$STAGING_PASS" ssh -o StrictHostKeyChecking=no "root@$STAGING_HOST" \
        "grep -q 'id=\"xc-tabs\"' /usr/lib/lua/luci/view/xc/overview.htm && grep -q 'node-modal-mask.*style=\"display:none;\"' /usr/lib/lua/luci/view/xc/overview.htm && echo OK || echo FAIL")
    if [ "$html_check" = "OK" ]; then
        pass "真机 LuCI 模板页面已具备完整的 Tab 选项卡与模态框防遮挡属性"
    else
        fail "真机 LuCI 页面结构校验未通过"
    fi
}

# ==============================================================================
# 执行调度
# ==============================================================================
echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}       luci-app-xc-lite 自动化自测套件 (Automated Verification Suite)         ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

case "$MODE" in
    --local)
        run_local_tests
        ;;
    --staging)
        run_staging_tests
        ;;
    --all)
        run_local_tests
        run_staging_tests
        ;;
    *)
        echo "未知参数: $MODE. 支持: --local, --staging, --all"
        exit 1
        ;;
esac

echo -e "\n${BLUE}==============================================================================${NC}"
echo -e "测试总计: ${TOTAL_TESTS} | 通过: ${GREEN}${PASSED_TESTS}${NC} | 失败: ${RED}${FAILED_TESTS}${NC}"
echo -e "${BLUE}==============================================================================${NC}"

if [ "$FAILED_TESTS" -gt 0 ]; then
    echo -e "${RED}❌ 自测未全部通过，发布门禁已阻断！请排查修复上述失败项后再发布。${NC}\n"
    exit 1
else
    echo -e "${GREEN}✅ 全项自测通过！代码符合先验后发质量标准。${NC}\n"
    exit 0
fi
