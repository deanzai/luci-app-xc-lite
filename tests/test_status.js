'use strict';

const assert = require('assert');
const { loadOverviewView } = require('./luci_test_env');

async function testStatusView() {
	console.log('=== Running Status View Tests ===');

	const mockStatus = {
		running: true,
		pid: 4567,
		version: '1.0.22-1',
		current_id: 1,
		fixed_proxy_id: 2,
		socks_listening: true,
		http_listening: true,
		exit_ip: '203.0.113.195',
		core: {
			running: true,
			source: 'custom',
			version: 'Xray 1.8.7 (custom)'
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
			{ id: 1, name: 'Active HK', type: 'VLESS REALITY', server: 'hk.node', port: 443 },
			{ id: 2, name: 'Fixed US', type: 'VLESS REALITY', server: 'us.node', port: 443 }
		]
	};

	const { viewInstance } = loadOverviewView();
	const header = viewInstance.renderStatusHeader(mockStatus, mockNodes);
	assert.ok(header, 'renderStatusHeader must return a DOM node');

	const text = header.textContent;
	assert.ok(text.includes('1.0.22-1'), 'Header must display plugin version');
	assert.ok(text.includes('4567'), 'Header must display process PID');
	assert.ok(text.includes('Active HK') || text.includes('#1'), 'Header must display current active node name or ID');
	assert.ok(text.includes('Fixed US') || text.includes('#2'), 'Header must display fixed proxy node');
	assert.ok(text.includes('7890'), 'Header must display SOCKS port');
	assert.ok(text.includes('10809'), 'Header must display HTTP port');

	console.log('  PASS: Status view renders version, pid, active node, and ports');
}

testStatusView().catch(err => {
	console.error('Status View Test FAILED:', err);
	process.exit(1);
});
