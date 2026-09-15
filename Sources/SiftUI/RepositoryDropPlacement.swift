import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 侧栏拖放落点：相对整个仓库组（名称行 + 展开的工作树）的中线。
/// 上半插入组前、下半插入组后，插入线画在组与组之间的缝上。
enum RepositoryDropPlacement {
    static func insertAfter(locationY: CGFloat, groupHeight: CGFloat) -> Bool {
        guard groupHeight > 0 else { return false }
        return locationY > groupHeight / 2
    }
}

/// 不用裸路径当 `String` 拖：系统会把它升级成 file URL，`dropDestination(for: String.self)` 接不住。
struct RepositoryDragItem: Codable, Transferable, Equatable {
    var path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct RepositoryReorderDropDelegate: DropDelegate {
    let groupHeight: CGFloat
    let onPreview: (Bool) -> Void
    let onExit: () -> Void
    let onDrop: (String, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.json])
    }

    func dropEntered(info: DropInfo) {
        preview(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        preview(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onExit()
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = RepositoryDropPlacement.insertAfter(
            locationY: info.location.y, groupHeight: groupHeight)
        guard let provider = info.itemProviders(for: [.json]).first else { return false }
        _ = provider.loadTransferable(type: RepositoryDragItem.self) { result in
            DispatchQueue.main.async {
                if case .success(let item) = result {
                    onDrop(item.path, after)
                }
            }
        }
        onExit()
        return true
    }

    private func preview(_ info: DropInfo) {
        onPreview(RepositoryDropPlacement.insertAfter(
            locationY: info.location.y, groupHeight: groupHeight))
    }
}

/// Finder 式插入线：落在组与组之间的缝上，2pt 强调色加左侧圆点。
struct DropInsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .allowsHitTesting(false)
    }
}
