'use strict';

const assert = require('assert');
const { loadOverviewView } = require('./luci_test_env');

async function runTests() {
	console.log('=== Running Modern LuCI overview.js Simulated User Operation Tests ===');

	const mockStatus = {
		running: true,
		pid: 12345,
		version: '1.0.23-1',
		current_id: 1,
		fixed_proxy_id: 2,
		socks_listening: true,
		http_listening: true,
		exit_ip: '198.51.100.1',
		core: {
			running: true,
			source: 'custom',
			version: 'Xray 1.8.7 (custom)',
			arch_compatible: true
		},
		assets: {
			geosite: { exists: true, source: 'custom', size_formatted: '3.2 MB' },
			geoip: { exists: true, source: 'custom', size_formatted: '2.8 MB' }
		}
	};

	const mockNodes = {
		version: 1,
		fixed_proxy_id: 2,
		nodes: [
			{ id: 1, name: 'HK VLESS 01', type: 'VLESS REALITY', server: 'hk.example.com', port: 443, uuid: 'uuid-1', public_key: 'pbk-1' },
			{ id: 2, name: 'US Fixed Proxy', type: 'VLESS REALITY', server: 'us.example.com', port: 443, uuid: 'uuid-2', public_key: 'pbk-2' },
			{ id: 3, name: 'JP Backup Node', type: 'SOCKS5', server: '127.0.0.1', port: 1080 }
		]
	};

	const mockSettings = {
		enabled: '1',
		listen_host: '0.0.0.0',
		socks_port: 7890,
		http_port: 10809,
		proxy_host: '127.0.0.1',
		health_url: 'http://www.gstatic.com/generate_204',
		probe_url: 'http://www.gstatic.com/generate_204',
		probe_timeout: 5,
		probe_concurrency: 3,
		log_level: 'warning',
		core_source: 'custom',
		asset_source: 'custom'
	};

	let switchedId = null;
	let probedId = null;
	let savedSettings = null;
	let importedText = null;

	const { viewInstance, rpcCalls, notifications, modals, sessionStorage } = loadOverviewView({
		get_status: () => mockStatus,
		get_nodes: () => mockNodes,
		get_settings: () => mockSettings,
		switch_node: (id) => { switchedId = id; return { code: 0, message: 'ok' }; },
		probe_node: (id) => { probedId = id; return { code: 0, id, latency: 68 }; },
		save_settings: (s, fId) => { savedSettings = { s, fId }; return { code: 0, message: 'saved' }; },
		import_nodes: (text) => { importedText = text; return { code: 0, count: 2, message: 'imported' }; },
		restart_service: () => ({ code: 0, message: 'restarted' }),
		stop_service: () => ({ code: 0, message: 'stopped' }),
		test_health: () => ({ code: 0, socks_ok: true, http_ok: true, exit_ip: '198.51.100.1' }),
		switch_source: () => ({ code: 0, message: 'switched' })
	});

	// Test 1: view.load()
	console.log('Test 1: view.load() fetches initial data');
	const loadedData = await viewInstance.load();
	assert.strictEqual(loadedData.length, 3, 'load() must return 3 promises for status, nodes, settings');
	assert.strictEqual(loadedData[0].version, '1.0.23-1');
	assert.strictEqual(loadedData[1].nodes.length, 3);
	console.log('  PASS: view.load()');

	// Test 2: view.render()
	console.log('Test 2: view.render() constructs UI and Tab navigation');
	const rendered = viewInstance.render(loadedData);
	assert.ok(rendered, 'render() must return a DOM node');

	// Tab bar check
	const tabBar = rendered.querySelector('.xc-tab-bar');
	assert.ok(tabBar, 'Must render .xc-tab-bar');
	const tabBtns = tabBar.querySelectorAll('button');
	assert.strictEqual(tabBtns.length, 3, 'Must render exactly 3 tab buttons (nodes, settings, core)');
	console.log('  PASS: Tab buttons rendered');

	// Test 3: Tab Switching
	console.log('Test 3: Simulated user clicks on Tab 2 (Settings)');
	tabBtns[1].click();
	assert.strictEqual(sessionStorage.xc_active_tab, 'settings', 'Active tab must be stored in sessionStorage');
	console.log('  PASS: Tab switching persistence');

	// Test 4: Node Table Rendering & Action Buttons
	console.log('Test 4: Node table contains all nodes and badges');
	const nodeTable = rendered.querySelector('#xc-nodes-table');
	assert.ok(nodeTable, 'Must contain #xc-nodes-table');
	const rows = nodeTable.querySelectorAll('.tr');
	// 1 title row + 3 node rows = 4 rows
	assert.strictEqual(rows.length, 4, 'Must render 3 node rows in table');

	// Current active badge check
	assert.ok(rows[1].textContent.includes('当前活动') || rows[1].textContent.includes('使用中'), 'Node 1 must have active indicator');
	// Fixed proxy badge check
	assert.ok(rows[2].textContent.includes('固定分流'), 'Node 2 must have fixed proxy indicator');
	console.log('  PASS: Node table & badges');

	// Test 5: Simulated User Clicks "Switch Node"
	console.log('Test 5: Simulated user switches node to ID=2');
	const switchBtns = nodeTable.querySelectorAll('button');
	const switchBtnNode2 = switchBtns.find(b => b.textContent.includes('切换'));
	assert.ok(switchBtnNode2, 'Must have a Switch button for available nodes');
	switchBtnNode2.click();
	assert.strictEqual(switchedId, 2, 'Clicking switch must invoke callSwitchNode with ID 2');
	console.log('  PASS: Switch node user action');

	// Test 6: Simulated User Probes Single Node
	console.log('Test 6: Simulated user clicks probe button on a node');
	const probeBtns = switchBtns.filter(b => b.textContent.includes('测速'));
	assert.ok(probeBtns.length > 0, 'Must have probe buttons');
	probeBtns[0].click();
	assert.strictEqual(probedId, 1, 'Clicking probe must invoke callProbeNode for ID 1');
	console.log('  PASS: Single node probe user action');

	// Test 7: Simulated User Opens "Add Node Modal"
	console.log('Test 7: Simulated user opens Add Node Modal');
	const allBtns = rendered.querySelectorAll('button');
	const addBtn = allBtns.find(b => b.textContent.includes('添加节点'));
	assert.ok(addBtn, 'Must have Add Node button');
	addBtn.click();
	const addModal = modals[modals.length - 1];
	assert.ok(addModal, 'Clicking Add Node must open a modal');
	assert.ok(addModal.title.includes('添加'), 'Modal title must contain 添加, got: ' + addModal.title);
	console.log('  PASS: Add Node modal display');

	// Test 8: Simulated User Opens "Batch Import Modal"
	console.log('Test 8: Simulated user opens Batch Import Modal');
	const importBtn = allBtns.find(b => b.textContent.includes('导入节点链接'));
	assert.ok(importBtn, 'Must have Import button');
	importBtn.click();
	const importModal = modals[modals.length - 1];
	assert.ok(importModal, 'Clicking Import must open a modal');
	assert.ok(importModal.title.includes('导入'), 'Modal title must contain 导入, got: ' + importModal.title);
	console.log('  PASS: Batch Import modal display');

	// Test 9: Simulated User Service Controls (Restart, Stop, Health)
	console.log('Test 9: Simulated user triggers Service Restart and Health Test');
	const restartBtn = allBtns.find(b => b.textContent.includes('重启服务') || b.textContent.includes('启动服务'));
	assert.ok(restartBtn, 'Must have Restart/Start button');
	restartBtn.click();
	await Promise.resolve();
	assert.ok(rpcCalls.some(c => c.method === 'restart_service'), 'Must invoke restart_service RPC');

	const healthBtn = allBtns.find(b => b.textContent.includes('测试双端口连通性'));
	assert.ok(healthBtn, 'Must have Health Test button');
	healthBtn.click();
	await Promise.resolve();
	assert.ok(rpcCalls.some(c => c.method === 'test_health'), 'Must invoke test_health RPC');
	console.log('  PASS: Service controls');

	// Test 10: Simulated User Switches Core Source
	console.log('Test 10: Simulated user switches Core Source to custom');
	await viewInstance.handleSwitchSource('custom', null);
	assert.ok(rpcCalls.some(c => c.method === 'switch_source' && c.args[0] === 'custom'), 'Must invoke switch_source RPC with custom');
	console.log('  PASS: Source switching');

	console.log('ALL MODERN UI SIMULATED USER TESTS PASSED (10/10)!');
}

runTests().catch(err => {
	console.error('TEST FAILED:', err);
	process.exit(1);
});
