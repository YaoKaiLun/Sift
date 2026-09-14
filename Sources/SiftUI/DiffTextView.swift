import SwiftUI
import AppKit
import GitKit

/// hunk 头上常显的暂存 / 取消暂存 / 丢弃。未跟踪、二进制、空、折叠不传。
/// 写操作由 store.mutate 忽略重入，按钮本身不因 isMutating 变灰，避免整排闪一次。
struct HunkActions {
    var showsStage: Bool
    var showsUnstage: Bool
    var showsDiscard: Bool
    var onStage: (String) -> Void
    var onUnstage: (String) -> Void
    var onDiscard: (String) -> Void
}

/// NSTextView 的 SwiftUI 封装。
///
/// 为什么不用 SwiftUI 的 Text：SwiftUI 没有能处理上万行文档的文本视图。
/// NSTextView 给的是二十年优化过的文本布局、原生选中、无障碍和滚动惯性。
///
/// 关键性能约定：更新文档时用 `replaceCharacters` 整体替换，
/// 并且**绝不**在滚动过程中改动 text storage。计划二的语法高亮必须走
/// attribute-only 的覆盖路径，不能重建文档，否则滚动位置会跳。
struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    var hunkActions: HunkActions?
    var onSelectionChange: ((NSRange) -> Void)?
    var onExplain: ((String, String) -> Void)?
    var onVisibleRangeChange: ((NSRange) -> Void)?
    var preserveVisibleRect: Bool = false
    var revealRange: NSRange? = nil
    var onDidReveal: (() -> Void)?
    var onExpandCollapsedFile: ((String) -> Void)?
    var hunkIsStaged: ((String) -> Bool?)?
    var showsBlame: Bool = false
    var blameByNewLine: [Int: BlameLine] = [:]
    var blameByFileID: [String: [Int: BlameLine]] = [:]
    var loadBlameCommit: ((BlameLine) async -> BlameCommitContent)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> DiffHostView {
        let container = DiffHostView(frame: .zero)
        container.coordinator = context.coordinator
        context.coordinator.install(in: container,
                                    document: document,
                                    hunkActions: hunkActions,
                                    onSelectionChange: onSelectionChange,
                                    onExplain: onExplain,
                                    onVisibleRangeChange: onVisibleRangeChange,
                                    preserveVisibleRect: preserveVisibleRect,
                                    revealRange: revealRange,
                                    onDidReveal: onDidReveal,
                                    onExpandCollapsedFile: onExpandCollapsedFile,
                                    hunkIsStaged: hunkIsStaged,
                                    showsBlame: showsBlame,
                                    blameByNewLine: blameByNewLine,
                                    blameByFileID: blameByFileID,
                                    loadBlameCommit: loadBlameCommit)
        return container
    }

    func updateNSView(_ container: DiffHostView, context: Context) {
        container.coordinator = context.coordinator
        context.coordinator.install(in: container,
                                    document: document,
                                    hunkActions: hunkActions,
                                    onSelectionChange: onSelectionChange,
                                    onExplain: onExplain,
                                    onVisibleRangeChange: onVisibleRangeChange,
                                    preserveVisibleRect: preserveVisibleRect,
                                    revealRange: revealRange,
                                    onDidReveal: onDidReveal,
                                    onExpandCollapsedFile: onExpandCollapsedFile,
                                    hunkIsStaged: hunkIsStaged,
                                    showsBlame: showsBlame,
                                    blameByNewLine: blameByNewLine,
                                    blameByFileID: blameByFileID,
                                    loadBlameCommit: loadBlameCommit)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document = DiffDocument(text: NSAttributedString(), hunkHeaders: [])
        var hunkActions: HunkActions?
        var onSelectionChange: ((NSRange) -> Void)?
        var onExplain: ((String, String) -> Void)?
        var onVisibleRangeChange: ((NSRange) -> Void)?
        var preserveVisibleRect = false
        var revealRange: NSRange?
        var onDidReveal: (() -> Void)?
        var onExpandCollapsedFile: ((String) -> Void)?
        var hunkIsStaged: ((String) -> Bool?)?
        var showsBlame = false
        var blameByNewLine: [Int: BlameLine] = [:]
        var blameByFileID: [String: [Int: BlameLine]] = [:]
        var loadBlameCommit: ((BlameLine) async -> BlameCommitContent)?
        private weak var container: NSView?
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private weak var rightScrollView: NSScrollView?
        private weak var rightTextView: NSTextView?
        private var overlay: HunkOverlayView?
        private var rightExplainOverlay: NSView?
        private var blameOverlay: BlameOverlayView?
        private var hunkActionRows: [String: NSStackView] = [:]
        private var hunkRowIdentities: [String: HunkRowIdentity] = [:]
        private var explainButton: NSButton?
        private weak var selectionTextView: NSTextView?
        private var isSplit = false
        private var isSyncing = false
        private var lastRevealedRange: NSRange?
        private var blameHits: [(rect: NSRect, line: BlameLine)] = []
        private var blamePopover: NSPopover?
        private var blameDetailTask: Task<Void, Never>?
        private var lastBlameDocumentIdentity: String = ""
        private var isRelayingOut = false
        private var isLayingOutHost = false
        private var lastInstalledHunkIDs: [String] = []
        private var lastReportedCharRange = NSRange(location: NSNotFound, length: 0)

        var blameHitRects: [NSRect] { blameHits.map(\.rect) }

        private struct HunkRowIdentity: Equatable {
            var showsStage: Bool
            var showsUnstage: Bool
            var showsDiscard: Bool
            var showsExplain: Bool
            var showsExpandCollapsed: Bool
        }

        func hostDidLayout() {
            guard let container, !isLayingOutHost else { return }
            isLayingOutHost = true
            defer { isLayingOutHost = false }
            if isSplit {
                if let split = container.subviews.compactMap({ $0 as? NSSplitView }).first,
                   split.frame != container.bounds {
                    split.frame = container.bounds
                }
                if let scrollView, overlay?.frame != scrollView.frame {
                    overlay?.frame = scrollView.frame
                }
            } else {
                if let scrollView, scrollView.frame != container.bounds {
                    scrollView.frame = container.bounds
                }
                if overlay?.frame != container.bounds {
                    overlay?.frame = container.bounds
                }
            }
            relayoutOverlay()
        }

        func install(in container: NSView,
                     document: DiffDocument,
                     hunkActions: HunkActions?,
                     onSelectionChange: ((NSRange) -> Void)?,
                     onExplain: ((String, String) -> Void)?,
                     onVisibleRangeChange: ((NSRange) -> Void)?,
                     preserveVisibleRect: Bool,
                     revealRange: NSRange?,
                     onDidReveal: (() -> Void)?,
                     onExpandCollapsedFile: ((String) -> Void)?,
                     hunkIsStaged: ((String) -> Bool?)?,
                     showsBlame: Bool,
                     blameByNewLine: [Int: BlameLine],
                     blameByFileID: [String: [Int: BlameLine]],
                     loadBlameCommit: ((BlameLine) async -> BlameCommitContent)?) {
            self.container = container
            self.document = document
            self.hunkActions = hunkActions
            self.onSelectionChange = onSelectionChange
            self.onExplain = onExplain
            self.onVisibleRangeChange = onVisibleRangeChange
            self.preserveVisibleRect = preserveVisibleRect
            self.revealRange = revealRange
            self.onDidReveal = onDidReveal
            self.onExpandCollapsedFile = onExpandCollapsedFile
            self.hunkIsStaged = hunkIsStaged
            self.showsBlame = showsBlame
            self.blameByNewLine = blameByNewLine
            self.blameByFileID = blameByFileID
            self.loadBlameCommit = loadBlameCommit
            let identity = blameDocumentIdentity()
            if !showsBlame || identity != lastBlameDocumentIdentity {
                cancelBlameDetailTask()
                blamePopover?.performClose(nil)
            }
            lastBlameDocumentIdentity = identity
            let wantSplit = document.splitRight != nil
            if container.subviews.isEmpty || wantSplit != isSplit {
                rebuildHierarchy(split: wantSplit)
            }
            applyBlameInsets()
            let origin = scrollView?.documentVisibleRect.origin
            if let textView {
                replaceText(in: textView, with: document.text, preserveVisibleRect: preserveVisibleRect)
            }
            if let rightTextView, let right = document.splitRight {
                replaceText(in: rightTextView, with: right, preserveVisibleRect: preserveVisibleRect)
            }
            if let revealRange {
                if revealRange != lastRevealedRange, let textView {
                    textView.scrollRangeToVisible(revealRange)
                    lastRevealedRange = revealRange
                    onDidReveal?()
                }
            } else {
                lastRevealedRange = nil
                if preserveVisibleRect, let origin, let scrollView {
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            relayoutOverlay()
            updateExplainButton()
            reportVisibleRange()
            let hunkIDs = document.hunkHeaders.map(\.id)
            let sameHunks = hunkIDs == lastInstalledHunkIDs
            lastInstalledHunkIDs = hunkIDs
            if !sameHunks {
                DispatchQueue.main.async { [weak self] in
                    self?.relayoutOverlay()
                    self?.reportVisibleRange()
                }
            }
        }

        private func rebuildHierarchy(split: Bool) {
            cancelBlameDetailTask()
            NotificationCenter.default.removeObserver(self)
            container?.subviews.forEach { $0.removeFromSuperview() }
            overlay = nil
            rightExplainOverlay = nil
            blameOverlay = nil
            removeAllHunkActionRows()
            lastInstalledHunkIDs = []
            explainButton = nil
            selectionTextView = nil
            scrollView = nil
            textView = nil
            rightScrollView = nil
            rightTextView = nil
            isSplit = split
            guard let container else { return }

            if split {
                let (leftScroll, leftText) = makeScrollView()
                let (rightScroll, rightText) = makeScrollView()
                scrollView = leftScroll
                textView = leftText
                rightScrollView = rightScroll
                rightTextView = rightText

                let splitView = NSSplitView()
                splitView.isVertical = true
                splitView.dividerStyle = .thin
                splitView.frame = container.bounds
                splitView.autoresizingMask = [.width, .height]
                splitView.addSubview(leftScroll)
                splitView.addSubview(rightScroll)
                container.addSubview(splitView)

                attachOverlay(to: leftScroll)
                attachExplainOverlay(to: rightScroll)
                attachBlameOverlay(to: rightScroll)
                observeScroll(leftScroll)
                observeScroll(rightScroll)
            } else {
                let (single, text) = makeScrollView()
                scrollView = single
                textView = text
                single.frame = container.bounds
                single.autoresizingMask = [.width, .height]
                container.addSubview(single)
                attachOverlay(to: single)
                attachBlameOverlay(to: single)
                observeScroll(single)
            }
        }

        private func makeScrollView() -> (NSScrollView, DiffCopyTextView) {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor

            let textView = DiffCopyTextView(frame: .zero)
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = true
            // 宽高都由 layout manager 按 usedRect 改，不要跟着 clip view 被拉高，
            // 否则后台排版会和 setNeedsDisplay 互相踢，主线程 100%。
            textView.autoresizingMask = []
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.allowsUndo = false
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            // 左边距和栏头标题对齐（Theme.horizontalPadding）。
            textView.textContainerInset = NSSize(width: Theme.horizontalPadding, height: 0)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.delegate = self
            // 不换行：宽度设为无限，靠横向滚动。
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.heightTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            textView.layoutManager?.backgroundLayoutEnabled = false
            textView.layoutManager?.allowsNonContiguousLayout = true
            textView.hunkCursorSource = self

            scrollView.documentView = textView
            return (scrollView, textView)
        }

        private func attachOverlay(to scrollView: NSScrollView) {
            let overlay = HunkOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = scrollView.frame
            overlay.coordinator = self
            // 必须和 scroll view 做兄弟。挂在 NSScrollView 上会被 tile()
            // 挤到滚动条槽里，全屏时按钮消失、窗口态时落到窗口底部。
            scrollView.superview?.addSubview(overlay, positioned: .above, relativeTo: scrollView)
            self.overlay = overlay
        }

        private func attachExplainOverlay(to scrollView: NSScrollView) {
            let overlay = PassthroughOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = scrollView.bounds
            scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
            rightExplainOverlay = overlay
        }

        private func attachBlameOverlay(to scrollView: NSScrollView) {
            cancelBlameDetailTask()
            let overlay = BlameOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = scrollView.bounds
            overlay.coordinator = self
            scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.blameOverlay = overlay
        }

        private func applyBlameInsets() {
            let extra = showsBlame ? BlameGutterMetrics.columnWidth : 0
            let inset = NSSize(width: Theme.horizontalPadding + extra, height: 0)
            textView?.textContainerInset = inset
            rightTextView?.textContainerInset = inset
        }

        private func observeScroll(_ scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(relayoutOverlay),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )
        }

        private func replaceText(in textView: NSTextView,
                                 with text: NSAttributedString,
                                 preserveVisibleRect: Bool) {
            guard let storage = textView.textStorage else { return }
            if storage.string == text.string {
                if !storage.isEqual(to: text) {
                    // attribute-only：同一段字符、新属性（含语法高亮第三遍）。不 replaceCharacters，滚动不跳。
                    storage.beginEditing()
                    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
                        storage.setAttributes(attrs, range: range)
                    }
                    storage.endEditing()
                }
            } else {
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
                storage.endEditing()
                if !preserveVisibleRect {
                    textView.scroll(NSPoint(x: 0, y: 0))
                }
                lastReportedCharRange = NSRange(location: NSNotFound, length: 0)
                sizeTextViewToDocument(textView)
            }
        }

        /// 用行数估高度，不要 `ensureLayout` 整篇文档。连续滚动把所有文件拼在一起，
        /// 全量排版会在滚动和语法高亮时把主线程卡住。
        private func sizeTextViewToDocument(_ textView: NSTextView) {
            guard let storage = textView.textStorage,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let inset = textView.textContainerInset
            let clip = textView.enclosingScrollView?.contentSize ?? .zero
            let used = layoutManager.usedRect(for: textContainer)
            let width = max(clip.width, ceil(used.maxX + inset.width * 2), textView.frame.width)
            let height = max(clip.height, estimatedDocumentHeight(storage.string, inset: inset))
            let size = NSSize(width: width, height: height)
            if abs(textView.frame.width - size.width) > 0.5
                || abs(textView.frame.height - size.height) > 0.5 {
                textView.setFrameSize(size)
            }
        }

        private func estimatedDocumentHeight(_ string: String, inset: NSSize) -> CGFloat {
            let ns = string as NSString
            var lines = 0
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                   options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                lines += 1
            }
            if ns.length > 0, ns.character(at: ns.length - 1) == 10 {
                lines += 1
            }
            if lines == 0 { lines = 1 }
            return ceil(CGFloat(lines) * Theme.codeLineHeight + inset.height * 2)
        }

        private func growTextViewIfNeeded(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let used = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            let neededWidth = ceil(used.maxX + inset.width * 2)
            let neededHeight = ceil(used.maxY + inset.height * 2)
            var size = textView.frame.size
            var changed = false
            if neededWidth > size.width + 0.5 {
                size.width = neededWidth
                changed = true
            }
            if neededHeight > size.height + 0.5 {
                size.height = neededHeight
                changed = true
            }
            if changed {
                textView.setFrameSize(size)
            }
        }

        @objc private func clipBoundsDidChange(_ notification: Notification) {
            if !isSyncing {
                syncVerticalScroll(from: notification)
            }
            if let textView {
                growTextViewIfNeeded(textView)
            }
            relayoutOverlay()
            reportVisibleRange()
        }

        private func reportVisibleRange() {
            guard let onVisibleRangeChange,
                  let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView else { return }
            let visible = textView.convert(scrollView.documentVisibleRect, from: scrollView)
            var rect = visible
            rect.origin.x -= textView.textContainerOrigin.x
            rect.origin.y -= textView.textContainerOrigin.y
            let glyphRange = layoutManager.glyphRange(
                forBoundingRectWithoutAdditionalLayout: rect, in: textContainer)
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard !NSEqualRanges(charRange, lastReportedCharRange) else { return }
            lastReportedCharRange = charRange
            onVisibleRangeChange(charRange)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            selectionTextView = textView
            onSelectionChange?(textView.selectedRange())
            updateExplainButton()
        }

        private func syncVerticalScroll(from notification: Notification) {
            guard isSplit,
                  let clip = notification.object as? NSClipView,
                  let left = scrollView,
                  let right = rightScrollView else { return }
            isSyncing = true
            defer { isSyncing = false }
            let y = clip.documentVisibleRect.origin.y
            if clip === left.contentView {
                var origin = right.documentVisibleRect.origin
                origin.y = y
                right.contentView.scroll(to: origin)
                right.reflectScrolledClipView(right.contentView)
            } else if clip === right.contentView {
                var origin = left.documentVisibleRect.origin
                origin.y = y
                left.contentView.scroll(to: origin)
                left.reflectScrolledClipView(left.contentView)
            }
        }

        deinit {
            blameDetailTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        private func cancelBlameDetailTask() {
            blameDetailTask?.cancel()
            blameDetailTask = nil
        }

        private func blameDocumentIdentity() -> String {
            let files = document.fileHeaders.map(\.id).joined(separator: ",")
            let hunks = document.hunkHeaders.map(\.id).joined(separator: ",")
            let ns = document.text.string as NSString
            let prefixLen = min(64, ns.length)
            let head = prefixLen == 0 ? "" : ns.substring(to: prefixLen)
            return "\(files)|\(hunks)|\(ns.length)|\(head)"
        }

        func mouseMoved(at _: NSPoint) {}

        func mouseExited() {}

        func hunkActionContains(windowPoint: NSPoint) -> Bool {
            guard let overlay else { return false }
            let local = overlay.convert(windowPoint, from: nil)
            return hunkActionRows.values.contains { !$0.isHidden && $0.frame.contains(local) }
        }

        @objc func relayoutOverlay() {
            guard !isRelayingOut else { return }
            isRelayingOut = true
            defer { isRelayingOut = false }
            if let scrollView, let overlay, overlay.frame != scrollView.frame {
                overlay.frame = scrollView.frame
            }
            overlay?.needsDisplay = true
            if isSplit {
                if let rightScrollView {
                    if blameOverlay?.frame != rightScrollView.bounds {
                        blameOverlay?.frame = rightScrollView.bounds
                    }
                    if rightExplainOverlay?.frame != rightScrollView.bounds {
                        rightExplainOverlay?.frame = rightScrollView.bounds
                    }
                }
            } else if let scrollView, blameOverlay?.frame != scrollView.bounds {
                blameOverlay?.frame = scrollView.bounds
            }
            rebuildBlameHits()
            if (selectionTextView ?? textView)?.selectedRange().length ?? 0 > 0 {
                updateExplainButton()
            } else {
                explainButton?.isHidden = true
            }
            syncHunkActionRows()
        }

        private func removeAllHunkActionRows() {
            hunkActionRows.values.forEach { $0.removeFromSuperview() }
            hunkActionRows.removeAll()
            hunkRowIdentities.removeAll()
        }

        private func syncHunkActionRows() {
            guard let overlay, let textView else { return }
            ensureVisibleTextLayout()
            var visible = Set<String>()
            let showsExplain = onExplain != nil
            let actions = hunkActions
            for header in document.hunkHeaders {
                guard let rect = DiffOverlayGeometry.headerRect(
                    characterRange: header.range, textView: textView, overlay: overlay),
                      rect.intersects(overlay.bounds) else { continue }
                let flags = actions.map { resolvedHunkFlags(for: header.id, actions: $0) }
                    ?? (stage: false, unstage: false, discard: false)
                guard flags.stage || flags.unstage || flags.discard || showsExplain else { continue }
                visible.insert(header.id)
                let identity = HunkRowIdentity(
                    showsStage: flags.stage,
                    showsUnstage: flags.unstage,
                    showsDiscard: flags.discard,
                    showsExplain: showsExplain,
                    showsExpandCollapsed: false)
                upsertHunkRow(id: header.id, identity: identity, headerRect: rect)
            }
            for header in document.fileHeaders where header.isCollapsed {
                guard let rect = DiffOverlayGeometry.headerRect(
                    characterRange: header.range, textView: textView, overlay: overlay),
                      rect.intersects(overlay.bounds) else { continue }
                visible.insert(header.id)
                let identity = HunkRowIdentity(
                    showsStage: false, showsUnstage: false, showsDiscard: false,
                    showsExplain: false, showsExpandCollapsed: true)
                upsertHunkRow(id: header.id, identity: identity, headerRect: rect)
            }
            for id in hunkActionRows.keys where !visible.contains(id) {
                hunkActionRows[id]?.removeFromSuperview()
                hunkActionRows.removeValue(forKey: id)
                hunkRowIdentities.removeValue(forKey: id)
            }
            if let window = overlay.window {
                window.invalidateCursorRects(for: overlay)
                window.invalidateCursorRects(for: textView)
            }
        }

        private func upsertHunkRow(id: String, identity: HunkRowIdentity, headerRect: NSRect) {
            guard let overlay else { return }
            let stack = hunkActionRows[id] ?? makeButtonStack()
            if hunkActionRows[id] == nil {
                overlay.addSubview(stack)
                hunkActionRows[id] = stack
            }
            if hunkRowIdentities[id] != identity {
                if identity.showsExpandCollapsed {
                    rebuildCollapsedButton(in: stack, hunkID: id)
                } else {
                    rebuildButtons(in: stack, identity: identity, hunkID: id)
                }
                hunkRowIdentities[id] = identity
            }
            place(stack, at: headerRect)
            overlay.window?.invalidateCursorRects(for: overlay)
            overlay.window?.invalidateCursorRects(for: stack)
        }

        @objc func stageClicked(_ sender: Any?) {
            guard let id = hunkID(from: sender) else { return }
            hunkActions?.onStage(id)
        }

        @objc func unstageClicked(_ sender: Any?) {
            guard let id = hunkID(from: sender) else { return }
            hunkActions?.onUnstage(id)
        }

        @objc func discardClicked(_ sender: Any?) {
            guard let id = hunkID(from: sender) else { return }
            hunkActions?.onDiscard(id)
        }

        @objc func expandCollapsedClicked(_ sender: Any?) {
            guard let id = hunkID(from: sender) else { return }
            onExpandCollapsedFile?(id)
        }

        @objc func explainHunkClicked(_ sender: Any?) {
            guard let id = hunkID(from: sender) else { return }
            var selected = ""
            var surrounding = ""
            if let header = document.hunkHeaders.first(where: { $0.id == id }),
               let storage = textView?.textStorage {
                let range = contentRange(afterHunk: header)
                selected = DiffDocumentBuilder.copyableString(from: storage, range: range)
                surrounding = DiffDocumentBuilder.copyableString(
                    from: storage,
                    range: DiffDocumentBuilder.surroundingRange(of: range, in: storage.string))
            }
            onExplain?(selected, surrounding)
        }

        private func hunkID(from sender: Any?) -> String? {
            if let view = sender as? NSView, let id = view.identifier?.rawValue, !id.isEmpty {
                return id
            }
            if let cell = sender as? NSCell,
               let id = cell.controlView?.identifier?.rawValue,
               !id.isEmpty {
                return id
            }
            return nil
        }

        private func contentRange(afterHunk header: DiffHunkHeader) -> NSRange {
            let start = header.range.location
            var end = document.text.length
            for other in document.hunkHeaders where other.range.location > start {
                end = min(end, other.range.location)
            }
            for file in document.fileHeaders where file.range.location > start {
                end = min(end, file.range.location)
            }
            return NSRange(location: start, length: max(0, end - start))
        }

        func drawFileHeaders(in overlay: NSView) {
            guard let textView, !document.fileHeaders.isEmpty else { return }
            ensureVisibleTextLayout()
            for header in document.fileHeaders {
                guard let rect = DiffOverlayGeometry.headerRect(
                    characterRange: header.range, textView: textView, overlay: overlay) else { continue }
                let bar = DiffOverlayGeometry.fullBleedBar(from: rect, overlayBounds: overlay.bounds)
                guard bar.intersects(overlay.bounds) else { continue }
                paintFileHeader(header, in: bar)
            }
        }

        func drawHunkHeaders(in overlay: NSView) {
            guard let textView, !document.hunkHeaders.isEmpty else { return }
            ensureVisibleTextLayout()
            for header in document.hunkHeaders {
                guard let rect = DiffOverlayGeometry.headerRect(
                    characterRange: header.range, textView: textView, overlay: overlay) else { continue }
                let bar = DiffOverlayGeometry.fullBleedBar(from: rect, overlayBounds: overlay.bounds)
                guard bar.intersects(overlay.bounds) else { continue }
                paintHunkHeader(header, in: bar)
            }
        }

        private func paintChromeBar(_ bar: NSRect) {
            NSColor.controlBackgroundColor.setFill()
            bar.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1).fill()
            NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1).fill()
        }

        private func paintHunkHeader(_ header: DiffHunkHeader, in bar: NSRect) {
            paintChromeBar(bar)
            let ns = document.text.string as NSString
            guard header.range.location + header.range.length <= ns.length else { return }
            var text = ns.substring(with: header.range)
            if text.hasSuffix("\n") { text.removeLast() }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let maxWidth = max(0, bar.width - Theme.horizontalPadding * 2 - 168)
            let title = text as NSString
            let size = title.size(withAttributes: attrs)
            let drawRect = NSRect(
                x: bar.minX + Theme.horizontalPadding,
                y: bar.midY - size.height / 2,
                width: maxWidth,
                height: size.height)
            title.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                       attributes: attrs)
        }

        private func paintFileHeader(_ header: DiffFileHeader, in bar: NSRect) {
            paintChromeBar(bar)

            let padding = Theme.horizontalPadding
            FileChangeChrome.drawChip(
                kind: header.changeKind,
                at: NSPoint(x: padding, y: bar.midY - Theme.statusChipSize.height / 2))

            var x = padding + Theme.statusColumnWidth + 6
            let ui = NSFont.systemFont(ofSize: 12)
            let uiBold = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let path = header.path as NSString
            let name = path.lastPathComponent
            let dir = path.deletingLastPathComponent
            if !dir.isEmpty {
                let dirText = (dir + "/") as NSString
                let dirAttrs: [NSAttributedString.Key: Any] = [
                    .font: ui,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let dirSize = dirText.size(withAttributes: dirAttrs)
                dirText.draw(
                    at: NSPoint(x: x, y: bar.midY - dirSize.height / 2),
                    withAttributes: dirAttrs)
                x += dirSize.width
            }
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: uiBold,
                .foregroundColor: NSColor.labelColor,
            ]
            let nameSize = (name as NSString).size(withAttributes: nameAttrs)
            (name as NSString).draw(
                at: NSPoint(x: x, y: bar.midY - nameSize.height / 2),
                withAttributes: nameAttrs)
            x += nameSize.width

            let statsFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            if let added = header.added, added > 0 {
                let text = "  +\(added)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: statsFont,
                    .foregroundColor: NSColor.systemGreen,
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x, y: bar.midY - size.height / 2), withAttributes: attrs)
                x += size.width
            }
            if let deleted = header.deleted, deleted > 0 {
                let text = " −\(deleted)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: statsFont,
                    .foregroundColor: NSColor.systemRed,
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x, y: bar.midY - size.height / 2), withAttributes: attrs)
            }

            if header.changeKind == .untracked {
                let badge = "New" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: ui,
                    .foregroundColor: NSColor.systemGreen,
                ]
                let size = badge.size(withAttributes: attrs)
                badge.draw(
                    at: NSPoint(x: bar.maxX - padding - size.width, y: bar.midY - size.height / 2),
                    withAttributes: attrs)
            }
        }

        private func resolvedHunkFlags(for id: String, actions: HunkActions) -> (stage: Bool, unstage: Bool, discard: Bool) {
            if let hunkIsStaged {
                switch hunkIsStaged(id) {
                case true: return (false, true, false)
                case false: return (true, false, true)
                case nil: return (false, false, false)
                }
            }
            return (actions.showsStage, actions.showsUnstage, actions.showsDiscard)
        }

        private func place(_ stack: NSStackView, at headerRect: NSRect) {
            guard let overlay else { return }
            stack.isHidden = false
            stack.layoutSubtreeIfNeeded()
            stack.frame = DiffOverlayGeometry.actionRowFrame(
                headerRect: headerRect, size: stack.fittingSize, overlayBounds: overlay.bounds)
        }

        private func ensureVisibleTextLayout() {
            guard let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let visible = textView.convert(scrollView.documentVisibleRect, from: scrollView)
            layoutManager.ensureLayout(forBoundingRect: visible, in: textContainer)
        }

        private func makeButtonStack() -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 2
            return stack
        }

        private func rebuildCollapsedButton(in stack: NSStackView, hunkID: String) {
            stack.arrangedSubviews.forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            stack.addArrangedSubview(makeButton(title: "仍要查看",
                                                action: #selector(expandCollapsedClicked(_:)),
                                                hunkID: hunkID))
        }

        private func rebuildButtons(in stack: NSStackView, identity: HunkRowIdentity, hunkID: String) {
            stack.arrangedSubviews.forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if identity.showsStage {
                stack.addArrangedSubview(makeButton(title: "暂存区块",
                                                    action: #selector(stageClicked(_:)),
                                                    hunkID: hunkID))
            }
            if identity.showsUnstage {
                stack.addArrangedSubview(makeButton(title: "取消暂存",
                                                    action: #selector(unstageClicked(_:)),
                                                    hunkID: hunkID))
            }
            if identity.showsDiscard {
                stack.addArrangedSubview(makeButton(title: "放弃区块",
                                                    action: #selector(discardClicked(_:)),
                                                    hunkID: hunkID))
            }
            if identity.showsExplain {
                stack.addArrangedSubview(makeButton(title: "解释",
                                                    action: #selector(explainHunkClicked(_:)),
                                                    hunkID: hunkID))
            }
        }

        private func makeButton(title: String, action: Selector, hunkID: String) -> NSButton {
            HunkActionButton(title: title, target: self, action: action, hunkID: hunkID)
        }

        @objc func explainClicked() {
            guard let textView = selectionTextView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let selected = DiffDocumentBuilder.copyableString(from: storage, range: range)
            let surroundingRange = DiffDocumentBuilder.surroundingRange(
                of: range, in: storage.string)
            let surrounding = DiffDocumentBuilder.copyableString(from: storage, range: surroundingRange)
            onExplain?(selected, surrounding)
        }

        private func updateExplainButton() {
            guard let textView = selectionTextView ?? self.textView,
                  textView.selectedRange().length > 0,
                  let host = explainHost(for: textView),
                  let rect = selectionRect(range: textView.selectedRange(), textView: textView, in: host)
            else {
                explainButton?.isHidden = true
                return
            }
            let button = explainButton ?? makeExplainButton()
            if button.superview !== host {
                button.removeFromSuperview()
                host.addSubview(button, positioned: .above, relativeTo: nil)
                explainButton = button
            }
            button.isHidden = false
            button.sizeToFit()
            let size = button.fittingSize
            let padding: CGFloat = 4
            var x = min(rect.maxX + padding, host.bounds.width - size.width - 8)
            x = max(8, x)
            let y: CGFloat
            if host.isFlipped {
                y = min(rect.maxY + padding, max(8, host.bounds.height - size.height - 8))
            } else {
                y = max(8, rect.minY - size.height - padding)
            }
            button.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        private func explainHost(for textView: NSTextView) -> NSView? {
            if textView === rightTextView {
                return rightExplainOverlay ?? rightScrollView
            }
            return overlay ?? scrollView
        }

        private func makeExplainButton() -> NSButton {
            HunkActionButton(title: "解释这段", target: self, action: #selector(explainClicked), hunkID: "explain-selection")
        }

        private func selectionRect(range: NSRange, textView: NSTextView, in host: NSView) -> NSRect? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return host.convert(rect, from: textView)
        }

        func blameHit(at pointInOverlay: NSPoint) -> BlameLine? {
            blameHits.first(where: { $0.rect.contains(pointInOverlay) })?.line
        }

        func drawBlame(in _: NSView) {
            guard showsBlame else { return }
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            for hit in blameHits {
                let name = String(hit.line.author.prefix(BlameGutterMetrics.maxAuthorChars)) as NSString
                let size = name.size(withAttributes: attrs)
                let y = hit.rect.midY - size.height / 2
                name.draw(at: NSPoint(x: hit.rect.minX + 2, y: y), withAttributes: attrs)
            }
        }

        func blameClicked(at pointInOverlay: NSPoint) {
            guard let hit = blameHits.first(where: { $0.rect.contains(pointInOverlay) }) else { return }
            blameDetailTask?.cancel()
            let line = hit.line
            let rect = hit.rect
            blameDetailTask = Task { [weak self] in
                let content: BlameCommitContent
                if let loader = self?.loadBlameCommit {
                    content = await loader(line)
                } else {
                    content = BlameCommitContent.fallback(for: line)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.showsBlame, !Task.isCancelled else { return }
                    self.showBlamePopover(content, relativeTo: rect)
                }
            }
        }

        private func rebuildBlameHits() {
            guard showsBlame, let overlay = blameOverlay else {
                if !blameHits.isEmpty {
                    blameHits = []
                    blameOverlay?.needsDisplay = true
                }
                return
            }
            blameHits = []
            defer { blameOverlay?.needsDisplay = true }
            let target = isSplit ? rightTextView : textView
            let hostScroll = isSplit ? rightScrollView : scrollView
            guard let target, let storage = target.textStorage,
                  let layoutManager = target.layoutManager,
                  let textContainer = target.textContainer,
                  let hostScroll else { return }

            // 只扫视口里已经排好的行。glyphRange(forCharacterRange:) 会强制补洞，
            // 补洞又改 text view 高度、再发 boundsDidChange，blame 开着时会把主线程吃满。
            let visible = target.convert(hostScroll.documentVisibleRect, from: hostScroll)
            var rect = visible
            rect.origin.x -= target.textContainerOrigin.x
            rect.origin.y -= target.textContainerOrigin.y
            let glyphRange = layoutManager.glyphRange(
                forBoundingRectWithoutAdditionalLayout: rect, in: textContainer)
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return }

            let ns = storage.string as NSString
            let firstUnlaid = layoutManager.firstUnlaidCharacterIndex()
            var location = charRange.location
            let end = min(NSMaxRange(charRange), ns.length)
            while location < end {
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                defer { location = NSMaxRange(lineRange) }
                if lineRange.location >= firstUnlaid { break }
                guard let parsed = parseDiffBodyLine(storage, range: lineRange),
                      let blameNumber = parsed.blameLineNumber else { continue }
                guard let line = blameLine(number: blameNumber, at: lineRange.location) else { continue }
                guard let lineRect = lineRectInOverlay(for: lineRange, textView: target, overlay: overlay)
                else { continue }
                let column = NSRect(
                    x: lineRect.minX,
                    y: lineRect.minY,
                    width: BlameGutterMetrics.columnWidth,
                    height: max(lineRect.height, 1))
                blameHits.append((column, line))
            }
            if let overlay = blameOverlay {
                DispatchQueue.main.async {
                    overlay.window?.invalidateCursorRects(for: overlay)
                }
            }
        }

        private func blameLine(number: Int, at location: Int) -> BlameLine? {
            if !blameByFileID.isEmpty, let fileID = fileID(containing: location) {
                return blameByFileID[fileID]?[number]
            }
            return blameByNewLine[number]
        }

        private func fileID(containing location: Int) -> String? {
            var current: String?
            for header in document.fileHeaders where header.range.location <= location {
                current = header.id
            }
            return current
        }

        private func parseDiffBodyLine(_ storage: NSAttributedString, range: NSRange) -> (marker: Character, blameLineNumber: Int?)? {
            let ns = storage.string as NSString
            var gutter = ""
            var marker: Character?
            var isHeader = false
            storage.enumerateAttributes(in: range) { attrs, run, _ in
                let role = attrs[.siftRole] as? String
                if role == "header" {
                    isHeader = true
                } else if role == "gutter" {
                    gutter += ns.substring(with: run)
                } else if role == "code", marker == nil {
                    marker = ns.substring(with: run).first
                }
            }
            guard !isHeader, !gutter.isEmpty, let marker else { return nil }
            return (marker, DiffDocumentBuilder.blameLineNumber(fromGutter: gutter, marker: marker))
        }

        private func lineRectInOverlay(for range: NSRange,
                                        textView: NSTextView,
                                        overlay: NSView) -> NSRect? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            // 未排到的行不要强制补齐，否则会和 clipBoundsDidChange 互相踢。
            guard NSMaxRange(range) <= layoutManager.firstUnlaidCharacterIndex() else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return nil }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = 0
            rect.size.width = BlameGutterMetrics.columnWidth
            rect.origin.y += textView.textContainerOrigin.y
            return overlay.convert(rect, from: textView)
        }

        private func showBlamePopover(_ content: BlameCommitContent, relativeTo rect: NSRect) {
            guard showsBlame, let overlay = blameOverlay else { return }
            blamePopover?.performClose(nil)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 480, height: 380)
            popover.contentViewController = NSHostingController(
                rootView: BlamePopoverView(content: content))
            blamePopover = popover
            popover.show(relativeTo: rect, of: overlay, preferredEdge: .maxX)
        }
    }
}

