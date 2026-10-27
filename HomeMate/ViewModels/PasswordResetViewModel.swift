import Foundation
import Combine

@MainActor
final class PasswordResetViewModel: ScreenViewModel {
    @Published var email = ""

    func send() async { await account.sendPasswordReset(to: email) }
    func prepare() { email = account.email }

}
