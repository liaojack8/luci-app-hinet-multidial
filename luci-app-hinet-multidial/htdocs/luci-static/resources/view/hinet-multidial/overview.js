'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require ui';
'require uci';
'require dom';

var callStatus = rpc.declare({ object: 'luci.hinet-multidial', method: 'status' });
var callDial   = rpc.declare({ object: 'luci.hinet-multidial', method: 'dial',   params: [ 'iface' ] });
var callStop   = rpc.declare({ object: 'luci.hinet-multidial', method: 'stop',   params: [ 'iface' ] });
var callRedial = rpc.declare({ object: 'luci.hinet-multidial', method: 'redial', params: [ 'iface' ] });
var callApply  = rpc.declare({ object: 'luci.hinet-multidial', method: 'apply' });
var callWgStatus  = rpc.declare({ object: 'luci.hinet-multidial', method: 'wg_status' });
var callWgConfig  = rpc.declare({ object: 'luci.hinet-multidial', method: 'wg_config',  params: [ 'index' ] });
var callWgSetPsk  = rpc.declare({ object: 'luci.hinet-multidial', method: 'wg_set_psk', params: [ 'index', 'psk' ] });
var callWgGenkeys = rpc.declare({ object: 'luci.hinet-multidial', method: 'wg_genkeys', params: [ 'index' ] });

function fmtUptime(s) {
	s = parseInt(s || 0, 10);
	if (!s || s < 0) return '-';
	var d = Math.floor(s / 86400); s %= 86400;
	var h = Math.floor(s / 3600);  s %= 3600;
	var m = Math.floor(s / 60);    s %= 60;
	return (d ? d + 'd ' : '') +
	       ('0' + h).slice(-2) + ':' + ('0' + m).slice(-2) + ':' + ('0' + s).slice(-2);
}

function busy(promise, msg) {
	ui.showModal(_('Please wait'), [ E('p', { 'class': 'spinning' }, msg) ]);
	return promise.then(function(r) { ui.hideModal(); return r; })
	              .catch(function(e) { ui.hideModal(); ui.addNotification(null, E('p', {}, _('Failed: ') + e)); });
}

function renderStatus(res, refresh) {
	var sessions = (res && res.sessions) || [];
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Session')),
		E('th', { 'class': 'th' }, _('State')),
		E('th', { 'class': 'th' }, _('Public IP')),
		E('th', { 'class': 'th' }, _('Uptime')),
		E('th', { 'class': 'th cbi-section-actions' }, _('Control'))
	]) ];

	if (!sessions.length) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 5 },
				E('em', {}, _('No sessions yet. Set the account and number of sessions above, then Save & Apply.')))
		]));
	}

	sessions.forEach(function(sn) {
		var up = !!sn.up, ifc = sn.iface;
		function act(fn, msg) {
			return ui.createHandlerFn(this, function() {
				return busy(fn(ifc), msg).then(refresh);
			});
		}
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'data-title': _('Session') }, ifc),
			E('td', { 'class': 'td', 'data-title': _('State') },
				E('span', { 'style': 'color:' + (up ? '#4caf50' : '#888') + ';font-weight:bold' },
					up ? _('UP') : _('down'))),
			E('td', { 'class': 'td', 'data-title': _('Public IP') }, sn.address || '-'),
			E('td', { 'class': 'td', 'data-title': _('Uptime') }, up ? fmtUptime(sn.uptime) : '-'),
			E('td', { 'class': 'td cbi-section-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply',
					'click': act(callDial,   _('Dialing %s…').format(ifc)) }, _('Dial')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-reload',
					'click': act(callRedial, _('Redialing %s…').format(ifc)) }, _('Redial')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-remove',
					'click': act(callStop,   _('Stopping %s…').format(ifc)) }, _('Stop'))
			])
		]));
	});

	return E('table', { 'class': 'table cbi-section-table' }, rows);
}

function fmtHandshake(up, hs) {
	if (!up) return _('down');
	hs = parseInt(hs || 0, 10);
	if (!hs) return _('listening');
	var ago = Math.max(0, Math.floor(Date.now() / 1000) - hs);
	return _('handshake %ss ago').format(ago);
}

function downloadText(name, text) {
	var blob = new Blob([ text ], { type: 'text/plain' });
	var url = URL.createObjectURL(blob);
	var a = E('a', { href: url, download: name, style: 'display:none' });
	document.body.appendChild(a);
	a.click();
	window.setTimeout(function() { URL.revokeObjectURL(url); a.remove(); }, 1000);
}

