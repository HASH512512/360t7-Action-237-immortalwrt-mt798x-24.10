# 自定义插件软件包 / UA3F 使用说明

本仓库在原 P3TERX 模板基础上，加了**清单驱动的自定义插件机制**，并以 UA3F 作为范例内置。
主构建入口仍是 `Build immortalwrt24.10-6.6 360T7 Latest Passwall+Sing-box`（360T7 / 6.6 内核 / Passwall+Sing-box）。

---

## 1. 加插件只要三个地方

| 需求 | 改哪里 |
|---|---|
| 启用一个**已存在于源码树 / feeds** 的包 | 在 `custom-packages.list` 里加一行 |
| 加一个**新 feed 源**里的包 | `custom-feeds.list` 加 feed + `custom-packages.list` 加包名 |
| 加一个**第三方 GitHub 仓库**里的插件 | `custom-repos.list` 加一行「URL\|分支\|目标目录」，再在 `custom-packages.list` 启用 |

格式细节：

```text
# custom-packages.list —— 两种写法都支持，以 # 开头为注释
luci-theme-argon                  # 简写
CONFIG_PACKAGE_luci-app-ttyd=y    # 完整符号

# custom-feeds.list —— 一行一条 feed 定义
src-git helloworld https://github.com/fw876/helloworld

# custom-repos.list —— URL|REF|目标目录|备注，REF 留空取默认分支
https://github.com/SunBK201/UA3F.git|master|package/UA3F|UA3F
```

---

## 2. UA3F

UA3F 是「Advanced HTTP Rewriting Proxy」，用于重写 User-Agent（校园网多设备检测、透明 UA 修改等场景）。

- 源码在 `diy-part1.sh` 里通过 `git clone https://github.com/SunBK201/UA3F.git package/UA3F` 取回，
  只取源码不取 feed，**仅当 `ENABLE_UA3F=true` 时执行**（避免影响 23.05 等未替换 golang feed 的分支）。
- UA3F 的 Makefile 位于 `package/UA3F/openwrt/Makefile`，命中 OpenWrt `package/*/*/Makefile` 扫描规则。
- UA3F **自带 LuCI 页面和 zh-cn 语言包**，符号就是 `CONFIG_PACKAGE_ua3f`，不存在独立的 `luci-app-ua3f` 包。
- 需要的依赖：`luci-compat`、`iptables` 系列、`ipset`、`kmod-nf-conntrack-netlink`，
  以及 nft 模式用的 `kmod-nft-tproxy` / `kmod-nft-queue` / `kmod-nft-socket`，都由 `diy-part2-custom.sh` 一并启用。
- 刷机后路径：**服务 → UA3F**。默认监听 `1080`，服务模式 `HTTP / SOCKS5 / TPROXY / REDIRECT / NFQUEUE`。

> UA3F 要求 `go >= 1.23.0`，6.6 这条线已把 golang feed 换成 `kenzok8/golang -b 1.25`，无需再动。

### 触发构建时的可调参数

`workflow_dispatch` 提供四个输入：

| 输入 | 默认 | 说明 |
|---|---|---|
| `build_ua3f` | `true` | 设 `false` 即退回原版固件（不克隆、不启用 UA3F） |
| `ua3f_ref` | `master` | 想锁版本填 `v3.6.0` 这类 tag |
| `extra_repos` | 空 | 临时追加插件源码，`URL\|REF\|目标目录`，多条用 `;` 分隔 |
| `extra_packages` | 空 | 临时追加启用的包，如 `luci-theme-argon luci-app-ttyd` |

---

## 3. 执行链路（相对原模板新增的部分）

```
Load custom feeds & sources   -> diy-part1.sh
  ├─ custom-feeds.list        追加 feed 到 feeds.conf.default
  ├─ custom-repos.list        克隆第三方插件到 package/
  └─ UA3F                     ENABLE_UA3F=true 时克隆
Update feeds                  （原样：替换 golang feed 为 kenzok8/golang 1.25）
Install feeds                 （原样：passwall 系列直连 clone，删掉 feeds 自带版本）
Load custom configuration     -> 2410-6.6-diy-part2-6-1-pw.sh（原样）
Enable custom packages        -> diy-part2-custom.sh               【新增】
  ├─ 注入 CONFIG_PACKAGE_xxx=y 到 openwrt/.config
  └─ 给 UA3F 的 Makefile 补 PKG_BUILD_DEPENDS += luci-base/host
Download package              make defconfig + UA3F 硬校验          【改】
Prepare tools & toolchain     make tools/install + toolchain/install 【新增】
Prebuild po2lmo               预构建 luci-base host 工具            【新增】
Compile the firmware          make + ua3f ipk 产物核对              【改】
```

