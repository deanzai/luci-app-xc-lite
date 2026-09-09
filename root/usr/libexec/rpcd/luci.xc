#!/usr/bin/lua
local json = require "luci.jsonc"

local ROOT = "/etc/xc"
local NODES_FILE = ROOT .. "/nodes.json"
local SETTINGS_FILE = ROOT .. "/settings.json"

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function parse_stdin()
    local input = io.read("*a")
    if not input or #input == 0 then return {} end
    local ok, data = pcall(json.parse, input)
    if ok and type(data) == "table" then return data end
    return {}
end

local function output_json(tbl)
    io.write(json.stringify(tbl or {}, 1) .. "\n")
end

local methods = {
    get_status = function()
        local p = io.popen("/usr/bin/xc status 2>/dev/null")
        local res = p and p:read("*a") or "{}"
        if p then p:close() end
        local ok, data = pcall(json.parse, res)
        output_json(ok and data or { running = false })
    end,

    get_nodes = function()
        local raw = read_file(NODES_FILE)
        if not raw then
            output_json({ version = 1, fixed_proxy_id = 1, nodes = {} })
            return
        end
        local ok, data = pcall(json.parse, raw)
        output_json(ok and data or { version = 1, fixed_proxy_id = 1, nodes = {} })
    end,

    switch_node = function(params)
        local id = tonumber(params.id)
        if not id then
            output_json({ code = 1, message = "invalid node id" })
            return
        end
        local tmp_log = "/tmp/xc-switch.log"
        local ret = os.execute("/usr/bin/xc switch " .. tostring(id) .. " >" .. tmp_log .. " 2>&1")
        local out = read_file(tmp_log) or ""
        os.remove(tmp_log)
        output_json({ code = (ret == 0) and 0 or 1, message = out })
    end,

    probe_node = function(params)
        local id = tonumber(params.id)
        if not id then
            output_json({ code = 1, latency = -1 })
            return
        end
        local timeout = tonumber(params.timeout)
        local cmd = "/usr/bin/xc probe " .. tostring(id)
        if timeout then
            cmd = cmd .. " " .. tostring(timeout)
        end
        local p = io.popen(cmd .. " 2>/dev/null")
        local res = p and p:read("*a") or "{}"
        if p then p:close() end
        local ok, data = pcall(json.parse, res)
        output_json(ok and data or { id = id, latency = -1, success = false })
    end,

    save_node = function(params)
        local node = (params and params.node) or params
        if type(node) == "table" and node.node then
            node = node.node
        end
        if not node or not node.id or not node.name then
            output_json({ code = 1, message = "invalid node parameters" })
            return
        end
        local raw = read_file(NODES_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or type(data) ~= "table" then
            data = { version = 1, fixed_proxy_id = 1, nodes = {} }
        end
        data.nodes = data.nodes or {}

        local found = false
        for i, n in ipairs(data.nodes) do
            if tonumber(n.id) == tonumber(node.id) then
                data.nodes[i] = node
                found = true
                break
            end
        end
        if not found then
            table.insert(data.nodes, node)
        end

        -- 若当前仅有 1 个节点（唯一节点），或尚未配置有效的固定分流节点，自动将固定分流节点初始化为此节点
        local has_valid_fixed = false
        if data.fixed_proxy_id then
            for _, n in ipairs(data.nodes) do
                if tonumber(n.id) == tonumber(data.fixed_proxy_id) then
                    has_valid_fixed = true
                    break
                end
            end
        end
        if #data.nodes <= 1 or not has_valid_fixed then
            data.fixed_proxy_id = tonumber(node.id)
        end

        local ok_write = write_file(NODES_FILE, json.stringify(data, 1))
        output_json({ code = ok_write and 0 or 1, message = ok_write and "success" or "failed to write nodes.json" })
    end,

    delete_node = function(params)
        local id = tonumber(params.id)
        if not id then
            output_json({ code = 1, message = "invalid id" })
            return
        end
        local raw = read_file(NODES_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or not data or not data.nodes then
            output_json({ code = 1, message = "nodes file missing" })
            return
        end

        local new_nodes = {}
        for _, n in ipairs(data.nodes) do
            if tonumber(n.id) ~= id then
                table.insert(new_nodes, n)
            end
        end
        data.nodes = new_nodes

        -- 若被删除的节点是固定分流节点，或删除后只剩 1 个节点，自动重置固定分流节点
        if tonumber(data.fixed_proxy_id) == id or #data.nodes <= 1 then
            data.fixed_proxy_id = (#data.nodes > 0) and tonumber(data.nodes[1].id) or nil
        end

        local ok_write = write_file(NODES_FILE, json.stringify(data, 1))
        output_json({ code = ok_write and 0 or 1, message = ok_write and "deleted" or "failed to write nodes.json" })
    end,

    switch_source = function(params)
        local raw = read_file(SETTINGS_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or type(data) ~= "table" then data = {} end

        if params and params.core_source then
            data.core_source = tostring(params.core_source)
        end
        if params and params.asset_source then
            data.asset_source = tostring(params.asset_source)
        end

        local ok_write = write_file(SETTINGS_FILE, json.stringify(data, 1))

        -- 若服务正在运行，自动重启以使核心或规则源切换生效
        local p = io.popen("pgrep -f 'xray run -c /etc/xc/config.json'")
        local pid = p and p:read("*l")
        if p then p:close() end
        if pid then
            os.execute("/etc/init.d/xc-xray restart >/dev/null 2>&1")
        end

        output_json({ code = ok_write and 0 or 1, message = ok_write and "source_updated" or "failed to write settings" })
    end,

    test_health = function()
        local tmp_log = "/tmp/xc-health.log"
        local ret = os.execute("/usr/bin/xc test >" .. tmp_log .. " 2>&1")
        local out = read_file(tmp_log) or ""
        os.remove(tmp_log)
        output_json({ code = (ret == 0) and 0 or 1, message = out })
    end,

    get_settings = function()
        local raw = read_file(SETTINGS_FILE)
        local ok, data = pcall(json.parse, raw or "")
        local defaults = {
            listen_host = "127.0.0.1",
            socks_host = "127.0.0.1",
            socks_port = 7890,
            http_host = "127.0.0.1",
            http_port = 10809,
            proxy_host = "127.0.0.1",
            probe_url = "http://www.gstatic.com/generate_204",
            health_url = "http://www.gstatic.com/generate_204",
            probe_timeout = 5,
            probe_concurrency = 3,
            core_source = "custom",
            asset_source = "custom"
        }
        if ok and type(data) == "table" then
            for k, v in pairs(defaults) do
                if data[k] == nil then data[k] = v end
            end
            output_json(data)
        else
            output_json(defaults)
        end
    end,

    save_settings = function(params)
        local settings = (params and params.settings) or params or {}
        if type(settings) == "table" and settings.settings then
            settings = settings.settings
        end
        local raw = read_file(SETTINGS_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or type(data) ~= "table" then data = {} end

        for k, v in pairs(settings) do
            data[k] = v
        end
        local ok_write = write_file(SETTINGS_FILE, json.stringify(data, 1))

        -- Also update fixed_proxy_id in nodes.json if provided
        if params.fixed_proxy_id then
            local n_raw = read_file(NODES_FILE)
            local n_ok, n_data = pcall(json.parse, n_raw or "")
            if n_ok and type(n_data) == "table" then
                n_data.fixed_proxy_id = tonumber(params.fixed_proxy_id)
                write_file(NODES_FILE, json.stringify(n_data, 1))
            end
        end

        output_json({ code = ok_write and 0 or 1, message = ok_write and "saved" or "save error" })
    end,

    restart_service = function()
        local tmp_log = "/tmp/xc-restart.log"
        local ret = os.execute("/usr/bin/xc restart >" .. tmp_log .. " 2>&1")
        local out = read_file(tmp_log) or ""
        os.remove(tmp_log)
        output_json({ code = (ret == 0) and 0 or 1, message = out })
    end,

    stop_service = function()
        local ret = os.execute("/usr/bin/xc stop >/dev/null 2>&1")
        output_json({ code = (ret == 0) and 0 or 1, message = (ret == 0) and "stopped" or "stop_failed" })
    end
}

-- rpcd Dispatcher
local action = arg[1]
if action == "list" then
    io.write('{"get_status":{},"get_nodes":{},"switch_node":{"id":0},"probe_node":{"id":0},"save_node":{"node":{}},"delete_node":{"id":0},"switch_source":{"core_source":"","asset_source":""},"test_health":{},"get_settings":{},"save_settings":{"settings":{},"fixed_proxy_id":0},"restart_service":{},"stop_service":{}}\n')
elseif action == "call" then
    local method = arg[2]
    local fn = methods[method]
    if fn then
        local params = {}
        if method == "switch_node" or method == "probe_node" or method == "save_node" or method == "delete_node" or method == "switch_source" or method == "save_settings" then
            params = parse_stdin()
        end
        fn(params)
    else
        output_json({ code = 2, message = "unknown method" })
    end
else
    output_json({ code = 3, message = "invalid rpcd action" })
end
