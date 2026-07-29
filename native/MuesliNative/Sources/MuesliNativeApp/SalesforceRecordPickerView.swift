import SwiftUI
import MuesliCore

/// Sheet that lets the user pick a Contact / Lead / Opportunity and log the
/// meeting (summary, optionally the transcript) to Salesforce as a Task.
struct SalesforceRecordPickerView: View {
    let meeting: MeetingRecord
    let controller: MuesliController
    let appState: AppState
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var results: [SalesforceRecord] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selected: SalesforceRecord?
    @State private var includeTranscript: Bool
    @State private var isLogging = false
    @State private var logError: String?
    @State private var loggedTargetName: String?
    @State private var existingLogs: [SalesforceLogEntry] = []

    init(
        meeting: MeetingRecord,
        controller: MuesliController,
        appState: AppState,
        onClose: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.controller = controller
        self.appState = appState
        self.onClose = onClose
        _includeTranscript = State(initialValue: appState.config.salesforceAttachTranscript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(MuesliTheme.surfaceBorder)
            if loggedTargetName != nil {
                successView
            } else if !controller.isSalesforceConnected {
                notConnectedView
            } else {
                pickerBody
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(MuesliTheme.backgroundBase)
        .onAppear {
            existingLogs = controller.salesforceLogs(for: meeting.id)
            controller.prewarmSalesforce()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log to Salesforce")
                    .font(MuesliTheme.title3())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Close") { onClose() }
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(MuesliTheme.spacing16)
    }

    // MARK: - Not connected

    private var notConnectedView: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Spacer()
            Image(systemName: "cloud")
                .font(.system(size: 32))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Salesforce isn't connected yet")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Connect Salesforce in Settings → Meetings, then come back to log this meeting.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Settings") {
                controller.openSalesforceSettings()
                onClose()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(MuesliTheme.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing16)
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(MuesliTheme.success)
            Text("Logged to \(loggedTargetName ?? "Salesforce")")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .multilineTextAlignment(.center)
            Button("Done") { onClose() }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(MuesliTheme.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing16)
    }

    // MARK: - Picker

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if !existingLogs.isEmpty {
                alreadyLoggedBanner
            }

            searchField

            resultsList

            Divider().background(MuesliTheme.surfaceBorder)

            Toggle(isOn: $includeTranscript) {
                Text("Attach full transcript as a file")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .toggleStyle(.checkbox)

            if let logError {
                Text(logError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button {
                    logMeeting()
                } label: {
                    HStack(spacing: 6) {
                        if isLogging { ProgressView().controlSize(.small) }
                        Text(isLogging ? "Logging…" : "Log to Salesforce")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(selected == nil ? MuesliTheme.textTertiary : MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || isLogging)
            }
        }
        .padding(MuesliTheme.spacing16)
        .task(id: searchText) { await runSearch() }
    }

    private var alreadyLoggedBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(existingLogs) { log in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.success)
                    Text("Already logged to \(log.targetName) (\(log.targetType))")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textSecondary)
                    if let url = log.recordURL {
                        Button("View") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MuesliTheme.accent)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MuesliTheme.textTertiary)
            TextField("Search contacts, leads, opportunities…", text: $searchText)
                .textFieldStyle(.plain)
                .font(MuesliTheme.body())
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MuesliTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let searchError {
                    Text(searchError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.vertical, 8)
                } else if results.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && !isSearching {
                    Text("No matching records.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(results) { record in
                        resultRow(record)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 180, maxHeight: 240)
    }

    private func resultRow(_ record: SalesforceRecord) -> some View {
        Button {
            selected = record
        } label: {
            HStack(spacing: 10) {
                Text(record.kind.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if selected == record {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MuesliTheme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected == record ? MuesliTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            results = []
            searchError = nil
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        isSearching = true
        searchError = nil
        let outcome = await controller.searchSalesforce(query)
        if Task.isCancelled { return }
        isSearching = false
        switch outcome {
        case .success(let records):
            results = records
        case .failure(let error):
            searchError = error.localizedDescription
            results = []
        }
    }

    private func logMeeting() {
        guard let target = selected else { return }
        isLogging = true
        logError = nil
        Task {
            let error = await controller.logMeetingToSalesforce(
                meeting: meeting,
                target: target,
                includeTranscript: includeTranscript
            )
            isLogging = false
            if let error {
                logError = error
            } else {
                loggedTargetName = target.name
                existingLogs = controller.salesforceLogs(for: meeting.id)
            }
        }
    }
}
