import Foundation
import Combine

@MainActor
final class WelcomeViewModel: ScreenViewModel {

    @Published var draft: HouseholdProfile
    init(store: HouseholdStore, account: CloudAccount) {
        draft = store.profile
        super.init(store: store, account: account)
    }
    var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func save() {
        guard isActive, canSave else { return }
        var updated = draft
        if account.signedIn { updated.members = updated.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        updated.onboarded = true
        let previous = store.profile; store.profile = updated
        if !store.save() { store.profile = previous }
    }

}
