# 反检测加固措施（TTL / NTP / DNS）

> ⚠️ 这一部分**主动对抗校园网的多设备检测**。使用它**可能违反你所在学校的网络使用
> 规定**，后果由使用者承担。这些措施都可以被绕过，也不保证有效。
> 完整的检测方式清单、证据强度与自检方法见 [detection.md](detection.md)。

---

## TTL 归一化

### 开关

三者统一由 `autoverify-hardening` 控制，**改的是 UCI，然后调用 `autoverify-apply` 落地**：

```sh
autoverify-hardening status            # 看三项开关 + 系统实际状态
```

所以 UCI 里的 `ttl.enabled` / `ntp.enabled` / `dns.enabled` 才是事实来源，
LuCI 页面、`uci set`、命令行开关三种途径改的是同一个地方，不会互相覆盖。

### 解决什么

路由器转发时先把 TTL 减 1，于是不同系统出来的包 TTL 各不相同（Windows 128、
Linux/Android 64），NAT 出去后呈现“一台机器后面有很多终端”的特征。统一 TTL
之后这个特征就消失了。

### 用法

```sh
autoverify-hardening ttl on          # 启用, 默认 TTL=64（Linux/Android）
autoverify-hardening ttl on 128      # 想让外部看起来是 Windows
autoverify-hardening status      # 含已匹配包数
autoverify-hardening ttl off         # 关闭
```

规则写在 `/etc/nftables.d/20-ttl-normalize.nft`，由 firewall4 包含进 `inet fw4` 表，
所以**重启和 `fw4 reload` 后都还在**，且 `off` 就能完全回滚。

### 代价（必须知道）

**对外的 `traceroute` / `mtr` 只能看到第一跳。** 这是 TTL 被改写的必然结果。
实测对比：

```
启用前:  1: 192.168.1.1 → 2: 100.105.0.1 → 3: 100.105.0.1 → 5: 183.207.67.9 → 6: 223.110.20.210
启用后:  1: 192.168.1.1 → 2: 223.5.5.5        （中间跳点全部消失）
```

排障时先 `autoverify-hardening ttl off`，否则分不清是校园网丢了包还是 TTL 被自己改了。

### 选择 TTL 值时想一下

不改 TTL 的指纹只有“TTL 差异”；改了之后多出一层一致性风险：TTL 64 对应 Linux，
而你实际设备可能是 Windows。**如果门户同时看 UA 和 TTL，两者不一致反而更异常。**
要么统一成 64 并保证没有其他 Windows 泄露点，要么干脆统一成你主力设备的值。

### 没覆盖的

- 只处理 **IPv4**。这台路由器 WAN 上没有 IPv6（`wan6` 是 down 的）。
- 只匹配 `iifname "br-lan"`。若以后新增 LAN 侧接口（访客网、VLAN），要把它加进去。

### 风险

这属于主动消除运营方的检测特征，不是普通配置优化。后果（包括账号被停）
由你承担。

### 注意：不关 flow offloading 的话，TTL 改写是假的

OpenWrt 可能默认开软件/硬件流量卸载。被卸载的连接走 fastpath，**直接跳过 netfilter 的
postrouting hook** —— `ip ttl set` 对它们根本不执行。表现为“规则计数在涨，但实际只覆盖了
一部分流量”，很难发现。`autoverify-hardening status` 会检测并告警。

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall && /etc/init.d/firewall restart
```

## NTP 收敛

### 解决什么

不同设备的默认 NTP 服务器和对时频率都不一样（time.windows.com / time.apple.com /
各家厂商自己的）——这些 `udp/123` 请求直接出去，对上游就是“同一个 IP 下面有一组
互不相同的 NTP 客户端”的特征。把 LAN 的 `udp/123` DNAT 到路由器，
并让路由器自己当 NTP server，对外就只剩一个 NTP 客户端。

### 用法

```sh
autoverify-hardening ntp on                        # 启用
autoverify-hardening ntp on ntp.aliyun.com         # 顺便换上游服务器
autoverify-hardening ntp off                       # 关闭
autoverify-hardening ntp status                    # 查看状态
```

实现为一个 UCI `config redirect`（在 LuCI 的防火墙页面里也看得到），
加上 `system.ntp.enable_server=1`。因此**重启后仍然生效**，`off` 就能完整回滚。

### 为什么客户端感知不到

DNAT 的回包靠 conntrack 反向改写源地址。实测：

```
客户端发:  src=192.168.1.156 dst=203.107.6.88 dport=123
路由器回:  src=192.168.1.1   dst=192.168.1.156
客户端看到: 回包源地址仍是 203.107.6.88
```

所以 NTP 客户端不会因为“源地址不符”丢弃回包，不会报错。

### 代价

路由器时钟不准时，后面所有设备跟着不准（TLS 证书校验依赖时间）。
路由器没认证上不了网时，上游同步会停，时间靠本地晶振维持。

## DNS 收敛

### 解决什么

和 NTP 同一思路。不同设备的默认解析器、DoH 开关、EDNS/ECS 行为、查询 ID 随机化
方式都不一样，这些 `udp/tcp 53` 请求直接出去，对上游就是“同一 IP 下有一组互不相同的
DNS 客户端”。重定向到路由器后，由 dnsmasq 统一对外解析。

DNS 和 NTP 是最容易被忽略的两个多设备特征源 —— 因为它们跟网页浏览无关，
但每台设备都会自己发。

### 用法

```sh
autoverify-hardening dns on
autoverify-hardening dns off
autoverify-hardening dns status      # 含 dnsmasq 监听情况和规则计数
```

启用前会先检查本机 53 端口真的在监听，否则拒绝启用（重定向过去没人应答 = 客户端直接断解析）。

### 为什么客户端感知不到

和 NTP 一样靠 conntrack 反向改写。实测：

```
客户端发:  src=192.168.1.156 dst=8.8.8.8 dport=53
路由器回:  src=192.168.1.1   dst=192.168.1.156 sport=53
客户端看到: 回包源地址仍是 8.8.8.8
```

路由器自己的上游查询走 `10.80.3.64 → 校园 DNS`，不受影响。

### 没覆盖的

**DoH（HTTPS 上的 DNS）绕过这里。** 浏览器/系统启用 DoH 后直接走 443，
要阻断需要屏蔽一长串不断变化的域名和 IP，副作用大且封不全，本脚本不做。

### 代价

基本没有。dnsmasq 本来就在跑，客户端只是从“自己解析”变成“让路由器解析”。
唯一影响：客户端无法再用自定义 DNS（比如自带广告过滤的解析器）。

## 三项反检测措施一览

| 措施 | 收敛的是 | 写入位置 | 开关 |
|---|---|---|---|
| TTL | IPv4 TTL | `/etc/nftables.d/20-ttl-normalize.nft` | `uci set autoverify.ttl.enabled` |
| NTP | LAN `udp/123` | UCI `firewall.ntp_converge` | `uci set autoverify.ntp.enabled` |
| DNS | LAN `udp/tcp 53` | UCI `firewall.dns_converge_{udp,tcp}` | `uci set autoverify.dns.enabled` |

三项都不随 autoverify 自动启用，重启和 `fw4 reload` 后都仍在。改完 UCI 后
执行 `/usr/sbin/autoverify-apply` 落地（或 `/etc/init.d/autoverify reload`）。

## 其它可能的检测方式

TTL 和 NTP 只是两个维度。TLS 指纹（JA3/JA4）、IPID、TCP 时间戳、HTTP/2 指纹、
QUIC、IPv6 泄露、并发连接数等的原理、证据强度、代价与自检方法，
见 **[detection.md](detection.md)**。
