//
//  MultipeerSession.swift
//  NearbyFinder
//

import Foundation
import os
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif

/// MultipeerConnectivity で近くのピアを自動発見・自動接続し、
/// discovery token などの小さなデータを交換するための薄いラッパー。
///
/// 接続戦略:
/// - 通常は displayName の大きい側だけが招待し、同時招待によるハンドシェイク衝突を避ける
/// - 発見から猶予時間を過ぎても未接続なら反対側からも招待する（探索が片方向しか
///   成功しないケースへの保険。片側固定だけだとデッドロックする）
/// - 未接続の間は短い周期で再招待し、失敗が続いたらトランスポート一式を作り直す
///   （MC は接続失敗後に内部状態が壊れたままになることがある）
final class MultipeerSession: NSObject {
    static let serviceType = "nearbyfinder"

    var onPeerConnecting: ((MCPeerID) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?
    var onPeerDisconnected: ((MCPeerID) -> Void)?
    var onDataReceived: ((Data, MCPeerID) -> Void)?
    var onServiceError: ((String) -> Void)?

    private var myPeerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser

    /// 発見済みピアと最初に発見した時刻
    private var discovered: [MCPeerID: Date] = [:]
    /// 招待送信中のピアと送信時刻。タイムアウト前に同じ相手へ招待を重ねると
    /// MC のハンドシェイクが壊れることがあるため、返答があるまで再招待しない
    private var pendingInvites: [MCPeerID: Date] = [:]
    /// MCSession が .connecting に入った時刻。iOS 26 では connected / notConnected の
    /// どちらにも進まないことがあるため、watchdog で回収する
    private var connectingStartedAt: [MCPeerID: Date] = [:]
    /// 上位層へ接続済みとして通知したピア。古い callback で現在の接続を落とさないために保持する
    private var connectedPeer: MCPeerID?
    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var consecutiveSendFailures = 0
    private var lastDiscoveryRefresh = Date()

    /// 生存確認の ping（1 バイト。JSON の GameMessage と衝突しない値）
    private static let pingData = Data([0x00])
    /// 相手から最後に何か受信した時刻。keepalive の死活判定に使う
    private var lastReceiveAt = Date()
    private var keepaliveTask: Task<Void, Never>?

    private let log = Logger(subsystem: "jp.hibiki.NearbyFinder", category: "mc")

    /// 非招待側が招待を始めるまでの猶予
    private static let inviteGracePeriod: TimeInterval = 6
    /// 招待の返答待ちタイムアウト
    private static let inviteTimeout: TimeInterval = 8
    /// 誰も見つからないまま探索を張り直すまでの時間
    private static let discoveryRefreshInterval: TimeInterval = 12
    /// MCSession が .connecting のまま遷移しない場合にトランスポートを作り直すまでの時間
    private static let connectingTimeout: TimeInterval = 15
    /// reliable send が連続失敗した場合に半開き接続と判断する回数
    private static let sendFailureLimit = 3

    override init() {
        let transport = Self.makeTransport()
        myPeerID = transport.peerID
        session = transport.session
        advertiser = transport.advertiser
        browser = transport.browser
        super.init()
        wireDelegates()
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        lastDiscoveryRefresh = Date()
        startRetryLoop()
    }

    /// 通信を止める。次の start() で再開できるよう、新しいトランスポートを組み直しておく
    /// （tearDown 済みの advertiser/browser は delegate が外れていて再利用できない）
    func stop() {
        retryTask?.cancel()
        keepaliveTask?.cancel()
        resetTransport()
    }

    /// MC は片側だけが切断済みの「半開き」状態に陥ることがある。こちらは接続済みの
    /// つもりで相手の招待を拒否し続け、相手は永遠に繋がれない（作り直し側の切断通知が
    /// 届き損ねたときに起きる）。接続中は互いに ping を送り合い、一定時間何も受信
    /// できなければ死んだ接続として自ら破棄し、通常の再接続サイクルに戻す。
    private func startKeepalive(with peer: MCPeerID) {
        keepaliveTask?.cancel()
        lastReceiveAt = Date()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let peers = self.session.connectedPeers
                if !peers.isEmpty {
                    do {
                        try self.session.send(Self.pingData, toPeers: peers, with: .reliable)
                        self.consecutiveSendFailures = 0
                    } catch {
                        if self.recordSendFailure(error, peers: peers) { return }
                    }
                }
                // connectedPeers が空でもループは抜けない: 通知なしで接続が消えた
                // 場合、上位層はまだ接続済みだと信じているので無受信判定で回収する
                let silence = Date().timeIntervalSince(self.lastReceiveAt)
                if silence > 15 {
                    self.log.warning("keepalive: \(Int(silence)) 秒無受信。半開き接続とみなしてトランスポートを作り直す")
                    self.recoverFromDeadConnection(peers.isEmpty ? [peer] : peers)
                    return
                }
            }
        }
    }

    /// 死んだと判定した接続の復帰処理。session.disconnect() だけだと自分側の
    /// delegate に .notConnected が届かないことがあり（半開きはそもそも通知の
    /// 取りこぼしで起きる現象）、その場合こちらだけ「接続済み」を信じ続ける
    /// ゾンビ状態になって相手は二度と繋がれない。delegate 通知には頼らず、
    /// トランスポートを作り直した上で上位層への切断通知も自前で行う。
    private func recoverFromDeadConnection(_ stalePeers: [MCPeerID]) {
        rebuildTransport()
        for peer in stalePeers {
            onPeerDisconnected?(peer)
        }
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            log.warning("send: connectedPeers が空のため送信できない")
            if let connectedPeer {
                recoverFromDeadConnection([connectedPeer])
            }
            return false
        }
        do {
            try session.send(data, toPeers: peers, with: .reliable)
            consecutiveSendFailures = 0
            return true
        } catch {
            recordSendFailure(error, peers: peers)
            return false
        }
    }

    /// reliable send の連続失敗を記録し、閾値を超えたら半開き接続として回収する。
    /// 戻り値はトランスポートを再構築したかどうか。
    @discardableResult
    private func recordSendFailure(_ error: Error, peers: [MCPeerID]) -> Bool {
        consecutiveSendFailures += 1
        log.error("send 失敗（\(self.consecutiveSendFailures)/\(Self.sendFailureLimit)）: \(error.localizedDescription)")
        guard consecutiveSendFailures >= Self.sendFailureLimit else { return false }
        recoverFromDeadConnection(peers)
        return true
    }

    /// フォアグラウンド復帰時に、表示上と MCSession の接続状態が一致しているか監査する。
    /// 一致していれば ping を即送信し、不一致なら再構築、未接続なら探索を張り直す。
    func refreshConnection() {
        let peers = session.connectedPeers
        if let connectedPeer, peers.isEmpty {
            log.warning("foreground: 上位層は接続済みだが connectedPeers が空。再構築する")
            recoverFromDeadConnection([connectedPeer])
            return
        }
        if connectedPeer == nil, !peers.isEmpty {
            log.warning("foreground: 未通知の接続が残っている。再構築する")
            recoverFromDeadConnection(peers)
            return
        }
        if !peers.isEmpty {
            _ = send(Self.pingData)
            return
        }
        if recoverFromConnectingTimeoutIfNeeded() { return }
        refreshDiscovery()
    }

    private func refreshDiscovery() {
        guard session.connectedPeers.isEmpty, connectingStartedAt.isEmpty else { return }
        browser.stopBrowsingForPeers()
        advertiser.stopAdvertisingPeer()
        discovered.removeAll()
        pendingInvites.removeAll()
        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        lastDiscoveryRefresh = Date()
    }

    // MARK: - トランスポート管理

    private static func makeTransport() -> (peerID: MCPeerID, session: MCSession, advertiser: MCNearbyServiceAdvertiser, browser: MCNearbyServiceBrowser) {
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = ProcessInfo.processInfo.hostName
        #endif
        // 同名デバイス（iOS 16+ は一律 "iPhone"）を区別できるようランダムな接尾辞を付ける
        let peerID = MCPeerID(displayName: "\(deviceName)#\(UInt16.random(in: 1000...9999))")
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        return (peerID, session, advertiser, browser)
    }

    private func wireDelegates() {
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    private func tearDownTransport() {
        session.delegate = nil
        advertiser.delegate = nil
        browser.delegate = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    /// 現在の接続を破棄し、新しい PeerID でトランスポート一式を作り直す（探索は始めない）
    private func resetTransport() {
        tearDownTransport()
        let transport = Self.makeTransport()
        myPeerID = transport.peerID
        session = transport.session
        advertiser = transport.advertiser
        browser = transport.browser
        wireDelegates()
        discovered.removeAll()
        pendingInvites.removeAll()
        connectingStartedAt.removeAll()
        connectedPeer = nil
        consecutiveFailures = 0
        consecutiveSendFailures = 0
        keepaliveTask?.cancel()
        log.info("トランスポートを作り直した（新 peerID: \(self.myPeerID.displayName)）")
    }

    /// 接続失敗が続いたときに、新しい PeerID でトランスポート一式を作り直す
    private func rebuildTransport() {
        resetTransport()
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        lastDiscoveryRefresh = Date()
    }

    // MARK: - 招待

    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 両端末の周期が同調して招待が衝突し続けないようランダムに揺らす
                try? await Task.sleep(for: .seconds(Double.random(in: 1.5...2.5)))
                guard let self, !Task.isCancelled else { return }
                self.retryTick()
            }
        }
    }

    private func retryTick() {
        if recoverFromConnectingTimeoutIfNeeded() { return }
        guard session.connectedPeers.isEmpty else { return }
        // .connecting 中は招待を重ねない。タイムアウトした場合は上の watchdog が回収する
        guard connectingStartedAt.isEmpty else { return }
        if discovered.isEmpty {
            // しばらく誰も見つからないときは Bonjour 探索を張り直す
            if Date().timeIntervalSince(lastDiscoveryRefresh) > Self.discoveryRefreshInterval {
                refreshDiscovery()
            }
            return
        }
        for (peer, firstSeen) in discovered {
            inviteIfResponsible(peer, firstSeen: firstSeen)
        }
    }

    /// 2 台のうちどちらか一方だけが代表して行う処理（招待、接続時の設定同期など）を
    /// 自分が担当するかどうか。displayName の比較なので両端末で必ず一方だけ true になる
    func isDesignatedLeader(vs peer: MCPeerID) -> Bool {
        myPeerID.displayName > peer.displayName
    }

    private func inviteIfResponsible(_ peer: MCPeerID, firstSeen: Date) {
        guard session.connectedPeers.isEmpty, connectingStartedAt.isEmpty else { return }
        // 前の招待が生きているうちは重ねない（失敗・切断・喪失の時点で解除される）
        if let invitedAt = pendingInvites[peer], Date().timeIntervalSince(invitedAt) < Self.inviteTimeout {
            return
        }
        if isDesignatedLeader(vs: peer) || Date().timeIntervalSince(firstSeen) > Self.inviteGracePeriod {
            pendingInvites[peer] = Date()
            browser.invitePeer(peer, to: session, withContext: nil, timeout: Self.inviteTimeout)
        }
    }

    /// .connecting のまま callback が止まった接続試行を検出して作り直す。
    @discardableResult
    private func recoverFromConnectingTimeoutIfNeeded() -> Bool {
        let now = Date()
        guard connectingStartedAt.contains(where: { now.timeIntervalSince($0.value) > Self.connectingTimeout }) else {
            return false
        }
        let stalePeers = Array(connectingStartedAt.keys)
        log.warning("connecting watchdog: \(Int(Self.connectingTimeout)) 秒遷移なし。トランスポートを作り直す")
        rebuildTransport()
        for peer in stalePeers {
            onPeerDisconnected?(peer)
        }
        return true
    }
}

