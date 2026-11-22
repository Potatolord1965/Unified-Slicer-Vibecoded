import SwiftUI
import UIKit
import UnifiedCore

/// The printer's camera. It connects only after a tap, so opening a printer costs no data.
struct CameraPanel: View {
    let printer: PrinterStatus
    let accent: Color
    @EnvironmentObject var model: AppModel
    @State var watching = false
    @State var attempt = 0
    @State var picture: UIImage?
    @State var error: String?

    var body: some View {
        Panel {
            if !watching {
                HStack(spacing: 10) {
                    Image(systemName: "video.fill").foregroundColor(Studio.muted)
                    Text("Camera").font(.subheadline)
                    Spacer()
                    Button("Watch") { watching = true }.foregroundColor(accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        if let error {
                            Text(error).font(.caption).foregroundColor(.white).multilineTextAlignment(.center).padding(16)
                        } else if let picture {
                            Image(uiImage: picture).resizable().scaledToFit()
                        } else {
                            ProgressView().tint(accent)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    HStack {
                        if error != nil { Button("Retry") { attempt += 1 }.foregroundColor(accent) }
                        Spacer()
                        Button("Close") { watching = false }.foregroundColor(Studio.text)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .task(id: "\(printer.key)-\(attempt)") { await watch() }
            }
        }
    }

    private func watch() async {
        error = nil
        picture = nil
        do {
            guard let feed = try await model.camera(printer) else { throw IOError("This printer has no camera the app can show") }
            do {
                for try await bytes in cameraFrames(feed) {
                    if let image = UIImage(data: bytes) { picture = image }
                }
            } catch {
                if !Task.isCancelled { self.error = "Could not reach the camera: \(readable(error))" }
            }
        } catch {
            if !Task.isCancelled { self.error = readable(error) }
        }
    }
}
