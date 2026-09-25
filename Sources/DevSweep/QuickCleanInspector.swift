import Foundation

/// 读取 QuickCleanEntry 并生成磁盘快照。
///
/// 刷新常用清理页面只做三件事：检查存在性、捕获 FileIdentity、计算大小。
/// 绝不重新调用 CacheScanner——常用清理页面必须做到即时刷新，
/// 不需要为几条记录重新扫描整台电脑。
enum QuickCleanInspector {
    static func snapshot(for entry: QuickCleanEntry) -> QuickCleanSnapshot {
        let url = URL(fileURLWithPath: entry.path)
        let identity = FileIdentity.capture(url)
        guard let identity else {
            // FileIdentity 对不存在路径和符号链接都返回 nil；两者都不允许清理，
            // 显示为「当前无内容」。
            return QuickCleanSnapshot(entry: entry, exists: false, size: 0, fileIdentity: nil)
        }
        let size = CacheScanner.size(of: url)
        return QuickCleanSnapshot(entry: entry, exists: true, size: size, fileIdentity: identity)
    }

    static func snapshots(for entries: [QuickCleanEntry]) -> [QuickCleanSnapshot] {
        entries.map(snapshot(for:))
    }

    /// 为一键清理重新生成执行用的 CacheItem。expectedFileIdentity 必须是执行前
    /// 刚刚捕获的，绝不能复用旧扫描结果；只接受当前真实存在的普通目录，
    /// 符号链接和已消失的路径会被排除。删除仍然走 CacheCleaner + DeletionValidator。
    static func executableItems(for entries: [QuickCleanEntry]) -> [CacheItem] {
        entries.compactMap { entry in
            let url = URL(fileURLWithPath: entry.path)
            guard let identity = FileIdentity.capture(url), identity.kind == .directory else { return nil }
            return CacheItem(
                category: entry.category,
                name: entry.displayName,
                path: url,
                size: CacheScanner.size(of: url),
                details: url.devSweepDisplayPath,
                risk: .safe,
                kind: .trash,
                expectedFileIdentity: identity,
                note: "常用清理"
            )
        }
    }
}
