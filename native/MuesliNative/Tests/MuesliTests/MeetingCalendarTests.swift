import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meetings view mode")
struct MeetingsViewModeTests {

    @Test("unknown and missing raw values fall back to the list view")
    func resolvesUnknownToList() {
        #expect(MeetingsViewMode.resolved(nil) == .list)
        #expect(MeetingsViewMode.resolved("") == .list)
        #expect(MeetingsViewMode.resolved("grid") == .list)
        #expect(MeetingsViewMode.resolved("calendar") == .calendar)
        #expect(MeetingsViewMode.resolved("list") == .list)
    }

    @Test("config round-trips the persisted view mode with a snake_case key")
    func configRoundTripsViewMode() throws {
        var config = AppConfig()
        #expect(config.resolvedMeetingsViewMode == .list)

        config.meetingsViewMode = MeetingsViewMode.calendar.rawValue
        let encoded = try JSONEncoder().encode(config)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["meetings_view_mode"] as? String == "calendar")

        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.resolvedMeetingsViewMode == .calendar)
    }

    @Test("configs written before the calendar view default to the list view")
    func legacyConfigDefaultsToList() throws {
        let legacy = Data("{\"dark_mode\": true}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
        #expect(decoded.resolvedMeetingsViewMode == .list)
    }

    @Test("an invalid persisted value decodes to the list view")
    func invalidPersistedValueDecodesToList() throws {
        let raw = Data("{\"meetings_view_mode\": \"heatmap\"}".utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: raw)
        #expect(decoded.resolvedMeetingsViewMode == .list)
    }
}

