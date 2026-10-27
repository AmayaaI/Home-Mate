import Foundation
import Combine
// Authentication stays on the device; no biometric data is stored by HomeMate.
import LocalAuthentication

@MainActor
final class AppLockViewModel: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @Published private(set) var unlocked = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var context: LAContext?
    private var generation = 0

    func lock() {
        generation += 1
        context?.invalidate()
        context = nil
        busy = false
        unlocked = false
    }

    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        guard await authenticate(reason: value ? "Enable protection for your household information." : "Turn off HomeMate app lock.") else { return }
        enabled = value
        unlocked = true
        UserDefaults.standard.set(value, forKey: "appLockEnabled")
    }

    func unlock() async {
        guard enabled, !unlocked, !busy else { return }
        if await authenticate(reason: "Unlock your household information in HomeMate.") { unlocked = true }
    }

    private func authenticate(reason: String) async -> Bool {
        let attempt = generation
        let authentication = LAContext()
        authentication.localizedFallbackTitle = ""
        var error: NSError?
        guard authentication.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            message = error?.localizedDescription ?? "Set up Face ID or Touch ID in device Settings first."
            return false
        }
        busy = true
        message = nil
        context = authentication
        defer { if generation == attempt { busy = false; context = nil } }
        do {
            let success = try await authentication.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return success && generation == attempt
        } catch {
            if generation == attempt { message = "Authentication wasn’t completed. Try again to continue." }
            return false
        }
    }
}
