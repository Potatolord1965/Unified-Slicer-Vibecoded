import AgoraRtmKit
import Foundation
import UnifiedCore

/// Elegoo's cloud messaging through Agora's RTM 2 SDK, configured as the desktop app does it
/// (string user ids, user-channel "PlainText" messages). The SDK allows one client per process.
final class AgoraRtmConnector: RtmConnector, @unchecked Sendable {
    static let shared = AgoraRtmConnector()
    private let current = Locked<AgoraRtmSession?>(nil)

    func connect(appId: String, userId: String, token: String, onMessage: @escaping @Sendable (String, String) -> Void) async throws -> RtmSession {
        // A session left over from an earlier send.
        current.with { s in
            s?.close()
            s = nil
        }
        let listener = RtmListener(onMessage)
        let config = AgoraRtmClientConfig(appId: appId, userId: userId)
        config.useStringUserId = true
        let client: AgoraRtmClientKit
        do {
            client = try AgoraRtmClientKit(config, delegate: listener)
        } catch {
            throw IOError("Elegoo messaging could not start: \(error.localizedDescription)")
        }
        let session = AgoraRtmSession(client, listener)
        do {
            try await bridge(timeout: 20, timeoutMessage: "Elegoo messaging did not connect") { (r: Resumer<Void>) in
                client.login(token) { _, errorInfo in
                    if let e = errorInfo {
                        r.fail(IOError("Elegoo messaging: sign-in failed (\(e.reason))"))
                    } else {
                        r.succeed(())
                    }
                }
            }
        } catch {
            session.close()
            throw error
        }
        current.set(session)
        return session
    }
}

private final class RtmListener: NSObject, AgoraRtmClientDelegate {
    let onMessage: @Sendable (String, String) -> Void

    init(_ onMessage: @escaping @Sendable (String, String) -> Void) { self.onMessage = onMessage }

    func rtmKit(_ rtmKit: AgoraRtmClientKit, didReceiveMessageEvent event: AgoraRtmMessageEvent) {
        let body: String
        if let text = event.message.stringData {
            body = text
        } else if let raw = event.message.rawData {
            body = String(decoding: raw, as: UTF8.self)
        } else {
            return
        }
        onMessage(event.publisher, body)
    }
}

final class AgoraRtmSession: RtmSession, @unchecked Sendable {
    private let client: AgoraRtmClientKit
    /// The SDK keeps its delegate weakly.
    private let listener: RtmListener
    private let closed = Locked(false)

    fileprivate init(_ client: AgoraRtmClientKit, _ listener: RtmListener) {
        self.client = client
        self.listener = listener
    }

    func publish(peer: String, message: String) async throws {
        let options = AgoraRtmPublishOptions()
        options.channelType = .user
        options.customType = "PlainText"
        try await bridge(timeout: 15, timeoutMessage: "Elegoo messaging: sending timed out") { (r: Resumer<Void>) in
            client.publish(channelName: peer, message: message, option: options) { _, errorInfo in
                if let e = errorInfo {
                    r.fail(IOError("Elegoo messaging: sending failed (\(e.reason))"))
                } else {
                    r.succeed(())
                }
            }
        }
    }

    func close() {
        let first = closed.with { c -> Bool in
            defer { c = true }
            return !c
        }
        if first { _ = client.destroy() }
    }
}
