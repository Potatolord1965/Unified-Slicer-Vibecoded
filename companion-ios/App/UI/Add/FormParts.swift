import SwiftUI
import UnifiedCore

/// A scrolling form with the studio background and a title.
struct FormScreen<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .studioBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct Hint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.subheadline).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorText: View {
    let text: String?

    init(_ text: String?) { self.text = text }

    var body: some View {
        if let text { Text(text).font(.subheadline).foregroundColor(Studio.bad).fixedSize(horizontal: false, vertical: true) }
    }
}

enum FieldKind {
    case text, email, phone, number, url, secret
}

struct Field: View {
    let label: String
    @Binding var value: String
    var kind: FieldKind = .text

    init(_ label: String, _ value: Binding<String>, kind: FieldKind = .text) {
        self.label = label
        _value = value
        self.kind = kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(Studio.muted)
            Group {
                if kind == .secret {
                    SecureField("", text: $value)
                } else {
                    TextField("", text: $value)
                }
            }
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(kind == .text ? .sentences : .never)
            .autocorrectionDisabled(kind != .text)
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(Studio.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Studio.hairline, lineWidth: 1))
        }
    }

    private var keyboard: UIKeyboardType {
        switch kind {
        case .email: return .emailAddress
        case .phone: return .phonePad
        case .number: return .numberPad
        case .url: return .URL
        case .text, .secret: return .default
        }
    }

    private var contentType: UITextContentType? {
        switch kind {
        case .email: return .username
        case .secret: return .password
        case .phone: return .telephoneNumber
        case .number: return .oneTimeCode
        default: return nil
        }
    }
}

/// One option of a few, as chips.
struct Choice<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selected: T

    init(_ options: [(T, String)], _ selected: Binding<T>) {
        self.options = options
        _selected = selected
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                Chip(text: options[i].1, selected: options[i].0 == selected, accent: Studio.neutral) { selected = options[i].0 }
                    .frame(maxWidth: 120)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The form's main button.
struct PrimaryButton: View {
    let title: String
    var busy = false
    var enabled = true
    var accent: Color = Studio.text
    let action: () -> Void

    var body: some View {
        FilledButton(title: title, color: accent, busy: busy, enabled: enabled, action: action)
            .padding(.top, 4)
    }
}

/// A readable reason a sign-in failed.
func friendly(_ e: Error) -> String {
    if let u = e as? URLError, u.code == .notConnectedToInternet { return "No internet connection" }
    return readable(e)
}
