import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Salesforce integration", .serialized)
@MainActor
struct SalesforceIntegrationTests {

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-sf-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    // MARK: - SalesforceAuthManager.normalizeHost

    @Test("normalizeHost defaults empty input and strips scheme/path")
    func normalizeHost() {
        #expect(SalesforceAuthManager.normalizeHost("") == "login.salesforce.com")
        #expect(SalesforceAuthManager.normalizeHost("   ") == "login.salesforce.com")
        #expect(SalesforceAuthManager.normalizeHost("test.salesforce.com") == "test.salesforce.com")
        #expect(SalesforceAuthManager.normalizeHost("https://acme.my.salesforce.com/") == "acme.my.salesforce.com")
        #expect(SalesforceAuthManager.normalizeHost("http://acme.my.salesforce.com/services/oauth2/token") == "acme.my.salesforce.com")
    }

    // MARK: - SalesforceRecord.Kind mapping

    @Test("Contact/Lead relate via WhoId, Opportunity via WhatId")
    func kindRelationField() {
        #expect(SalesforceRecord.Kind.contact.relationField == "WhoId")
        #expect(SalesforceRecord.Kind.lead.relationField == "WhoId")
        #expect(SalesforceRecord.Kind.opportunity.relationField == "WhatId")
        #expect(SalesforceRecord.Kind.contact.label == "Contact")
        #expect(SalesforceRecord.Kind.opportunity.label == "Opportunity")
    }

    // MARK: - SOSL escaping

    @Test("soslEscape escapes reserved characters, leaves plain text intact")
    func soslEscape() {
        #expect(SalesforceClient.soslEscape("Acme") == "Acme")
        #expect(SalesforceClient.soslEscape("Acme & Co (EU)") == "Acme \\& Co \\(EU\\)")
        #expect(SalesforceClient.soslEscape("a+b:c") == "a\\+b\\:c")
    }

    // MARK: - Search response parsing

    @Test("parseSearchRecords maps each object type and drops unsupported types")
    func parseSearchRecords() {
        let json = #"""
        {
          "searchRecords": [
            {"attributes": {"type": "Contact"}, "Id": "003x", "Name": "Jane Doe", "Email": "jane@acme.com", "Account": {"Name": "Acme Inc"}},
            {"attributes": {"type": "Lead"}, "Id": "00Qx", "Name": "John Lead", "Company": "LeadCo"},
            {"attributes": {"type": "Opportunity"}, "Id": "006x", "Name": "Big Deal", "StageName": "Negotiate"},
            {"attributes": {"type": "Account"}, "Id": "001x", "Name": "Unsupported"}
          ]
        }
        """#
        let records = SalesforceClient.parseSearchRecords(Data(json.utf8))
        #expect(records.count == 3) // Account dropped

        let contact = records[0]
        #expect(contact.kind == .contact)
        #expect(contact.name == "Jane Doe")
        #expect(contact.subtitle == "Acme Inc") // Account name preferred over email

        #expect(records[1].kind == .lead)
        #expect(records[1].subtitle == "LeadCo")

        #expect(records[2].kind == .opportunity)
        #expect(records[2].subtitle == "Negotiate")
    }

    @Test("parseSearchRecords falls back to email when contact has no account")
    func parseSearchRecordsContactEmailFallback() {
        let json = #"""
        {"searchRecords": [{"attributes": {"type": "Contact"}, "Id": "003y", "Name": "No Account", "Email": "solo@x.com"}]}
        """#
        let records = SalesforceClient.parseSearchRecords(Data(json.utf8))
        #expect(records.first?.subtitle == "solo@x.com")
    }

    @Test("parseSearchRecords returns empty on malformed JSON")
    func parseSearchRecordsMalformed() {
        #expect(SalesforceClient.parseSearchRecords(Data("not json".utf8)).isEmpty)
        #expect(SalesforceClient.parseSearchRecords(Data(#"{"foo": 1}"#.utf8)).isEmpty)
    }

    // MARK: - Composite response parsing

    @Test("parseCompositeTaskId returns the Task id from a successful composite response")
    func parseCompositeTaskIdSuccess() throws {
        let json = #"""
        {"compositeResponse": [
          {"body": {"id": "00T00000ABCDEFG", "success": true}, "httpStatusCode": 201, "referenceId": "task"},
          {"body": {"id": "068000000FILE01", "success": true}, "httpStatusCode": 201, "referenceId": "file"}
        ]}
        """#
        let taskID = try SalesforceClient.parseCompositeTaskId(Data(json.utf8))
        #expect(taskID == "00T00000ABCDEFG")
    }

    @Test("parseCompositeTaskId throws on a failed sub-request")
    func parseCompositeTaskIdFailure() {
        let json = #"""
        {"compositeResponse": [
          {"body": [{"message": "Required field missing: Subject", "errorCode": "REQUIRED_FIELD_MISSING"}], "httpStatusCode": 400, "referenceId": "task"}
        ]}
        """#
        #expect(throws: SalesforceClientError.self) {
            _ = try SalesforceClient.parseCompositeTaskId(Data(json.utf8))
        }
    }

    // MARK: - Error extraction

    @Test("extractError reads Salesforce array and object error shapes")
    func extractError() {
        #expect(SalesforceClient.extractError(Data(#"[{"message": "boom", "errorCode": "X"}]"#.utf8)) == "boom")
        #expect(SalesforceClient.extractError(Data(#"{"message": "bad request"}"#.utf8)) == "bad request")
        #expect(SalesforceClient.extractError(Data(#"{"error_description": "invalid grant"}"#.utf8)) == "invalid grant")
    }

    // MARK: - Activity date parsing

    @Test("salesforceActivityDate parses ISO-8601 with and without fractional seconds")
    func activityDateParsing() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let expected = iso.date(from: "2026-07-21T15:30:00Z")!
        #expect(MuesliController.salesforceActivityDate(from: "2026-07-21T15:30:00Z") == expected)

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedFrac = isoFrac.date(from: "2026-07-21T15:30:00.500Z")!
        #expect(MuesliController.salesforceActivityDate(from: "2026-07-21T15:30:00.500Z") == expectedFrac)
    }

    @Test("salesforceActivityDate falls back to now on unparseable input")
    func activityDateFallback() {
        let result = MuesliController.salesforceActivityDate(from: "not-a-date")
        #expect(abs(result.timeIntervalSinceNow) < 5)
    }

    // MARK: - DictationStore salesforce_logs round-trip

    @Test("recordSalesforceLog persists and salesforceLogs reads back newest-first")
    func salesforceLogRoundTrip() throws {
        let store = try makeStore()
        let start = Date()
        try store.insertMeeting(
            title: "Quarterly Review",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(1800),
            rawTranscript: "transcript",
            formattedNotes: "notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: nil,
            selectedTemplateName: nil,
            selectedTemplateKind: nil,
            selectedTemplatePrompt: nil
        )
        let meetingID = try #require(try store.recentMeetings(limit: 1).first).id

        try store.recordSalesforceLog(
            meetingID: meetingID, taskID: "00T1", targetID: "003a", targetType: "Contact",
            targetName: "Jane Doe", instanceURL: "https://acme.my.salesforce.com",
            includedTranscript: true, loggedAt: 100
        )
        try store.recordSalesforceLog(
            meetingID: meetingID, taskID: "00T2", targetID: "006b", targetType: "Opportunity",
            targetName: "Big Deal", instanceURL: "https://acme.my.salesforce.com",
            includedTranscript: false, loggedAt: 200
        )

        let logs = try store.salesforceLogs(meetingID: meetingID)
        #expect(logs.count == 2)
        // Newest first (logged_at DESC)
        #expect(logs[0].taskID == "00T2")
        #expect(logs[0].targetType == "Opportunity")
        #expect(logs[0].includedTranscript == false)
        #expect(logs[0].recordURL?.absoluteString == "https://acme.my.salesforce.com/00T2")
        #expect(logs[1].taskID == "00T1")
        #expect(logs[1].targetName == "Jane Doe")
        #expect(logs[1].includedTranscript == true)
    }

    @Test("salesforceLogs is empty for a meeting that was never logged")
    func salesforceLogsEmpty() throws {
        let store = try makeStore()
        #expect(try store.salesforceLogs(meetingID: 999).isEmpty)
    }

    @Test("SalesforceLogEntry.recordURL is nil without an instance URL")
    func recordURLRequiresInstance() {
        let entry = SalesforceLogEntry(
            id: 1, meetingID: 1, taskID: "00T1", targetID: "003a", targetType: "Contact",
            targetName: "Jane", instanceURL: "", includedTranscript: false, loggedAt: 0
        )
        #expect(entry.recordURL == nil)
    }
}
