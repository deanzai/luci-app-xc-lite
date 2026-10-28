local t = require "testlib"
local json = require "mock_json"

local function read_file(path)
  local handle = io.open(path, "r")
  t.truthy(handle, path .. " is missing")
  local value = handle:read("*a")
  handle:close()
  return value
end

local menu_path = "root/usr/share/luci/menu.d/luci-app-xc.json"
local acl_path = "root/usr/share/rpcd/acl.d/luci-app-xc.json"
local ucitrack_path = "root/usr/share/ucitrack/luci-app-xc.json"
local defaults_path = "root/etc/uci-defaults/80_luci-app-xc"
local config_path = "root/etc/config/xc"
local view_path = "htdocs/luci-static/resources/view/xc/overview.js"
local rpcd_path = "root/usr/libexec/rpcd/luci.xc"

t.test("Modern LuCI registration and architecture files exist", function()
  for _, path in ipairs({ menu_path, acl_path, ucitrack_path, defaults_path, config_path, view_path, rpcd_path }) do
    read_file(path)
  end
end)

t.test("LuCI menu entry registers modern view and ACL dependency", function()
  local content = read_file(menu_path)
  t.contains(content, "admin/services/xc")
  t.contains(content, "xc/overview")
  t.contains(content, "luci-app-xc")
  t.contains(content, "xc 节点分流")
end)

t.test("LuCI ACL grants strictly required ubus and uci privileges", function()
  local content = read_file(acl_path)
  t.contains(content, "luci-app-xc")
  t.contains(content, "luci.xc")
  t.contains(content, "get_status")
  t.contains(content, "get_nodes")
  t.contains(content, "get_settings")
  t.contains(content, "probe_node")
  t.contains(content, "test_health")
  t.contains(content, "switch_node")
  t.contains(content, "switch_fixed_node")
  t.contains(content, "save_node")
  t.contains(content, "delete_node")
  t.contains(content, "import_nodes")
  t.contains(content, "switch_source")
  t.contains(content, "save_settings")
  t.contains(content, "restart_service")
  t.contains(content, "stop_service")
  t.contains(content, "uci")
end)

t.test("ucitrack links xc config changes to xc init service", function()
  local content = read_file(ucitrack_path)
  t.contains(content, '"config": "xc"')
  t.contains(content, '"init": "xc"')
end)

t.test("UCI defaults script handles permissions and auto migration", function()
  local content = read_file(defaults_path)
  t.contains(content, "/etc/xc")
  t.contains(content, "/var/etc/xc")
  t.contains(content, "chmod +x /usr/bin/xc /usr/libexec/rpcd/luci.xc /etc/init.d/xc")
  t.contains(content, "/usr/bin/xc migrate")
  t.contains(content, "xc.main.enabled")
end)

t.test("UCI main configuration defines standard runtime defaults", function()
  local content = read_file(config_path)
  t.contains(content, "config xc 'main'")
  t.contains(content, "option enabled '1'")
  t.contains(content, "option socks_port '7890'")
  t.contains(content, "option http_port '10809'")
  t.contains(content, "option log_level 'warning'")
  t.contains(content, "option probe_url 'http://www.gstatic.com/generate_204'")
  t.contains(content, "option health_url 'http://www.gstatic.com/generate_204'")
  t.contains(content, "option core_source 'custom'")
  t.contains(content, "option asset_source 'custom'")
end)

t.test("overview.js client binds all RPC methods exposed by rpcd and permitted by ACL", function()
  local content = read_file(view_path)
  t.contains(content, "callGetStatus")
  t.contains(content, "callGetNodes")
  t.contains(content, "callGetSettings")
  t.contains(content, "callSwitchNode")
  t.contains(content, "callProbeNode")
  t.contains(content, "callSaveNode")
  t.contains(content, "callDeleteNode")
  t.contains(content, "callSwitchSource")
  t.contains(content, "callRestartService")
  t.contains(content, "callStopService")
  t.contains(content, "callTestHealth")
  t.contains(content, "callSaveSettings")
  t.contains(content, "callImportNodes")
end)
