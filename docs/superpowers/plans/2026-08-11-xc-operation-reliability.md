# XC Operation Reliability Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make node switching, service restart, resource downloads, and all user operations observable, cancellable where applicable, and recoverable on `fast_select_api`.

**Architecture:** Keep the existing Lua 5.1 runtime lock, protected state files, asynchronous `/usr/bin/xc` workers, and structured XC log. Add a runtime-only restart/recovery path, invalidate exit-IP cache at every active-runtime boundary, add a fixed cancellation marker that the platform download wait loop can terminate, and add bounded operation events at controller/runtime/asset-job boundaries.

**Tech Stack:** Lua 5.1, LuCI CBI/templates, ES5-compatible browser JavaScript, Xray/procd, Node.js DOM tests, injected Lua platform fixtures.

---

## File map

- `root/usr/lib/lua/xc/runtime.lua`: exit-IP invalidation, restart/recovery operations, runtime phase events and elapsed-time fields.
- `root/usr/lib/lua/xc/platform.lua`: cancellable fixed-source download wait loop and fixed cancellation-path validation.
- `root/usr/lib/lua/xc/assetjob.lua`: cancellation marker lifecycle, cancelled terminal state, phase/progress event callback.
- `root/usr/lib/lua/xc/assetmanager.lua`: pass cancellation context to Geo/Xray downloads and preserve atomic replacement.
- `root/usr/lib/lua/xc/cli.lua`, `root/usr/bin/xc`: expose `restart-service`, `recover-service`, and `asset-cancel` worker/API commands.
- `luasrc/controller/xc.lua`: register restart/recovery/cancel endpoints, sanitize operation events, and surface stable backend messages.
- `luasrc/view/xc/status.htm`: use the dedicated restart operation and display recovery action/state.
- `luasrc/view/xc/core.htm`: display resource byte progress and provide cancellation while a task is active.
- `tests/test_runtime.lua`, `tests/test_platform_process.lua`, `tests/test_assetjob.lua`: failing-first backend regressions.
- `tests/test_controller_static.lua`, `tests/test_controller_actions.lua`, `tests/test_controller_core.lua`: endpoint and event contract regressions.
- `tests/test_status.js`, `tests/test_core_ui.js`: DOM/XHR behavior regressions.
- `po/templates/xc.pot`, `po/zh_Hans/xc.po`: synchronized visible text.
- `docs/superpowers/specs/2026-08-11-xc-operation-reliability-design.md`: approved design; do not change behavior outside that scope.

## Task 1: Add failing runtime and controller contracts

**Files:**
- Modify: `tests/test_runtime.lua`
- Modify: `tests/test_controller_static.lua`
- Modify: `tests/test_controller_actions.lua`

- [ ] **Step 1: Add the exit-IP invalidation regression test.**

Add a runtime test beside the existing exit-IP cache tests that preloads a valid cache for `old`, performs a successful fast switch to `new`, then switches back to `old` and calls `status()`. Assert that the second `status()` invokes `observe_exit_ip` instead of returning the preloaded value. The test must assert the observed value is the new fixture value and that the cache file is absent immediately after the active-node mutation.

- [ ] **Step 2: Add the dedicated restart regression test.**

Add a fixture test with a valid runtime and `global.health_url`, make both listener checks succeed, and make `real_connection_check` fail. Call `state.runtime:restart_service()`. Assert `{ ok = true, code = "restarted" }`, exactly one restart event, two listener checks, no real-connection event, and no UCI commit. Add a second case where listener readiness fails and assert `restart_failed` plus a completion error event.

- [ ] **Step 3: Add the recovery regression test.**

Create a pending runtime transaction using the existing transaction fixture helpers, call `state.runtime:recover_service()`, and assert that the transaction is removed only after the old configuration is validated and listeners become ready. Add a failed-listener case and assert `recovery_required`, the transaction remains, and the service is not reported as recovered.

- [ ] **Step 4: Add controller route and response assertions.**