extension MultipeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let callbackSessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard callbackSessionID == ObjectIdentifier(self.session) else {
                self.log.info("古い MCSession の state callback を無視: \(peerID.displayName)")
                return
            }
            switch state {
            case .connecting:
                self.log.info("state: connecting \(peerID.displayName)")
                if self.connectingStartedAt[peerID] == nil {
                    self.connectingStartedAt[peerID] = Date()
                }
                self.onPeerConnecting?(peerID)
            case .connected:
                self.log.info("state: connected \(peerID.displayName)")
                let isDuplicate = self.connectedPeer == peerID
                self.connectedPeer = peerID
                self.connectingStartedAt.removeValue(forKey: peerID)
                self.consecutiveFailures = 0
                self.consecutiveSendFailures = 0
                self.pendingInvites.removeValue(forKey: peerID)
                self.startKeepalive(with: peerID)
                if !isDuplicate {
                    self.onPeerConnected?(peerID)
                }
            case .notConnected:
                self.log.warning("state: notConnected \(peerID.displayName)")
                let wasConnecting = self.connectingStartedAt.removeValue(forKey: peerID) != nil
                let wasConnected = self.connectedPeer == peerID
                if wasConnected { self.connectedPeer = nil }
                // 失敗が確定したので、次のリトライで即座に再招待できるようにする
                self.pendingInvites.removeValue(forKey: peerID)
                if self.session.connectedPeers.isEmpty {
                    self.keepaliveTask?.cancel()
                }
                if wasConnecting || wasConnected {
                    self.onPeerDisconnected?(peerID)
                }
                // 接続の試行失敗が続くときは MC の内部状態が壊れている可能性があるため作り直す
                if self.session.connectedPeers.isEmpty {
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures >= 3 {
                        self.rebuildTransport()
                    }
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let callbackSessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard callbackSessionID == ObjectIdentifier(self.session) else {
                self.log.info("古い MCSession の data callback を無視: \(peerID.displayName)")
                return
            }
            self.lastReceiveAt = Date()
            // keepalive の ping は上位層へ渡さない
            guard data != Self.pingData else { return }
            self.onDataReceived?(data, peerID)
        }
    }

    // 今回は使わない delegate 要件
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let callbackAdvertiserID = ObjectIdentifier(advertiser)
        Task { @MainActor in
            guard callbackAdvertiserID == ObjectIdentifier(self.advertiser) else {
                self.log.info("古い advertiser の招待を拒否: \(peerID.displayName)")
                invitationHandler(false, nil)
                return
            }
            // 接続済みのときは受けない（二重セッション防止）。半開きで拒否し続ける
            // 状態は keepalive が接続を切って解消する
            let accept = self.session.connectedPeers.isEmpty
            self.log.info("招待受信: \(peerID.displayName) → \(accept ? "受諾" : "拒否（接続済みのため）")")
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let callbackAdvertiserID = ObjectIdentifier(advertiser)
        Task { @MainActor in
            guard callbackAdvertiserID == ObjectIdentifier(self.advertiser) else { return }
            self.onServiceError?("接続の待受を開始できません: \(error.localizedDescription)")
        }
    }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let callbackBrowserID = ObjectIdentifier(browser)
        Task { @MainActor in
            guard callbackBrowserID == ObjectIdentifier(self.browser) else {
                self.log.info("古い browser の foundPeer を無視: \(peerID.displayName)")
                return
            }
            if self.discovered[peerID] == nil {
                self.discovered[peerID] = Date()
            }
            self.inviteIfResponsible(peerID, firstSeen: self.discovered[peerID] ?? Date())
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let callbackBrowserID = ObjectIdentifier(browser)
        Task { @MainActor in
            guard callbackBrowserID == ObjectIdentifier(self.browser) else { return }
            self.discovered.removeValue(forKey: peerID)
            self.pendingInvites.removeValue(forKey: peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let callbackBrowserID = ObjectIdentifier(browser)
        Task { @MainActor in
            guard callbackBrowserID == ObjectIdentifier(self.browser) else { return }
            self.onServiceError?("相手の探索を開始できません: \(error.localizedDescription)")
        }
    }
}
