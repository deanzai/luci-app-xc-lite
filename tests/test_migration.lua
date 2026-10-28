local t = require "testlib"
local json = require "mock_json"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("uci-defaults 80_luci-app-xc handles initialization and auto-migration", function()
  local defaults = read_file("root/etc/uci-defaults/80_luci-app-xc")
  t.contains(defaults, "/etc/xc")
  t.contains(defaults, "/var/etc/xc")
  t.contains(defaults, "chmod +x /usr/bin/xc /usr/libexec/rpcd/luci.xc /etc/init.d/xc")
  t.contains(defaults, "/usr/bin/xc migrate")
  t.contains(defaults, "uci -q get xc.main.enabled")
end)

t.test("CLI xc implements migrate command and config extraction", function()
  local cli = read_file("root/usr/bin/xc")
  t.contains(cli, 'command == "migrate"')
  t.contains(cli, "extract_nodes_from_config")
  t.contains(cli, "migrate_to_uci")
end)

t.test("rpcd luci.xc implements migrate_to_uci and zero-config auto-discovery", function()
  local rpcd = read_file("root/usr/libexec/rpcd/luci.xc")
  t.contains(rpcd, "extract_nodes_from_config")
  t.contains(rpcd, "migrate_to_uci")
  t.contains(rpcd, "sync_json_compat")
end)

t.test("hotplug iface script handles interface reloads", function()
  local hotplug = read_file("root/etc/hotplug.d/iface/95-xc")
  t.contains(hotplug, "uci -q get xc.main.enabled")
  t.contains(hotplug, "/etc/init.d/xc reload")
end)

return true