Extend static route lists to require POST-only `restart-service`, `recover-service`, and `core-resource-cancel`. Extend controller action fixtures with `start_restart`, `runtime.restart_service`, `runtime.recover_service`, and `asset_job.cancel`. Assert that malformed or missing job IDs return `invalid_request`, successful restart returns `switch_started`-style asynchronous data with `operation = "restart"`, and stable runtime/asset errors map to their documented HTTP statuses.

- [ ] **Step 5: Run the focused tests and verify RED.**

Run from the worktree:

```sh
./.tools/lua5.1 tests/test_runtime.lua
./.tools/lua5.1 tests/test_controller_static.lua
./.tools/lua5.1 tests/test_controller_actions.lua
```

Expected: the new assertions fail because the runtime methods and endpoints do not exist; existing tests must still load and report their normal results. Do not edit production files before observing these failures.

- [ ] **Step 6: Commit only the failing-test additions.**

```sh
git add tests/test_runtime.lua tests/test_controller_static.lua tests/test_controller_actions.lua
git commit -m "test: define restart recovery and cache invalidation behavior"
```

## Task 2: Implement runtime restart, recovery, and cache invalidation

**Files:**
- Modify: `root/usr/lib/lua/xc/runtime.lua`
- Modify: `root/usr/lib/lua/xc/cli.lua`
- Modify: `root/usr/bin/xc`
- Modify: `luasrc/controller/xc.lua`
- Modify: `luasrc/view/xc/status.htm`
- Modify: `tests/test_runtime.lua`, `tests/test_controller_actions.lua`, `tests/test_status.js`

- [ ] **Step 1: Add one protected cache invalidation helper.**

Add a method next to `_cached_exit_ip`:

```lua
function Runtime:_invalidate_exit_ip()
  return self:_checked_remove(EXIT_IP_CACHE_PATH)
end
```

Call it before any operation that can change the effective egress (`_fast_switch_locked`, `_switch_locked`, `_rollback_locked`, and the new restart method), and after a successful active-node commit where the old cache must not be reused. If invalidation fails, return `internal_error` from the operation rather than claiming a fresh egress result.

- [ ] **Step 2: Add bounded restart readiness.**

Add `_restart_readiness(global)` that calls `self.exec.service_state(self.now() + 30)`, then checks SOCKS and HTTP listeners against one deadline. It must return `nil` on success and `"restart_failed"` on service/listener failure. It must not call `_readiness`, `real_connection_check`, or mutate UCI.

- [ ] **Step 3: Implement `Runtime:restart_service()`.**

Wrap `_restart_readiness` in `_with_lock("restart", ...)`. The callback must reject a missing active runtime configuration with `missing_runtime`, invalidate the exit-IP cache, call `self.exec.restart()`, check `_restart_readiness(global)`, and return `result(true, "restarted", { node = global.active_node })`. Add `restart` to `_record_completion` with start/end stage events and elapsed milliseconds. Preserve the transaction file if automatic recovery fails.

- [ ] **Step 4: Implement `Runtime:recover_service()`.**

Wrap a callback in `_with_lock("recover_service", ...)`. The callback must run the existing `_recover_pending_locked()`, return its stable failure unchanged when recovery fails, then load the current global state, restart only when XC is enabled and a runtime config exists, verify `_restart_readiness`, invalidate the exit-IP cache, and return `result(true, "recovered")`. The method must leave a pending transaction in place when the old configuration or listener validation fails.

- [ ] **Step 5: Expose worker commands and asynchronous controller actions.**

In `cli.lua`, add exact command branches:

```lua
if command == "restart-service" and #argv == 1 then
  return finish(deps, deps.runtime:restart_service())
end
if command == "recover-service" and #argv == 1 then
  return finish(deps, deps.runtime:recover_service())
end
```

In `platform.lua`, add `exec.start_restart` and `exec.start_recover` that only launch `/usr/bin/xc restart-service` and `/usr/bin/xc recover-service`. In the controller, add POST entries and actions that verify current status is not busy/recovery-blocked, start the fixed worker, and return `{ code = "operation_started", operation = "restart" }` or `{ operation = "recover_service" }`.

- [ ] **Step 6: Update the status page to use the new actions.**

