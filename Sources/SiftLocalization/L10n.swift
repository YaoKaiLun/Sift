import Foundation
import os

/// 用户可见文案。系统首选语言以 `zh` 开头时用中文，否则用英文。
public enum L10n {
    public enum Language: Sendable {
        case chinese
        case english
    }

    /// 测试可覆盖；生产代码不要赋值。
    public static var languageOverride: Language? {
        get { overrideBox.withLock { $0 } }
        set { overrideBox.withLock { $0 = newValue } }
    }

    private static let overrideBox = OSAllocatedUnfairLock<Language?>(initialState: nil)

    public static var language: Language {
        if let languageOverride { return languageOverride }
        let preferred = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
        return preferred.lowercased().hasPrefix("zh") ? .chinese : .english
    }

    public static var usesChinese: Bool { language == .chinese }

    private static func t(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }

    // MARK: - 侧栏

    public static var repositories: String { t("仓库", "Repositories") }
    public static var addRepository: String { t("添加仓库", "Add Repository") }
    public static var addRepositoryEllipsis: String { t("添加仓库…", "Add Repository…") }
    public static var add: String { t("添加", "Add") }
    public static var chooseGitRepository: String { t("选择一个 Git 仓库目录", "Choose a Git repository") }
    public static var noRepositories: String { t("还没有仓库", "No Repositories") }
    public static var noRepositoriesHint: String { t("点右上角的 + 添加", "Click + in the top right to add one") }
    public static var removeRepository: String { t("移除此仓库", "Remove Repository") }
    public static var pinRepository: String { t("置顶仓库", "Pin Repository") }
    public static var unpinRepository: String { t("取消置顶", "Unpin Repository") }
    public static var branch: String { t("分支", "Branch") }
    public static var stashes: String { t("stashes", "stashes") }
    public static var applyStash: String { t("应用", "Apply") }
    public static var deleteStash: String { t("删除", "Delete") }
    public static var deleteWorktree: String { t("删除工作树", "Delete Worktree") }
    public static var deleteWorktreeTitle: String { t("删除工作树？", "Delete Worktree?") }
    public static var deleteWorktreeMessage: String {
        t("工作树目录会从磁盘移除，对应分支仍会保留。",
          "The worktree directory will be removed from disk. The branch will be kept.")
    }
    public static var cannotApplyStashWithLocalChanges: String {
        t("当前工作区有未提交改动，无法应用 stash。",
          "The working tree has local changes, so the stash can't be applied.")
    }
    public static var cannotRemoveDirtyWorktree: String {
        t("该工作树有未提交改动，无法删除。",
          "This worktree has local changes, so it can't be deleted.")
    }
    public static var cannotRemoveMainWorktree: String {
        t("不能删除主工作树。", "The main worktree can't be deleted.")
    }
    public static var appearance: String { t("外观", "Appearance") }
    public static var followSystem: String { t("跟随系统", "System") }
    public static var lightAppearance: String { t("浅色", "Light") }
    public static var darkAppearance: String { t("深色", "Dark") }

    // MARK: - 文件列表

    public static var changes: String { t("改动", "Changes") }
    public static var staged: String { t("已暂存", "Staged") }
    public static var unstaged: String { t("未暂存", "Unstaged") }
    public static var toggleSidebar: String { t("显示或隐藏侧边栏", "Show or Hide Sidebar") }
    public static var filterFiles: String { t("过滤文件", "Filter Files") }
    public static var clearFilter: String { t("取消过滤", "Clear Filter") }
    public static var toggleFileView: String { t("切换平铺视图与树视图", "Toggle List and Tree View") }
    public static var selectWorktree: String { t("选择一个工作树", "Select a Worktree") }
    public static var noChanges: String { t("没有改动", "No Changes") }
    public static var noFilesAfterFilter: String { t("过滤后没有文件", "No Files Match the Filter") }
    public static var delete: String { t("删除", "Delete") }
    public static var binary: String { t("二进制", "Binary") }
    public static var restoreDefaults: String { t("恢复默认", "Restore Defaults") }
    public static var applyFilter: String { t("应用过滤", "Apply Filter") }

    public static func deleteUntrackedTitle(count: Int) -> String {
        if count == 1 {
            return t("删除未跟踪文件？", "Delete Untracked File?")
        }
        return t("删除 \(count) 个未跟踪文件？", "Delete \(count) Untracked Files?")
    }