/// 文字按钮：无系统 bezel，hover 用和工具栏一样的圆角底。
/// 自己收 mouseDown/Up 并 `sendAction`：关掉 cell highlight 后系统不一定会发 action。
final class HunkActionButton: NSButton {
    private var hovering = false
    private var pressed = false

    convenience init(title: String, target: AnyObject?, action: Selector, hunkID: String) {
        self.init(title: title, target: target, action: action)
        identifier = NSUserInterfaceItemIdentifier(hunkID)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 11, weight: .medium)
        contentTintColor = .secondaryLabelColor
        attributedTitle = Self.title(title, hovering: false, pressed: false)
        wantsLayer = true
        layer?.masksToBounds = true
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 10, height: Theme.codeLineHeight)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshAppearance()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refreshAppearance()
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
        refreshAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        refreshAppearance()
        if inside {
            _ = sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = attributedTitle
        let size = title.size()
        let origin = NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(.toNearestOrAwayFromZero),
            y: ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero))
        title.draw(at: origin)
    }

    private func refreshAppearance() {
        attributedTitle = Self.title(title, hovering: hovering, pressed: pressed)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private static func title(_ string: String, hovering: Bool, pressed: Bool) -> NSAttributedString {
        let color: NSColor = (hovering || pressed) ? .labelColor : .secondaryLabelColor
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ])
    }
}

