import SwiftUI
import MuesliCore

/// Month grid of recorded meetings, with scheduled-but-not-recorded calendar
/// events shown alongside them.
struct MeetingCalendarView: View {
    let month: MeetingCalendarMonth
    let selectedMeetingID: Int64?
    /// Month of the newest stored meeting, offered as a shortcut when the
    /// visible month has nothing in it.
    let latestMeetingMonth: Date?
    let canStartMeeting: Bool
    let onSelectMeeting: (Int64) -> Void
    let onStepMonth: (Int) -> Void
    let onGoToMonth: (Date) -> Void
    let onJoinAndRecord: (UnifiedCalendarEvent) -> Void
    let onCreateNote: (UnifiedCalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            header
            grid
        }
        .padding(MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(month.title)
                    .font(.custom("Cormorant Garamond", size: 22).weight(.medium))
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text(summaryText)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            if let latestMeetingMonth,
               month.meetingCount == 0,
               !MeetingCalendarLogic.isSameMonth(latestMeetingMonth, month.monthStart) {
                Button {
                    onGoToMonth(latestMeetingMonth)
                } label: {
                    Text("Jump to \(MeetingCalendarLogic.monthTitle(for: latestMeetingMonth))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Go to the month of the most recent meeting")
            }

            HStack(spacing: 4) {
                monthStepButton(systemImage: "chevron.left", help: "Previous month", step: -1)
                Button {
                    onGoToMonth(Date())
                } label: {
                    Text("Today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Jump to the current month")
                monthStepButton(systemImage: "chevron.right", help: "Next month", step: 1)
            }
        }
    }

    private func monthStepButton(systemImage: String, help: String, step: Int) -> some View {
        Button {
            onStepMonth(step)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 26, height: 24)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var summaryText: String {
        var parts: [String] = []
        if month.meetingCount == 0 {
            parts.append("No meetings")
        } else {
            parts.append("\(month.meetingCount) meeting\(month.meetingCount == 1 ? "" : "s")")
            parts.append(MeetingCalendarLogic.formatDurationSummary(month.totalDurationSeconds))
        }
        if month.scheduledCount > 0 {
            parts.append("\(month.scheduledCount) scheduled")
        }
        return parts.joined(separator: "  \u{2022}  ")
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 6) {
                    ForEach(week) { day in
                        MeetingCalendarDayCell(
                            day: day,
                            selectedMeetingID: selectedMeetingID,
                            canStartMeeting: canStartMeeting,
                            onSelectMeeting: onSelectMeeting,
                            onJoinAndRecord: onJoinAndRecord,
                            onCreateNote: onCreateNote
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Day cell

private struct MeetingCalendarDayCell: View {
    let day: MeetingCalendarDay
    let selectedMeetingID: Int64?
    let canStartMeeting: Bool
    let onSelectMeeting: (Int64) -> Void
    let onJoinAndRecord: (UnifiedCalendarEvent) -> Void
    let onCreateNote: (UnifiedCalendarEvent) -> Void

    @State private var isShowingDetail = false

    private static let maxVisibleItems = 3
    private static let cellHeight: CGFloat = 108

    private var visibleItems: [MeetingCalendarItem] {
        overflowCount > 0 ? Array(day.items.prefix(Self.maxVisibleItems - 1)) : day.items
    }

    /// When the day overflows, the last chip slot becomes the "+N more" button,
    /// so that hidden entry is counted here too.
    private var overflowCount: Int {
        day.items.count > Self.maxVisibleItems
            ? day.items.count - (Self.maxVisibleItems - 1)
            : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                dayNumberLabel
                Spacer(minLength: 0)
            }

            ForEach(visibleItems) { item in
                MeetingCalendarChip(
                    item: item,
                    isSelected: item.meetingID != nil && item.meetingID == selectedMeetingID
                ) {
                    if let meetingID = item.meetingID {
                        onSelectMeeting(meetingID)
                    } else {
                        isShowingDetail = true
                    }
                }
            }

            if overflowCount > 0 {
                Button {
                    isShowingDetail = true
                } label: {
                    Text("+\(overflowCount) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show all \(day.items.count) entries")
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(height: Self.cellHeight, alignment: .topLeading)
        .background(cellBackground)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(
                    day.isToday ? MuesliTheme.accent.opacity(0.45) : MuesliTheme.surfaceBorder,
                    lineWidth: day.isToday ? 1.5 : 0.5
                )
        )
        .opacity(day.isInDisplayedMonth ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !day.items.isEmpty else { return }
            isShowingDetail = true
        }
        .popover(isPresented: $isShowingDetail, arrowEdge: .trailing) {
            MeetingCalendarDayDetail(
                day: day,
                canStartMeeting: canStartMeeting,
                onSelectMeeting: { id in
                    isShowingDetail = false
                    onSelectMeeting(id)
                },
                onJoinAndRecord: { event in
                    isShowingDetail = false
                    onJoinAndRecord(event)
                },
                onCreateNote: { event in
                    isShowingDetail = false
                    onCreateNote(event)
                }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var dayNumberLabel: some View {
        if day.isToday {
            Text(day.dayNumber)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MuesliTheme.backgroundBase)
                .frame(width: 18, height: 18)
                .background(Circle().fill(MuesliTheme.accent))
        } else {
            Text(day.dayNumber)
                .font(.system(size: 11, weight: day.isInDisplayedMonth ? .semibold : .regular))
                .foregroundStyle(day.isInDisplayedMonth ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                .frame(width: 18, height: 18)
        }
    }

    /// Layered against the card's `backgroundRaised`, so weekdays read lighter
    /// and weekends darker in dark mode and the reverse in light mode.
    /// Out-of-month cells are dimmed by the cell's own opacity instead.
    private var cellBackground: Color {
        if day.isToday { return MuesliTheme.accent.opacity(0.08) }
        return day.isWeekend ? MuesliTheme.backgroundDeep : MuesliTheme.backgroundBase
    }

    private var accessibilityLabel: String {
        let dateLabel = MeetingCalendarFormat.accessibilityDate(day.date)
        guard !day.items.isEmpty else { return "\(dateLabel), no meetings" }
        let recorded = day.meetingCount
        let scheduled = day.items.count - recorded
        var parts: [String] = [dateLabel]
        if recorded > 0 { parts.append("\(recorded) meeting\(recorded == 1 ? "" : "s")") }
        if scheduled > 0 { parts.append("\(scheduled) scheduled") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Chip

private struct MeetingCalendarChip: View {
    let item: MeetingCalendarItem
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(width: 2.5)

                Text(MeetingCalendarFormat.time(item.start))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize()

                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .frame(height: 17)
            .padding(.horizontal, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        isSelected ? MuesliTheme.accent.opacity(0.6) : borderColor,
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var accentColor: Color {
        switch item {
        case .meeting(let entry, _):
            switch entry.status {
            case .recording: return MuesliTheme.recording
            case .processing: return MuesliTheme.transcribing
            case .failed: return MuesliTheme.recording.opacity(0.6)
            case .noteOnly: return MuesliTheme.textSecondary
            case .completed: return MuesliTheme.accent
            }
        case .scheduled:
            return MuesliTheme.textTertiary
        }
    }

    private var background: Color {
        if isSelected { return MuesliTheme.surfaceSelected }
        if isHovering { return MuesliTheme.backgroundHover }
        return item.isScheduled ? Color.clear : MuesliTheme.surfacePrimary.opacity(0.45)
    }

    private var borderColor: Color {
        item.isScheduled ? MuesliTheme.surfaceBorder : Color.clear
    }

    private var helpText: String {
        switch item {
        case .meeting(let entry, let start):
            let range = MeetingCalendarFormat.timeRange(start: start, durationSeconds: entry.durationSeconds)
            return "\(item.title) — \(range)"
        case .scheduled(let event):
            let range = "\(MeetingCalendarFormat.time(event.startDate)) – \(MeetingCalendarFormat.time(event.endDate))"
            return "\(item.title) — \(range) (scheduled)"
        }
    }
}

// MARK: - Day detail popover

private struct MeetingCalendarDayDetail: View {
    let day: MeetingCalendarDay
    let canStartMeeting: Bool
    let onSelectMeeting: (Int64) -> Void
    let onJoinAndRecord: (UnifiedCalendarEvent) -> Void
    let onCreateNote: (UnifiedCalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(MeetingCalendarFormat.dayHeading(day.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)

            Divider()

            ForEach(day.items) { item in
                row(for: item)
                if item.id != day.items.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func row(for item: MeetingCalendarItem) -> some View {
        switch item {
        case .meeting(let entry, let start):
            Button {
                onSelectMeeting(entry.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(MeetingCalendarFormat.timeRange(start: start, durationSeconds: entry.durationSeconds))
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textTertiary)

                        if entry.status != .completed {
                            Text(entry.status.displayLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(entry.status.displayColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(entry.status.displayColor.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: entry.source) {
                            SyncOriginBadge(label: label)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open meeting notes")

        case .scheduled(let event):
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text("\(MeetingCalendarFormat.time(event.startDate)) – \(MeetingCalendarFormat.time(event.endDate))")
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.textTertiary)

                    Text("Scheduled")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(MuesliTheme.textSecondary.opacity(0.12))
                        .clipShape(Capsule())
                }

                HStack(spacing: 6) {
                    if event.meetingURL != nil, canStartMeeting {
                        Button {
                            onJoinAndRecord(event)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 9))
                                Text("Join & Record")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: NSColor(red: 0.20, green: 0.72, blue: 0.53, alpha: 1.0)))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onCreateNote(event)
                    } label: {
                        Text("Add note")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MuesliTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Create a meeting note for this event")
                }
            }
        }
    }
}

// MARK: - Formatting

enum MeetingCalendarFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayHeadingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter
    }()

    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func timeRange(start: Date, durationSeconds: Double) -> String {
        guard durationSeconds >= 1 else { return time(start) }
        let end = start.addingTimeInterval(durationSeconds)
        return "\(time(start)) – \(time(end))"
    }

    static func dayHeading(_ date: Date) -> String {
        dayHeadingFormatter.string(from: date)
    }

    static func accessibilityDate(_ date: Date) -> String {
        accessibilityFormatter.string(from: date)
    }
}