    public static func deleteUntrackedMessage(paths: String) -> String {
        t("\(paths)\n此操作无法从 git 恢复。",
          "\(paths)\nThis cannot be recovered from Git.")
    }

    public static func deleteFiles(count: Int) -> String {
        count == 1
            ? t("删除文件", "Delete File")
            : t("删除 \(count) 个文件", "Delete \(count) Files")
    }

    public static func discardWorktreeChanges(count: Int) -> String {
        count == 1
            ? t("放弃修改", "Discard Changes")
            : t("放弃 \(count) 个文件的修改", "Discard Changes in \(count) Files")
    }

    // MARK: - Diff

    public static var selectFile: String { t("选择一个文件", "Select a File") }
    public static var noTextDiff: String { t("此文件没有文本差异", "No Text Diff") }
    public static var binaryFile: String { t("二进制文件", "Binary File") }
    public static var modeChangeOnly: String { t("只有文件权限变化", "Mode Change Only") }
    public static var diff: String { t("差异", "Diff") }
    public static var switchToSingleFile: String { t("切换为单文件", "Switch to Single File") }
    public static var switchToContinuous: String { t("切换为连续滚动", "Switch to Continuous Scroll") }
    public static var blameUnavailableContinuous: String { t("连续滚动模式下不可用", "Unavailable in Continuous Scroll") }
    public static var blameUnavailableImage: String { t("图片预览不可用", "Unavailable for Image Preview") }
    public static var hideBlame: String { t("隐藏 blame 侧槽", "Hide Blame Gutter") }
    public static var showBlame: String { t("显示 blame 侧槽", "Show Blame Gutter") }
    public static var find: String { t("查找", "Find") }
    public static var findEllipsis: String { t("查找…", "Find…") }
    public static var viewAnyway: String { t("仍要查看", "View Anyway") }
    public static var stageHunk: String { t("暂存区块", "Stage Hunk") }
    public static var unstageHunk: String { t("取消暂存", "Unstage") }
    public static var discardHunk: String { t("放弃区块", "Discard Hunk") }
    public static var explain: String { t("解释", "Explain") }
    public static var explainSelection: String { t("解释这段", "Explain Selection") }
    public static var copyCodeReference: String { t("复制代码引用", "Copy Code Reference") }
    public static var showInFinder: String { t("在 Finder 中显示", "Show in Finder") }
    public static var old: String { t("旧", "Old") }
    public static var new: String { t("新", "New") }
    public static var imageTooLarge: String { t("图片过大，无法预览", "Image is too large to preview") }

    public static func collapsedNote(reason: String) -> String {
        t("这是生成文件或体积过大的文件（\(reason)），已默认折叠。",
          "This generated or oversized file (\(reason)) is collapsed by default.")
    }

    public static func collapsedStub(reason: String) -> String {
        t("（已折叠：\(reason)）", "(Collapsed: \(reason))")
    }

    public static func modeChangeNote(oldMode: String, newMode: String) -> String {
        t("只有文件权限变化  \(oldMode) → \(newMode)",
          "Mode change only  \(oldMode) → \(newMode)")
    }

    public static func matchingRule(_ rule: String) -> String {
        t("匹配规则 \(rule)", "Matched rule \(rule)")
    }

    public static func lineCount(_ count: Int) -> String {
        t("共 \(count) 行", "\(count) lines")
    }

    public static func fileSizeKB(_ kilobytes: Int) -> String {
        t("共 \(kilobytes) KB", "\(kilobytes) KB")
    }

    public static var modified: String { t("已修改", "Modified") }
    public static var added: String { t("新增", "Added") }
    public static var deleted: String { t("已删除", "Deleted") }
    public static var renamed: String { t("已重命名", "Renamed") }
    public static var copied: String { t("已复制", "Copied") }
    public static var typeChanged: String { t("类型变化", "Type Changed") }
    public static var unmerged: String { t("冲突", "Conflict") }
    public static var untracked: String { t("未跟踪", "Untracked") }

    // MARK: - 解释与设置