/// SwiftUI 用 Auto Layout 改 representable 的尺寸，不会走子视图 autoresizing。
/// 这里在 layout 里把 scroll view 和 overlay 钉满，全屏/缩放才跟得上。
final class DiffHostView: NSView {
    weak var coordinator: DiffTextView.Coordinator?

    override func layout() {
        super.layout()
        coordinator?.hostDidLayout()
    }
}

/// 分栏右栏：只承载「解释这段」，不处理 hunk hover。
private final class PassthroughOverlayView: NSView {
    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for subview in subviews where !subview.isHidden && subview.frame.contains(local) {
            if let hit = subview.hitTest(local) {
                return hit
            }
        }
        return nil
    }
}

/// 叠在 scroll view 上：只拦截按钮点击，其余事件穿透给 NSTextView。
private final class HunkOverlayView: NSView {
    weak var coordinator: DiffTextView.Coordinator?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        coordinator?.drawHunkHeaders(in: self)
        coordinator?.drawFileHeaders(in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.mouseMoved(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.mouseExited()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for subview in subviews where !subview.isHidden && subview.frame.contains(local) {
            if let hit = subview.hitTest(local) {
                return hit
            }
        }
        return nil
    }

    override func resetCursorRects() {
        discardCursorRects()
        for subview in subviews where !subview.isHidden {
            addCursorRect(subview.frame, cursor: .pointingHand)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if subviews.contains(where: { !$0.isHidden && $0.frame.contains(local) }) {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }
}

/// 叠在 scroll view 左侧：blame 短名列，只拦截这一列的点击。
private final class BlameOverlayView: NSView {
    weak var coordinator: DiffTextView.Coordinator?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        coordinator?.drawBlame(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if coordinator?.blameHit(at: local) != nil {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.blameClicked(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard let coordinator else { return }
        for hit in coordinator.blameHitRects {
            addCursorRect(hit, cursor: .pointingHand)
        }
    }
}

enum BlameGutterMetrics {
    static let maxAuthorChars = 8
    static var columnWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil(font.maximumAdvancement.width * CGFloat(maxAuthorChars)) + 8
    }
}

struct BlameCommitContent {
    let author: String
    let timeText: String
    let header: String
    let patch: String

    static func fallback(for line: BlameLine) -> BlameCommitContent {
        BlameCommitContent(
            author: line.author,
            timeText: BlameCommitContent.formatted(line.authorTime),
            header: line.summary,
            patch: "")
    }

    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct BlamePopoverView: View {
    let content: BlameCommitContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(content.author)
                    .font(.headline)
                Text(content.timeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !content.header.isEmpty {
                    Text(content.header)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !content.patch.isEmpty {
                    Divider()
                    Text(content.patch)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 360)
    }
}

/// 复制时丢掉 gutter 行号，保留 +/- 与正文。
/// 只读 diff 文本。方向键交给文件列表切行，不移动插入点。
final class DiffCopyTextView: NSTextView {
    weak var hunkCursorSource: DiffTextView.Coordinator?

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return false }
        let copied = DiffDocumentBuilder.copyableString(from: storage, range: selectedRange())
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(copied, forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        writeSelection(to: pboard, type: .string)
    }

    override func cursorUpdate(with event: NSEvent) {
        if hunkCursorSource?.hunkActionContains(windowPoint: event.locationInWindow) == true {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if hunkCursorSource?.hunkActionContains(windowPoint: event.locationInWindow) == true {
            NSCursor.pointingHand.set()
        }
    }
}
