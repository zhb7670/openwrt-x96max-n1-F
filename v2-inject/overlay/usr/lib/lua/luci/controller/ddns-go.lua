--==========================================================================
--  DDNS-GO 的 LuCI 入口（V2 定制）
--
--  为什么需要这个文件:
--    官方 luci-app-ddns-go 用的是新架构（menu.d/*.json + resources/view/*.js），
--    而本固件（flippy / LEDE 24.10.3）的 luci-base:
--      · createindex() 只扫 /usr/lib/lua/luci/controller/*.lua，完全不读 menu.d
--      · dispatcher.lua 里没有 view() 函数
--    → 官方菜单在这台机器上天生不可能出现，只能用老式写法自己补。
--
--  ★★ 硬约束（踩过的坑）:
--    文件名必须与 module() 名严格一致 —— ddns-go.lua ↔ luci.controller.ddns-go
--    否则 createindex() 断言失败 → 整个 LuCI 全站 500，连登录页都打不开。
--
--  排序 58：落在「服务」菜单里合适的位置。
--==========================================================================
module("luci.controller.ddns-go", package.seeall)

function index()
	entry({"admin", "services", "ddns-go"},
		alias("admin", "services", "ddns-go", "ddns-go"),
		_("DDNS-GO"), 58)

	entry({"admin", "services", "ddns-go", "ddns-go"},
		template("ddns-go/ddns-go"),
		_("DDNS-GO"), 1).leaf = true
end
