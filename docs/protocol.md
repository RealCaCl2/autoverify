# zportal 协议说明（实测所得）

> 这是 [autoverify](../README.md) 的实现依据。全部结论来自对真实门户的抓包与探测，
> 不是从文档抄的。在别的学校遇到差异时，这一节能帮你定位是哪里不一样。
>
> 实测环境：淮安大学校园网 `iHuaiGong-Student`（卓智 zportal）。

---

门户：`http://10.82.66.10:9090/zportal/`（卓智 zportal，Tomcat）

**1. 未认证时，门户用“200 + 页面内跳转”把客户端引到登录页（不是 302）。**

这是实测踩到的坑：最初只按标准 302 实现，结果在真实 NAS 上三个探测全部返回
**HTTP 200 且无 Location**，`find_portal_url` 直接失败，日志报
`未发现门户重定向, 无法定位认证页`。

所以探测必须同时看三个地方，现在都支持：

| 形态 | 处理方式 |
|---|---|
| `3xx` + `Location` | 用 curl 的 `%{redirect_url}` |
| `200` + `Location` 头 | 解析 `-D` 存下的响应头 |
| `200` + 页面内跳转 | 在响应体里搜 `loginForWeb` / `/zportal/login`（相对路径不强制带 `?`） |
| 多跳重定向 | 跟随后取 `%{url_effective}` |

三种形态都有对应的 mock 回归用例
（`MOCK_PROBE_MODE=302|meta|location200|login302`，其中 `login302` 完整复现真实 NAS 的两跳）。

若仍定位不到，日志会直接打出**最后一次探测的状态码、响应头和响应体**，便于对照调整。

**2. NAS 实际给的门户地址是 `/zportal/login?`，且该地址还要再 302 一次。**

注意不是浏览器地址栏里那个 `loginForWeb`，而且参数是**完全百分号编码**的
（连 `-` 和 `.` 都编成了 `%2d` / `%2e`）：

```
http://10.82.66.10:9090/zportal/login
    ?wlanuserip=10.80.3.64
    &wlanacname=HYGXY%2dCR16K%2dMC%2d1F
    &mac=AABB-CCDD-EEFF
    &nasip=10%2e82%2e66%2e9
    &ssid=iHuaiGong%2dStudent
    &url=http%3a%2f%2fwww%2ehyit%2eedu%2ecn
```

> 这段是**抓包的原始值，原样保留**：`HYGXY` 与 `hyit.edu.cn` 均为**旧校名的拼音缩写
> 与域名**。学校已于 2026-02 更名为淮安大学（域名 `hau.edu.cn`），但 NAS 侧配置未必
> 同步。**这些参数全部按 NAS 给的原样回填**，程序不猜测、不修改。

**这个地址本身会再 302 一次**才到真正的登录页。不跟随跳转只会拿到空 body，
表现为 `无法获取认证页面`。所以抓登录页时必须带 `-L`。

（浏览器地址栏里则是 `loginForWeb` 带上解码后的参数，两者都要能认。）

**3. 登录页里 7 个隐藏字段被服务端加密成 hex：**

| 字段 | 实测值长度 | 说明 |
|---|---|---|
| `ssid` | 48 hex | 明文 17 字节 |
| `mac` | 32 hex | 明文 14 字节 |
| `t` | 明文 | 固定 `wireless-v2-plain` |
| `wlanacname` | 48 hex | 明文 17 字节 |
| `url` | 48 hex | 明文 22 字节 |
| `nasip` | 32 hex | 明文 10 字节 |
| `wlanuserip` | 32 hex | 明文 13 字节 |

长度全部是 8 字节的整数倍且与明文长度符合 PKCS5 填充 —— 分组密码（DES 类）。
**这些值跨会话完全恒定**（同一组入参连抓 3 次结果一致），说明用的是固定密钥，
不需要会话状态。

**3. 提交认证（以下的字段名、取值、顺序均以真实浏览器抓包为准）：**

```
POST http://10.82.66.10:9090/zportal/login/do
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Origin:   http://10.82.66.10:9090
Referer:  http://10.82.66.10:9090/zportal/loginForWeb?wlanuserip=...
X-Requested-With: XMLHttpRequest

qrCodeId=请输入编号&username=..&pwd=..&validCode=验证码&validCodeFlag=false
&ssid=..&mac=..&t=wireless-v2-plain&wlanacname=..&url=..&nasip=..&wlanuserip=..
```

两个容易漏掉的点：

- **`qrCodeId` 和 `validCode` 提交的是页面上的占位文字**（它们是表单内无 `name`
  以外特殊处理的普通输入框，jQuery 的 `serialize()` 会把占位文字一起发出去）。
- 门户的 `validCode` 标签写成了 `value="验证码" ... value=""`（重复属性）。
  按 HTML 规范，解析器保留**第一个**，所以浏览器实际发的是 `验证码`。
  解析时必须取第一个 `value`，不能取最后一个。

**4. 响应：**

```json
{"message":"","nextPage":"goToAuthResult","result":"success"}
```

`result` 为 `success` / `online`（重复认证）/ 其它（失败，原因在 `message`）。

**5. 只发 POST 不够，必须跟上 `nextPage` 跳转。**

浏览器端 JS 在成功分支会执行 `location.href = data.nextPage`，对 `nextPage` 为
`goToAuthResult` 的情况会再请求一次 `/zportal/goToAuthResult`。
**实测：只发 POST 会拿到 `result=success`，但会话并不通（`generate_204` 返回 200 被劫持）。**
本程序会跟随这一步（`follow_next_page()`），`test/` 里的 mock 门户就卡这个回归点：
它只在 `goToAuthResult` 被请求后才放行。

**6. 表单里还有一个 `qrCodeId` 字段**（二维码编号登录用），它在 `<form id="login_form">`
内部，浏览器的 `serialize()` 会连同占位文字一起提交。本程序原样回填。

**补充实测结论：** 门户**忽略 URL 里的 `wlanuserip` 参数，改用请求的源 IP**。
从两台不同设备（都 NAT 在同一个出口 `10.80.3.64` 后面）传入不同的 `wlanuserip`，
门户返回的加密值完全相同；而 `mac` 确实取 URL 参数。这意味着认证总是绑定
**发起请求那台机器的出口 IP** —— 也就是路由器自己。

### 为什么不去实现那套加密

因为隐藏字段是由门户**按明文参数实时生成**的，且跨会话恒定，
所以最省事也最稳的做法是：**每次认证前重新抓一次登录页，把字段原样回填**。
这样门户换密钥、换算法、换字段都不影响本程序（只要字段名不变，变了会明确报错）。
