'use strict';

const assert = require('assert');
const { loadOverviewView } = require('./luci_test_env');

async function testNodeManagement() {
	console.log('=== Running Task 9 Node Management & UI Tests ===');

	const mockStatus = {
		running: true,
		current_id: 1,
		version: '1.0.22-1'
	};

	const mockNodes = {
		version: 1,
		fixed_proxy_id: 1,
		nodes: [
			{ id: 1, name: 'HK-01', type: 'VLESS REALITY', server: 'hk.node', port: 443 },
			{ id: 2, name: 'JP-02', type: 'VMess', server: 'jp.node', port: 443 }
		]
	};

	const mockSettings = {
		probe_concurrency: 3,
		probe_timeout: 5
	};

	let savedNode = null;
	let deletedId = null;

	const { viewInstance, modals } = loadOverviewView({
		save_node: (node) => { savedNode = node; return { code: 0, message: 'ok' }; },
		delete_node: (id) => { deletedId = id; return { code: 0, message: 'ok' }; },
		probe_node: (id) => ({ code: 0, id, latency: 45 })
	});

	// Test 1: Render Node Table
	const tableSection = viewInstance.renderNodeTable(mockStatus, mockNodes, mockSettings);
	assert.ok(tableSection, 'Must render node table section');
	const table = tableSection.querySelector('#xc-nodes-table');
	assert.ok(table, 'Must have #xc-nodes-table');

	// Test 2: Add Node Modal
	viewInstance.showNodeModal('add', null, mockNodes);
	const addModal = modals[modals.length - 1];
	assert.ok(addModal, 'Must show add modal');
	assert.ok(addModal.title.includes('添加'), 'Modal title must be 添加');

	// Test 3: Edit Node Modal
	viewInstance.showNodeModal('edit', mockNodes.nodes[0], mockNodes);
	const editModal = modals[modals.length - 1];
	assert.ok(editModal, 'Must show edit modal');
	assert.ok(editModal.title.includes('编辑'), 'Modal title must be 编辑');

	// Test 4: Batch Import Modal
	viewInstance.showImportModal(mockNodes);
	const importModal = modals[modals.length - 1];
	assert.ok(importModal, 'Must show import modal');
	assert.ok(importModal.title.includes('导入'), 'Modal title must be 导入');

	console.log('  PASS: Node Table, Add Modal, Edit Modal, and Import Modal');
}

testNodeManagement().catch(err => {
	console.error('Task 9 Test FAILED:', err);
	process.exit(1);
});