### 三个必须保留的细节

1. **`Prepare tools & toolchain` + `Prebuild po2lmo` 不能删，顺序也不能动。**
   UA3F 的 `Build/Prepare` 直接调用裸命令 `po2lmo` 生成中文语言包，而 `po2lmo` 由 `luci-base` 的 **host build** 提供。
   `immortalwrt/luci/luci.mk` 里 `PKG_BUILD_DEPENDS += ... luci-base/host` **只对 luci 系包生效**，
   第三方包没有这个依赖，`make -j$(nproc)` 并行时会出现 `po2lmo: not found`。

   > 踩坑记录：直接在 `Load custom configuration` 之后调 `make package/feeds/luci/luci-base/host/compile`
   > 会**失败**——此时 `tools` / `toolchain` 还没 `install`，make 直接退出，`po2lmo` 压根没生成。
   > 所以必须先 `make tools/install` + `make toolchain/install`（这两步本来就是 `make world` 的前置工作，
   > 提前做**不增加总时长**），而且这两步要放在 `make defconfig` 之后。

2. **`diy-part2-custom.sh` 里的 `PKG_BUILD_DEPENDS` 补丁是双保险。**
   它让 `po2lmo` 在 OpenWrt 自己的依赖图里排在 UA3F 之前，
   即使预构建那步出问题，`make` 的依赖顺序和原有的 `make -j8 || make -j1` 重试也能兜住。

3. **`grep -q '^CONFIG_PACKAGE_ua3f=y' .config` 硬校验不能删。**
   `make defconfig` 对依赖不满足的符号是**静默丢弃**的，没有这道闸门就会产出一个「构建成功但没有 UA3F」的固件。

---

## 4. 构建日志里应该看到

```
[diy-part1] 克隆 https://github.com/SunBK201/UA3F.git @ v3.6.0 -> package/UA3F  (UA3F)
[diy-part1] UA3F 版本: 3.6.0
[diy-part2-custom] 启用(替换 not set): CONFIG_PACKAGE_ua3f
[diy-part2-custom] 已给 UA3F 补 PKG_BUILD_DEPENDS += luci-base/host
  [OK]   CONFIG_PACKAGE_ua3f=y
po2lmo OK
---- ua3f 相关 ipk ----
-rw-r--r--  ...  ua3f_3.6.0-1_aarch64_cortex-a53.ipk
```

---

## 4. 构建日志里应该看到

```
[diy-part1] 克隆 https://github.com/SunBK201/UA3F.git @ master -> package/UA3F  (UA3F)
[diy-part1] UA3F 版本: 3.6.0
[diy-part2-custom] 启用(替换 not set): CONFIG_PACKAGE_ua3f
  [OK]   CONFIG_PACKAGE_ua3f=y
po2lmo OK
---- ua3f 相关 ipk ----
-rw-r--r--  ...  ua3f_3.6.0-1_aarch64_cortex-a53.ipk
```

Release 说明末尾会自动追加一行：
`内置插件：UA3F 3.6.0（LuCI 路径：服务 → UA3F；默认监听 1080，服务模式 SOCKS5/HTTP/TPROXY/REDIRECT/NFQUEUE）`

---

## 5. 已知边界

- **与 passwall 共存**：UA3F 推荐走 TPROXY；NFQUEUE 模式与部分代理有冲突。
- **`kmod-nft-*` 符号**：若某分支源里没有这些符号，`defconfig` 会静默丢弃，不影响构建。
- **23.05 系列**：与 6.6 共用 `diy-part1.sh`，但因为没有传 `ENABLE_UA3F`，会跳过 UA3F，行为不变。
  若要在 23.05 上启用，除了传 `ENABLE_UA3F=true`，还要在该 workflow 的 `Update feeds` 步骤里加上替换 golang feed 的两行（UA3F 需要 `go >= 1.23`）。
- **其他 workflow（5.4 / Q30Pro / CMCC-A10）**：默认不受影响。要接入只需在自己 workflow 的 env 里补
  `CUSTOM_PKG_SH: diy-part2-custom.sh` / `ENABLE_UA3F: "true"`，并在 `Load custom configuration` 之后加两个 step（照抄 6.6 那条）。
- **可选加固**：给 UA3F 的 Makefile 补 `PKG_SOURCE` + `PKG_HASH`（上游是注释状态，靠本地目录编译），
  可让构建更可复现，避免依赖 runner 联网拉 Go module。
