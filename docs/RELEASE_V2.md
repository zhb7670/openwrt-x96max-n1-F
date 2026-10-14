## V2 — 官方流程 + DDNS-GO 修复

V2 **不是重打一遍 V1**。它是在 V1 完全相同的打包流程上，**额外注入了一层定制 overlay**，
把之前在这台设备上手工修好的 **DDNS-GO 两个问题**固化进固件，做到「刷完即用」。

> **V1 与 V2 的原代码不混在一起，而且是工作流级别的隔离**：
> - V2 的定制内容只放在 **`v2-inject/`** 目录，且只被 **`build-v2.yml`** 引用；
> - **`build-v1.yml` 里根本没有"注入"这一步**，也没有 `inject_dir` 这类参数，
>   结构上就不可能读到 `v2-inject/`，也不存在"参数填错打成 V2"的可能；
> - 两份工作流是独立的文件、独立的排队队列（`build-v1-*` / `build-v2-*`），
>   改一份不会影响另一份。
>
> 默认 LAN IP 均为 **`192.168.100.1`**（用户 `root` / 密码 `password`）。

---

### 一、V2 到底优化了什么（逐条）

#### 优化 1：DDNS-GO 的 LuCI 菜单从「完全没有」到「正常出现」

- **现象**：固件里装了 `luci-app-ddns-go`，但 LuCI 后台**到处都找不到它的菜单**，
  只能靠手动敲 `http://<ip>:9876/` 才能打开它的 Web UI。
- **根因**：官方的 `luci-app-ddns-go` 用的是 **LuCI 新架构**——
  菜单声明在 `menu.d/*.json`、视图在 `resources/view/*.js`。
  而本固件的 LuCI 是**老架构**：
  - `createindex()` 只扫 `/usr/lib/lua/luci/controller/*.lua`，**根本不读 `menu.d/`**
  - `dispatcher.lua` **没有 `view()` 函数**，撑不起新架构的视图加载
  → 所以官方菜单在**这套固件上天生不会出现**，不是装错包，是架构不兼容。

  **实测证据（对 ophub rootfs 解包核对）**：

  | 检查项 | 实测结果 | 含义 |
  |---|---|---|
  | `luci-base` 版本 | `git-26.034.10143-64f3163-1` | 老式 lua 架构的 LuCI |
  | `dispatcher.lua` 行数 | 946 | — |
  | grep `function view` | **0 次** | 确认**没有** `view()`，撑不起 `"type": "view"` |
  | grep `menu.d` | **0 次** | 确认**根本不读** `menu.d` |
  | grep `function template` | 1 次 | 老式写法可用 ✅ |
  | grep `function alias` | 1 次 | 老式写法可用 ✅ |
  | 整个 rootfs 的 `menu.d/*.json` | **只有 1 个** | 就是 `luci-app-ddns-go.json` 自己 |

  而官方那个 `luci-app-ddns-go.json` 里写的 action 是：

  ```json
  "admin/services/ddns-go":            { "order": 58, "action": { "type": "firstchild" } }
  "admin/services/ddns-go/ddns-go":    { "order": 10, "action": { "type": "view", "path": "ddns-go/ddns-go" } }
  "admin/services/ddns-go/config":     { "order": 20, "action": { "type": "view", "path": "ddns-go/config" } }
  "admin/services/ddns-go/log":        { "order": 30, "action": { "type": "view", "path": "ddns-go/log" } }
  ```

  `firstchild` 和 `view` 这两种 action 本固件**都不支持**（`dispatcher.lua` 里只有
  `template` / `cbi` / `form` / `arcombine`），所以即便读到了 menu.d 也渲染不出来。

  **源码级铁证** —— `dispatcher.lua` 第 500 行起 `createindex()` 的实现：

  ```lua
  function createindex()
      local controllers = { }
      local base = "%s/controller/" % util.libpath()
      local _, path

      for path in (fs.glob("%s*.lua" % base) or function() end) do
          controllers[#controllers+1] = path          -- 只扫 controller/*.lua
      end

      for path in (fs.glob("%s*/*.lua" % base) or function() end) do
          controllers[#controllers+1] = path          -- 只扫 controller/*/*.lua
      end
      -- ……中间是索引缓存的 mtime 校验……
      for _, path in ipairs(controllers) do
          local modname = "luci.controller." .. path:sub(#base+1, #path-4):gsub("/", ".")
          local mod = require(modname)
          assert(mod ~= true,
                 "Invalid controller file found\n" ..
                 "The file '" .. path .. "' contains an invalid module line.\n" ..
                 "Please verify whether the module name is set to '" .. modname ..
                 "' - It must correspond to the file path!")
          local idx = mod.index
          assert(type(idx) == "function", "……contains no index() function……")
          index[modname] = idx
      end
      -- ……
  end
  ```

  三条都能一一对上：

  | 源码位置 | 说明 |
  |---|---|
  | `base = "%s/controller/"` + 两个 `fs.glob("*lua")` | **扫描范围只有 controller 目录**，全程不出现 menu.d → 官方菜单不可能被索引到 |
  | `modname = "luci.controller." .. 文件名` | 模块名**由文件名反推**，所以文件名必须与 `module()` 名严格一致 |
  | `assert(mod ~= true, "Invalid controller file found…")` | 名字不一致时 `require` 会返回 `true`（loader 无返回值），**assert 立即抛异常 → 整个 LuCI 500**。官方注释原文写着 "It must correspond to the file path!" |

  顺带确认：`createindex()` 里的**索引缓存是有 mtime 校验的**（拿 controller 文件的
  mtime 跟缓存文件比），所以 `/tmp/luci-indexcache` 会随 controller 更新自动失效；
  真正会"改了不生效"的是**第二层** `/tmp/luci-modulecache`（`ccache.lua` 无时间戳校验）。

