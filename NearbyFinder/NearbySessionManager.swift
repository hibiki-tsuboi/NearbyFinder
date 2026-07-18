//
//  NearbySessionManager.swift
//  NearbyFinder
//

import Foundation
import Combine
import simd
import MultipeerConnectivity
#if os(iOS)
import NearbyInteraction
import AVFoundation
#endif

enum NearbyStatus: Equatable {
    case unsupported      // UWB 非搭載端末
    case denied           // Nearby Interaction の権限が拒否された
    case searching        // ピア探索中
    case connecting       // 接続済み・discovery token 交換中
    case ranging          // 測距中
}

#if os(iOS)

/// MultipeerConnectivity での discovery token 交換と NISession の管理を束ね、
/// 相手までの距離・方向を publish する。
final class NearbySessionManager: NSObject, ObservableObject {
    @Published private(set) var status: NearbyStatus = .searching
    @Published private(set) var peerName: String?
    @Published private(set) var distance: Float?
    @Published private(set) var direction: simd_float3?
    @Published private(set) var note: String?
    /// 方向が取れないときのユーザー向けヒント（camera assistance の収束状態から生成）
    @Published private(set) var directionHint: String?

    /// discoveryToken 以外のゲームメッセージを上位層（GameManager）へ渡す
    var onGameMessage: ((GameMessage) -> Void)?

    private let multipeer = MultipeerSession()
    private var niSession: NISession?
    private var isPeerConnected = false
    private var searchHintTask: Task<Void, Never>?
    /// ARKit 連携（camera assistance）で方向の精度と取得率を上げる。カメラ拒否時は false に落とす
    private var useCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance

    func start() {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            status = .unsupported
            return
        }
        configureMultipeerHandlers()
        startNISession()
        multipeer.start()
        scheduleSearchHint()
    }

    /// 一定時間見つからないときに確認事項を表示する
    private func scheduleSearchHint() {
        searchHintTask?.cancel()
        searchHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.status == .searching, self.note == nil else { return }
            self.note = "見つからないときは、両方の端末で Wi-Fi と Bluetooth がオンか、設定 > プライバシーとセキュリティ > ローカルネットワーク で NearbyFinder が許可されているかを確認してください"
        }
    }

    // MARK: - セッション管理

    private func startNISession() {
        let session = NISession()
        session.delegate = self
        niSession = session
        // 接続済みのまま作り直した場合は、新しいトークンを送って測距を再開する
        if isPeerConnected {
            shareMyToken()
        }
    }

    private func configureMultipeerHandlers() {
        multipeer.onPeerConnecting = { [weak self] peer in
            guard let self, self.status == .searching else { return }
            self.note = "\(Self.displayName(of: peer)) を発見、接続しています…"
        }
        multipeer.onPeerConnected = { [weak self] peer in
            guard let self else { return }
            self.isPeerConnected = true
            self.peerName = Self.displayName(of: peer)
            self.status = .connecting
            self.note = nil
            self.shareMyToken()
        }
        multipeer.onPeerDisconnected = { [weak self] _ in
            guard let self else { return }
            let wasConnected = self.isPeerConnected
            self.isPeerConnected = false
            self.peerName = nil
            self.distance = nil
            self.direction = nil
            self.directionHint = nil
            if self.status != .unsupported && self.status != .denied {
                self.status = .searching
                self.note = wasConnected ? "接続が切れました。自動的に再接続します…" : nil
            }
        }
        multipeer.onDataReceived = { [weak self] data, _ in
            self?.receivedData(data)
        }
        multipeer.onServiceError = { [weak self] message in
            self?.note = message
        }
    }

    func send(_ message: GameMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        multipeer.send(data)
    }

    private func shareMyToken() {
        guard let token = niSession?.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        send(.discoveryToken(data))
    }

    private func receivedData(_ data: Data) {
        guard let message = try? JSONDecoder().decode(GameMessage.self, from: data) else { return }
        switch message {
        case .discoveryToken(let tokenData):
            adoptPeerToken(tokenData)
        default:
            onGameMessage?(message)
        }
    }

    private func adoptPeerToken(_ tokenData: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        config.isCameraAssistanceEnabled = useCameraAssistance
        niSession?.run(config)
        status = .ranging
        note = nil
    }

    private static func displayName(of peer: MCPeerID) -> String {
        // MultipeerSession が付けたランダム接尾辞を表示用に取り除く
        String(peer.displayName.split(separator: "#").first ?? "相手")
    }
}

