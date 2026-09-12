#!/usr/bin/env bash
# 构建、测试、性能门禁。CI 与本地提交前都跑这个。
# 任何一项失败都以非零退出码结束。
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 构建"
swift build

echo "==> 单元测试"
swift test --skip PerformanceTests

echo "==> 性能门禁"
swift test --filter LargeRepoPerformanceTests

echo "==> 全部通过"
