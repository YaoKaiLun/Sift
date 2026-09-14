#!/usr/bin/env bash
# Cursor Cloud Agent 环境安装脚本。
#
# 重要背景：Sift 是一个原生 macOS 应用，最低系统 macOS 15（AppKit / SwiftUI / CoreServices/FSEvents /
# os.OSAllocatedUnfairLock / Darwin）。它无法在 Linux 上构建或运行——完整的
# `swift build` / `swift test` / 运行 App 必须在装有 Xcode 26（Swift 6.2）的 macOS 上完成。
#
# Cloud Agent 跑在 Linux 上，因此本脚本只做力所能及的事：装好 Linux 版 Swift 6.2 工具链，
# 让编辑、SourceKit-LSP、语法检查与 SwiftPM 清单校验可用，并校验 Package.swift 能被解析。
# 脚本是幂等的：Swift 已安装时跳过下载。
set -euo pipefail

SWIFT_VERSION="6.2"
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/${SWIFT_TAG}/${SWIFT_TAG}-${SWIFT_PLATFORM}.tar.gz"
SWIFT_ROOT="/opt/swift"
SWIFT_BIN="${SWIFT_ROOT}/usr/bin"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 安装 Swift 运行/编译所需的系统依赖"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libz3-dev pkg-config tzdata unzip zlib1g-dev

if [ ! -x "${SWIFT_BIN}/swift" ]; then
    echo "==> 下载 Swift ${SWIFT_VERSION} 工具链（Linux / ${SWIFT_PLATFORM}）"
    tmp_tarball="$(mktemp /tmp/swift-toolchain.XXXXXX.tar.gz)"
    curl -fSL --retry 4 -o "${tmp_tarball}" "${SWIFT_URL}"
    echo "==> 解压到 ${SWIFT_ROOT}"
    sudo mkdir -p "${SWIFT_ROOT}"
    sudo tar xzf "${tmp_tarball}" -C "${SWIFT_ROOT}" --strip-components=1
    rm -f "${tmp_tarball}"
else
    echo "==> Swift 工具链已存在，跳过下载"
fi

echo "==> 将 Swift 工具链软链到 /usr/local/bin"
sudo ln -sf \
    "${SWIFT_BIN}/swift" \
    "${SWIFT_BIN}/swiftc" \
    "${SWIFT_BIN}/sourcekit-lsp" \
    "${SWIFT_BIN}/swift-build" \
    "${SWIFT_BIN}/swift-test" \
    "${SWIFT_BIN}/swift-package" \
    /usr/local/bin/

echo "==> Swift 版本"
swift --version

echo "==> 校验 SwiftPM 清单 (Package.swift)"
# 只做清单解析与依赖解析——这两步不依赖 Apple 框架，在 Linux 上可用。
# 不跑 `swift build` / `swift test`：源码依赖 macOS 专有框架，只能在 macOS 上构建。
( cd "${repo_root}" && swift package dump-package > /dev/null && swift package resolve )

echo "==> 环境就绪：Swift 工具链可用于编辑 / LSP / 清单校验。"
echo "    注意：构建、测试与运行 Sift 需在 macOS（Xcode 26 / Swift 6.2）上执行 Scripts/preflight.sh。"
