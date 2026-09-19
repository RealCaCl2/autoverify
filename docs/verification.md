# 实测记录

> 这些是在真实校园网环境里跑出来的结果，用来证明各功能确实生效。
> 复现命令见各条目自身。

---

已在真实环境（校园网 / Xiaomi Mi Router 4A Gigabit v2 / OpenWrt 25.12.5，有线 WAN）跑通：

- 连通性探测、WAN 自动识别（`phy1-sta0` / `10.80.3.64`）
- 从 NAS 的 200 响应里解析出 `/zportal/login?...`，跨两跳拿到登录页
- 回填 7 个隐藏字段 + `qrCodeId` / `validCode`，提交认证并恢复上网
- `stop` 能被 SIGTERM 干净终止（不再靠 procd SIGKILL）
- `autoverify-hardening ttl`：用 `traceroute` 只剩第一跳作证；规则计数持续增长
- `autoverify-hardening ntp`：conntrack 证明回包确实来自路由器（`src=192.168.1.1`）
- `autoverify-hardening dns`：同上，且客户端解析与 HTTPS 访问均正常
- `autoverify-hardening dhcp`：**抓包看真实 DHCP 报文**，三个字段均已被替换
  （主机名 `LAPTOP-XXXXXXXX`、client-id `ether 58:ea:1f:31:04:bd`、vendor-class `MSFT 5.0`），
  且 `Requested-IP` 与租约 IP 一致 —— 换 client-id 没有导致换 IP。
  DHCPv6 侧：修好后 `(Client-FQDN)` 选项从报文中消失，报文长度 112 -> 98 字节
- `autoverify-hardening ipv6`：不只看配置 —— 若客户端地址的 `ValidLifetime`
  还在被 RA 续期，就说明没生效。实测 100 秒内减少 101 秒（单调递减、无续期）
- **出站 UA 不再自报家门**：用 `tcpdump` 抓真实探测报文，线上 `User-Agent` 已变为普通 Chrome，
  旧值里的 `OpenWrt` / `autoverify` 字样彻底消失（抓完即卸，不常驻）
- **`autoverify update-check` 退出码矩阵**：r3<r4 返 1（有新版）、r4=r4 返 0、
  r10>r4 返 0（不误报）、读不到版本与网络不通各返 2
- **apk 包**：`apk add --allow-untrusted` 安装成功，包内 14 个文件全部到位，
  与仓库源码 **MD5 逐个一致**；apk 的 conffile 机制正确保留了已有 UCI 配置（密码未丢）
- **LuCI 菜单已注册**：LuCI 索引缓存里出现了 `"autoverify"` 与 `"luci-app-autoverify"`；
  视图 JS 可经 HTTP 取到（200 / 8811 字节）；JS 与两份 JSON 语法均校验通过
- **LuCI 的 ACL 已用真实会话验证**（登录 `/cgi-bin/luci/` 拿 sysauth 会话，再 POST 到
  `/ubus/` 调 `file.exec`）：四条授权命令均返回输出；
  `autoverify login` 与 `/bin/cat /etc/shadow` 都返回 `result:[6]`（权限拒绝）
- **apk 升级路径**：`apk add` r1 -> r2 成功，配置保留

当前检测强度：**只有“账号并发会话数”**，而且是按 IP 记账的，NAT 后已经解决。
其余检测方式（见 [detection.md](detection.md)）没有证据表明在启用。

仍是推测、没单独验证过的：

- ⚠️ **LuCI 页面的实际渲染效果**。验证手段到此为止（无浏览器），
  表单细节如有渲染问题需要你打开看一眼，看 F12 控制台报什么错。
- **开机自启**：`S95autoverify` 软链已建，但没重启过路由器验证。
- **hotplug 钩子**：出口接口 up 时立即认证这一条没单独触发过。
- **daemon 无人值守循环**：与手动 `once` 走同一套函数，但没在真实掉线时
  完整观察过它自己恢复。另外手动跑 `once` 时日志只进终端（`log()` 写 stderr），
  不进 syslog；只有 daemon 的日志会被 procd 转发到 syslog。