    public static var modelSettings: String { t("模型配置", "Model Settings") }
    public static var modelSettingsEllipsis: String { t("模型配置…", "Model Settings…") }
    public static var close: String { t("关闭", "Close") }
    public static var save: String { t("保存", "Save") }
    public static var endpoint: String { t("接口地址", "Endpoint") }
    public static var model: String { t("模型", "Model") }
    public static var modelPrompt: String { t("例如 gpt-4o 或 openai/gpt-4o", "e.g. gpt-4o or openai/gpt-4o") }
    public static var enterAPIKey: String { t("请输入 API Key", "Enter API Key") }
    public static var hideSecret: String { t("隐藏密钥", "Hide Secret") }
    public static var showSecret: String { t("显示密钥", "Show Secret") }
    public static var explainHint: String { t("选中代码后点「解释这段」。", "Select code, then click Explain Selection.") }
    public static var thinking: String { t("思考中...", "Thinking...") }
    public static var followUpPlaceholder: String { t("追问同一选区…", "Ask a follow-up about this selection…") }
    public static var send: String { t("发送", "Send") }
    public static var followUp: String { t("追问", "Follow-up") }
    public static var displayMenu: String { t("显示", "View") }

    // MARK: - 更新

    public static var checkForUpdates: String { t("检查更新…", "Check for Updates…") }
    public static var cancelDownload: String { t("取消下载", "Cancel Download") }
    public static var update: String { t("更新", "Update") }
    public static var downloading: String { t("下载中…", "Downloading…") }
    public static var restart: String { t("重启", "Restart") }
    public static var restartToInstall: String { t("重启并安装更新", "Restart and Install Update") }
    public static var checkUpdatesTitle: String { t("检查更新", "Check for Updates") }

    public static func downloadVersion(_ version: String) -> String {
        t("下载 \(version)", "Download \(version)")
    }

    public static func updateReady(_ version: String) -> String {
        t("\(version) 已就绪 — 点击重启", "\(version) is ready — click to restart")
    }

    public static func upToDate(_ version: String) -> String {
        t("已是最新版本（\(version)）。", "You're on the latest version (\(version)).")
    }

    public static var noInstallableDMG: String {
        t("找到了 Release，但没有可安装的 DMG。",
          "A release was found, but it has no installable DMG.")
    }

    public static var cannotCheckUpdates: String {
        t("无法检查更新，请稍后重试。", "Couldn't check for updates. Try again later.")
    }

    public static var cannotInstallUpdate: String {
        t("无法安装更新，请到 GitHub Release 手动下载。",
          "Couldn't install the update. Download it from the GitHub release.")
    }

    // MARK: - 通用与错误

    public static var somethingWentWrong: String { t("出错了", "Something Went Wrong") }
    public static var ok: String { t("好", "OK") }

    public static func cannotAddRepository(_ detail: String) -> String {
        t("无法添加仓库：\(detail)", "Couldn't add repository: \(detail)")
    }

    public static func cannotLoadDiff(_ detail: String) -> String {
        t("无法加载 diff：\(detail)", "Couldn't load the diff: \(detail)")
    }

    public static func cannotReadStatus(_ detail: String) -> String {
        t("无法读取文件状态：\(detail)", "Couldn't read file status: \(detail)")
    }

    public static func cannotDeleteTracked(_ path: String) -> String {
        t("无法删除已跟踪文件：\(path)", "Can't delete a tracked file: \(path)")
    }

    public static func cannotOpenFile(_ path: String) -> String {
        t("无法打开文件：\(path)", "Couldn't open file: \(path)")
    }

    public static func cannotCompleteOperation(_ detail: String) -> String {
        t("无法完成操作：\(detail)", "Couldn't complete the operation: \(detail)")
    }

    public static func refuseDeleteOutside(_ path: String) -> String {
        t("拒绝删除仓库外的路径：\(path)", "Refusing to delete a path outside the repository: \(path)")
    }

    public static func refuseDeleteTracked(_ path: String) -> String {
        t("拒绝删除已跟踪文件：\(path)", "Refusing to delete a tracked file: \(path)")
    }

    public static var explainNotConfigured: String {
        t("请先在设置中填写 Base URL、API 密钥和模型。",
          "Fill in the endpoint, API key, and model in Settings first.")
    }

    public static func requestFailedHTTP(_ code: Int) -> String {
        t("请求失败（HTTP \(code)）。", "Request failed (HTTP \(code)).")
    }

    public static func networkError(_ detail: String) -> String {
        t("网络错误：\(detail)", "Network error: \(detail)")
    }

    public static func requestFailed(_ detail: String) -> String {
        t("请求失败：\(detail)", "Request failed: \(detail)")
    }
}