Add restart/recovery URLs and a recovery button. The restart button posts to `restart-service`, not `switch`; the recovery button posts to `recover-service` when `data.recovery_required === true` or the service is stopped/error. Keep buttons disabled while the status operation is active. Render the server's stable `message` when a mutation fails, then force a cache-busting status poll.

- [ ] **Step 7: Run the runtime/controller/status tests and verify GREEN.**

```sh
./.tools/lua5.1 tests/test_runtime.lua
./.tools/lua5.1 tests/test_controller_static.lua
./.tools/lua5.1 tests/test_controller_actions.lua
node tests/test_status.js
```

Expected: the new restart/recovery/cache assertions and all existing tests pass. If a test fails, change the implementation rather than weakening the assertion.

- [ ] **Step 8: Commit the runtime restart boundary.**

```sh
git add root/usr/lib/lua/xc/runtime.lua root/usr/lib/lua/xc/cli.lua root/usr/bin/xc root/usr/lib/lua/xc/platform.lua luasrc/controller/xc.lua luasrc/view/xc/status.htm tests/test_runtime.lua tests/test_controller_actions.lua tests/test_status.js
git commit -m "fix: separate service restart from node health checks"
```

## Task 3: Add failing asset cancellation and progress tests

**Files:**
- Modify: `tests/test_assetjob.lua`
- Modify: `tests/test_platform_process.lua`
- Modify: `tests/test_controller_core.lua`
- Modify: `tests/test_core_ui.js`

- [ ] **Step 1: Add the asset-job cancellation test.**

Extend the asset fixture with `write_file`/`remove` tracking and a fake `exec.download` that checks a passed cancellation path. Start a GeoIP job, set the cancellation marker for its returned job ID, run the job, and assert `ok == false`, `code == "asset_update_cancelled"`, the temporary file is removed, the cancellation marker is removed, and a new `start()` succeeds after the cancelled worker releases its lock.

- [ ] **Step 2: Add the platform process cancellation test.**

Extend the injected nixio fixture so `waitpid(..., "nohang")` remains running until a cancellation file appears, and `kill`/reap calls are recorded. Call the adapter's fixed download with the fixed cancel path and assert curl is terminated when the marker appears. Assert an arbitrary cancel path is rejected before fork.

- [ ] **Step 3: Add controller/core UI contracts.**

Require `core-resource-cancel` in the controller static test and `asset_job.cancel` in the controller core test. Add core UI assertions for the cancel URL, a resource cancel control, text containing downloaded and total bytes, and the `asset_update_cancelled` display branch.

- [ ] **Step 4: Run the focused tests and verify RED.**

```sh
./.tools/lua5.1 tests/test_assetjob.lua
./.tools/lua5.1 tests/test_platform_process.lua
./.tools/lua5.1 tests/test_controller_core.lua
node tests/test_core_ui.js
```

Expected: new cancellation assertions fail because no cancellation marker, platform callback, endpoint, or UI control exists.

- [ ] **Step 5: Commit only the asset failing tests.**

```sh
git add tests/test_assetjob.lua tests/test_platform_process.lua tests/test_controller_core.lua tests/test_core_ui.js
git commit -m "test: define cancellable asset download behavior"
```

## Task 4: Implement cancellable downloads and resource UI

**Files:**
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `root/usr/lib/lua/xc/assetmanager.lua`
- Modify: `root/usr/lib/lua/xc/assetjob.lua`
- Modify: `luasrc/controller/xc.lua`
- Modify: `luasrc/view/xc/core.htm`
- Modify: `root/usr/lib/lua/xc/cli.lua`, `root/usr/bin/xc`
- Modify: `po/templates/xc.pot`, `po/zh_Hans/xc.po`

- [ ] **Step 1: Add fixed cancellation-path validation.**

Define one constant `CANCEL_PATH = "/var/etc/xc/asset-update-cancel"` in `assetjob.lua` and expose it for tests. In `platform.lua`, accept only that exact path as the optional download cancellation path. Do not accept a job-supplied filesystem path.

- [ ] **Step 2: Make the platform wait loop cancellation-aware.**

