local vless_node = {
    id = 1,
    name = "Tokyo VLESS",
    type = "VLESS REALITY",
    server = "tokyo.example.com",
    port = 443,
    uuid = "12345678-1234-1234-1234-123456789abc",
    flow = "xtls-rprx-vision",
    security = "reality",
    sni = "gateway.icloud.com",
    public_key = "dummy_key",
    short_id = "abcd1234",
    fingerprint = "chrome"
}

local socks_node = {
    id = 2,
    name = "Local Naive",
    type = "SOCKS5",
    server = "127.0.0.1",
    port = 1080
}

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
                    flow = node.flow or ""
                }}
            }}
        },
        streamSettings = {
            network = "tcp",
            security = "reality",
            realitySettings = {
                serverName = node.sni or "",
                publicKey = node.public_key or "",
                shortId = node.short_id or "",
                spiderX = node.spider_x or "/",
                fingerprint = node.fingerprint or "chrome"
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

local function make_probe_config(node, socks_port)
    return {
        log = { loglevel = "none" },
        inbounds = {
            {
                tag = "probe-in",
                listen = "127.0.0.1",
                port = socks_port,
                protocol = "socks",
                settings = { auth = "noauth", udp = false }
            }
        },
        outbounds = {
            make_outbound(node, "proxy"),
            { tag = "direct", protocol = "freedom" }
        }
    }
end

-- Test VLESS probe config
local v_cfg = make_probe_config(vless_node, 18081)
assert(v_cfg.log.loglevel == "none", "loglevel must be none")
assert(v_cfg.inbounds[1].port == 18081, "port mismatch")
assert(v_cfg.outbounds[1].protocol == "vless", "vless outbound protocol mismatch")
assert(v_cfg.routing == nil, "must not contain routing")
assert(v_cfg.dns == nil, "must not contain dns")

-- Test SOCKS probe config
local s_cfg = make_probe_config(socks_node, 18082)
assert(s_cfg.outbounds[1].protocol == "socks", "socks outbound protocol mismatch")
assert(s_cfg.inbounds[1].port == 18082, "port mismatch")

print("SUCCESS: make_probe_config creates pristine ultra-lightweight configs for both VLESS and SOCKS!")
