"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

const model = fs.readFileSync("luasrc/model/cbi/xc/core.lua", "utf8");
const view = fs.readFileSync("luasrc/view/xc/core.htm", "utf8");

assert.ok(model.includes('SimpleForm("xc_core"'), "core page uses a SimpleForm shell");
assert.ok(model.includes('section.template = "xc/core"'), "core page delegates rendering to xc/core");
assert.ok(model.includes("m.submit = false"), "core page does not submit a CBI form");
assert.ok(model.includes("m.reset = false"), "core page does not render a reset action");
assert.ok(model.includes("m.cancel = false"), "core page does not render a cancel action");
assert.strictEqual(model.includes("XC runtime and Xray core logs are shown here"), false,
  "core page must not repeat the log page description");
assert.strictEqual(model.includes('translate("Xray")'), false,
  "core page should not render a duplicate outer title");

for (const id of [
  "xc-core-page",
  "xc-core-upload-file", "xc-core-upload-progress", "xc-core-upload-progress-text",
  "xc-core-upload", "xc-core-versions", "xc-core-operation-state"
  ,"xc-core-resource-xray-source", "xc-core-resource-geoip-source",
  "xc-core-resource-geosite-source", "xc-core-resource-xray-check", "xc-core-resource-geoip-check",
  "xc-core-resource-geosite-check", "xc-core-resource-xray-operation", "xc-core-resource-geoip-operation",
  "xc-core-resource-geosite-operation", "xc-core-resource-xray-cancel", "xc-core-resource-geoip-cancel",
  "xc-core-resource-geosite-cancel"
  ,"xc-core-proxy-enabled", "xc-core-proxy-type", "xc-core-proxy-address",
  "xc-core-proxy-port", "xc-core-proxy-username", "xc-core-proxy-password", "xc-core-proxy-save"
]) {
  assert.ok(view.includes('id="' + id + '"'), "missing core UI element " + id);
}
assert.strictEqual(view.includes('id="xc-core-resource-xray-update"'), false,
  "the resource row must use a single check/update action button");
assert.ok(view.includes('value="<%:Check update%>"'), "the single action button starts as Check update");

assert.ok(view.includes('data-asset-proxy-apply-url='), "core page must expose the proxy apply route");
assert.strictEqual(view.includes('type="password"'), true, "proxy password field must mask input");
assert.strictEqual(view.includes('type="checkbox"'), true, "proxy enable must be a checkbox");
assert.strictEqual(view.includes("saveProxySettings"), true, "core page must wire the proxy save action");

assert.strictEqual(view.includes('id="xc-core-upload-sha256"'), false,
  "core upload must not expose an expected SHA-256 field");
assert.strictEqual(view.includes('id="xc-core-upload-note"'), false,
  "core upload must not expose a note field");
assert.strictEqual(view.includes('form.append("sha256"'), false,
  "core upload must not submit an expected SHA-256 field");
assert.strictEqual(view.includes('form.append("note"'), false,
  "core upload must not submit a note field");
assert.ok(view.includes("xhr.upload.onprogress"), "core upload must report XMLHttpRequest progress");
assert.ok(view.includes('data-core-resource-update-url='), "missing resource update endpoint");
assert.ok(view.includes('data-core-resource-update-status-url='), "missing resource update status endpoint");
assert.ok(view.includes('data-core-resource-rollback-url='), "missing resource rollback endpoint");
assert.ok(view.includes('data-core-resource-cancel-url='), "missing resource cancel endpoint");
assert.strictEqual(view.includes('type="url"'), false, "resource updates must not expose custom URL input");
assert.ok(view.includes('data-core-resource-kind="xray"'), "missing Xray resource row");
assert.ok(view.includes('data-core-resource-kind="geoip"'), "missing GeoIP resource row");
assert.ok(view.includes('data-core-resource-kind="geosite"'), "missing GeoSite resource row");
for (const kind of ["xray", "geoip", "geosite"]) {
  assert.strictEqual(view.includes('id="xc-core-resource-' + kind + '-progress"'), false,
    "resource updates use inline text progress only");
}
assert.strictEqual(view.includes("xc-core-current-source"), false, "top-level current core panel was removed");
assert.strictEqual(view.includes("xc-core-refresh"), false, "manual refresh button was removed");
assert.strictEqual(view.includes("xc-core-system-action"), false, "system activation button was removed");

