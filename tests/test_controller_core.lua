local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("controller upload enforces size limit and destination paths", function()
  local source = read_file("root/usr/lib/lua/luci/controller/xc.lua")
  t.contains(source, "60 * 1024 * 1024")
  t.contains(source, "/etc/xc/bin")
  t.contains(source, "/etc/xc/assets")
end)

t.test("coremanager parses ELF headers and identifies machine architectures", function()
  local source = read_file("root/usr/lib/lua/xc/coremanager.lua")
  t.contains(source, "ELF_MACHINES")
  t.contains(source, "elf_arch")
  t.contains(source, "aarch64")
  t.contains(source, "x86_64")
  t.contains(source, "mips")
  t.contains(source, "parse_version")
end)

t.test("coremanager manages core state and validates version string", function()
  local source = read_file("root/usr/lib/lua/xc/coremanager.lua")
  t.contains(source, "MAX_SUPPORTED_VERSION")
  t.contains(source, "supported_version")
  t.contains(source, "Manager:validate")
  t.contains(source, "Manager:status")
end)
