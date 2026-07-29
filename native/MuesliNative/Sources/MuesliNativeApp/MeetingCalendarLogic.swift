import Foundation
import MuesliCore

/// How the meetings browser presents its contents.
enum MeetingsViewMode: String, CaseIterable, Codable, Sendable {
    case list
    case calendar

    var label: String {
        switch self {
        case .list: return "List"
        case .calendar: return "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .calendar: return "calendar"
        }
    }

    static func resolved(_ raw: String?) -> MeetingsViewMode {
        guard let raw, let mode = MeetingsViewMode(rawValue: raw) else { return .list }
        return mode
    }
}

/// One entry inside a calendar day cell: either a stored meeting or a scheduled
/// calendar event that has not been recorded yet.
enum MeetingCalendarItem: Identifiable, Equatable {
    case meeting(entry: MeetingCalendarEntry, start: Date)
    case scheduled(event: UnifiedCalendarEvent)

    var id: String {
        switch self {
        case .meeting(let entry, _): return "meeting-\(entry.id)"
        case .scheduled(let event): return "event-\(event.id)"
        }
    }

    var start: Date {
        switch self {
        case .meeting(_, let start): return start
        case .scheduled(let event): return event.startDate
        }
    }

    var title: String {
        switch self {
        case .meeting(let entry, _):
            let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled meeting" : trimmed
        case .scheduled(let event):
            let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled event" : trimmed
        }
    }

    var isScheduled: Bool {
        if case .scheduled = self { return true }
        return false
    }

    var meetingID: Int64? {
        if case .meeting(let entry, _) = self { return entry.id }
        return nil
    }
}

struct MeetingCalendarDay: Identifiable, Equatable {
    /// Start of day, which is also the grid position key.
    let id: Date
    var date: Date { id }
    let dayNumber: String
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isWeekend: Bool
    let items: [MeetingCalendarItem]

    var meetingCount: Int {
        items.reduce(0) { $0 + ($1.isScheduled ? 0 : 1) }
    }
}

struct MeetingCalendarMonth: Equatable {
    let monthStart: Date
    let title: String
    /// Weekday headers, already rotated to the calendar's `firstWeekday`.
    let weekdaySymbols: [String]
    let weeks: [[MeetingCalendarDay]]
    /// Stored meetings that fall inside the displayed month.
    let meetingCount: Int
    /// Combined duration of those meetings, in seconds.
    let totalDurationSeconds: Double
    /// Scheduled-but-not-recorded events inside the displayed month.
    let scheduledCount: Int

    var days: [MeetingCalendarDay] { weeks.flatMap { $0 } }
}

enum MeetingCalendarLogic {
    /// Fixed six-week grid so the view does not change height between months.
    static let weekCount = 6
    static let daysPerWeek = 7

    static func monthStart(containing date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    /// Move `months` whole months away from the month containing `date`.
    static func month(byAdding months: Int, to date: Date, calendar: Calendar = .current) -> Date {
        let start = monthStart(containing: date, calendar: calendar)
        return calendar.date(byAdding: .month, value: months, to: start) ?? start
    }

    static func isSameMonth(_ lhs: Date, _ rhs: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }

    /// Short weekday names starting at the calendar's first weekday.
    static func orderedWeekdaySymbols(
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        let symbols = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard symbols.count == daysPerWeek else { return symbols }
        let offset = max(calendar.firstWeekday - 1, 0) % daysPerWeek
        guard offset > 0 else { return symbols }
        return Array(symbols[offset...] + symbols[..<offset])
    }

    static func month(
        containing referenceDate: Date,
        entries: [MeetingCalendarEntry],
        scheduledEvents: [UnifiedCalendarEvent] = [],
        hiddenEventIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> MeetingCalendarMonth {
        let monthStart = monthStart(containing: referenceDate, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "d"

        let titleFormatter = DateFormatter()
        titleFormatter.locale = locale
        titleFormatter.calendar = calendar
        titleFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var itemsByDay: [Date: [MeetingCalendarItem]] = [:]
        var recordedEventIDs = Set<String>()

        for entry in entries {
            if let eventID = entry.calendarEventID, !eventID.isEmpty {
                recordedEventIDs.insert(eventID)
            }
            guard let start = MeetingBrowserLogic.parseDate(entry.startTime) else { continue }
            let day = calendar.startOfDay(for: start)
            itemsByDay[day, default: []].append(.meeting(entry: entry, start: start))
        }

        for event in scheduledEvents {
            guard !event.isAllDay else { continue }
            guard !hiddenEventIDs.contains(event.id) else { continue }
            // A scheduled event that already produced a meeting row is
            // represented by that meeting, not twice.
            guard !recordedEventIDs.contains(event.id) else { continue }
            let day = calendar.startOfDay(for: event.startDate)
            itemsByDay[day, default: []].append(.scheduled(event: event))
        }

        itemsByDay = itemsByDay.mapValues { items in
            items.sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }

        let leadingDays = leadingDayCount(monthStart: monthStart, calendar: calendar)
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart

        var weeks: [[MeetingCalendarDay]] = []
        var meetingCount = 0
        var scheduledCount = 0
        var totalDuration: Double = 0

        for week in 0..<weekCount {
            var row: [MeetingCalendarDay] = []
            for weekday in 0..<daysPerWeek {
                let offset = week * daysPerWeek + weekday
                guard let cellDate = calendar.date(byAdding: .day, value: offset, to: gridStart) else { continue }
                let day = calendar.startOfDay(for: cellDate)
                let items = itemsByDay[day] ?? []
                let isInDisplayedMonth = isSameMonth(day, monthStart, calendar: calendar)

                if isInDisplayedMonth {
                    for item in items {
                        switch item {
                        case .meeting(let entry, _):
                            meetingCount += 1
                            totalDuration += max(entry.durationSeconds, 0)
                        case .scheduled:
                            scheduledCount += 1
                        }
                    }
                }

                row.append(MeetingCalendarDay(
                    id: day,
                    dayNumber: dayFormatter.string(from: day),
                    isInDisplayedMonth: isInDisplayedMonth,
                    isToday: day == today,
                    isWeekend: calendar.isDateInWeekend(day),
                    items: items
                ))
            }
            weeks.append(row)
        }

        return MeetingCalendarMonth(
            monthStart: monthStart,
            title: titleFormatter.string(from: monthStart),
            weekdaySymbols: orderedWeekdaySymbols(calendar: calendar, locale: locale),
            weeks: weeks,
            meetingCount: meetingCount,
            totalDurationSeconds: totalDuration,
            scheduledCount: scheduledCount
        )
    }

    /// Number of trailing days from the previous month that pad the first row.
    static func leadingDayCount(monthStart: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return ((weekday - calendar.firstWeekday) + daysPerWeek) % daysPerWeek
    }

    /// The month of the most recent meeting, used so opening the calendar on a
    /// quiet month does not look empty.
    static func mostRecentMeetingMonth(
        entries: [MeetingCalendarEntry],
        calendar: Calendar = .current
    ) -> Date? {
        let latest = entries.compactMap { MeetingBrowserLogic.parseDate($0.startTime) }.max()
        return latest.map { monthStart(containing: $0, calendar: calendar) }
    }

    static func monthTitle(
        for date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    static func formatDurationSummary(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if total >= 60 {
            return "\(total / 60)m"
        }
        return "\(total)s"
    }
}
