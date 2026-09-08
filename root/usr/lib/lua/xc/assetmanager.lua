local routing = require "xc.routing"
local core = require "xc.core"

local M = {}
local Manager = {}
Manager.__index = Manager

local XRAY_VERSION = routing.MAX_SUPPORTED_VERSION
local ACTIVE_DIR = routing.MANAGED_ASSET_DIR
local DEFAULT_DIR = ACTIVE_DIR .. "/default"
local METADATA_PATH = ACTIVE_DIR .. "/update-metadata.json"
local SOURCE_PREFIX = "https://gh-proxy.net/"
local DOWNLOAD_TIMEOUT = 1200

local SOURCE_TABLE = {
  xray = {
    official = {
      id = "official", label = "Official GitHub", format = "zip",
      url = "https://github.com/XTLS/Xray-core/releases/download/v" .. XRAY_VERSION .. "/Xray-linux-%s.zip"
    },
    mirror = {
      id = "mirror", label = "GitHub mirror", format = "zip",
      url = SOURCE_PREFIX .. "https://github.com/XTLS/Xray-core/releases/download/v" .. XRAY_VERSION .. "/Xray-linux-%s.zip"
    }
  },
  geoip = {
    official = {
      id = "official", label = "Official rules release", format = "dat",
      url = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    },
    mirror = {
      id = "mirror", label = "jsDelivr mirror", format = "dat",
      url = "https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
    }
  },
  geosite = {
    official = {
      id = "official", label = "Official rules release", format = "dat",
      url = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    },
    mirror = {
      id = "mirror", label = "jsDelivr mirror", format = "dat",
      url = "https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
    }
  }
}

local FILE_NAMES = { geoip = "geoip.dat", geosite = "geosite.dat" }
local ARCHIVE_ARCH = {
  aarch64 = "arm64-v8a", arm = "arm32-v7a", x86_64 = "64", i386 = "32"
}
local ARCH_ALIASES = {
  aarch64 = "aarch64", arm64 = "aarch64", armv8l = "arm", armv7 = "arm", armv7l = "arm", arm = "arm",
  x86_64 = "x86_64", amd64 = "x86_64", i386 = "i386", i486 = "i386", i586 = "i386", i686 = "i386"
}

local function result(ok, code, fields)
  local output = { ok = ok, code = code }
  for key, value in pairs(fields or {}) do output[key] = value end
  return output
end

local function safe_kind(kind)
  return type(kind) == "string" and SOURCE_TABLE[kind] ~= nil
end

local function safe_source(source)
  return type(source) == "string" and #source <= 32 and source:match("^[a-z][a-z0-9_-]*$") ~= nil
end

local function public_source(source)
  return { id = source.id, label = source.label }
end

local function validator_count(metadata)
  local count = 0
  for _, key in ipairs({ "etag", "last_modified", "size" }) do
    if metadata[key] ~= nil then count = count + 1 end
  end
  return count
end

local function metadata_same(previous, current, source)
  if type(previous) ~= "table" or type(current) ~= "table" or previous.source ~= source then return false end
  if validator_count(current) == 0 then return false end
  for _, key in ipairs({ "etag", "last_modified", "size" }) do
    if current[key] ~= nil and previous[key] ~= current[key] then return false end
  end
  return true
end

