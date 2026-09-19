#!/bin/sh
#
# 端到端测试: 启动 mock 门户, 验证 autoverify 的探测 -> 抓页 -> 认证 -> 复核 全流程,
# 以及各种失败响应的处理。不接触真实校园网。
#
# 用法: sh test/run.sh          (需要 python3 和 curl)
#
set -u

PY="${PYTHON:-python3}"
# 默认随机端口: 避免上一轮残留的 mock 占着固定端口应答, 导致测试结果串味
PORT="${PORT:-$(( 20000 + ($$ % 20000) ))}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/files/usr/sbin/autoverify"

command -v "$PY" >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }
command -v curl  >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

export TUNING_PROBE_URLS="http://127.0.0.1:$PORT/probe"
export PORTAL_HOST=127.0.0.1
export PORTAL_PORT="$PORT"
export MAIN_USERNAME="20230001"
export MAIN_PASSWORD="p@ss w0rd&x=1"   # 故意带空格和 & , 验证编码
export TUNING_HTTP_TIMEOUT=5

# 脚本现在从 /usr/lib/autoverify/cfg.sh 读配置; 本地跑要指到仓库里的那份。
# 没有 uci 命令时会自动退回同名环境变量 (上面那些就是 SECTION_OPTION 形式)。
export AV_LIB="$ROOT/files/usr/lib/autoverify/cfg.sh"

FAILED=0
MOCK_PID=""

start_mock() {
	# 端口必须空闲。Windows 上 SO_REUSEADDR 允许两个进程绑同一端口,
	# 若上一轮的 mock 还活着, 请求会被它接走, 而它带着上一轮的 MOCK_RESP。
	if curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/probe" 2>/dev/null; then
		echo "错误: 端口 $PORT 已被占用 (很可能是上一轮测试残留的 mock 进程)"
		echo "      先结束残留进程, 或换端口: PORT=18123 sh test/run.sh"
		exit 1
	fi

	MOCK_RESP="$1" "$PY" "$ROOT/test/mock_portal.py" "$PORT" > "$TMPOUT" 2>&1 &
	MOCK_PID=$!

	# 等启动完成: 既要有就绪日志, 也要端口真的能连上
	_i=0
	while [ "$_i" -lt 40 ]; do
		if grep -q "mock portal listening" "$TMPOUT" 2>/dev/null \
		   && curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/probe" 2>/dev/null; then
			return 0
		fi
		sleep 0.2
		_i=$((_i + 1))
	done
	echo "mock 门户未能启动 (端口 $PORT):"
	sed 's/^/    /' "$TMPOUT"
	exit 1
}

stop_mock() {
	[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
	wait "$MOCK_PID" 2>/dev/null
	MOCK_PID=""
	# 等端口真正释放, 否则下一次 start_mock 的占用检查会误报
	_i=0
	while [ "$_i" -lt 25 ]; do
		curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/probe" 2>/dev/null || break
		sleep 0.2
		_i=$((_i + 1))
	done
	return 0
}

TMPOUT=$(mktemp) || exit 1
trap 'stop_mock; rm -f "$TMPOUT"' EXIT INT TERM

check() {
	_name="$1"; _expect_rc="$2"; _expect_text="$3"
	_out=$(sh "$SCRIPT" once 2>&1)
	_rc=$?
	printf -- '--- %s\n' "$_name"
	printf '%s\n' "$_out" | sed 's/^/    /'
	if [ "$_rc" != "$_expect_rc" ]; then
		echo "    [FAIL] 退出码 $_rc, 期望 $_expect_rc"
		FAILED=1
		return
	fi
	if [ -n "$_expect_text" ]; then
		case "$_out" in
			*"$_expect_text"*) ;;
			*) echo "    [FAIL] 输出中未出现: $_expect_text"; FAILED=1; return ;;
		esac
	fi
	echo "    [OK]"
}

echo "=========== 1. 认证成功 ==========="
start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "probe 302 -> 抓登录页 -> 提交 -> 跟随 nextPage -> 204 复核" 0 "认证后连通性验证通过"
echo "    mock 收到的请求:"
sed 's/^/      /' "$TMPOUT"

# 对齐浏览器 #login_form.serialize(): 字段名、顺序、占位文字、Origin 头
assert_post() {
	_name="$1"; shift
	for _want in "$@"; do
		if grep -qF "$_want" "$TMPOUT"; then
			echo "    [OK]   $_name: $_want"
		else
			echo "    [FAIL] $_name: 未找到 $_want"; FAILED=1
		fi
	done
}
echo "    --- 与浏览器报文的逐项对比 ---"
# 占位文字涉及非 ASCII 字节。Windows/MSYS 下本地 curl 会把 argv 从 UTF-8
# 重新编码成当前代码页(GBK), 因此这里只断言“字段存在且非空”。
# 路由器上的 curl 是原生 Linux 二进制, argv 是裸字节, 无此问题。
assert_post_nonempty() {
	if grep -qE "^  $2=.+" "$TMPOUT"; then
		echo "    [OK]   $1"
	else
		echo "    [FAIL] $1: 字段缺失或为空"; FAILED=1
	fi
}
assert_post "Origin 头"        'Origin: http://127.0.0.1:'"$PORT"
assert_post "Content-Type"     'Content-Type: application/x-www-form-urlencoded; charset=UTF-8'
assert_post "validCodeFlag"    'validCodeFlag=false'
assert_post "跟随 nextPage"    'GET /zportal/goToAuthResult'
assert_post_nonempty "qrCodeId 已原样回填(占位文字)" qrCodeId
assert_post_nonempty "validCode 已原样回填(占位文字)" validCode

