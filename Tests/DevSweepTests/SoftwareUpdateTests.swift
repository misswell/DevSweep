import XCTest
@testable import DevSweep

final class SoftwareUpdateTests: XCTestCase {
    func testComparesSemanticVersionsNumerically() throws {
        let current = try XCTUnwrap(DevSweepVersion("1.9.9"))
        let available = try XCTUnwrap(DevSweepVersion("v1.10.0"))

        XCTAssertLessThan(current, available)
        XCTAssertEqual(DevSweepVersion("1.10"), DevSweepVersion("1.10.0"))
        XCTAssertNil(DevSweepVersion("not-a-version"))
    }

    func testDecodesReleaseAndRequiresVerifiedDevSweepArchive() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "name": "DevSweep v1.2.3",
          "body": "Safer updates",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "source.zip",
              "browser_download_url": "https://example.com/source.zip",
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name": "DevSweep-1.2.3-macos.zip",
              "browser_download_url": "https://example.com/DevSweep-1.2.3-macos.zip",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            }
          ]
        }
        """

        let release = try DevSweepRelease.decodeGitHubResponse(Data(json.utf8))

        XCTAssertEqual(release.version, DevSweepVersion("1.2.3"))
        XCTAssertEqual(release.releaseNotes, "Safer updates")
        XCTAssertEqual(release.archiveURL.absoluteString, "https://example.com/DevSweep-1.2.3-macos.zip")
        XCTAssertEqual(release.sha256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    func testRejectsReleaseWithoutGitHubDigest() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "DevSweep-1.2.3-macos.zip",
            "browser_download_url": "https://example.com/DevSweep-1.2.3-macos.zip",
            "digest": null
          }]
        }
        """

        XCTAssertThrowsError(try DevSweepRelease.decodeGitHubResponse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? DevSweepUpdateError, .missingVerifiedArchive)
        }
    }

    func testReleaseOnlyReportsNewerVersions() throws {
        let release = DevSweepRelease(
            version: try XCTUnwrap(DevSweepVersion("2.0.0")),
            releaseNotes: "",
            archiveURL: try XCTUnwrap(URL(string: "https://example.com/update.zip")),
            sha256: String(repeating: "a", count: 64)
        )

        XCTAssertTrue(release.isNewer(than: "1.9.9"))
        XCTAssertFalse(release.isNewer(than: "2.0"))
        XCTAssertFalse(release.isNewer(than: "2.1.0"))
        XCTAssertFalse(release.isNewer(than: "development"))
    }

    func testComputesArchiveSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("DevSweep".utf8).write(to: url, options: .atomic)

        XCTAssertEqual(
            try DevSweepUpdatePackageValidator.sha256(of: url),
            "c9985db64da8321cf59c6761f94386a8be407038a6ccdd6f34d180a29999118b"
        )
    }
}