for (const action of ["core-status", "core-upload", "core-activate", "core-rollback", "core-delete",
  "core-resource-update", "core-resource-rollback"]) {
  assert.ok(view.includes('data-' + action + '-url='), "missing reserved endpoint " + action);
}

assert.strictEqual(view.includes("innerHTML"), false, "core UI must render untrusted fields with text nodes");
assert.strictEqual(view.includes("eval("), false, "core UI must not evaluate server data");
assert.ok(view.includes("data-core-action"), "core actions are explicit data attributes");
assert.ok(view.includes("confirm("), "destructive actions require confirmation");
assert.ok(view.includes('class="table xc-core-version-table"'), "installed versions use a LuCI table wrapper");
assert.ok(view.includes("xc-core-version-runtime"), "installed versions include runtime status cells");

function hasClass(node, name) {
  return (" " + node.className + " ").indexOf(" " + name + " ") >= 0;
}

function element(tag) {
  const node = {
    tagName: (tag || "div").toUpperCase(), id: "", className: "", textContent: "",
    value: "", disabled: false, hidden: false, files: [], children: [], attributes: {},
    parentNode: null, onclick: null, onchange: null,
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
    removeChild(child) {
      const index = this.children.indexOf(child);
      if (index >= 0) this.children.splice(index, 1);
      child.parentNode = null;
      return child;
    },
    setAttribute(name, value) {
      this.attributes[name] = String(value);
      if (name === "id") this.id = String(value);
      if (name === "class") this.className = String(value);
    },
    getAttribute(name) {
      if (name === "id") return this.id || null;
      return this.attributes[name] === undefined ? null : this.attributes[name];
    },
    querySelectorAll(selector) {
      const all = [];
      function visit(parent) {
        parent.children.forEach(child => {
          if (selector === "input[data-core-action]" && child.tagName === "INPUT" &&
              child.getAttribute("data-core-action")) all.push(child);
          visit(child);
        });
      }
      visit(this);
      return all;
    },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  };
  Object.defineProperty(node, "firstChild", { get() { return this.children[0] || null; } });
  return node;
}

