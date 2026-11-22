import SwiftUI
import UnifiedCore

/// The add / sign-in flow, shown as a sheet that starts at `root` (nil: the list of choices).
struct AddFlow: View {
    let root: AddRoute?
    @EnvironmentObject var model: AppModel
    @State var path: [AddRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let root {
                    screen(root)
                } else {
                    AddChoices(path: $path)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.sheet = nil }
                }
            }
            .navigationDestination(for: AddRoute.self) { screen($0) }
        }
    }

    @ViewBuilder
    private func screen(_ r: AddRoute) -> some View {
        switch r {
        case .bambu(let replace): BambuLoginView(replaceId: replace)
        case .elegoo(let replace): ElegooLoginView(replaceId: replace)
        case .creality(let replace): CrealityLoginView(replaceId: replace)
        case .markforged(let replace): MarkforgedView(replaceId: replace)
        case .lan(let kind, let replace): LanPrinterView(kind: kind, existing: model.accounts.first(where: { $0.id == replace })?.lan)
        case .scan: QRScanView { code in path.append(.signIn(code: code, ask: false)) }
        case .signIn(let code, let ask): ComputerSignInView(codeText: code, askFirst: ask, onScanAgain: { scanAgain() })
        }
    }

    private func scanAgain() {
        if root == .scan {
            path = []
        } else {
            path = [.scan]
        }
    }
}

private struct AddChoices: View {
    @Binding var path: [AddRoute]

    var body: some View {
        FormScreen("Add") {
            SectionLabel("Quickest").padding(.top, -12).padding(.bottom, -8)
            row("From Unified Slicer", "Scan the code under Accounts > Sign in on phone", .other) { path.append(.scan) }
            SectionLabel("Cloud accounts").padding(.bottom, -8)
            row("Bambu Lab", "Bambu Cloud account", .bambu) { path.append(.bambu(replace: nil)) }
            row("Elegoo", "Elegoo Cloud account (Centauri Carbon 2)", .elegoo) { path.append(.elegoo(replace: nil)) }
            row("Creality", "Creality Cloud account", .creality) { path.append(.creality(replace: nil)) }
            row("Markforged", "Eiger organization API keys", .markforged) { path.append(.markforged(replace: nil)) }
            SectionLabel("On your network").padding(.bottom, -8)
            ForEach(LanKind.allCases, id: \.self) { k in
                row(k.label, "Local network", k.brand) { path.append(.lan(k, replace: nil)) }
            }
        }
    }

    private func row(_ title: String, _ subtitle: String, _ brand: Brand, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Panel {
                HStack(spacing: 14) {
                    Circle().fill(brand.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundColor(Studio.text)
                        Text(subtitle).font(.caption).foregroundColor(Studio.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(Studio.muted)
                }
                .padding(16)
            }
        }
        .buttonStyle(.plain)
    }
}

enum BambuStep {
    case password, emailCode, tfa
}

struct BambuLoginView: View {
    let replaceId: String?
    @EnvironmentObject var model: AppModel
    @State var email = ""
    @State var password = ""
    @State var region = "global"
    @State var code = ""
    @State var step = BambuStep.password
    @State var tfaKey = ""
    @State var busy = false
    @State var error: String?

    var body: some View {
        FormScreen("Bambu Lab") {
            Hint("Sign in with your Bambu Lab account. Printers bound to it in Bambu Handy or Bambu Studio appear here.")
            Choice([("global", "Global"), ("china", "China")], $region)
            Field("E-mail", $email, kind: .email)
            if step == .password {
                Field("Password", $password, kind: .secret)
            } else {
                Hint(step == .tfa ? "Enter the code from your authenticator app." : "Bambu e-mailed you a verification code.")
                Field("Code", $code, kind: .number)
            }
            ErrorText(error)
            PrimaryButton(title: step == .password ? "Sign in" : "Verify", busy: busy, accent: Brand.bambu.color) { submit() }
        }
    }

    private func done(_ a: BambuAccount) {
        var account = a
        if let replaceId { account.id = replaceId }
        model.saveAccount(.bambu(account))
    }

    private func submit() {
        busy = true
        error = nil
        let auth = BambuAuth(model.http)
        let mail = email.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                switch step {
                case .password:
                    switch try await auth.login(email: mail, password: password, region: region) {
                    case .signedIn(let a): done(a)
                    case .needsEmailCode: step = .emailCode
                    case .needsTfa(let key):
                        tfaKey = key
                        step = .tfa
                    }
                case .emailCode:
                    done(try await auth.loginWithCode(email: mail, code: code, region: region))
                case .tfa:
                    done(try await auth.loginWithTfa(email: mail, tfaKey: tfaKey, code: code, region: region))
                }
            } catch {
                self.error = friendly(error)
            }
        }
    }
}

