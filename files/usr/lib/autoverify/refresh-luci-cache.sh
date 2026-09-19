#!/bin/sh
#
# 把 LuCI 视图文件的 mtime 刷成当前时间。
#
# 为什么需要这么做：
#   包内文件继承的是 OpenWrt 的构建日期作为 mtime（实测装到设备上拿到的是
#   25.12.5 的发版日），而 uhttpd 只发 ETag / Last-Modified、**不发 Cache-Control**。
#   浏览器在没有 Cache-Control 时会按 (现在 - Last-Modified) 的 10% 当启发式新鲜期
#   —— 构建日期越久远，这个窗口越长（实测约 8 天）。
#
#   后果：升级后浏览器可能直接拿缓存里的旧 JS，表现为"页面代码明明改了，但点按钮
#   毫无反应"，排查时极难想到是缓存。刷新 mtime 后启发式新鲜期约等于 0，
#   浏览器会重新校验并拿到新文件。
#
# 由 package/autoverify/Makefile 的 postinst 调用（升级时 post-upgrade 会复用）。
#
# 幂等，无副作用。

# 镜像构建期 IPKG_INSTROOT 非空，那时不能去碰构建主机的文件
[ -n "${IPKG_INSTROOT:-}" ] && exit 0

for _f in \
	/www/luci-static/resources/view/autoverify.js
do
	[ -f "$_f" ] && touch "$_f"
done

exit 0
