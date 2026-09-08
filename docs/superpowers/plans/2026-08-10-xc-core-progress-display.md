# XC Core Progress Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace resource-update progress bars with inline percentage text and keep terminal update messages only for the current page session.

**Architecture:** Keep the asynchronous asset job and its status endpoint unchanged. Update `luasrc/view/xc/core.htm` so resource rows render text-only progress, and only render an active job returned by the status endpoint on initial load; terminal `succeeded`, `failed`, and `unchanged` states are not restored after refresh.

**Tech Stack:** LuCI template HTML/JavaScript, Node.js DOM test harness, Lua 5.1 host suite.

---

### Task 1: Add the failing UI assertions

**Files:**
- Modify: `tests/test_core_ui.js`
- Test: `tests/test_core_ui.js`

- [ ] **Step 1: Assert text-only progress behavior**

Change the resource job assertions to require `下载中【46%】`, remove the expectation that the resource progress element is visible, and assert the resource progress elements are absent from the rendered page source.

- [ ] **Step 2: Assert terminal states are not restored on page initialization**

Add a harness response containing `stage: "succeeded"`, `stage: "failed"`, or `stage: "unchanged"` for the initial status request and assert the corresponding operation text remains empty after initialization. Keep the active `downloading` response covered so an in-progress job still renders after refresh.

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```sh
node tests/test_core_ui.js
```

Expected: FAIL because the current template still contains resource `<progress>` elements, renders a graphical progress bar, and restores terminal operation text.

### Task 2: Implement the minimal core-page behavior

**Files:**
- Modify: `luasrc/view/xc/core.htm`
- Modify: `po/templates/xc.pot`
- Modify: `po/zh_Hans/xc.po`

- [ ] **Step 1: Remove resource progress elements and CSS**

Delete the three resource-row `<progress>` elements and the resource progress CSS rule. Keep the upload progress bar unchanged because it is a separate upload feature.

- [ ] **Step 2: Render inline percentages**

Change `resourceText(payload)` to format a known download percentage as `text.downloading + "【" + percent + "%】"`; preserve `text.downloading` when `total_bytes` is unavailable. Render `succeeded` as `text.updateSucceeded + "【100%】"`.

- [ ] **Step 3: Hide terminal status during initial status restoration**

In the initial `pollResourceJob(true)` callback, call `renderResourceJob(data)` only for an active job and clear the resource operation text for terminal data. Do not change the background polling path used while a job is active.

- [ ] **Step 4: Synchronize only changed visible strings**

Run the existing catalog check and update the gettext catalogs only if the new display text introduces a source string not already present. Do not add user-visible untranslated strings.

### Task 3: Verify, build, deploy, and accept

**Files:**
- Build: `luci-app-xc_0.1.0-r28_all.ipk`
- Build: `luci-i18n-xc-zh-cn_0.1.0-r28_all.ipk`

- [ ] **Step 1: Run focused UI tests**

```sh
node tests/test_core_ui.js
```

Expected: `core UI DOM tests passed`.

- [ ] **Step 2: Run the complete host suite**

```sh
bash tests/run-host.sh
```

Expected: 468 or more Lua tests pass, UI tests pass, translation and package checks pass.

- [ ] **Step 3: Build r28 IPKs and verify their names and hashes**

Build with the repository's OpenWrt release workflow, then confirm both IPKs use `0.1.0-r28` and calculate SHA-256 checksums before upload.

- [ ] **Step 4: Deploy to `192.168.6.1` with a rollback backup**

Back up `/etc/config/xc` and the affected LuCI package state under a timestamped `/tmp/xc-backups/` directory, install the r28 packages, and refresh LuCI services. Do not print credentials or full configuration data.

- [ ] **Step 5: Run device acceptance checks**

Confirm the installed package version is r28, `xray run -test -config /var/etc/xc/config.json` and `/usr/bin/xc test` pass, the XC service is running, and ports 7890/10809 are listening. Remove the uploaded IPKs after installation while retaining the backup.

- [ ] **Step 6: Commit and push the implementation**

After fresh verification, commit the plan, UI, catalog, and test changes on `fast_select_api`, then push the branch and verify local and remote commit IDs match.
