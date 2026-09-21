# joywise-autoverify Agent Guide

## 项目边界

`joywise-autoverify`（运行时命令/包名仍为 `autoverify`）是面向 OpenWrt 的卓智（zportal）校园网自动认证插件，运行时以 POSIX
`sh` 和 `curl` 为核心，LuCI 只负责配置和诊断入口。项目同时包含 TTL、NTP、DNS、DHCP
和 IPv6 加固能力；这些能力可能违反网络管理方的使用规定，任何改动都必须保持显式开关、
可回滚，并避免扩大网络流量的控制范围。

本项目只在用户有权使用的账号和网络上运行。不要把真实的 `/etc/config/autoverify`、密码、
Cookie、完整门户查询串或隐藏认证字段提交到仓库、日志、状态文件或测试输出中。

## 代码地图与数据流

- `files/usr/sbin/autoverify`：探测、门户发现、登录、daemon 和命令行入口。
- `files/usr/lib/autoverify/cfg.sh`：UCI 配置读取；本地测试无 `uci` 时才回退到环境变量。
- `files/etc/init.d/autoverify`：procd 服务和加固配置应用。
- `files/etc/hotplug.d/iface/99-autoverify`：出口接口上线后的后台触发。
- `files/usr/sbin/autoverify-apply`、`autoverify-hardening`：加固配置与实际应用。
- `files/www/luci-static/resources/view/autoverify.js`：LuCI 表单和操作按钮。
- `test/run.sh`、`test/mock_portal.py`：不接触真实校园网的本地回归测试。
- `package/autoverify/Makefile`：APK 内容清单；新增运行时文件必须同步安装。
- `docs/`：协议、加固、检测和验证记录。

认证主链路是：探测连通性 → 解析 `/zportal/` 登录地址 → 跟随登录页跳转并提取隐藏字段
→ POST 用户凭据 → 跟随 `nextPage` → 再次探测确认真实在线。门户返回成功不等于 NAS
已授权，最终探测不能省略。

## 运行时约束

- 目标 shell 是 BusyBox `ash`；源码必须保持 POSIX `sh`，不能依赖 Bash、Python、Node、
  `flock`、`jq` 或 GNU 专属选项。
- 目标依赖主要是 `curl`、`uci`、`ip`、`nft` 及 OpenWrt 的 procd；可选命令缺失时，
  只读诊断应尽可能输出 `unknown`，不应伪造结果。
- UCI 是设备上的唯一配置事实来源。环境变量只服务于无 `uci` 的本地测试，不得改变设备
  上的配置优先级。
- `/var/run` 中的数据视为临时运行态；任何持久化摘要都只能保存脱敏结论。文件写入应先
  写同目录临时文件再原子替换，并使用严格 `umask`。
- 不改变已有 `check`、`once`、`daemon` 的基本语义；新增命令和错误码必须写入文档并有
  回归测试。

## 安全的协作流程

1. 先读取工作树和 Git 状态，确认用户已有改动，不覆盖、不清理、不重置。
2. 先完成计划和本指南，再做一次基线提交；该提交只固定起点，不包含实现阶段改动。
3. 每个阶段只做一个可验证的主题，完成后立即原子提交；提交前运行与该阶段相关的静态
   检查和回归测试。
4. 优先增加测试，再改行为；测试 mock 只绑定 `127.0.0.1`，不得调用真实校园网。
5. 禁止 `git reset --hard`、`git checkout --`、递归删除、覆盖用户配置或未经确认的
   外部发布。回滚使用 `git revert <commit>` 或恢复前一提交，并先保留证据。
6. 设备验证不可由本地仓库推断。没有 OpenWrt 设备时，明确记录“未执行”，不把本地
   Windows/Git Bash 结果冒充 BusyBox 验证。

## 提交约定

提交消息使用清晰的单一主题，例如：

- `docs: add agent guide and execution plan`
- `feat: add authentication lock and stale recovery`
- `feat: add runtime status model`
- `feat: add configuration validation`
- `fix: harden nextPage handling`
- `test: cover lock and validation regressions`

一个提交不得同时混入无关格式化、构建产物、真实配置或多个难以回滚的功能主题。每次提交
后检查 `git status --short`，确认没有 `dist/`、SDK、临时文件和敏感配置。

## 验证入口

在 Linux/CI 或安装了 Git Bash 的 Windows 环境中：

```sh
sh test/run.sh
dash -n files/usr/sbin/autoverify
node --check files/www/luci-static/resources/view/autoverify.js
```

CI 还会解析两个 LuCI JSON 文件并运行 ShellCheck。构建 APK 需要 OpenWrt SDK，不能以
本地源码文件存在代替包内文件清单验证。

## 当前执行重点

本轮按 `PLAN.md` 的依赖顺序推进，优先完成认证互斥、stale lock、中断清理及其测试；随后
再按资源和可验证性推进状态、配置校验、nextPage 安全处理、只读诊断、LuCI、文档和 CI。
任何依赖真实设备或 OpenWrt 特有命令的验收都保留为明确的未完成项，不通过猜测标记完成。