_seq=$(grep -oE '^  [A-Za-z]+=' "$TMPOUT" | sed 's/^  //' | tr -d '=' | tr '\n' ' ' | sed 's/ $//')
_want="qrCodeId username pwd validCode validCodeFlag ssid mac t wlanacname url nasip wlanuserip"
if [ "$_seq" = "$_want" ]; then
	echo "    [OK]   字段顺序与浏览器一致"
else
	echo "    [FAIL] 字段顺序不一致:"
	echo "           实际: $_seq"
	echo "           期望: $_want"
	FAILED=1
fi
stop_mock

echo "=========== 2. 密码错误 ==========="
start_mock '{"message":"您输入的帐号或密码有误","nextPage":"","result":"fail"}'
check "认证失败应返回非 0 并报出门户提示" 1 "您输入的帐号或密码有误"
stop_mock

echo "=========== 3. 重复认证 ==========="
start_mock '{"message":"该帐号已在线, 请勿重复认证","nextPage":"","result":"online"}'
check "result=online 视为已在线" 0 "已在线"
stop_mock

echo "=========== 4. 门户要求验证码 ==========="
start_mock '{"message":"请输入验证码","nextPage":"","result":"fail"}'
check "应提示需先在浏览器认证" 1 "门户要求输入验证码"
stop_mock

echo "=========== 5. 返回非 JSON ==========="
start_mock '<html>502 Bad Gateway</html>'
check "应报出无法解析并带原始响应" 1 "认证响应无法解析"
stop_mock

# 下面两个用例对应真实 NAS 的形态。实测这台 NAS 未认证时回 200 而不是 302,
# 最初的实现只认 302, 导致“未发现门户重定向, 无法定位认证页”。
echo "=========== 6. 未认证回 200 + 页面内 JS 跳转 (真实形态) ==========="
MOCK_PROBE_MODE=meta start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "应能从页面内跳转里找到门户地址" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 7. 未认证回 200 + Location 头 ==========="
MOCK_PROBE_MODE=location200 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "应能从 200 响应的 Location 头找到门户地址" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 8. 完全找不到门户地址 ==========="
start_mock '{"message":"","result":"success"}'
# 把探测指向只回 404 的路径, 模拟“NAS 回了 200/其它但内容里没有门户地址”
PROBE_SAVE="$TUNING_PROBE_URLS"
export TUNING_PROBE_URLS="http://127.0.0.1:$PORT/nothing"
check "应报错并把响应头/响应体打进日志" 1 "未发现门户重定向"
export TUNING_PROBE_URLS="$PROBE_SAVE"
stop_mock

echo "=========== 9. 两跳: 200 + JS 跳 /zportal/login, 该地址再 302 到 loginForWeb ==========="
# 完整复现真实 NAS 的行为。第一版实现只认 302 (报“未发现门户重定向”),
# 第二版不跟随登录页那一跳 (报“无法获取认证页面”)。
MOCK_PROBE_MODE=login302 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "应能跨两跳拿到登录页并完成认证" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 10. 空 portal.host (开源后的默认配置) ==========="
# 包里默认 host 为空, 门户地址靠响应里的 /zportal/ 自动识别。
# 这里同时卡住一个真 bug: case 的 *""* 能匹配任意字符串, host 为空时会把
# 任何地址都判成门户 —— 下面的 10b 就是这个回归点。
HOST_SAVE="$PORTAL_HOST"
PORTAL_HOST=""

MOCK_PROBE_MODE=login302 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "空 portal.host 时应能认出 /zportal/ 并完成认证" 0 "认证后连通性验证通过"
stop_mock

echo "--- 空 host 时, 与门户无关的跳转不能被当成门户"
# 旧实现下 is_portal_url 会匹配任意串, 于是拿公告页当登录页去请求,
# 报的是“无法获取认证页面”而不是“未发现门户重定向”。
MOCK_PROBE_MODE=other302 start_mock '{"message":"","result":"success"}'
check "应报未发现门户重定向" 1 "未发现门户重定向"
stop_mock

PORTAL_HOST="$HOST_SAVE"

echo
if [ "$FAILED" = "0" ]; then
	echo "全部通过"
else
	echo "存在失败用例"
fi
exit "$FAILED"