local function display_metadata(metadata)
  if type(metadata) ~= "table" then return nil end
  local value
  if type(metadata.last_modified) == "string" then
    -- HTTP 日期形如 "Wed, 12 Aug 2026 12:00:00 GMT"：取可读的日期部分。
    value = metadata.last_modified:match("(%d+ %a+ %d+)")
  end
  -- 远程无 last-modified 时回退到本地记录的下载日期；不展示 etag/大小等长标识。
  if type(value) ~= "string" or #value == 0 then
    value = type(metadata.updated_at) == "string" and metadata.updated_at or nil
    if type(value) == "string" and (#value == 0 or #value > 64) then value = nil end
  end
  return value
end

local function clean_plain(value, maximum)
  if type(value) ~= "string" then return "" end
  if #value > maximum or value:find("[%z\1-\31\127]") then return nil end
  return value
end

local function normalize_proxy(values)
  if type(values) ~= "table" then return nil, "asset_proxy_invalid" end
  local enabled = values.enabled == true or values.enabled == 1 or values.enabled == "1"
  local kind = values.type == "http" and "http" or "socks"
  local address = clean_plain(values.address, 253) or ""
  -- 拒绝会破坏 curl 代理 URL 的字符：@、/、空白以及路径片段。
  if address ~= "" and address:find("[@/ \t\r\n]") then address = "" end
  local port_text = clean_plain(values.port, 5)
  local port = type(port_text) == "string" and port_text:match("^%d+$") and tonumber(port_text) or nil
  if port ~= nil and (port < 1 or port > 65535) then port = nil end
  if enabled then
    if address == "" then return nil, "asset_proxy_address_required" end
    if port == nil then return nil, "asset_proxy_port_invalid" end
  end
  local username = clean_plain(values.username, 128)
  local password = clean_plain(values.password, 128)
  if username == nil or password == nil then return nil, "asset_proxy_invalid" end
  -- 冒号是 --proxy-user 的用户名/密码分隔符，空白会破坏参数边界。
  if username:find("[: \t\r\n]") then return nil, "asset_proxy_invalid" end
  return {
    enabled = enabled, type = kind, address = address,
    port = port and tostring(port) or "",
    username = username, password = password
  }
end

local function asset_path(kind)
  return ACTIVE_DIR .. "/" .. FILE_NAMES[kind]
end

local function default_path(kind)
  return DEFAULT_DIR .. "/" .. FILE_NAMES[kind]
end

local function ensure_dir(fs, path)
  if fs.exists(path) then return true end
  return type(fs.mkdir) == "function" and fs.mkdir(path, 700) == true
end

local function source_path(fs, kind)
  for _, directory in ipairs({ ACTIVE_DIR, routing.ASSET_DIR, routing.FALLBACK_ASSET_DIR }) do
    local path = directory .. "/" .. FILE_NAMES[kind]
    if fs.exists(path) then return path end
  end
  return nil
end

local function arch_info(arch)
  if type(arch) ~= "string" then return nil end
  local raw = arch:lower()
  local normalized = ARCH_ALIASES[raw]
  return normalized, normalized and ARCHIVE_ARCH[normalized]
end

function M.new(adapters)
  if type(adapters) ~= "table" or type(adapters.fs) ~= "table" or type(adapters.exec) ~= "table"
    or type(adapters.now) ~= "function" or type(adapters.wall_time) ~= "function" then return nil end
  if type(adapters.fs.exists) ~= "function" or type(adapters.fs.mkdir) ~= "function"
    or type(adapters.fs.copy_file) ~= "function" or type(adapters.fs.rename) ~= "function"
    or type(adapters.fs.remove) ~= "function" or type(adapters.fs.stat) ~= "function"
    or type(adapters.exec.download) ~= "function" or type(adapters.exec.extract_xray) ~= "function" then return nil end
  return setmetatable({ fs = adapters.fs, exec = adapters.exec, core = adapters.core,
    uci = adapters.uci, json = adapters.json, now = adapters.now, wall_time = adapters.wall_time }, Manager)
end

function Manager:source(kind, id)
  if not safe_kind(kind) then return nil end
  return SOURCE_TABLE[kind][id] or SOURCE_TABLE[kind].official
end

function Manager:sources(kind)
  if not safe_kind(kind) then return {} end
  local values = {}
  for _, id in ipairs({ "official", "mirror" }) do
    values[#values + 1] = public_source(SOURCE_TABLE[kind][id])
  end
  return values
end

function Manager:status()
  local assets = routing.asset_status(self.fs)
  local defaults = {}
  for _, kind in ipairs({ "geoip", "geosite" }) do defaults[kind] = self.fs.exists(default_path(kind)) end
  assets.sources = {}
  assets.selected = {}
  assets.defaults = defaults
  for _, kind in ipairs({ "xray", "geoip", "geosite" }) do
    assets.sources[kind] = self:sources(kind)
    local selected = "official"
    local global = self.uci and self.uci.get_global and self.uci.get_global() or nil
    local option = type(global) == "table" and global[kind .. "_update_source"] or nil
    if type(option) == "string" and SOURCE_TABLE[kind][option] then selected = option end
    assets.selected[kind] = selected
  end
  assets.proxy = self:proxy_settings()
  return assets
end

function Manager:proxy_settings()
  local global = type(self.uci) == "table" and type(self.uci.get_global) == "function" and self.uci.get_global() or nil
  if type(global) ~= "table" then return { enabled = false, type = "socks", address = "", port = "", username = "" } end
  local enabled = global.asset_proxy_enabled == "1" or global.asset_proxy_enabled == 1 or global.asset_proxy_enabled == true
  local kind = global.asset_proxy_type == "http" and "http" or "socks"
  local address = clean_plain(global.asset_proxy_address, 253) or ""
  local port = clean_plain(global.asset_proxy_port, 5) or ""
  local username = clean_plain(global.asset_proxy_username, 128) or ""
  local password = clean_plain(global.asset_proxy_password, 128)
  return {
    enabled = enabled, type = kind, address = address, port = port,
    username = username, has_password = password ~= nil and password ~= ""
  }
end

function Manager:check_update(kind, source_id)
  if not safe_kind(kind) or not safe_source(source_id) then return result(false, "asset_invalid") end
  local source = self:source(kind, source_id)
  if not source then return result(false, "asset_invalid") end
  local remote
  if kind ~= "xray" and type(self.exec.remote_metadata) == "function" then
    local called, value = pcall(self.exec.remote_metadata, source.url, self.now() + 30)
    if called and type(value) == "table" then remote = value end
  end
  local previous = self:metadata(kind)
  local current_version, latest_version
  local check_failed = false
  if kind == "xray" then
    -- Xray 的版本比较完全在本地进行（已安装核心 vs 支持的版本），
    -- 其下载 URL 含架构占位符，不能直接用于远程元数据检查。
    if type(self.core) == "table" and type(self.core.status) == "function" then
      local called, status = pcall(self.core.status, self.core)
      if called and type(status) == "table" and type(status.current_info) == "table"
        and type(status.current_info.version) == "string" then
        current_version = status.current_info.version
      end
    end
    latest_version = XRAY_VERSION
  else
    current_version = display_metadata(previous)
    latest_version = display_metadata(remote)
    if remote == nil then check_failed = true end
  end
  local can_upgrade
  if kind == "xray" then
    can_upgrade = type(current_version) == "string" and current_version ~= XRAY_VERSION
  else
    -- 远程元数据缺少校验器或源切换时保守地视为可更新（fail-open），
    -- 因为本地快照与远端无法严格比较。
    can_upgrade = remote ~= nil and not metadata_same(previous, remote, source.id)
  end
  local output = { ok = true, code = "asset_check_completed", kind = kind, source = source.id,
    current_version = current_version or "", latest_version = latest_version or "",
    can_upgrade = can_upgrade == true }
  if check_failed then output.error = "asset_check_failed" end
  return output
end

function Manager:apply_proxy(values)
  local normalized, error_code = normalize_proxy(values)
  if not normalized then return result(false, error_code or "asset_proxy_invalid") end
  if type(self.uci) ~= "table" or type(self.uci.stage_global) ~= "function"
    or type(self.uci.commit) ~= "function" then return result(false, "asset_runtime_unavailable") end
  local global = type(self.uci.get_global) == "function" and self.uci.get_global() or nil
  local fields = {
    asset_proxy_enabled = normalized.enabled and "1" or "0",
    asset_proxy_type = normalized.type,
    asset_proxy_address = normalized.address,
    asset_proxy_port = normalized.port,
    asset_proxy_username = normalized.username
  }
  -- 密码框留空时保留已保存的密码；填入非空值才更新。
  -- 若无法读取现有配置，则不写入密码字段，避免用空值覆盖。
  local password = normalized.password
  local password_field = nil
  if password ~= "" then
    password_field = password
  elseif type(global) == "table" then
    password_field = type(global.asset_proxy_password) == "string" and global.asset_proxy_password or ""
  end
  if password_field ~= nil then fields.asset_proxy_password = password_field end
  local staged_called, staged = pcall(self.uci.stage_global, fields)
  if not staged_called or staged ~= true then
    if type(self.uci.revert) == "function" then pcall(self.uci.revert) end
    return result(false, "asset_commit_failed")
  end
  local committed_called, committed = pcall(self.uci.commit)
  if not committed_called or committed ~= true then
    if type(self.uci.revert) == "function" then pcall(self.uci.revert) end
    return result(false, "asset_commit_failed")
  end
  return result(true, "asset_proxy_applied")
end

function Manager:_update_geo(kind, source, on_stage, cancel_path, on_progress)
  local fs = self.fs
  if not ensure_dir(fs, ACTIVE_DIR) or not ensure_dir(fs, DEFAULT_DIR) then return result(false, "asset_install_failed") end
  local target, temporary = asset_path(kind), ACTIVE_DIR .. "/.asset-update-" .. kind
  if not fs.exists(default_path(kind)) then
    local baseline = fs.exists(target) and target or source_path(fs, kind)
    if baseline and not fs.copy_file(baseline, default_path(kind), 67108864, 600) then
      return result(false, "asset_install_failed")
    end
  end
  fs.remove(temporary)
  if self.exec.download(source.url, temporary, 67108864, self.now() + DOWNLOAD_TIMEOUT, cancel_path, on_progress) ~= true then
    fs.remove(temporary)
    return result(false, "asset_download_failed")
  end
  if type(on_stage) == "function" then pcall(on_stage, "installing") end
  local renamed = fs.rename(temporary, target)
  fs.remove(temporary)
  if not renamed then return result(false, "asset_install_failed") end
  return result(true, "asset_updated", { kind = kind, source = source.id, default = fs.exists(default_path(kind)) })
end

function Manager:_update_xray(source, on_stage, cancel_path, on_progress)
  if type(self.core) ~= "table" or type(self.core.install) ~= "function"
    or type(self.exec.machine) ~= "function" or type(self.exec.hash_file) ~= "function" then
    return result(false, "asset_runtime_unavailable")
  end
  local raw_arch = self.exec.machine(self.now() + 5)
  local arch, release_arch = arch_info(raw_arch)
  if not arch or not release_arch then return result(false, "asset_invalid") end
  local archive = "/var/etc/xc/.asset-update-xray.zip"
  local binary = "/var/etc/xc/.asset-update-xray"
  self.fs.remove(archive); self.fs.remove(binary)
  local url = string.format(source.url, release_arch)
  if self.exec.download(url, archive, 67108864, self.now() + DOWNLOAD_TIMEOUT, cancel_path, on_progress) ~= true then
    self.fs.remove(archive); return result(false, "asset_download_failed")
  end
  if type(on_stage) == "function" then pcall(on_stage, "installing") end
  if self.exec.extract_xray(archive, binary, self.now() + 30) ~= true then
    self.fs.remove(archive); self.fs.remove(binary); return result(false, "asset_install_failed")
  end
  local stat = self.fs.stat(binary)
  local hash = self.exec.hash_file(binary, self.now() + 30)
  if type(stat) ~= "table" or stat.type ~= "reg" or type(stat.size) ~= "number" or stat.size < 1
    or type(hash) ~= "string" then
    self.fs.remove(archive); self.fs.remove(binary); return result(false, "asset_install_failed")
  end
  local id = core.version_id(XRAY_VERSION, arch, hash)
  local manifest = id and { id = id, version = XRAY_VERSION, arch = arch, size = stat.size,
    sha256 = hash, uploaded_at = self.wall_time(), validation = "binary" } or nil
  local installed = manifest and self.core:install(binary, manifest) or nil
  self.fs.remove(archive); self.fs.remove(binary)
  if type(installed) ~= "table" or installed.ok ~= true then return result(false, "asset_install_failed") end
  return result(true, "asset_updated", { kind = "xray", source = source.id, version = installed.version })
end

function Manager:update(kind, source_id, on_stage, cancel_path, on_progress)
  if not safe_kind(kind) then return result(false, "asset_invalid") end
  local source = self:source(kind, source_id)
  if kind == "xray" then return self:_update_xray(source, on_stage, cancel_path, on_progress) end
  return self:_update_geo(kind, source, on_stage, cancel_path, on_progress)
end

function Manager:metadata(kind)
  if not safe_kind(kind) or type(self.json) ~= "table" or type(self.json.parse) ~= "function"
    or type(self.fs.read) ~= "function" then return nil end
  local text = self.fs.read(METADATA_PATH, 32768)
  if type(text) ~= "string" then return nil end
  local called, value = pcall(self.json.parse, text)
  return called and type(value) == "table" and type(value[kind]) == "table" and value[kind] or nil
end

function Manager:save_metadata(kind, source_id, metadata)
  if not safe_kind(kind) or not safe_source(source_id) or type(metadata) ~= "table"
    or type(self.json) ~= "table" or type(self.json.stringify) ~= "function"
    or type(self.fs.write_file) ~= "function" then return false end
  local current = {}
  if type(self.fs.read) == "function" then
    local text = self.fs.read(METADATA_PATH, 32768)
    if type(text) == "string" and type(self.json.parse) == "function" then
      local called, parsed = pcall(self.json.parse, text)
      if called and type(parsed) == "table" then current = parsed end
    end
  end
  local value = { source = source_id }
  for _, key in ipairs({ "etag", "last_modified", "size" }) do
    local item = metadata[key]
    if key == "size" then
      if type(item) == "number" and item >= 0 and item <= 67108864 and math.floor(item) == item then value[key] = item end
    elseif type(item) == "string" and #item <= 256 and not item:find("[%z\1-\31\127]") then
      value[key] = item
    end
  end
  -- 记录本地下载日期，作为版本显示的兜底（远程可能不提供 last-modified）。
  if type(self.wall_time) == "function" then
    local called, date = pcall(os.date, "%d %b %Y", self.wall_time())
    if called and type(date) == "string" and #date <= 64 and not date:find("[%z\1-\31\127]") then
      value.updated_at = date
    end
  end
  current[kind] = value
  local called, encoded = pcall(self.json.stringify, current)
  if not called or type(encoded) ~= "string" or #encoded > 32768 then return false end
  return self.fs.write_file(METADATA_PATH, encoded, 600) == true
end

function Manager:save_source(kind, source_id)
  if not safe_kind(kind) or not safe_source(source_id) or not self:source(kind, source_id)
    or type(self.uci) ~= "table" or type(self.uci.stage_global) ~= "function"
    or type(self.uci.commit) ~= "function" then return false end
  local values = { [kind .. "_update_source"] = source_id }
  local staged_called, staged = pcall(self.uci.stage_global, values)
  if not staged_called or staged ~= true then
    if type(self.uci.revert) == "function" then pcall(self.uci.revert) end
    return false
  end
  local committed_called, committed = pcall(self.uci.commit)
  if not committed_called or committed ~= true then
    if type(self.uci.revert) == "function" then pcall(self.uci.revert) end
    return false
  end
  return true
end

function Manager:rollback(kind)
  if kind == "xray" then
    if type(self.core) ~= "table" or type(self.core.rollback) ~= "function" then return result(false, "asset_runtime_unavailable") end
    return self.core:rollback()
  end
  if not FILE_NAMES[kind] then return result(false, "asset_invalid") end
  local backup = default_path(kind)
  if not self.fs.exists(backup) then return result(false, "asset_no_default") end
  if self.fs.copy_file(backup, asset_path(kind), 67108864, 600) ~= true then return result(false, "asset_install_failed") end
  return result(true, "asset_rolled_back", { kind = kind })
end

M.ACTIVE_DIR = ACTIVE_DIR
M.DEFAULT_DIR = DEFAULT_DIR
M.METADATA_PATH = METADATA_PATH
M.SOURCES = SOURCE_TABLE

return M
