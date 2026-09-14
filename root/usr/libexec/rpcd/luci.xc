#!/usr/bin/lua
local json = require "luci.jsonc"

local ok_uci, uci_mod = pcall(require, "uci")
local uci_cursor = ok_uci and uci_mod.cursor() or nil

local ROOT = "/etc/xc"
local NODES_FILE = ROOT .. "/nodes.json"
local SETTINGS_FILE = ROOT .. "/settings.json"
local CURRENT_FILE = ROOT .. "/current"

local DEFAULT_SETTINGS = {
    enabled = "1",
    listen_host = "0.0.0.0",
    socks_host = "0.0.0.0",
    socks_port = 7890,
    http_host = "0.0.0.0",
    http_port = 10809,
    proxy_host = "127.0.0.1",
    probe_url = "http://www.gstatic.com/generate_204",
    health_url = "http://www.gstatic.com/generate_204",
    probe_timeout = 5,
    probe_concurrency = 3,
    core_source = "custom",
    asset_source = "custom",
    log_level = "warning"
}

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

local CONFIG_FILE = "/var/etc/xc/config.json"
local COMPAT_CONFIG = ROOT .. "/config.json"

local function extract_nodes_from_config(cfg_path)
    local raw = read_file(cfg_path)
    if not raw then return nil end
    local ok, cfg = pcall(json.parse, raw)
    if not ok or type(cfg) ~= "table" or type(cfg.outbounds) ~= "table" then
        return nil
    end

    local nodes = {}
    local seen = {}
    local next_id = 1

    for _, ob in ipairs(cfg.outbounds) do
        local tag = ob.tag or ""
        local protocol = (ob.protocol or ""):lower()
        local stream = ob.streamSettings or {}
        local settings = ob.settings or {}

        local is_system = (tag == "direct" or tag == "block" or tag == "dns-out" or tag == "bypass" or tag == "warp" or protocol == "freedom" or protocol == "blackhole" or protocol == "dns")

        if not is_system and protocol ~= "" then
            local node = {
                id = next_id,
                type = protocol:upper()
            }

            if protocol == "vless" then
                local vnext = settings.vnext and settings.vnext[1]
                if vnext then
                    node.server = vnext.address
                    node.port = tonumber(vnext.port)
                    local user = vnext.users and vnext.users[1]
                    if user then
                        node.uuid = user.id
                        node.flow = user.flow
                    end
                end
                local sec = (stream.security or ""):lower()
                if sec == "reality" then
                    node.type = "VLESS REALITY"
                    local r = stream.realitySettings or {}
                    node.public_key = r.publicKey
                    node.short_id = r.shortId
                    node.sni = r.serverName
                    node.fingerprint = r.fingerprint or "chrome"
                    node.spider_x = r.spiderX
                elseif sec == "tls" then
                    node.type = "VLESS TLS"
                    local t = stream.tlsSettings or {}
                    node.sni = t.serverName
                    node.fingerprint = t.fingerprint or "chrome"
                end
            elseif protocol == "vmess" then
                local vnext = settings.vnext and settings.vnext[1]
                if vnext then
                    node.server = vnext.address
                    node.port = tonumber(vnext.port)
                    local user = vnext.users and vnext.users[1]
                    if user then
                        node.uuid = user.id
                        node.alter_id = user.alterId
                    end
                end
                node.type = "VMess"
                if (stream.security or ""):lower() == "tls" then
                    local t = stream.tlsSettings or {}
                    node.sni = t.serverName
                end
            elseif protocol == "trojan" then
                local srv = settings.servers and settings.servers[1]
                if srv then
                    node.server = srv.address
                    node.port = tonumber(srv.port)
                    node.uuid = srv.password
                end
                node.type = "Trojan"
                local t = stream.tlsSettings or {}
                node.sni = t.serverName
            elseif protocol == "shadowsocks" then
                local srv = settings.servers and settings.servers[1]
                if srv then
                    node.server = srv.address
                    node.port = tonumber(srv.port)
                    node.method = srv.method
                    node.password = srv.password
                end
                node.type = "Shadowsocks"
            elseif protocol == "socks" then
                local srv = settings.servers and settings.servers[1]
                if srv then
                    node.server = srv.address
                    node.port = tonumber(srv.port)
                end
                node.type = "SOCKS5"
            end

            if node.server and node.port then
                local dedup_key = tostring(node.type) .. "@" .. tostring(node.server) .. ":" .. tostring(node.port) .. "#" .. tostring(node.uuid or "")
                if not seen[dedup_key] then
                    seen[dedup_key] = true
                    node.name = (tag ~= "" and tag ~= "proxy" and tag ~= "proxy-selected") and tag or (tostring(node.sni or node.server) .. "-" .. tostring(node.port))
                    table.insert(nodes, node)
                    next_id = next_id + 1
                end
            end
        end
    end

    return #nodes > 0 and nodes or nil
