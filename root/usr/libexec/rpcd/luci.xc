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
        local p = io.popen("/usr/bin/xc probe " .. tostring(id) .. " 2>/dev/null")
        local res = p and p:read("*a") or "{}"
        if p then p:close() end
        local ok, data = pcall(json.parse, res)
        output_json(ok and data or { id = id, latency = -1, success = false })
    end,

    save_node = function(params)
        local node = params.node
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
        local ok_write = write_file(NODES_FILE, json.stringify(data, 1))
        output_json({ code = ok_write and 0 or 1, message = ok_write and "deleted" or "failed to write nodes.json" })
    end,

    rollback = function()
        local tmp_log = "/tmp/xc-rollback.log"
        local ret = os.execute("/usr/bin/xc rollback >" .. tmp_log .. " 2>&1")
        local out = read_file(tmp_log) or ""
        os.remove(tmp_log)
        output_json({ code = (ret == 0) and 0 or 1, message = out })
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
            proxy_host = "127.0.0.1",
            probe_url = "http://www.gstatic.com/generate_204",
            health_url = "https://api.ipify.org"
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
        local settings = params.settings or {}
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
    end
}

-- rpcd Dispatcher
local action = arg[1]
if action == "list" then
    io.write('{"get_status":{},"get_nodes":{},"switch_node":{"id":0},"probe_node":{"id":0},"save_node":{"node":{}},"delete_node":{"id":0},"rollback":{},"test_health":{},"get_settings":{},"save_settings":{"settings":{},"fixed_proxy_id":0}}\n')
elseif action == "call" then
    local method = arg[2]
    local fn = methods[method]
    if fn then
        local params = parse_stdin()
        fn(params)
    else
        output_json({ code = 2, message = "unknown method" })
    end
else
    output_json({ code = 3, message = "invalid rpcd action" })
end