Extend `poll_child`/`wait_status` with an optional `cancelled` callback. On each bounded wait iteration, if the callback returns true, call the existing `terminate_and_reap` and return false. The default download adapter passes a callback that checks the fixed cancellation file; all other process calls keep the current behavior.

- [ ] **Step 3: Pass cancellation context through the asset manager.**

Change the internal signatures to `Manager:_update_geo(kind, source, on_stage, cancel_path)`, `Manager:_update_xray(source, on_stage, cancel_path)`, and `Manager:update(kind, source_id, on_stage, cancel_path)`. Pass the fixed path as the fifth argument to `exec.download` for both Geo and Xray archives. Keep target replacement as temporary-file download followed by rename/copy only after successful installation.

- [ ] **Step 4: Add asset-job cancellation state.**

Implement `Job:cancel(job_id)` with this exact behavior: validate the job ID, read the current state, require an active matching job, write the fixed cancellation file with the job ID and mode 600, and return `{ ok = true, code = "asset_update_cancel_requested", job_id = job_id }`. Do not acquire the long-running job lock in this endpoint. `Job:start` removes a stale cancellation file before creating a new job. `Job:run` checks the marker before each phase, maps a cancelled download to `asset_update_cancelled`, removes temporary files through the manager, writes the terminal state, removes the marker, and releases the lock in every finish path.

- [ ] **Step 5: Preserve and extend status fields.**

Keep `stage`, `total_bytes`, `downloaded_bytes`, `percent`, `started_at`, and `updated_at`. Add `cancel_requested` only as a boolean derived from the fixed marker for the matching job; never return the marker contents. Keep active downloads capped at 99. Return terminal `stage = "cancelled"` with `active = false` and `code = "asset_update_cancelled"`.

- [ ] **Step 6: Add controller route and core-page cancel flow.**

Register POST `/core-resource-cancel`, validate `job_id` with the same safe pattern used by `assetjob`, and return only `code` and `job_id`. Add a resource-row cancel button that is visible/enabled only for the active row. On cancel response, continue polling until the terminal state, render a translated cancellation message, unlock resource controls, and reload resource status. Render active progress as `阶段 · 已下载/总大小 · 百分比`; if total is unknown, show the downloaded byte count and stage without inventing a percentage.

- [ ] **Step 7: Synchronize translations and run GREEN tests.**

Add only the new visible strings required by the cancel button, byte-progress text, cancellation stage, restart/recovery feedback, and failure messages to both catalogs with non-empty Simplified Chinese translations. Run:

```sh
./.tools/lua5.1 tests/test_assetjob.lua
./.tools/lua5.1 tests/test_platform_process.lua
./.tools/lua5.1 tests/test_controller_core.lua
node tests/test_core_ui.js
```

Expected: all asset/platform/controller/core UI tests pass and active downloads still never display 100 before success.

- [ ] **Step 8: Commit the cancellable resource flow.**

```sh
git add root/usr/lib/lua/xc/platform.lua root/usr/lib/lua/xc/assetmanager.lua root/usr/lib/lua/xc/assetjob.lua root/usr/lib/lua/xc/cli.lua root/usr/bin/xc luasrc/controller/xc.lua luasrc/view/xc/core.htm po/templates/xc.pot po/zh_Hans/xc.po tests/test_assetjob.lua tests/test_platform_process.lua tests/test_controller_core.lua tests/test_core_ui.js
git commit -m "fix: make resource downloads cancellable and observable"
```

## Task 5: Add failing operation-log coverage

**Files:**
- Modify: `tests/test_runtime.lua`
- Modify: `tests/test_controller_actions.lua`
- Modify: `tests/test_assetjob.lua`
- Modify: `tests/test_logview.lua`

- [ ] **Step 1: Add runtime phase-event assertions.**

For restart, recovery, safe switch, fast switch, rollback, access apply, and current-connection test, assert the fixture log events contain a start event, at least one phase event, and a terminal event with `outcome` and a bounded numeric `elapsed_ms`. Assert failure paths use the stable error code and never contain `url`, `uuid`, `password`, `raw`, or `config` field values.

