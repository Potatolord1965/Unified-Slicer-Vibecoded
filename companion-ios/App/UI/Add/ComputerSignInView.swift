import SwiftUI
import UnifiedCore

/// Signs in with the accounts Unified Slicer on a computer hands over (Accounts > Sign in on phone).
/// `codeText` is the scanned QR code. Nothing is saved until the person confirms the list.
///
/// `askFirst`: the code came in as a link, which any web page or app can open, so nothing is
/// fetched until the person taps Continue. A code scanned in this app is fetched straight away.
struct ComputerSignInView: View {
    let codeText: String
    let askFirst: Bool
    let onScanAgain: () -> Void
    @EnvironmentObject var model: AppModel
    @State var agreed = false
    @State var result: HandedOver?
    @State var error: String?

    private var code: SignInCode? { SignInCode.parse(codeText) }
    private var confirmed: Bool { !askFirst || agreed }

    var body: some View {
        FormScreen("Sign in from computer") {
            if let error {
                ErrorText(error)
                OutlineButton(title: "Scan again", action: onScanAgain)
            } else if let code, !confirmed {
                Hint("Get your sign-ins from Unified Slicer on the computer at \(code.hosts.joined(separator: " or "))? Only continue if you just made a sign-in code on your own computer.")
                PrimaryButton(title: "Continue") { agreed = true }
                OutlineButton(title: "Cancel") { model.sheet = nil }
            } else if let r = result {
                if r.accounts.isEmpty {
                    Hint("\(r.computer) isn't signed in to any printer service this app supports.")
                    OutlineButton(title: "Close") { model.sheet = nil }
                } else {
                    Hint("From \(r.computer). They're stored in this phone's keychain only.")
                    ForEach(r.accounts) { a in
                        let replaces = model.accounts.contains { $0.sameLogin(a) }
                        Panel {
                            HStack(spacing: 14) {
                                Circle().fill(a.brand.color).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.label)
                                    Text(a.kindLabel + (replaces ? " · replaces the saved sign-in" : ""))
                                        .font(.caption).foregroundColor(Studio.muted)
                                }
                            }
                            .padding(16)
                        }
                    }
                    let n = r.accounts.count
                    PrimaryButton(title: n == 1 ? "Sign in to 1 account" : "Sign in to \(n) accounts") { model.importAccounts(r.accounts) }
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Hint("Getting your sign-ins from the computer…")
                }
            }
        }
        .task(id: confirmed) { await fetch() }
    }

    private func fetch() async {
        guard let code else {
            error = "That isn't a Unified Slicer sign-in code. On the computer, open Accounts and click Sign in on phone."
            return
        }
        guard confirmed, result == nil else { return }
        do {
            result = try await SignInHandoff().fetch(code)
        } catch {
            if !Task.isCancelled { self.error = readable(error) }
        }
    }
}
