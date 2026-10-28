'use strict';

const assert = require('assert');
const { loadOverviewView } = require('./luci_test_env');

async function testSettingsAndLogUI() {
	console.log('=== Running Settings & Log UI Tests ===');

	const mockNodes = {
		version: 1,
		fixed_proxy_id: 1,
		nodes: [
			{ id: 1, name: 'Node 1', type: 'VLESS REALITY' }
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
		log_level: 'warning'
	};

	const { viewInstance } = loadOverviewView();
	const section = viewInstance.renderSettingsSection(mockNodes, mockSettings);
	assert.ok(section, 'Must render settings section');

	const text = section.textContent;
	assert.ok(text.includes('全局基础设置'), 'Must include 全局基础设置 title');
	assert.ok(text.includes('log_level'), 'Must include log_level option');
	assert.ok(text.includes('warning'), 'Must include warning option');
	assert.ok(text.includes('info'), 'Must include info option');

	const inputs = section.querySelectorAll('input');
	const values = inputs.map(i => String(i.value));
	assert.ok(values.includes('7890'), 'Must include default socks port');
	assert.ok(values.includes('10809'), 'Must include default http port');

	console.log('  PASS: Settings section renders log_level and network parameters');

	// Test Case: Multi-node select attribute regression (e.g. 11 nodes where fixed node is 1, not last node 11)
	const nodes11 = {
		version: 1,
		fixed_proxy_id: 1,
		nodes: [
			{ id: 1, name: 'reality-uk', type: 'VLESS REALITY' },
			{ id: 2, name: 'reality-gem', type: 'VLESS REALITY' },
			{ id: 3, name: 'reality-jp-vir', type: 'VLESS REALITY' },
			{ id: 4, name: 'reality-hk', type: 'VLESS REALITY' },
			{ id: 5, name: 'reality-jp', type: 'VLESS REALITY' },
			{ id: 7, name: 'Naive-na167', type: 'NaiveProxy SOCKS5' },
			{ id: 8, name: 'Naive-na208', type: 'NaiveProxy SOCKS5' },
			{ id: 9, name: 'Naive-na217', type: 'NaiveProxy SOCKS5' },
			{ id: 10, name: 'Naive-na95', type: 'NaiveProxy SOCKS5' },
			{ id: 11, name: 'Naive-na174', type: 'NaiveProxy SOCKS5' }
		]
	};

	const section11 = viewInstance.renderSettingsSection(nodes11, { fixed_proxy_id: 1, log_level: 'warning' });
	const selects = section11.querySelectorAll('select');
	assert.ok(selects.length >= 2, 'Must have logLevelSelect and fixedSelect');
	const fixedSel = selects[0];
	const logLevelSel = selects[1];

	assert.strictEqual(logLevelSel.value, 'warning', 'logLevelSelect must default to warning, not the last option (debug)');
	assert.strictEqual(String(fixedSel.value), '1', 'fixedSelect must accurately select node 1, NOT the last node 11');
	console.log('  PASS: Multi-node dropdown correctly selects node 1 without falling through to node 11');
}

testSettingsAndLogUI().catch(err => {
	console.error('Settings & Log UI Test FAILED:', err);
	process.exit(1);
});
