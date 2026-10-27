import Foundation
import Combine

@MainActor
final class SettingsViewModel: ScreenViewModel {
    @Published var draftProfile = HouseholdProfile()

    var appearance: String {
        get { store.preferences.appearance ?? "system" }
        set {
            guard isActive, ["system", "light", "dark"].contains(newValue) else { return }
            var preferences = store.preferences; preferences.appearance = newValue
            store.updatePreferences(preferences)
        }
    }
    var notifications: Bool {
        get { store.profile.reminders }
        set {
            guard isActive else { return }
            let previous = store.profile.reminders
            store.profile.reminders = newValue
            if newValue { Task { await store.enableNotifications() } }
            else if !store.save() { store.profile.reminders = previous }
        }
    }
    func prepareDraft() { draftProfile = store.profile }
    func saveDraft() -> Bool {
        guard isActive else { return false }
        let previous = store.profile; store.profile = draftProfile
        if store.save() { return true }
        store.profile = previous; return false
    }
    func backup() async { guard isActive else { return }; await account.sync(store: store, restore: false) }
    func restore() async { guard isActive else { return }; await account.sync(store: store, restore: true) }

}
