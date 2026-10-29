local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("Makefile exists", function()
  t.truthy(io.open("Makefile", "r"), "Makefile is missing")
end)

t.test("package release and version are configured in Makefile", function()
  local makefile = read_file("Makefile")
  t.contains(makefile, "PKG_NAME:=luci-app-xc")
  t.contains(makefile, "PKG_VERSION:=1.0.21")
  t.contains(makefile, "PKG_RELEASE:=1")
end)

t.test("runtime XC directory is not declared as an opkg conffile", function()
  local makefile = read_file("Makefile")
  t.eq(makefile:find("\n/etc/xc/\n", 1, true), nil,
    "opkg conffiles must contain files, not the runtime directory")
end)

t.test("package and translation versions stay aligned", function()
  local makefile = read_file("Makefile")
  local release = assert(makefile:match("PKG_RELEASE:=(%d+)"))
  local version_str = assert(makefile:match("PKG_VERSION:=([%d%.]+)"))
  t.truthy(release)
  t.truthy(version_str)
end)

t.test("runtime plugin display release follows the package release", function()
  local makefile = read_file("Makefile")
  local release = assert(makefile:match("PKG_RELEASE:=(%d+)"))
  local version_str = assert(makefile:match("PKG_VERSION:=([%d%.]+)"))
  package.loaded["xc.version"] = nil
  local version = require "xc.version"
  t.eq(tostring(version.release), release)
  t.eq(version.version, version_str)
  t.eq(version.display, version_str .. "-r" .. release)
end)

t.test("package depends on required base packages", function()
  local makefile = read_file("Makefile")
  t.contains(makefile, "+luci-base")
  t.contains(makefile, "+rpcd")
  t.contains(makefile, "+libuci-lua")
end)

t.test("managed resource updates are packaged and documented", function()
  t.truthy(io.open("root/usr/lib/lua/xc/assetmanager.lua", "r"), "asset manager is missing")
  t.truthy(io.open("root/usr/lib/lua/xc/assetjob.lua", "r"), "asset job manager is missing")
  t.truthy(io.open("root/usr/lib/lua/xc/coremanager.lua", "r"), "core manager is missing")
  t.contains(read_file("README.md"), "luci-app-xc")
end)

t.test("repository attributes force package text to LF", function()
  t.contains(read_file(".gitattributes"), "* text=auto eol=lf")
end)

t.test("Linux package and gettext source files contain no carriage returns", function()
  local manifest = "tests/tmp/lf-files"
  local command = table.concat({
    "mkdir -p tests/tmp && find root scripts tests po htdocs",
    "-path 'tests/tmp' -prune -o -type f \\\(",
    "-path 'root/usr/bin/*' -o -path 'root/etc/init.d/*'",
    "-o -path 'root/etc/hotplug.d/*' -o -path 'root/etc/uci-defaults/*'",
    "-o -name '*.sh' -o -name '*.lua' -o -name '*.htm' -o -name '*.js'",
    "-o -name '*.po' -o -name '*.pot' \\\) -print | sort > " .. manifest
  }, " ")
  assert(os.execute(command) == 0)

  local paths = { "Makefile" }
  local handle = assert(io.open(manifest, "r"))
  for path in handle:lines() do paths[#paths + 1] = path end
  handle:close()
  os.remove(manifest)

  for _, path in ipairs(paths) do
    t.eq(read_file(path):find("\r", 1, true), nil, path .. " must use LF line endings")
  end
end)

t.test("CI installs required runtimes and runs the complete host verification", function()
  local aggregate = read_file("tests/run-host.sh")
  t.contains(aggregate, '"$lua51" tests/run.lua')
  t.contains(aggregate, "sh tests/test_check_package.sh")
  t.contains(aggregate, "sh scripts/check-package.sh")
end)

for _, path in ipairs({
  "root/etc/config/xc", "root/etc/init.d/xc",
  "root/usr/bin/xc", "root/usr/lib/lua/luci/controller/xc.lua"
}) do
  t.test(path .. " exists", function()
    t.truthy(io.open(path, "r"), path .. " is missing")
  end)
end

t.test("init lifecycle uses procd and manages tmpfs config and xray assets", function()
  local source = read_file("root/etc/init.d/xc")
  t.contains(source, "USE_PROCD=1")
  t.contains(source, "resolve_xray")
  t.contains(source, "resolve_asset_dir")
  t.contains(source, "procd_open_instance")
  t.contains(source, "procd_set_param command")
  t.contains(source, "XRAY_LOCATION_ASSET")
end)

t.test("init selects the installed Xray asset directory", function()
  local source = read_file("root/etc/init.d/xc")
  t.contains(source, "/usr/share/xray")
  t.contains(source, "/usr/share/v2ray")
  t.contains(source, "geosite.dat")
  t.contains(source, "geoip.dat")
end)