function renderWgStatus(res, wgRefresh) {
	var tuns = (res && res.tunnels) || [];
	var ep = (res && res.endpoint) || '';
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Tunnel')),
		E('th', { 'class': 'th' }, _('Session')),
		E('th', { 'class': 'th' }, _('Client endpoint')),
		E('th', { 'class': 'th' }, _('State')),
		E('th', { 'class': 'th cbi-section-actions' }, _('Client'))
	]) ];

	if (!tuns.length) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 5 },
				E('em', {}, _('Enable WireGuard above and Save & Apply — one tunnel appears per active session.')))
		]));
	}

	tuns.forEach(function(t) {
		var idx = t.index, up = !!t.up, hasKey = !!t.pubkey;
		function fetchThen(fn) {
			return callWgConfig(idx).then(function(r) {
				if (!r || !r.ok) { ui.addNotification(null, E('p', {}, (r && r.error) || _('no config'))); return; }
				fn(r);
			});
		}
		var dl = ui.createHandlerFn(this, function() {
			return fetchThen(function(r) { downloadText('wg' + idx + '-client.conf', r.conf); });
		});
		var qr = ui.createHandlerFn(this, function() {
			return fetchThen(function(r) {
				if (!r.qr) { ui.addNotification(null, E('p', {}, _('QR needs the qrencode package.'))); return; }
				var box = E('div', { 'style': 'text-align:center;max-width:340px;margin:0 auto' });
				box.innerHTML = r.qr;
				ui.showModal(_('Scan with the WireGuard app'), [
					box,
					E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')))
				]);
			});
		});
		var regen = ui.createHandlerFn(this, function() {
			return busy(callWgSetPsk(idx, ''), _('Regenerating PSK…')).then(wgRefresh);
		});
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'data-title': _('Tunnel') }, 'wg' + idx),
			E('td', { 'class': 'td', 'data-title': _('Session') }, t.session),
			E('td', { 'class': 'td', 'data-title': _('Client endpoint') }, (ep || '-') + ':' + t.port),
			E('td', { 'class': 'td', 'data-title': _('State') },
				E('span', { 'style': 'color:' + (up ? '#4caf50' : '#888') + ';font-weight:bold' },
					fmtHandshake(up, t.handshake))),
			E('td', { 'class': 'td cbi-section-actions' }, hasKey ? [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': dl }, _('Config')),
				' ',
				E('button', { 'class': 'btn cbi-button', 'click': qr }, _('QR')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-reload', 'click': regen }, _('New PSK'))
			] : E('em', {}, _('Save & Apply to generate keys')))
		]));
	});

	return E('table', { 'class': 'table cbi-section-table' }, rows);
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('hinet_multidial'), uci.load('network') ]);
	},

	// Save & Apply persists the config; the hinet-multidial service reconciles
	// the actual wanp interfaces server-side (procd reload trigger). We just
	// refresh the live table once the interfaces have had a moment to appear.
	handleSaveApply: function(ev, mode) {
		var self = this;
		return this.map.save()
			.then(function() { return uci.apply(); })
			.then(function() {
				ui.addNotification(null,
					E('p', {}, _('Applied. Interfaces are reconciling to the selected count…')), 'info');
				if (self.refresh) {
					window.setTimeout(self.refresh, 2500);
					window.setTimeout(self.refresh, 6000);
				}
				if (self.wgRefresh) {
					window.setTimeout(self.wgRefresh, 3000);
					window.setTimeout(self.wgRefresh, 7000);
				}
			})
			.catch(function(e) { ui.addNotification(null, E('p', {}, _('Apply failed: ') + e)); });
	},

	render: function() {
		var m, s, o;

		m = new form.Map('hinet_multidial',
			_('HiNet Multi-Dial Controller'),
			_('Dial multiple PPPoE sessions over one physical WAN port, each with its own public IP. ' +
			  'The DHCP WAN lifeline is never touched. <strong>Save &amp; Apply</strong> creates or removes ' +
			  'the interfaces and reloads the network; the buttons in the status table act on running sessions live.'));
		this.map = m;

		// ---- global settings + account + number of sessions ----
		s = m.section(form.NamedSection, 'main', 'controller', _('Controller'));
		s.anonymous = true;

		o = s.option(form.ListValue, 'count', _('Number of sessions (IPs)'),
			_('How many PPPoE sessions to dial. Each becomes wanp&lt;n&gt; with its own public IP ' +
			  'and private routing table. Save &amp; Apply creates or removes interfaces to match.'));
		for (var i = 1; i <= 6; i++) o.value(String(i), String(i));
		o.default = '1';

		o = s.option(form.Value, 'username', _('HiNet account (HN number)'),
			_('Enter just the 8-digit HN number — <code>@hinet.net</code> is added automatically. ' +
			  'Shared by every session. For another ISP, enter the full account including <code>@</code>.'));
		o.placeholder = '12345678';
		o.validate = function(section_id, value) {
			if (!value || value.indexOf('@') >= 0) return true;
			if (/^[0-9]{6,12}$/.test(value)) return true;
			return _('Enter the 8-digit HN number, or a full account containing @.');
		};

		o = s.option(form.Value, 'password', _('PPPoE password'));
		o.password = true;

		o = s.option(form.Flag, 'enabled', _('Auto-dial at boot'),
			_('When on, the sessions are dialed automatically at boot. When off they stay down until dialed here.'));
		o.rmempty = false;

		o = s.option(form.Value, 'boot_delay', _('Initial delay (seconds)'),
			_('Wait this long after boot before the first dial, letting the DHCP WAN settle.'));
		o.datatype = 'range(0,120)'; o.default = '5'; o.placeholder = '5';

		o = s.option(form.Value, 'dial_delay', _('Delay between sessions (seconds)'),
			_('Gap between each dial — staggering avoids a burst of simultaneous PPPoE discovery frames.'));
		o.datatype = 'range(0,120)'; o.default = '3'; o.placeholder = '3';

		o = s.option(form.Flag, 'wg_enabled', _('Enable WireGuard egress tunnels'),
			_('Create one WG tunnel per active session (wg&lt;i&gt; → wanp&lt;i&gt;). A client connects to ' +
			  'wan0 on a per-tunnel port; its internet traffic exits via that session\'s public IP, while ' +
			  'ordinary LAN users keep using wan0. WG clients can also reach the LAN.'));
		o.rmempty = false;

		o = s.option(form.Value, 'wg_port_base', _('WireGuard port base'),
			_('Tunnel i listens on this port + i (base 51820 → wg1 = 51821). Opened on wan0.'));
		o.datatype = 'port'; o.default = '51820'; o.placeholder = '51820';
		o.depends('wg_enabled', '1');

		return m.render().then(L.bind(function(mapEl) {
			var statusBody = E('div', {}, E('em', {}, _('Loading…')));
			var self = this;

			function refresh() {
				return callStatus().then(function(res) {
					dom.content(statusBody, renderStatus(res, refresh));
				}).catch(function() {
					dom.content(statusBody, E('em', {}, _('status unavailable')));
				});
			}
			self.refresh = refresh;

			var controls = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Live Sessions')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Per-session control acts immediately on the running interface. ' +
					  'The global buttons below dial or stop every session at once (staggered).')),
				E('div', { 'style': 'margin-bottom:1em' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, function() {
							return busy(callDial(), _('Dialing all sessions…')).then(refresh);
						}) }, _('Dial all (staggered)')),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(self, function() {
							return busy(callStop(), _('Stopping all sessions…')).then(refresh);
						}) }, _('Stop all'))
				]),
				statusBody
			]);

			poll.add(refresh);
			refresh();

			// ---- WireGuard tunnels panel ----
			var wgBody = E('div', {}, E('em', {}, _('Loading…')));
			function wgRefresh() {
				return callWgStatus().then(function(res) {
					dom.content(wgBody, renderWgStatus(res, wgRefresh));
				}).catch(function() {
					dom.content(wgBody, E('em', {}, _('status unavailable')));
				});
			}
			self.wgRefresh = wgRefresh;

			var wgPanel = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('WireGuard Tunnels')),
				E('div', { 'class': 'cbi-section-descr' },
					_('One tunnel per active session. Download a client config (Endpoint auto-filled with ' +
					  'wan0\'s IP) or scan the QR. The pre-shared key adds a symmetric layer — regenerate it any time.')),
				E('div', { 'style': 'margin-bottom:1em' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-negative',
						'click': ui.createHandlerFn(self, function() {
							if (!confirm(_('Regenerate ALL WireGuard keypairs? This invalidates every existing client config.')))
								return;
							return busy(callWgGenkeys(), _('Rotating keys…')).then(wgRefresh);
						}) }, _('Regenerate all keys'))
				]),
				wgBody
			]);

			poll.add(wgRefresh);
			wgRefresh();

			return E('div', {}, [ mapEl, controls, wgPanel ]);
		}, this));
	}
});
