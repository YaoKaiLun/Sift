#!/usr/bin/env bash
# 生成一个有 1000 个改动文件的仓库，用于性能测试。
# 用法：make-large-fixture.sh <目标目录>
set -euo pipefail

TARGET="${1:?用法: make-large-fixture.sh <目标目录>}"
FILE_COUNT=1000
LINES_PER_FILE=200

rm -rf "$TARGET"
mkdir -p "$TARGET"
cd "$TARGET"

git init -q -b main
git config user.email "perf@sift.local"
git config user.name "Sift Perf"
git config commit.gpgsign false

for i in $(seq 1 "$FILE_COUNT"); do
  dir="src/module$((i % 20))/sub$((i % 7))"
  mkdir -p "$dir"
  seq 1 "$LINES_PER_FILE" | sed "s/^/line /" > "$dir/file$i.ts"
done

# 再放一个大文件，验证折叠规则确实拦住了它。
seq 1 50000 | sed 's/^/generated line /' > pnpm-lock.yaml

git add -A
git commit -q -m "baseline"

# 每个文件改一行，制造 1000 个改动文件。
for i in $(seq 1 "$FILE_COUNT"); do
  dir="src/module$((i % 20))/sub$((i % 7))"
  sed -i '' '100s/.*/line 100 MODIFIED/' "$dir/file$i.ts"
done

# lockfile 必须出现在 status 里，折叠测试才能拿到它。
sed -i '' '1s/.*/generated line 1 MODIFIED/' pnpm-lock.yaml

echo "已在 $TARGET 生成 $FILE_COUNT 个改动文件"
