import Foundation
import GitKit

public indirect enum FileTreeNode: Sendable, Identifiable {
    case directory(name: String, path: String, children: [FileTreeNode])
    case file(FileStatus)

    public var id: String {
        switch self {
        case .directory(_, let path, _): "dir:" + path
        case .file(let status): "file:" + status.path
        }
    }
}

/// 把扁平的改动文件列表转成目录树。纯函数，没有任何副作用。
public enum FileTreeBuilder {
    /// - Parameter collapsingSingleChildDirectories: 为 true 时把只含一个子目录的
    ///   目录链压成一行（`apps/web/src`），避免 monorepo 里层层无意义的缩进。
    public static func build(from statuses: [FileStatus],
                             collapsingSingleChildDirectories: Bool) -> [FileTreeNode] {
        var root = MutableDirectory(name: "", path: "")
        for status in statuses {
            let components = status.path.split(separator: "/").map(String.init)
            root.insert(status: status, components: components, depth: 0)
        }
        var children = root.materialize()
        if collapsingSingleChildDirectories {
            children = children.map(collapse)
        }
        return children
    }

    private static func collapse(_ node: FileTreeNode) -> FileTreeNode {
        guard case .directory(let name, let path, let children) = node else { return node }
        // 恰好一个子节点且该子节点是目录时，把两层合成一层，然后继续往下压。
        if children.count == 1,
           case .directory(let childName, let childPath, let grandchildren) = children[0] {
            return collapse(.directory(name: "\(name)/\(childName)",
                                       path: childPath,
                                       children: grandchildren))
        }
        return .directory(name: name, path: path, children: children.map(collapse))
    }

    /// 构建期使用的可变中间结构。
    private struct MutableDirectory {
        let name: String
        let path: String
        var subdirectories: [String: MutableDirectory] = [:]
        var files: [FileStatus] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        mutating func insert(status: FileStatus, components: [String], depth: Int) {
            guard depth < components.count - 1 else {
                files.append(status)
                return
            }
            let childName = components[depth]
            let childPath = path.isEmpty ? childName : "\(path)/\(childName)"
            var child = subdirectories[childName] ?? MutableDirectory(name: childName, path: childPath)
            child.insert(status: status, components: components, depth: depth + 1)
            subdirectories[childName] = child
        }

        func materialize() -> [FileTreeNode] {
            let directoryNodes = subdirectories.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { FileTreeNode.directory(name: $0.name, path: $0.path,
                                              children: $0.materialize()) }
            let fileNodes = files
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                .map { FileTreeNode.file($0) }
            return directoryNodes + fileNodes
        }
    }
}
