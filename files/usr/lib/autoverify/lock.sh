#!/bin/sh
#
# autoverify 认证互斥锁。
#
# 使用目录创建作为原子操作，避免依赖 OpenWrt 不一定编译进来的 flock applet。
# 调用方必须设置 LOCK_ROOT、LOCK_MAX_AGE，并在退出路径调用
# auth_lock_release。锁 owner 只保存诊断所需的非敏感元数据。

AUTH_LOCK_HELD=0

auth_lock_now() {
	date +%s 2>/dev/null || printf '0\n'
}

auth_lock_write_owner() {
	_umask_saved=$(umask)
	umask 077
	_owner_tmp="$AUTH_LOCK_DIR/owner.$$"
	{
		printf 'pid=%s\n' "$$"
		printf 'started_at=%s\n' "$(auth_lock_now)"
		printf 'source=%s\n' "${1:-manual}"
		printf 'operation=%s\n' "${2:-once}"
	} >"$_owner_tmp" || {
		umask "$_umask_saved"
		return 1
	}
	chmod 600 "$_owner_tmp" 2>/dev/null
	mv "$_owner_tmp" "$AUTH_LOCK_DIR/owner" 2>/dev/null || {
		rm -f "$_owner_tmp"
		umask "$_umask_saved"
		return 1
	}
	chmod 600 "$AUTH_LOCK_DIR/owner" 2>/dev/null
	umask "$_umask_saved"
	return 0
}

# 返回 0 表示锁可以回收，返回 1 表示仍应视为有效。
auth_lock_is_stale() {
	[ -r "$AUTH_LOCK_DIR/owner" ] || return 0

	_pid=$(sed -n 's/^pid=//p' "$AUTH_LOCK_DIR/owner" 2>/dev/null | head -n 1)
	_started=$(sed -n 's/^started_at=//p' "$AUTH_LOCK_DIR/owner" 2>/dev/null | head -n 1)
	case "$_pid" in
		''|*[!0-9]*) return 0 ;;
	esac
	case "$_started" in
		''|*[!0-9]*) _started=0 ;;
	esac

	# OpenWrt 默认挂载 /proc。测试环境或裁剪系统没有 /proc 时，退回 kill -0
	# 和时间上限，避免把“无法读取 cmdline”误当成可回收锁。
	if [ -d /proc ]; then
		[ -d "/proc/$_pid" ] || return 0
		if [ -r "/proc/$_pid/cmdline" ]; then
			_cmdline=$(tr '\000' ' ' <"/proc/$_pid/cmdline" 2>/dev/null)
			case "$_cmdline" in
				*autoverify*) ;;
				*) return 0 ;;
			esac
		fi
	else
		kill -0 "$_pid" 2>/dev/null || return 0
	fi

	_now=$(auth_lock_now)
	case "$_now" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$_started" -gt 0 ] || return 1
	[ "$_now" -ge "$_started" ] || return 1
	[ $((_now - _started)) -gt "${LOCK_MAX_AGE:-300}" ] && return 0
	return 1
}

auth_lock_acquire() {
	_source=${1:-manual}
	_operation=${2:-once}
	[ -n "${LOCK_ROOT:-}" ] || LOCK_ROOT=/var/run/autoverify
	AUTH_LOCK_DIR="$LOCK_ROOT/auth.lock.d"

	mkdir -p "$LOCK_ROOT" 2>/dev/null || return 1
	chmod 700 "$LOCK_ROOT" 2>/dev/null
	if mkdir "$AUTH_LOCK_DIR" 2>/dev/null; then
		if auth_lock_write_owner "$_source" "$_operation"; then
			AUTH_LOCK_HELD=1
			return 0
		fi
		rm -rf "$AUTH_LOCK_DIR"
		return 1
	fi

	if auth_lock_is_stale; then
		# 先改名再清理，避免另一个调用者看到半截 owner 文件。目标名带 PID，
		# 正常释放路径只会删除自己持有的目录。
		_reap_dir="$LOCK_ROOT/auth.lock.reap.$$"
		if mv "$AUTH_LOCK_DIR" "$_reap_dir" 2>/dev/null; then
			rm -rf "$_reap_dir"
		fi
		if mkdir "$AUTH_LOCK_DIR" 2>/dev/null; then
			if auth_lock_write_owner "$_source" "$_operation"; then
				AUTH_LOCK_HELD=1
				return 0
			fi
			rm -rf "$AUTH_LOCK_DIR"
			return 1
		fi
	fi
	return 3
}

auth_lock_release() {
	[ "${AUTH_LOCK_HELD:-0}" = "1" ] || return 0
	_owner_pid=$(sed -n 's/^pid=//p' "$AUTH_LOCK_DIR/owner" 2>/dev/null | head -n 1)
	[ "$_owner_pid" = "$$" ] || return 0
	AUTH_LOCK_HELD=0
	rm -rf "$AUTH_LOCK_DIR"
	return 0
}
