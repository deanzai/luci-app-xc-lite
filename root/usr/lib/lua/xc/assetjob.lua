local M = {}
local Job = {}
Job.__index = Job

local STATUS_PATH = "/var/etc/xc/asset-update-status.json"
local LOCK_PATH = "/var/etc/xc/asset-update.lock"
local CANCEL_PATH = "/var/etc/xc/asset-update-cancel"
local STATUS_MAX = 32768
local MAX_AGE = 1800
local TEMP_PATHS = {
  geoip = "/etc/xc/xray/assets/.asset-update-geoip",
  geosite = "/etc/xc/xray/assets/.asset-update-geosite",
  xray = "/var/etc/xc/.asset-update-xray.zip"
}
local KINDS = { xray = true, geoip = true, geosite = true }
local ACTIVE_STAGES = { starting = true, checking = true, downloading = true, installing = true }

local function result(ok, code, fields)
  local value = { ok = ok, code = code }
  for key, item in pairs(fields or {}) do value[key] = item end
  return value
end

local function safe_kind(kind)
  return type(kind) == "string" and KINDS[kind] == true
end

local function safe_source(source)
  return type(source) == "string" and source:match("^[a-z][a-z0-9_-]*$") ~= nil and #source <= 32
end

local function safe_job_id(job_id)
  return type(job_id) == "string" and job_id:match("^[0-9][0-9%-]*$") ~= nil and #job_id <= 64
end

local function public_version(value)
  if type(value) == "table" then value = value.version end
  return type(value) == "string" and #value <= 64
    and value:match("^[a-z0-9][a-z0-9_.%-]*$") ~= nil and value or nil
end

local function active(stage)
  return ACTIVE_STAGES[stage] == true
end

local function elapsed_ms(self, started_at)
  local called, current = pcall(self.now)
  current = called and tonumber(current) or tonumber(started_at) or 0
  started_at = tonumber(started_at) or current
  local elapsed = math.floor((current - started_at) * 1000 + 0.5)
  if elapsed < 0 then elapsed = 0 elseif elapsed > 1800000 then elapsed = 1800000 end
  return elapsed
end

local function copy_fields(state, fields)
  local output = {}
  for _, key in ipairs({ "job_id", "kind", "source", "stage", "code", "started_at", "updated_at",
    "total_bytes", "downloaded_bytes", "percent", "version", "default" }) do
    if state[key] ~= nil then output[key] = state[key] end
  end
  for key, value in pairs(fields or {}) do output[key] = value end
  return output
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

function M.new(adapters)
  if type(adapters) ~= "table" or type(adapters.fs) ~= "table" or type(adapters.exec) ~= "table"
    or type(adapters.manager) ~= "table" or type(adapters.json) ~= "table"
    or type(adapters.fs.read) ~= "function" or type(adapters.fs.write_file) ~= "function"
    or type(adapters.fs.remove) ~= "function"
    or type(adapters.fs.acquire_lock) ~= "function" or type(adapters.fs.release_lock) ~= "function"
    or type(adapters.fs.stat) ~= "function" or type(adapters.exec.start_asset_update) ~= "function"
    or type(adapters.now) ~= "function" or type(adapters.wall_time) ~= "function" then return nil end
  if type(adapters.manager.source) ~= "function" or type(adapters.manager.update) ~= "function" then return nil end
  return setmetatable({ fs = adapters.fs, exec = adapters.exec, manager = adapters.manager,
    json = adapters.json, now = adapters.now, wall_time = adapters.wall_time,
    record_event = adapters.record_event }, Job)
end

function Job:_event(message, fields, level)
  if type(self.record_event) ~= "function" then return end
  pcall(self.record_event, message, fields or {}, level or "info")
end

function Job:_read()
  local text = self.fs.read(STATUS_PATH, STATUS_MAX)
  if type(text) ~= "string" then return nil end
  local called, value = pcall(self.json.parse, text)
  if not called or type(value) ~= "table" or not safe_job_id(value.job_id)
    or not safe_kind(value.kind) or not safe_source(value.source) then return nil end
  return value
end

function Job:_write(state, fields)
  local value = copy_fields(state, fields)
  value.updated_at = self.wall_time()
  local called, encoded = pcall(self.json.stringify, value)
  if not called or type(encoded) ~= "string" or #encoded > STATUS_MAX then return false end
  return self.fs.write_file(STATUS_PATH, encoded, 600) == true
end

function Job:_cancel_requested(job_id)
  local called, marker = pcall(self.fs.read, CANCEL_PATH, 128)
  return called and marker == job_id
end

function Job:_remove_temporary(kind)
  local path = TEMP_PATHS[kind]
  return path == nil or self.fs.remove(path) == true
end

