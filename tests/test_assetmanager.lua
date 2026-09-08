local t = require "testlib"
local manager_module = require "xc.assetmanager"
local mock_json = require "tests.mock_json"

local function json_quote(value)
  return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function json_encode(value)
  if type(value) == "string" then return json_quote(value) end
  if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
  local keys, output = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do output[#output + 1] = json_quote(key) .. ":" .. json_encode(value[key]) end
  return "{" .. table.concat(output, ",") .. "}"
end

local function fixture(options)
  options = options or {}
  local files = options.files or {}
  local dirs = {
    ["/etc/xc/xray/assets"] = true,
    ["/etc/xc/xray/assets/default"] = true
  }
  local events = {}
  local saved_global = {}
  local fs = {
    exists = function(path) return files[path] ~= nil or dirs[path] == true end,
    stat = function(path)
      if files[path] ~= nil then return { type = "reg", size = #files[path] } end
      if dirs[path] then return { type = "dir" } end
      return nil
    end,
    mkdir = function(path) dirs[path] = true; return true end,
    copy_file = function(source, destination)
      if files[source] == nil then return false end
      files[destination] = files[source]
      events[#events + 1] = "copy:" .. source .. ":" .. destination
      return true
    end,
    rename = function(source, destination)
      if files[source] == nil then return false end
      files[destination], files[source] = files[source], nil
      events[#events + 1] = "rename:" .. source .. ":" .. destination
      return true
    end,
    remove = function(path) files[path] = nil; return true end,
    read = function(path) return files[path] end,
    write_file = function(path, content) files[path] = content; return true end
  }
  local exec = {
    download = function(url, path, _, deadline)
      events[#events + 1] = "download:" .. url .. ":" .. path
      if options.capture_deadline then options.capture_deadline(deadline) end
      if options.download_ok == false then return false end
      files[path] = options.downloaded or "downloaded-new"
      return true
    end,
    extract_xray = function(_, path)
      files[path] = options.extracted or "xray-binary"
      return options.extract_ok ~= false
    end,
    machine = function() return options.machine or "aarch64" end,
    hash_file = function() return "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890" end,
    remote_metadata = function() return options.remote_metadata end
  }
  local core = {
    install = function(_, path, manifest)
      if files[path] == nil then return { ok = false, code = "core_install_failed" } end
      events[#events + 1] = "core-install:" .. manifest.id
      return { ok = true, code = "core_installed", version = manifest }
    end,
    rollback = function() return { ok = true, code = "core_rolled_back" } end,
    status = function()
      if options.core_status ~= nil then return options.core_status end
      return { ok = true, code = "core_status", current_info = { version = options.core_version } }
    end
  }
  local manager = manager_module.new({
    fs = fs, exec = exec, core = core,
    uci = {
      get_global = function() return options.uci_global end,
      stage_global = function(values)
        for key, value in pairs(values) do saved_global[key] = value end
        return options.stage_ok ~= false
      end,
      commit = function() return options.commit_ok ~= false end,
      revert = function() return true end
    },
    json = { parse = mock_json.parse, stringify = json_encode },
    now = function() return 100 end, wall_time = function() return 1700000000 end
  })
  return manager, { files = files, dirs = dirs, events = events, saved_global = saved_global }
end

t.test("asset sources are fixed and invalid source falls back to official", function()
  local manager = assert(fixture())
  local sources = manager:sources("geoip")
  t.truthy(#sources >= 2)
  t.truthy(manager:source("geoip", "official"))
  t.eq(manager:source("geoip", "user-url"), manager:source("geoip", "official"))
  t.eq(manager:source("user-kind", "official"), nil)
end)

t.test("jsDelivr mirror uses the responsive CDN endpoint", function()
  local manager = assert(fixture())
  t.contains(manager:source("geoip", "mirror").url, "https://testingcf.jsdelivr.net/gh/")
  t.contains(manager:source("geosite", "mirror").url, "https://testingcf.jsdelivr.net/gh/")
end)

t.test("asset update keeps one immutable default snapshot", function()
  local manager, state = fixture({ files = {
    ["/usr/share/xray/geoip.dat"] = "package-old"
  } })
  t.truthy(manager:update("geoip", "official").ok)
  t.eq(state.files["/etc/xc/xray/assets/default/geoip.dat"], "package-old")
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "downloaded-new")
  state.downloaded = "downloaded-later"
  t.truthy(manager:update("geoip", "mirror").ok)
  t.eq(state.files["/etc/xc/xray/assets/default/geoip.dat"], "package-old")
  t.truthy(manager:rollback("geoip").ok)
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "package-old")
end)

t.test("geo update downloads beside the managed target before atomic rename", function()
  local manager, state = fixture()
  t.truthy(manager:update("geoip", "mirror").ok)
  t.contains(table.concat(state.events, "|"), "download:https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat:/etc/xc/xray/assets/.asset-update-geoip")
end)

t.test("asset download failure preserves the active file", function()
  local manager, state = fixture({ download_ok = false, files = {
    ["/etc/xc/xray/assets/geoip.dat"] = "current"
  } })
  local result = manager:update("geoip", "official")
  t.eq(result.ok, false)
  t.eq(result.code, "asset_download_failed")
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "current")
end)

t.test("asset downloads allow a slow mirror within the bounded extended window", function()
  local deadline
  local manager = assert(fixture({ capture_deadline = function(value) deadline = value end }))
  t.truthy(manager:update("geoip", "mirror").ok)
  t.eq(deadline, 1300)
end)

t.test("xray update installs an inactive downloaded core without semantic validation", function()
  local manager, state = fixture({ downloaded = "xray-archive" })
  local result = manager:update("xray", "official")
  t.eq(result.ok, true)
  t.eq(result.code, "asset_updated")
  t.truthy(state.events[2]:match("core%-install:v26_6_27%-aarch64%-"))
end)

t.test("xray update normalizes common uname architecture aliases", function()
  local manager, state = fixture({ machine = "armv7l" })
  local result = manager:update("xray", "official")
  t.eq(result.ok, true)
  t.truthy(state.events[2]:match("core%-install:v26_6_27%-arm%-"))
end)

t.test("asset rollback without a default snapshot is safe", function()
  local manager, state = fixture({ files = { ["/etc/xc/xray/assets/geoip.dat"] = "current" } })
  local result = manager:rollback("geoip")
  t.eq(result.ok, false)
  t.eq(result.code, "asset_no_default")
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "current")
end)

t.test("asset update exposes installation stage callback", function()
  local manager = assert(fixture())
  local stage
  t.truthy(manager:update("geoip", "official", function(value) stage = value end).ok)
  t.eq(stage, "installing")
end)

t.test("asset metadata is stored without URL or secret fields", function()
  local manager, state = fixture()
  t.truthy(manager:save_metadata("geoip", "official", {
    etag = "etag-value", last_modified = "yesterday", size = 123
  }))
  local metadata = manager:metadata("geoip")
  t.eq(metadata.source, "official")
  t.eq(metadata.etag, "etag-value")
  t.eq(metadata.size, 123)
  t.eq(metadata.url, nil)
  t.truthy(metadata.updated_at ~= nil and #metadata.updated_at > 0, "save must record the local download date")
  t.eq(state.files["/etc/xc/xray/assets/update-metadata.json"]:find("etag-value", 1, true) ~= nil, true)
end)

t.test("asset check falls back to the recorded download date for the current version", function()
  local files = {}
  local previous = { source = "official", etag = "same-etag", size = 100, updated_at = "12 Aug 2026" }
  files["/etc/xc/xray/assets/update-metadata.json"] = json_encode({ geoip = previous })
  local manager = fixture({
    files = files,
    remote_metadata = { last_modified = "Wed, 12 Aug 2026 12:00:00 GMT" }
  })
  local result = manager:check_update("geoip", "official")
  t.eq(result.ok, true)
  t.eq(result.current_version, "12 Aug 2026", "the recorded download date is the local version")
  t.eq(result.latest_version, "12 Aug 2026")
end)

t.test("asset check reports a remote update for geo data without local metadata", function()
  local manager = fixture({ remote_metadata = { etag = "new-etag", size = 100 } })
  local result = manager:check_update("geoip", "official")
  t.eq(result.ok, true)
  t.eq(result.code, "asset_check_completed")
  t.eq(result.current_version, "")
  t.eq(result.latest_version, "", "no date is available, no opaque etag is shown as a version")
  t.eq(result.can_upgrade, true)
  t.eq(result.error, nil)
end)

t.test("asset check shows a readable date version from last-modified", function()
  local manager = fixture({
    remote_metadata = { last_modified = "Wed, 12 Aug 2026 12:00:00 GMT", etag = "\"0f2d4e9a\"", size = 100 }
  })
  local result = manager:check_update("geoip", "official")
  t.eq(result.ok, true)
  t.eq(result.latest_version, "12 Aug 2026", "the date must be preferred over the opaque etag hash")
  t.eq(result.can_upgrade, true)
end)

t.test("asset check reports up to date when validators match", function()
  local files = {}
  local previous = { source = "official", etag = "same-etag", size = 100 }
  files["/etc/xc/xray/assets/update-metadata.json"] = json_encode({ geoip = previous })
  local manager = fixture({
    files = files,
    remote_metadata = { etag = "same-etag", size = 100 }
  })
  local result = manager:check_update("geoip", "official")
  t.eq(result.ok, true)
  t.eq(result.current_version, "", "etag-only local metadata shows no date version")
  t.eq(result.latest_version, "", "etag-only remote metadata shows no date version")
  t.eq(result.can_upgrade, false)
end)

t.test("asset check fails closed when the remote metadata request fails", function()
  local manager = fixture({ remote_metadata = nil })
  local result = manager:check_update("geosite", "official")
  t.eq(result.ok, true)
  t.eq(result.error, "asset_check_failed")
  t.eq(result.can_upgrade, false)
  t.eq(result.latest_version, "")
end)

t.test("asset check compares the installed Xray version to the supported release", function()
  local old = fixture({ core_version = "24.12.31" })
  local old_result = old:check_update("xray", "official")
  t.eq(old_result.ok, true)
  t.eq(old_result.error, nil, "xray checks are local and must never report a remote check failure")
  t.eq(old_result.current_version, "24.12.31")
  t.eq(old_result.latest_version, "26.6.27")
  t.eq(old_result.can_upgrade, true)

  local current = fixture({ core_version = "26.6.27" })
  local current_result = current:check_update("xray", "official")
  t.eq(current_result.ok, true)
  t.eq(current_result.error, nil)
  t.eq(current_result.current_version, "26.6.27")
  t.eq(current_result.latest_version, "26.6.27")
  t.eq(current_result.can_upgrade, false)
end)

t.test("asset check rejects unknown kinds and falls back unknown sources", function()
  local manager = fixture()
  t.eq(manager:check_update("unknown", "official").ok, false)
  local fallback = manager:check_update("geoip", "not-a-source")
  t.eq(fallback.ok, true)
  t.eq(fallback.source, "official", "unknown source ids must fall back to official")
end)

t.test("asset proxy apply saves validated settings when enabled", function()
  local manager, state = fixture()
  local result = manager:apply_proxy({
    enabled = true, type = "socks", address = "192.168.6.1", port = "7890",
    username = "user", password = "secret"
  })
  t.eq(result.ok, true)
  t.eq(result.code, "asset_proxy_applied")
  t.eq(state.saved_global.asset_proxy_enabled, "1")
  t.eq(state.saved_global.asset_proxy_type, "socks")
  t.eq(state.saved_global.asset_proxy_address, "192.168.6.1")
  t.eq(state.saved_global.asset_proxy_port, "7890")
  t.eq(state.saved_global.asset_proxy_username, "user")
  t.eq(state.saved_global.asset_proxy_password, "secret")
end)

t.test("asset proxy apply rejects enabled proxies missing required fields", function()
  local manager = fixture()
  t.eq(manager:apply_proxy({ enabled = true, address = "", port = "7890" }).code, "asset_proxy_address_required")
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "70000" }).code, "asset_proxy_port_invalid")
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "abc" }).code, "asset_proxy_port_invalid")
end)

