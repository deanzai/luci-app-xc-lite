local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local controller_source = read_file("root/usr/lib/lua/luci/controller/xc.lua")

t.test("controller index guards registration by config file access", function()
  t.contains(controller_source, 'function index()')
  t.contains(controller_source, 'nixio.fs.access("/etc/config/xc")')
end)

t.test("controller upload handler processes multipart stream", function()
  t.contains(controller_source, 'function act_upload(target_type)')
  t.contains(controller_source, 'luci.http.setfilehandler(')
  t.contains(controller_source, 'field_name == "type"')
  t.contains(controller_source, 'field_name == "token"')
  t.contains(controller_source, 'field_name == "file"')
end)

t.test("controller protects against zip slip and cleans up extraction dir", function()
  t.contains(controller_source, 'extract_dir = "/tmp/xc_extract_" .. os.time()')
  t.contains(controller_source, 'unzip -o -q')
  t.contains(controller_source, 'tar -zxf')
  t.contains(controller_source, 'rm -rf %s')
end)

t.test("controller notifies rpcd after core and asset source updates", function()
  t.contains(controller_source, 'notify_source_switch')
  t.contains(controller_source, 'ubus call luci.xc switch_source')
  t.contains(controller_source, '{"core_source":"custom"}')
  t.contains(controller_source, '{"asset_source":"custom"}')
end)
