module("luci.controller.xc", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/xc") then
        return
    end

    entry({"admin", "services", "xc"}, template("xc/overview"), _("xc 节点分流"), 60).dependent = true
    entry({"admin", "services", "xc", "status"}, call("act_status")).leaf = true
    entry({"admin", "services", "xc", "get_nodes"}, call("act_get_nodes")).leaf = true
    entry({"admin", "services", "xc", "switch_node"}, call("act_switch_node")).leaf = true
    entry({"admin", "services", "xc", "probe_node"}, call("act_probe_node")).leaf = true
    entry({"admin", "services", "xc", "save_node"}, call("act_save_node")).leaf = true
    entry({"admin", "services", "xc", "delete_node"}, call("act_delete_node")).leaf = true
    entry({"admin", "services", "xc", "rollback"}, call("act_rollback")).leaf = true
    entry({"admin", "services", "xc", "test_health"}, call("act_test_health")).leaf = true
    entry({"admin", "services", "xc", "get_settings"}, call("act_get_settings")).leaf = true
    entry({"admin", "services", "xc", "save_settings"}, call("act_save_settings")).leaf = true
end

local function call_rpcd(method, input_json)
    local cmd
    if input_json and #input_json > 0 then
        cmd = "echo " .. luci.util.shellquote(input_json) .. " | /usr/libexec/rpcd/luci.xc call " .. method .. " 2>/dev/null"
    else
        cmd = "/usr/libexec/rpcd/luci.xc call " .. method .. " 2>/dev/null"
    end
    local p = io.popen(cmd)
    local res = p and p:read("*a") or "{}"
    if p then p:close() end
    luci.http.prepare_content("application/json")
    luci.http.write(res)
end

function act_status()
    call_rpcd("get_status")
end

function act_get_nodes()
    call_rpcd("get_nodes")
end

function act_switch_node()
    local id = luci.http.formvalue("id")
    call_rpcd("switch_node", string.format('{"id":%d}', tonumber(id) or 0))
end

function act_probe_node()
    local id = luci.http.formvalue("id")
    call_rpcd("probe_node", string.format('{"id":%d}', tonumber(id) or 0))
end

function act_save_node()
    local node_str = luci.http.formvalue("node") or luci.http.content()
    call_rpcd("save_node", string.format('{"node":%s}', node_str))
end

function act_delete_node()
    local id = luci.http.formvalue("id")
    call_rpcd("delete_node", string.format('{"id":%d}', tonumber(id) or 0))
end

function act_rollback()
    call_rpcd("rollback")
end

function act_test_health()
    call_rpcd("test_health")
end

function act_get_settings()
    call_rpcd("get_settings")
end

function act_save_settings()
    local content = luci.http.content() or "{}"
    call_rpcd("save_settings", content)
end
