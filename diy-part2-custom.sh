#!/bin/bash
#
# File name: diy-part2-custom.sh
# Description: 通用「自定义插件软件包」启用脚本
#
# 执行时机：openwrt/.config 已就位、make defconfig 之前，工作目录 = openwrt/
# 作用：把要编进固件的包写成 CONFIG_PACKAGE_xxx=y，注入 openwrt/.config。
#       因为后面紧跟 make defconfig，defconfig 会保留这些已存在的合法符号。
#
set -uo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
LIST_FILE="$WS/custom-packages.list"
CFG=".config"

log() { echo -e "\033[1;32m[diy-part2-custom]\033[0m $*"; }
warn() { echo -e "\033[1;33m[diy-part2-custom][WARN]\033[0m $*"; }

[ -f "$CFG" ] || {
	echo "::error::找不到 openwrt/.config，请确认 workdir 为 openwrt/"
	exit 1
}

# 把一个符号置为 =y：处理 未出现 / 已 =y / # ... is not set 三种情况
enable_sym() {
	local sym="$1"
	[ -z "$sym" ] && return 0
	case "$sym" in CONFIG_*) ;; *) sym="CONFIG_PACKAGE_$sym" ;; esac

	if grep -qE "^# ${sym} is not set" "$CFG"; then
		sed -i "s|^# ${sym} is not set|${sym}=y|" "$CFG"
		log "启用(替换 not set): $sym"
	elif grep -qE "^${sym}=" "$CFG"; then
		sed -i "s|^${sym}=.*|${sym}=y|" "$CFG"
		log "启用(覆盖原值):   $sym"
	else
		echo "${sym}=y" >>"$CFG"
		log "启用(新增行):     $sym"
	fi
}

# ---------------------------------------------------------------- #
# 1) UA3F 及其依赖（UA3F 自带 LuCI 页面 + zh-cn 语言包，
#    不存在独立的 luci-app-ua3f 包，符号就是 CONFIG_PACKAGE_ua3f）
#    仅当 ENABLE_UA3F=true 时启用
# ---------------------------------------------------------------- #
if [ "${ENABLE_UA3F:-false}" = "true" ]; then
	for s in \
		CONFIG_PACKAGE_ua3f \
		CONFIG_PACKAGE_luci-compat \
		CONFIG_PACKAGE_iptables \
		CONFIG_PACKAGE_iptables-mod-extra \
		CONFIG_PACKAGE_iptables-mod-ipopt \
		CONFIG_PACKAGE_iptables-mod-tproxy \
		CONFIG_PACKAGE_iptables-mod-nfqueue \
		CONFIG_PACKAGE_ipset \
		CONFIG_PACKAGE_kmod-nf-conntrack-netlink \
		CONFIG_PACKAGE_kmod-nft-tproxy \
		CONFIG_PACKAGE_kmod-nft-queue \
		CONFIG_PACKAGE_kmod-nft-socket; do
		enable_sym "$s"
	done

	# UA3F 的 Build/Prepare 调用裸命令 po2lmo，而 po2lmo 由 luci-base 的 host build 提供。
	# luci.mk 会给 luci 系包自动加 luci-base/host 依赖，UA3F 是第三方包没有，必须自己补，
	# 否则 make -j 并行时 UA3F 可能先于 po2lmo 构建 -> "po2lmo: not found"。
	UA3F_MK="package/UA3F/openwrt/Makefile"
	if [ -f "$UA3F_MK" ]; then
		if grep -q '^PKG_BUILD_DEPENDS:=golang/host$' "$UA3F_MK"; then
			sed -i 's|^PKG_BUILD_DEPENDS:=golang/host$|PKG_BUILD_DEPENDS:=golang/host luci-base/host|' "$UA3F_MK"
			log "已给 UA3F 补 PKG_BUILD_DEPENDS += luci-base/host"
		elif grep -q 'luci-base/host' "$UA3F_MK"; then
			log "UA3F 已有 luci-base/host 构建依赖"
		else
			warn "未匹配到 UA3F 的 PKG_BUILD_DEPENDS 行，po2lmo 依赖需靠 workflow 里的预构建步骤保证"
		fi
	else
		warn "$UA3F_MK 不存在，跳过 UA3F 构建依赖补丁"
	fi
fi

# ---------------------------------------------------------------- #
# 2) custom-packages.list：每行一个包
#    写法 A：CONFIG_PACKAGE_luci-app-xxx=y（完整符号）
#    写法 B：luci-app-xxx（自动补 CONFIG_PACKAGE_ 前缀并置 y）
# ---------------------------------------------------------------- #
if [ -f "$LIST_FILE" ]; then
	while IFS= read -r line; do
		line="${line%%#*}"
		line="$(echo "$line" | xargs)"
		[ -z "$line" ] && continue
		case "$line" in
		*=y) enable_sym "${line%%=*}" ;;
		*=m) enable_sym "${line%%=*}" ;;
		*) enable_sym "$line" ;;
		esac
	done <"$LIST_FILE"
else
	warn "未找到 $LIST_FILE，仅处理内置清单"
fi

# ---------------------------------------------------------------- #
# 3) workflow input extra_packages（空格/逗号分隔）
# ---------------------------------------------------------------- #
if [ -n "${EXTRA_PACKAGES:-}" ]; then
	for s in $(echo "$EXTRA_PACKAGES" | tr ',;' '  '); do
		enable_sym "$s"
	done
fi

# ---------------------------------------------------------------- #
# 4) 汇总校验：确认目标符号在 .config 中确实为 =y
# ---------------------------------------------------------------- #
echo "-------- 关键符号校验 --------"
for sym in CONFIG_PACKAGE_ua3f CONFIG_PACKAGE_luci-compat CONFIG_PACKAGE_iptables \
	CONFIG_PACKAGE_iptables-mod-tproxy CONFIG_PACKAGE_ipset; do
	if grep -qE "^${sym}=y" "$CFG"; then
		echo "  [OK]   $sym=y"
	else
		warn "$sym 未为 =y（若源里无此包则正常，否则需检查）"
	fi
done
echo "------------------------------"

log "part2-custom 完成，共注入 $(grep -cE '^CONFIG_PACKAGE_(ua3f|iptables|ipset|kmod-nft|kmod-nf-conntrack-netlink)' "$CFG") 条相关符号"
