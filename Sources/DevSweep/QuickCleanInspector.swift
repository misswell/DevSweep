import Foundation

/// 读取 QuickCleanEntry 并生成磁盘快照。
///
/// 刷新常用清理页面只检查已收藏路径；有模拟器时额外查询登记及构建/测试状态。
/// 绝不重新调用 CacheScanner——常用清理页面必须做到即时刷新，
/// 不需要为几条记录重新扫描整台电脑。
enum QuickCleanInspector {
    /// 版本升级后的安装包重新绑定结果；未重新绑定的条目原样保留。
    struct Resolution {
        let entries: [QuickCleanEntry]
        let notes: [String: String]
    }

    static let manualPaths = [
        "/Library/Developer/CoreSimulator/Caches",
        "/Library/Developer/Xcode/DocumentationCache"
    ]

    /// 更新安装包的版本家族键：`Orca-1.4.230-arm64-mac.zip` 和
    /// `Orca-1.4.240-arm64-mac.zip` 得到同一个键。只归一化文件名里的版本号，
    /// 父目录必须完全一致，避免跨应用或跨更新器扩大清理授权。
    static func versionFamilyKey(for url: URL) -> String? {
        guard let regex = versionTokenRegex else { return nil }
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard regex.firstMatch(in: name, range: range) != nil else { return nil }
        let normalized = regex.stringByReplacingMatches(in: name, range: range, withTemplate: "#")
        return url.deletingLastPathComponent().standardizedFileURL.path + "/" + normalized
    }

    private static let versionTokenRegex = try? NSRegularExpression(pattern: #"\d+(?:[._]\d+)+"#)

    /// 旧版本安装包被更新器移除后，只在同一父目录里找唯一一个通过更新残留
    /// 校验的新版本文件，并把条目重新指向它；旧文件仍存在时保持精确路径，
    /// 多个候选时不猜测，留给用户重新确认。
    static func resolveVersionedEntries(
        _ entries: [QuickCleanEntry],
        whitelistedPaths: [URL] = []
    ) -> Resolution {
        var resolved: [QuickCleanEntry] = []
        var notes: [String: String] = [:]
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)
            guard entry.isUpdateArchive,
                  let familyKey = versionFamilyKey(for: url),
                  FileIdentity.capture(url) == nil
            else {
                resolved.append(entry)
                continue
            }

            let directory = url.deletingLastPathComponent()
            guard !PathWhitelist.contains(directory, in: whitelistedPaths),
                  !PathWhitelist.contains(url, in: whitelistedPaths),
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                      options: []
                  )
            else {
                resolved.append(entry)
                continue
            }

