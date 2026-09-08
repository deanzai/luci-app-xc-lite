#!/usr/bin/lua
local json = require "luci.jsonc"

local ROOT = "/etc/xc"
local NODES_FILE = ROOT .. "/nodes.json"
local CONFIG_FILE = ROOT .. "/config.json"
local CURRENT_FILE = ROOT .. "/current"
local PREV_CONFIG = ROOT .. "/config.previous"
local PREV_CURRENT = ROOT .. "/current.previous"
local SETTINGS_FILE = ROOT .. "/settings.json"
local DEFAULT_SETTINGS = {
    listen_host = "127.0.0.1",
    socks_host = "127.0.0.1",
    socks_port = 7890,
    http_host = "127.0.0.1",
    http_port = 10809,
    proxy_host = "127.0.0.1",
    probe_url = "http://www.gstatic.com/generate_204",
    health_url = "http://www.gstatic.com/generate_204"
}

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write(path, data)
    local f = assert(io.open(path, "w"))
    f:write(data)
    f:close()
end

local function setting(name)
    local raw = read(SETTINGS_FILE)
    if not raw then return DEFAULT_SETTINGS[name] end
    local ok, data = pcall(json.parse, raw)
    if ok and data and data[name] ~= nil then return data[name] end
    return DEFAULT_SETTINGS[name]
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
    return os.execute(command) == 0
end

local function sleep(seconds)
    os.execute("sleep " .. tostring(seconds))
end

local function check_port_listening(port)
    local p = io.popen("netstat -lnt 2>/dev/null | grep '" .. tostring(port) .. " '")
    if not p then return false end
    local line = p:read("*l")
    p:close()
    return line ~= nil
end

local function wait_for_listener(port)
    for _ = 1, 20 do
        if check_port_listening(port) then return true end
        sleep(1)
    end
    return false
end

local function nodes_data()
    local raw = read(NODES_FILE)
    if not raw then
        return { version = 1, fixed_proxy_id = 1, nodes = {} }
    end
    local ok, data = pcall(json.parse, raw)
    if ok and type(data) == "table" then return data end
    return { version = 1, fixed_proxy_id = 1, nodes = {} }
end

local function find_node(nodes, id)
    if not nodes or not nodes.nodes then return nil end
    for _, node in ipairs(nodes.nodes) do
        if tonumber(node.id) == tonumber(id) then
            return node
        end
    end
    return nil
end

local function vless_outbound(node, tag)
    return {
        tag = tag,
        protocol = "vless",
        settings = {
            vnext = {{
                address = node.server,
                port = tonumber(node.port),
                users = {{
                    id = node.uuid,
                    encryption = "none",
                    flow = node.flow or "xtls-rprx-vision"
                }}
            }}
        },
        streamSettings = {
            network = "tcp",
            security = "reality",
            realitySettings = {
                show = false,
                fingerprint = node.fingerprint or "chrome",
                serverName = node.sni,
                publicKey = node.public_key,
                shortId = node.short_id or "",
                spiderX = node.spider_x or "/"
            }
        }
    }
end

local function socks_outbound(node, tag)
    return {
        tag = tag,
        protocol = "socks",
        settings = {
            servers = {{
                address = node.server,
                port = tonumber(node.port)
            }}
        }
    }
end

local function make_outbound(node, tag)
    if node.type == "VLESS REALITY" then
        return vless_outbound(node, tag)
    end
    return socks_outbound(node, tag)
end

