import Foundation
import Combine

@MainActor
final class FamilySharingViewModel: ScreenViewModel {
    @Published var families: [SharedFamily] = []
    @Published var invitations: [FamilyInvitation] = []
    @Published var familyName = ""
    @Published var working = false
    @Published var loading = false
    @Published var error: String?
    @Published var notice: String?

    var api: FamilyAPI { FamilyAPI(account: account) }
    func refresh() async {
        guard isActive, account.signedIn, !loading else { return }
        let scope = account.dataScope; loading = true
        defer { loading = false }
        do {
            let families = try await api.families()
            let invitations = try await api.incomingInvites()
            guard scope == account.dataScope, !Task.isCancelled else { return }
            self.families = families; self.invitations = invitations; error = nil
        } catch { if scope == account.dataScope, !Task.isCancelled { self.families = []; invitations = []; self.error = error.localizedDescription } }
    }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard isActive, !working else { return }; working = true; error = nil
        Task {
            defer { working = false }
            do { try await operation(); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }

    func sendVerification() { run { try await self.account.sendVerificationEmail(); self.notice = "Verification email sent. Open the link, then tap I verified my email." } }
    func checkVerification() { run { try await self.account.refreshIdentity() } }
    func accept(_ invite: FamilyInvitation) { run { try await self.api.accept(invite, displayName: self.profile.name) } }
    var canCreate: Bool { !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && familyName.count <= 100 }
    func create() {
        let name = familyName
        run {
            _ = try await self.api.create(name: name, displayName: self.profile.name, currency: self.profile.currency)
            self.familyName = ""; self.notice = "Family created. Select it under More → Viewing household, then open Members to invite someone using their account email."
        }
    }
    func monitor(active: Bool) async {
        guard active, isActive, account.signedIn else { return }
        do { try await account.refreshIdentity() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        while !Task.isCancelled {
            if !working { await refresh() }
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
        }
    }

}