- **解决**：用老式写法补一份 controller + view（`luci.controller.ddns-go` + `template`）。
  排序沿用官方 menu.d 里的 **58**，保证菜单落点和官方意图一致。
- **★ 踩过的坑（必须写下来）**：controller 的**文件名必须与 `module()` 名严格一致**
  （`ddns-go.lua` ↔ `luci.controller.ddns-go`）。名字对不上时 `createindex()` 会断言失败，
  后果是 **整个 LuCI 全站 500**，不只是这一个菜单坏掉。

#### 优化 2：DDNS-GO 服务默认不启动 → 开机即运行

- **现象**：菜单有了，但服务状态是 `active with no instances`，**9876 端口不监听**。
- **根因**：`/etc/config/ddns-go` 出厂默认是

  ```uci
  config basic 'config'
      option enabled '0'      # ← 问题在这
  ```

  而 `/etc/init.d/ddns-go` 里有

  ```sh
  config_get_bool enabled $cfg enabled 1
  [ "$enabled" = "1" ] || return 1     # enabled=0 直接 return
  ```

  → 服务实例压根不创建，进程不跑，端口不监听。
- **解决**：把 `enabled` 置 1 并重启服务。
- **★ 踩过的坑**：段名是 `basic`（`config basic 'config'`），
  所以 UCI 键是 **`ddns-go.config.enabled`**，
  **不是** `ddns-go.basic.enabled`——写错就静默无效。

#### 优化 3（附带）：清理 LuCI 双层缓存

- 改完 controller 后新菜单不出现，多半是被缓存挡住。LuCI 有两层缓存：
  - `/tmp/luci-indexcache`（索引缓存）
  - `/tmp/luci-modulecache`（**模块字节码缓存**——`ccache.lua` 里**没有任何时间戳校验**，
    命中就永久返回旧字节码）
- V2 的自修脚本会把两层一起 `rm -rf`，避免"改了没效果"的假象。

---

### 二、注入清单（只有 3 个文件）

| 路径 | 作用 |
|---|---|
| `v2-inject/overlay/usr/lib/lua/luci/controller/ddns-go.lua` | 老式 controller，把菜单挂到 **服务 → DDNS-GO**（排序 58） |
| `v2-inject/overlay/usr/lib/lua/luci/view/ddns-go/ddns-go.htm` | 视图页：内嵌 `http://<当前主机>:9876/` 的 iframe，另带「新窗口打开」兜底按钮 |
| `v2-inject/overlay/etc/uci-defaults/99-ddns-go-fix` | 首次开机执行一次：开 `enabled` → 自启+重启服务 → 清 LuCI 缓存 |

