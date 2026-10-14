## V1 — 纯 ophub 官方流程固件

本版**完全按 [ophub/flippy-openwrt-actions](https://github.com/ophub/flippy-openwrt-actions) 的标准做法**打出，
没有做**任何**定制注入。它是 V2 的基线版本，用来随时对照"官方原样是什么样"。

---

### 一、打包出来的 4 个固件

| 机型 | 内核 | 文件名 | 大小（字节） | sha256 |
|---|---|---|---|---|
| Phicomm N1（S905D） | 6.12.112 | `openwrt_s905d_n1_R26.03.25_k6.12.112-flippy-95+o.img.gz` | 653,499,024 | `eeb58fa8…f5096f` |
| Phicomm N1（S905D） | 6.18.56 | `openwrt_s905d_n1_R26.03.25_k6.18.56-flippy-95+.img.gz` | 658,006,969 | `4fa2a6e9…43daa` |
| X96Max+（S905X3） | 6.12.112 | `openwrt_s905x3_multi_R26.03.25_k6.12.112-flippy-95+o.img.gz` | 656,606,182 | `6be21f1d…83b338` |
| X96Max+（S905X3） | 6.18.56 | `openwrt_s905x3_multi_R26.03.25_k6.18.56-flippy-95+.img.gz` | 661,679,295 | `630b1600…e4714a` |

完整校验值见资产 `sha256sums.txt`。下载后校验：

```bash
sha256sum -c sha256sums.txt
```

> 关于体积：gzip 是流式压缩，**同一份内容两次构建出来的字节数天然会有几百 KB 的波动**，
> 这不是内容差异。判断固件是否同一份，请看 sha256，不要看大小。

---

### 二、打包流程总结（5 步，全自动）

```
① 初始化构建环境
   apt 装 ophub 官方依赖清单（https://ophub.org/ubuntu2604-make-openwrt-depends）
   剔除清单里的 shell 通配符（如 gcc-arm*），否则 apt 整批失败
   补装 xfsprogs（清单里没有，但建扩展盘要用 mkfs.xfs）

② 创建扩展磁盘
   在 runner 的 / 上 truncate 一个 xfs 镜像 → losetup 挂到 /builder → 把 /opt 软链过去
   （openwrt_flippy.sh 默认拿 /opt 当工作目录）

③ 下载 OpenWrt rootfs
   从 ophub 的 Release 取现成的 armsr/armv8 rootfs（本版：2026.02.20-…-rootfs.tar.gz）
   ★ 注意：这一步就决定了我们「不编译 OpenWrt」——用的是 ophub 编好的通用 rootfs

④ 打包固件（调用本仓库根目录的 action = ophub 的 openwrt_flippy.sh）
   clone unifreq/openwrt_packit → 查 ophub/kernel 取最新内核 → 跑 mk_<soc>.sh → pigz 压缩

⑤ 列产物 / 算 sha256 / 上传 Artifact / 发布 Release
```

关键日志证据：

```
(1) [ flippy - 6.12.112 ] is the latest version.
(2) [ flippy - 6.18.56 ] is the latest version.
Kernel version: [ 6.12.112-flippy-95+o ]
OPENWRT_VER: [ R26.03.25 ]
[ SUCCESS ] All devices packaged successfully.
```

---

### 三、文件名是怎么来的（三个片段，全自动）

文件名格式：`openwrt_<机型>_<OPENWRT_VER>_k<内核版本>-flippy-<内核包标签>.img.gz`

| 片段 | 取值 | 来源 |
|---|---|---|
| `R26.03.25` | `R26.03.25` | `unifreq/openwrt_packit/make.env` 里 `OPENWRT_VER` 的**硬编码值**。是本打包脚本自身的版本号，**不是构建日期** |
| `-flippy-95+o` | 6.12.x → `flippy-95+o`<br>6.18.x → `flippy-95+` | **内核包自带**。`ophub/kernel` 里 boot 文件名为 `boot-6.12.112-flippy-95+o.tar.gz`，脚本用 `KERNEL_VERSION="${boot_kernel_file:5:-7}"` 截出中间段 |
| `6.12.112` / `6.18.56` | 同系列最新 | `KERNEL_AUTO_LATEST=true` 时，抓 `ophub/kernel` 的 `kernel_flippy` release，按正则 `6.12.[0-9]+` / `6.18.[0-9]+` `sort -urV \| head -1` |

---

### 四、和 ophub 官方 release 的关系

本版产物与 ophub 官方 `OpenWrt_armv8_save_2026.10` 里的固件**结构完全一致，只差内核小版本**：

| 机型 | ophub 官方 | 本版 V1 |
|---|---|---|
| N1 · 6.12 | `k6.12.111-flippy-95+o`（653,800,745 B） | `k6.12.112-flippy-95+o`（653,499,024 B） |
| N1 · 6.18 | `k6.18.54-flippy-95+`（658,370,357 B） | `k6.18.56-flippy-95+`（658,006,969 B） |
| X96+ · 6.12 | `k6.12.111-flippy-95+o`（657,034,985 B） | `k6.12.112-flippy-95+o`（656,606,182 B） |
| X96+ · 6.18 | `k6.18.54-flippy-95+`（662,093,053 B） | `k6.18.56-flippy-95+`（661,679,295 B） |

---

### 五、V1 刻意「没有做」的事

这一栏就是 V1 与 V2 的分界线，列出来是为了让两个版本可对照、不混淆：

| 项目 | V1 | V2 |
|---|---|---|
| DDNS-GO 的 LuCI 菜单 | ❌ 无（固件原生状态） | ✅ 已补（服务 → DDNS-GO） |
| DDNS-GO `enabled` 默认值 | ❌ 保持 `0`（服务不启动） | ✅ 改为 `1`（开机即监听 9876） |
| 定制 overlay 注入 | ❌ `inject_dir` 留空，整步跳过 | ✅ 注入 `v2-inject/overlay/` |
| 原代码目录 | 只有 `openwrt_flippy.sh` + `action.yml`（ophub 原件） | 额外引入 `v2-inject/`（V2 专属，V1 从不引用） |

---

### 六、刷机与使用

- 默认 LAN IP：**192.168.1.1**
- 用户名 `root`　密码 `password`
- 默认 Wi-Fi SSID：`OpenWrt`　密码：无
- 首次登录后：**系统 → Amlogic Service → Install OpenWrt** 可写入 eMMC

---

### 七、上游与许可

- 打包流程：[ophub/flippy-openwrt-actions](https://github.com/ophub/flippy-openwrt-actions)（GPL-2.0）
- 打包脚本：[unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit)
- 内核：[ophub/kernel](https://github.com/ophub/kernel)
- 本仓库 `openwrt_flippy.sh` / `action.yml` / `LICENSE` 均取自 ophub，原样保留
