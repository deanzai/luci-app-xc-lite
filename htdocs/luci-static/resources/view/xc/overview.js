'use strict';
'require view';
'require ui';
'require rpc';
'require poll';

var callGetStatus = rpc.declare({
	object: 'luci.xc',
	method: 'get_status',
	expect: {}
});

var callGetNodes = rpc.declare({
	object: 'luci.xc',
	method: 'get_nodes',
	expect: { version: 1, fixed_proxy_id: 1, nodes: [] }
});

var callGetSettings = rpc.declare({
	object: 'luci.xc',
	method: 'get_settings',
	expect: {}
});

var callSwitchNode = rpc.declare({
	object: 'luci.xc',
	method: 'switch_node',
	params: [ 'id' ],
	expect: {}
});

var callProbeNode = rpc.declare({
	object: 'luci.xc',
	method: 'probe_node',
	params: [ 'id' ],
	expect: {}
});

var callSaveNode = rpc.declare({
	object: 'luci.xc',
	method: 'save_node',
	params: [ 'node' ],
	expect: {}
});

var callDeleteNode = rpc.declare({
	object: 'luci.xc',
	method: 'delete_node',
	params: [ 'id' ],
	expect: {}
});

var callRollback = rpc.declare({
	object: 'luci.xc',
	method: 'rollback',
	expect: {}
});

var callTestHealth = rpc.declare({
	object: 'luci.xc',
	method: 'test_health',
	expect: {}
});

var callSaveSettings = rpc.declare({
	object: 'luci.xc',
	method: 'save_settings',
	params: [ 'settings', 'fixed_proxy_id' ],
	expect: {}
});

