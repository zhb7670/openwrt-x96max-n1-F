## V2 — 官方流程 + DDNS-GO 修复

V2 **不是重打一遍 V1**。它是在 V1 完全相同的打包流程上，**额外注入了一层定制 overlay**，
把之前在这台设备上手工修好的 **DDNS-GO 两个问题**固化进固件，做到「刷完即用」。

> **V1 与 V2 的原代码不混在一起**：V2 的全部定制内容只放在 `v2-inject/` 目录，
> V1 构建时 `inject_dir` 留空、整步跳过，**永远不会读 `v2-inject/`**。

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
- **解决**：用老式写法补一份 controller + view（`luci.controller.ddns-go` + `template`）。
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

### 二·补、适用前提（请先读这一条）

V2 修的是 **DDNS-GO 已经装好、但菜单不出现 / 服务不启动** 这两个问题。

**它不负责安装 ddns-go 后端本身。** 判断方法：

```bash
ls -l /usr/bin/ddns-go /etc/init.d/ddns-go /etc/config/ddns-go
```

| 情况 | 结果 |
|---|---|
| 三个文件都在 | 刷完 V2 **开箱即用**：菜单出现、服务已启动、9876 在听 |
| 只有 `/etc/config/ddns-go`，没有 `init.d`/二进制 | 菜单会出现，服务不启动（缺后端） |
| 三个都没有 | 菜单文件已就位，但页面内嵌的 9876 打不开；首启自修脚本**主动跳过，不动系统**。等你装好 ddns-go 后，菜单立即可用 |

也就是说：**即使当前的 rootfs 默认包集里没有 ddns-go，装 V2 也没有任何副作用**——
菜单文件是静态落盘的，自修脚本有守卫会自己让路。装完 ddns-go 后再手动确认一次即可：

```bash
uci set ddns-go.config.enabled='1' && uci commit ddns-go && /etc/init.d/ddns-go restart
```

---

### 三、注入是怎么合进固件的

在 V1 的 5 步流程里，**第 3 步和第 4 步之间**插了一步（仅当 `inject_dir` 非空时执行）：

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
| 触发参数 | `inject_dir=` 留空 | `inject_dir=v2-inject` |

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

然后浏览器打开 `http://<路由IP>` → **服务 → DDNS-GO**，菜单应正常出现，
点进去就是 ddns-go 的配置页。

---

### 六、不需要 DDNS-GO 修复？

那就直接用 **V1**（纯官方）。或者在触发构建时把 `inject_dir` 留空，产出的就是 V1 行为。
V1 与 V2 可以长期并存，互不影响。

---

### 七、上游与许可

- 打包流程：[ophub/flippy-openwrt-actions](https://github.com/ophub/flippy-openwrt-actions)（GPL-2.0）
- 打包脚本：[unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit)
- 内核：[ophub/kernel](https://github.com/ophub/kernel)
- `v2-inject/` 下的定制内容为本仓库自行编写