function Job:_new_id()
  return tostring(math.floor(self.wall_time())) .. "-" .. tostring(math.floor(self.now() * 1000))
end

function Job:_stale(state)
  return active(state.stage) and type(state.started_at) == "number"
    and self.wall_time() - state.started_at > MAX_AGE
end

function Job:start(kind, source)
  if not safe_kind(kind) or not safe_source(source) or not self.manager:source(kind, source) then
    return result(false, "asset_invalid")
  end
  local lock = self.fs.acquire_lock(LOCK_PATH)
  if not lock then return result(false, "asset_update_busy") end
  local current = self:_read()
  if current and active(current.stage) and not self:_stale(current) then
    self.fs.release_lock(lock)
    return result(false, "asset_update_busy")
  end
  if self.fs.remove(CANCEL_PATH) ~= true then
    self.fs.release_lock(lock)
    return result(false, "asset_runtime_unavailable")
  end
  local job_id = self:_new_id()
  local state = { job_id = job_id, kind = kind, source = source, stage = "starting",
    code = "asset_update_started", started_at = self.wall_time(), downloaded_bytes = 0, total_bytes = 0 }
  local written = self:_write(state)
  local released = self.fs.release_lock(lock)
  if not written or not released then return result(false, "asset_runtime_unavailable") end
  local called, started = pcall(self.exec.start_asset_update, kind, source, job_id)
  if not called or started ~= true then
    self:mark_failed(job_id, "asset_runtime_unavailable")
    return result(false, "asset_runtime_unavailable")
  end
  self:_event("asset update started", { operation = "asset_update", stage = "started", code = "asset_update_started",
    outcome = "started", kind = kind, source = source, job_id = job_id, elapsed_ms = 0 })
  return result(true, "asset_update_started", { job_id = job_id, kind = kind, stage = "checking" })
end

function Job:cancel(job_id)
  if not safe_job_id(job_id) then return result(false, "asset_invalid") end
  local state = self:_read()
  if not state or state.job_id ~= job_id or not active(state.stage) or self:_stale(state) then
    return result(false, "asset_invalid")
  end
  if self.fs.write_file(CANCEL_PATH, job_id, 600) ~= true then
    return result(false, "asset_runtime_unavailable")
  end
  self:_event("asset cancellation requested", { operation = "asset_update", stage = "cancel_requested",
    code = "asset_update_cancel_requested", outcome = "requested", kind = state.kind, source = state.source,
    job_id = job_id, elapsed_ms = 0 })
  return result(true, "asset_update_cancel_requested", { job_id = job_id })
end

function Job:mark_failed(job_id, code)
  if not safe_job_id(job_id) then return false end
  local lock = self.fs.acquire_lock(LOCK_PATH)
  if not lock then return false end
  local state = self:_read()
  local written = state and state.job_id == job_id and self:_write(state, { stage = "failed", code = code })
  local released = self.fs.release_lock(lock)
  return written == true and released == true
end

