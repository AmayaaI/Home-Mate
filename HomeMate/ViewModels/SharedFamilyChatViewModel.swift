import Foundation
import Combine

@MainActor
final class SharedFamilyChatViewModel: ScreenViewModel {
    @Published var messages: [FamilyMessage] = []
    @Published var text = ""
    @Published var error: String?
    @Published var sending = false
    @Published var loadingHistory = false
    @Published private(set) var failedDraft: String?
    private var historyLimit = 100

    var api: FamilyAPI { FamilyAPI(account: account) }
    func load() async {
        guard isActive else { return }
        let scope = account.dataScope
        // The opened chat owns its family destination; the dashboard's viewing
        // household does not determine where messages are read or written.
        do { let values = try await api.messages(familyID: family.id, limit: historyLimit); guard isCurrent(scope) else { return }; messages = values; error = nil }
        catch { if isCurrent(scope) { messages = []; self.error = error.localizedDescription } }
    }

    private let initialFamily: SharedFamily
    var family: SharedFamily {
        context?.families.first(where: { $0.id == initialFamily.id }) ?? initialFamily
    }
    init(store: HouseholdStore, account: CloudAccount, family: SharedFamily, context: HouseholdContext? = nil) {
        self.initialFamily = family
        super.init(store: store, account: account, context: context)
    }

    var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000 }
    func send() async {
        guard isActive, canSend else { return }
        let scope = account.dataScope; let draft = text
        sending = true; defer { sending = false }
        do {
            try await api.send(text: draft, displayName: profile.name, familyID: family.id)
            guard isCurrent(scope) else { return }
            text = ""; failedDraft = nil; await load()
        } catch {
            if isCurrent(scope) { self.failedDraft = draft; self.error = error.localizedDescription }
        }
    }
    var canLoadOlder: Bool { messages.count >= historyLimit && historyLimit < 500 }
    func loadOlder() async {
        guard !loadingHistory, canLoadOlder else { return }
        loadingHistory = true; defer { loadingHistory = false }
        historyLimit = min(historyLimit + 100, 500)
        await load()
    }
    func retryFailed() async {
        guard let failedDraft, !sending else { return }
        text = failedDraft
        await send()
    }
    func monitor(active: Bool) async {
        guard active, isActive else { return }
        while !Task.isCancelled {
            await load()
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

}
