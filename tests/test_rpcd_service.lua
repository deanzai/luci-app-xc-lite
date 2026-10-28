local t = require "testlib"
local json = require "mock_json"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local function command_output(command)
  local output = "tests/tmp/rpcd-test-output"
  local env = 'LUA_PATH="tests/?.lua;root/usr/lib/lua/?.lua;root/usr/lib/lua/?/init.lua;;" '
  assert(os.execute(env .. command .. " > " .. output) == 0)
  local value = read_file(output)
  os.remove(output)
  return value
end

local rpcd_script = "root/usr/libexec/rpcd/luci.xc"

t.test("rpcd script is executable and has valid hashbang", function()
  local source = read_file(rpcd_script)
  t.truthy(source:match("^#!/usr/bin/lua"))
  t.eq(os.execute("test -x " .. rpcd_script), 0)
end)

t.test("rpcd list returns all 14 methods and parameter specifications", function()
  local out = command_output("./.tools/lua5.1 " .. rpcd_script .. " list")
  t.truthy(out)
  t.contains(out, '"get_status"')
  t.contains(out, '"get_nodes"')
  t.contains(out, '"switch_node"')
  t.contains(out, '"switch_fixed_node"')
  t.contains(out, '"probe_node"')
  t.contains(out, '"save_node"')
  t.contains(out, '"delete_node"')
  t.contains(out, '"import_nodes"')
  t.contains(out, '"switch_source"')
  t.contains(out, '"test_health"')
  t.contains(out, '"get_settings"')
  t.contains(out, '"save_settings"')
  t.contains(out, '"restart_service"')
  t.contains(out, '"stop_service"')
end)

t.test("rpcd call rejects unknown methods with error code 2", function()
  local out = command_output("./.tools/lua5.1 " .. rpcd_script .. " call nonexistent_method")
  t.contains(out, '"code":2')
  t.contains(out, "unknown method")
end)

t.test("rpcd call rejects invalid rpcd actions with error code 3", function()
  local out = command_output("./.tools/lua5.1 " .. rpcd_script .. " invalid_action")
  t.contains(out, '"code":3')
  t.contains(out, "invalid rpcd action")
end)

t.test("rpcd implements strict secrets redaction in sanitize_output", function()
  local source = read_file(rpcd_script)
  t.contains(source, "function sanitize_output(val)")
  t.contains(source, "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x")
  t.contains(source, "[redacted]")
  t.contains(source, "[Pp][Aa][Ss][Ss][Ww]")
  t.contains(source, "[Tt][Oo][Kk][Ee][Nn]")
  t.contains(source, "[Ss][Ee][Cc][Rr][Ee][Tt]")
end)

t.test("rpcd leverages importer module for multiple protocols", function()
  local source = read_file(rpcd_script)
  t.contains(source, 'pcall(require, "xc.importer")')
  t.contains(source, "importer.parse")
  local importer_source = read_file("root/usr/lib/lua/xc/importer.lua")
  t.contains(importer_source, 'scheme == "vless"')
  t.contains(importer_source, 'scheme == "vmess"')
  t.contains(importer_source, 'scheme == "trojan"')
  t.contains(importer_source, 'scheme == "ss"')
end)
