'use strict';

const fs = require('fs');
const vm = require('vm');

function createDOMNode(tag, attrs, children) {
	const node = {
		tagName: (tag || 'div').toUpperCase(),
		attributes: {},
		style: {},
		childNodes: [],
		parentNode: null,
		value: '',
		disabled: false,
		checked: false,
		listeners: {},
		className: '',

		get textContent() {
			let txt = '';
			for (const c of this.childNodes) {
				if (c && c.textContent) txt += c.textContent;
			}
			return txt;
		},
		set textContent(v) {
			this.childNodes = [{
				tagName: '#text',
				textContent: String(v),
				childNodes: [],
				parentNode: this
			}];
		},
		get innerText() {
			return this.textContent;
		},
		set innerText(v) {
			this.textContent = v;
		},
		get innerHTML() {
			return this.textContent;
		},
		set innerHTML(html) {
			this.textContent = String(html).replace(/<[^>]+>/g, '');
		},

		setAttribute(k, v) {
			this.attributes[k] = String(v);
			if (k === 'class') this.className = String(v);
			if (k === 'value') this.value = String(v);
			if (k === 'disabled') this.disabled = Boolean(v);
			if (k === 'checked') this.checked = Boolean(v);
			if (k === 'selected') this.selected = true;
		},
		getAttribute(k) {
			if (this.attributes[k] !== undefined) return this.attributes[k];
			if (this[k] !== undefined && typeof this[k] !== 'function') return String(this[k]);
			return null;
		},
		removeAttribute(k) {
			delete this.attributes[k];
		},
		appendChild(child) {
			if (child === null || child === undefined) return;
			if (typeof child !== 'object') {
				child = {
					tagName: '#text',
					textContent: String(child),
					attributes: {},
					style: {},
					childNodes: [],
					parentNode: this
				};
			} else {
				child.parentNode = this;
			}
			this.childNodes.push(child);
			if (this.tagName === 'SELECT' && child && child.tagName === 'OPTION') {
				if (child.selected || (!this.value && this.childNodes.length === 1)) {
					this.value = child.value;
				}
			}
			return child;
		},
		removeChild(child) {
			const idx = this.childNodes.indexOf(child);
			if (idx >= 0) {
				this.childNodes.splice(idx, 1);
				child.parentNode = null;
			}
		},
		addEventListener(event, fn) {
			if (!this.listeners[event]) this.listeners[event] = [];
			this.listeners[event].push(fn);
		},
		dispatchEvent(event) {
			const type = typeof event === 'string' ? event : (event.type || 'click');
			const fns = this.listeners[type] || [];
			const evObj = typeof event === 'object' ? event : { type, target: this, preventDefault() {}, stopPropagation() {} };
			for (const fn of fns) {
				fn.call(this, evObj);
			}
		},
		click() {
			this.dispatchEvent({ type: 'click', target: this, preventDefault() {}, stopPropagation() {} });
		},
		querySelector(selector) {
			const res = this.querySelectorAll(selector);
			return res.length > 0 ? res[0] : null;
		},
		querySelectorAll(selector) {
			const matched = [];
			function search(curr) {
				if (!curr || !curr.childNodes) return;
				if (matchesSelector(curr, selector)) {
					matched.push(curr);
				}
				for (const c of curr.childNodes) {
					if (typeof c === 'object') search(c);
				}
			}
			for (const c of this.childNodes) {
				if (typeof c === 'object') search(c);
			}
			return matched;
		}
	};

	if (attrs && typeof attrs === 'object') {
		for (const k of Object.keys(attrs)) {
			const v = attrs[k];
			if (v == null) continue;
			if (k.startsWith('on') && typeof v === 'function') {
				node.addEventListener(k.substring(2).toLowerCase(), v);
			} else if (k === 'click' && typeof v === 'function') {
				node.addEventListener('click', v);
			} else if (k === 'change' && typeof v === 'function') {
				node.addEventListener('change', v);
			} else if (k === 'style' && typeof v === 'string') {
				node.setAttribute('style', v);
				v.split(';').forEach(rule => {
					const [sk, sv] = rule.split(':').map(s => s && s.trim());
					if (sk && sv) node.style[sk] = sv;
				});
			} else {
				node.setAttribute(k, v);
			}
		}
	}

	if (children) {
		const arr = Array.isArray(children) ? children : [children];
		for (const ch of arr) {
			if (ch !== null && ch !== undefined) {
				node.appendChild(typeof ch === 'object' ? ch : String(ch));
			}
		}
	}

	return node;
}

