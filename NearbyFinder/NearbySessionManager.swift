//
//  NearbySessionManager.swift
//  NearbyFinder
//

import Foundation
import Combine
import os
import simd
import MultipeerConnectivity
#if os(iOS)
import NearbyInteraction
import AVFoundation
import ARKit
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
    /// camera assistance 由来の水平方位角（ラジアン）。iPhone 14 以降は UWB 単体の
    /// direction が常に nil（supportsDirectionMeasurement == false）のため、
    /// 矢印表示はこの値にフォールバックする。ARKit の収束後にのみ得られる
    @Published private(set) var horizontalAngle: Float?
    @Published private(set) var note: String?
    /// 方向が取れないときのユーザー向けヒント（camera assistance の収束状態から生成）
    @Published private(set) var directionHint: String?
    /// ARKit ワールド座標系での相手の推定位置（camera assistance 収束後に得られる）。AR 演出用
    @Published private(set) var peerWorldTransform: simd_float4x4?

    /// discoveryToken 以外のゲームメッセージを上位層（GameManager）へ渡す
    var onGameMessage: ((GameMessage) -> Void)?
    /// MC 接続確立時に呼ばれる。isLeader は両端末で必ず一方だけ true（代表側）
    var onConnected: ((_ isLeader: Bool) -> Void)?

    private let multipeer = MultipeerSession()
    private var niSession: NISession?
    private var isStarted = false
    private var isPeerConnected = false
    private var searchHintTask: Task<Void, Never>?
    /// MC は繋がったのに NI トークン交換が完了しないときの再送ループ
    private var tokenRetryTask: Task<Void, Never>?
    /// 受信済みの相手の NI トークン。NI セッションを作り直したときに再適用する
    /// （相手が自分のトークンを再送してくれるとは限らない）
    private var peerTokenData: Data?
    /// NI セッションを作り直した世代を識別する ID。古い token / ack を混ぜないために使う
    private var localTokenSessionID = UUID()
    private var peerTokenSessionID: UUID?
    /// 現在の NI セッションへ相手 token を適用済みか
    private var didAdoptPeerToken = false
    /// 相手が現在の自分 token を適用した ack を受信済みか
    private var didReceiveAckForLocalToken = false
    /// 相手 token より先に ack が届いた場合に、送信元の NI セッション ID を一時保持する
    private var pendingAckFromPeerSessionID: UUID?
    /// 診断ログ（Console.app で subsystem: jp.hibiki.NearbyFinder を絞り込むと追える）
    private let log = Logger(subsystem: "jp.hibiki.NearbyFinder", category: "nearby")
    /// ARKit 連携（camera assistance）で方向の精度と取得率を上げる。カメラ拒否時は false に落とす
    private var useCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance

    /// 自分のペアの Apple Watch との橋渡し
    private let watchRelay = PhoneWatchRelay()
    /// 相手プレイヤーの Apple Watch と測距するセッション（相手の Watch トークンを受けたら作る）
    private var watchPeerSession: NISession?
    private let watchPeerDelegate = WatchPeerSessionDelegate()

    /// camera assistance と AR 演出（宝箱の描画）で共有する ARSession
    let arSession = ARSession()

    /// start() を呼ぶ前（タイトル画面）から参照できる UWB 対応判定
    var isDeviceSupported: Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    func start() {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            status = .unsupported
            return
        }
        guard !isStarted else {
            refreshConnectionAfterForeground()
            return
        }
        isStarted = true
        if useCameraAssistance {
            // 自前の ARSession を NI と共有すると、worldTransform(for:) の座標系で
            // AR コンテンツを描画できる
            arSession.run(ARWorldTrackingConfiguration())
        }
        configureMultipeerHandlers()
        startNISession()
        multipeer.start()
        scheduleSearchHint()
        watchRelay.onWatchToken = { [weak self] data in
            self?.send(.watchToken(data))
        }
        watchRelay.start()
    }

    /// ペアの Apple Watch へゲーム状態を中継する
    func relayGameStateToWatch(phase: String, role: String?, deadline: Date?, outcome: String?) {
        var state: [String: Any] = ["phase": phase]
        if let role { state["role"] = role }
        if let deadline { state["deadline"] = deadline }
        if let outcome { state["outcome"] = outcome }
        watchRelay.updateGameState(state)
    }

    /// タイトル画面へ戻るときに通信を全て止める。start() で再開できる
    func stop() {
        isStarted = false
        searchHintTask?.cancel()
        tokenRetryTask?.cancel()
        peerTokenData = nil
        peerTokenSessionID = nil
        didAdoptPeerToken = false
        didReceiveAckForLocalToken = false
        pendingAckFromPeerSessionID = nil
        multipeer.stop()
        niSession?.invalidate()
        niSession = nil
        watchPeerSession?.invalidate()
        watchPeerSession = nil
        arSession.pause()
        isPeerConnected = false
        peerName = nil
        distance = nil
        direction = nil
        horizontalAngle = nil
        directionHint = nil
        peerWorldTransform = nil
        note = nil
        if status != .unsupported && status != .denied {
            status = .searching
        }
    }

    /// フォアグラウンド復帰時に MC と NI の両方を監査し、表示だけ残った接続を回収する。
    func refreshConnectionAfterForeground() {
        guard isStarted else { return }
        multipeer.refreshConnection()
        guard status != .denied && status != .unsupported else { return }
        guard isPeerConnected else { return }
        if let config = niSession?.configuration {
            niSession?.run(config)
        }
        // MC は生きていても相手の NI セッションが変わっている可能性があるため再通知する
        shareMyToken()
        if !hasCompletedTokenHandshake {
            status = .connecting
            startTokenRetry()
        }
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
        if useCameraAssistance {
            // 設定を run する前に呼ぶ必要がある
            session.setARSession(arSession)
        }
        niSession = session
        localTokenSessionID = UUID()
        didReceiveAckForLocalToken = false
        pendingAckFromPeerSessionID = nil
        didAdoptPeerToken = false
        // 接続済みのまま作り直した場合は、新しいトークンを送って測距を再開する
        if isPeerConnected {
            status = .connecting
            if let peerTokenData, let peerTokenSessionID {
                // 手元に残っている相手トークンで測距を再開する
                didAdoptPeerToken = runConfiguration(with: peerTokenData)
                if didAdoptPeerToken {
                    send(.discoveryTokenAck(
                        tokenSessionID: peerTokenSessionID,
                        senderSessionID: localTokenSessionID
                    ))
                }
            }
            shareMyToken()
            startTokenRetry()
        }
    }

    private func configureMultipeerHandlers() {
        multipeer.onPeerConnecting = { [weak self] peer in
            guard let self, self.status == .searching else { return }
            self.note = "\(Self.displayName(of: peer)) を発見、接続しています…"
        }
        multipeer.onPeerConnected = { [weak self] peer in
            guard let self, self.isStarted else { return }
            self.isPeerConnected = true
            self.peerName = Self.displayName(of: peer)
            self.status = .connecting
            self.note = nil
            self.peerTokenData = nil
            self.peerTokenSessionID = nil
            self.didAdoptPeerToken = false
            self.didReceiveAckForLocalToken = false
            self.pendingAckFromPeerSessionID = nil
            self.distance = nil
            self.direction = nil
            self.horizontalAngle = nil
            self.peerWorldTransform = nil
            self.shareMyToken()
            self.startTokenRetry()
            // 自分の Watch が既にトークンを送ってきていれば、相手へも中継する
            if let watchToken = self.watchRelay.watchToken {
                self.send(.watchToken(watchToken))
            }
            self.onConnected?(self.multipeer.isDesignatedLeader(vs: peer))
        }
        multipeer.onPeerDisconnected = { [weak self] _ in
            guard let self else { return }
            let wasConnected = self.isPeerConnected
            self.isPeerConnected = false
            self.tokenRetryTask?.cancel()
            self.peerTokenData = nil
            self.peerTokenSessionID = nil
            self.didAdoptPeerToken = false
            self.didReceiveAckForLocalToken = false
            self.pendingAckFromPeerSessionID = nil
            self.peerName = nil
            self.distance = nil
            self.direction = nil
            self.horizontalAngle = nil
            self.directionHint = nil
            self.peerWorldTransform = nil
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

    @discardableResult
    func send(_ message: GameMessage) -> Bool {
        do {
            let data = try JSONEncoder().encode(message)
            return multipeer.send(data)
        } catch {
            log.error("GameMessage encode 失敗: \(error.localizedDescription)")
            return false
        }
    }

    private func shareMyToken() {
        guard let token = niSession?.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else {
            log.warning("shareMyToken: トークンを送れない（discoveryToken=\(self.niSession?.discoveryToken == nil ? "nil" : "あり")）")
            return
        }
        log.info("shareMyToken: 自分のトークンを送信 session=\(self.localTokenSessionID.uuidString)")
        send(.discoveryToken(sessionID: localTokenSessionID, data: data))
    }

    /// トークン送信は一度きりだと取りこぼす経路がある（discoveryToken がまだ nil、
    /// 送信の失敗など）ため、相手から現在 session ID の ack が届くまで数秒おきに再送する
    private func startTokenRetry() {
        tokenRetryTask?.cancel()
        tokenRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                guard self.isPeerConnected, !self.hasCompletedTokenHandshake else { return }
                self.shareMyToken()
            }
        }
    }

    private func receivedData(_ data: Data) {
        let message: GameMessage
        do {
            message = try JSONDecoder().decode(GameMessage.self, from: data)
        } catch {
            log.error("GameMessage decode 失敗（異なるビルドの可能性）: \(error.localizedDescription)")
            note = "相手とアプリのバージョンが異なる可能性があります"
            return
        }
        switch message {
        case .discoveryToken(let sessionID, let tokenData):
            adoptPeerToken(tokenData, sessionID: sessionID)
        case .discoveryTokenAck(let tokenSessionID, let senderSessionID):
            adoptTokenAck(tokenSessionID: tokenSessionID, senderSessionID: senderSessionID)
        case .watchToken(let tokenData):
            adoptWatchToken(tokenData)
        case .watchPeerToken(let tokenData):
            watchRelay.forwardPeerToken(tokenData)
        default:
            onGameMessage?(message)
        }
    }

    /// 相手プレイヤーの Apple Watch のトークンを受け取り、Watch 用の測距セッションを開始して
    /// こちらのトークンを返送する。距離は Watch 側だけが使うため、この端末では表示しない。
    private func adoptWatchToken(_ tokenData: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else { return }
        watchPeerSession?.invalidate()
        let session = NISession()
        session.delegate = watchPeerDelegate
        watchPeerSession = session
        session.run(NINearbyPeerConfiguration(peerToken: token))
        guard let myToken = session.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: myToken, requiringSecureCoding: true)
        else { return }
        send(.watchPeerToken(data))
    }

    private func adoptPeerToken(_ tokenData: Data, sessionID: UUID) {
        guard isStarted, isPeerConnected else {
            log.info("adoptPeerToken: 未接続中の遅延 token を無視")
            return
        }

        let isNewPeerSession = peerTokenSessionID != sessionID
        if isNewPeerSession {
            log.info("adoptPeerToken: 新しい相手セッションを受信 session=\(sessionID.uuidString)")
            peerTokenSessionID = sessionID
            peerTokenData = nil
            didAdoptPeerToken = false
            // 相手が NI セッションを作り直した場合、新セッションが自分 token を
            // 適用したことを改めて確認する必要がある
            didReceiveAckForLocalToken = pendingAckFromPeerSessionID == sessionID
            pendingAckFromPeerSessionID = nil
            distance = nil
            direction = nil
            horizontalAngle = nil
            peerWorldTransform = nil
            status = .connecting
        } else if didAdoptPeerToken {
            // ack 自体が取りこぼされて相手が再送している可能性があるので毎回答える
            log.info("adoptPeerToken: 同じ相手 token を再受信 → ack を再送")
            send(.discoveryTokenAck(tokenSessionID: sessionID, senderSessionID: localTokenSessionID))
            completeTokenHandshakeIfPossible()
            return
        }

        guard runConfiguration(with: tokenData) else {
            log.error("adoptPeerToken: token の適用に失敗 session=\(sessionID.uuidString)")
            return
        }
        peerTokenData = tokenData
        didAdoptPeerToken = true
        send(.discoveryTokenAck(tokenSessionID: sessionID, senderSessionID: localTokenSessionID))

        if isNewPeerSession {
            // 新しい相手 NI セッションにも自分 token を必ず渡し直す
            shareMyToken()
            startTokenRetry()
        }
        completeTokenHandshakeIfPossible()
    }

    private func adoptTokenAck(tokenSessionID: UUID, senderSessionID: UUID) {
        guard isStarted, isPeerConnected else { return }
        guard tokenSessionID == localTokenSessionID else {
            log.info("adoptTokenAck: 古い自分セッション宛ての ack を無視")
            return
        }
        guard let peerTokenSessionID else {
            // reliable の順序外や直前の送信失敗に備え、相手 token 到着まで保留する
            pendingAckFromPeerSessionID = senderSessionID
            log.info("adoptTokenAck: 相手 token より先に ack を受信。保留する")
            return
        }
        guard peerTokenSessionID == senderSessionID else {
            log.info("adoptTokenAck: 古い相手セッションからの ack を無視")
            return
        }
        didReceiveAckForLocalToken = true
        log.info("adoptTokenAck: 自分 token の適用確認 session=\(tokenSessionID.uuidString)")
        completeTokenHandshakeIfPossible()
    }

    private var hasCompletedTokenHandshake: Bool {
        isPeerConnected && didAdoptPeerToken && didReceiveAckForLocalToken
    }

    private func completeTokenHandshakeIfPossible() {
        guard hasCompletedTokenHandshake else {
            if isPeerConnected, status != .denied && status != .unsupported {
                status = .connecting
            }
            return
        }
        log.info("token handshake 完了")
        status = .ranging
        note = nil
        tokenRetryTask?.cancel()
    }

    /// 相手トークンで NI コンフィグを実行して測距を開始する。トークンが壊れていれば false
    @discardableResult
    private func runConfiguration(with tokenData: Data) -> Bool {
        guard isStarted, isPeerConnected, status != .denied, status != .unsupported, let niSession else { return false }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else { return false }
        let config = NINearbyPeerConfiguration(peerToken: token)
        config.isCameraAssistanceEnabled = useCameraAssistance
        niSession.run(config)
        log.info("runConfiguration: NI config 実行（cameraAssistance=\(self.useCameraAssistance)）")
        return true
    }

    private static func displayName(of peer: MCPeerID) -> String {
        // MultipeerSession が付けたランダム接尾辞を表示用に取り除く
        String(peer.displayName.split(separator: "#").first ?? "相手")
    }

    private func isCurrentNISession(_ callbackSessionID: ObjectIdentifier) -> Bool {
        guard isStarted, let niSession else { return false }
        return callbackSessionID == ObjectIdentifier(niSession)
    }
}

