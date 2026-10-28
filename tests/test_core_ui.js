'use strict';

const assert = require('assert');
const { loadOverviewView } = require('./luci_test_env');

async function testCoreAssetsUI() {
	console.log('=== Running Core & Assets UI Operation Tests ===');

	let switchedCore = undefined;
	let switchedAsset = undefined;

	const { viewInstance, modals, notifications, rpcCalls, getLastXhr, document } = loadOverviewView({
		switch_source: (core, asset) => {
			switchedCore = core;
			switchedAsset = asset;
			return { code: 0, message: 'ok' };
		}
	});

	// Case 1: All components missing
	const missingStatus = {
		core_status: {
			xray_ok: false,
			geosite_ok: false,
			geoip_ok: false,
			active_core_source: 'missing',
			active_asset_source: 'missing'
		}
	};
	const missingPane = viewInstance.renderCoreAssetsSection(missingStatus);
	assert.ok(missingPane, 'renderCoreAssetsSection must return a DOM section');
	const missingText = missingPane.textContent;
	assert.ok(missingText.includes('缺失 (未安装)'), 'Must indicate missing status when not installed');
	assert.ok(missingText.includes('Xray 核心程序'), 'Must render Xray core row');
	assert.ok(missingText.includes('GeoSite'), 'Must render GeoSite row');
	assert.ok(missingText.includes('GeoIP'), 'Must render GeoIP row');
	console.log('  PASS 1: Component status badges render correctly for missing state');

	// Case 2: Custom core and builtin fallback asset
	const activeStatus = {
		core_status: {
			xray_ok: true,
			xray_path: '/etc/xc/bin/xray',
			geosite_ok: true,
			geosite_path: '/usr/share/xray/geosite.dat',
			geoip_ok: true,
			geoip_path: '/usr/share/xray/geoip.dat',
			active_core_source: 'custom',
			builtin_core_available: true,
			active_asset_source: 'builtin_fallback',
			builtin_asset_available: true
		}
	};
	const activePane = viewInstance.renderCoreAssetsSection(activeStatus);
	const activeText = activePane.textContent;
	assert.ok(activeText.includes('已选用 (自定义核心)'), 'Must display custom core active badge');
	assert.ok(activeText.includes('系统保底生效中'), 'Must display builtin fallback asset badge');
	console.log('  PASS 2: Component status badges render correctly for custom core & fallback assets');

	// Case 3: Switch Core Source to Builtin
	viewInstance.handleSwitchSource('builtin', null);
	assert.strictEqual(switchedCore, 'builtin', 'Must call switch_source with core=builtin');
	assert.strictEqual(switchedAsset, null, 'Asset should remain null when switching core only');
	console.log('  PASS 3: handleSwitchSource successfully triggers RPC to switch core');

	// Case 4: Switch Asset Source to Custom
	viewInstance.handleSwitchSource(null, 'custom');
	assert.strictEqual(switchedAsset, 'custom', 'Must call switch_source with asset=custom');
	console.log('  PASS 4: handleSwitchSource successfully triggers RPC to switch assets');

	// Case 5: Trigger Upload Core Modal
	viewInstance.triggerUpload('xray', 'Xray 核心程序');
	const fileInput = document.body.querySelector('input[type="file"]');
	assert.ok(fileInput, 'triggerUpload must append a hidden file input to document.body');

	const mockFile = {
		name: 'xray-linux-mipsle.tar.gz',
		size: 15 * 1024 * 1024 // 15MB
	};
	fileInput.files = [mockFile];
	fileInput.dispatchEvent('change');

	// Verify modal was shown
	const uploadModal = modals[modals.length - 1];
	assert.ok(uploadModal, 'Must open LuCI modal on file select');
	assert.ok(uploadModal.title.includes('上传并部署'), 'Modal title must mention 上传并部署');
	assert.ok(uploadModal.body[0].textContent.includes('xray-linux-mipsle.tar.gz'), 'Modal must display file name');
	assert.ok(uploadModal.body[0].textContent.includes('15.00 MB'), 'Modal must display file size in MB');

	// Verify XHR was configured
	const xhr = getLastXhr();
	assert.ok(xhr, 'XMLHttpRequest must have been created');
	assert.strictEqual(xhr.method, 'POST');
	assert.ok(xhr.url.includes('/cgi-bin/luci/admin/services/xc/upload?type=xray'), 'Upload URL must point to upload endpoint with type=xray');
	assert.ok(xhr.sentData, 'FormData must have been sent via XHR');
	assert.strictEqual(xhr.sentData.entries.type, 'xray', 'FormData must contain type');
	assert.strictEqual(xhr.sentData.entries.token, 'mock-token-abc', 'FormData must contain CSRF token');
	assert.strictEqual(xhr.sentData.entries.file.name, 'xray-linux-mipsle.tar.gz', 'FormData must contain selected file');
	console.log('  PASS 5: triggerUpload creates modal, formats file info, and posts to upload controller');

	// Case 6: Simulate Upload Progress
	if (xhr.upload.onprogress) {
		xhr.upload.onprogress({
			lengthComputable: true,
			loaded: 7.5 * 1024 * 1024,
			total: 15 * 1024 * 1024
		});
	}
	assert.ok(uploadModal.body[0].textContent.includes('50%'), 'Modal must update upload progress to 50%');
	console.log('  PASS 6: XHR upload progress updates modal stats and percentage');

	// Case 7: Cancel Upload
	const btnCancel = uploadModal.body[0].querySelector('.cbi-button-reset');
	assert.ok(btnCancel, 'Modal must contain cancel upload button');
	btnCancel.click();
	assert.strictEqual(xhr.aborted, true, 'Clicking cancel must abort XHR request');
	assert.ok(uploadModal.body[0].textContent.includes('已由用户手动取消上传'), 'Modal must display user cancelled message');
	console.log('  PASS 7: Cancelling upload cleanly aborts in-flight request');

	console.log('All Core & Assets UI tests PASSED successfully!');
}

testCoreAssetsUI().catch(err => {
	console.error('Core UI test failed:', err);
	process.exit(1);
});
