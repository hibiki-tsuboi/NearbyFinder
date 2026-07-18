//
//  PhoneWatchRelay.swift
//  NearbyFinder
//

#if os(iOS)
import Foundation
import WatchConnectivity

/// ペアリングされた自分の Apple Watch との橋渡し。
/// Watch の NI トークンを受け取って相手 iPhone へ中継できるよう上位層へ渡し、
/// 相手 iPhone から返ってきたトークンを Watch へ転送する。
final class PhoneWatchRelay: NSObject {
    /// 自分の Watch からトークンが届いたとき（相手 iPhone へ転送する）
    var onWatchToken: ((Data) -> Void)?

    /// 最後に受け取った自分の Watch のトークン（ピア接続時の再送用）
    private(set) var watchToken: Data?

    private var pendingPeerToken: Data?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 相手 iPhone から届いた Watch 用トークンを自分の Watch へ渡す
    func forwardPeerToken(_ data: Data) {
        pendingPeerToken = data
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["peerToken": data])
    }
}

extension PhoneWatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard activationState == .activated else { return }
            // iPhone アプリ起動前に Watch 側が送っていたトークンを拾う
            if let data = session.receivedApplicationContext["watchToken"] as? Data {
                self.watchToken = data
                self.onWatchToken?(data)
            }
            if let pending = self.pendingPeerToken {
                try? session.updateApplicationContext(["peerToken": pending])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let data = applicationContext["watchToken"] as? Data {
                self.watchToken = data
                self.onWatchToken?(data)
            }
        }
    }

    // iOS 側で必須の delegate 要件
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif
