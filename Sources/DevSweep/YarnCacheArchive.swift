import Foundation

/// Reads only the ZIP index. The npm scope and package name are separate path
/// components there, whereas Yarn's archive filename joins them with a hyphen.
enum YarnCacheArchive {
    static func package(at url: URL) -> (name: String, version: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? readPackage(handle, filename: url.lastPathComponent)
    }

    private static func readPackage(_ handle: FileHandle, filename: String) throws -> (String, String)? {
        let size = try handle.seekToEnd()
        let tailSize = Int(min(size, 65_557))
        guard tailSize >= 22 else { return nil }
        try handle.seek(toOffset: size - UInt64(tailSize))
        guard let tail = try handle.read(upToCount: tailSize), tail.count == tailSize,
              let end = (0...(tailSize - 22)).reversed().first(where: {
                  tail.word(at: $0, bytes: 4) == 0x06054b50
                      && $0 + 22 + tail.word(at: $0 + 20, bytes: 2) == tailSize
              }),
              tail.word(at: end + 4, bytes: 4) == 0 else { return nil }
        let entryCount = tail.word(at: end + 10, bytes: 2)
        let indexSize = tail.word(at: end + 12, bytes: 4)
        let indexOffset = tail.word(at: end + 16, bytes: 4)
        guard entryCount < 0xffff, entryCount == tail.word(at: end + 8, bytes: 2),
              indexSize <= 8 * 1_024 * 1_024, indexSize >= 46,
              UInt64(indexOffset) + UInt64(indexSize) == size - UInt64(tailSize - end) else { return nil }
        try handle.seek(toOffset: UInt64(indexOffset))
        guard let index = try handle.read(upToCount: indexSize), index.count == indexSize else { return nil }

        var offset = 0
        var packageNames = Set<String>()
        for _ in 0..<entryCount {
            guard offset + 46 <= indexSize, index.word(at: offset, bytes: 4) == 0x02014b50 else { return nil }
            let nameSize = index.word(at: offset + 28, bytes: 2)
            let nameStart = offset + 46
            offset = nameStart + nameSize + index.word(at: offset + 30, bytes: 2)
                + index.word(at: offset + 32, bytes: 2)
            guard offset <= indexSize else { return nil }
            guard let path = String(data: index[nameStart..<(nameStart + nameSize)], encoding: .utf8),
                  path.hasSuffix("/package.json") else { continue }
            let parts = path.split(separator: "/")
            guard parts.first == "node_modules" else { continue }
            if parts.count == 3, !parts[1].hasPrefix("@") {
                packageNames.insert(String(parts[1]))
            } else if parts.count == 4, parts[1].hasPrefix("@") {
                packageNames.insert(parts[1] + "/" + parts[2])
            }
        }
        guard offset == indexSize, packageNames.count == 1, let name = packageNames.first,
              DependencyManager.yarn.acceptsRule(name) else { return nil }

        let prefix = name.replacingOccurrences(of: "/", with: "-") + "-npm-"
        guard filename.hasPrefix(prefix), filename.hasSuffix(".zip") else { return nil }
        let locator = String(filename.dropFirst(prefix.count).dropLast(4))
        guard let hash = locator.range(of: #"-[0-9a-f]{10}(?:-[a-zA-Z0-9]+)?\z"#, options: .regularExpression)
        else { return nil }
        let version = String(locator[..<hash.lowerBound])
        guard version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.+-]+)?\z"#,
                            options: .regularExpression) != nil else { return nil }
        return (name, version)
    }
}

private extension Data {
    func word(at offset: Int, bytes: Int) -> Int {
        var value = 0
        for index in 0..<bytes {
            value |= Int(self[startIndex + offset + index]) << (8 * index)
        }
        return value
    }
}
