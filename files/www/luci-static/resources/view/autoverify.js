'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

/*
 * 校园网自动认证 - 设置页面
 *
 * 表单直接绑定 UCI /etc/config/autoverify。点"保存并应用"后：
 *   uci commit autoverify -> procd 的 reload trigger 触发
 *   /etc/init.d/autoverify reload -> 重新落地加固配置 + 重启认证进程
 * 因此页面里不需要自己做"应用"，也不用 exec 任何脚本。
 */
return view.extend({
	load: function() {
		return uci.load('autoverify');
	},

	/*
	 * 执行路由上的命令并弹窗显示结果。
	 *
	 * 必须把退出码也显示出来: autoverify check / once 正常情况下本来就不产生输出,
	 * 只看 stdout 会得到一个空弹窗, 分不清是成功、离线、还是权限被拒。
	 * hint 用来解释退出码的含义。
	 */
	handleAction: function(cmd, args, title, hint) {
		return fs.exec(cmd, args).then(function(res) {
			var out = ((res.stdout || '') + (res.stderr || '')).replace(/\s+$/, '');
			var body = out || _('(命令没有产生输出)');

			body += '\n\n' + _('退出码: %d').format(res.code);
			if (hint)
				body += '\n' + hint;

			ui.showModal(title || cmd, [
				E('pre', {
					'style': 'white-space:pre-wrap;word-break:break-all;max-height:60vh;overflow:auto;' +
					         'background:var(--background-color-low);padding:.5em;border-radius:4px'
				}, body),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('关闭'))
				])
			]);
		}).catch(function(err) {
			ui.addNotification(null,
				E('p', _('执行失败: %s').format(err && err.message ? err.message : err)), 'error');
		});
	},

	render: function() {
		var m, s, o;

		m = new form.Map('autoverify', _('校园网自动认证'),
			_('zportal 门户自动认证，以及针对校园网多设备检测的反制措施。' +
			  '改完点“保存并应用”，配置会落盘并自动重启认证进程。'));

		/* ---------------------------------------------------------- 账号 --- */
		s = m.section(form.NamedSection, 'main', 'autoverify', _('账号'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('关闭后不启动认证守护进程，也不再自动认证'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('账号'), _('通常是学号'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return value ? true : _('账号不能为空');
		};

		o = s.option(form.Value, 'password', _('密码'));
		o.password = true;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return value ? true : _('密码不能为空');
		};

		/* ---------------------------------------------------------- 门户 --- */
		s = m.section(form.NamedSection, 'portal', 'autoverify', _('门户'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'host', _('门户地址'), _('认证服务器 IP'));
		o.default = '10.82.66.10';
		o.datatype = 'ip4addr';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('门户端口'));
		o.default = '9090';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('登录页地址（覆盖）'),
			_('通常留空。未认证时程序会自动从 NAS 的响应里解析登录页地址，' +
			  'wlanuserip / mac / nasip / wlanacname / ssid 都会自动跟随网络变化。' +
			  '仅当自动探测失败时，才把浏览器地址栏里的 loginForWeb 地址粘到这里，' +
			  '其中会变化的客户端 IP 用 %WANIP% 占位。'));
		o.placeholder = 'http://10.82.66.10:9090/zportal/loginForWeb?wlanuserip=%WANIP%&...';

		/* ---------------------------------------------------- 探测与轮询 --- */
		s = m.section(form.NamedSection, 'tuning', 'autoverify', _('探测与轮询'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.DynamicList, 'probe_urls', _('连通性探测地址'),
			_('未认证时这些地址会被 NAS 劫持并引导到门户。' +
			  '判定"在线" = 状态码等于下面的期望值，且没有被重定向。'));
		o.rmempty = false;

		o = s.option(form.Value, 'user_agent', _('请求 User-Agent'),
			_('发出所有 HTTP 请求时带的 UA。探测走明文 HTTP，校园网直接看得见，' +
			  '所以不能填任何带 OpenWrt 或本项目名字的串，也不要填虚构/过时的 UA。' +
			  '建议与 UA-Mask 的 UA 保持一致 —— 两边不同，等于告诉对方这里住着两种浏览器。'));
		o.default = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
			'(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36';
		o.rmempty = false;

		o = s.option(form.Value, 'expect_code', _('期望状态码'), _('generate_204 类地址填 204'));
		o.default = '204';
		o.datatype = 'uinteger';

		o = s.option(form.Value, 'http_timeout', _('单次 HTTP 超时'), _('秒'));
		o.default = '8';
		o.datatype = 'uinteger';

		o = s.option(form.Value, 'check_interval', _('在线检查间隔'), _('秒'));
		o.default = '60';
		o.datatype = 'uinteger';

		o = s.option(form.Value, 'retry_interval', _('失败重试间隔'), _('秒，之后逐次翻倍'));
		o.default = '20';
		o.datatype = 'uinteger';

		o = s.option(form.Value, 'max_retry_interval', _('重试间隔上限'),
			_('秒。限制退避的上限，避免高频失败把门户的失败计数打满而强制要求验证码。'));
		o.default = '300';
		o.datatype = 'uinteger';

		o = s.option(form.Flag, 'verbose', _('详细日志'),
			_('每次探测都写日志，排障用。也可以临时执行 autoverify -v once。'));
		o.default = '0';
		o.rmempty = false;

		/* ---------------------------------------------------------- 接口 --- */
		s = m.section(form.NamedSection, 'network', 'autoverify', _('接口'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'wan_if', _('出口 netdev'),
			_('如 phy1-sta0。留空则自动取默认路由接口。'));
		o.placeholder = _('自动');

		o = s.option(form.Value, 'hotplug_if', _('触发认证的 netifd 接口'),
			_('如 wwan（无线 STA）或 wan（有线）。' +
			  '注意这与上面的 netdev 名不是同一个命名空间。'));
		o.default = 'wwan';

		o = s.option(form.Value, 'lan_dev', _('LAN 接口'),
			_('TTL 归一化作用的接口，通常是 br-lan。'));
		o.default = 'br-lan';

		/* ------------------------------------------------------ TTL 归一化 --- */
		s = m.section(form.NamedSection, 'ttl', 'hardening', _('TTL 归一化'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('把 LAN 转发出去的 IPv4 包 TTL 统一。' +
			  '不同系统初始 TTL 不同（Windows 128、Linux/Android 64），' +
			  'NAT 后出现离散值就会被判定为多设备。'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'ttl', _('TTL 值'),
			_('取与你主力设备一致的值。跨层一致性也有意义：' +
			  '如果你的浏览器 UA 是 Windows 而 TTL 是 64，某些检测会认为两者不匹配。'));
		o.value('64', _('64 — Linux / Android / iOS'));
		o.value('128', _('128 — Windows'));
		o.default = '64';
		o.depends('enabled', '1');

		/* ---------------------------------------------------------- NTP --- */
		s = m.section(form.NamedSection, 'ntp', 'hardening', _('NTP 收敛'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('把 LAN 的 udp/123 重定向到路由器，并让路由器作为 NTP 服务器。' +
			  '不同设备的默认 NTP 服务器和对时频率都不一样，直接出去就是多设备特征。'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'server', _('上游 NTP 服务器'),
			_('路由器自己向这些服务器对时；客户端则统一由路由器应答。'));
		o.depends('enabled', '1');

		/* ---------------------------------------------------------- DNS --- */
		s = m.section(form.NamedSection, 'dns', 'hardening', _('DNS 收敛'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('把 LAN 的 udp/tcp 53 重定向到路由器的 dnsmasq。' +
			  '不同设备的默认解析器、DoH 开关、EDNS 行为都不同，统一后对外只剩一个 DNS 客户端。' +
			  '注意：浏览器启用 DoH 时走 443，本项覆盖不到。'));
		o.default = '1';
		o.rmempty = false;

		/* ---------------------------------------------------------- 操作 --- */
		var actions = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('操作')),
			E('div', { 'class': 'cbi-section-descr' },
				_('以下按钮调用路由器上的命令，输出和退出码会弹窗显示，不会修改任何配置。')),
			E('div', { 'class': 'cbi-value' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleAction',
						'/usr/sbin/autoverify', [ '-v', 'once' ],
						_('立即认证一次'),
						_('已在线时不会重复认证 —— 在线状态下强行认证会顶掉自己已有的会话。'))
				}, _('立即认证一次')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleAction',
						'/usr/sbin/autoverify', [ '-v', 'check' ],
						_('检测连通性'),
						_('退出码 0 = 在线，1 = 离线。'))
				}, _('检测连通性')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleAction',
						'/usr/sbin/autoverify-hardening', [ 'status' ],
						_('查看加固状态'))
				}, _('查看加固状态')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleAction',
						'/usr/sbin/autoverify', [ 'update-check' ],
						_('检查更新'),
						_('退出码 0 = 已是最新，1 = 有新版本，2 = 查询失败。' +
						  '查询 GitHub Releases，只读，不会自动安装。'))
				}, _('检查更新'))
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleAction',
						'/usr/sbin/autoverify', [ 'debug' ],
						_('将要提交的认证字段 (只读)'),
						_('只读，不会提交认证。密码已脱敏。' +
						  ' 未认证时才能看到完整的登录页字段；在线时会提示“未发现门户重定向”，这是正常的。'))
				}, _('将要提交的认证字段 (只读)'))
			]),
			E('div', { 'class': 'cbi-section-descr' },
				_('提示：手动执行时的日志只进终端，不进 syslog；' +
				  '只有守护进程自己的日志会被 procd 转发到系统日志。'))
		]);

		return m.render().then(function(mapEl) {
			return E([], [mapEl, actions]);
		});
	}
});