end

-- 自动数据迁移：若 UCI 中尚无配置或节点，从已有 JSON 或 config.json 自动平滑导入
local function migrate_to_uci()
    if not uci_cursor then return end
    local committed = false

    -- 1. 迁移 settings.json -> uci xc.main
    local s_raw = read_file(SETTINGS_FILE)
    if s_raw then
        local s_ok, s_data = pcall(json.parse, s_raw)
        if s_ok and type(s_data) == "table" then
            for k, v in pairs(s_data) do
                if v ~= nil and uci_cursor:get("xc", "main", k) == nil then
                    uci_cursor:set("xc", "main", k, tostring(v))
                    committed = true
                end
            end
        end
    end

    -- 2. 迁移 nodes.json -> uci xc.<node_id>
    local node_count = 0
    local n_raw = read_file(NODES_FILE)
    if n_raw then
        local n_ok, n_data = pcall(json.parse, n_raw)
        if n_ok and type(n_data) == "table" then
            if n_data.fixed_proxy_id and uci_cursor:get("xc", "main", "fixed_proxy_id") == nil then
                uci_cursor:set("xc", "main", "fixed_proxy_id", tostring(n_data.fixed_proxy_id))
                committed = true
            end
            if type(n_data.nodes) == "table" then
                for _, node in ipairs(n_data.nodes) do
                    if node.id then
                        local sec_name = "node_" .. tostring(node.id)
                        if not uci_cursor:get_all("xc", sec_name) and not uci_cursor:get_all("xc", tostring(node.id)) then
                            uci_cursor:set("xc", sec_name, "node")
                            for nk, nv in pairs(node) do
                                if nv ~= nil then
                                    uci_cursor:set("xc", sec_name, nk, tostring(nv))
                                end
                            end
                            committed = true
                        end
                        node_count = node_count + 1
                    end
                end
            end
        end
    end

    -- 3. 若 UCI 和 nodes.json 均无节点，但存在直接添加的 config.json，则自动逆向解析并导入
    if node_count == 0 then
        local existing_count = 0
        uci_cursor:foreach("xc", "node", function() existing_count = existing_count + 1 end)
        if existing_count == 0 then
            local extracted = extract_nodes_from_config(CONFIG_FILE) or extract_nodes_from_config(COMPAT_CONFIG)
            if extracted and #extracted > 0 then
                for _, node in ipairs(extracted) do
                    local sec_name = "node_" .. tostring(node.id)
                    uci_cursor:set("xc", sec_name, "node")
                    for nk, nv in pairs(node) do
                        if nv ~= nil then
                            uci_cursor:set("xc", sec_name, nk, tostring(nv))
                        end
                    end
                    committed = true
                end
                if uci_cursor:get("xc", "main", "fixed_proxy_id") == nil then
                    uci_cursor:set("xc", "main", "fixed_proxy_id", "1")
                    committed = true
                end
                if uci_cursor:get("xc", "main", "current_id") == nil then
                    uci_cursor:set("xc", "main", "current_id", "1")
                    committed = true
                end
                -- 同步写出一份 nodes.json 保持双向兼容
                write_file(NODES_FILE, json.stringify({ version = 1, fixed_proxy_id = 1, nodes = extracted }, 1))
            end
        end
    end

    -- 4. 迁移 current -> uci xc.main.current_id
    local cur_raw = read_file(CURRENT_FILE)
    if cur_raw then
        local cid = cur_raw:match("%d+")
        if cid and uci_cursor:get("xc", "main", "current_id") == nil then
            uci_cursor:set("xc", "main", "current_id", tostring(cid))
            committed = true
        end
    end

    if committed then
        pcall(uci_cursor.commit, uci_cursor, "xc")
    end
