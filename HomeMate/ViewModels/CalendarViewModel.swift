import Foundation
import Combine

@MainActor
final class CalendarViewModel: ScreenViewModel {
    @Published var selectedDate = Date()
    @Published var visibleMonth = Date()
    @Published var filter: RecordKind?
    @Published var editing: HouseholdRecord?
    @Published var choosingDate = false

    var month: CalendarMonth { CalendarMonth(date: visibleMonth) }
    var activities: [HouseholdRecord] {
        activeRecords.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) && (filter == nil || $0.kind == filter) }.sorted { $0.date < $1.date }
    }
    var weekdayNames: [String] {
        let names = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(names[start...] + names[..<start])
    }
    func moveMonth(_ offset: Int) {
        let date = month.moving(offset, preserving: selectedDate)
        visibleMonth = date; selectedDate = date
    }
    func addActivity() {
        let date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        editing = HouseholdRecord(kind: filter ?? .event, title: "", date: date, assignee: recommendedMember)
    }
    func timeLabel(_ record: HouseholdRecord) -> String {
        let start = record.date.formatted(date: .omitted, time: .shortened)
        if let end = record.endDate { return "\(start) – \(end.formatted(date: calendar.isDate(record.date, inSameDayAs: end) ? .omitted : .abbreviated, time: .shortened))" }
        return start
    }
    func phoneURL(_ phone: String?) -> URL? {
        guard let phone else { return nil }
        let cleaned = phone.filter { $0.isNumber || $0 == "+" }
        guard cleaned.filter(\.isNumber).count >= 5 else { return nil }
        return URL(string: "tel:\(cleaned)")
    }
    func assigneeLabel(_ record: HouseholdRecord) -> String {
        AssignmentDisplay.label(for: record.assignee, accountEmail: account.email, localName: profile.name, members: context?.members ?? [], shared: context?.family != nil)
    }

    let calendar = Calendar.current
    func selectDate(_ date: Date) { selectedDate = date; if !calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month) { visibleMonth = date } }
    func activityKinds(on date: Date) -> [RecordKind] { RecordKind.allCases.filter { kind in (filter == nil || kind == filter) && activeRecords.contains { $0.kind == kind && calendar.isDate($0.date, inSameDayAs: date) } } }
    func activityCount(on date: Date) -> Int { activeRecords.filter { calendar.isDate($0.date, inSameDayAs: date) }.count }

}