function matchesSelector(node, selector) {
	if (!node || typeof node.getAttribute !== 'function' || !selector || typeof selector !== 'string') return false;
	if (selector.startsWith('#')) {
		return (node.getAttribute('id') === selector.substring(1)) || (node.id === selector.substring(1));
	}
	if (selector.startsWith('.')) {
		const cls = selector.substring(1);
		return (node.className || '').split(/\s+/).includes(cls);
	}
	const attrMatch = selector.match(/^([a-zA-Z0-9_-]*)\[([a-zA-Z0-9_-]+)(?:=([^\],]+))?\]$/);
	if (attrMatch) {
		const tag = attrMatch[1];
		const attr = attrMatch[2];
		const val = attrMatch[3] ? attrMatch[3].replace(/^['"]|['"]$/g, '') : null;
		if (tag && node.tagName.toLowerCase() !== tag.toLowerCase()) return false;
		const actual = node.getAttribute(attr);
		if (val !== null) return actual === val;
		return actual !== null;
	}
	if (selector.includes('.')) {
		const parts = selector.split('.');
		const tag = parts[0];
		const cls = parts.slice(1);
		if (tag && node.tagName.toLowerCase() !== tag.toLowerCase()) return false;
		const nodeClasses = (node.className || '').split(/\s+/);
		return cls.every(c => nodeClasses.includes(c));
	}
	return node.tagName.toLowerCase() === selector.toLowerCase();
}

function loadOverviewView(mockRPCs = {}) {
	const overviewPath = 'htdocs/luci-static/resources/view/xc/overview.js';
	let code = fs.readFileSync(overviewPath, 'utf8');

	// Strip LuCI module require lines
	code = code.replace(/'require\s+[^']+';/g, '');

	const notifications = [];
	const modals = [];
	const pollJobs = [];
	const sessionStorageData = {};

	const mockUi = {
		addNotification(title, message, type) {
			notifications.push({ title, message, type });
		},
		showModal(title, children) {
			modals.push({ title, children, body: children });
		},
		hideModal() {
			modals.pop();
		}
	};

	const mockPoll = {
		add(fn, interval) {
			pollJobs.push({ fn, interval });
		},
		start() {},
		stop() {}
	};

	let rpcIndex = 0;
	const rpcCalls = [];
	const mockRpc = {
		declare(spec) {
			const method = spec.method;
			return function(...args) {
				rpcCalls.push({ method, args });
				if (mockRPCs[method]) {
					return Promise.resolve(mockRPCs[method](...args));
				}
				return Promise.resolve(spec.expect || {});
			};
		}
	};

	const mockView = {
		extend(obj) {
			return Object.assign({}, obj);
		}
	};

	const mockSessionStorage = {
		getItem(k) { return sessionStorageData[k] || null; },
		setItem(k, v) { sessionStorageData[k] = String(v); },
		removeItem(k) { delete sessionStorageData[k]; }
	};

	const rootDoc = createDOMNode('body', {}, []);
	const mockDocument = {
		body: rootDoc,
		getElementById(id) {
			return rootDoc.querySelector('#' + id);
		},
		querySelector(sel) {
			return rootDoc.querySelector(sel);
		},
		querySelectorAll(sel) {
			return rootDoc.querySelectorAll(sel);
		},
		createElement(tag) {
			return createDOMNode(tag, {}, []);
		}
	};

	const mockWindow = {
		sessionStorage: mockSessionStorage,
		document: mockDocument,
		location: { reload() {} },
		setTimeout: global.setTimeout,
		clearTimeout: global.clearTimeout
	};

	class MockFormData {
		constructor() {
			this.entries = {};
		}
		append(k, v) {
			this.entries[k] = v;
		}
	}

	let lastXhr = null;
	class MockXMLHttpRequest {
		constructor() {
			this.upload = {};
			this.headers = {};
			this.readyState = 0;
			this.status = 0;
			this.responseText = '';
			this.aborted = false;
			lastXhr = this;
		}
		open(method, url, async) {
			this.method = method;
			this.url = url;
			this.async = async;
		}
		setRequestHeader(k, v) {
			this.headers[k] = v;
		}
		send(data) {
			this.sentData = data;
		}
		abort() {
			this.aborted = true;
			if (this.onabort) this.onabort();
		}
	}

	const mockL = {
		env: { token: 'mock-token-abc' },
		url: (p) => '/cgi-bin/luci/' + p
	};

	const sandbox = {
		view: mockView,
		ui: mockUi,
		rpc: mockRpc,
		poll: mockPoll,
		E: createDOMNode,
		_: (s) => s,
		L: mockL,
		FormData: MockFormData,
		XMLHttpRequest: MockXMLHttpRequest,
		window: mockWindow,
		document: mockDocument,
		sessionStorage: mockSessionStorage,
		confirm: () => true,
		alert: () => {},
		console: console,
		Promise: Promise,
		Array: Array,
		Object: Object,
		String: String,
		Number: Number,
		Boolean: Boolean,
		parseInt: parseInt,
		parseFloat: parseFloat,
		Math: Math,
		Date: Date,
		encodeURIComponent: encodeURIComponent,
		decodeURIComponent: decodeURIComponent
	};

	const script = new vm.Script('(function() {\n' + code + '\n})()');
	const exportedView = script.runInNewContext(sandbox);

	return {
		viewInstance: exportedView,
		notifications,
		modals,
		pollJobs,
		rpcCalls,
		sessionStorage: sessionStorageData,
		document: mockDocument,
		createDOMNode,
		getLastXhr: () => lastXhr
	};
}

module.exports = {
	createDOMNode,
	loadOverviewView
};
