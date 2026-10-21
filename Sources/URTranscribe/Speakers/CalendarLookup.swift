import EventKit
import Foundation

/// What the calendar says about the call happening right now.
struct MeetingInfo {
    var title: String
    var calendarTitle: String?
    /// Everyone on the invite who is not you.
    var others: [String]
    /// Your own name as the invite spells it, if present.
    var myName: String?

    /// Two-person calls: every remote word belongs to the one other attendee.
    var oneOnOneName: String? { others.count == 1 ? others[0] : nil }
}

enum CalendarLookup {
    static let store = EKEventStore()

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static var calendarTitles: [String] {
        guard hasAccess else { return [] }
        return Array(Set(store.calendars(for: .event).map(\.title))).sorted()
    }

    /// The timed event that best matches a call starting now.
    static func currentMeeting(at date: Date = Date()) -> MeetingInfo? {
        guard hasAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(15 * 60), calendars: nil)
        let candidates = store.events(matching: predicate).filter { event in
            !event.isAllDay
                && event.startDate <= date.addingTimeInterval(10 * 60)
                && event.endDate >= date.addingTimeInterval(-5 * 60)
                && event.availability != .free
        }
        // Prefer events with other people on them, then the one that started closest to now.
        let best = candidates.max { a, b in
            let aPeople = (a.attendees?.count ?? 0) > 0, bPeople = (b.attendees?.count ?? 0) > 0
            if aPeople != bPeople { return !aPeople }
            return abs(a.startDate.timeIntervalSince(date)) > abs(b.startDate.timeIntervalSince(date))
        }
        guard let event = best else { return nil }

        var people = event.attendees ?? []
        if let organizer = event.organizer, !people.contains(where: { $0.url == organizer.url }) {
            people.append(organizer)
        }
        let me = people.first(where: \.isCurrentUser)
        let others = people
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .map(displayName)
        return MeetingInfo(
            title: event.title ?? "Call",
            calendarTitle: event.calendar?.title,
            others: Array(NSOrderedSet(array: others)) as? [String] ?? others,
            myName: me.map(displayName)
        )
    }

    private static func displayName(_ participant: EKParticipant) -> String {
        if let name = participant.name, !name.isEmpty, !name.contains("@") { return name }
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        let local = address.split(separator: "@").first.map(String.init) ?? address
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