@Suite("Meeting calendar logic")
struct MeetingCalendarLogicTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2  // Monday
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_US") }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")!
        guard let date = formatter.date(from: iso) else {
            fatalError("bad fixture date \(iso)")
        }
        return date
    }

    private func entry(
        id: Int64,
        _ iso: String,
        title: String = "Standup",
        durationSeconds: Double = 1800,
        status: MeetingStatus = .completed,
        source: MeetingSource = .meeting,
        calendarEventID: String? = nil
    ) -> MeetingCalendarEntry {
        MeetingCalendarEntry(
            id: id,
            title: title,
            startTime: iso,
            durationSeconds: durationSeconds,
            status: status,
            source: source,
            calendarEventID: calendarEventID
        )
    }

    private func event(
        id: String,
        start: String,
        durationMinutes: Double = 30,
        title: String = "Scheduled sync",
        isAllDay: Bool = false
    ) -> UnifiedCalendarEvent {
        let startDate = date(start)
        return UnifiedCalendarEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(durationMinutes * 60),
            isAllDay: isAllDay,
            source: .eventKit
        )
    }

    // MARK: - Grid geometry

    @Test("the grid is always six weeks so the view keeps a stable height")
    func gridIsAlwaysSixWeeks() {
        let month = MeetingCalendarLogic.month(
            containing: date("2026-02-10T12:00:00Z"),
            entries: [],
            now: date("2026-02-10T12:00:00Z"),
            calendar: calendar,
            locale: locale
        )

        #expect(month.weeks.count == 6)
        #expect(month.weeks.allSatisfy { $0.count == 7 })
        #expect(month.days.count == 42)
    }

    @Test("the first cell is the calendar's first weekday on or before the 1st")
    func gridStartsOnFirstWeekday() throws {
        // 1 July 2026 is a Wednesday, so a Monday-first grid leads with 2 days.
        let month = MeetingCalendarLogic.month(
            containing: date("2026-07-15T12:00:00Z"),
            entries: [],
            now: date("2026-07-15T12:00:00Z"),
            calendar: calendar,
            locale: locale
        )

        let first = try #require(month.days.first)
        #expect(calendar.component(.day, from: first.date) == 29)
        #expect(calendar.component(.month, from: first.date) == 6)
        #expect(first.isInDisplayedMonth == false)
        #expect(MeetingCalendarLogic.leadingDayCount(
            monthStart: month.monthStart,
            calendar: calendar
        ) == 2)
    }

    @Test("a Sunday-first calendar shifts the leading pad and weekday headers")
    func sundayFirstCalendarShiftsGrid() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1

        let month = MeetingCalendarLogic.month(
            containing: date("2026-07-15T12:00:00Z"),
            entries: [],
            now: date("2026-07-15T12:00:00Z"),
            calendar: sundayFirst,
            locale: locale
        )

        #expect(MeetingCalendarLogic.leadingDayCount(
            monthStart: month.monthStart,
            calendar: sundayFirst
        ) == 3)
        #expect(month.weekdaySymbols.first == "Sun")

        let mondayFirstSymbols = MeetingCalendarLogic.orderedWeekdaySymbols(
            calendar: calendar,
            locale: locale
        )
        #expect(mondayFirstSymbols.first == "Mon")
        #expect(mondayFirstSymbols.last == "Sun")
        #expect(mondayFirstSymbols.count == 7)
    }

    @Test("the displayed month is flagged on in-month cells only")
    func inMonthFlagging() {
        let month = MeetingCalendarLogic.month(
            containing: date("2026-07-15T12:00:00Z"),
            entries: [],
            now: date("2026-07-15T12:00:00Z"),
            calendar: calendar,
            locale: locale
        )

        let inMonth = month.days.filter(\.isInDisplayedMonth)
        #expect(inMonth.count == 31)
        #expect(month.title == "July 2026")
    }

    @Test("today is marked only on the matching day")
    func todayIsMarkedOnce() throws {
        let now = date("2026-07-15T09:30:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [],
            now: now,
            calendar: calendar,
            locale: locale
        )

        let todays = month.days.filter(\.isToday)
        #expect(todays.count == 1)
        #expect(calendar.component(.day, from: try #require(todays.first).date) == 15)
    }

    // MARK: - Bucketing

    @Test("meetings land on their local day and sort by start time")
    func meetingsBucketByDayAndSort() throws {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [
                entry(id: 1, "2026-07-15T15:00:00Z", title: "Afternoon"),
                entry(id: 2, "2026-07-15T08:00:00Z", title: "Morning"),
                entry(id: 3, "2026-07-20T08:00:00Z", title: "Next week")
            ],
            now: now,
            calendar: calendar,
            locale: locale
        )

        let fifteenth = try #require(month.days.first { calendar.component(.day, from: $0.date) == 15 })
        #expect(fifteenth.items.map(\.title) == ["Morning", "Afternoon"])
        #expect(fifteenth.items.map(\.meetingID) == [2, 1])

        let twentieth = try #require(month.days.first { calendar.component(.day, from: $0.date) == 20 })
        #expect(twentieth.items.count == 1)
        #expect(twentieth.meetingCount == 1)
    }

    @Test("unparseable timestamps are dropped instead of crashing the grid")
    func unparseableTimestampsAreDropped() {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [
                entry(id: 1, "not-a-date", title: "Broken"),
                entry(id: 2, "2026-07-15T08:00:00Z", title: "Good")
            ],
            now: now,
            calendar: calendar,
            locale: locale
        )

        #expect(month.meetingCount == 1)
        #expect(month.days.flatMap(\.items).map(\.title) == ["Good"])
    }

    @Test("meetings from adjacent months show in the padding cells but not in the totals")
    func adjacentMonthMeetingsExcludedFromTotals() throws {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [
                entry(id: 1, "2026-06-30T09:00:00Z", title: "Late June", durationSeconds: 3600),
                entry(id: 2, "2026-07-02T09:00:00Z", title: "Early July", durationSeconds: 1800)
            ],
            now: now,
            calendar: calendar,
            locale: locale
        )

        #expect(month.meetingCount == 1)
        #expect(month.totalDurationSeconds == 1800)

        let june30 = try #require(month.days.first {
            !$0.isInDisplayedMonth && calendar.component(.day, from: $0.date) == 30
        })
        #expect(june30.items.map(\.title) == ["Late June"])
    }

    @Test("month totals sum durations and clamp negatives")
    func monthTotalsSumDurations() {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [
                entry(id: 1, "2026-07-02T09:00:00Z", durationSeconds: 3600),
                entry(id: 2, "2026-07-03T09:00:00Z", durationSeconds: 1800),
                entry(id: 3, "2026-07-04T09:00:00Z", durationSeconds: -50)
            ],
            now: now,
            calendar: calendar,
            locale: locale
        )

        #expect(month.meetingCount == 3)
        #expect(month.totalDurationSeconds == 5400)
    }

    // MARK: - Scheduled events

    @Test("scheduled events appear alongside meetings and are counted separately")
    func scheduledEventsAppearAlongsideMeetings() throws {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [entry(id: 1, "2026-07-15T08:00:00Z", title: "Recorded")],
            scheduledEvents: [event(id: "evt-1", start: "2026-07-15T14:00:00Z", title: "Later today")],
            now: now,
            calendar: calendar,
            locale: locale
        )

        let fifteenth = try #require(month.days.first { calendar.component(.day, from: $0.date) == 15 })
        #expect(fifteenth.items.map(\.title) == ["Recorded", "Later today"])
        #expect(fifteenth.items.map(\.isScheduled) == [false, true])
        #expect(fifteenth.meetingCount == 1)
        #expect(month.meetingCount == 1)
        #expect(month.scheduledCount == 1)
    }

    @Test("an event already recorded as a meeting is not shown twice")
    func recordedEventIsNotDuplicated() throws {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [
                entry(id: 1, "2026-07-15T08:00:00Z", title: "Recorded", calendarEventID: "evt-1")
            ],
            scheduledEvents: [event(id: "evt-1", start: "2026-07-15T08:00:00Z", title: "Same event")],
            now: now,
            calendar: calendar,
            locale: locale
        )

        let fifteenth = try #require(month.days.first { calendar.component(.day, from: $0.date) == 15 })
        #expect(fifteenth.items.map(\.title) == ["Recorded"])
        #expect(month.scheduledCount == 0)
    }

    @Test("hidden and all-day events are excluded")
    func hiddenAndAllDayEventsExcluded() {
        let now = date("2026-07-15T12:00:00Z")
        let month = MeetingCalendarLogic.month(
            containing: now,
            entries: [],
            scheduledEvents: [
                event(id: "hidden", start: "2026-07-15T14:00:00Z", title: "Hidden"),
                event(id: "all-day", start: "2026-07-16T00:00:00Z", title: "Holiday", isAllDay: true),
                event(id: "visible", start: "2026-07-17T14:00:00Z", title: "Visible")
            ],
            hiddenEventIDs: ["hidden"],
            now: now,
            calendar: calendar,
            locale: locale
        )

        #expect(month.days.flatMap(\.items).map(\.title) == ["Visible"])
        #expect(month.scheduledCount == 1)
    }

    // MARK: - Navigation helpers

    @Test("stepping months stays anchored to the first of the month")
    func steppingMonths() {
        let july = MeetingCalendarLogic.monthStart(
            containing: date("2026-07-15T12:00:00Z"),
            calendar: calendar
        )
        #expect(calendar.component(.day, from: july) == 1)

        let june = MeetingCalendarLogic.month(byAdding: -1, to: july, calendar: calendar)
        #expect(calendar.component(.month, from: june) == 6)

        // Crossing a year boundary from a 31-day month must not spill over.
        let january = MeetingCalendarLogic.monthStart(
            containing: date("2026-01-31T12:00:00Z"),
            calendar: calendar
        )
        let december = MeetingCalendarLogic.month(byAdding: -1, to: january, calendar: calendar)
        #expect(calendar.component(.year, from: december) == 2025)
        #expect(calendar.component(.month, from: december) == 12)
        #expect(calendar.component(.day, from: december) == 1)

        let february = MeetingCalendarLogic.month(byAdding: 1, to: january, calendar: calendar)
        #expect(calendar.component(.month, from: february) == 2)
        #expect(calendar.component(.day, from: february) == 1)
    }

    @Test("isSameMonth compares month granularity, not exact dates")
    func isSameMonthGranularity() {
        #expect(MeetingCalendarLogic.isSameMonth(
            date("2026-07-01T00:00:00Z"),
            date("2026-07-31T23:00:00Z"),
            calendar: calendar
        ))
        #expect(!MeetingCalendarLogic.isSameMonth(
            date("2026-07-31T23:00:00Z"),
            date("2026-08-01T00:00:00Z"),
            calendar: calendar
        ))
    }

    @Test("the latest meeting month ignores unparseable rows and returns nil when empty")
    func latestMeetingMonth() throws {
        #expect(MeetingCalendarLogic.mostRecentMeetingMonth(entries: [], calendar: calendar) == nil)
        #expect(MeetingCalendarLogic.mostRecentMeetingMonth(
            entries: [entry(id: 1, "nonsense")],
            calendar: calendar
        ) == nil)

        let latest = MeetingCalendarLogic.mostRecentMeetingMonth(
            entries: [
                entry(id: 1, "2026-03-04T09:00:00Z"),
                entry(id: 2, "2026-09-21T09:00:00Z"),
                entry(id: 3, "bad-date")
            ],
            calendar: calendar
        )
        let unwrapped = try #require(latest)
        #expect(calendar.component(.year, from: unwrapped) == 2026)
        #expect(calendar.component(.month, from: unwrapped) == 9)
        #expect(calendar.component(.day, from: unwrapped) == 1)
    }

    @Test("duration summaries collapse to the coarsest useful unit")
    func durationSummaries() {
        #expect(MeetingCalendarLogic.formatDurationSummary(0) == "0s")
        #expect(MeetingCalendarLogic.formatDurationSummary(45) == "45s")
        #expect(MeetingCalendarLogic.formatDurationSummary(1800) == "30m")
        #expect(MeetingCalendarLogic.formatDurationSummary(3600) == "1h")
        #expect(MeetingCalendarLogic.formatDurationSummary(5400) == "1h 30m")
        #expect(MeetingCalendarLogic.formatDurationSummary(90_000) == "25h")
    }
}