- [ ] **Step 2: Add controller operation-event assertions.**

Exercise probe, test-current, import preview/commit, core upload/activate/rollback/delete, resource update/rollback/cancel, and access apply fixtures. Assert each action emits a start or terminal event even when validation fails after a backend is created, and assert the event fields contain only the operation's safe ID/count/kind/source/code fields.

- [ ] **Step 3: Add download progress-threshold assertions.**

Use a fake download status sequence of 10%, 25%, 50%, 75%, 99%, 99% and 100/installing. Assert the log sink receives only one event for each configured threshold, plus start, installing, and terminal events; assert the log contains no URL and remains within the existing entry size bound.

- [ ] **Step 4: Run the focused tests and verify RED.**

```sh
./.tools/lua5.1 tests/test_runtime.lua
./.tools/lua5.1 tests/test_controller_actions.lua
./.tools/lua5.1 tests/test_assetjob.lua
./.tools/lua5.1 tests/test_logview.lua
```

Expected: new event-count and phase assertions fail because current operations lack the required start/progress/duration records.

- [ ] **Step 5: Commit only the logging failing tests.**

```sh
git add tests/test_runtime.lua tests/test_controller_actions.lua tests/test_assetjob.lua tests/test_logview.lua
git commit -m "test: require operation and download lifecycle logs"
```

## Task 6: Implement complete operation observability

**Files:**
- Modify: `root/usr/lib/lua/xc/runtime.lua`
- Modify: `root/usr/lib/lua/xc/assetjob.lua`
- Modify: `root/usr/lib/lua/xc/assetmanager.lua`
- Modify: `luasrc/controller/xc.lua`
- Modify: `root/usr/lib/lua/xc/probe.lua` only if the controller cannot carry the event boundary
- Modify: `root/usr/lib/lua/xc/coremanager.lua` only if core lifecycle stages need an injected event callback

- [ ] **Step 1: Add bounded runtime operation helpers.**

Add a private runtime helper that records `{ operation, stage, code, outcome, node, elapsed_ms }` only for valid operation/stage/code values. In `_with_lock`, capture `started_at = self.now()`, emit `started`, emit existing operation-specific phase events, and include `elapsed_ms = math.floor((self.now() - started_at) * 1000 + 0.5)` in the terminal event. Clamp elapsed time to a non-negative maximum of 300000 milliseconds.

- [ ] **Step 2: Add switch/recovery/restart phase events.**

Emit phases at candidate validation, runtime install, restart requested, listeners ready, active commit, rollback/recovery, and terminal completion. Keep fast-switch's existing detailed API stages, adding the same operation and elapsed fields without changing its safe event values.

- [ ] **Step 3: Add controller boundaries for synchronous actions.**

Use one controller helper to record a safe start event before probe/test/import-preview/core/resource/access work and a terminal event after the response. Use the existing `probe_event`, `import_event`, and `core_event` sanitizers as the field whitelist; do not log request bodies. For import preview log only count/result; for probe log section ID, transport outcome, latency, and elapsed time.

- [ ] **Step 4: Add asset-job worker events.**

Pass an optional `record_event` callback into `assetjob.new` from both `new_backend()` and `/usr/bin/xc`. Emit `asset update started`, `asset download started`, threshold progress, `asset install started`, and terminal events. Record only kind/source/job ID, bytes, percent, code, outcome, and elapsed time. The callback must be wrapped in `pcall` so a log failure cannot break the download or lock cleanup.

- [ ] **Step 5: Improve operation feedback in the two affected UIs.**

In `status.htm` and `core.htm`, when a JSON response has a stable `message`, render it with `textContent`; otherwise use the translated fallback. During restart/recovery and resource cancellation, keep controls disabled until the status poll observes the terminal state. Do not render raw server HTML.

- [ ] **Step 6: Run all focused GREEN tests and package checks.**

```sh
./.tools/lua5.1 tests/test_runtime.lua
./.tools/lua5.1 tests/test_assetjob.lua
./.tools/lua5.1 tests/test_controller_actions.lua
./.tools/lua5.1 tests/test_logview.lua
node tests/test_status.js
node tests/test_core_ui.js
sh scripts/check-package.sh
```

