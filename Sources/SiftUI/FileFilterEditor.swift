import SwiftUI
import DiffEngine
import RepoStore

struct FileFilterEditor: View {
    @Environment(RepoStore.self) private var store
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行一条 glob。匹配文件名；以 / 结尾则匹配路径中的目录段。")
                .font(Theme.secondaryFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(Theme.codeFont)
                .frame(minWidth: 280, minHeight: 200)
            HStack {
                Button("恢复默认") {
                    text = FileFilter.defaultPatterns.joined(separator: "\n")
                    commit()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            text = store.fileFilterPatterns.joined(separator: "\n")
        }
        .onDisappear { commit() }
    }

    private func commit() {
        store.fileFilterPatterns = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
