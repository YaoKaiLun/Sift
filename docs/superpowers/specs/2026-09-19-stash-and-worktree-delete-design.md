# Stash 侧栏与删除 worktree

**日期**：2026-09-19
**状态**：已确认（方案 1；后续小节按用户要求不再逐段确认）
**基线**：当前主分支

## 范围

| 切片 | 做什么 | 不做 |
|------|--------|------|
| Stash 列表 | 仓库分组末尾展示 `stashes`，空则隐藏，默认折叠 | 创建 stash、pop、改名、按 worktree 分列表 |
| 查看 | 点 stash 行，中栏只读文件列表 + diff，逻辑同未推送 commit | 暂存勾选、hunk 暂存/放弃 |
| 应用 | 右键「应用」→ `git stash apply`；工作区 `git status` 非空则拒绝 | 冲突解决、`--index`、应用到未选中的 worktree |
| 删除 stash | 右键「删除」→ `git stash drop` | 批量删除 |
| 删除 worktree | 链接 worktree 右键「删除工作树」；确认后 `git worktree remove` | 删主工作树、`--force`、删对应分支 |

约束沿用计划三：最低 macOS 15、鼠标可达、主线程不跑 git。

## 侧栏

- 每个仓库分组顺序：仓库行 → 全部 worktree（未推送 commit 仍挂在当前 worktree 下）→ `stashes`。
- `git stash list` 为空则不渲染该组。默认折叠。点箭头只展开/收起，不改变选中。
- stash 行展示 `git stash list` 的说明（例如 `WIP on feat: …`）。身份用 stash 的 commit SHA。
- 点 stash：进入只读查看。若当前 worktree 不属于该仓库，先切到该仓库主工作树。
- 点当前 worktree 行：退出 stash / commit 阅读，回到工作区文件列表。

## 应用与删除 stash

- 应用目标为当时选中的 worktree。`status` 含已跟踪或未跟踪改动则提示无法应用，不调用 `stash apply`。
- 应用成功后退出 stash 阅读，刷新该 worktree 工作区。stash 条目保留。
- 删除走 `stash drop`（按当前列表中匹配 SHA 的 `stash@{n}`）。正在阅读该条则退出阅读。

## 删除 worktree

- 仅链接 worktree 出现「删除工作树」。主工作树无此项。
- 确认框之后：该 worktree 的 `status` 非空则提示无法删除，不 `--force`。
- 命令从主工作树执行 `git worktree remove <path>`。删的是当前选中项时，切到该仓库剩余 worktree（优先主工作树）。
- 不删除对应分支，不把仓库移出侧栏。

## GitKit / RepoStore

- `StashInfo`：`sha`、`reflogSelector`、`message`。
- `GitRepository.stashes()` / `stashFiles(selector:)`（`stash show --name-status` / `--numstat`，含 `--include-untracked`）/ `applyStash` / `dropStash` / `hasUncommittedChanges` / `removeWorktree(at:)`。
- `RepositoryEntry.stashes` 随 `worktree list` 一起刷新。
- `selectedStash` 与 `selectedCommit` 互斥。`isReadingSnapshot` 为真时禁止写操作，文件选择 id 使用 snapshot SHA。
- 友好错误走现有 `errorMessage` alert。