`/etc/uci-defaults/` 是 OpenWrt 的约定：**系统首次启动时执行一次，成功后脚本自动删除**，
所以不会重复跑、也不会每次开机都动配置。

脚本第 0 步有**守卫**：如果固件里连 `/etc/config/ddns-go` 和 `/etc/init.d/ddns-go` 都没有
（即根本没装 ddns-go 后端），则**直接退出**，不会凭空造出一个空的配置段。

---

### 二·补、适用前提（已实测确认）

**先说结论：本版用的 ophub rootfs 里已经自带完整的 ddns-go 后端，无需另装。**

对 `2026.02.20-openwrt-armsr-armv8-generic-rootfs.tar.gz` 解包核对，以下文件都在：

```
/usr/bin/ddns-go                      ← 主程序
/etc/init.d/ddns-go                   ← procd 服务脚本
/etc/config/ddns-go                   ← 出厂配置（问题就在这）
/etc/rc.d/S99ddns-go                  ← 开机自启软链，已存在
/etc/uci-defaults/luci-ddns-go        ← 官方自己的首启脚本
/usr/share/ddns-go/ddns-go-default.yaml
/lib/upgrade/keep.d/ddns-go            ← 升级时保留配置
/usr/libexec/ddns-go-call
```

所以刷完 V2 就是**开箱即用**。

#### ★ 铁证：出厂配置就是 `enabled '0'`

解包出来的 `/etc/config/ddns-go` 原文：

```uci
config basic 'config'
        option enabled '0'          ← ★ 病根
        option logger '1'
        option port '9876'
        option time '300'
        option ctimes '5'
        option skipverify '0'
        option delay '0'
        option dns '223.5.5.5'
```

对应的 `/etc/init.d/ddns-go` 第 56–58 行：

```sh
config_get_bool enabled $cfg enabled 1
[[ x$enabled = x1 ]] || return 1     ← enabled=0 就在这里 return 掉了
```

（段名是 `config`，段类型是 `basic`，所以 UCI 键写作 `ddns-go.config.enabled`。）

#### ★★ 最耐人寻味的一条：官方脚本漏了改 `enabled`

官方自带的 `/etc/uci-defaults/luci-ddns-go` 原文：

```sh
#!/bin/sh
[ -s "/etc/ddns-go/localtime" ] && mv -f /etc/ddns-go/localtime /etc/localtime
/etc/init.d/ddns-go enable
/etc/init.d/ddns-go start        ← 这一句其实是白做的
rm -f /tmp/luci*
exit 0
```

官方**确实**调了 `enable` 和 `start`，但**始终没有把 UCI 里的 `enabled` 改成 1**。
于是 `start` 被上面那行 `|| return 1` 拦下，结果就是：

- `enable` 生效 → `/etc/rc.d/S99ddns-go` 软链存在，看起来"已启用"
- `start` 无效 → 进程没起，`active with no instances`，9876 不监听

**官方漏掉的这一步，正是 V2 补上的那一步。** 我们的 `99-ddns-go-fix` 先执行
（`9` 的字典序在 `l` 之前），把 `enabled` 置 1 再 `restart`；
之后官方的 `luci-ddns-go` 再跑一遍 `enable`/`start` 也变成有效调用。
两种执行顺序都能起来，互为兜底。

另外注意：官方脚本里也有 `rm -f /tmp/luci*` —— 说明清 LuCI 缓存这件事官方自己也认为是必需的。

#### 万一将来换个 rootfs（没有 ddns-go）

那也不用担心。我们的自修脚本第 0 步有守卫：检测不到 `/etc/config/ddns-go`
和 `/etc/init.d/ddns-go` 时**直接退出，不改系统**；菜单文件仍然静态落盘，
等你装好 ddns-go 后再执行一次下面这条即可：

```bash
uci set ddns-go.config.enabled='1' && uci commit ddns-go && /etc/init.d/ddns-go restart
```

