//
//  WatchRanger.swift
//  NearbyFinderWatch
//

import Foundation
import Combine
import WatchConnectivity
import NearbyInteraction

/// ペアリング済み iPhone を経由して相手（宝）の iPhone と discovery token を交換し、
/// Watch ↔ 宝 iPhone の直接 UWB 測距を行う。
///
/// トークンの経路: Watch → (Watch Connectivity) → 自分の iPhone → (MC) → 相手の iPhone
/// 測距そのものは Watch と相手 iPhone の UWB チップ間で直接行われる。
/// watchOS の Nearby Interaction は距離のみ提供（方向は取得できない）。
final class WatchRanger: NSObject, ObservableObject {
    enum State: Equatable {
        case unsupported      // UWB 非搭載の Watch
        case waitingForPhone  // ペアの iPhone アプリとの接続待ち
        case waitingForPeer   // 相手 iPhone のトークン待ち
        case ranging          // 測距中
    }

    @Published private(set) var state: State = .waitingForPhone
    @Published private(set) var distance: Float?

    private var niSession: NISession?
    private var wcActivated = false

    func start() {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            state = .unsupported
            return
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        startNISession()
    }

    private func startNISession() {
        let session = NISession()
        session.delegate = self
        niSession = session
        sendTokenToPhone()
    }

    private func sendTokenToPhone() {
        guard wcActivated,
              let token = niSession?.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        // applicationContext は最新値の到達が保証され、どちらが後から起動しても受け取れる
        try? WCSession.default.updateApplicationContext(["watchToken": data])
    }

    private func receivedPeerToken(_ data: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else { return }
        niSession?.run(NINearbyPeerConfiguration(peerToken: token))
        state = .ranging
    }
}

extension WatchRanger: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.wcActivated = activationState == .activated
            guard self.wcActivated else { return }
            if self.state == .waitingForPhone {
                self.state = .waitingForPeer
            }
            self.sendTokenToPhone()
            // Watch アプリ起動前に iPhone 側が送っていたトークンを拾う
            if let data = session.receivedApplicationContext["peerToken"] as? Data {
                self.receivedPeerToken(data)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let data = applicationContext["peerToken"] as? Data {
                self.receivedPeerToken(data)
            }
        }
    }
}

extension WatchRanger: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first else { return }
        let distance = object.distance
        Task { @MainActor in
            self.distance = distance
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        Task { @MainActor in
            self.distance = nil
            switch reason {
            case .peerEnded:
                self.niSession?.invalidate()
                self.startNISession()
                self.state = .waitingForPeer
            case .timeout:
                if let config = self.niSession?.configuration {
                    self.niSession?.run(config)
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            if let config = self.niSession?.configuration {
                self.niSession?.run(config)
            }
            self.sendTokenToPhone()
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor in
            self.distance = nil
            self.startNISession()
            self.state = .waitingForPeer
        }
    }
}
