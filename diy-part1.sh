#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# 工作目录 = openwrt/，执行时机 = ./scripts/feeds update -a 之前。
# 职责：
#   1) 追加自定义 feed              <- custom-feeds.list
#   2) 克隆自定义插件源码到 package/ <- custom-repos.list / $EXTRA_REPOS
#   3) 内置 UA3F 源码               <- $ENABLE_UA3F / $UA3F_REF
#
# Uncomment a feed source
# sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default
#
# Add a feed source
# echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
# echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default
# echo 'src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages' >>feeds.conf.default
#
set -uo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"

log() { echo -e "\033[1;32m[diy-part1]\033[0m $*"; }
warn() { echo -e "\033[1;33m[diy-part1][WARN]\033[0m $*"; }

# git clone 带 3 次重试；最后一个参数视为目标目录
clone_retry() {
	local dest="${!#}"
	local i
	for i in 1 2 3; do
		git clone "$@" && return 0
		warn "clone 第 $i 次失败，5s 后重试: $*"
		rm -rf "$dest"
		sleep 5
	done
	return 1
}

# 校验源码目录里确实有能被 OpenWrt 扫描到的 Makefile
check_pkg_dir() {
	local d="$1" f
	[ -d "$d" ] || return 1
	for f in "$d"/Makefile "$d"/*/Makefile; do
		[ -f "$f" ] && return 0
	done
	return 1
}

clone_repo_spec() {
	local url="$1" ref="$2" dest="$3" note="$4"
	[ -z "$url" ] && return 0
	[ -z "$dest" ] && dest="package/$(basename "${url%.git}")"

	if [ -d "$dest" ]; then
		log "已存在，跳过: $dest"
		return 0
	fi

	log "克隆 ${url} @ ${ref:-HEAD} -> ${dest}${note:+  ($note)}"
	if [ -n "$ref" ]; then
		clone_retry --depth 1 --branch "$ref" "$url" "$dest" ||
			clone_retry "$url" "$dest" || {
			warn "克隆失败: $url"
			return 1
		}
	else
		clone_retry --depth 1 "$url" "$dest" || {
			warn "克隆失败: $url"
			return 1
		}
	fi
	check_pkg_dir "$dest" || warn "$dest 下没找到 Makefile，OpenWrt 可能扫不到这个包"
	return 0
}

# ---------------------------------------------------------------- #
# 1) custom-feeds.list：每行一条 feed 定义，追加到 feeds.conf.default
#    例：src-git helloworld https://github.com/fw876/helloworld
# ---------------------------------------------------------------- #
FEED_LIST="$WS/custom-feeds.list"
if [ -f "$FEED_LIST" ]; then
	while IFS= read -r line; do
		line="${line%%#*}"
		line="$(echo "$line" | xargs)"
		[ -z "$line" ] && continue
		case "$line" in
		src-*)
			if grep -qF "$line" feeds.conf.default 2>/dev/null; then
				log "feed 已存在，跳过: $line"
				continue
			fi
			echo "$line" >>feeds.conf.default
			log "已追加 feed: $line"
			;;
		*) warn "非法 feed 行（需以 src- 开头）: $line" ;;
		esac
	done <"$FEED_LIST"
fi

# ---------------------------------------------------------------- #
# 2) custom-repos.list：每行「URL|REF|目标目录|备注」，REF 可留空
# ---------------------------------------------------------------- #
REPO_LIST="$WS/custom-repos.list"
if [ -f "$REPO_LIST" ]; then
	while IFS= read -r line; do
		line="${line%%#*}"
		line="$(echo "$line" | xargs)"
		[ -z "$line" ] && continue
		IFS='|' read -r _url _ref _dest _note <<<"$line"
		clone_repo_spec "$(echo "${_url:-}" | xargs)" "$(echo "${_ref:-}" | xargs)" \
			"$(echo "${_dest:-}" | xargs)" "$(echo "${_note:-}" | xargs)"
	done <"$REPO_LIST"
fi

# workflow_dispatch 临时传入：URL|REF|DEST，多条用 ; 分隔
if [ -n "${EXTRA_REPOS:-}" ]; then
	while IFS= read -r item; do
		item="$(echo "$item" | xargs)"
		[ -z "$item" ] && continue
		IFS='|' read -r _url _ref _dest _ <<<"$item"
		clone_repo_spec "$(echo "${_url:-}" | xargs)" "$(echo "${_ref:-}" | xargs)" \
			"$(echo "${_dest:-}" | xargs)" "来自 EXTRA_REPOS"
	done < <(echo "$EXTRA_REPOS" | tr ';' '\n')
fi

# ---------------------------------------------------------------- #
# 3) UA3F（Advanced HTTP Rewriting Proxy）
#    - Makefile 在 package/UA3F/openwrt/Makefile，命中 package/*/*/Makefile 扫描规则
#    - 自带 LuCI 页面与 zh-cn 语言包，不存在独立的 luci-app-ua3f 包
#    - 仅 ENABLE_UA3F=true 时克隆，避免影响 23.05 等未替换 golang feed 的老分支
# ---------------------------------------------------------------- #
if [ "${ENABLE_UA3F:-false}" = "true" ]; then
	UA3F_REF="${UA3F_REF:-master}"
	UA3F_REPO="${UA3F_REPO:-https://github.com/SunBK201/UA3F.git}"
	clone_repo_spec "$UA3F_REPO" "$UA3F_REF" "package/UA3F" "UA3F"
	if [ -f package/UA3F/openwrt/Makefile ]; then
		log "UA3F 版本: $(sed -n 's/^PKG_VERSION:=//p' package/UA3F/openwrt/Makefile | head -1)"
	else
		warn "package/UA3F/openwrt/Makefile 不存在，UA3F 不会被编译"
	fi
else
	log "ENABLE_UA3F != true，跳过 UA3F"
fi

log "part1 完成"
