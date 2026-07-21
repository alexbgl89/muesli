import Foundation

// MARK: - Models

/// A Salesforce record a meeting can be logged against.
struct SalesforceRecord: Identifiable, Equatable {
    enum Kind: String {
        case contact = "Contact"
        case lead = "Lead"
        case opportunity = "Opportunity"

        var label: String {
            switch self {
            case .contact: return "Contact"
            case .lead: return "Lead"
            case .opportunity: return "Opportunity"
            }
        }

        /// Activities relate a person via `WhoId` (Contact/Lead) and a
        /// non-human record via `WhatId` (Opportunity/Account/…).
        var relationField: String {
            switch self {
            case .contact, .lead: return "WhoId"
            case .opportunity: return "WhatId"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    /// Account name / company / stage — contextual detail for the picker row.
    let subtitle: String?
}

enum SalesforceClientError: Error, LocalizedError {
    case requestFailed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message): return "Salesforce request failed: \(message)"
        case .permissionDenied(let message):
            return "Salesforce denied the request (check your object/field permissions): \(message)"
        }
    }
}

// MARK: - REST client

/// Thin Salesforce REST client. Mirrors `GoogleCalendarClient`: a bearer token
/// from `SalesforceAuthManager`, per-request `URLSession`, and a 401→refresh→retry
/// loop. Every call targets the org's `instance_url` (from the auth manager),
/// never a hardcoded host.
@MainActor
final class SalesforceClient {
    static let shared = SalesforceClient()

    /// Pinned to the version verified against the target org. `GET /services/data/`
    /// lists supported versions if this ever needs to advance.
    private let apiVersion = "v64.0"

    /// Instance URL used by the most recent successful call — recorded so callers
    /// can build a deep link to the created record.
    private(set) var lastInstanceURL: String?

    /// Resolve the active credential provider from config (Connected App vs CLI).
    private func provider() -> SalesforceTokenProviding {
        let mode = SalesforceAuthMode(rawValue: ConfigStore().load().salesforceAuthMode) ?? .app
        switch mode {
        case .app: return SalesforceAuthManager.shared
        case .cli: return SalesforceCLIBridge.shared
        }
    }

    /// Pre-fetch credentials so the first real request (search/log) doesn't pay
    /// the token-acquisition cost — notably the CLI subprocess spawn.
    func warmUp() async {
        _ = try? await provider().token()
    }

    // MARK: Search (typeahead picker)

    /// Cross-object typeahead using SOSL — one call returns Contacts, Leads and
    /// Opportunities matching a name prefix.
    func search(_ term: String, limit: Int = 20) async throws -> [SalesforceRecord] {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return [] }