            let candidates = children.filter {
                isVersionFamilyCandidate($0, familyKey: familyKey, whitelistedPaths: whitelistedPaths)
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                if candidates.count > 1 {
                    notes[entry.id] = "检测到 \(candidates.count) 个新版本安装包，请确认后重新加入常用清理"
                }
                resolved.append(entry)
                continue
            }
            resolved.append(QuickCleanEntry(
                path: QuickCleanRegistry.key(for: candidate),
                displayName: entry.displayName,
                category: entry.category,
                dateAdded: entry.dateAdded,
                targetKind: entry.targetKind,
                identifier: entry.identifier
            ))
        }
        return Resolution(entries: resolved, notes: notes)
    }

    private static func isVersionFamilyCandidate(
        _ candidate: URL,
        familyKey: String,
        whitelistedPaths: [URL]
    ) -> Bool {
        guard versionFamilyKey(for: candidate) == familyKey,
              !PathWhitelist.contains(candidate, in: whitelistedPaths),
              CacheScanner.softwareUpdateResidueName(for: candidate, isDirectory: false) != nil,
              (try? DeletionValidator.validateQuickCleanRegistration(
                  path: candidate, allowRegularFile: true
              )) != nil
        else { return false }
        return FileIdentity.capture(candidate)?.kind == .regular
    }

    static func registrationKind(
        for item: CacheItem, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> QuickCleanEntry.TargetKind? {
        if item.kind == .simulatorDevice {
            return SimulatorCleanupExecutor.matches(path: item.path, udid: item.identifier, home: home)
                ? .simulatorDevice : nil
        }
        if item.kind == .trash, item.risk == .manual,
           manualPaths.contains(item.path.standardizedFileURL.path) { return .manual }
        guard item.kind == .trash, item.risk != .manual else { return nil }
        if item.category == "Rust / Tauri 项目", CacheScanner.cargoBuildFileProfile(for: item.path) != nil {
            return .cargoBuildFile
        }
        if FileIdentity.capture(item.path)?.kind == .regular,
           item.category == "应用缓存", item.name == "软件更新安装包",
           CacheScanner.softwareUpdateResidueName(for: item.path, isDirectory: false) != nil {
            return .updateArchive
        }
        return FileIdentity.capture(item.path)?.kind == .directory ? .directory : nil
    }

    static func isReservedPath(_ path: URL, home: URL) -> Bool {
        let reserved = manualPaths.map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")]
        return reserved.contains {
            XCTestDeviceLocator.isInside(path, of: $0) || XCTestDeviceLocator.isInside($0, of: path)
        }
    }

    private static func validatedIdentity(for entry: QuickCleanEntry) -> FileIdentity? {
        guard entry.isAutomatic else { return nil }
        let url = URL(fileURLWithPath: entry.path)
        guard (try? DeletionValidator.validateQuickCleanRegistration(
            path: url, allowRegularFile: entry.allowsRegularFile
        )) != nil,
              let identity = FileIdentity.capture(url),
              identity.kind == (entry.allowsRegularFile ? .regular : .directory) else { return nil }
        if entry.isCargoBuildFile, CacheScanner.cargoBuildFileProfile(for: url) == nil { return nil }
        if entry.isUpdateArchive,
           CacheScanner.softwareUpdateResidueName(for: url, isDirectory: false) == nil {
            return nil
        }
        return identity
    }

    static func snapshot(for entry: QuickCleanEntry) -> QuickCleanSnapshot {
        snapshots(for: [entry]).first!
    }

    private static func automaticSnapshot(
        for entry: QuickCleanEntry, note: String? = nil
    ) -> QuickCleanSnapshot {
        let url = URL(fileURLWithPath: entry.path)
        let identity = validatedIdentity(for: entry)
        guard let identity else {
            // 不存在、符号链接或授权类型不匹配的目标均不可清理。
            return QuickCleanSnapshot(entry: entry, exists: false, size: 0, fileIdentity: nil, note: note)
        }
        let size = CacheScanner.size(of: url)
        return QuickCleanSnapshot(entry: entry, exists: true, size: size, fileIdentity: identity)
    }

    static func snapshots(
        for entries: [QuickCleanEntry],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        simulatorInspector: SimulatorCleanupInspecting = SimulatorCleanupExecutor(),
        notes: [String: String] = [:]
    ) -> [QuickCleanSnapshot] {
        // One targeted simctl/ps lookup, never a whole-machine cache scan.
        var devices: [SimulatorCleanupDevice] = []
        var activityProtection: String?
        if entries.contains(where: \.isSimulator) {
            do {
                devices = try simulatorInspector.devices()
                activityProtection = try simulatorInspector.activityProtection()
            } catch { activityProtection = error.localizedDescription }
        }
        return entries.map { entry in
            guard !entry.isAutomatic else {
                return automaticSnapshot(for: entry, note: notes[entry.id])
            }
            let url = URL(fileURLWithPath: entry.path)
            let identity = FileIdentity.capture(url)
            let exists = identity?.kind == .directory
            var protection: String?
            if entry.isManual {
                protection = "请先退出 Xcode 和所有模拟器，再按管理员权限手动处理"
            } else if !SimulatorCleanupExecutor.matches(path: url, udid: entry.identifier, home: home)
                        || url.resolvingSymlinksInPath().path != url.standardizedFileURL.path {
                protection = SimulatorCleanupError.invalidTarget.localizedDescription
            } else if let device = devices.first(where: { $0.udid == entry.identifier }) {
                if device.state != "Shutdown" {
                    protection = SimulatorCleanupError.active.localizedDescription
                } else if let dataPath = device.dataPath,
                          URL(fileURLWithPath: dataPath).standardizedFileURL.path != url.appendingPathComponent("data").standardizedFileURL.path {
                    protection = SimulatorCleanupError.invalidTarget.localizedDescription
                } else {
                    protection = activityProtection
                }
            } else {
                protection = activityProtection ?? SimulatorCleanupError.missing.localizedDescription
            }
            return QuickCleanSnapshot(
                entry: entry, exists: exists, size: exists ? CacheScanner.size(of: url) : 0,
                fileIdentity: entry.isSimulator && exists ? identity : nil,
                protection: protection
            )
        }
    }

    /// 为一键清理重新生成执行用的 CacheItem。expectedFileIdentity 必须是执行前
    /// 刚刚捕获的，绝不能复用旧扫描结果；只接受授权类型的目录或安装包，
    /// 符号链接和已消失的路径会被排除。删除仍然走 CacheCleaner + DeletionValidator。
    static func executableItems(for entries: [QuickCleanEntry]) -> [CacheItem] {
        entries.compactMap { entry in
            let url = URL(fileURLWithPath: entry.path)
            guard let identity = validatedIdentity(for: entry) else { return nil }
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