extension NearbySessionManager: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        // ピアは 1 台だけなので先頭のオブジェクトが相手
        guard let object = nearbyObjects.first else { return }
        let distance = object.distance
        let direction = object.direction
        Task { @MainActor in
            self.distance = distance
            self.direction = direction
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        Task { @MainActor in
            self.distance = nil
            self.direction = nil
            switch reason {
            case .peerEnded:
                // 相手側がセッションを終了した。作り直してトークンを再交換する
                self.niSession?.invalidate()
                self.startNISession()
                if self.isPeerConnected { self.status = .connecting }
                self.note = "相手のセッションが終了しました。再接続しています…"
            case .timeout:
                // 測距圏外など。設定が残っていれば再実行してリトライする
                if let config = self.niSession?.configuration {
                    self.niSession?.run(config)
                }
                self.note = "相手を見失いました。9m 以内に近づいてみてください"
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence, for object: NINearbyObject?) {
        let hint: String?
        switch convergence.status {
        case .converged, .unknown:
            hint = nil
        case .notConverged(let reasons):
            if reasons.contains(.insufficientHorizontalSweep) {
                hint = "iPhone を左右に振ってみよう"
            } else if reasons.contains(.insufficientVerticalSweep) {
                hint = "iPhone を上下に振ってみよう"
            } else if reasons.contains(.insufficientMovement) {
                hint = "iPhone を持って少し動き回ってみよう"
            } else if reasons.contains(.insufficientLighting) {
                hint = "暗すぎるかも。明るい場所で試そう"
            } else {
                hint = nil
            }
        @unknown default:
            hint = nil
        }
        Task { @MainActor in
            self.directionHint = hint
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        Task { @MainActor in
            self.note = "測距を一時停止中です（両方の端末でアプリを前面にしてください）"
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            if let config = self.niSession?.configuration {
                self.niSession?.run(config)
            }
            // 相手側もセッションを作り直している可能性があるためトークンを再送する
            self.shareMyToken()
            self.note = nil
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor in
            self.distance = nil
            self.direction = nil
            if (error as? NIError)?.code == .userDidNotAllow {
                // 再起動すると拒否 → 即無効化のループになるため、ここで止める
                self.status = .denied
                self.note = "設定 > プライバシーとセキュリティ > Nearby Interaction から許可してください"
                return
            }
            // カメラ拒否で camera assistance が失敗した場合は、補助なしに切り替えて再開する
            let cameraAuth = AVCaptureDevice.authorizationStatus(for: .video)
            if self.useCameraAssistance, cameraAuth == .denied || cameraAuth == .restricted {
                self.useCameraAssistance = false
                self.note = "カメラが許可されていないため、方向補助なしで続行します"
            } else {
                self.note = "セッションを再起動しています…（\(error.localizedDescription)）"
            }
            // セッションを作り直して復帰を試みる
            self.startNISession()
            if self.isPeerConnected { self.status = .connecting }
        }
    }
}

#else

/// Nearby Interaction が使えないプラットフォーム（macOS など）向けのスタブ。
final class NearbySessionManager: NSObject, ObservableObject {
    @Published private(set) var status: NearbyStatus = .unsupported
    @Published private(set) var peerName: String?
    @Published private(set) var distance: Float?
    @Published private(set) var direction: simd_float3?
    @Published private(set) var note: String?
    @Published private(set) var directionHint: String?

    var onGameMessage: ((GameMessage) -> Void)?

    func start() {}
    func send(_ message: GameMessage) {}
}

#endif
