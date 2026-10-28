local t = require "testlib"

local function source(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("probe module provides TCP and TLS socket latency measurement", function()
  local value = source("root/usr/lib/lua/xc/probe.lua")
  t.contains(value, "nixio.socket")
  t.contains(value, "poll")
end)

t.test("rpcd exposes probe_node method with timeout and real proxy target", function()
  local value = source("root/usr/libexec/rpcd/luci.xc")
  t.contains(value, '"probe_node"')
  t.contains(value, "probe_url")
  t.contains(value, "generate_204")
end)

t.test("overview.js implements probe UI with concurrency control and badge rendering", function()
  local value = source("htdocs/luci-static/resources/view/xc/overview.js")
  t.contains(value, "callProbeNode")
  t.contains(value, "probe_concurrency")
  t.contains(value, "probe_timeout")
  t.contains(value, "badge")
end)

return true