---

### 三、注入是怎么合进固件的

在 V1 的 5 步流程里，**第 3 步和第 4 步之间**插了一步。
这一步**只写在 `build-v2.yml` 里**，`build-v1.yml` 中不存在：

```
① 初始化环境  ② 建扩展盘  ③ 下载官方 rootfs
                              ↓
                        ③.5 注入定制 overlay   ← ★ V2 新增
                              ↓
                        ④ 打包  ⑤ 发布
```

具体做法：

```bash
# 1. 解包官方 rootfs（保留权限）
sudo tar -xzf opt/download/openwrt-armsr-armv8-generic-rootfs.tar.gz -C /builder/inject-work -p
# 2. 叠加 overlay
sudo cp -a v2-inject/overlay/. /builder/inject-work/
# 3. uci-defaults 脚本补上可执行位（git 检出后是 644）
sudo chmod 755 /builder/inject-work/etc/uci-defaults/99-ddns-go-fix
# 4. 用同一个文件名重新打包
cd /builder/inject-work && sudo tar -cpf - . | pigz -9 > opt/download/openwrt-armsr-armv8-generic-rootfs.tar.gz
```

**为什么必须保持原文件名**：`openwrt_flippy.sh` 只认
`opt/download/openwrt-armsr-armv8-generic-rootfs.tar.gz` 这一个名字，
换名就找不到 rootfs，整包失败。

---

### 四、V2 与 V1 的差异对照

| 项目 | V1 | V2 |
|---|---|---|
| 打包流程 | ophub 官方 5 步 | 同 V1，**多一步 overlay 注入** |
| rootfs | 官方原样 | 官方 + `v2-inject/overlay/` |
| DDNS-GO 菜单 | 无 | **有**（服务 → DDNS-GO，排序 58） |
| DDNS-GO `enabled` | `0`（不启动） | `1`（开机即监听 9876） |
| LuCI 缓存 | — | 首启自动清空双层缓存 |
| 内核 / 机型 / 文件名 | 6.12.112 · 6.18.56；N1 · X96Max+ | **完全相同** |
| 原代码位置 | 仓库根（ophub 原件） | 根 + **`v2-inject/`（V2 专属）** |
| 工作流文件 | `build-v1.yml`（**没有注入步骤**） | `build-v2.yml`（含注入步骤） |
| 排队队列 | `build-v1-*` | `build-v2-*`（两边互不干扰） |

**V2 的固件文件名与 V1 完全一致**（因为内核、机型、`OPENWRT_VER` 都没变），
所以两个版本分属两个 Release tag：**V1** 和 **V2**。

---

### 五、刷完 V2 后怎么验证

```bash
# 1. 菜单文件在位
ls -l /usr/lib/lua/luci/controller/ddns-go.lua
ls -l /usr/lib/lua/luci/view/ddns-go/ddns-go.htm

# 2. 配置项已打开
uci get ddns-go.config.enabled        # 期望输出：1

# 3. 服务在跑、端口在听
/etc/init.d/ddns-go status
netstat -lntp | grep 9876             # 期望看到 0.0.0.0:9876 LISTEN

# 4. 自修脚本已被消费（首启跑完即自动删除）
ls /etc/uci-defaults/99-ddns-go-fix   # 期望：No such file or directory
```

然后浏览器打开 `http://192.168.100.1` → **服务 → DDNS-GO**，菜单应正常出现，
点进去就是 ddns-go 的配置页。

---

### 六、不需要 DDNS-GO 修复？

那就直接用 **V1**（纯官方）——跑 `build-v1.yml` 就行，**那份工作流里没有注入步骤**，
不存在"误打成 V2"的可能。
V1 与 V2 可以长期并存，互不影响。

---

### 七、上游与许可

- 打包流程：[ophub/flippy-openwrt-actions](https://github.com/ophub/flippy-openwrt-actions)（GPL-2.0）
- 打包脚本：[unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit)
- 内核：[ophub/kernel](https://github.com/ophub/kernel)
- `v2-inject/` 下的定制内容为本仓库自行编写
