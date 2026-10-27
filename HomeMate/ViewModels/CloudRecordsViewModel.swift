import Foundation
import Combine

@MainActor
final class CloudRecordsViewModel: ScreenViewModel {
    @Published var records: [HouseholdRecord] = []
    @Published var busy = false
    @Published var message = ""
    @Published var selected: HouseholdRecord?
    @Published var pendingDelete: HouseholdRecord?

    func load() async {
        guard isActive, !busy else { return }
        busy = true
        defer { busy = false }
        do { records = try await FirebaseHouseholdAPI(account: account).records(); message = records.isEmpty ? "No cloud records yet. Upload one from an activity editor." : "" }
        catch { records = []; message = error.localizedDescription }
    }

    func deletePending() async {
        guard isActive, !busy, let record = pendingDelete else { return }
        pendingDelete = nil; busy = true; defer { busy = false }
        let scope = account.dataScope
        do {
            try await FirebaseHouseholdAPI(account: account).delete(id: record.id)
            if isCurrent(scope) { records.removeAll { $0.id == record.id }; message = "Cloud copy deleted. Local copies remain." }
        } catch { if isCurrent(scope) { message = error.localizedDescription } }
    }

}