function Job:run(kind, source, job_id)
  if not safe_kind(kind) or not safe_source(source) or not safe_job_id(job_id) then
    return result(false, "asset_invalid")
  end
  local lock = self.fs.acquire_lock(LOCK_PATH)
  if not lock then return result(false, "asset_update_busy") end
  local state = self:_read()
  if not state or state.job_id ~= job_id or state.kind ~= kind or state.source ~= source then
    self.fs.release_lock(lock)
    return result(false, "asset_invalid")
  end
  local started_at = self.now()
  local function finish(stage, code, fields)
    fields = fields or {}
    fields.stage = stage
    fields.code = code
    local written = self:_write(state, fields)
    local temporary_removed = self:_remove_temporary(kind)
    local marker_removed = self.fs.remove(CANCEL_PATH) == true
    local released = self.fs.release_lock(lock)
    local succeeded = written == true and temporary_removed and marker_removed and released == true
      and stage ~= "failed" and stage ~= "cancelled"
    self:_event("asset update completed", { operation = "asset_update", stage = "completed", terminal_stage = stage,
      code = code, outcome = succeeded and "success" or "failure", kind = kind, source = source,
      job_id = job_id, elapsed_ms = elapsed_ms(self, started_at) })
    return result(succeeded
      and stage ~= "failed" and stage ~= "cancelled", code, fields)
  end
  local function cancelled()
    if self:_cancel_requested(job_id) then return finish("cancelled", "asset_update_cancelled") end
  end
  local requested = cancelled()
  if requested then return requested end
  if not self:_write(state, { stage = "checking", code = "asset_update_checking" }) then
    self:_remove_temporary(kind); self.fs.remove(CANCEL_PATH); self.fs.release_lock(lock)
    return result(false, "asset_runtime_unavailable")
  end
  local selected = self.manager:source(kind, source)
  if not selected then return finish("failed", "asset_invalid") end
  requested = cancelled()
  if requested then return requested end
  local remote
  if type(self.exec.remote_metadata) == "function" then
    local called, value = pcall(self.exec.remote_metadata, selected.url, self.now() + 30)
    if called and type(value) == "table" then remote = value end
  end
  local previous = type(self.manager.metadata) == "function" and self.manager:metadata(kind) or nil
  if remote and metadata_same(previous, remote, source) then
    return finish("unchanged", "asset_update_unchanged", { total_bytes = remote.size or 0, percent = 100 })
  end
  local total = remote and tonumber(remote.size) or 0
  if total < 0 or total > 67108864 then total = 0 end
  if not self:_write(state, { stage = "downloading", code = "asset_update_downloading",
    total_bytes = math.floor(total), downloaded_bytes = 0, percent = 0 }) then
    self:_remove_temporary(kind); self.fs.remove(CANCEL_PATH); self.fs.release_lock(lock)
    return result(false, "asset_runtime_unavailable")
  end
  self:_event("asset download started", { operation = "asset_update", stage = "downloading",
    code = "asset_update_downloading", outcome = "started", kind = kind, source = source, job_id = job_id,
    total_bytes = math.floor(total), downloaded_bytes = 0, percent = 0, elapsed_ms = elapsed_ms(self, started_at) })
  requested = cancelled()
  if requested then return requested end
  local reported = {}
  local thresholds = { 25, 50, 75, 99 }
  local function on_progress(downloaded)
    downloaded = type(downloaded) == "number" and math.max(0, math.floor(downloaded)) or 0
    if total <= 0 then return end
    local percent = math.max(0, math.min(99, math.floor(downloaded * 100 / total + 0.5)))
    for _, threshold in ipairs(thresholds) do
      if percent >= threshold and not reported[threshold] then
        reported[threshold] = true
        self:_write(state, { downloaded_bytes = downloaded, total_bytes = math.floor(total), percent = percent })
        self:_event("asset download progress", { operation = "asset_update", stage = "downloading",
          code = "asset_update_downloading", outcome = "progress", kind = kind, source = source, job_id = job_id,
          total_bytes = math.floor(total), downloaded_bytes = downloaded, percent = threshold,
          elapsed_ms = elapsed_ms(self, started_at) })
      end
    end
  end
  local function on_stage(stage)
    if stage == "installing" and not self:_cancel_requested(job_id) then
      self:_write(state, { stage = "installing", code = "asset_update_installing" })
      self:_event("asset install started", { operation = "asset_update", stage = "installing",
        code = "asset_update_installing", outcome = "started", kind = kind, source = source, job_id = job_id,
        elapsed_ms = elapsed_ms(self, started_at) })
    end
  end
  local called, updated = pcall(self.manager.update, self.manager, kind, source, on_stage, CANCEL_PATH, on_progress)
  requested = cancelled()
  if requested then return requested end
  if not called or type(updated) ~= "table" or updated.ok ~= true then
    local code = called and type(updated) == "table" and updated.code or "asset_install_failed"
    return finish("failed", code)
  end
  if remote and type(self.manager.save_metadata) == "function" then
    pcall(self.manager.save_metadata, self.manager, kind, source, remote)
  end
  requested = cancelled()
  if requested then return requested end
  if type(self.manager.save_source) == "function" then
    local saved_called, saved = pcall(self.manager.save_source, self.manager, kind, source)
    if not saved_called or saved ~= true then return finish("failed", "asset_commit_failed") end
  end
  local version = public_version(updated.version)
  return finish("succeeded", "asset_update_succeeded", {
    total_bytes = math.floor(total), percent = 100, version = version, default = updated.default
  })
end

function Job:status()
  local state = self:_read()
  if not state then return { active = false } end
  local output = copy_fields(state)
  local stale = self:_stale(state)
  output.active = active(state.stage) and not stale
  output.cancel_requested = self:_cancel_requested(state.job_id)
  if stale then output.stage = "failed"; output.code = "asset_update_interrupted" end
  if state.stage == "downloading" then
    local path = TEMP_PATHS[state.kind]
    local information = path and self.fs.stat(path) or nil
    if type(information) == "table" and information.type == "reg" and type(information.size) == "number" then
      output.downloaded_bytes = math.max(0, math.floor(information.size))
    else
      output.downloaded_bytes = 0
    end
    local total = tonumber(output.total_bytes) or 0
    if total > 0 then output.percent = math.max(0, math.min(99, math.floor(output.downloaded_bytes * 100 / total + 0.5))) end
  end
  if output.stage == "starting" then output.stage = "checking" end
  return output
end

M.STATUS_PATH = STATUS_PATH
M.LOCK_PATH = LOCK_PATH
M.CANCEL_PATH = CANCEL_PATH

return M