        let sosl = "FIND {\(Self.soslEscape(cleaned))*} IN NAME FIELDS RETURNING "
            + "Contact(Id,Name,Email,Account.Name), Lead(Id,Name,Company), "
            + "Opportunity(Id,Name,StageName) LIMIT \(limit)"
        let encoded = sosl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sosl
        let data = try await send("GET", path: "/services/data/\(apiVersion)/search/?q=\(encoded)")
        return Self.parseSearchRecords(data)
    }

    // MARK: Log a completed meeting

    /// Create a completed Task against `target`, optionally attaching the full
    /// transcript as a File — all in one Composite round trip. Returns the new
    /// Task Id.
    @discardableResult
    func logMeeting(
        target: SalesforceRecord,
        subject: String,
        activityDate: Date,
        summary: String,
        transcript: String?
    ) async throws -> String {
        var taskBody: [String: Any] = [
            "Subject": String(subject.prefix(255)),
            "Status": "Completed",
            "TaskSubtype": "Call",
            "ActivityDate": Self.activityDateFormatter.string(from: activityDate),
            "Description": String(summary.prefix(32_000)),
        ]
        taskBody[target.kind.relationField] = target.id

        var requests: [[String: Any]] = [[
            "method": "POST",
            "referenceId": "task",
            "url": "/services/data/\(apiVersion)/sobjects/Task",
            "body": taskBody,
        ]]

        if let transcript, !transcript.isEmpty {
            let base64 = Data(transcript.utf8).base64EncodedString()
            // FirstPublishLocationId auto-creates the ContentDocumentLink to the
            // Task on insert, so we avoid the extra GET + ContentDocumentLink
            // sub-requests (2 sub-requests total instead of 4).
            requests.append([
                "method": "POST",
                "referenceId": "file",
                "url": "/services/data/\(apiVersion)/sobjects/ContentVersion",
                "body": [
                    "Title": "Transcript — \(subject)",
                    "PathOnClient": "transcript.txt",
                    "VersionData": base64,
                    "FirstPublishLocationId": "@{task.id}",
                ],
            ])
        }

        let body: [String: Any] = ["allOrNone": true, "compositeRequest": requests]
        let data = try await send("POST", path: "/services/data/\(apiVersion)/composite", jsonBody: body)
        return try Self.parseCompositeTaskId(data)
    }

    // MARK: - HTTP with 401 refresh-retry

    private func send(_ method: String, path: String, jsonBody: [String: Any]? = nil) async throws -> Data {
        let provider = self.provider()
        var (token, instanceURL) = try await provider.token()
        var refreshed = false
        let payload = try jsonBody.map { try JSONSerialization.data(withJSONObject: $0) }

        while true {
            guard let url = URL(string: instanceURL + path) else {
                throw SalesforceClientError.requestFailed("invalid URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let payload {
                request.httpBody = payload
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 401 && !refreshed {
                refreshed = true
                (token, instanceURL) = try await provider.refreshedToken()
                continue
            }

            guard (200..<300).contains(statusCode) else {
                let message = Self.extractError(data)
                if statusCode == 401 || statusCode == 403 {
                    throw SalesforceClientError.permissionDenied(message)
                }
                throw SalesforceClientError.requestFailed("HTTP \(statusCode): \(message)")
            }
            lastInstanceURL = instanceURL
            return data
        }
    }

    // MARK: - Parsing

    static func parseSearchRecords(_ data: Data) -> [SalesforceRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["searchRecords"] as? [[String: Any]] else {
            return []
        }
        return records.compactMap { record in
            guard let attributes = record["attributes"] as? [String: Any],
                  let type = attributes["type"] as? String,
                  let kind = SalesforceRecord.Kind(rawValue: type),
                  let id = record["Id"] as? String,
                  let name = record["Name"] as? String else {
                return nil
            }
            let subtitle: String?
            switch kind {
            case .contact:
                let account = (record["Account"] as? [String: Any])?["Name"] as? String
                subtitle = account ?? (record["Email"] as? String)
            case .lead:
                subtitle = record["Company"] as? String
            case .opportunity:
                subtitle = record["StageName"] as? String
            }
            return SalesforceRecord(id: id, kind: kind, name: name, subtitle: subtitle)
        }
    }

    static func parseCompositeTaskId(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["compositeResponse"] as? [[String: Any]] else {
            throw SalesforceClientError.requestFailed("malformed composite response")
        }
        // Surface the first failed sub-request (allOrNone rolls everything back).
        for response in responses {
            let statusCode = response["httpStatusCode"] as? Int ?? 0
            if !(200..<300).contains(statusCode) {
                throw SalesforceClientError.requestFailed(extractCompositeError(response["body"]))
            }
        }
        for response in responses where (response["referenceId"] as? String) == "task" {
            if let body = response["body"] as? [String: Any], let id = body["id"] as? String {
                return id
            }
        }
        throw SalesforceClientError.requestFailed("no Task id in composite response")
    }

    /// Salesforce REST errors are usually a JSON array `[{message, errorCode}]`,
    /// but OAuth/other endpoints return an object. Handle both.
    static func extractError(_ data: Data) -> String {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let message = array.first?["message"] as? String {
            return message
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (object["message"] as? String) ?? (object["error_description"] as? String) {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown error"
    }

    static func extractCompositeError(_ body: Any?) -> String {
        if let array = body as? [[String: Any]], let message = array.first?["message"] as? String {
            return message
        }
        if let object = body as? [String: Any], let message = object["message"] as? String {
            return message
        }
        return "request failed"
    }

    /// Escape SOSL reserved characters so user input can't break the query.
    static func soslEscape(_ term: String) -> String {
        let reserved = Set("?&|!{}[]()^~*:\\\"'+-")
        var out = ""
        for character in term {
            if reserved.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Task.ActivityDate is date-only.
    private static let activityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
