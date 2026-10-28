local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local source = read_file("root/usr/lib/lua/luci/controller/xc.lua")

t.test("controller registers secure streaming upload endpoint with root auth", function()
  t.contains(source, 'module("luci.controller.xc", package.seeall)')
  t.contains(source, 'entry({"admin", "services", "xc", "upload"}, call("act_upload"))')
  t.contains(source, 'e.leaf = true')
  t.contains(source, 'e.sysauth = "root"')
  t.contains(source, 'e.sysauth_authenticator = "htmlauth"')
end)

t.test("controller implements strict CSRF token validation and 403 rejection", function()
  t.contains(source, "HTTP_X_CSRF_TOKEN")
  t.contains(source, "session_token")
  t.contains(source, 'luci.http.status(403, "Forbidden")')
  t.contains(source, "CSRF Token 鉴权失败")
end)

t.test("controller limits upload file size to 60MB and purges temporary files", function()
  t.contains(source, "60 * 1024 * 1024")
  t.contains(source, 'upload_err = "file_too_large"')
  t.contains(source, "os.remove(tmp_file)")
end)

t.test("controller supports auto format detection for ELF, ZIP, tar.gz and DAT rules", function()
  t.contains(source, '"\\127ELF"')
  t.contains(source, '"PK\\03\\04"')
  t.contains(source, '"\\031\\139"')
  t.contains(source, 'upload_type == "xray"')
  t.contains(source, 'upload_type == "geosite"')
  t.contains(source, 'upload_type == "geoip"')
end)

t.test("controller enforces correct target permissions and checks xray binary execution", function()
  t.contains(source, "/etc/xc/bin/xray")
  t.contains(source, "fs.chmod(dest, 755)")
  t.contains(source, "/etc/xc/assets/geosite.dat")
  t.contains(source, "/etc/xc/assets/geoip.dat")
  t.contains(source, "fs.chmod(dest, 644)")
  t.contains(source, "version 2>&1 | head -n 1")
  t.contains(source, "架构不兼容")
end)
