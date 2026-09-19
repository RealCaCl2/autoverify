# autoverify

[![CI](https://github.com/RealCaCl2/autoverify/actions/workflows/ci.yml/badge.svg)](https://github.com/RealCaCl2/autoverify/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

校园网门户（**卓智 / 深澜 zportal**）的 OpenWrt 自动认证程序，带 LuCI 设置页面。

纯 POSIX sh，无编译依赖，运行时只需要 `curl`。断线自动重认证，出口接口 up 时立即认证。

> 不限于某一所学校，但**目前只在淮安大学（原淮阴工学院）实测验证过**。
> 门户地址靠响应里的 `/zportal/` 自动识别，多数 zportal 学校不需要改代码。

---

## ⚠️ 先读这段

- 本项目**只做认证自动化**。校园网通常按 IP 计会话，路由器 NAT 后面的多台设备共用
  同一个已认证 IP —— 这在**很多学校的用户协议里是明确禁止的**。
- 仓库里的 `autoverify-hardening`（TTL 归一化 / NTP 收敛 / DNS 收敛）是**主动对抗
  多设备检测**的措施。用它**可能违反你所在学校的网络使用规定**，后果自负。
- 这些措施**都能被绕过，也不保证有效**。原理与自检方法见 [docs/detection.md](docs/detection.md)。
- **请只在你确实有权使用的账号和网络上运行。**
- 作者不对使用本项目导致的任何后果负责。

## 它解决什么问题

校园网出口是按 **IP** 绑会话的。路由器接入校园网后拿到一个 `10.80.x.x` 地址，
必须有一个设备完成门户认证，整条出口才能通。本程序跑在路由器上，替这条出口完成认证：

```
校园网 ── WAN(10.80.x.x) ── [OpenWrt + autoverify] ── LAN(192.168.1.0/24) ── 你的设备
                                     ↑ 认证的是这个 IP
```

---

> 协议细节（NAS 为什么会回 200、隐藏字段长什么样、为什么必须跟那个跳转）
> 见 **[docs/protocol.md](docs/protocol.md)**。

---

## 适配你的学校

大多数 **zportal**（卓智/深澜）学校**开箱可用**，因为：

- 门户地址不写死 —— 靠响应里的 `/zportal/` 自动识别（`portal.host` 留空即可）
- `wlanuserip` / `mac` / `nasip` / `wlanacname` / `ssid` 全部从 NAS 的响应里现取，
  换网、换设备、换 AP 都不用改配置
- 隐藏字段每次认证前重新抓登录页回填，**不依赖任何加密算法**，门户换密钥/换算法都不影响

**如果跑不通，按这个顺序查：**

1. `/usr/sbin/autoverify debug` —— 看它探测到了什么、认出了哪个地址、拿到了哪些字段。
   在 LuCI 页面上也有对应按钮。
2. **门户不是 zportal**（如 `srun_portal_pc`、Dr.COM、锐捷 ePortal）→ 本项目不适用，
   需改写 `find_portal_url` / `do_login`。
3. **门户要求验证码** → 程序做不到，会明确报错并提示先手动认证一次。
4. **门户回了 success 但会话没起来** → 见 [docs/protocol.md](docs/protocol.md) 里关于
   `nextPage` 的部分：只发 POST 不够，**必须跟随它给的跳转**。

完整的协议实测（NAS 为什么会回 200 而不是 302、隐藏字段长什么样、`userIndex` 为什么
按 IP 记账）见 **[docs/protocol.md](docs/protocol.md)**。

## 安装

### 方式一：apk 包（推荐）

从 [Releases](../../releases) 下载 `autoverify-*.apk`（**noarch，架构无关**，任何 OpenWrt 25.x
都能装），或自己构建（见下文）。

```sh
# 1. 路由器上先装 curl
apk update && apk add curl

# 2. 把 apk 传上去。
#    OpenWrt 的 dropbear 没有 sftp-server，新版 scp 默认走 SFTP 会失败，用管道传：
cat autoverify-1.0.0-r3.apk | ssh root@192.168.1.1 'cat > /tmp/autoverify.apk'

# 3. 安装。包没有用 OpenWrt 官方密钥签名，所以要 --allow-untrusted
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/autoverify.apk && rm /tmp/autoverify.apk
```

装完直接去 LuCI：**服务 → 校园网自动认证**。

> apk 的 conffile 机制：`/etc/config/autoverify` 已存在且与包内默认值不同时，
> 你的配置会被保留，包内默认值另存为 `/etc/config/autoverify.apk-new`。**密码不会丢。**

### 方式二：直接铺文件（不用包管理器）

```sh
tar cz -C files . | ssh root@192.168.1.1 'tar xz -C /'
ssh root@192.168.1.1 '
  chmod +x /usr/sbin/autoverify /usr/sbin/autoverify-apply /usr/sbin/autoverify-hardening \
           /etc/init.d/autoverify /etc/hotplug.d/iface/99-autoverify /etc/uci-defaults/90-autoverify-migrate
  chmod 600 /etc/config/autoverify
'
```

### 从源码构建 apk

apk 包是 apk-tools 3.x 的 **ADB 二进制格式**（文件头 `ADBd`），schema 只松散定义、
实际取决于 apk-tools 的 C 源码，**无法手工拼装**，必须用 OpenWrt SDK。

```sh
# 在 WSL / Linux 里（需要 build-essential unzip zstd flex bison libncurses-dev）
bash tools/build-apk.sh
# 产物落在 dist/
```

脚本会自动下载 SDK。**默认用 USTC 镜像** —— `downloads.openwrt.org` 在国内常只有
100KB/s 量级，而 SDK 有 200MB+，会卡很久（实测 135KB/s vs 镜像 1.3MB/s）。
可用 `MIRROR=` 覆盖，或改成 `https://mirror.sjtu.edu.cn/openwrt`。

## 配置

配置在 **UCI**：`/etc/config/autoverify`。

### 用 LuCI（推荐）

**服务 → 校园网自动认证**。各分组对应 UCI 里的同名 section。
改完点“保存并应用”，会自动落盘、重新落地加固配置、并重启认证进程。

### 用命令行

```sh
uci set autoverify.main.username='你的学号'
uci set autoverify.main.password='你的密码'
uci commit autoverify
/etc/init.d/autoverify reload
```

### 配置项

| section | option | 说明 |
|---|---|---|
| `main` | `enabled` / `username` / `password` | 开关与账号 |
| `portal` | `host` / `port` / `url` | 门户地址 |
| `tuning` | `probe_urls` / `expect_code` / `http_timeout` / `check_interval` / `retry_interval` / `max_retry_interval` / `verbose` | 探测与轮询 |
| `network` | `wan_if` / `hotplug_if` / `lan_dev` | 接口 |
| `ttl` / `ntp` / `dns` | `enabled` 等 | 反检测措施，见 **[docs/hardening.md](docs/hardening.md)** |

**`portal.url` 通常留空。** 未认证时程序会自动从 NAS 的响应里解析登录页地址，
`wlanuserip` / `mac` / `nasip` / `wlanacname` / `ssid` 全部自动跟随网络变化。
仅当自动探测失败时，才把浏览器地址栏里的地址粘进去，其中的客户端 IP 用 `%WANIP%` 占位。

## 启动

```sh
/etc/init.d/autoverify enable
/etc/init.d/autoverify start
logread -f -e autoverify     # Ctrl-C 退出
```

## 验证

### LuCI 页面里的“操作”区

三个按钮：**立即认证一次** / **检测连通性** / **查看加固状态**，再加一个只读的
**将要提交的认证字段**。输出和退出码都弹窗显示。

### 命令行

```sh
/usr/sbin/autoverify debug              # 只读: 打印配置/连通性/将要提交的字段，不提交认证
/usr/sbin/autoverify check; echo $?     # 0=在线 1=离线
/usr/sbin/autoverify once               # 检测后按需认证一次
/usr/sbin/autoverify -v once            # 带详细日志
/usr/sbin/autoverify-hardening status   # 加固措施开关 + 系统实际状态
```

`-v` 必须用参数形式：UCI 是唯一事实来源，环境变量只在没有 `uci` 命令时才作为回退，
所以 `VERBOSE=1 autoverify once` 在路由器上是无效的。

`debug` 输出示例：

```
== 配置 ==
  来源            : UCI /etc/config/autoverify
  账号            : 20230001
  探测地址        : http://connect.rom.miui.com/generate_204 ...
  WAN 接口        : phy1-sta0
  该接口 IP       : 10.80.3.64
  该接口 MAC      : AABB-CCDD-EEFF
== 连通性 ==
  离线 (需要认证)
== 认证页与字段 ==
  提交地址: http://10.82.66.10:9090/zportal/login/do
  提交字段:
    qrCodeId=请输入编号
    username=20230001
    pwd=***
    ...
```

## LuCI 设置页面

菜单：**服务 → 校园网自动认证**（`/cgi-bin/luci/admin/services/autoverify`）。

<img src="docs/screenshot.png" alt="LuCI 设置页面" width="680">

页面分七组配置（每组对应 UCI 里的一个 section），外加一个操作区：

| 分组 | 内容 |
|---|---|
| 账号 | 启用开关、账号、密码 |
| 门户 | 门户地址 / 端口 / 登录页地址覆盖 |
| 探测与轮询 | 探测地址（可增删多条）、期望状态码、各类超时与间隔 |
| 接口 | 出口 netdev、hotplug 接口、LAN 接口 |
| TTL 归一化 | 开关 + TTL 值（64 / 128 下拉选择） |
| NTP 收敛 | 开关 + 上游服务器列表 |
| DNS 收敛 | 开关 |
| 操作 | 立即认证一次 / 检测连通性 / 查看加固状态 / 将要提交的认证字段（输出+退出码弹窗） |

四个按钮都加 `-v` 并显示退出码：`autoverify check` / `once` **正常情况下本来就不产生
任何输出**（只用退出码表示结果），只看 stdout 会得到空弹窗，分不清是成功、离线还是
权限被拒。

ACL 里**故意不授权 `autoverify login`** —— 它会在已在线时强行重新认证，顶掉自己的会话。

点“保存并应用”后会：`uci commit autoverify` → procd 的 reload trigger 触发
`/etc/init.d/autoverify reload` → 重新落地加固配置 + 重启认证进程。
**页面本身不需要 exec 任何“应用”脚本**。

涉及文件：

```
www/luci-static/resources/view/autoverify.js      视图
usr/share/luci/menu.d/luci-app-autoverify.json   菜单
usr/share/rpcd/acl.d/luci-app-autoverify.json    权限(uci 读写 + 三条命令的 exec)
```

## 运行机制

| 组件 | 作用 |
|---|---|
| `/etc/init.d/autoverify` | procd 服务，开机自启，进程异常自动拉起 |
| `/usr/sbin/autoverify daemon` | 每 `CHECK_INTERVAL`(60s) 探测一次，掉线即重认证 |
| `/etc/hotplug.d/iface/99-autoverify` | 出口接口 up 时立刻认证一次，不等轮询 |

三项反检测措施（TTL 归一化 / NTP 收敛 / DNS 收敛）由 `autoverify-hardening` 开关，
**开机时由 init 脚本自动从 UCI 落地**，不随认证进程一起跑。
详见 **[docs/hardening.md](docs/hardening.md)**。

`daemon` 等待用的是"后台 sleep + wait"而不是前台 `sleep`。busybox ash 要等前台
子进程结束后才处理 trap，若直接前台 `sleep 300`，`/etc/init.d/autoverify stop`
会一直卡到 procd 超时后 SIGKILL，而这段时间 `start` 已经跑起来，会出现
**两个 daemon 同时发认证请求**。

两个接口配置项分属不同命名空间，别搞混：

- `WAN_IF` 是 **netdev** 名（如 `phy1-sta0`），用于读 IP 和 MAC，留空自动探测。
- `HOTPLUG_IF` 是 **netifd 接口名**（如 `wwan` / `wan`），用于决定热插拔是否触发。

认证失败时重试间隔按 `20s → 40s → 80s → …` 退避，上限 `MAX_RETRY_INTERVAL`(300s)，
避免高频失败把门户的失败计数打满而强制要求验证码。

---

## 测试

不需要连真实校园网，用内置的 mock 门户做端到端回归：

```sh
sh test/run.sh          # 需要 python3 + curl
```

覆盖：认证成功、密码错误、重复认证、要求验证码、门户返回非 JSON。

其中“认证成功”用例会卡住**必须跟随 `nextPage`（`goToAuthResult`）才能拿到授权**这一点 ——
mock 只在 `goToAuthResult` 被请求后才返回 204。
---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/protocol.md](docs/protocol.md) | zportal 协议实测说明（实现依据） |
| [docs/hardening.md](docs/hardening.md) | 反检测加固：TTL / NTP / DNS |
| [docs/detection.md](docs/detection.md) | 多设备检测方式清单、证据强度、自检方法 |
| [docs/verification.md](docs/verification.md) | 实测记录 |


## 已知限制

- 门户若要求输入**验证码**，程序做不到，会明确报错并提示先手动认证一次。
- 门户页面结构变更（字段改名/改 id）会导致报错 `认证页缺少字段: ...`，需要同步更新
  `LOGIN_FIELDS`。
- 若 NAS 换一种方式引导客户端到门户，报错 `未发现门户重定向` 并附带响应头/响应体，
  据此在 `find_portal_url` 里补一种识别方式即可。
- 只走明文 HTTP。若门户改为 HTTPS 或改用其它认证协议（如 `srun_portal_pc`），需要重写。
- 账号密码以明文存在 `/etc/config/autoverify`（权限 600，UCI 格式）。OpenWrt 上做本地加密意义有限，
  但请自行知悉这一点，不要把该文件提交到任何仓库。

## 在 Windows/MSYS 上跑测试的坑

git-bash 里的 `curl` 是 Windows 原生二进制，**argv 会被从 UTF-8 重新编码成当前代码页
（中文系统上是 GBK）**。因此 `test/run.sh` 对 `qrCodeId` / `validCode` 只断言
“字段存在且非空”，不比较具体字节。路由器上的 curl 是原生 Linux 二进制，argv 为裸字节，
无此问题（已在路由器上用 `hexdump -C` 逐字节确认）。