extension NearbySessionManager: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let callbackSessionID = ObjectIdentifier(session)
        // ピアは 1 台だけなので先頭のオブジェクトが相手
        guard let object = nearbyObjects.first else { return }
        let distance = object.distance
        let direction = object.direction
        let horizontalAngle = object.horizontalAngle
        // camera assistance が収束していれば ARKit ワールド座標での相手の位置が得られる
        let worldTransform = session.worldTransform(for: object)
        Task { @MainActor in
            guard self.isCurrentNISession(callbackSessionID) else {
                self.log.info("古い NISession の didUpdate を無視")
                return
            }
            // 距離の出はじめ／途切れの遷移だけログする（毎フレームは出さない）
            if (distance == nil) != (self.distance == nil) {
                self.log.info("didUpdate: 距離 \(distance == nil ? "ロスト" : "取得開始")")
            }
            self.distance = distance
            self.direction = direction
            self.horizontalAngle = horizontalAngle
            self.peerWorldTransform = worldTransform
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        let callbackSessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrentNISession(callbackSessionID) else {
                self.log.info("古い NISession の didRemove を無視")
                return
            }
            self.log.warning("didRemove: reason=\(reason == .peerEnded ? "peerEnded" : reason == .timeout ? "timeout" : "unknown")")
            self.distance = nil
            self.direction = nil
            self.horizontalAngle = nil
            self.peerWorldTransform = nil
            switch reason {
            case .peerEnded:
                // 相手側のセッションが終了した（エラー復帰などで作り直している）。
                // 自分のセッションは無事なので invalidate せず、古い相手トークンを
                // 捨てて新しいトークンを待つ。
                // 注意: 以前はここで自分も invalidate し、保存済みトークンで測距を
                // 再開していたが、相手の死んだセッションのトークンで config を実行
                // すると相手側にも peerEnded が飛び、相互無効化が無限に続いて
                // エラー表示のないまま距離が永遠に届かないデグレになっていた。
                // このハンドラでは自分のセッションを絶対に invalidate しないこと。
                self.peerTokenData = nil
                self.peerTokenSessionID = nil
                self.didAdoptPeerToken = false
                self.didReceiveAckForLocalToken = false
                self.pendingAckFromPeerSessionID = nil
                if self.isPeerConnected { self.status = .connecting }
                self.note = "相手の測距セッションが再起動しました。再接続しています…"
                // 相手は作り直した直後で、こちらの新しいトークンは持っている
                // （こちらは作り直していない）が、念のため再送して交換を確実にする
                self.shareMyToken()
                self.startTokenRetry()
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
        let callbackSessionID = ObjectIdentifier(session)
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
            guard self.isCurrentNISession(callbackSessionID) else { return }
            self.directionHint = hint
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        let callbackSessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrentNISession(callbackSessionID) else { return }
            self.note = "測距を一時停止中です（両方の端末でアプリを前面にしてください）"
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        let callbackSessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrentNISession(callbackSessionID) else { return }
            if let config = self.niSession?.configuration {
                self.niSession?.run(config)
            }
            // 相手側もセッションを作り直している可能性があるためトークンを再送する
            self.shareMyToken()
            self.note = nil
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let callbackSessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard self.isCurrentNISession(callbackSessionID) else {
                self.log.info("古い NISession の didInvalidate を無視")
                return
            }
            self.log.error("didInvalidate: \(error.localizedDescription)")
            self.niSession = nil
            self.distance = nil
            self.direction = nil
            self.horizontalAngle = nil
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
                self.arSession.pause()
                self.peerWorldTransform = nil
                self.note = "カメラが許可されていないため、方向補助なしで続行します"
            } else {
                self.note = "セッションを再起動しています…（\(error.localizedDescription)）"
            }
            // セッションを作り直して復帰を試みる
            // （startNISession が測距の再開まで進むことがあるため、状態は先に戻しておく）
            if self.isPeerConnected { self.status = .connecting }
            self.startNISession()
        }
    }
}

/// 相手プレイヤーの Apple Watch と測距するセッション用の最小 delegate。
/// 距離を使うのは Watch 側だけなので、この端末では復帰処理だけを行う。
private final class WatchPeerSessionDelegate: NSObject, NISessionDelegate {
    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration {
            session.run(config)
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        if reason == .timeout, let config = session.configuration {
            session.run(config)
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
    @Published private(set) var horizontalAngle: Float?
    @Published private(set) var note: String?
    @Published private(set) var directionHint: String?
    @Published private(set) var peerWorldTransform: simd_float4x4?

    var onGameMessage: ((GameMessage) -> Void)?
    var onConnected: ((_ isLeader: Bool) -> Void)?

    var isDeviceSupported: Bool { false }

    func start() {}
    func stop() {}
    @discardableResult func send(_ message: GameMessage) -> Bool { false }
    func refreshConnectionAfterForeground() {}
    func relayGameStateToWatch(phase: String, role: String?, deadline: Date?, outcome: String?) {}
}

#endif