Expected: zero failures, no translation coverage errors, and no CRLF/unsafe-log-field failures. If new visible strings were introduced, update both catalogs before rerunning the check.

- [ ] **Step 7: Commit the observability implementation.**

```sh
git add root/usr/lib/lua/xc/runtime.lua root/usr/lib/lua/xc/assetjob.lua root/usr/lib/lua/xc/assetmanager.lua luasrc/controller/xc.lua luasrc/view/xc/status.htm luasrc/view/xc/core.htm po/templates/xc.pot po/zh_Hans/xc.po tests/test_runtime.lua tests/test_assetjob.lua tests/test_controller_actions.lua tests/test_logview.lua tests/test_status.js tests/test_core_ui.js
git commit -m "feat: add operation lifecycle logging"
```

## Task 7: Full verification and test-device deployment

**Files/artifacts:**
- Verify: all source and tests in the worktree
- Build artifact: the branch's current `luci-app-xc_0.1.0-r*_all.ipk` with the actual release suffix
- Device: `192.168.13.1`

- [ ] **Step 1: Run the complete host suite from Bash.**

```sh
bash -lc 'cd "/c/Users/sdjam/.codex/worktrees/64d7/设计xray切换插件（luci）" && sh tests/run-host.sh'
```

Expected: Lua suite, all Node UI tests, package/translation checks, and po2lmo fixture check exit 0. Record the exact passing count in the final handoff.

- [ ] **Step 2: Verify the final diff and sensitive-field policy.**

```sh
git diff origin/fast_select_api...HEAD --check
git status --short --branch
rg -n -i "vless://|vmess://|trojan://|password=|uuid=|private_key|raw_outbound" docs/superpowers/plans/2026-08-11-xc-operation-reliability.md docs/superpowers/specs/2026-08-11-xc-operation-reliability-design.md
```

Expected: diff check passes; only the already-untracked local artifact directories remain unrelated; design/plan docs contain no credentials or raw node data.

- [ ] **Step 3: Locate or build the branch IPK.**

Use the existing OpenWrt SDK/build workflow if present. If no SDK is available locally, report that build as blocked and use only an already-built artifact whose package contents match the verified source; do not fabricate a package or install an unverified artifact.

- [ ] **Step 4: Back up non-sensitive device state before deployment.**

Through the existing SSH access to `192.168.13.1`, create a timestamped backup under `/tmp/xc-operation-fix-backup/` containing file metadata and copies of `/etc/config/xc`, `/var/etc/xc/config.json`, `/etc/xc/rollback`, and `/etc/xc/xray/transaction` when present. Do not print file contents, credentials, UUIDs, raw outbounds, or SSH secrets in tool output.

- [ ] **Step 5: Install and smoke-test the package on the device.**

Copy only the verified main package and matching translation package to `/tmp`, install without `--force-depends`, then check:

```sh
/usr/bin/xc status
/etc/init.d/xc running
/usr/bin/xray run -test -format json -c /var/etc/xc/config.json
```

Open the LuCI pages and verify restart, recovery visibility, exit-IP refresh, resource cancel/status, and log entries. For a resource test, use a controlled update source already accepted by the package; do not expose URLs or credentials in captured output.

- [ ] **Step 6: Verify rollback path and preserve user state.**

Before leaving the device, confirm the service is running, ports 7890/10809 are present, no active asset job remains, and the original active node/configuration is restored if the smoke test changed it. Keep the backup path and report whether the package can be removed/reinstalled safely.

- [ ] **Step 7: Commit the verification record only after fresh evidence.**

Create `docs/2026-08-11-xc-operation-reliability-verification.md` with timestamps, command exit codes, package version, device address, and pass/fail results only; omit credentials, UUIDs, URLs, raw configs, and full logs. Run `git diff --check`, then commit:

```sh
git add docs/2026-08-11-xc-operation-reliability-verification.md
git commit -m "docs: record operation reliability device verification"
```

Do not claim device success if the SDK, SSH access, package build, or any smoke check is unavailable.