t.test("asset proxy apply keeps the saved password when left empty", function()
  local manager, state = fixture({
    uci_global = { asset_proxy_password = "previous-pass", asset_proxy_address = "10.0.0.1" }
  })
  local result = manager:apply_proxy({ enabled = true, address = "10.0.0.2", port = "7890", password = "" })
  t.eq(result.ok, true)
  t.eq(state.saved_global.asset_proxy_password, "previous-pass", "empty password must preserve the saved one")
  t.eq(state.saved_global.asset_proxy_address, "10.0.0.2")
end)

t.test("asset proxy apply saves disabled state and new password", function()
  local manager, state = fixture()
  t.truthy(manager:apply_proxy({ enabled = false, address = "10.0.0.1", port = "7890", password = "new-pass" }).ok)
  t.eq(state.saved_global.asset_proxy_enabled, "0")
  t.eq(state.saved_global.asset_proxy_password, "new-pass")
end)

t.test("asset proxy apply surfaces commit failures", function()
  local manager = fixture({ commit_ok = false })
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "7890" }).code, "asset_commit_failed")
end)

t.test("asset proxy settings expose status without the stored password", function()
  local manager = fixture({
    uci_global = { asset_proxy_enabled = "1", asset_proxy_type = "http",
      asset_proxy_address = "10.0.0.1", asset_proxy_port = "8888",
      asset_proxy_username = "user", asset_proxy_password = "secret" }
  })
  local settings = manager:proxy_settings()
  t.eq(settings.enabled, true)
  t.eq(settings.type, "http")
  t.eq(settings.address, "10.0.0.1")
  t.eq(settings.port, "8888")
  t.eq(settings.username, "user")
  t.eq(settings.password, nil, "status must never expose the stored password")
  t.eq(settings.has_password, true)
end)

t.test("asset proxy apply rejects credentials and addresses that break the proxy URL", function()
  local manager = fixture()
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1@evil.com", port = "7890" }).code,
    "asset_proxy_address_required", "address must not contain @")
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1/path", port = "7890" }).code,
    "asset_proxy_address_required", "address must not contain /")
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "7890", username = "a:b" }).code,
    "asset_proxy_invalid", "username must not contain the credential separator")
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "7890", username = string.rep("a", 129) }).code,
    "asset_proxy_invalid", "overlong username must be rejected")
  t.eq(manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "7890", username = "ok", password = "bad\1char" }).code,
    "asset_proxy_invalid", "control characters in the password must be rejected")
end)

t.test("asset proxy apply keeps a saved password even when global config is unreadable", function()
  local manager, state = fixture({ stage_ok = true })
  local result = manager:apply_proxy({ enabled = true, address = "10.0.0.1", port = "7890", password = "" })
  t.eq(result.ok, true)
  t.eq(state.saved_global.asset_proxy_password, nil, "password field must be left untouched when no saved password is readable")
end)

return true