end

-- 同步导出 JSON 文件（保持对第三方脚本或旧工具的向后兼容）
local function sync_json_compat(nodes_payload, settings_payload)
    if nodes_payload then
        write_file(NODES_FILE, json.stringify(nodes_payload, 1))
    end
    if settings_payload then
        write_file(SETTINGS_FILE, json.stringify(settings_payload, 1))
    end
end

local APP_VERSION = "1.0.18-1"

local methods = {
    get_status = function()
        local p = io.popen("/usr/bin/xc status 2>/dev/null")
        local res = p and p:read("*a") or "{}"
        if p then p:close() end
        local ok, data = pcall(json.parse, res)
        if ok and type(data) == "table" then
            data.app_version = data.app_version or APP_VERSION
            output_json(data)
        else
            output_json({ running = false, app_version = APP_VERSION })
        end
    end,

    get_nodes = function()
        if uci_cursor then
            migrate_to_uci()
            local nodes = {}
            uci_cursor:foreach("xc", "node", function(s)
                local n = {}
                for k, v in pairs(s) do
                    if k:sub(1, 1) ~= "." then
                        if k == "id" or k == "port" then
                            n[k] = tonumber(v)
                        else
                            n[k] = v
                        end
                    end
                end
                if n.id then
                    table.insert(nodes, n)
                end
            end)
            table.sort(nodes, function(a, b) return (a.id or 0) < (b.id or 0) end)
            local fixed_id = tonumber(uci_cursor:get("xc", "main", "fixed_proxy_id"))
            if not fixed_id and #nodes > 0 then
                fixed_id = nodes[1].id
            end
            local payload = { version = 1, fixed_proxy_id = fixed_id or 1, nodes = nodes }
            output_json(payload)
            return
        end

        -- Fallback: 本地沙箱无 uci.so 时读取 JSON
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

        local node_id = tonumber(node.id)
        local sec_name = "node_" .. tostring(node_id)

        if uci_cursor then
            migrate_to_uci()
            -- 若存在老版纯数字 section，先清理
            if uci_cursor:get_all("xc", tostring(node_id)) then
                uci_cursor:delete("xc", tostring(node_id))
            end
            uci_cursor:set("xc", sec_name, "node")
            for k, v in pairs(node) do
                if v ~= nil and type(v) ~= "table" and type(v) ~= "function" then
                    uci_cursor:set("xc", sec_name, k, tostring(v))
                end
            end

            -- 维护 fixed_proxy_id
            local cur_fixed = tonumber(uci_cursor:get("xc", "main", "fixed_proxy_id"))
            if not cur_fixed then
                uci_cursor:set("xc", "main", "fixed_proxy_id", tostring(node_id))
            end
            local ok_commit = pcall(uci_cursor.commit, uci_cursor, "xc")

            -- 同步维护兼容性 nodes.json
            local all_nodes = {}
            uci_cursor:foreach("xc", "node", function(s)
                local n = {}
                for k, v in pairs(s) do
                    if k:sub(1, 1) ~= "." then
                        n[k] = (k == "id" or k == "port") and tonumber(v) or v
                    end
                end
                if n.id then table.insert(all_nodes, n) end
            end)
            table.sort(all_nodes, function(a, b) return (a.id or 0) < (b.id or 0) end)
            sync_json_compat({
                version = 1,
                fixed_proxy_id = tonumber(uci_cursor:get("xc", "main", "fixed_proxy_id")) or node_id,
                nodes = all_nodes
            })

            output_json({ code = ok_commit and 0 or 1, message = ok_commit and "success" or "uci commit failed" })
            return
        end

        -- Fallback: 本地沙箱模式
        local raw = read_file(NODES_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or type(data) ~= "table" then
            data = { version = 1, fixed_proxy_id = 1, nodes = {} }
        end
        data.nodes = data.nodes or {}
        local found = false
        for i, n in ipairs(data.nodes) do
            if tonumber(n.id) == node_id then
                data.nodes[i] = node
                found = true
                break
            end
        end
        if not found then table.insert(data.nodes, node) end
        if #data.nodes <= 1 or not data.fixed_proxy_id then
            data.fixed_proxy_id = node_id
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

        if uci_cursor then
            migrate_to_uci()
            uci_cursor:delete("xc", "node_" .. tostring(id))
            uci_cursor:delete("xc", tostring(id))

            -- 若删除的是当前 fixed_proxy_id，重新指定
            local cur_fixed = tonumber(uci_cursor:get("xc", "main", "fixed_proxy_id"))
            local remaining_nodes = {}
            uci_cursor:foreach("xc", "node", function(s)
                local n = {}
                for k, v in pairs(s) do
                    if k:sub(1, 1) ~= "." then
                        n[k] = (k == "id" or k == "port") and tonumber(v) or v
                    end
                end
                if n.id then table.insert(remaining_nodes, n) end
            end)
            table.sort(remaining_nodes, function(a, b) return (a.id or 0) < (b.id or 0) end)

            if cur_fixed == id or #remaining_nodes <= 1 then
                local next_fixed = (#remaining_nodes > 0) and remaining_nodes[1].id or nil
                if next_fixed then
                    uci_cursor:set("xc", "main", "fixed_proxy_id", tostring(next_fixed))
                else
                    uci_cursor:delete("xc", "main", "fixed_proxy_id")
                end
            end

            local ok_commit = pcall(uci_cursor.commit, uci_cursor, "xc")
            sync_json_compat({
                version = 1,
                fixed_proxy_id = tonumber(uci_cursor:get("xc", "main", "fixed_proxy_id")),
                nodes = remaining_nodes
            })
            output_json({ code = ok_commit and 0 or 1, message = ok_commit and "deleted" or "uci delete failed" })
            return
        end

        -- Fallback: 本地沙箱模式
        local raw = read_file(NODES_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or not data or not data.nodes then
            output_json({ code = 1, message = "nodes file missing" })
            return
        end
        local new_nodes = {}
        for _, n in ipairs(data.nodes) do
            if tonumber(n.id) ~= id then table.insert(new_nodes, n) end
        end
        data.nodes = new_nodes
        if tonumber(data.fixed_proxy_id) == id or #data.nodes <= 1 then
            data.fixed_proxy_id = (#data.nodes > 0) and tonumber(data.nodes[1].id) or nil
        end
        local ok_write = write_file(NODES_FILE, json.stringify(data, 1))
        output_json({ code = ok_write and 0 or 1, message = ok_write and "deleted" or "failed to write nodes.json" })
    end,

    switch_source = function(params)
        local core_src = params and params.core_source and tostring(params.core_source)
        local asset_src = params and params.asset_source and tostring(params.asset_source)

        if uci_cursor then
            migrate_to_uci()
            if core_src then uci_cursor:set("xc", "main", "core_source", core_src) end
            if asset_src then uci_cursor:set("xc", "main", "asset_source", asset_src) end
            local ok_commit = pcall(uci_cursor.commit, uci_cursor, "xc")

            -- 同步兼容写入 settings.json
            local cur_settings = uci_cursor:get_all("xc", "main") or {}
            sync_json_compat(nil, cur_settings)

            -- 若服务正在运行，重启以加载新核心/规则源
            local p = io.popen("pgrep -f 'xray run -c'")
            local pid = p and p:read("*l")
            if p then p:close() end
            if pid then
                os.execute("/etc/init.d/xc restart >/dev/null 2>&1")
            end

            output_json({ code = ok_commit and 0 or 1, message = ok_commit and "source_updated" or "failed to commit uci" })
            return
        end

        -- Fallback: 本地沙箱模式
        local raw = read_file(SETTINGS_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or type(data) ~= "table" then data = {} end
        if core_src then data.core_source = core_src end
        if asset_src then data.asset_source = asset_src end
        local ok_write = write_file(SETTINGS_FILE, json.stringify(data, 1))
        local p = io.popen("pgrep -f 'xray run -c'")
        local pid = p and p:read("*l")
        if p then p:close() end
        if pid then
            os.execute("/etc/init.d/xc restart >/dev/null 2>&1")
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
        if uci_cursor then
            migrate_to_uci()
            local main = uci_cursor:get_all("xc", "main") or {}
            local res = {}
            for k, def_v in pairs(DEFAULT_SETTINGS) do
                local val = main[k]
                if val == nil then
                    res[k] = def_v
                elseif type(def_v) == "number" then
                    res[k] = tonumber(val) or def_v
                else
                    res[k] = val
                end
            end
            output_json(res)
            return
        end

        -- Fallback: 本地沙箱模式
        local raw = read_file(SETTINGS_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if ok and type(data) == "table" then
            for k, v in pairs(DEFAULT_SETTINGS) do
                if data[k] == nil then data[k] = v end
            end
            output_json(data)
        else
            output_json(DEFAULT_SETTINGS)
        end
    end,

    save_settings = function(params)
        local settings = (params and params.settings) or params or {}
        if type(settings) == "table" and settings.settings then
            settings = settings.settings
        end

        if uci_cursor then
            migrate_to_uci()
            for k, v in pairs(settings) do
                if v ~= nil then
                    uci_cursor:set("xc", "main", k, tostring(v))
                end
            end
            if params and params.fixed_proxy_id then
                uci_cursor:set("xc", "main", "fixed_proxy_id", tostring(params.fixed_proxy_id))
            end

            -- 联动服务自启状态
            local is_enabled = true
            if settings.enabled ~= nil then
                local ev = tostring(settings.enabled)
                is_enabled = (ev == "1" or ev == "true")
                uci_cursor:set("xc", "main", "enabled", is_enabled and "1" or "0")
                if is_enabled then
                    os.execute("/etc/init.d/xc enable >/dev/null 2>&1")
                else
                    os.execute("/etc/init.d/xc disable >/dev/null 2>&1")
                    os.execute("/etc/init.d/xc stop >/dev/null 2>&1")
                end
            end

            local ok_commit = pcall(uci_cursor.commit, uci_cursor, "xc")

            -- 同步兼顾更新 settings.json 与 nodes.json 中的 fixed_proxy_id
            local cur_settings = uci_cursor:get_all("xc", "main") or {}
            sync_json_compat(nil, cur_settings)
            if params and params.fixed_proxy_id then
                local n_raw = read_file(NODES_FILE)
                local n_ok, n_data = pcall(json.parse, n_raw or "")
                if n_ok and type(n_data) == "table" then
                    n_data.fixed_proxy_id = tonumber(params.fixed_proxy_id)
                    write_file(NODES_FILE, json.stringify(n_data, 1))
                end
            end

            -- 若已启用且服务正在运行（或刚刚启用），执行 xc restart 以重新渲染配置生效
            if is_enabled then
                local p = io.popen("pgrep -f 'xray run -c'")
                local pid = p and p:read("*l")
                if p then p:close() end
                if pid then
                    os.execute("/usr/bin/xc restart >/dev/null 2>&1")
                end
            end

            output_json({ code = ok_commit and 0 or 1, message = ok_commit and "saved" or "save error" })
            return
        end

        -- Fallback: 本地沙箱模式
        local raw = read_file(SETTINGS_FILE)
        local ok, data = pcall(json.parse, raw or "")
        if not ok or type(data) ~= "table" then data = {} end
        for k, v in pairs(settings) do data[k] = v end
        local ok_write = write_file(SETTINGS_FILE, json.stringify(data, 1))
        if params and params.fixed_proxy_id then
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