@Suite("Meeting calendar entries store query", .serialized)
struct MeetingCalendarEntriesStoreTests {

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-calendar-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func insert(
        _ store: DictationStore,
        title: String,
        start: Date,
        durationMinutes: Double = 30,
        calendarEventID: String? = nil,
        source: MeetingSource = .meeting
    ) throws -> Int64 {
        try store.insertMeeting(
            title: title,
            calendarEventID: calendarEventID,
            startTime: start,
            endTime: start.addingTimeInterval(durationMinutes * 60),
            rawTranscript: "transcript body",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            source: source
        )
    }

    @Test("entries cover the full history that the paged meeting fetch truncates")
    func entriesCoverFullHistory() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<25 {
            try insert(
                store,
                title: "Meeting \(index)",
                start: base.addingTimeInterval(Double(index) * 86_400)
            )
        }

        let paged = try store.recentMeetings(limit: 10)
        let entries = try store.meetingCalendarEntries()

        #expect(paged.count == 10)
        #expect(entries.count == 25)
        #expect(Set(entries.map(\.id)).count == 25)
    }

    @Test("entries carry the metadata a day cell renders")
    func entriesCarryDisplayMetadata() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let id = try insert(
            store,
            title: "Quarterly review",
            start: start,
            durationMinutes: 45,
            calendarEventID: "evt-42",
            source: .audioImport
        )

        let entry = try #require(try store.meetingCalendarEntries().first { $0.id == id })
        #expect(entry.title == "Quarterly review")
        #expect(entry.calendarEventID == "evt-42")
        #expect(entry.source == .audioImport)
        #expect(entry.status == .completed)
        #expect(entry.durationSeconds == 2700)
        #expect(MeetingBrowserLogic.parseDate(entry.startTime) == start.roundedToSecond)
        #expect(entry.folderID == nil)
    }

    @Test("deleted meetings are excluded")
    func deletedMeetingsExcluded() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let keep = try insert(store, title: "Keep", start: start)
        let drop = try insert(store, title: "Drop", start: start.addingTimeInterval(3600))

        try store.deleteMeeting(id: drop)

        let ids = try store.meetingCalendarEntries().map(\.id)
        #expect(ids == [keep])
    }

    @Test("the origin filter splits Mac and iPhone meetings")
    func originFilterSplitsSources() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let mac = try insert(store, title: "On Mac", start: start)
        let phone = try insert(
            store,
            title: "From iPhone",
            start: start.addingTimeInterval(3600),
            source: .iOS
        )

        #expect(try store.meetingCalendarEntries(origin: .all).count == 2)
        #expect(try store.meetingCalendarEntries(origin: .thisMac).map(\.id) == [mac])
        #expect(try store.meetingCalendarEntries(origin: .fromIPhone).map(\.id) == [phone])
    }

    @Test("a folder scope includes nested folders")
    func folderScopeIncludesDescendants() throws {
        let store = try makeStore()
        let parent = try store.createFolder(name: "Clients")
        let child = try store.createFolder(name: "Acme", parentID: parent)
        let unrelated = try store.createFolder(name: "Personal")

        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let inParent = try insert(store, title: "Parent meeting", start: start)
        let inChild = try insert(store, title: "Child meeting", start: start.addingTimeInterval(3600))
        let outside = try insert(store, title: "Other meeting", start: start.addingTimeInterval(7200))
        try store.moveMeeting(id: inParent, toFolder: parent)
        try store.moveMeeting(id: inChild, toFolder: child)
        try store.moveMeeting(id: outside, toFolder: unrelated)

        let scoped = try store.meetingCalendarEntries(folderID: parent)
        #expect(Set(scoped.map(\.id)) == [inParent, inChild])
        #expect(scoped.allSatisfy { $0.folderID == parent || $0.folderID == child })

        #expect(try store.meetingCalendarEntries(folderID: unrelated).map(\.id) == [outside])
    }

    @Test("the limit keeps the newest meetings")
    func limitKeepsNewest() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        var ids: [Int64] = []
        for index in 0..<5 {
            ids.append(try insert(
                store,
                title: "Meeting \(index)",
                start: base.addingTimeInterval(Double(index) * 86_400)
            ))
        }

        let limited = try store.meetingCalendarEntries(limit: 2)
        #expect(limited.count == 2)
        #expect(Set(limited.map(\.id)) == Set(ids.suffix(2)))
    }
}

private extension Date {
    /// `insertMeeting` stores whole-second ISO-8601 strings, so fixtures compare
    /// against the truncated value rather than the raw sub-second instant.
    var roundedToSecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.towardZero))
    }
}