function harness(withXhr, initialJob, checkResult) {
  const ids = [
    "xc-core-page",
    "xc-core-upload-file", "xc-core-upload-progress", "xc-core-upload-progress-text",
    "xc-core-upload", "xc-core-versions", "xc-core-operation-state"
    ,"xc-core-resource-xray-source", "xc-core-resource-geoip-source",
    "xc-core-resource-geosite-source", "xc-core-resource-xray-check", "xc-core-resource-geoip-check",
    "xc-core-resource-geosite-check", "xc-core-resource-xray-rollback", "xc-core-resource-geoip-rollback",
    "xc-core-resource-geosite-rollback", "xc-core-resource-xray-status", "xc-core-resource-geoip-status",
    "xc-core-resource-geosite-status", "xc-core-resource-xray-operation", "xc-core-resource-geoip-operation",
    "xc-core-resource-geosite-operation", "xc-core-resource-xray-cancel", "xc-core-resource-geoip-cancel",
    "xc-core-resource-geosite-cancel", "xc-core-resource-xray-current", "xc-core-resource-geoip-current",
    "xc-core-resource-geosite-current", "xc-core-resource-xray-latest", "xc-core-resource-geoip-latest",
    "xc-core-resource-geosite-latest", "xc-core-resource-xray-checkstatus", "xc-core-resource-geoip-checkstatus",
    "xc-core-resource-geosite-checkstatus"
  ];
  const elements = {};
  ids.forEach(id => { elements[id] = element(id === "xc-core-upload-file" ? "input" : "div"); });
  elements["xc-core-page"].setAttribute("data-core-status-url", "/xc/core-status");
  elements["xc-core-page"].setAttribute("data-core-upload-url", "/xc/core-upload");
  elements["xc-core-page"].setAttribute("data-core-activate-url", "/xc/core-activate");
  elements["xc-core-page"].setAttribute("data-core-rollback-url", "/xc/core-rollback");
  elements["xc-core-page"].setAttribute("data-core-delete-url", "/xc/core-delete");
  elements["xc-core-page"].setAttribute("data-core-resource-update-url", "/xc/core-resource-update");
  elements["xc-core-page"].setAttribute("data-core-resource-update-status-url", "/xc/core-resource-update-status");
  elements["xc-core-page"].setAttribute("data-core-resource-check-url", "/xc/core-resource-check");
  elements["xc-core-page"].setAttribute("data-core-resource-rollback-url", "/xc/core-resource-rollback");
  elements["xc-core-page"].setAttribute("data-core-resource-cancel-url", "/xc/core-resource-cancel");
  let confirmations = 0;
  const requests = [];
  const pending = [];
  const document = {
    getElementById(id) { return elements[id] || null; },
    createElement: element,
    createTextNode(value) { return { nodeType: 3, textContent: String(value), parentNode: null }; },
    addEventListener(name, callback) { if (name === "DOMContentLoaded") callback(); }
  };
  const window = {};
  const translations = {
    "Unavailable": "不可用", "Unknown": "未知", "Running": "运行中", Error: "错误",
    "System core": "系统核心", "Manual core": "手动核心", "System provided": "系统提供", Current: "当前", Rollback: "回滚",
    Running: "运行中", Stopped: "已停止", "Not running": "未运行", Error: "错误",
    Activate: "激活", Delete: "删除", Validated: "已校验", "Binary validated": "已完成二进制校验",
    "Configuration validated": "已完成配置校验", "No installed core versions": "暂无已安装核心",
    "The interface is not available": "接口尚未启用", "Operation completed": "操作完成",
    "The core was validated and installed; it can now be activated.": "核心已校验并安装，现在可以激活。",
    "Use system core": "使用系统核心", "Confirm activation of the system Xray core? The service may restart.": "确认切换到系统 Xray 核心？服务可能重启。",
    "Checking for updates": "正在检查更新", "Detected new version": "检测到新版本", Downloading: "下载中",
    "Download complete; installing": "下载完成，正在安装", "Update complete": "更新完成",
    "Latest version already installed": "已是最新版本", "Update failed": "更新失败",
    "Check failed": "检查失败", "Download failed": "下载失败", "Installation failed": "安装失败",
    "Source selection save failed": "源选择保存失败", "Update interrupted": "更新被中断",
    "Another core resource update is already in progress.": "已有核心资源正在更新。", Downloaded: "已下载"
    ,"Cancel update": "取消更新", "Update cancelled": "更新已取消"
  };
  const script = view.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/<%=util\.serialize_json\(translate\("([^"]+)"\)\)%>/g,
      (_, value) => JSON.stringify(translations[value] || value));
  function complete(xhr, payload) {
    xhr.readyState = 4;
    xhr.responseText = JSON.stringify(payload);
    if (typeof xhr.onreadystatechange === "function") xhr.onreadystatechange();
  }
  function FakeXHR() {
    this.readyState = 0;
    this.responseText = "";
    this.upload = {};
  }
  FakeXHR.prototype.open = function(method, url) { this.method = method; this.url = url; };
  FakeXHR.prototype.setRequestHeader = function() {};
  FakeXHR.prototype.respond = function(value) { complete(this, value); };
  FakeXHR.prototype.send = function(body) {
    this.body = body;
    requests.push({ method: this.method, url: this.url, body: body, xhr: this });
    if (this.method === "GET") {
      if (this.url.indexOf("core-resource-update-status") >= 0) {
        complete(this, { ok: true, data: initialJob || { active: false } });
        return;
      }
      if (this.url.indexOf("core-resource-check") >= 0) {
        complete(this, { ok: true, data: checkResult || { kind: "geoip", current_version: "26.6.27", latest_version: "26.6.28", can_upgrade: true } });
        return;
      }
      complete(this, { ok: true, data: { resources: {
        sources: {
          xray: [{ id: "official", label: "Official" }],
          geoip: [{ id: "official", label: "Official" }, { id: "mirror", label: "Mirror" }],
          geosite: [{ id: "official", label: "Official" }]
        }, selected: { xray: "official", geoip: "official", geosite: "official" }, defaults: {}
      } } });
    } else pending.push(this);
  };
  const context = {
    window, document, JSON, Number, String, Array, Math,
    confirm() { confirmations++; return true; }
  };
  if (withXhr) context.XMLHttpRequest = FakeXHR;
  vm.runInNewContext(script, context);
  return {
    window, elements, requests, pending,
    completeNext() { complete(pending.shift(), { ok: true, data: {} }); },
    get confirmations() { return confirmations; }
  };
}

