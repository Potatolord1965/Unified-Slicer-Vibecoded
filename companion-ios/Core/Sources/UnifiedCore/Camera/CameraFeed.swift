import Foundation

/// Where a printer's camera picture comes from. Only printers reachable on the local network have one.
public enum CameraFeed: Equatable, Sendable {
    /// A snapshot URL (polled) or an MJPEG stream.
    case http(url: String, headers: [String: String] = [:])
    /// Bambu A1 / P1 series: JPEG frames over TLS on port 6000, from the printer with `serial`.
    case bambuJpeg(host: String, accessCode: String, serial: String)
    /// Bambu X1 series: RTSP over TLS (H.264); `url` carries the credentials.
    case bambuRtsp(url: String, serial: String)
}

/// A source whose printers have a camera this app can show.
public protocol CameraCapable {
    /// The feed of `deviceId`; throws with a readable message when the camera is off or missing.
    func camera(deviceId: String) async throws -> CameraFeed
}

/// Whether printers of `account` have a camera this app can show. Cloud video uses the makers' own closed services.
public func hasCamera(_ account: Account) -> Bool {
    guard case .lan(let p) = account else { return false }
    return [.bambu, .moonraker, .octoprint, .prusaLink].contains(p.kind)
}
