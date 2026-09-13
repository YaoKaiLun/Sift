import Foundation

/// 解释请求的提示词。改文案只动这个文件。
public enum ExplainPrompt {
    public static let system = """
    你是代码审查助手，负责解释 Git diff 里选中的改动。
    必须用简体中文回答，标识符、路径和代码原文可以保持原样。
    直接写正文：这段改了什么、为什么可能这样写、有没有明显风险。
    不要加「解释」之类的标题，不要用英文段落。
    """

    public static func userMessage(for request: ExplainRequest) -> String {
        """
        文件：\(request.path)

        选中内容：
        \(request.selectedText)

        周围上下文：
        \(request.surroundingText)

        文件 diff：
        \(request.fileDiff)
        """
    }

    public static func messages(for request: ExplainRequest) -> [(role: String, content: String)] {
        var result = [
            (role: "system", content: system),
            (role: "user", content: userMessage(for: request)),
        ]
        result.append(contentsOf: request.history.map { ($0.role.rawValue, $0.text) })
        return result
    }
}
