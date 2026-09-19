#!/bin/sh
#
# autoverify 配置读取
#
# 唯一事实来源是 UCI /etc/config/autoverify。读取优先级:
#   1. UCI
#   2. 同名环境变量 (大写, 便于本地测试与临时排障)
#   3. 调用处给的默认值
#
# 被 autoverify / autoverify-apply / autoverify-hardening 共同使用。

AV_PKG="autoverify"

# av_cfg <section> <option> [default]
av_cfg() {
	_av_v=""
	if command -v uci >/dev/null 2>&1; then
		_av_v=$(uci -q get "$AV_PKG.$1.$2" 2>/dev/null)
	fi
	if [ -z "$_av_v" ]; then
		# 环境变量名 = SECTION_OPTION (均大写)。
		# 始终带段前缀是因为 enabled / url / port 这类选项名在多个段里重名,
		# 而且 PORT / URL 是极常见的环境变量名, 不带前缀会误命中。
		# 无 uci 命令时(本地测试)才走这条路径。option 名均为 [a-z_], 无注入风险。
		# 必须用 a-z / A-Z 区间写法: busybox 的 tr 默认未启用 FEATURE_TR_CLASSES,
		# '[:lower:]' / '[:upper:]' 会静默地不做任何转换(已在跑 OpenWrt 的路由器上实测)。
		# shellcheck disable=SC2018,SC2019
		_av_var="$(printf '%s' "$1" | tr 'a-z' 'A-Z')_$(printf '%s' "$2" | tr 'a-z' 'A-Z')"
		eval "_av_v=\${$_av_var:-}"
	fi
	[ -n "$_av_v" ] || _av_v="$3"
	printf '%s\n' "$_av_v"
}

# av_cfg_bool <section> <option> [default]  -> 输出 0/1
av_cfg_bool() {
	case "$(av_cfg "$1" "$2" "$3")" in
		1|on|true|yes|enabled) printf '1\n' ;;
		*)                     printf '0\n' ;;
	esac
}

# UCI 里是否已存在该 section (用于判断配置是否已初始化)
av_section_exists() {
	command -v uci >/dev/null 2>&1 || return 1
	uci -q get "$AV_PKG.$1" >/dev/null 2>&1
}
