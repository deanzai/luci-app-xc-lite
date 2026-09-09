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
	params: [ 'id', 'timeout' ],
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

var callSwitchSource = rpc.declare({
	object: 'luci.xc',
	method: 'switch_source',
	params: [ 'core_source', 'asset_source' ],
	expect: {}
});

var callRestartService = rpc.declare({
	object: 'luci.xc',
	method: 'restart_service',
	expect: {}
});

var callStopService = rpc.declare({
	object: 'luci.xc',
	method: 'stop_service',
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

	renderMissingAlert: function(status) {
		var cs = status && status.core_status;
		if (!cs || cs.ready) {
			return E('div', { 'style': 'display:none;' });
		}
		var missingNames = [];
		if (!cs.xray_ok) missingNames.push(_('Xray 核心程序 (xray)'));
		if (!cs.geosite_ok) missingNames.push(_('GeoSite 域名规则库 (geosite.dat)'));
		if (!cs.geoip_ok) missingNames.push(_('GeoIP IP规则库 (geoip.dat)'));

		return E('div', {
			'class': 'alert-message danger',
			'style': 'margin-bottom: 20px; border-left: 5px solid #ef4444; background: #fef2f2; padding: 14px 18px; border-radius: 6px; color: #991b1b; box-shadow: 0 1px 3px rgba(0,0,0,0.08);'
		}, [
			E('h4', { 'style': 'margin: 0 0 6px 0; color: #b91c1c; font-size: 15px; display: flex; align-items: center;' }, [
				E('span', { 'style': 'font-size: 18px; margin-right: 8px;' }, '⚠️'),
				_('核心文件或路由规则丢失，服务无法正常启动！')
			]),
			E('p', { 'style': 'margin: 0; font-size: 13px; line-height: 1.5;' }, [
				_('检测到以下必要组件缺失：'),
				E('strong', { 'style': 'color: #dc2626; margin: 0 4px;' }, missingNames.join('、')),
				_('。请在下方「核心组件与规则文件管理」区域上传对应的文件。若已上传或安装，请确认文件路径及可执行权限。系统错误已同步输出至系统日志 (logread)。')
			])
		]);
	},

	triggerUpload: function(type, title) {
		var self = this;
		var input = document.createElement('input');
		input.type = 'file';
		input.style.display = 'none';
		document.body.appendChild(input);

		input.addEventListener('change', function() {
			if (!input.files || input.files.length === 0) {
				document.body.removeChild(input);
				return;
			}
			var file = input.files[0];
			document.body.removeChild(input);

			var totalMB = (file.size / (1024 * 1024)).toFixed(2);

			var pbar = E('div', {
				'style': 'width: 0%; height: 100%; background: linear-gradient(90deg, #3b82f6, #2563eb); border-radius: 8px; transition: width 0.12s ease-out;'
			});
			var pbarTrack = E('div', {
				'style': 'width: 100%; height: 16px; background-color: #e5e7eb; border-radius: 8px; overflow: hidden; margin: 12px 0 8px 0; box-shadow: inset 0 1px 2px rgba(0,0,0,0.1);'
			}, [ pbar ]);

			var statsText = E('span', {
				'style': 'font-family: monospace; font-weight: bold; color: #2563eb;'
			}, '0% (0.00 / ' + totalMB + ' MB)');

			var statusText = E('span', {
				'style': 'color: #4b5563;'
			}, _('正在连接路由器并准备上传...'));

			var infoRow = E('div', {
				'style': 'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 12px;'
			}, [ statusText, statsText ]);

			var msgBox = E('div', {
				'style': 'display: none; padding: 10px 14px; border-radius: 6px; font-size: 13px; line-height: 1.5; margin-bottom: 12px;'
			});

			var currentXhr = null;

			var btnCancel = E('button', {
				'class': 'cbi-button cbi-button-reset',
				'click': function() {
					if (currentXhr) {
						currentXhr.abort();
						currentXhr = null;
					}
					statusText.innerText = _('上传已取消');
					msgBox.style.display = 'block';
					msgBox.style.background = '#fffbeb';
					msgBox.style.border = '1px solid #fde68a';
					msgBox.style.color = '#b45309';
					msgBox.innerHTML = _('已由用户手动取消上传。');
					btnCancel.style.display = 'none';
					btnClose.style.display = 'inline-block';
				}
			}, _('取消上传'));

			var btnClose = E('button', {
				'class': 'cbi-button cbi-button-action',
				'style': 'display: none;',
				'click': ui.hideModal
			}, _('关闭'));

			var modalBody = E('div', { 'style': 'padding: 5px 0;' }, [
				E('div', { 'style': 'display: flex; justify-content: space-between; font-size: 13px; margin-bottom: 6px;' }, [
					E('strong', { 'style': 'font-family: monospace; color: #111827;' }, file.name),
					E('span', { 'style': 'color: #6b7280; font-family: monospace;' }, totalMB + ' MB')
				]),
				pbarTrack,
				infoRow,
				msgBox,
				E('div', { 'class': 'right', 'style': 'margin-top: 15px;' }, [
					btnCancel,
					btnClose
				])
			]);

			ui.showModal(_('上传并部署 ') + title, [ modalBody ]);

			var formData = new FormData();
			formData.append('type', type);
			formData.append('file', file);
			if (L.env && L.env.token) {
				formData.append('token', L.env.token);
			}

			var uploadUrl = L.url('admin/services/xc/upload') + '?type=' + encodeURIComponent(type);
			var xhr = new XMLHttpRequest();
			currentXhr = xhr;
			var startTime = Date.now();

			xhr.upload.onprogress = function(e) {
				if (e.lengthComputable) {
					var percent = Math.min(100, Math.round((e.loaded / e.total) * 100));
					pbar.style.width = percent + '%';
					var loadedMB = (e.loaded / (1024 * 1024)).toFixed(2);
					statsText.innerText = percent + '% (' + loadedMB + ' / ' + totalMB + ' MB)';

					if (percent >= 100) {
						statusText.innerText = _('文件数据已上传完毕，正在服务端写入并校验架构与权限...');
						pbar.style.background = 'linear-gradient(90deg, #10b981, #059669)';
					} else {
						var elapsedSec = (Date.now() - startTime) / 1000;
						if (elapsedSec > 0.4) {
							var speedKB = ((e.loaded / 1024) / elapsedSec).toFixed(0);
							var speedStr = speedKB > 1024 ? (speedKB / 1024).toFixed(1) + ' MB/s' : speedKB + ' KB/s';
							statusText.innerText = _('正在高速上传中') + ' (' + speedStr + ')...';
						} else {
							statusText.innerText = _('正在上传中...');
						}
					}
				}
			};

			xhr.onload = function() {
				currentXhr = null;
				btnCancel.style.display = 'none';
				btnClose.style.display = 'inline-block';

				var res = null;
				var rawText = (xhr.responseText || '').trim();
				try {
					res = JSON.parse(rawText);
				} catch(err) {
					var lastBrace = rawText.lastIndexOf('{');
					if (lastBrace >= 0) {
						try { res = JSON.parse(rawText.substring(lastBrace)); } catch(e2) { res = null; }
					}
				}

				if (xhr.status === 200 && res && res.code === 0) {
					pbar.style.width = '100%';
					pbar.style.background = '#10b981';
					statsText.innerText = '100% - ' + _('部署成功');
					statsText.style.color = '#10b981';
					statusText.innerText = _('文件校验通过并已就绪！');

					msgBox.style.display = 'block';
					msgBox.style.background = '#ecfdf5';
					msgBox.style.border = '1px solid #a7f3d0';
					msgBox.style.color = '#065f46';
					msgBox.innerHTML = '<strong>' + title + _(' 上传并部署成功！') + '</strong><br>' + (res.message || '') + '<br><span style="font-size:12px; color:#047857;">' + _('页面将在 1.5 秒后自动刷新...') + '</span>';

					setTimeout(function() {
						window.location.reload();
					}, 1500);
				} else {
					pbar.style.background = '#ef4444';
					statsText.style.color = '#ef4444';
					statsText.innerText = _('处理失败');
					statusText.innerText = _('校验未通过');

					msgBox.style.display = 'block';
					msgBox.style.background = '#fef2f2';
					msgBox.style.border = '1px solid #fecaca';
					msgBox.style.color = '#991b1b';
					var errMsg = (res && res.message) ? res.message : ('HTTP ' + xhr.status + ': ' + (xhr.statusText || _('服务端未返回有效结果')) + (rawText ? (' (' + rawText.substring(0, 100) + ')') : ''));
					msgBox.innerHTML = '<strong>' + _('上传安装失败：') + '</strong><br>' + errMsg;
				}
			};

			xhr.onerror = function() {
				currentXhr = null;
				btnCancel.style.display = 'none';
				btnClose.style.display = 'inline-block';
				pbar.style.background = '#ef4444';
				statsText.style.color = '#ef4444';
				statsText.innerText = _('网络异常');
				statusText.innerText = _('连接中断');

				msgBox.style.display = 'block';
				msgBox.style.background = '#fef2f2';
				msgBox.style.border = '1px solid #fecaca';
				msgBox.style.color = '#991b1b';
				msgBox.innerHTML = '<strong>' + _('网络连接错误：') + '</strong><br>' + _('无法连接至路由器接口，请检查网络连接或刷新页面重新登录。');
			};

			xhr.ontimeout = function() {
				currentXhr = null;
				btnCancel.style.display = 'none';
				btnClose.style.display = 'inline-block';
				pbar.style.background = '#ef4444';
				statsText.style.color = '#ef4444';
				statsText.innerText = _('请求超时');
				statusText.innerText = _('上传超时');

				msgBox.style.display = 'block';
				msgBox.style.background = '#fef2f2';
				msgBox.style.border = '1px solid #fecaca';
				msgBox.style.color = '#991b1b';
				msgBox.innerHTML = '<strong>' + _('上传请求超时：') + '</strong><br>' + _('文件体积较大或网络较慢导致请求超时，请重试。');
			};

			xhr.open('POST', uploadUrl, true);
			xhr.send(formData);
		});

		input.click();
	},

	handleSwitchSource: function(coreSource, assetSource) {
		var self = this;
		var desc = '';
		if (coreSource) desc += (coreSource === 'builtin' ? _('切换为内置核心') : _('切换为自定义核心'));
		if (assetSource) desc += (desc ? '，' : '') + (assetSource === 'builtin' ? _('切换为内置规则库') : _('切换为自定义规则库'));
		if (!confirm(_('确定要 ') + desc + _(' 吗？系统将自动重载 Xray 进程生效。'))) return;

		callSwitchSource(coreSource, assetSource).then(function(res) {
			if (res && res.code === 0) {
				ui.addNotification(null, E('p', {}, _('核心/规则来源已切换并重新加载服务！')), 'success');
				window.location.reload();
			} else {
				ui.addNotification(null, E('p', {}, _('切换失败：') + (res.message || '')), 'danger');
			}
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('请求异常：') + e), 'danger');
		});
	},

	renderCoreAssetsSection: function(status) {
		var self = this;
		var cs = (status && status.core_status) || { xray_ok: false, geosite_ok: false, geoip_ok: false };

		var xrayModeText = _('● 缺失 (未安装)');
		var xrayBadgeStyle = 'background-color:#ef4444; color:#fff;';
		var xraySwitchBtn = null;

		if (cs.active_core_source === 'custom') {
			xrayModeText = _('● 已选用 (自定义核心)');
			xrayBadgeStyle = 'background-color:#10b981; color:#fff;';
			if (cs.builtin_core_available) {
				xraySwitchBtn = E('button', {
					'class': 'cbi-button',
					'style': 'margin-right: 6px;',
					'click': function() { self.handleSwitchSource('builtin', null); }
				}, _('切为系统内置'));
			}
		} else if (cs.active_core_source === 'builtin') {
			xrayModeText = _('● 已选用 (系统内置)');
			xrayBadgeStyle = 'background-color:#2563eb; color:#fff;';
			if (cs.custom_core_available) {
				xraySwitchBtn = E('button', {
					'class': 'cbi-button cbi-button-apply',
					'style': 'margin-right: 6px; font-weight:bold;',
					'click': function() { self.handleSwitchSource('custom', null); }
				}, _('切换为自定义核心'));
			} else {
				xraySwitchBtn = E('button', {
					'class': 'cbi-button',
					'style': 'margin-right: 6px;',
					'disabled': true,
					'title': _('请先上传自定义核心后即可一键切换')
				}, _('未上传自定义'));
			}
		} else if (cs.active_core_source === 'builtin_fallback') {
			xrayModeText = _('○ 系统保底生效中 (未上传自定义)');
			xrayBadgeStyle = 'background-color:#f59e0b; color:#fff;';
			xraySwitchBtn = E('button', {
				'class': 'cbi-button',
				'style': 'margin-right: 6px;',
				'title': _('锁定为系统内置，不再提示保底'),
				'click': function() { self.handleSwitchSource('builtin', null); }
			}, _('切为系统内置'));
		}

		var assetModeText = _('● 缺失 (未安装)');
		var assetBadgeStyle = 'background-color:#ef4444; color:#fff;';
		var assetSwitchBtn = null;

		if (cs.active_asset_source === 'custom') {
			assetModeText = _('● 已选用 (自定义规则)');
			assetBadgeStyle = 'background-color:#10b981; color:#fff;';
			if (cs.builtin_asset_available) {
				assetSwitchBtn = function() {
					return E('button', {
						'class': 'cbi-button',
						'style': 'margin-right: 6px;',
						'click': function() { self.handleSwitchSource(null, 'builtin'); }
					}, _('切为系统内置'));
				};
			}
		} else if (cs.active_asset_source === 'builtin') {
			assetModeText = _('● 已选用 (系统内置)');
			assetBadgeStyle = 'background-color:#2563eb; color:#fff;';
			if (cs.custom_asset_available) {
				assetSwitchBtn = function() {
					return E('button', {
						'class': 'cbi-button cbi-button-apply',
						'style': 'margin-right: 6px; font-weight:bold;',
						'click': function() { self.handleSwitchSource(null, 'custom'); }
					}, _('切换为自定义规则'));
				};
			} else {
				assetSwitchBtn = function() {
					return E('button', {
						'class': 'cbi-button',
						'style': 'margin-right: 6px;',
						'disabled': true,
						'title': _('请先上传自定义规则库后即可一键切换')
					}, _('未上传自定义'));
				};
			}
		} else if (cs.active_asset_source === 'builtin_fallback') {
			assetModeText = _('○ 系统保底生效中 (未上传自定义)');
			assetBadgeStyle = 'background-color:#f59e0b; color:#fff;';
			assetSwitchBtn = function() {
				return E('button', {
					'class': 'cbi-button',
					'style': 'margin-right: 6px;',
					'title': _('锁定为系统内置，不再提示保底'),
					'click': function() { self.handleSwitchSource(null, 'builtin'); }
				}, _('切为系统内置'));
			};
		}

		var items = [
			{
				key: 'xray',
				title: _('Xray 核心程序 (xray)'),
				desc: _('支持 Linux ELF 程序或 .zip / .tar.gz 压缩包上传（自动解压并校验），内置核心自动保底'),
				ok: cs.xray_ok,
				path: cs.xray_path || _('未找到 (/etc/xc/bin/xray, /usr/bin/xray)'),
				badgeText: xrayModeText,
				badgeStyle: xrayBadgeStyle,
				switchBtn: xraySwitchBtn,
				btnText: _('上传 Xray 核心')
			},
			{
				key: 'geosite',
				title: _('GeoSite 域名规则库 (geosite.dat)'),
				desc: _('负责特定服务代理分流与直连，支持手动切换自定义/内置规则库'),
				ok: cs.geosite_ok,
				path: cs.geosite_path || _('未找到 (/etc/xc/assets/geosite.dat, /usr/share/xray/geosite.dat)'),
				badgeText: assetModeText,
				badgeStyle: assetBadgeStyle,
				switchBtn: assetSwitchBtn ? assetSwitchBtn() : null,
				btnText: _('上传 geosite.dat')
			},
			{
				key: 'geoip',
				title: _('GeoIP IP规则库 (geoip.dat)'),
				desc: _('负责中国大陆 IP 直连与私网绕行，支持手动切换自定义/内置规则库'),
				ok: cs.geoip_ok,
				path: cs.geoip_path || _('未找到 (/etc/xc/assets/geoip.dat, /usr/share/xray/geoip.dat)'),
				badgeText: assetModeText,
				badgeStyle: assetBadgeStyle,
				switchBtn: assetSwitchBtn ? assetSwitchBtn() : null,
				btnText: _('上传 geoip.dat')
			}
		];

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th', 'style': 'width:140px; text-align:center;' }, _('状态 / 模式')),
				E('th', { 'class': 'th', 'style': 'width:240px;' }, _('组件名称')),
				E('th', { 'class': 'th' }, _('当前生效路径 / 说明')),
				E('th', { 'class': 'th cbi-section-actions', 'style': 'width:260px; text-align:right;' }, _('操作'))
			])
		]);

		items.forEach(function(item) {
			var badge = E('span', {
				'class': 'badge',
				'style': item.badgeStyle + ' padding:3px 8px; border-radius:4px; font-weight:bold;'
			}, item.badgeText);

			var actionElements = [];
			if (item.switchBtn) {
				actionElements.push(item.switchBtn);
			}
			actionElements.push(E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function() {
					self.triggerUpload(item.key, item.title);
				}
			}, item.btnText));

			var tr = E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'text-align:center;' }, badge),
				E('td', { 'class': 'td' }, [
					E('strong', {}, item.title)
				]),
				E('td', { 'class': 'td' }, [
					E('div', { 'style': 'font-family:monospace; font-size:12px; color:' + (item.ok ? '#2563eb' : '#dc2626') }, item.path),
					E('div', { 'style': 'font-size:11px; color:#888; margin-top:2px;' }, item.desc)
				]),
				E('td', { 'class': 'td cbi-section-actions', 'style': 'text-align:right;' }, actionElements)
			]);
			table.appendChild(tr);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('核心组件与规则文件管理 (/etc/xc/bin, /etc/xc/assets)')),
			E('div', { 'class': 'cbi-section-descr' }, _('支持网页直接上传 Xray 核心（支持 Linux ELF 或 .zip / .tar.gz 自动解压）及 routing 规则库。系统内置核心与规则作为安全保底，可自由手动切换来源。')),
			E('div', { 'class': 'cbi-section-node' }, [ table ])
		]);
	},

	renderStatusHeader: function(status, nodesData) {
		var isRunning = status && status.running;
		var curId = status ? status.current_id : null;
		var fixedId = nodesData ? nodesData.fixed_proxy_id : 1;

		var nodes = (nodesData && nodesData.nodes) ? nodesData.nodes : [];
		var curNode = nodes.find(function(n) { return Number(n.id) === Number(curId); });
		var fixedNode = nodes.find(function(n) { return Number(n.id) === Number(fixedId); });

		// 单节点或固定分流节点未匹配时，自动联动对齐当前活动节点
		if ((!fixedNode || nodes.length <= 1) && curNode) {
			fixedNode = curNode;
		}

		var curText = nodes.length === 0 ? _('未选择 (节点列表为空)') : (curNode ? ('#' + curNode.id + ' ' + curNode.name + ' (' + curNode.type + ')') : _('未选择'));
		var fixedText = nodes.length === 0 ? _('未配置') : (fixedNode ? ('#' + fixedNode.id + ' ' + fixedNode.name + ' (' + fixedNode.type + ')') : ('ID: ' + fixedId));

		var sPort = (status && status.socks_port) || 7890;
		var hPort = (status && status.http_port) || 10809;
		var sHost = (status && status.socks_host) || '127.0.0.1';
		var hHost = (status && status.http_host) || '127.0.0.1';

		var socksStatus = (status && status.socks_listening) ? _('正常监听') : _('未监听');
		var httpStatus = (status && status.http_listening) ? _('正常监听') : _('未监听');

		var cs = status && status.core_status;
		var coreStatusText = (cs && cs.ready)
			? _('就绪 (xray: ') + (cs.xray_path || '') + ')'
			: _('异常：有必要组件缺失');
		var coreBadge = (cs && cs.ready)
			? E('span', { 'class': 'badge', 'style': 'background-color:#10b981; color:#fff; padding:2px 6px; border-radius:3px; font-weight:normal; margin-left:8px;' }, _('组件正常'))
			: E('span', { 'class': 'badge', 'style': 'background-color:#ef4444; color:#fff; padding:2px 6px; border-radius:3px; font-weight:normal; margin-left:8px;' }, _('文件丢失'));

		var self = this;

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-node' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('服务运行状态')),
					E('div', { 'class': 'cbi-value-field' }, [
						isRunning 
							? E('span', { 'class': 'badge', 'style': 'background-color:#10b981; color:#fff; padding:4px 8px; border-radius:4px; font-weight:bold;' }, _('● Xray 运行中 (PID: ') + (status.pid || 'running') + ')')
							: E('span', { 'class': 'badge', 'style': 'background-color:#ef4444; color:#fff; padding:4px 8px; border-radius:4px; font-weight:bold;' }, _('● 服务未运行')),
						isRunning ? E('button', {
							'class': 'cbi-button',
							'style': 'margin-left: 10px;',
							'click': function() {
								ui.showModal(_('正在重启服务'), [ E('p', {}, _('正在平滑重载 Xray 核心服务并执行连通性校验...')) ]);
								callRestartService().then(function(res) {
									ui.hideModal();
									if (res && res.code === 0) {
										ui.addNotification(null, E('p', {}, _('服务重启成功！')), 'success');
									} else {
										ui.addNotification(null, E('p', {}, _('服务重启失败: ') + (res.message || '')), 'danger');
									}
									window.location.reload();
								});
							}
						}, _('⟳ 重启服务')) : E('button', {
							'class': 'cbi-button cbi-button-save',
							'style': 'margin-left: 10px; font-weight:bold;',
							'click': function() {
								ui.showModal(_('正在启动服务'), [ E('p', {}, _('正在启动 Xray 核心服务并执行连通性校验...')) ]);
								callRestartService().then(function(res) {
									ui.hideModal();
									if (res && res.code === 0) {
										ui.addNotification(null, E('p', {}, _('服务启动成功！')), 'success');
									} else {
										ui.addNotification(null, E('p', {}, _('服务启动失败: ') + (res.message || '')), 'danger');
									}
									window.location.reload();
								});
							}
						}, _('▶ 启动服务')),
						isRunning ? E('button', {
							'class': 'cbi-button cbi-button-reset',
							'style': 'margin-left: 5px;',
							'click': function() {
								if (!confirm(_('确定停止服务吗？停止后代理端口将暂停监听。'))) return;
								callStopService().then(function() { window.location.reload(); });
							}
						}, _('⏹ 停止')) : '',
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'style': 'margin-left: 5px;',
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
						}, _('测试双端口连通性'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('核心与规则组件')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('span', {}, coreStatusText),
						coreBadge
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
					// 1. Switch Node or Start Service
					(isCur && isRunning) ? E('button', { 'class': 'cbi-button', 'disabled': true }, _('使用中')) :
					E('button', {
						'class': (isCur && !isRunning) ? 'cbi-button cbi-button-save' : 'cbi-button cbi-button-apply',
						'style': (isCur && !isRunning) ? 'font-weight:bold;' : '',
						'click': function(ev) {
							ev.target.disabled = true;
							var actionDesc = (isCur && !isRunning) ? _('正在启动当前节点') : (_('正在切换到节点 #') + node.id + ' [' + node.name + ']...');
							ui.showModal((isCur && !isRunning) ? _('启动服务') : _('正在切换节点'), [
								E('p', {}, actionDesc),
								E('p', {}, _('正在执行 Xray 配置校验、平滑切换及全链路健康测试，请稍候...'))
							]);
							callSwitchNode(node.id).then(function(res) {
								ui.hideModal();
								if (res && res.code === 0) {
									ui.addNotification(null, E('p', {}, _('操作成功，节点已就绪！')), 'success');
									window.location.reload();
								} else {
									ui.addNotification(null, E('p', {}, _('操作失败，已自动回滚: ') + (res.message || '')), 'danger');
									ev.target.disabled = false;
								}
							});
						}
					}, (isCur && !isRunning) ? _('▶ 启动服务') : _('切换')),

					// 2. Single Probe
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'style': 'margin-left:4px;',
						'click': function(ev) {
							var cell = document.getElementById(latencyId);
							if (cell) cell.innerHTML = '<span style="color:#2563eb;">' + _('测速中...') + '</span>';
							var timeout = Number((settingsData && settingsData.probe_timeout) || 5);
							callProbeNode(node.id, timeout).then(function(res) {
								if (!cell) return;
								if (res && res.latency > 0) {
									var color = res.latency < 200 ? '#10b981' : (res.latency < 500 ? '#f59e0b' : '#ef4444');
									cell.innerHTML = '<span style="color:' + color + '; font-weight:bold; font-family:monospace;">' + res.latency + ' ms</span>';
								} else {
									cell.innerHTML = '<span style="color:#ef4444; font-size:11px;">' + _('超时 / 失败') + '</span>';
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

		var probeStatusSpan = E('span', { 'style': 'margin-left:10px; font-size:12px; color:#2563eb; font-weight:bold;' }, '');
		var probeBtn;
		var isProbing = false;

		var stopProbing = function() {
			self._probeAborted = true;
			isProbing = false;
			if (probeBtn) {
				probeBtn.disabled = false;
				probeBtn.className = 'cbi-button cbi-button-action';
				probeBtn.style.cssText = 'margin-left:8px; background-color:#10b981; color:#fff;';
				probeBtn.innerText = _('⚡ 全部测速');
			}
			probeStatusSpan.innerText = _('已停止测速');
			setTimeout(function() {
				if (!isProbing && probeStatusSpan.innerText === _('已停止测速')) {
					probeStatusSpan.innerText = '';
				}
			}, 3000);
		};

		probeBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:8px; background-color:#10b981; color:#fff;',
			'click': function(ev) {
				if (isProbing) {
					stopProbing();
					return;
				}
				if (!nodes || nodes.length === 0) {
					ui.addNotification(null, E('p', {}, _('当前无可用节点进行测速')), 'warning');
					return;
				}

				isProbing = true;
				self._probeAborted = false;
				probeBtn.className = 'cbi-button cbi-button-reset';
				probeBtn.style.cssText = 'margin-left:8px; background-color:#ef4444; color:#fff; border-color:#dc2626;';
				probeBtn.innerText = '■ ' + _('停止测速');

				var concurrency = Number((settingsData && settingsData.probe_concurrency) || 3);
				if (isNaN(concurrency) || concurrency < 1) concurrency = 3;
				var timeout = Number((settingsData && settingsData.probe_timeout) || 5);
				if (isNaN(timeout) || timeout < 1) timeout = 5;

				var total = nodes.length;
				var completed = 0;
				var currentIndex = 0;

				probeStatusSpan.innerText = _('测速中 (0/') + total + ')...';

				nodes.forEach(function(n) {
					var cell = document.getElementById('latency-cell-' + n.id);
					if (cell) cell.innerHTML = '<span style="color:#9ca3af;">' + _('等待中...') + '</span>';
				});

				var runWorker = function() {
					if (self._probeAborted || currentIndex >= total) {
						return Promise.resolve();
					}
					var n = nodes[currentIndex++];
					var cell = document.getElementById('latency-cell-' + n.id);
					if (cell) cell.innerHTML = '<span style="color:#2563eb;">' + _('测速中...') + '</span>';

					return callProbeNode(n.id, timeout).then(function(res) {
						completed++;
						if (!self._probeAborted) {
							probeStatusSpan.innerText = _('测速中 (') + completed + '/' + total + ')...';
						}
						if (cell) {
							if (res && res.latency > 0) {
								var color = res.latency < 200 ? '#10b981' : (res.latency < 500 ? '#f59e0b' : '#ef4444');
								cell.innerHTML = '<span style="color:' + color + '; font-weight:bold; font-family:monospace;">' + res.latency + ' ms</span>';
							} else {
								cell.innerHTML = '<span style="color:#ef4444; font-size:11px;">' + _('超时 / 失败') + '</span>';
							}
						}
						if (!self._probeAborted && currentIndex < total) {
							return runWorker();
						}
					}).catch(function() {
						completed++;
						if (cell) cell.innerHTML = '<span style="color:#ef4444; font-size:11px;">' + _('错误') + '</span>';
						if (!self._probeAborted && currentIndex < total) {
							return runWorker();
						}
					});
				};

				var workers = [];
				for (var w = 0; w < concurrency && w < total; w++) {
					workers.push(runWorker());
				}

				Promise.all(workers).then(function() {
					if (!self._probeAborted) {
						isProbing = false;
						probeBtn.className = 'cbi-button cbi-button-action';
						probeBtn.style.cssText = 'margin-left:8px; background-color:#10b981; color:#fff;';
						probeBtn.innerText = _('⚡ 全部测速');
						probeStatusSpan.innerText = _('测速完成 (') + completed + '/' + total + ')';
						ui.addNotification(null, E('p', {}, _('全部节点测速已完成！')), 'success');
					}
				});
			}
		}, _('⚡ 全部测速'));

		var toolbar = E('div', { 'class': 'cbi-section-actions', 'style': 'margin-bottom:12px; display:flex; justify-content:space-between; align-items:center;' }, [
			E('div', { 'style': 'display:flex; align-items:center; flex-wrap:wrap;' }, [
				// Add Node Button
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'click': function() {
						self.showNodeModal('add', null, nodesData);
					}
				}, '+ ' + _('添加节点信息')),

				// Concurrency Queue Speed Test
				probeBtn,
				probeStatusSpan
			]),
			E('div', { 'style': 'font-size:12px; color:#666;' }, [
				E('span', { 'style': 'margin-right:12px;' }, '● ' + _('当前活动节点')),
				E('span', { 'style': 'color:#10b981; font-weight:bold; margin-right:8px;' }, '<200ms ' + _('极优')),
				E('span', { 'style': 'color:#f59e0b; font-weight:bold; margin-right:8px;' }, '200~500ms ' + _('良好')),
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
		var probeTimeout = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:100px;', 'value': (settingsData && settingsData.probe_timeout) || 5 });
		var probeConcurrency = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:100px;', 'value': (settingsData && settingsData.probe_concurrency) || 3 });

		var fixedSelect = E('select', { 'class': 'cbi-input-select' });
		var nodes = (nodesData && nodesData.nodes) ? nodesData.nodes : [];
		var curFixed = nodesData ? nodesData.fixed_proxy_id : null;
		if ((!curFixed || nodes.length <= 1) && nodes.length > 0) {
			curFixed = nodes[0].id;
		}
		if (nodes.length === 0) {
			fixedSelect.appendChild(E('option', { 'value': '' }, _('暂无可用节点')));
		} else {
			nodes.forEach(function(n) {
				fixedSelect.appendChild(E('option', { 'value': n.id, 'selected': Number(n.id) === Number(curFixed) }, '#' + n.id + ' - ' + n.name + ' (' + n.type + ')'));
			});
		}

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('全局基础设置 (/etc/xc/settings.json)')),
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
					E('div', { 'class': 'cbi-value-field' }, [
						probeUrl,
						E('div', { 'style': 'margin-top:6px; display:flex; gap:8px; align-items:center;' }, [
							E('span', { 'style': 'font-size:12px; color:#666;' }, _('常用预设: ')),
							E('button', {
								'class': 'cbi-button cbi-button-neutral',
								'style': 'padding:2px 8px; font-size:11px;',
								'click': function(ev) {
									ev.preventDefault();
									probeUrl.value = 'http://www.gstatic.com/generate_204';
								}
							}, 'Google 204'),
							E('button', {
								'class': 'cbi-button cbi-button-neutral',
								'style': 'padding:2px 8px; font-size:11px;',
								'click': function(ev) {
									ev.preventDefault();
									probeUrl.value = 'http://cp.cloudflare.com/generate_204';
								}
							}, 'Cloudflare 204')
						]),
						E('div', { 'class': 'cbi-value-description' }, _('节点 RTT 延迟测试目标地址，需返回 HTTP 204 或 200 状态码。'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('测速参数控制')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('div', { 'style': 'display:flex; gap:16px; align-items:center; flex-wrap:wrap;' }, [
							E('div', {}, [
								E('span', { 'style': 'font-size:12px; color:#666;' }, _('超时时间(秒): ')),
								probeTimeout
							]),
							E('div', {}, [
								E('span', { 'style': 'font-size:12px; color:#666;' }, _('并发通道数: ')),
								probeConcurrency
							])
						]),
						E('div', { 'class': 'cbi-value-description' }, _('超时建议 3~5 秒，避免失效节点过久等待；并发建议 2~4，控制路由器瞬时 CPU 与内存压力。'))
					])
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
									health_url: healthUrl.value.trim(),
									probe_timeout: Number(probeTimeout.value.trim()) || 5,
									probe_concurrency: Number(probeConcurrency.value.trim()) || 3
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

		var activeTab = 'nodes';
		try {
			activeTab = window.sessionStorage.getItem('xc_active_tab') || 'nodes';
		} catch(e) {}

		var nodePane = this.renderNodeTable(status, nodesData, settingsData);
		var settingsPane = this.renderSettingsSection(nodesData, settingsData);
		var corePane = this.renderCoreAssetsSection(status);

		var tabs = [
			{ id: 'nodes', name: '📋 ' + _('节点管理与测速'), pane: nodePane },
			{ id: 'settings', name: '⚙️ ' + _('全局基础设置'), pane: settingsPane },
			{ id: 'core', name: '📦 ' + _('核心组件与规则'), pane: corePane }
		];

		var tabUl = E('ul', { 'class': 'cbi-tabmenu', 'style': 'margin-top:16px; margin-bottom:18px;' });

		var switchTab = function(tabId) {
			activeTab = tabId;
			try {
				window.sessionStorage.setItem('xc_active_tab', tabId);
			} catch(e) {}

			tabs.forEach(function(t) {
				var isCur = (t.id === tabId);
				t.pane.style.display = isCur ? 'block' : 'none';
				if (t.li) {
					t.li.className = isCur ? 'cbi-tab' : 'cbi-tab-disabled';
				}
			});
		};

		tabs.forEach(function(t) {
			var a = E('a', {
				'href': '#',
				'click': function(ev) {
					ev.preventDefault();
					switchTab(t.id);
				}
			}, t.name);
			t.li = E('li', { 'class': (t.id === activeTab) ? 'cbi-tab' : 'cbi-tab-disabled' }, [ a ]);
			tabUl.appendChild(t.li);
			t.pane.style.display = (t.id === activeTab) ? 'block' : 'none';
		});

		var m = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('xc 节点切换与分流管理器')),
			E('div', { 'class': 'cbi-map-descr' }, _('轻量级 Xray 节点切换与分流管理插件，支持 VLESS REALITY 与本地 NaiveProxy SOCKS 节点，提供全链路延迟测速、平滑切换与失败回滚。')),
			this.renderMissingAlert(status),
			this.renderStatusHeader(status, nodesData),
			tabUl,
			nodePane,
			settingsPane,
			corePane
		]);

		return m;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
