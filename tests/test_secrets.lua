local t = require "testlib"
local runtime_module = require "xc.runtime"
local logview = require "xc.logview"

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local function runtime_fixture()
  local files = {}
  local function yes() return true end
  local adapters = {
    now = function() return 1 end,
    sleep = yes,
    network = function() return "127.0.0.1" end,
    json = {
      stringify = function(value)
        local parts = {}
        for key, item in pairs(value) do
          parts[#parts + 1] = string.format('%q:%q', tostring(key), tostring(item))
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end,
      parse = function() return nil end
    },
    uci = {
      get_global = yes, get_node = yes, list_nodes = function() return {} end,
      set_active = yes, clear_active = yes, commit = yes, revert = yes
    },
    exec = {
      run = yes, restart = yes, stop = yes, listener_ready = yes,
      real_connection_check = yes, service_state = function() return "stopped" end,
      xray_api_override = yes, xray_api_balancer = function() return "xc-node-safe" end
    },
    fs = {
      acquire_lock = function() return {} end, release_lock = yes,
      lock_state = function() return "unlocked" end,
      allocate_generation = function() return "generation" end,
      list_generation_files = function() return {} end,
      trash_generation = yes, delete_trashed_generation = yes,
      read = function(path) return files[path], files[path] and nil or "missing" end,
      write_temp = function(path, value) return { path = path .. ".tmp", value = value } end,
      chmod = function() return true end,
      fsync = function() return true end,
      close = function() return true end,
      rename = function(source, destination)
        files[destination], files[source] = files[source], nil
        return true
      end,
      fsync_dir = function() return true end,
      exists = function(path) return files[path] ~= nil end,
      remove = function() return true end
    }
  }
  adapters.fs.write_temp = function(path, value)
    adapters.fs.pending = { path = path .. ".tmp", value = value }
    files[adapters.fs.pending.path] = value
    return adapters.fs.pending
  end
  return runtime_module.new(adapters), files
end

t.test("log helper redacts credentials links and raw outbound JSON", function()
  local runtime, files = runtime_fixture()
  local uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  local password = "task10-password"
  local link = "vless://" .. uuid .. "@secret.invalid:443?security=tls#Private"
  local raw = '{"protocol":"trojan","password":"raw-password"}'
  local result = runtime:log("failure " .. uuid .. " password=" .. password .. " " .. link .. " " .. raw, {
    uuid = uuid, password = password, share_link = link, raw_outbound = raw
  })
  t.eq(result.ok, true)
  local output = files[runtime_module.paths.log]
  for _, secret in ipairs({ uuid, password, link, "secret.invalid", raw, "raw-password" }) do
    t.eq(output:find(secret, 1, true), nil, "log leaked " .. secret)
  end
end)

t.test("logview filters and masks sensitive UUIDs and keys", function()
  local fake_json = { parse = function() return nil end }
  local line = os.date("%a %b %d %H:%M:%S %Y", 1785326400)
    .. " daemon.warn xray[123]: user aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee connected with password=supersecret token=mytoken"
  local entries = logview.collect({
    level = "all",
    wall_time = 1785326400,
    uptime = 7200,
    json = fake_json,
    xc = "",
    xray = line
  })
  t.truthy(entries)
  t.truthy(#entries > 0)
  local msg = entries[1].message
  t.eq(msg:find("supersecret", 1, true), nil, "Password must be masked")
  t.eq(msg:find("mytoken", 1, true), nil, "Token must be masked")
end)

t.test("rpcd sanitize_output masks credentials and enforces bounds", function()
  local rpcd_source = read_file("root/usr/libexec/rpcd/luci.xc")
  t.contains(rpcd_source, "function sanitize_output(val)")
  t.contains(rpcd_source, "[redacted]")
  t.contains(rpcd_source, "%x%x%x%x%x%x%x%x%-%x%x%x%x")
end)

t.test("package scripts are executable", function()
  for _, path in ipairs({
    "root/etc/init.d/xc", "root/etc/hotplug.d/iface/95-xc",
    "root/etc/uci-defaults/80_luci-app-xc", "root/usr/bin/xc",
    "root/usr/libexec/rpcd/luci.xc"
  }) do
    t.eq(os.execute("test -x " .. path), 0, path .. " must be executable")
  end
end)

t.test("rpcd ACL and ucitrack declare valid privileges", function()
  local acl = read_file("root/usr/share/rpcd/acl.d/luci-app-xc.json")
  local track = read_file("root/usr/share/ucitrack/luci-app-xc.json")
  t.contains(acl, '"read"')
  t.contains(acl, '"write"')
  t.contains(acl, '"uci": [ "xc" ]')
  t.contains(acl, '"ubus"')
  t.contains(track, '"config": "xc"')
  t.contains(track, '"init": "xc"')
end)

t.test("translation catalogs are unique complete and valid gettext", function()
  local function unquote(value)
    local chunk = assert(loadstring("return " .. value))
    return chunk()
  end

  local function parse_catalog(path, require_translation)
    local entries, seen, block = {}, {}, nil
    local function finish()
      if not block then return end
      t.eq(block.fuzzy, false, path .. " fuzzy msgid " .. block.msgid)
      if block.msgid == "" then block = nil; return end
      t.eq(seen[block.msgid], nil, path .. " duplicate msgid " .. block.msgid)
      seen[block.msgid] = true
      if require_translation then
        t.truthy(block.msgstr and block.msgstr ~= "", path .. " empty msgstr " .. block.msgid)
      end
      entries[block.msgid] = block.msgstr
      block = nil
    end
    for line in (read_file(path) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if line == "" then
        finish()
      elseif line:match("^#,") and line:match("fuzzy") then
        block = block or { msgid = "", msgstr = "", field = nil, fuzzy = false }
        block.fuzzy = true
      else
        local field, quoted = line:match("^(msgid)%s+(\".*\")$")
        if not field then field, quoted = line:match("^(msgstr)%s+(\".*\")$") end
        if field then
          block = block or { msgid = "", msgstr = "", field = nil, fuzzy = false }
          block[field], block.field = unquote(quoted), field
        elseif block and block.field and line:match('^"') then
          block[block.field] = block[block.field] .. unquote(line)
        end
      end
    end
    finish()
    return entries, seen
  end

  local template_entries = parse_catalog("po/templates/xc.pot", false)
  local translations = parse_catalog("po/zh_Hans/xc.po", true)
  for msgid in pairs(template_entries) do
    t.truthy(translations[msgid] ~= nil, "Simplified Chinese missing " .. msgid)
  end
end)
