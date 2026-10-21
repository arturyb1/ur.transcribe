import AppKit
import XCTest
@testable import URTranscribe

@MainActor
final class WindowTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    func testSettingsResizeVerticallyOnly() throws {
        WindowManager.shared.showSettings()
        let window = try XCTUnwrap(WindowManager.shared.settingsWindow)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize.width, window.contentMaxSize.width, "width is fixed")
        XCTAssertEqual(window.contentMinSize.height, SettingsView.heights.min)
        XCTAssertGreaterThan(window.contentMaxSize.height, 5000)

        // The content must not snap the window back to its fitting size.
        let width = window.contentLayoutRect.width
        window.setContentSize(NSSize(width: width, height: 900))
        window.layoutIfNeeded()
        XCTAssertEqual(window.contentLayoutRect.height, 900, accuracy: 1)
        window.close()
    }

    func testTranscriptWindowResizes() throws {
        WindowManager.shared.showTranscript()
        let window = try XCTUnwrap(WindowManager.shared.transcriptWindow)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        window.setContentSize(NSSize(width: 900, height: 700))
        window.layoutIfNeeded()
        XCTAssertEqual(window.contentLayoutRect.width, 900, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 700, accuracy: 1)
        window.close()
    }
}

/// Installs the speaker model from the release zip into a clean cache.
/// Slow and needs the zip, so it only runs when pointed at one:
///
///     URT_MODEL_ZIP=/path/to/speaker-model-sortformer-v3-fp16.zip swift test --filter ModelInstallTests
final class ModelInstallTests: XCTestCase {
    private var backup: URL?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["URT_MODEL_ZIP"] != nil else {
            throw XCTSkip("Set URT_MODEL_ZIP to run")
        }
        let cache = LiveDiarizer.modelsFolder.appendingPathComponent("sortformer")
        if FileManager.default.fileExists(atPath: cache.path) {
            let moved = FileManager.default.temporaryDirectory.appendingPathComponent("sortformer-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: cache, to: moved)
            backup = moved
        }
    }

    override func tearDownWithError() throws {
        guard let backup else { return }
        let cache = LiveDiarizer.modelsFolder.appendingPathComponent("sortformer")
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.moveItem(at: backup, to: cache)
    }

    func testInstallFromZipLoadsOffline() async throws {
        let zip = URL(fileURLWithPath: ProcessInfo.processInfo.environment["URT_MODEL_ZIP"]!)
        XCTAssertFalse(LiveDiarizer.isModelCached)
        _ = try await LiveDiarizer.installAndLoad(archive: zip)
        XCTAssertTrue(LiveDiarizer.isModelCached)
    }

    func testRejectsWrongZip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not a model".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("wrong.zip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", folder.appendingPathComponent("readme.txt").path, zip.path]
        try task.run()
        task.waitUntilExit()

        do {
            _ = try await LiveDiarizer.installAndLoad(archive: zip)
            XCTFail("expected badArchive")
        } catch LiveDiarizer.ModelError.badArchive {
            // expected
        }
    }
}
