import Foundation
import Combine

@MainActor
final class LoginViewModel: ScreenViewModel {
    @Published var registering = false
    @Published var confirmation = ""
    @Published var showingError = false
    @Published var localError: String?

    var valid: Bool {
        InputValidation.email(account.email) && !account.password.isEmpty && (!registering || (!confirmation.isEmpty && confirmation == account.password && account.password.count >= 6))
    }

    func submit() async {
        guard initialScope == account.dataScope, !account.busy else { return }
        localError = nil
        guard valid else {
            localError = registering && !confirmation.isEmpty && confirmation != account.password
                ? "The passwords do not match."
                : registering ? "Enter a valid email, a password of at least 6 characters, and matching confirmation." : "Enter a valid email and password."
            showingError = true; return
        }
        if !(await account.authenticate(register: registering)) { showingError = true }
    }
    func switchMode() {
        registering.toggle(); localError = nil; account.message = ""; account.password = ""; confirmation = ""
    }

}
