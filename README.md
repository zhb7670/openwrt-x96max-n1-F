# openwrt-x96max-n1-F

Phicomm **N1 (S905D)** 与 **X96Max+ (S905X3)** 的 OpenWrt 固件打包仓库。

打包流程完全照搬 [ophub/flippy-openwrt-actions](https://github.com/ophub/flippy-openwrt-actions) 的标准做法 —— **不自己编译 OpenWrt**，而是下载 ophub 现成的 rootfs，再用 `unifreq/openwrt_packit` 的打包脚本按机型 + 内核生成镜像。

---

## 版本一览

每个版本发布在**独立的 Release tag**，原代码也分开存放，互不影响。

| 版本 | 内容 | 状态 | 说明 |
|---|---|---|---|
| **V1** | **纯 ophub 官方流程**，零定制注入 | ✅ 已发布 | 基线版本，随时可对照「官方原样」 |
| **V2** | 官方流程 **+ DDNS-GO 修复** | 🚧 构建中 | 只多一步 overlay 注入，V1 流程一字未改 |

> **V1 与 V2 的原代码不混在一起。**
> V1 只用到仓库根目录的 `openwrt_flippy.sh` + `action.yml`（ophub 原件）；
> V2 的全部定制内容隔离在 **`v2-inject/`** 专属目录里，
> **V1 构建时 `inject_dir` 留空，整步跳过，永远不会读到 `v2-inject/`。**

版本说明详见 [`docs/RELEASE_V1.md`](docs/RELEASE_V1.md) 与 [`docs/RELEASE_V2.md`](docs/RELEASE_V2.md)。

---

## 产出（每版各 4 个固件，文件名相同）

| 机型 | SoC | 内核 | 文件名 |
|---|---|---|---|
| Phicomm N1 | s905d | 6.12.112 | `openwrt_s905d_n1_R26.03.25_k6.12.112-flippy-95+o.img.gz` |
| Phicomm N1 | s905d | 6.18.56 | `openwrt_s905d_n1_R26.03.25_k6.18.56-flippy-95+.img.gz` |
| X96Max+ | s905x3 | 6.12.112 | `openwrt_s905x3_multi_R26.03.25_k6.12.112-flippy-95+o.img.gz` |
| X96Max+ | s905x3 | 6.18.56 | `openwrt_s905x3_multi_R26.03.25_k6.18.56-flippy-95+.img.gz` |

> V1 与 V2 的**文件名完全相同**（机型 / 内核 / `OPENWRT_VER` 都没变），
> 靠 Release tag（`V1` / `V2`）区分，别下载错了。

固件默认参数：IP `192.168.1.1`、用户 `root`、密码 `password`、WIFI `OpenWrt`（无密码）。

---

## 仓库结构

```
.
├── .github/workflows/build.yml   # 打包工作流（本仓库自己的）
├── action.yml                    # 取自 ophub/flippy-openwrt-actions（GPL-2.0）
├── openwrt_flippy.sh             # 上面的 action 实际执行的脚本（GPL-2.0）
├── docs/
│   ├── RELEASE_V1.md             # V1 版本说明（纯官方）
│   └── RELEASE_V2.md             # V2 版本说明（DDNS-GO 修复）
├── v2-inject/                    # ★ V2 专属，V1 从不引用
│   └── overlay/
│       ├── etc/uci-defaults/99-ddns-go-fix
│       └── usr/lib/lua/luci/
│           ├── controller/ddns-go.lua
│           └── view/ddns-go/ddns-go.htm
├── LICENSE
└── README.md
```

`action.yml` + `openwrt_flippy.sh` 原样取自 ophub，仅用于被 `workflow` 里的 `uses: ./` 调用。
好处是流程完全掌握在自己仓库里，不受上游删库 / 改名影响；代价是上游更新时需要手动同步。

---

## 打包流程

`build.yml` 依次做这些事（**第 3.5 步只有 V2 会走到**）：

1. **装依赖** —— 先用 ophub 官方清单（`https://ophub.org/ubuntu2604-make-openwrt-depends`）整批安装，失败则逐个装并跳过个别不可用的包，最后补 `xfsprogs`。装完自检 `fdisk/sfdisk/losetup/mkfs.xfs/mkimage/dtc/pigz/...`。
2. **扩展磁盘** —— 用 `/` 剩余空间建一个 xfs 镜像挂到 `/builder`，再把 `/opt` 指向 `/builder/opt`（`openwrt_flippy.sh` 默认拿 `/opt` 当工作目录）。
3. **下载 rootfs** —— 从 `ophub/flippy-openwrt-actions` 的 `OpenWrt_armv8_rootfs` Release 下载 `*-rootfs.tar.gz`，重命名成 `openwrt-armsr-armv8-generic-rootfs.tar.gz`。
4. **3.5 注入定制 overlay**（仅 `inject_dir` 非空时）—— 解包 rootfs → `cp -a` 叠加 `v2-inject/overlay/` → 用**同一个文件名**重新打包。
5. **打包** —— `uses: ./` 调用根目录的 `openwrt_flippy.sh`，它内部会：
   - `git clone` `unifreq/openwrt_packit` 到 `/opt/openwrt_packit`
   - 查询 `ophub/kernel` 的 `kernel_flippy` release，把 `6.12.y`/`6.18.y` 解析成同系列最新版（→ `6.12.112` / `6.18.56`）
   - 下载内核包并校验 sha256
   - 逐个机型执行 `mk_s905d_n1.sh` / `mk_s905x3_multi.sh`
   - `pigz` 压缩得到的 `.img` → `.img.gz`
6. **上传** —— 产物存 Artifact（7 天），按 tag 从 `docs/` 取对应版本说明，发布到 Release。

---

## 触发方式

**打 V1（纯官方，不注入）**

```bash
gh workflow run build.yml --ref main \
  -f package_soc=s905d_s905x3 \
  -f kernel_version=6.12.y_6.18.y \
  -f auto_kernel=true \
  -f openwrt_ip=192.168.1.1 \
  -f rootfs_asset=2026.02.20-openwrt-armsr-armv8-generic-rootfs.tar.gz \
  -f release_tag=V1 \
  -f inject_dir=
```

**打 V2（官方 + DDNS-GO 修复）**

```bash
gh workflow run build.yml --ref main \
  -f package_soc=s905d_s905x3 \
  -f kernel_version=6.12.y_6.18.y \
  -f auto_kernel=true \
  -f openwrt_ip=192.168.1.1 \
  -f rootfs_asset=2026.02.20-openwrt-armsr-armv8-generic-rootfs.tar.gz \
  -f release_tag=V2 \
  -f inject_dir=v2-inject
```

只打一个机型时：`-f package_soc=s905d`。想钉死内核版本不用自动解析：`-f auto_kernel=false -f kernel_version=6.12.112_6.18.56`。

---

## 文件名里的三个片段是怎么来的

| 片段 | 来源 |
|---|---|
| `R26.03.25` | `unifreq/openwrt_packit/make.env` 里 `OPENWRT_VER` 的硬编码值。`openwrt_flippy.sh` 在 `OPENWRT_VER=auto` 时会去读它。**不是构建日期** |
| `-flippy-95+o` | 内核包自带。`ophub/kernel` 的 6.12.x 里 boot 文件叫 `boot-6.12.112-flippy-95+o.tar.gz`，脚本用 `KERNEL_VERSION="${boot_kernel_file:5:-7}"` 直接截出来。6.18.56 对应的是 `-flippy-95+`（没有 `o`） |
| `6.12.112` / `6.18.56` | `KERNEL_AUTO_LATEST=true` 时脚本抓 `ophub/kernel` 的 release 列表，按 `6.12.[0-9]+` / `6.18.[0-9]+` 正则排序取最新 |

---

## V2 修复了什么（摘要）

| 问题 | 根因 | 解决 |
|---|---|---|
| LuCI 里**找不到** DDNS-GO 菜单 | 官方 `luci-app-ddns-go` 用新架构（`menu.d/*.json` + `resources/view/*.js`），而本固件 `createindex()` 只扫 `controller/*.lua`、`dispatcher.lua` 无 `view()` | 补一份**老式** `controller` + `view` |
| 服务 `active with no instances`，9876 不监听 | `/etc/config/ddns-go` 出厂 `config basic 'config'` + `option enabled '0'`；init 脚本 `[ "$enabled" = "1" ] \|\| return 1` | 首启 `uci set ddns-go.config.enabled='1'` 并重启服务 |
| 改完菜单不生效 | LuCI 双层缓存（`luci-indexcache` / `luci-modulecache`，后者无时间戳校验） | 自修脚本 `rm -rf` 两层缓存 |

完整说明见 [`docs/RELEASE_V2.md`](docs/RELEASE_V2.md)。

> ★ 两个必须记住的坑：
> ① controller **文件名必须与 `module()` 名严格一致**（`ddns-go.lua` ↔ `luci.controller.ddns-go`），否则 `createindex()` 断言失败 → **全站 500**；
> ② UCI 段名是 `basic`（`config basic 'config'`），所以键是 **`ddns-go.config.enabled`**，不是 `ddns-go.basic.enabled`。

---

## 刷机

1. 解压：`gzip -d openwrt_s905d_n1_*.img.gz`
2. 用 `balenaEtcher` / `Rufus` / `dd` 写入 U 盘或 SD 卡
3. 设备从 U 盘启动后：**系统 → Amlogic Service → Install OpenWrt**（写入 eMMC）
4. 浏览器打开 `192.168.1.1`，`root` / `password`

下载完整性校验：

```bash
sha256sum -c sha256sums.txt
```

---

## 上游与许可

- 打包脚本：[unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit)（Flippy）
- Action 封装：[ophub/flippy-openwrt-actions](https://github.com/ophub/flippy-openwrt-actions) (GPL-2.0)
- 内核：[ophub/kernel](https://github.com/ophub/kernel)（`kernel_flippy` tag）
- 本仓库中的 `action.yml` 与 `openwrt_flippy.sh` 版权归 ophub，沿用 GPL-2.0。
- `v2-inject/` 下的定制内容为本仓库自行编写。
