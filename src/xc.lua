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
    proxy_host = "127.0.0.1",
    probe_url = "http://www.gstatic.com/generate_204",
    health_url = "https://api.ipify.org"
}

local function read(path)
    local f = assert(io.open(path, "r"))
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
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return DEFAULT_SETTINGS[name] end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(json.parse, raw)
    if ok and data and data[name] then return data[name] end
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

local function wait_for_listener(port)
    for _ = 1, 20 do
        local p = io.popen("netstat -lnt 2>/dev/null | grep '" .. tostring(port) .. " '")
        local line = p:read("*l")
        p:close()
        if line then return true end
        sleep(1)
    end
    return false
end

local function nodes_data()
    return json.parse(read(NODES_FILE))
end

local function find_node(nodes, id)
    for _, node in ipairs(nodes.nodes) do
        if tonumber(node.id) == tonumber(id) then
            return node
        end
    end
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
    socks_port = socks_port or 7890
    http_port = http_port or 10809
    local selected = make_outbound(node, "proxy-selected")
    local fixed = make_outbound(node._reality_uk, "reality-uk")
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
                listen = setting("listen_host"),
                port = socks_port,
                protocol = "socks",
                settings = {auth = "noauth", udp = true},
                sniffing = {enabled = true, destOverride = {"http", "tls", "quic"}, routeOnly = true}
            },
            {
                tag = "http-in",
                listen = setting("listen_host"),
                port = http_port,
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
                {type = "field", domain = {"geosite:openai", "geosite:youtube", "geosite:twitter", "geosite:telegram", "geosite:tiktok", "geosite:netflix", "geosite:google", "geosite:facebook", "full:voice.google.com", "domain:voice.googleusercontent.com"}, outboundTag = "reality-uk"},
                {type = "field", domain = {"geosite:geolocation-!cn"}, outboundTag = "proxy-selected"},
                {type = "field", ip = {"geoip:cn"}, outboundTag = "direct"},
                {type = "field", domain = {"geosite:cn"}, outboundTag = "direct"},
                {type = "field", domain = {"full:publicwsldistros.blob.core.windows.net", "full:services.googleapis.cn", "full:registry-1.docker.io", "full:www.cpu-monkey.com", "domain:armbian.org", "domain:armbian.com", "domain:cpu-monkey.com", "domain:vsean.net"}, outboundTag = "proxy-selected"}
            }
        }
    }
end

local function make_config_for(nodes, node, socks_port, http_port)
    node._reality_uk = find_node(nodes, nodes.reality_uk_id)
    assert(node._reality_uk, "reality-uk node missing")
    return make_config(node, socks_port, http_port)
end

local function current_id()
    local ok, value = pcall(read, CURRENT_FILE)
    return ok and tonumber(value) or nil
end

local function output_node(node, latency)
    local marker = " "
    local current = current_id()
    if current == tonumber(node.id) then marker = "*" end
    local value = latency or "error"
    io.write(string.format("%s %2d  [%-18s] %-28s %s\n", marker, tonumber(node.id), node.type, node.name, value))
end

local function probe(node, port)
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
    local pid = p:read("*l")
    p:close()
    if not pid then return nil end
    write(pidfile, pid)
    if not wait_for_listener(port) then
        os.execute("kill " .. pid .. " >/dev/null 2>&1")
        os.remove(config); os.remove(log); os.remove(pidfile)
        return nil
    end
    local c = io.popen("curl --silent --show-error --max-time 8 -o /dev/null -w '%{time_total} %{http_code}' --proxy socks5h://" .. setting("proxy_host") .. ":" .. tostring(port) .. " " .. setting("probe_url") .. " 2>/dev/null")
    local result = c:read("*a")
    c:close()
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
        os.exit(2)
    end
    local config = ROOT .. "/config.new.json"
    write(config, json.stringify(make_config_for(data, node), 1))
    if not run("/usr/bin/xray run -test -c " .. shell_quote(config) .. " >/tmp/xc-test.log 2>&1") then
        io.stderr:write(read("/tmp/xc-test.log")); os.exit(1)
    end
    os.execute("cp -f " .. shell_quote(CONFIG_FILE) .. " " .. shell_quote(PREV_CONFIG))
    os.execute("cp -f " .. shell_quote(CURRENT_FILE) .. " " .. shell_quote(PREV_CURRENT))
    if not os.rename(config, CONFIG_FILE) then
        io.stderr:write("failed to replace active config\n")
        os.exit(1)
    end
    write(CURRENT_FILE, tostring(id) .. "\n")
    if not run("/etc/init.d/xc-xray restart >/dev/null 2>&1") then
        os.execute("cp -f " .. shell_quote(PREV_CONFIG) .. " " .. shell_quote(CONFIG_FILE))
        os.execute("cp -f " .. shell_quote(PREV_CURRENT) .. " " .. shell_quote(CURRENT_FILE))
        os.execute("/etc/init.d/xc-xray restart >/dev/null 2>&1")
        os.exit(1)
    end
    wait_for_listener(7890)
    local ok = run("curl --silent --show-error --max-time 15 -o /dev/null --proxy socks5h://" .. setting("proxy_host") .. ":7890 " .. setting("health_url") .. " >/dev/null 2>&1")
    if not ok then
        os.execute("cp -f " .. shell_quote(PREV_CONFIG) .. " " .. shell_quote(CONFIG_FILE))
        os.execute("cp -f " .. shell_quote(PREV_CURRENT) .. " " .. shell_quote(CURRENT_FILE))
        os.execute("/etc/init.d/xc-xray restart >/dev/null 2>&1")
        io.stderr:write("health check failed; rolled back\n")
        os.exit(1)
    end
    io.write("selected " .. tostring(id) .. " [" .. node.type .. "] " .. node.name .. "\n")
end

local function test_current()
    local socks = run("curl --silent --show-error --max-time 15 -o /dev/null --proxy socks5h://" .. setting("proxy_host") .. ":7890 " .. setting("health_url") .. " >/dev/null 2>&1")
    local http = run("curl --silent --show-error --max-time 15 -o /dev/null --proxy http://" .. setting("proxy_host") .. ":10809 " .. setting("health_url") .. " >/dev/null 2>&1")
    io.write("socks7890=" .. (socks and "ok" or "fail") .. " http10809=" .. (http and "ok" or "fail") .. "\n")
    os.exit((socks and http) and 0 or 1)
end

local data = nodes_data()
local command = arg[1] or "current"
if command == "-l" or command == "list" then
    list_nodes(data)
elseif command == "current" then
    local id = current_id()
    local node = id and find_node(data, id)
    if node then io.write(string.format("%d [%s] %s\n", id, node.type, node.name)) else io.write("none\n") end
elseif command == "test" then
    test_current()
elseif command == "rollback" then
    if run("test -s " .. shell_quote(PREV_CONFIG) .. " && test -s " .. shell_quote(PREV_CURRENT)) then
        os.execute("cp -f " .. shell_quote(PREV_CONFIG) .. " " .. shell_quote(CONFIG_FILE))
        os.execute("cp -f " .. shell_quote(PREV_CURRENT) .. " " .. shell_quote(CURRENT_FILE))
        run("/etc/init.d/xc-xray restart")
    else
        io.stderr:write("no rollback state\n"); os.exit(1)
    end
elseif tonumber(command) then
    select_node(tonumber(command))
else
    io.stderr:write("usage: xc -l | xc <id> | xc current | xc test | xc rollback\n")
    os.exit(2)
end
