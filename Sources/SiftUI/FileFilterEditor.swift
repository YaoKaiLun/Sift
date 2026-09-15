import SwiftUI
import DiffEngine
import RepoStore
import SiftLocalization

struct FileFilterEditor: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(Theme.codeFont)
                .frame(minWidth: 280, minHeight: 200)
            HStack {
                Button(L10n.restoreDefaults) {
                    text = FileFilter.defaultPatterns.joined(separator: "\n")
                }
                .buttonStyle(BorderedActionButtonStyle())
                Spacer(minLength: 0)
                Button(L10n.applyFilter) {
                    apply()
                }
                .buttonStyle(BorderedActionButtonStyle())
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            text = store.fileFilterPatterns.joined(separator: "\n")
        }
    }

    private func apply() {
        store.fileFilterPatterns = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        store.hidesFilteredFiles = true
        dismiss()
    }
}
