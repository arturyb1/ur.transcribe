import Foundation

/// Decides the name on every remote line, in layers:
/// 1. A one-on-one invite: the other attendee said everything.
/// 2. Zoom's "who is talking" signal, voted per diarized voice.
/// 3. Otherwise a stable numbered label ("Speaker 2").
@MainActor
final class SpeakerNamer {
    private let meeting: MeetingInfo?
    private var votes: [Int: [String: Int]] = [:]
    private var resolved: [Int: String] = [:]

    /// Votes needed before a voice gets a name, and the share they must hold.
    private let minimumVotes = 3
    private let minimumShare = 0.6

    init(meeting: MeetingInfo?) {
        self.meeting = meeting
    }

    var isOneOnOne: Bool { meeting?.oneOnOneName != nil }

    /// Feed Zoom's talking names observed during a diarized turn.
    func vote(speaker: Int, names: [String]) {
        guard !names.isEmpty else { return }
        for name in names { votes[speaker, default: [:]][name, default: 0] += 1 }
        resolve()
    }

    func name(forSpeaker speaker: Int?) -> String {
        if let name = meeting?.oneOnOneName { return name }
        guard let speaker else { return "Speaker ?" }
        return resolved[speaker] ?? "Speaker \(speaker + 1)"
    }

    /// Assign each name to at most one voice, strongest evidence first.
    private func resolve() {
        var candidates: [(speaker: Int, name: String, count: Int)] = []
        for (speaker, tally) in votes {
            let total = tally.values.reduce(0, +)
            guard let (name, count) = tally.max(by: { $0.value < $1.value }),
                  count >= minimumVotes, Double(count) / Double(total) >= minimumShare
            else { continue }
            candidates.append((speaker, name, count))
        }
        var taken = Set<String>()
        var result: [Int: String] = [:]
        for candidate in candidates.sorted(by: { $0.count > $1.count }) where !taken.contains(candidate.name) {
            result[candidate.speaker] = candidate.name
            taken.insert(candidate.name)
        }
        resolved = result
    }
}
