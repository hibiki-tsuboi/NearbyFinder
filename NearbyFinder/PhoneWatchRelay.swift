//
//  PhoneWatchRelay.swift
//  NearbyFinder
//

#if os(iOS)
import Foundation
import WatchConnectivity

/// ペアリングされた自分の Apple Watch との橋渡し。
/// Watch の NI トークンを受け取って相手 iPhone へ中継できるよう上位層へ渡し、
/// 相手 iPhone から返ってきたトークンとゲーム状態を Watch へ転送する。
final class PhoneWatchRelay: NSObject {
    /// 自分の Watch からトークンが届いたとき（相手 iPhone へ転送する）
    var onWatchToken: ((Data) -> Void)?

    /// 最後に受け取った自分の Watch のトークン（ピア接続時の再送用）
    private(set) var watchToken: Data?

    /// Watch へ送る applicationContext。updateApplicationContext は辞書全体を
    /// 置き換えるため、トークンとゲーム状態をまとめて保持して毎回丸ごと送る
    private var outgoingContext: [String: Any] = [:]

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 相手 iPhone から届いた Watch 用トークンを自分の Watch へ渡す
    func forwardPeerToken(_ data: Data) {
        outgoingContext["peerToken"] = data
        pushContext()
    }

    /// ゲーム状態（フェーズ・役割・締切・勝敗）を Watch へ渡す
    func updateGameState(_ state: [String: Any]) {
        // ゲーム状態のキーは毎回総入れ替えする（nil になったキーを残さないため）
        outgoingContext = outgoingContext.filter { $0.key == "peerToken" }
        outgoingContext.merge(state) { _, new in new }
        pushContext()
    }

    private func pushContext() {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(outgoingContext)
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
            self.pushContext()
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