struct CrealityLoginView: View {
    let replaceId: String?
    @EnvironmentObject var model: AppModel
    @State var type = 2
    @State var account = ""
    @State var password = ""
    @State var region = "global"
    @State var busy = false
    @State var error: String?

    var body: some View {
        FormScreen("Creality") {
            Hint("Sign in with your Creality Cloud account. Printers bound in Creality Print or the Creality Cloud app appear here.")
            Choice([("global", "Global"), ("china", "China")], $region)
            Choice([(2, "E-mail"), (1, "Phone")], $type)
            Field(type == 2 ? "E-mail" : "Phone with country code", $account, kind: type == 2 ? .email : .phone)
            Field("Password", $password, kind: .secret)
            ErrorText(error)
            PrimaryButton(title: "Sign in", busy: busy, accent: Brand.creality.color) {
                busy = true
                error = nil
                let api = CrealityApi(model.http, region: region, deviceUid: CrealityApi.newDeviceUid())
                let login = account.trimmingCharacters(in: .whitespaces)
                Task {
                    defer { busy = false }
                    do {
                        var a = try await api.login(accountType: type, account: login, password: password)
                        if let replaceId { a.id = replaceId }
                        model.saveAccount(.creality(a))
                    } catch {
                        self.error = friendly(error)
                    }
                }
            }
        }
    }
}

struct MarkforgedView: View {
    let replaceId: String?
    @EnvironmentObject var model: AppModel
    @State var access = ""
    @State var secret = ""
    @State var busy = false
    @State var error: String?

    var body: some View {
        FormScreen("Markforged") {
            Hint("Markforged printers report through Eiger. An organization admin creates API keys in Eiger under Settings > API Access.")
            Field("Access key", $access)
            Field("Secret key", $secret, kind: .secret)
            ErrorText(error)
            let a = access.trimmingCharacters(in: .whitespaces)
            let s = secret.trimmingCharacters(in: .whitespaces)
            PrimaryButton(title: "Connect", busy: busy, enabled: !a.isEmpty && !s.isEmpty, accent: Brand.markforged.color) {
                busy = true
                error = nil
                let account = MarkforgedAccount(id: replaceId ?? "markforged-" + UUID().uuidString.lowercased(), label: "Eiger", accessKey: a, secretKey: s)
                let http = model.http
                Task {
                    defer { busy = false }
                    do {
                        _ = try await EigerSource(account, SourceContext(http: http)).refresh() // checks the keys
                        model.saveAccount(.markforged(account))
                    } catch {
                        self.error = friendly(error)
                    }
                }
            }
        }
    }
}

struct LanPrinterView: View {
    let kind: LanKind
    let existing: LanPrinter?
    @EnvironmentObject var model: AppModel
    @State var name = ""
    @State var host = ""
    @State var secret = ""
    @State var serial = ""
    @State var loaded = false

    var body: some View {
        FormScreen(kind.label) {
            Hint(hint)
            Hint("Only reachable while your phone is on the same network (or a VPN to it).")
            Field("Name", $name)
            Field("IP address or host", $host, kind: .url)
            if let label = kind.secretLabel { Field(label, $secret, kind: .secret) }
            if kind.needsSerial { Field("Serial number", $serial) }
            let h = host.trimmingCharacters(in: .whitespaces)
            let sn = serial.trimmingCharacters(in: .whitespaces).uppercased()
            PrimaryButton(title: "Save", enabled: !h.isEmpty && (!kind.needsSerial || !sn.isEmpty), accent: kind.brand.color) {
                let label = name.trimmingCharacters(in: .whitespaces)
                model.saveAccount(.lan(LanPrinter(
                    id: existing?.id ?? "lan-" + UUID().uuidString.lowercased(),
                    label: label.isEmpty ? kind.label : label,
                    kind: kind,
                    host: h,
                    secret: secret.trimmingCharacters(in: .whitespaces),
                    serial: sn
                )))
            }
        }
        .onAppear {
            guard !loaded, let existing else { return }
            loaded = true
            name = existing.label
            host = existing.host
            secret = existing.secret
            serial = existing.serial
        }
    }

    private var hint: String {
        switch kind {
        case .bambu: return "Turn on LAN mode (or LAN only liveview) on the printer. The IP address, access code and serial number are in the printer's network settings."
        case .elegooCC2: return "The IP address and access code are in the printer's Settings > Network. The default code is 123456."
        case .moonraker: return "Moonraker's address, e.g. 192.168.1.20 or 192.168.1.20:7125. An API key is only needed if Moonraker requires one."
        case .octoprint: return "OctoPrint's address, e.g. octopi.local. Create an API key in OctoPrint under Settings > Application Keys."
        case .prusaLink: return "The printer's IP address and the PrusaLink API key from the printer's network settings."
        }
    }
}
