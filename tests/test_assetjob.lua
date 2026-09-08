local t = require "testlib"

local loaded, job_module = pcall(require, "xc.assetjob")

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
  for _, key in ipairs(keys) do
    output[#output + 1] = json_quote(key) .. ":" .. json_encode(value[key])
  end
  return "{" .. table.concat(output, ",") .. "}"
end

local function fixture(options)
  options = options or {}
  local files, events = {}, {}
  local log_events = options.log_events or {}
  local locked = false
  local fs = {
    acquire_lock = function()
      if locked then return nil end
      locked = true
      return { lock = true }
    end,
    release_lock = function()
      locked = false
      return true
    end,
    read = function(path) return files[path] end,
    write_file = function(path, content) files[path] = content; return true end,
    stat = function(path)
      if files[path] == nil then return nil end
      return { type = "reg", size = type(files[path]) == "string" and #files[path] or 0 }
    end,
    remove = function(path) files[path] = nil; return true end
  }
  local manager = {
    source = function(_, kind, id)
      if kind ~= "geoip" or id ~= "official" then return nil end
      return { id = "official", url = "https://example.invalid/geoip.dat" }
    end,
    metadata = function() return options.previous_metadata end,
    update = function(_, kind, source, on_stage, cancel_path, on_progress)
      events[#events + 1] = "update:" .. kind .. ":" .. source
      if options.observe_download then options.observe_download() end
      for _, progress in ipairs(options.progress or {}) do
        if on_progress then on_progress(progress) end
      end
      if on_stage then on_stage("installing") end
      local result = { ok = true, code = "asset_updated", kind = kind, source = source }
      if options.update_version then
        result.version = {
          id = "v26_6_27-aarch64-51c3e26e4ba03f3a", version = "26.6.27", arch = "aarch64",
          size = 128, sha256 = string.rep("a", 64)
        }
      end
      return result
    end,
    save_metadata = function(_, kind, source, metadata)
      events[#events + 1] = "metadata:" .. kind .. ":" .. source .. ":" .. tostring(metadata.etag)
      return true
    end,
    save_source = function(_, kind, source)
      events[#events + 1] = "source:" .. kind .. ":" .. source
      if options.save_source_error then error("source commit failed") end
      return true
    end
  }
  local exec = {
    start_asset_update = function(kind, source, job_id)
      events[#events + 1] = "start:" .. kind .. ":" .. source .. ":" .. job_id
      return options.start_ok ~= false
    end,
    remote_metadata = function() return options.remote_metadata end
  }
  local job = loaded and job_module.new({
    fs = fs, exec = exec, manager = manager, json = { parse = mock_json.parse, stringify = json_encode },
    now = options.now or function() return 100 end, wall_time = function() return 1700000000 end,
    record_event = options.record_event
  }) or nil
  if options.observe_download then options.job = job; options.files = files end
  return job, { files = files, events = events, log_events = log_events }
end

t.test("asset job module exposes asynchronous task and status contracts", function()
  t.eq(loaded, true, "asset job module is required")
  t.truthy(type(job_module.new) == "function")
  t.truthy(type(job_module.STATUS_PATH) == "string")
end)

t.test("asset job start returns immediately and rejects a second active job", function()
  if not loaded then return end
  local job, state = fixture({ remote_metadata = { etag = "new", size = 100 } })
  local started = job:start("geoip", "official")
  t.eq(started.ok, true)
  t.eq(started.stage, "checking")
  t.eq(#state.events, 1)
  local busy = job:start("geoip", "official")
  t.eq(busy.ok, false)
  t.eq(busy.code, "asset_update_busy")
end)

t.test("asset job reports real temporary file progress and installation stage", function()
  if not loaded then return end
  local state
  local job
  local options = { remote_metadata = { etag = "new", size = 100 } }
  options.observe_download = function()
    state.files["/etc/xc/xray/assets/.asset-update-geoip"] = string.rep("x", 50)
    state.progress = job:status()
  end
  job, state = fixture(options)
  local started = job:start("geoip", "official")
  t.eq(started.ok, true)
  local ran = job:run("geoip", "official", started.job_id)
  t.eq(ran.ok, true)
  t.eq(state.progress.stage, "downloading")
  t.eq(state.progress.downloaded_bytes, 50)
  t.eq(state.progress.total_bytes, 100)
  t.eq(state.progress.percent, 50)
  t.eq(job:status().stage, "succeeded")
  t.contains(table.concat(state.events, "|"), "metadata:geoip:official:new")
  t.contains(table.concat(state.events, "|"), "source:geoip:official")
end)

t.test("asset job keeps an active download below terminal completion", function()
  if not loaded then return end
  local job, state = fixture({ remote_metadata = { etag = "new", size = 100 } })
  local started = job:start("geoip", "official")
  local downloading = job:_read()
  downloading.stage = "downloading"
  downloading.total_bytes = 100
  job.fs.write_file(job_module.STATUS_PATH, json_encode(downloading), 600)
  state.files["/etc/xc/xray/assets/.asset-update-geoip"] = string.rep("x", 150)
  local status = job:status()
  t.eq(status.active, true)
  t.eq(status.percent, 99)
  t.eq(started.ok, true)
end)

t.test("asset job logs download thresholds, install, and terminal outcome", function()
  if not loaded then return end
  local log_events = {}
  local job, state = fixture({
    remote_metadata = { etag = "new", size = 100 },
    progress = { 10, 25, 50, 75, 99, 99, 100 }, log_events = log_events,
    record_event = function(message, fields, level)
      log_events[#log_events + 1] = { message = message, fields = fields, level = level }
    end
  })
  local started = job:start("geoip", "official")
  t.truthy(job:run("geoip", "official", started.job_id).ok)
  local stages, thresholds = {}, {}
  for _, event in ipairs(log_events) do
    if event.message ~= "asset download progress" then
      stages[event.fields.stage] = (stages[event.fields.stage] or 0) + 1
    else
      thresholds[event.fields.percent] = (thresholds[event.fields.percent] or 0) + 1
    end
    t.eq(event.fields.url, nil)
    t.eq(event.fields.uuid, nil)
    t.eq(event.fields.elapsed_ms ~= nil and event.fields.elapsed_ms >= 0 and event.fields.elapsed_ms <= 1800000, true)
  end
  t.eq(stages.started, 1)
  t.eq(stages.downloading, 1)
  t.eq(stages.installing, 1)
  t.eq(stages.completed, 1)
  for _, percent in ipairs({ 25, 50, 75, 99 }) do t.eq(thresholds[percent], 1) end
end)

t.test("asset job clamps reported elapsed to the extended bounded window", function()
  local clock = { now = 100 }
  local log_events = {}
  local options = {
    remote_metadata = { etag = "new", size = 100 },
    progress = { 100 },
    observe_download = function() clock.now = 2000 end,
    now = function() return clock.now end,
    log_events = log_events,
    record_event = function(message, fields, level)
      log_events[#log_events + 1] = { message = message, fields = fields, level = level }
    end
  }
  local job, ctx = fixture(options)
  local started = job:start("geoip", "official")
  t.truthy(job:run("geoip", "official", started.job_id).ok)
  local terminal
  for _, event in ipairs(ctx.log_events) do
    if event.fields.elapsed_ms ~= nil then terminal = event.fields.elapsed_ms end
  end
  t.eq(terminal, 1800000, "elapsed must clamp to the extended window, not the old 300000")
end)

t.test("asset job cancellation terminates the current task and releases all state", function()
  if not loaded then return end
  local job, state = fixture({ remote_metadata = { etag = "new", size = 100 } })
  local started = job:start("geoip", "official")
  t.eq(started.ok, true)
  state.files["/etc/xc/xray/assets/.asset-update-geoip"] = string.rep("x", 40)
  local requested = job:cancel(started.job_id)
  t.eq(requested.ok, true)
  t.eq(requested.code, "asset_update_cancel_requested")
  local ran = job:run("geoip", "official", started.job_id)
  t.eq(ran.ok, false)
  t.eq(ran.code, "asset_update_cancelled")
  t.eq(job:status().active, false)
  t.eq(job:status().stage, "cancelled")
  t.eq(state.files[job_module.CANCEL_PATH], nil)
  t.eq(state.files["/etc/xc/xray/assets/.asset-update-geoip"], nil)
  t.eq(job:start("geoip", "official").ok, true)
end)

t.test("asset job releases the lock when source persistence throws", function()
  if not loaded then return end
  local job, state = fixture({ remote_metadata = { etag = "new", size = 100 }, save_source_error = true })
  local started = job:start("geoip", "official")
  local called, value = pcall(job.run, job, "geoip", "official", started.job_id)
  t.eq(called, true)
  t.contains(table.concat(state.events, "|"), "source:geoip:official")
  t.eq(value.code, "asset_commit_failed")
  t.eq(value.ok, false)
  t.eq(value.code, "asset_commit_failed")
  local retry = job:start("geoip", "official")
  t.eq(retry.ok, true)
  t.eq(state.events[#state.events]:match("^start:geoip:official:"), "start:geoip:official:")
end)

t.test("asset job stores the Xray version as a scalar status field", function()
  if not loaded then return end
  local job, state = fixture({ remote_metadata = { etag = "new", size = 100 }, update_version = true })
  local started = job:start("geoip", "official")
  local result = job:run("geoip", "official", started.job_id)
  t.eq(result.ok, true)
  t.eq(type(job:status().version), "string")
  t.eq(job:status().version, "26.6.27")
  t.eq(state.files[job_module.STATUS_PATH]:find("sha256", 1, true), nil)
end)

t.test("asset job skips the download when validators are unchanged", function()
  if not loaded then return end
  local metadata = { source = "official", etag = "same", size = 100 }
  local job, state = fixture({ previous_metadata = metadata, remote_metadata = { etag = "same", size = 100 } })
  local started = job:start("geoip", "official")
  t.truthy(job:run("geoip", "official", started.job_id).ok)
  t.eq(job:status().stage, "unchanged")
  t.eq(table.concat(state.events, "|"):find("update:", 1, true), nil)
end)

t.test("asset job exposes an interrupted terminal state after timeout", function()
  if not loaded then return end
  local job = fixture({ remote_metadata = { etag = "new", size = 100 } })
  local started = job:start("geoip", "official")
  local stale = job:_read()
  stale.started_at = 1
  job.fs.write_file(job_module.STATUS_PATH, json_encode(stale), 600)
  local status = job:status()
  t.eq(status.active, false)
  t.eq(status.stage, "failed")
  t.eq(status.code, "asset_update_interrupted")
end)

t.test("asset job keeps a slow download active inside the extended bounded window", function()
  if not loaded then return end
  local job = fixture({ remote_metadata = { etag = "new", size = 100 } })
  local started = job:start("geoip", "official")
  local state = job:_read()
  state.started_at = 1699999000
  job.fs.write_file(job_module.STATUS_PATH, json_encode(state), 600)
  local status = job:status()
  t.eq(status.active, true)
  t.eq(status.stage, "checking")
  t.eq(started.ok, true)
end)

return true