local function make_config(node, socks_port, http_port)
    local s_host = setting("socks_host") or setting("listen_host")
    local s_port = tonumber(socks_port or setting("socks_port") or 7890)
    local h_host = setting("http_host") or setting("listen_host")
    local h_port = tonumber(http_port or setting("http_port") or 10809)
    local selected = make_outbound(node, "proxy-selected")
    local fixed = make_outbound(node._fixed_proxy or node, "proxy")
    return {
        log = {loglevel = "warning"},
        dns = {
            servers = {{
                address = "https://1.1.1.1/dns-query",
                tag = "dns-proxy",
                skipFallback = true,
                queryStrategy = "UseIPv4"
            }},
            disableFallback = true,
            queryStrategy = "UseIPv4"
        },
        inbounds = {
            {
                tag = "socks-in",
                listen = s_host,
                port = s_port,
                protocol = "socks",
                settings = {auth = "noauth", udp = true},
                sniffing = {enabled = true, destOverride = {"http", "tls", "quic"}, routeOnly = true}
            },
            {
                tag = "http-in",
                listen = h_host,
                port = h_port,
                protocol = "http",
                sniffing = {enabled = true, destOverride = {"http", "tls", "quic"}, routeOnly = true}
            }
        },
        outbounds = {
            selected,
            fixed,
            {tag = "direct", protocol = "freedom"},
            {tag = "block", protocol = "blackhole"}
        },
        routing = {
            domainStrategy = "AsIs",
            rules = {
                {type = "field", inboundTag = {"dns-proxy"}, outboundTag = "proxy-selected"},
                {type = "field", domain = {"geosite:category-ads-all"}, outboundTag = "block"},
                {type = "field", ip = {"geoip:private"}, outboundTag = "direct"},
                {type = "field", domain = {"geosite:private"}, outboundTag = "direct"},
                {type = "field", ip = {"192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "127.0.0.0/8"}, outboundTag = "direct"},
                {type = "field", domain = {"geosite:openai", "geosite:youtube", "geosite:twitter", "geosite:telegram", "geosite:tiktok", "geosite:netflix", "geosite:google", "geosite:facebook", "full:voice.google.com", "domain:voice.googleusercontent.com"}, outboundTag = "proxy"},
                {type = "field", domain = {"geosite:geolocation-!cn"}, outboundTag = "proxy-selected"},
                {type = "field", ip = {"geoip:cn"}, outboundTag = "direct"},
                {type = "field", domain = {"geosite:cn"}, outboundTag = "direct"},
            }
        }
    }
end

local function make_config_for(nodes, node, socks_port, http_port)
    local fixed = nil
    if nodes and nodes.fixed_proxy_id then
        fixed = find_node(nodes, nodes.fixed_proxy_id)
    end
    node._fixed_proxy = fixed or node
    return make_config(node, socks_port, http_port)
end

local function current_id()
    local raw = read(CURRENT_FILE)
    return raw and tonumber(raw:match("%d+")) or nil
end

local function output_node(node, latency)
    local marker = " "
    local current = current_id()
    if current == tonumber(node.id) then marker = "*" end
    local value = latency or "error"
    io.write(string.format("%s %2d  [%-18s] %-28s %s\n", marker, tonumber(node.id), node.type, node.name, value))
end

local function probe(node, port)
    port = port or (18080 + tonumber(node.id))
    local config = "/tmp/xc-probe-" .. tostring(node.id) .. ".json"
    local log = "/tmp/xc-probe-" .. tostring(node.id) .. ".log"
    local pidfile = "/tmp/xc-probe-" .. tostring(node.id) .. ".pid"
    local data = nodes_data()
    local probe_config = make_config_for(data, node, port, port + 1)
    table.insert(probe_config.routing.rules, 1, {type = "field", domain = {"full:www.gstatic.com"}, outboundTag = "proxy-selected"})
    write(config, json.stringify(probe_config, 1))
    if not run("/usr/bin/xray run -test -c " .. shell_quote(config) .. " >/dev/null 2>&1") then
        os.remove(config)
        return nil
    end
    local p = io.popen("sh -c " .. shell_quote("/usr/bin/xray run -c " .. config .. " >" .. log .. " 2>&1 & echo $!"))
    local pid = p and p:read("*l")
    if p then p:close() end
    if not pid then os.remove(config); return nil end
    write(pidfile, pid)
    if not wait_for_listener(port) then
        os.execute("kill " .. pid .. " >/dev/null 2>&1")
        os.remove(config); os.remove(log); os.remove(pidfile)
        return nil
    end
    local c = io.popen("curl --silent --show-error --max-time 8 -o /dev/null -w '%{time_total} %{http_code}' --proxy socks5h://" .. setting("proxy_host") .. ":" .. tostring(port) .. " " .. setting("probe_url") .. " 2>/dev/null")
    local result = c and c:read("*a") or ""
    if c then c:close() end
    os.execute("kill " .. pid .. " >/dev/null 2>&1")
    os.remove(config); os.remove(log); os.remove(pidfile)
    local seconds, status = result:match("([%d%.]+)%s+(%d%d%d)")
    local n = tonumber(seconds)
    if not n or status == "000" then return nil end
    return math.floor(n * 1000 + 0.5)
end

local function list_nodes(data)
    io.write("ID  TYPE                 NODE                          LATENCY\n")
    for _, node in ipairs(data.nodes) do
        output_node(node, probe(node, 18080 + tonumber(node.id)))
    end
end

local function select_node(id)
    local data = nodes_data()
    local node = find_node(data, id)
    if not node then
        io.stderr:write("unknown node: " .. tostring(id) .. "\n")
        return false, "unknown node: " .. tostring(id)
    end
    local config = ROOT .. "/config.new.json"
    write(config, json.stringify(make_config_for(data, node), 1))
    if not run("/usr/bin/xray run -test -c " .. shell_quote(config) .. " >/tmp/xc-test.log 2>&1") then
        local err = read("/tmp/xc-test.log") or "xray configuration test failed"
        io.stderr:write(err)
        return false, err
    end
    os.execute("cp -f " .. shell_quote(CONFIG_FILE) .. " " .. shell_quote(PREV_CONFIG) .. " 2>/dev/null")
    os.execute("cp -f " .. shell_quote(CURRENT_FILE) .. " " .. shell_quote(PREV_CURRENT) .. " 2>/dev/null")
    if not os.rename(config, CONFIG_FILE) then
        io.stderr:write("failed to replace active config\n")
        return false, "failed to replace active config"
    end
    write(CURRENT_FILE, tostring(id) .. "\n")
    if not run("/etc/init.d/xc-xray restart >/dev/null 2>&1") then
        os.execute("cp -f " .. shell_quote(PREV_CONFIG) .. " " .. shell_quote(CONFIG_FILE))
        os.execute("cp -f " .. shell_quote(PREV_CURRENT) .. " " .. shell_quote(CURRENT_FILE))
        os.execute("/etc/init.d/xc-xray restart >/dev/null 2>&1")
        return false, "service restart failed"
    end
    local s_port = tonumber(setting("socks_port") or 7890)
    local ok = false
    for _ = 1, 25 do
        sleep(1)
        if check_port_listening(s_port) and run("curl --silent --show-error --max-time 3 -o /dev/null --proxy socks5h://" .. setting("proxy_host") .. ":" .. tostring(s_port) .. " " .. setting("health_url") .. " >/dev/null 2>&1") then
            ok = true
            break
        end
    end
    if not ok then
        if os.execute("test -s " .. shell_quote(PREV_CONFIG)) == 0 then
            os.execute("cp -f " .. shell_quote(PREV_CONFIG) .. " " .. shell_quote(CONFIG_FILE))
            os.execute("cp -f " .. shell_quote(PREV_CURRENT) .. " " .. shell_quote(CURRENT_FILE))
            os.execute("/etc/init.d/xc-xray restart >/dev/null 2>&1")
        end
        io.stderr:write("health check failed; rolled back\n")
        return false, "health check failed; rolled back"
    end
    io.write("selected " .. tostring(id) .. " [" .. node.type .. "] " .. node.name .. "\n")
    return true
end

local function test_current()
    local s_port = tonumber(setting("socks_port") or 7890)
    local h_port = tonumber(setting("http_port") or 10809)
    local socks = run("curl --silent --show-error --max-time 15 -o /dev/null --proxy socks5h://" .. setting("proxy_host") .. ":" .. tostring(s_port) .. " " .. setting("health_url") .. " >/dev/null 2>&1")
    local http = run("curl --silent --show-error --max-time 15 -o /dev/null --proxy http://" .. setting("proxy_host") .. ":" .. tostring(h_port) .. " " .. setting("health_url") .. " >/dev/null 2>&1")
    io.write(string.format("socks%d=%s http%d=%s\n", s_port, socks and "ok" or "fail", h_port, http and "ok" or "fail"))
    return socks, http
end

local function rollback_state()
    if run("test -s " .. shell_quote(PREV_CONFIG) .. " && test -s " .. shell_quote(PREV_CURRENT)) then
        os.execute("cp -f " .. shell_quote(PREV_CONFIG) .. " " .. shell_quote(CONFIG_FILE))
        os.execute("cp -f " .. shell_quote(PREV_CURRENT) .. " " .. shell_quote(CURRENT_FILE))
        run("/etc/init.d/xc-xray restart >/dev/null 2>&1")
        return true
    end
    return false
end

-- CLI Entry Point
local data = nodes_data()
local command = arg[1] or "current"

if command == "list" then
    list_nodes(data)
elseif command == "current" then
    local id = current_id()
    local node = id and find_node(data, id)
    if node then io.write(string.format("%d [%s] %s\n", id, node.type, node.name)) else io.write("none\n") end
elseif command == "status" then
    local p = io.popen("pgrep -f '/usr/bin/xray run -c /etc/xc/config.json'")
    local pid = p and p:read("*l")
    if p then p:close() end
    local cur_id = current_id()
    local cur_node = cur_id and find_node(data, cur_id)
    local s_port = tonumber(setting("socks_port") or 7890)
    local h_port = tonumber(setting("http_port") or 10809)
    local s_host = setting("socks_host") or setting("listen_host")
    local h_host = setting("http_host") or setting("listen_host")
    local status = {
        running = pid ~= nil,
        pid = pid,
        current_id = cur_id,
        current_node = cur_node,
        fixed_proxy_id = data.fixed_proxy_id,
        socks_host = s_host,
        socks_port = s_port,
        http_host = h_host,
        http_port = h_port,
        socks_listening = check_port_listening(s_port),
        http_listening = check_port_listening(h_port)
    }
    io.write(json.stringify(status, 1) .. "\n")
elseif command == "probe" then
    local id = tonumber(arg[2])
    if not id then
        io.stderr:write("usage: xc probe <id>\n"); os.exit(2)
    end
    local node = find_node(data, id)
    if not node then
        io.stderr:write("unknown node: " .. tostring(id) .. "\n"); os.exit(1)
    end
    local lat = probe(node, 18080 + id)
    local res = { id = id, latency = lat or -1, success = (lat ~= nil) }
    io.write(json.stringify(res, 1) .. "\n")
elseif command == "switch" then
    local id = tonumber(arg[2])
    if not id then
        io.stderr:write("usage: xc switch <id>\n"); os.exit(2)
    end
    local ok, err = select_node(id)
    os.exit(ok and 0 or 1)
elseif command == "test" then
    local s, h = test_current()
    os.exit((s and h) and 0 or 1)
elseif command == "rollback" then
    if rollback_state() then
        io.write("rollback success\n")
    else
        io.stderr:write("no rollback state\n"); os.exit(1)
    end
elseif tonumber(command) then
    local ok = select_node(tonumber(command))
    os.exit(ok and 0 or 1)
else
    io.stderr:write("usage: xc list | xc <id> | xc switch <id> | xc current | xc probe <id> | xc status | xc test | xc rollback\n")
    os.exit(2)
end
