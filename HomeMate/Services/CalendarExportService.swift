import Foundation

/// A reviewed copy for Apple's event editor, separate from HomeMate's saved record.
struct CalendarEventDraft: Identifiable, Equatable {
    let id: UUID
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String
}

enum CalendarExportOutcome { case saved, cancelled }

enum CalendarExportService {
    static func draft(from record: HouseholdRecord) throws -> CalendarEventDraft {
        guard record.kind == .event || record.kind == .task || record.kind == .maintenance else { throw ExportError.invalid("Only tasks, maintenance and events can be added to Apple Calendar.") }
        if let problem = record.validationError { throw ExportError.invalid(problem) }
        guard record.date > Date() else { throw ExportError.invalid("Choose a future date and time before adding this to Apple Calendar.") }
        let end = record.endDate ?? record.date.addingTimeInterval(3600)
        guard end > record.date else { throw ExportError.invalid("Choose an end time after the start time.") }
        let location = record.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEventDraft(id: record.id,
                                  title: record.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                  startDate: record.date, endDate: end,
                                  location: location?.isEmpty == false ? location : nil,
                                  notes: record.notes)
    }

    private enum ExportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
}
