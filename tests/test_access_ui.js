'use strict';

const assert = require('assert');
const fs = require('fs');

console.log('=== Running Access Control & ACL Verification Tests ===');

// 1. Verify RPCD ACL JSON
const aclPath = 'root/usr/share/rpcd/acl.d/luci-app-xc.json';
assert.ok(fs.existsSync(aclPath), 'RPCD ACL file must exist at ' + aclPath);
const aclRaw = fs.readFileSync(aclPath, 'utf8');
const acl = JSON.parse(aclRaw);
assert.ok(acl['luci-app-xc'], 'ACL must define luci-app-xc group');

const readUbus = (acl['luci-app-xc'].read && acl['luci-app-xc'].read.ubus && acl['luci-app-xc'].read.ubus['luci.xc']) || [];
const writeUbus = (acl['luci-app-xc'].write && acl['luci-app-xc'].write.ubus && acl['luci-app-xc'].write.ubus['luci.xc']) || [];
const readUci = (acl['luci-app-xc'].read && acl['luci-app-xc'].read.uci) || [];
const writeUci = (acl['luci-app-xc'].write && acl['luci-app-xc'].write.uci) || [];

assert.ok(readUci.includes('xc'), 'Read access must include uci: xc');
assert.ok(writeUci.includes('xc'), 'Write access must include uci: xc');
console.log('  PASS 1: RPCD ACL syntax and UCI scope verified');

// 2. Verify Menu Declaration JSON
const menuPath = 'root/usr/share/luci/menu.d/luci-app-xc.json';
assert.ok(fs.existsSync(menuPath), 'Menu definition file must exist at ' + menuPath);
const menuRaw = fs.readFileSync(menuPath, 'utf8');
const menu = JSON.parse(menuRaw);
const entry = menu['admin/services/xc'];
assert.ok(entry, 'Menu must declare admin/services/xc route');
assert.strictEqual(entry.action.type, 'view', 'Menu action type must be view');
assert.strictEqual(entry.action.path, 'xc/overview', 'Menu view path must match xc/overview');
assert.ok(entry.depends && entry.depends.acl && entry.depends.acl.includes('luci-app-xc'),
	'Menu route must depend on luci-app-xc ACL group');
console.log('  PASS 2: LuCI menu declaration points to overview.js with proper ACL dependency');

// 3. Verify UCITRACK JSON
const ucitrackPath = 'root/usr/share/ucitrack/luci-app-xc.json';
assert.ok(fs.existsSync(ucitrackPath), 'Ucitrack file must exist at ' + ucitrackPath);
const ucitrack = JSON.parse(fs.readFileSync(ucitrackPath, 'utf8'));
assert.ok(ucitrack.config === 'xc' || ucitrack.xc, 'Ucitrack must track xc configuration');
assert.strictEqual(ucitrack.init || (ucitrack.xc && ucitrack.xc.init), 'xc', 'Ucitrack must specify init script xc');
console.log('  PASS 3: Ucitrack triggers daemon reload on UCI changes');

// 4. Cross-verify with overview.js RPC Declarations
const overviewJs = fs.readFileSync('htdocs/luci-static/resources/view/xc/overview.js', 'utf8');
const rpcMethodRegex = /method:\s*['"]([a-zA-Z0-9_-]+)['"]/g;
const declaredMethods = [];
let match;
while ((match = rpcMethodRegex.exec(overviewJs)) !== null) {
	if (!declaredMethods.includes(match[1])) {
		declaredMethods.push(match[1]);
	}
}

assert.ok(declaredMethods.length >= 10, 'overview.js must declare at least 10 RPC methods, found ' + declaredMethods.length);

const allGrantedMethods = new Set([...readUbus, ...writeUbus]);
for (const method of declaredMethods) {
	assert.ok(allGrantedMethods.has(method),
		'Security violation: method "' + method + '" declared in overview.js is NOT granted in RPCD ACL! This will cause RPC 403 Access Denied.');
}
console.log('  PASS 4: All ' + declaredMethods.length + ' RPC methods in overview.js are explicitly granted in RPCD ACL');

// 5. Ensure secure code practices in overview.js
assert.strictEqual(overviewJs.includes('eval('), false, 'overview.js must never call eval()');
assert.strictEqual(overviewJs.includes('document.write('), false, 'overview.js must never call document.write()');
console.log('  PASS 5: Security audit passed (no eval, no document.write)');

console.log('All Access Control & ACL tests PASSED successfully!');
