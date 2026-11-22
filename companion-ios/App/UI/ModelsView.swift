import SwiftUI
import UniformTypeIdentifiers
import UnifiedCore

/// Model sites that offer printer-ready files, opened inside the app.
enum ModelSite: String, CaseIterable, Hashable {
    case makerworld, nexprint, creality

    var title: String {
        switch self {
        case .makerworld: return "MakerWorld"
        case .nexprint: return "Nexprint"
        case .creality: return "Creality Cloud"
        }
    }

    var subtitle: String {
        switch self {
        case .makerworld: return "Bambu Lab · Print hands the job to Bambu Handy"
        case .nexprint: return "Elegoo · download a sliced file to print it"
        case .creality: return "Creality · download a sliced file to print it"
        }
    }

    var url: URL {
        switch self {
        case .makerworld: return URL(string: "https://makerworld.com/")!
        case .nexprint: return URL(string: "https://www.nexprint.com/")!
        case .creality: return URL(string: "https://www.crealitycloud.com/")!
        }
    }

    var brand: Brand {
        switch self {
        case .makerworld: return .bambu
        case .nexprint: return .elegoo
        case .creality: return .creality
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @State var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Find something to print").font(.title2.weight(.semibold)).padding(.top, 8)
                Text("Browse a model site and download a sliced file; the app then offers to send it to a printer.")
                    .font(.caption).foregroundColor(Studio.muted).padding(.top, 2)
                if let send = model.send {
                    Button { model.sheet = .send } label: {
                        Panel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(send.file) → \(send.printer)").font(.subheadline).foregroundColor(Studio.text).lineLimit(1)
                                AccentProgress(progress: send.percent, accent: send.error != nil ? Studio.bad : Studio.good)
                                Text(send.error ?? send.status).font(.caption).foregroundColor(Studio.muted)
                            }
                            .padding(14)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                }
                SectionLabel("Model sites")
                ForEach(ModelSite.allCases, id: \.self) { site in
                    NavigationLink(value: site) {
                        Panel {
                            HStack(spacing: 14) {
                                Circle().fill(site.brand.color).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.title).foregroundColor(Studio.text)
                                    Text(site.subtitle).font(.caption).foregroundColor(Studio.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(Studio.muted)
                            }
                            .padding(16)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                SectionLabel("From this phone")
                Button { picking = true } label: {
                    Panel {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").foregroundColor(Studio.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Print a file").foregroundColor(Studio.text)
                                Text("G-code saved on the phone or in a cloud drive").font(.caption).foregroundColor(Studio.muted)
                            }
                            Spacer()
                        }
                        .padding(16)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .studioBackground()
        .homeToolbar()
        .navigationDestination(for: ModelSite.self) { BrowserView(site: $0) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): model.openFile(url)
            case .failure(let e): model.alert = readable(e)
            }
        }
    }
}
