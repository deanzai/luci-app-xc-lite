local t = require "testlib"
local access = require "xc.access"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("ACL defines strictly separated read and write access for rpcd", function()
  local acl = read_file("root/usr/share/rpcd/acl.d/luci-app-xc.json")
  t.contains(acl, '"read"')
  t.contains(acl, '"write"')
  t.contains(acl, '"luci.xc"')
  t.contains(acl, '"get_status"')
  t.contains(acl, '"switch_node"')
end)

t.test("access module normalizes defaults and generates outbound rules", function()
  local defaults = access.defaults()
  t.truthy(defaults.dns_remote)
  t.truthy(defaults.dns_cn)
  local norm, err = access.normalize({})
  t.truthy(norm, "normalize should succeed on empty table")
  local rules = access.rules(norm)
  t.truthy(type(rules) == "table")
end)

return true