{
  const h = harness(true, null, { ok: true, data: { kind: "geoip", current_version: "1", latest_version: "1", can_upgrade: false } });
  h.window.XCCoreUI.renderStatus({ resources: {
    sources: {
      xray: [{ id: "official", label: "Official" }],
      geoip: [{ id: "official", label: "Official" }, { id: "mirror", label: "Mirror" }],
      geosite: [{ id: "official", label: "Official" }]
    }, selected: { geoip: "mirror" }, defaults: {}
  }});
  assert.strictEqual(h.elements["xc-core-resource-geoip-check"].value, "Check update",
    "the single action button starts as Check update");
  h.elements["xc-core-resource-geoip-check"].onclick();
  const check = h.requests[h.requests.length - 1];
  assert.ok(check.url.indexOf("/xc/core-resource-check?kind=geoip") === 0,
    "without a new version the action button performs a check");
  assert.strictEqual(h.elements["xc-core-resource-geoip-check"].value, "Check update",
    "the button stays Check update when nothing new is available");
}

{
  const h = harness(true);
  h.window.XCCoreUI.renderStatus({ resources: {
    sources: {
      xray: [{ id: "official", label: "Official" }],
      geoip: [{ id: "official", label: "Official" }, { id: "mirror", label: "Mirror" }],
      geosite: [{ id: "official", label: "Official" }]
    }, selected: { geoip: "mirror" }, defaults: {}
  }});
  h.elements["xc-core-resource-geoip-check"].onclick();
  assert.strictEqual(h.elements["xc-core-resource-geoip-check"].value, "Update",
    "a new version switches the action button to Update");
  h.elements["xc-core-resource-geoip-check"].onclick();
  const update = h.requests[h.requests.length - 1];
  assert.strictEqual(update.method, "POST");
  assert.ok(update.url.indexOf("/xc/core-resource-update") === 0);
  assert.strictEqual(update.body, "kind=geoip&source=mirror");
  assert.strictEqual(h.elements["xc-core-resource-geoip-check"].disabled, true,
    "the selected resource row is locked during update");
  assert.strictEqual(h.elements["xc-core-resource-geoip-rollback"].disabled, true);
  assert.strictEqual(h.elements["xc-core-resource-xray-check"].disabled, true);
  h.completeNext();
  assert.strictEqual(h.elements["xc-core-resource-geoip-check"].disabled, false);
}

{
  const h = harness();
  h.window.XCCoreUI.renderStatus({ resources: {
    sources: {
      xray: [{ id: "official", label: "Official" }, { id: "mirror", label: "Mirror" }],
      geoip: [{ id: "official", label: "Official" }, { id: "mirror", label: "Mirror" }],
      geosite: [{ id: "official", label: "Official" }, { id: "mirror", label: "Mirror" }]
    }, selected: { xray: "official", geoip: "mirror", geosite: "official" },
    defaults: { geoip: true, geosite: false }
  }});
  assert.strictEqual(h.elements["xc-core-resource-geoip-source"].children.length, 2,
    "GeoIP renders only backend-provided sources");
  assert.strictEqual(h.elements["xc-core-resource-geoip-source"].value, "mirror");
  assert.strictEqual(h.elements["xc-core-resource-geoip-status"].textContent, "Default snapshot available");
}

{
  const h = harness();
  h.window.XCCoreUI.renderVersions([
    { id: "v26_6_27-aarch64-aaaaaaaaaaaaaaaa", version: "26.6.27", arch: "aarch64",
      size: 123, sha256: "a".repeat(64), current: true },
    { id: "v26_6_26-aarch64-bbbbbbbbbbbbbbbb", version: "26.6.26", arch: "aarch64",
      size: 456, sha256: "b".repeat(64), previous: true },
    { id: "v26_6_25-aarch64-cccccccccccccccc", version: "26.6.25", arch: "aarch64",
      size: 789, sha256: "c".repeat(64), validation: "full" },
    { id: "bad/id", version: "unsafe", arch: "aarch64", sha256: "b".repeat(64) }
  ], "v26_6_27-aarch64-aaaaaaaaaaaaaaaa", "running", null);
  const rows = h.elements["xc-core-versions"].children;
  assert.strictEqual(rows.length, 3, "invalid version records are not rendered");
  assert.strictEqual(rows[0].children[0].textContent, "26.6.27");
  const actions = h.elements["xc-core-versions"].querySelectorAll("input[data-core-action]");
  assert.strictEqual(actions.length, 4, "version records expose only safe actions");
  assert.strictEqual(actions[0].getAttribute("data-core-action"), "current");
  assert.strictEqual(actions[1].getAttribute("data-core-action"), "rollback");
  assert.strictEqual(rows[2].children[3].textContent, "已完成配置校验");
  assert.strictEqual(rows[0].children[4].textContent, "运行中");
}

