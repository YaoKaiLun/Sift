import SwiftUI

/// 中栏里一次未推送提交的完整说明。主题一行，正文可滚动。
struct CommitMessageBlock: View {
    let subject: String
    let messageBody: String

    init(subject: String, body: String) {
        self.subject = subject
        self.messageBody = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subject)
                .font(Theme.headerFont)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !messageBody.isEmpty {
                ScrollView {
                    Text(messageBody)
                        .font(Theme.secondaryFont)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Theme.sidebarRowHeight * 7, alignment: .top)
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