return view.extend({
	load: function() {
		return Promise.all([
			callGetStatus(),
			callGetNodes(),
			callGetSettings()
		]);
	},

	renderStatusHeader: function(status, nodesData) {
		var isRunning = status && status.running;
		var curId = status ? status.current_id : null;
		var fixedId = nodesData ? nodesData.fixed_proxy_id : 1;

		var nodes = (nodesData && nodesData.nodes) ? nodesData.nodes : [];
		var curNode = nodes.find(function(n) { return Number(n.id) === Number(curId); });
		var fixedNode = nodes.find(function(n) { return Number(n.id) === Number(fixedId); });

		var curText = nodes.length === 0 ? _('未选择 (节点列表为空)') : (curNode ? ('#' + curNode.id + ' ' + curNode.name + ' (' + curNode.type + ')') : _('未选择'));
		var fixedText = nodes.length === 0 ? _('未配置') : (fixedNode ? ('#' + fixedNode.id + ' ' + fixedNode.name) : ('ID: ' + fixedId));

		var sPort = (status && status.socks_port) || 7890;
		var hPort = (status && status.http_port) || 10809;
		var sHost = (status && status.socks_host) || '127.0.0.1';
		var hHost = (status && status.http_host) || '127.0.0.1';

		var socksStatus = (status && status.socks_listening) ? _('正常监听') : _('未监听');
		var httpStatus = (status && status.http_listening) ? _('正常监听') : _('未监听');

		var self = this;

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-node' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('服务运行状态')),
					E('div', { 'class': 'cbi-value-field' }, [
						isRunning 
							? E('span', { 'class': 'badge', 'style': 'background-color:#10b981; color:#fff; padding:4px 8px; border-radius:4px; font-weight:bold;' }, _('● Xray 运行中 (PID: ') + (status.pid || 'running') + ')')
							: E('span', { 'class': 'badge', 'style': 'background-color:#ef4444; color:#fff; padding:4px 8px; border-radius:4px; font-weight:bold;' }, _('● 服务未运行')),
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'style': 'margin-left: 15px;',
							'click': function(ev) {
								ev.target.disabled = true;
								ui.showModal(_('健康检查'), [ E('p', {}, _('正在测试 SOCKS 与 HTTP 代理出口连通性...')) ]);
								callTestHealth().then(function(res) {
									ui.hideModal();
									ev.target.disabled = false;
									if (res && res.code === 0) {
										ui.addNotification(null, E('p', {}, _('健康检查通过：双端口出口访问正常！')), 'success');
									} else {
										ui.addNotification(null, E('p', {}, _('出口检查异常: ') + (res.message || _('未知错误'))), 'danger');
									}
								});
							}
						}, _('测试双端口连通性')),
						E('button', {
							'class': 'cbi-button cbi-button-reset',
							'style': 'margin-left: 8px;',
							'click': function() {
								if (!confirm(_('确定要回滚到上一份节点配置吗？'))) return;
								callRollback().then(function(res) {
									if (res && res.code === 0) {
										ui.addNotification(null, E('p', {}, _('配置已成功回滚！')), 'success');
										window.location.reload();
									} else {
										ui.addNotification(null, E('p', {}, _('回滚失败: ') + (res.message || _('无历史备份配置'))), 'warning');
									}
								});
							}
						}, _('回滚上一节点'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('当前活动节点 (proxy-selected)')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('strong', { 'style': 'color:#2563eb; font-size:14px;' }, curText),
						E('div', { 'class': 'cbi-value-description' }, _('承担普通海外流量 (geosite:geolocation-!cn) 与最终 fallback 出口'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('固定分流节点 (Fixed Proxy)')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('strong', {}, fixedText),
						E('div', { 'class': 'cbi-value-description' }, _('固定承担 OpenAI, YouTube, Google, Twitter, Telegram 等 geosite 访问'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('客户端监听端口')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('span', {}, 'SOCKS5: ' + sHost + ':' + sPort + ' (' + socksStatus + ') | HTTP: ' + hHost + ':' + hPort + ' (' + httpStatus + ') | DNS: 1.1.1.1 DoH (防泄露)')
					])
				])
			])
		]);
	},

	renderNodeTable: function(status, nodesData, settingsData) {
		var self = this;
		var curId = status ? status.current_id : null;
		var fixedId = nodesData ? nodesData.fixed_proxy_id : 1;
		var nodes = (nodesData && nodesData.nodes) ? nodesData.nodes : [];

		var table = E('table', { 'class': 'table cbi-section-table', 'id': 'xc-nodes-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th', 'style': 'width:60px; text-align:center;' }, _('状态')),
				E('th', { 'class': 'th', 'style': 'width:60px; text-align:center;' }, _('编号')),
				E('th', { 'class': 'th' }, _('节点名称')),
				E('th', { 'class': 'th', 'style': 'width:150px;' }, _('协议类型')),
				E('th', { 'class': 'th' }, _('服务器与端口')),
				E('th', { 'class': 'th', 'style': 'width:120px; text-align:center;' }, _('代理链延迟')),
				E('th', { 'class': 'th cbi-section-actions', 'style': 'width:240px; text-align:right;' }, _('操作'))
			])
		]);

		if (nodes.length === 0) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '7', 'style': 'text-align:center; padding:25px; color:#888; font-size:13px;' }, _('暂无节点信息，请点击下方「+ 添加节点信息」按钮手动添加节点。'))
			]));
		} else {
			nodes.forEach(function(node) {
				var isCur = Number(node.id) === Number(curId);
				var isFixed = Number(node.id) === Number(fixedId);

				var latencyId = 'latency-cell-' + node.id;
				var tr = E('tr', { 'class': 'tr' }, [
				// Status dot
				E('td', { 'class': 'td', 'style': 'text-align:center;' }, [
					isCur
						? E('span', { 'style': 'color:#2563eb; font-weight:bold; font-size:16px;' }, '●')
						: E('span', { 'style': 'color:#ccc;' }, '○')
				]),
				// ID
				E('td', { 'class': 'td', 'style': 'text-align:center; font-family:monospace; font-weight:bold;' }, String(node.id)),
				// Name
				E('td', { 'class': 'td' }, [
					E('strong', {}, node.name),
					isFixed ? E('span', { 'style': 'margin-left:6px; font-size:10px; background:#e0e7ff; color:#3730a3; padding:1px 5px; border-radius:3px;' }, _('固定分流')) : ''
				]),
				// Type
				E('td', { 'class': 'td' }, [
					E('span', { 'style': 'font-family:monospace; font-size:11px;' }, node.type)
				]),
				// Server:Port
				E('td', { 'class': 'td', 'style': 'font-family:monospace;' }, node.server + ':' + node.port),
				// Latency
				E('td', { 'class': 'td', 'id': latencyId, 'style': 'text-align:center;' }, [
					E('span', { 'style': 'color:#888; font-size:11px;' }, _('未测速'))
				]),
				// Actions
				E('td', { 'class': 'td cbi-section-actions', 'style': 'text-align:right;' }, [
					// 1. Switch Node
					isCur ? E('button', { 'class': 'cbi-button', 'disabled': true }, _('使用中')) :
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': function(ev) {
							ev.target.disabled = true;
							ui.showModal(_('正在切换节点'), [
								E('p', {}, _('正在切换到节点 #') + node.id + ' [' + node.name + ']...'),
								E('p', {}, _('正在执行 Xray 配置校验、平滑切换及全链路健康测试，请稍候...'))
							]);
							callSwitchNode(node.id).then(function(res) {
								ui.hideModal();
								if (res && res.code === 0) {
									ui.addNotification(null, E('p', {}, _('成功切换至节点 #') + node.id + ' [' + node.name + ']！'), 'success');
									window.location.reload();
								} else {
									ui.addNotification(null, E('p', {}, _('节点切换失败，已自动回滚: ') + (res.message || '')), 'danger');
									ev.target.disabled = false;
								}
							});
						}
					}, _('切换')),

					// 2. Single Probe
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'style': 'margin-left:4px;',
						'click': function(ev) {
							var cell = document.getElementById(latencyId);
							if (cell) cell.innerHTML = '<span style="color:#2563eb;">测速中...</span>';
							callProbeNode(node.id).then(function(res) {
								if (!cell) return;
								if (res && res.latency > 0) {
									var color = res.latency < 250 ? '#10b981' : (res.latency < 500 ? '#f59e0b' : '#ef4444');
									cell.innerHTML = '<span style="color:' + color + '; font-weight:bold; font-family:monospace;">' + res.latency + ' ms</span>';
								} else {
									cell.innerHTML = '<span style="color:#ef4444; font-size:11px;">超时 / 失败</span>';
								}
							});
						}
					}, _('测速')),

					// 3. Edit Node
					E('button', {
						'class': 'cbi-button cbi-button-edit',
						'style': 'margin-left:4px;',
						'click': function() {
							self.showNodeModal('edit', node, nodesData);
						}
					}, _('编辑')),

					// 4. Delete Node
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'style': 'margin-left:4px;',
						'disabled': isCur || isFixed,
						'title': (isCur || isFixed) ? _('活动节点或固定分流节点不可删除') : _('删除节点'),
						'click': function() {
							if (!confirm(_('确定要删除节点 #') + node.id + ' [' + node.name + '] 吗？')) return;
							callDeleteNode(node.id).then(function(res) {
								if (res && res.code === 0) {
									ui.addNotification(null, E('p', {}, _('节点已删除')), 'success');
									window.location.reload();
								} else {
									ui.addNotification(null, E('p', {}, _('删除失败: ') + (res.message || '')), 'danger');
								}
							});
						}
					}, _('删除'))
				])
			]);

			table.appendChild(tr);
		});
		}

		var toolbar = E('div', { 'class': 'cbi-section-actions', 'style': 'margin-bottom:12px; display:flex; justify-content:space-between; align-items:center;' }, [
			E('div', {}, [
				// Add Node Button
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'click': function() {
						self.showNodeModal('add', null, nodesData);
					}
				}, '+ ' + _('添加节点信息')),

				// Manual Refresh All Speed Test
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'style': 'margin-left:8px; background-color:#10b981; color:#fff;',
					'click': function(ev) {
						ev.target.disabled = true;
						ev.target.innerText = _('正在并发全链路测速...');
						ui.addNotification(null, E('p', {}, _('开始并发测试各节点完整代理链延迟...')), 'info');
						
						var promises = nodes.map(function(n) {
							var cell = document.getElementById('latency-cell-' + n.id);
							if (cell) cell.innerHTML = '<span style="color:#2563eb;">测速中...</span>';
							return callProbeNode(n.id).then(function(res) {
								if (!cell) return;
								if (res && res.latency > 0) {
									var color = res.latency < 250 ? '#10b981' : (res.latency < 500 ? '#f59e0b' : '#ef4444');
									cell.innerHTML = '<span style="color:' + color + '; font-weight:bold; font-family:monospace;">' + res.latency + ' ms</span>';
								} else {
									cell.innerHTML = '<span style="color:#ef4444; font-size:11px;">超时 / 失败</span>';
								}
							});
						});

						Promise.all(promises).then(function() {
							ev.target.disabled = false;
							ev.target.innerText = _('手动刷新全部测速');
							ui.addNotification(null, E('p', {}, _('全部节点测速完成！')), 'success');
						});
					}
				}, _('手动刷新全部测速'))
			]),
			E('div', { 'style': 'font-size:12px; color:#666;' }, [
				E('span', { 'style': 'margin-right:12px;' }, '● ' + _('当前节点')),
				E('span', { 'style': 'color:#10b981; font-weight:bold; margin-right:8px;' }, '<250ms ' + _('极优')),
				E('span', { 'style': 'color:#f59e0b; font-weight:bold; margin-right:8px;' }, '250~500ms ' + _('良好')),
				E('span', { 'style': 'color:#ef4444; font-weight:bold;' }, '>500ms ' + _('较慢'))
			])
		]);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('节点清单与管理 (/etc/xc/nodes.json)')),
			toolbar,
			table
		]);
	},

	showNodeModal: function(mode, nodeData, allData) {
		var isEdit = mode === 'edit' && nodeData;
		var nextId = 1;
		if (allData && allData.nodes && allData.nodes.length > 0) {
			nextId = Math.max.apply(null, allData.nodes.map(function(n) { return Number(n.id) || 0; })) + 1;
		}

		var curId = isEdit ? nodeData.id : nextId;
		var curName = isEdit ? nodeData.name : '';
		var curType = isEdit ? nodeData.type : 'VLESS REALITY';
		var curServer = isEdit ? nodeData.server : '';
		var curPort = isEdit ? nodeData.port : (curType === 'VLESS REALITY' ? 443 : 45321);

		var curUuid = (isEdit && nodeData.uuid) ? nodeData.uuid : '';
		var curSni = (isEdit && nodeData.sni) ? nodeData.sni : 'gateway.icloud.com';
		var curPubkey = (isEdit && nodeData.public_key) ? nodeData.public_key : '';
		var curShortid = (isEdit && nodeData.short_id) ? nodeData.short_id : '';
		var curFp = (isEdit && nodeData.fingerprint) ? nodeData.fingerprint : 'chrome';
		var curFlow = (isEdit && nodeData.flow) ? nodeData.flow : 'xtls-rprx-vision';

		var idInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': curId, 'disabled': isEdit, 'style': 'width:100%;' });
		var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': curName, 'placeholder': 'e.g. hk-reality-01', 'style': 'width:100%;' });
		var serverInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': curServer, 'placeholder': 'domain or ip', 'style': 'width:100%;' });
		var portInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': curPort, 'style': 'width:100%;' });

		var uuidInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': curUuid, 'style': 'width:100%;' });
		var sniInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': curSni, 'style': 'width:100%;' });
		var pubkeyInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': curPubkey, 'style': 'width:100%;' });
		var shortidInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': curShortid, 'placeholder': '可留空', 'style': 'width:100%;' });

		var fpSelect = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%;' }, [
			E('option', { 'value': 'chrome', 'selected': curFp === 'chrome' }, 'chrome'),
			E('option', { 'value': 'firefox', 'selected': curFp === 'firefox' }, 'firefox'),
			E('option', { 'value': 'safari', 'selected': curFp === 'safari' }, 'safari'),
			E('option', { 'value': 'edge', 'selected': curFp === 'edge' }, 'edge')
		]);

		var flowSelect = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%;' }, [
			E('option', { 'value': 'xtls-rprx-vision', 'selected': curFlow === 'xtls-rprx-vision' }, 'xtls-rprx-vision'),
			E('option', { 'value': 'none', 'selected': curFlow === 'none' }, 'none')
		]);

		var realitySection = E('div', { 'id': 'modal-reality-fields', 'style': (curType === 'VLESS REALITY') ? 'display:block;' : 'display:none;' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'UUID'),
				E('div', { 'class': 'cbi-value-field' }, uuidInput)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'SNI (Server Name)'),
				E('div', { 'class': 'cbi-value-field' }, sniInput)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Public Key (公钥)'),
				E('div', { 'class': 'cbi-value-field' }, pubkeyInput)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Short ID (短 ID)'),
				E('div', { 'class': 'cbi-value-field' }, shortidInput)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Fingerprint (指纹)'),
				E('div', { 'class': 'cbi-value-field' }, fpSelect)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Flow (流控)'),
				E('div', { 'class': 'cbi-value-field' }, flowSelect)
			])
		]);

		var naiveSection = E('div', { 'id': 'modal-naive-fields', 'style': (curType === 'NaiveProxy SOCKS5') ? 'display:block;' : 'display:none;' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('本地 SOCKS 说明')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('p', { 'class': 'cbi-value-description' }, _('NaiveProxy 需已在路由器本地运行，默认地址 127.0.0.1，端口一般为 45321~45325。'))
				])
			])
		]);

		var typeSelect = E('select', {
			'class': 'cbi-input-select',
			'style': 'width:100%;',
			'change': function(ev) {
				var val = ev.target.value;
				if (val === 'VLESS REALITY') {
					realitySection.style.display = 'block';
					naiveSection.style.display = 'none';
					if (portInput.value == '45321') portInput.value = '443';
				} else {
					realitySection.style.display = 'none';
					naiveSection.style.display = 'block';
					if (portInput.value == '443') portInput.value = '45321';
				}
			}
		}, [
			E('option', { 'value': 'VLESS REALITY', 'selected': curType === 'VLESS REALITY' }, 'VLESS REALITY'),
			E('option', { 'value': 'NaiveProxy SOCKS5', 'selected': curType === 'NaiveProxy SOCKS5' }, 'NaiveProxy SOCKS5')
		]);

		var body = E('div', { 'class': 'cbi-map' }, [
			E('div', { 'class': 'cbi-section-node' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('节点 ID (数字编号)')),
					E('div', { 'class': 'cbi-value-field' }, idInput)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('节点备注名称')),
					E('div', { 'class': 'cbi-value-field' }, nameInput)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('协议类型')),
					E('div', { 'class': 'cbi-value-field' }, typeSelect)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('服务器地址')),
					E('div', { 'class': 'cbi-value-field' }, serverInput)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('端口')),
					E('div', { 'class': 'cbi-value-field' }, portInput)
				]),
				realitySection,
				naiveSection
			])
		]);

		var title = isEdit ? (_('编辑节点 #') + nodeData.id) : _('添加新节点信息');

		ui.showModal(title, [
			body,
			E('div', { 'class': 'right', 'style': 'margin-top:15px;' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': ui.hideModal
				}, _('取消')),
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'style': 'margin-left:8px;',
					'click': function() {
						var nodeObj = {
							id: Number(idInput.value),
							name: nameInput.value.trim(),
							type: typeSelect.value,
							server: serverInput.value.trim(),
							port: Number(portInput.value)
						};

						if (!nodeObj.name || !nodeObj.server || !nodeObj.port) {
							alert(_('请完整填写节点名称、服务器地址与端口！'));
							return;
						}

						if (nodeObj.type === 'VLESS REALITY') {
							nodeObj.uuid = uuidInput.value.trim();
							nodeObj.sni = sniInput.value.trim();
							nodeObj.public_key = pubkeyInput.value.trim();
							nodeObj.short_id = shortidInput.value.trim();
							nodeObj.fingerprint = fpSelect.value;
							nodeObj.flow = flowSelect.value;

							if (!nodeObj.uuid || !nodeObj.public_key) {
								alert(_('VLESS REALITY 协议必须填写 UUID 和 Public Key！'));
								return;
							}
						}

						callSaveNode(nodeObj).then(function(res) {
							ui.hideModal();
							if (res && res.code === 0) {
								ui.addNotification(null, E('p', {}, _('节点信息已保存成功！')), 'success');
								window.location.reload();
							} else {
								ui.addNotification(null, E('p', {}, _('保存失败: ') + (res.message || '')), 'danger');
							}
						});
					}
				}, _('保存节点'))
			])
		]);
	},

	renderSettingsSection: function(nodesData, settingsData) {
		var socksHost = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:180px;', 'value': (settingsData && settingsData.socks_host) || (settingsData && settingsData.listen_host) || '127.0.0.1' });
		var socksPort = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:100px;', 'value': (settingsData && settingsData.socks_port) || 7890 });

		var httpHost = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:180px;', 'value': (settingsData && settingsData.http_host) || (settingsData && settingsData.listen_host) || '127.0.0.1' });
		var httpPort = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:100px;', 'value': (settingsData && settingsData.http_port) || 10809 });

		var proxyHost = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (settingsData && settingsData.proxy_host) || '127.0.0.1' });
		var probeUrl = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (settingsData && settingsData.probe_url) || 'http://www.gstatic.com/generate_204' });
		var healthUrl = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (settingsData && settingsData.health_url) || 'http://www.gstatic.com/generate_204' });

		var fixedSelect = E('select', { 'class': 'cbi-input-select' });
		var nodes = (nodesData && nodesData.nodes) ? nodesData.nodes : [];
		var curFixed = nodesData ? nodesData.fixed_proxy_id : null;
		if (nodes.length === 0) {
			fixedSelect.appendChild(E('option', { 'value': '' }, _('暂无可用节点')));
		} else {
			nodes.forEach(function(n) {
				fixedSelect.appendChild(E('option', { 'value': n.id, 'selected': Number(n.id) === Number(curFixed) }, '#' + n.id + ' - ' + n.name + ' (' + n.type + ')'));
			});
		}

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('全局运行参数 (/etc/xc/settings.json)')),
			E('div', { 'class': 'cbi-section-node' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, E('strong', {}, _('SOCKS 代理接口'))),
					E('div', { 'class': 'cbi-value-field' }, [
						E('div', { 'style': 'display:flex; gap:10px; align-items:center; flex-wrap:wrap;' }, [
							E('div', {}, [ E('span', { 'style': 'font-size:12px; color:#666;' }, _('绑定地址: ')), socksHost ]),
							E('div', {}, [ E('span', { 'style': 'font-size:12px; color:#666;' }, _('监听端口: ')), socksPort ])
						]),
						E('div', { 'class': 'cbi-value-description' }, _('支持 TCP/UDP，客户端配置为 SOCKS5h。默认 127.0.0.1 仅本机，填 0.0.0.0 可供局域网使用。'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, E('strong', {}, _('HTTP 代理接口'))),
					E('div', { 'class': 'cbi-value-field' }, [
						E('div', { 'style': 'display:flex; gap:10px; align-items:center; flex-wrap:wrap;' }, [
							E('div', {}, [ E('span', { 'style': 'font-size:12px; color:#666;' }, _('绑定地址: ')), httpHost ]),
							E('div', {}, [ E('span', { 'style': 'font-size:12px; color:#666;' }, _('监听端口: ')), httpPort ])
						]),
						E('div', { 'class': 'cbi-value-description' }, _('供普通浏览器或 HTTP 客户端使用的正向 HTTP 代理端口。'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('健康测试代理地址 (proxy_host)')),
					E('div', { 'class': 'cbi-value-field' }, proxyHost)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('测速目标 URL (probe_url)')),
					E('div', { 'class': 'cbi-value-field' }, probeUrl)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('出口测试 URL (health_url)')),
					E('div', { 'class': 'cbi-value-field' }, healthUrl)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('固定分流节点 (fixed_proxy_id)')),
					E('div', { 'class': 'cbi-value-field' }, [
						fixedSelect,
						E('div', { 'class': 'cbi-value-description' }, _('指定负责承担 YouTube, Google, OpenAI 等 geosite 流量的固定节点'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }),
					E('div', { 'class': 'cbi-value-field' }, [
						E('button', {
							'class': 'cbi-button cbi-button-save',
							'click': function(ev) {
								ev.target.disabled = true;
								var newSettings = {
									socks_host: socksHost.value.trim(),
									socks_port: Number(socksPort.value.trim()),
									http_host: httpHost.value.trim(),
									http_port: Number(httpPort.value.trim()),
									proxy_host: proxyHost.value.trim(),
									probe_url: probeUrl.value.trim(),
									health_url: healthUrl.value.trim()
								};
								callSaveSettings(newSettings, Number(fixedSelect.value)).then(function(res) {
									ev.target.disabled = false;
									if (res && res.code === 0) {
										ui.addNotification(null, E('p', {}, _('全局设置已成功保存！')), 'success');
									} else {
										ui.addNotification(null, E('p', {}, _('保存全局设置失败')), 'danger');
									}
								});
							}
						}, _('保存全局设置'))
					])
				])
			])
		]);
	},

	render: function(data) {
		var status = data[0] || {};
		var nodesData = data[1] || { version: 1, fixed_proxy_id: 1, nodes: [] };
		var settingsData = data[2] || {};

		var m = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('xc 节点切换与分流管理器')),
			E('div', { 'class': 'cbi-map-descr' }, _('轻量级 Xray 节点切换与分流管理插件，支持 VLESS REALITY 与本地 NaiveProxy SOCKS 节点，提供全链路延迟测速、平滑切换与失败回滚。')),
			this.renderStatusHeader(status, nodesData),
			this.renderNodeTable(status, nodesData, settingsData),
			this.renderSettingsSection(nodesData, settingsData)
		]);

		return m;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