{
  const h = harness();
  h.window.XCCoreUI.renderVersions([], "system", "running", {
    version: "26.6.27", arch: "aarch64", size: 128
  });
  const rows = h.elements["xc-core-versions"].children;
  assert.strictEqual(rows.length, 1, "system core is shown as a read-only row");
  assert.strictEqual(rows[0].children[0].textContent, "系统核心 26.6.27");
  assert.strictEqual(rows[0].children[4].textContent, "运行中");
  assert.strictEqual(rows[0].querySelectorAll("input[data-core-action]").length, 0);
}

{
  const h = harness();
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "downloading", active: true, total_bytes: 100, downloaded_bytes: 46 });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "下载中【46%】");
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "downloading", active: true, total_bytes: 100, downloaded_bytes: 150 });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "下载中【99%】");
  assert.strictEqual(h.elements["xc-core-resource-geoip-check"].disabled, true);
}

{
  const h = harness();
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "downloading", active: true, total_bytes: 0, downloaded_bytes: 0 });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "下载中【0%】");
}

{
  const h = harness(true);
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "downloading", active: true,
    job_id: "1700000000-100", total_bytes: 100, downloaded_bytes: 46 });
  assert.strictEqual(h.elements["xc-core-resource-geoip-cancel"].disabled, false);
  h.elements["xc-core-resource-geoip-cancel"].onclick();
  assert.strictEqual(h.pending[0].method, "POST");
  assert.ok(h.pending[0].url.indexOf("/xc/core-resource-cancel") === 0);
  assert.strictEqual(h.pending[0].body, "job_id=1700000000-100");
  h.pending[0].respond({ ok: true, data: { code: "asset_update_cancel_requested", job_id: "1700000000-100" } });
  assert.strictEqual(h.elements["xc-core-resource-geoip-cancel"].disabled, true);
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "cancelled", active: false, code: "asset_update_cancelled" });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "更新已取消");
}

{
  const h = harness();
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "failed", code: "asset_download_failed" });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "更新失败：下载失败");
}

{
  const h = harness();
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "failed", code: "asset_update_busy" });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "已有核心资源正在更新。");
}

{
  const h = harness();
  h.window.XCCoreUI.renderResourceJob({ kind: "geoip", stage: "succeeded" });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "更新完成【100%】");
}

for (const terminalStage of ["succeeded", "failed", "unchanged"]) {
  const h = harness(true, { kind: "geoip", stage: terminalStage, active: false });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "",
    "terminal resource state is not restored after page load: " + terminalStage);
}

{
  const h = harness(true, { kind: "geoip", stage: "downloading", active: true, total_bytes: 100, downloaded_bytes: 46 });
  assert.strictEqual(h.elements["xc-core-resource-geoip-operation"].textContent, "下载中【46%】",
    "active resource progress is restored after page load");
}

{
  const h = harness();
  h.window.XCCoreUI.renderVersions([
    { id: "v1-aarch64-aaaaaaaaaaaaaaaa", version: "1.0.0", arch: "aarch64",
      size: 1, sha256: "a".repeat(64) }
  ]);
  const button = h.elements["xc-core-versions"].querySelector("input[data-core-action]");
  button.onclick();
  assert.strictEqual(h.confirmations, 1, "activation requires confirmation");
  assert.strictEqual(h.elements["xc-core-operation-state"].textContent, "接口尚未启用");
  assert.strictEqual(button.disabled, false, "placeholder action does not leave the page locked");
}

{
  const h = harness();
  const file = h.elements["xc-core-upload-file"];
  const upload = h.elements["xc-core-upload"];
  assert.strictEqual(upload.disabled, true, "upload is disabled without a file");
  file.files = [{ name: "xray", size: 10 }];
  file.onchange();
  assert.strictEqual(upload.disabled, false, "upload enables after selecting a file");
  file.files = [];
  file.onchange();
  assert.strictEqual(upload.disabled, true, "upload disables when selection is cleared");
}

console.log("core UI DOM tests passed");
