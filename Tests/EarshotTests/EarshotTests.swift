import XCTest
@testable import Earshot

@MainActor
final class TranscriptWriterTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func line(_ source: TranscriptWriter.Source, _ start: Double, _ end: Double, _ text: String) -> TranscriptWriter.Line {
        .init(source: source, start: start, end: end, text: text, streamStart: start, streamEnd: end)
    }

    private func render(_ writer: TranscriptWriter, removeEcho: Bool = true) throws -> String {
        writer.flush(
            participants: ["Ana", "Ben"],
            label: { $0.source == .me ? "Ana" : "Ben" },
            removeEcho: removeEcho, timestamps: false, force: true)
        return try String(contentsOf: writer.fileURL, encoding: .utf8)
    }

    func testFormatOrdersAndMergesTurns() throws {
        let writer = TranscriptWriter(folder: folder, title: "Weekly sync", date: Date(timeIntervalSince1970: 0))
        writer.add(line(.remote, 5, 7, "Sounds good."))
        writer.add(line(.me, 0, 2, "Hi there."))
        writer.add(line(.me, 2, 4, "Shall we start?"))
        let text = try render(writer)
        XCTAssertTrue(text.hasPrefix("Meeting Title: Weekly sync\n"))
        XCTAssertTrue(text.contains("Meeting participants: Ana, Ben\n"))
        XCTAssertTrue(text.hasSuffix("Transcript:\nAna: Hi there. Shall we start?\nBen: Sounds good.\n"))
        XCTAssertTrue(writer.fileURL.lastPathComponent.hasSuffix(" Weekly sync.md"))
    }

    func testEchoFromSpeakersIsDropped() throws {
        let writer = TranscriptWriter(folder: folder, title: "Echo", date: Date())
        writer.add(line(.remote, 10, 14, "We need to finish the contract review by Friday"))
        writer.add(line(.me, 10.4, 14.2, "need to finish the contract review by Friday"))
        writer.add(line(.me, 15, 16, "Agreed, I will take it."))
        let text = try render(writer)
        XCTAssertFalse(text.contains("Ana: need to finish"))
        XCTAssertTrue(text.contains("Ana: Agreed, I will take it."))
        XCTAssertTrue(try render(writer, removeEcho: false).contains("Ana: need to finish"))
    }

    func testFileNamesDoNotCollide() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = TranscriptWriter(folder: folder, title: "1:1 / Ana", date: Date())
        first.add(line(.me, 0, 1, "Hello"))
        _ = try render(first)
        let second = TranscriptWriter(folder: folder, title: "1:1 / Ana", date: Date())
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertFalse(first.fileURL.lastPathComponent.contains("/"))
        XCTAssertTrue(second.fileURL.lastPathComponent.hasSuffix(" 2.md"))
    }
}

@MainActor
final class SpeakerTests: XCTestCase {
    func testOneOnOneNamesEveryRemoteLine() {
        let namer = SpeakerNamer(meeting: MeetingInfo(title: "1:1", calendarTitle: nil, others: ["Jordan"], myName: nil))
        XCTAssertEqual(namer.name(forSpeaker: 2), "Jordan")
        XCTAssertEqual(namer.name(forSpeaker: nil), "Jordan")
    }

    func testVotesNameVoicesUniquely() {
        let namer = SpeakerNamer(meeting: MeetingInfo(title: "Team", calendarTitle: nil, others: ["A", "B", "C"], myName: nil))
        XCTAssertEqual(namer.name(forSpeaker: 0), "Speaker 1")
        namer.vote(speaker: 0, names: ["Alex", "Alex", "Alex", "Casey"])
        namer.vote(speaker: 1, names: ["Alex", "Alex", "Alex"])
        namer.vote(speaker: 2, names: ["Casey", "Casey", "Casey", "Casey"])
        XCTAssertEqual(namer.name(forSpeaker: 2), "Casey")
        // Alex is claimed by one voice only; the other keeps its number.
        let robs = [namer.name(forSpeaker: 0), namer.name(forSpeaker: 1)].filter { $0 == "Alex" }
        XCTAssertEqual(robs.count, 1)
    }

    func testZoomNameCleanup() {
        XCTAssertEqual(ZoomSpeakerWatcher.clean("Jane Doe (Host)"), "Jane Doe")
        XCTAssertEqual(ZoomSpeakerWatcher.clean("Jane Doe, Video on, Audio unmuted"), "Jane Doe")
    }

    func testDefaultPatternsMatchTalkingLabel() throws {
        let regex = try NSRegularExpression(pattern: ZoomSpeakerWatcher.defaultPatterns[0], options: .caseInsensitive)
        let text = "Talking: Jane Doe"
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        XCTAssertEqual((text as NSString).substring(with: match.range(at: 1)), "Jane Doe")
    }

    func testRoutingRules() {
        let meeting = MeetingInfo(title: "Studio planning", calendarTitle: "Work", others: [], myName: nil)
        XCTAssertTrue(RoutingRule(match: .calendar, value: "work", folderPath: "/tmp/a").matches(meeting))
        XCTAssertTrue(RoutingRule(match: .titleContains, value: "studio", folderPath: "/tmp/b").matches(meeting))
        XCTAssertFalse(RoutingRule(match: .calendar, value: "Personal", folderPath: "/tmp/c").matches(meeting))
        XCTAssertFalse(RoutingRule(match: .titleContains, value: "", folderPath: "/tmp/d").matches(meeting))
    }
}
