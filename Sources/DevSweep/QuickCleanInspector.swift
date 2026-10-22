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

    /// 目录集合统一交给一次 `du`，整个集合共享硬链接去重；
    /// 这个常量只控制界面增量发布的批量大小。
    private static let publishBatchSize = 16

    /// 大集合允许更长的总预算，但仍保留超时上限，避免一次刷新无限占用。
    private static func measurementTimeout(for directoryCount: Int) -> TimeInterval {
        min(300, max(60, Double(directoryCount)))
    }

    private static func automaticSnapshot(
        for entry: QuickCleanEntry,
        identity: FileIdentity,
        measurement: StorageMeasurement
    ) -> QuickCleanSnapshot {
        QuickCleanSnapshot(
            entry: entry,
            exists: true,
            measurement: measurement,
            fileIdentity: identity,
            note: measurement.warning
        )
    }

    /// 不存在、符号链接或授权类型不匹配的目标一律不可清理。
    private static func invalidAutomaticSnapshot(
        for entry: QuickCleanEntry, note: String? = nil
    ) -> QuickCleanSnapshot {
        QuickCleanSnapshot(
            entry: entry, exists: false,
            measurement: StorageMeasurement(
                allocatedBytes: 0, state: .failed, failureReason: note ?? "路径不存在"
            ),
            fileIdentity: nil, note: note
        )
    }

    private static func fileMeasurement(for url: URL) -> StorageMeasurement {
        StorageMeasurementService.measureFile(
            url, allocatedSize: (try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]))?.fileAllocatedSize
        )
    }

    private static func simulatorState(
        for entries: [QuickCleanEntry],
        inspector: SimulatorCleanupInspecting
    ) -> (devices: [SimulatorCleanupDevice], protection: String?) {
        guard entries.contains(where: \.isSimulator) else { return ([], nil) }
        // One targeted simctl/ps lookup, never a whole-machine cache scan.
        do {
            return (try inspector.devices(), try inspector.activityProtection())
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private static func guardedSnapshot(
        for entry: QuickCleanEntry,
        home: URL,
        devices: [SimulatorCleanupDevice],
        activityProtection: String?,
        measurement: StorageMeasurement?
    ) -> QuickCleanSnapshot {
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
        let fallback = StorageMeasurement(
            allocatedBytes: 0,
            state: exists ? .failed : .complete,
            failureReason: exists ? "无法统计该条目占用" : nil
        )
        return QuickCleanSnapshot(
            entry: entry,
            exists: exists,
            measurement: exists ? (measurement ?? fallback) : StorageMeasurement(allocatedBytes: 0),
            fileIdentity: entry.isSimulator && exists ? identity : nil,
            protection: protection
        )
    }

    /// 刷新磁盘快照：存在性、FileIdentity、大小全部重新读取，绝不调用完整 CacheScanner。
    ///
    /// 目录占用交给同一次 `du`，整个集合共享硬链接去重；读取到每个目录时立即产生
    /// 增量快照，`onProgress` 只收到本次新增或更新的条目，不再重复发送历史结果。
    /// 模拟器状态需要 `simctl`，放在文件快照之后，不拖慢可清理项。
    static func snapshots(
        for entries: [QuickCleanEntry],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        simulatorInspector: SimulatorCleanupInspecting = SimulatorCleanupExecutor(),
        notes: [String: String] = [:],
        isCancelled: () -> Bool = { false },
        onProgress: (([QuickCleanSnapshot]) -> Void)? = nil
    ) -> [QuickCleanSnapshot] {
        // 按索引而不是按 id 收集：结果必须与传入条目一一对应、顺序一致。
        var slots = [QuickCleanSnapshot?](repeating: nil, count: entries.count)
        var directorySlots: [(index: Int, entry: QuickCleanEntry, url: URL, identity: FileIdentity)] = []

        for (index, entry) in entries.enumerated() where entry.isAutomatic {
            if isCancelled() { break }
            guard let identity = validatedIdentity(for: entry) else {
                slots[index] = invalidAutomaticSnapshot(for: entry, note: notes[entry.id])
                continue
            }
            let url = URL(fileURLWithPath: entry.path)
            if identity.kind == .regular {
                slots[index] = automaticSnapshot(
                    for: entry, identity: identity, measurement: fileMeasurement(for: url)
                )
            } else {
                directorySlots.append((index, entry, url, identity))
            }
        }

        // 文件与失效路径不依赖 du，先让界面看到它们。
        let initial = slots.compactMap { $0 }
        if !initial.isEmpty { onProgress?(initial) }

        // 同一路径可能被收藏多次，回调时所有对应行一起更新。
        var rowsByPath: [String: [(index: Int, entry: QuickCleanEntry, identity: FileIdentity)]] = [:]
        for item in directorySlots {
            rowsByPath[item.url.path, default: []].append((item.index, item.entry, item.identity))
        }

        var pendingPublish: [QuickCleanSnapshot] = []
        func publish(_ snapshot: QuickCleanSnapshot) {
            pendingPublish.append(snapshot)
            if pendingPublish.count >= publishBatchSize {
                onProgress?(pendingPublish)
                pendingPublish.removeAll(keepingCapacity: true)
            }
        }

        let measurements = StorageMeasurementService.measureAll(
            directorySlots.map(\.url),
            timeout: measurementTimeout(for: directorySlots.count),
            isCancelled: isCancelled,
            onMeasurement: { path, measurement in
                for item in rowsByPath[path] ?? [] {
                    let snapshot = automaticSnapshot(
                        for: item.entry, identity: item.identity, measurement: measurement
                    )
                    slots[item.index] = snapshot
                    publish(snapshot)
                }
            }
        )
        if !pendingPublish.isEmpty { onProgress?(pendingPublish) }

        // 最终校准：du 的错误归属只在进程结束后才能确定。
        for item in directorySlots {
            guard let measurement = measurements[item.url.path] else { continue }
            slots[item.index] = automaticSnapshot(
                for: item.entry, identity: item.identity, measurement: measurement
            )
        }

        let guarded = entries.enumerated().filter { !$0.element.isAutomatic }
        guard !guarded.isEmpty, !isCancelled() else { return slots.compactMap { $0 } }
        let guardedEntries = guarded.map(\.element)
        let state = simulatorState(for: guardedEntries, inspector: simulatorInspector)
        if isCancelled() { return slots.compactMap { $0 } }

        // 身份、UDID 和活动状态仍逐设备核验；容量只对通过核验的目标批量测量。
        var guardedURLs: [URL] = []
        for item in guarded {
            let url = URL(fileURLWithPath: item.element.path)
            if item.element.isManual || FileIdentity.capture(url)?.kind == .directory {
                guardedURLs.append(url)
            }
        }
        let guardedMeasurements = StorageMeasurementService.measure(
            guardedURLs, timeout: measurementTimeout(for: guardedURLs.count)
        )
        for item in guarded {
            let url = URL(fileURLWithPath: item.element.path)
            slots[item.offset] = guardedSnapshot(
                for: item.element, home: home,
                devices: state.devices, activityProtection: state.protection,
                measurement: guardedMeasurements[url.path]
            )
        }
        if !guarded.isEmpty { onProgress?(slots.compactMap { $0 }) }
        return slots.compactMap { $0 }
    }

    /// 为一键清理重新生成执行用的 CacheItem。expectedFileIdentity 必须是执行前
    /// 刚刚捕获的，绝不能复用旧扫描结果；只接受授权类型的目录或安装包，
    /// 符号链接和已消失的路径会被排除。
    ///
    /// 安全核验先逐项完成，容量再统一批量读取：测量失败不影响已通过核验的目标清理，
    /// 但会把下限状态带进报告。删除仍然走 CacheCleaner + DeletionValidator。
    static func executableItems(for entries: [QuickCleanEntry]) -> [CacheItem] {
        var validated: [(entry: QuickCleanEntry, url: URL, identity: FileIdentity)] = []
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)
            guard let identity = validatedIdentity(for: entry) else { continue }
            validated.append((entry, url, identity))
        }
        guard !validated.isEmpty else { return [] }

        let directoryURLs = validated
            .filter { $0.identity.kind == .directory }
            .map(\.url)
        let directoryMeasurements = StorageMeasurementService.measure(
            directoryURLs, timeout: measurementTimeout(for: directoryURLs.count)
        )

        return validated.map { item in
            let measurement = item.identity.kind == .directory
                ? directoryMeasurements[item.url.path]
                : fileMeasurement(for: item.url)
            return CacheItem(
                category: item.entry.category,
                name: item.entry.displayName,
                path: item.url,
                size: measurement?.allocatedBytes ?? 0,
                sizeWarning: measurement?.warning,
                details: item.url.devSweepDisplayPath,
                risk: .safe,
                kind: .trash,
                expectedFileIdentity: item.identity,
                note: "常用清理"
            )
        }
    }
}
