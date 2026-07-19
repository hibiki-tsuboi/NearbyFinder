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
/// - 発見した互換ピアはすべて記録し、接続試行は常に 1 台ずつ行う
/// - 通常は displayName の大きい側だけが招待し、同時招待によるハンドシェイク衝突を避ける
/// - 発見から猶予時間を過ぎても未接続なら反対側からも招待する（探索が片方向しか
///   成功しないケースへの保険。片側固定だけだとデッドロックする）
/// - 招待に応答しない相手（実機の Bonjour キャッシュに残った、終了済みアプリの
///   古い広告 = ゴースト）は一定時間候補から外して次の候補を試す。ゴーストに
///   固定されて生きている相手を拒否し続けないよう、停滞した試行は生きた相手
///   からの招待で置き換える
/// - 未接続の間は短い周期で再試行し、失敗が続いたらトランスポート一式を作り直す
///   （MC は接続失敗後に内部状態が壊れたままになることがある）
final class MultipeerSession: NSObject {
    static let serviceType = "nearbyfinder"

    /// GameMessage の互換性を保証できる接続プロトコル世代。
    /// discoveryInfo と招待 context の両方で一致を確認してから接続する。
    private static let protocolVersion = 3
    private static let protocolVersionKey = "pv"
    private static let instanceIDKey = "id"

    private struct DiscoveredPeer {
        let firstSeen: Date
        var lastSeen: Date
        let instanceID: UUID
    }

    private struct InvitationMetadata: Codable {
        let protocolVersion: Int
        let instanceID: UUID
    }

    var onPeerConnecting: ((MCPeerID) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?
    var onPeerDisconnected: ((MCPeerID) -> Void)?
    var onDataReceived: ((Data, MCPeerID) -> Void)?
    var onServiceError: ((String) -> Void)?

    /// アプリ起動ごとの論理端末 ID。トランスポート再構築では変えず、古い広告との
    /// 区別と同一端末の追跡に使う。
    private let localInstanceID: UUID
    private let myPeerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser

    /// 発見済みの互換ピア。応答しない古い広告が混ざっている前提で、招待時に選別する
    private var discovered: [MCPeerID: DiscoveredPeer] = [:]
    /// 進行中の接続試行の相手。試行は常に 1 台ずつ行い、同じ serviceType の
    /// 第三者や再構築前の古い広告へ並行接続しない。
    private var candidatePeer: MCPeerID?
    private var candidateInstanceID: UUID?
    /// 招待に応答しなかった端末（instanceID）と失敗時刻。実機では終了済みアプリの
    /// Bonjour 広告がしばらくキャッシュに残り、生きた相手より先に発見されることが
    /// ある。応答しない広告を一定時間候補から外し、全候補を順番に試せるようにする
    ///（最初に見つけた 1 台への固定だけだと、ゴースト相手に永遠に繋がらない）。
    private var recentInviteFailures: [UUID: Date] = [:]
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
    private var transportGeneration = 1
    private var connectionAttemptID: UUID?

    /// 生存確認の ping（1 バイト。JSON の GameMessage と衝突しない値）
    private static let pingData = Data([0x00])
    /// 相手から最後に何か受信した時刻。keepalive の死活判定に使う
    private var lastReceiveUptime = ProcessInfo.processInfo.systemUptime
    /// タスクの実行間隔が大きく空いた直後に、通信断と誤判定しないための猶予期限
    private var keepaliveGraceUntilUptime = ProcessInfo.processInfo.systemUptime
    private var lastKeepaliveTickUptime = ProcessInfo.processInfo.systemUptime
    private var isApplicationActive = true
    private var keepaliveTask: Task<Void, Never>?

    private let log = Logger(subsystem: "jp.hibiki.NearbyFinder", category: "mc")

    /// 非招待側が招待を始めるまでの猶予
    private static let inviteGracePeriod: TimeInterval = 6
    /// 招待の返答待ちタイムアウト
    private static let inviteTimeout: TimeInterval = 8
    /// MC が招待タイムアウト後の state callback を返すまでの追加猶予
    private static let invitationCallbackGrace: TimeInterval = 2
    /// 招待できる相手が誰もいないまま探索を張り直すまでの時間。実機の AWDL は
    /// 探索の張り直しが多すぎるとスロットリングされるため、頻度は控えめにする
    private static let discoveryRefreshInterval: TimeInterval = 20
    /// MCSession が .connecting のまま遷移しない場合にトランスポートを作り直すまでの時間
    private static let connectingTimeout: TimeInterval = 15
    /// これ以上応答を待った招待が失敗したら、相手を終了済みプロセスの古い広告
    ///（ゴースト）とみなす。即時の拒否（= 生きている）と区別するための下限
    private static let unansweredInviteThreshold: TimeInterval = 6
    /// ゴーストとみなした相手を候補から外しておく時間
    private static let inviteFailureCooldown: TimeInterval = 25
    /// 進行中の handshake を、生きた相手からの招待で置き換えるまでの保護時間。
    /// これより古い .connecting は停滞とみなし、招待の受諾を優先する
    private static let connectingTakeoverProtection: TimeInterval = 4
    private static let keepaliveInterval: TimeInterval = 5
    private static let keepaliveTimeout: TimeInterval = 20
    private static let foregroundGracePeriod: TimeInterval = 20
    private static let delayedTickThreshold: TimeInterval = 10
    /// reliable send が連続失敗した場合に半開き接続と判断する回数
    private static let sendFailureLimit = 3

    override init() {
        let instanceID = UUID()
        let peerID = Self.makePeerID(instanceID: instanceID)
        let transport = Self.makeTransport(peerID: peerID, instanceID: instanceID)
        localInstanceID = instanceID
        myPeerID = peerID
        session = transport.session
        advertiser = transport.advertiser
        browser = transport.browser
        super.init()
        wireDelegates()
    }

    func start() {
        isApplicationActive = true
        recentInviteFailures.removeAll()
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        lastDiscoveryRefresh = Date()
        startRetryLoop()
        log.info("start: transport=\(self.transportGeneration) local=\(self.shortLocalInstanceID, privacy: .public) peer=\(self.myPeerID.displayName, privacy: .public) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }

    /// 通信を止める。次の start() で再開できるよう、新しいトランスポートを組み直しておく
    /// （tearDown 済みの advertiser/browser は delegate が外れていて再利用できない）
    func stop() {
        retryTask?.cancel()
        keepaliveTask?.cancel()
        resetTransport(reason: "stop")
    }

    /// アプリが非アクティブな間は keepalive の無受信判定を止める。iOS がタスクを
    /// 長時間停止したことを通信断として扱わないため、inactive の時点で通知する。
    func applicationDidBecomeInactive() {
        guard isApplicationActive else { return }
        isApplicationActive = false
        log.info("lifecycle: inactive transport=\(self.transportGeneration)")
    }

    /// MC は片側だけが切断済みの「半開き」状態に陥ることがある。こちらは接続済みの
    /// つもりで相手の招待を拒否し続け、相手は永遠に繋がれない（作り直し側の切断通知が
    /// 届き損ねたときに起きる）。接続中は互いに ping を送り合い、一定時間何も受信
    /// できなければ死んだ接続として自ら破棄し、通常の再接続サイクルに戻す。
    private func startKeepalive(with peer: MCPeerID) {
        keepaliveTask?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        lastReceiveUptime = now
        lastKeepaliveTickUptime = now
        keepaliveGraceUntilUptime = now + Self.keepaliveTimeout
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.keepaliveInterval))
                guard let self, !Task.isCancelled else { return }

                let now = ProcessInfo.processInfo.systemUptime
                let tickGap = now - self.lastKeepaliveTickUptime
                self.lastKeepaliveTickUptime = now
                guard self.isApplicationActive else { continue }

                // バックグラウンドや低電力状態でタスク実行が遅延した場合、相手の応答を
                // 待たずに古い lastReceive を評価すると正常な接続を切ってしまう。
                if tickGap > Self.delayedTickThreshold {
                    self.keepaliveGraceUntilUptime = now + Self.foregroundGracePeriod
                    self.log.info("keepalive: scheduling gap=\(Int(tickGap))s、判定猶予を延長")
                }

                let peers = self.connectedTransportPeers
                if let peer = peers.first {
                    do {
                        try self.session.send(Self.pingData, toPeers: [peer], with: .reliable)
                        self.consecutiveSendFailures = 0
                    } catch {
                        if self.recordSendFailure(error, peers: peers) { return }
                    }
                }
                // connectedPeers が空でもループは抜けない: 通知なしで接続が消えた
                // 場合、上位層はまだ接続済みだと信じているので無受信判定で回収する
                let silence = now - self.lastReceiveUptime
                if now >= self.keepaliveGraceUntilUptime, silence > Self.keepaliveTimeout {
                    self.log.warning("keepalive: \(Int(silence)) 秒無受信 transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)。半開き接続として再構築")
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
        rebuildTransport(reason: "dead connection")
        for peer in stalePeers {
            onPeerDisconnected?(peer)
        }
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        let peers = connectedTransportPeers
        guard !peers.isEmpty else {
            log.warning("send: 対象 peer が connectedPeers にない transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
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
        log.error("send 失敗（\(self.consecutiveSendFailures)/\(Self.sendFailureLimit)）transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public): \(Self.errorDetails(error), privacy: .public)")
        guard consecutiveSendFailures >= Self.sendFailureLimit else { return false }
        recoverFromDeadConnection(peers)
        return true
    }

    /// フォアグラウンド復帰時に、表示上と MCSession の接続状態が一致しているか監査する。
    /// 一致していれば ping を即送信し、不一致なら再構築、未接続なら探索を張り直す。
    func refreshConnection() {
        let now = ProcessInfo.processInfo.systemUptime
        isApplicationActive = true
        lastReceiveUptime = now
        lastKeepaliveTickUptime = now
        keepaliveGraceUntilUptime = now + Self.foregroundGracePeriod
        log.info("lifecycle: active transport=\(self.transportGeneration) grace=\(Int(Self.foregroundGracePeriod))s lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")

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
        if let connectedPeer, peers.contains(where: { $0 != connectedPeer }) {
            log.warning("foreground: 想定外の複数 peer が接続中。1台固定のため再構築する")
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
        candidatePeer = nil
        candidateInstanceID = nil
        pendingInvites.removeAll()
        connectionAttemptID = nil
        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        lastDiscoveryRefresh = Date()
        log.info("discovery refresh: transport=\(self.transportGeneration)")
    }

    // MARK: - トランスポート管理

    private static func makePeerID(instanceID: UUID) -> MCPeerID {
        #if canImport(UIKit)
        let deviceName = UIDevice.current.model
        #else
        let deviceName = "Device"
        #endif
        // 同名端末でも必ず一方だけを代表側にできるよう、起動 ID 全体を付ける。
        return MCPeerID(displayName: "\(deviceName)#\(instanceID.uuidString)")
    }

    private static func makeTransport(peerID: MCPeerID, instanceID: UUID) -> (session: MCSession, advertiser: MCNearbyServiceAdvertiser, browser: MCNearbyServiceBrowser) {
        let session = makeSession(peerID: peerID)
        let discoveryInfo = [
            protocolVersionKey: String(protocolVersion),
            instanceIDKey: instanceID.uuidString
        ]
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        return (session, advertiser, browser)
    }

    private static func makeSession(peerID: MCPeerID) -> MCSession {
        MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
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

    /// 現在の接続を破棄し、同じ論理 PeerID でトランスポート一式を作り直す（探索は始めない）。
    /// PeerID を再構築ごとに変えると、直前の Bonjour 広告が別端末として残るため固定する。
    private func resetTransport(reason: String) {
        tearDownTransport()
        transportGeneration += 1
        let transport = Self.makeTransport(peerID: myPeerID, instanceID: localInstanceID)
        session = transport.session
        advertiser = transport.advertiser
        browser = transport.browser
        wireDelegates()
        discovered.removeAll()
        candidatePeer = nil
        candidateInstanceID = nil
        pendingInvites.removeAll()
        connectingStartedAt.removeAll()
        connectedPeer = nil
        connectionAttemptID = nil
        consecutiveFailures = 0
        consecutiveSendFailures = 0
        keepaliveTask?.cancel()
        log.info("transport rebuild: generation=\(self.transportGeneration) reason=\(reason, privacy: .public) local=\(self.shortLocalInstanceID, privacy: .public)")
    }

    /// 接続失敗が続いたときにトランスポート一式を作り直す
    private func rebuildTransport(reason: String) {
        resetTransport(reason: reason)
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        lastDiscoveryRefresh = Date()
    }

    private var connectedTransportPeers: [MCPeerID] {
        guard let connectedPeer, session.connectedPeers.contains(connectedPeer) else { return [] }
        return [connectedPeer]
    }

    private var shortLocalInstanceID: String {
        String(localInstanceID.uuidString.prefix(8))
    }

    private var shortAttemptID: String {
        connectionAttemptID.map { String($0.uuidString.prefix(8)) } ?? "none"
    }

    private static func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    private func invitationMetadataData() -> Data? {
        try? JSONEncoder().encode(InvitationMetadata(
            protocolVersion: Self.protocolVersion,
            instanceID: localInstanceID
        ))
    }

    /// 発見済みの中から次に招待する相手を 1 台選ぶ。応答しなかった広告は一定時間
    /// 除外し、より新しく見つかった（= いま生きている可能性が高い。キャッシュ由来の
    /// 古い広告は探索開始直後にまとめて届く）ものを優先する。
    private func pickInviteCandidate() -> (peer: MCPeerID, entry: DiscoveredPeer)? {
        let now = Date()
        let eligible = discovered.filter { _, entry in
            guard let failedAt = recentInviteFailures[entry.instanceID] else { return true }
            return now.timeIntervalSince(failedAt) > Self.inviteFailureCooldown
        }
        let best = eligible.max { a, b in
            if a.value.lastSeen != b.value.lastSeen { return a.value.lastSeen < b.value.lastSeen }
            return a.value.instanceID.uuidString < b.value.instanceID.uuidString
        }
        return best.map { ($0.key, $0.value) }
    }

    /// 招待に応答しなかった相手をしばらく候補から外す（ゴースト対策）
    private func markInviteFailure(_ peer: MCPeerID) {
        guard let instanceID = discovered[peer]?.instanceID
                ?? (candidatePeer == peer ? candidateInstanceID : nil)
        else { return }
        recentInviteFailures[instanceID] = Date()
        log.info("invite failure: 応答がないため \(Int(Self.inviteFailureCooldown)) 秒候補から除外 peer=\(peer.displayName, privacy: .public)")
    }

    /// 発見（または招待受信）した互換ピアを記録する
    private func recordDiscoveredPeer(_ peer: MCPeerID, instanceID: UUID, source: String) {
        let now = Date()
        if var entry = discovered[peer] {
            entry.lastSeen = now
            discovered[peer] = entry
        } else {
            discovered[peer] = DiscoveredPeer(firstSeen: now, lastSeen: now, instanceID: instanceID)
            log.info("peer record: source=\(source, privacy: .public) peer=\(peer.displayName, privacy: .public) id=\(String(instanceID.uuidString.prefix(8)), privacy: .public) transport=\(self.transportGeneration)")
        }
    }

    private func clearCandidateIfIdle(_ peer: MCPeerID) {
        guard candidatePeer == peer,
              connectedPeer == nil,
              connectingStartedAt[peer] == nil,
              pendingInvites[peer] == nil
        else { return }
        log.info("candidate unlock: peer=\(peer.displayName, privacy: .public)")
        candidatePeer = nil
        candidateInstanceID = nil
        connectionAttemptID = nil
    }

    /// 両端末が同時に招待したとき、送信中の接続を cancel した同じ MCSession で
    /// 相手の招待を受けると、connected の後に cancel 由来の notConnected が届き、
    /// 確立した接続まで落ちることがある。非代表側は受諾専用の新しい MCSession に
    /// 差し替え、旧セッションの遅延 callback を ObjectIdentifier の検査で捨てる。
    private func replaceSessionForIncomingInvitation(from peer: MCPeerID) {
        let oldSession = session
        oldSession.delegate = nil
        oldSession.cancelConnectPeer(peer)
        oldSession.disconnect()

        session = Self.makeSession(peerID: myPeerID)
        session.delegate = self
        transportGeneration += 1
        pendingInvites.removeAll()
        connectingStartedAt.removeAll()
        consecutiveFailures = 0
        consecutiveSendFailures = 0
        log.info("session replace: simultaneous invitation peer=\(peer.displayName, privacy: .public) generation=\(self.transportGeneration)")
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
        guard isApplicationActive else { return }
        if recoverFromConnectingTimeoutIfNeeded() { return }
        guard session.connectedPeers.isEmpty else { return }
        let now = Date()
        let unansweredInvites = pendingInvites.filter {
            connectingStartedAt[$0.key] == nil
                && now.timeIntervalSince($0.value) > Self.inviteTimeout + Self.invitationCallbackGrace
        }
        if !unansweredInvites.isEmpty {
            // 招待がタイムアウトしたのに state callback が一度も届かない。相手が
            // 終了済みの古い広告なら今後も応答は来ないので候補から外した上で、
            // MC の内部状態が壊れている可能性にも備えてトランスポートを作り直す
            for peer in unansweredInvites.keys {
                markInviteFailure(peer)
            }
            log.warning("invite watchdog: state callback が届かないため再構築 transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
            rebuildTransport(reason: "invitation callback timeout")
            return
        }
        // .connecting 中は招待を重ねない。タイムアウトした場合は上の watchdog が回収する
        guard connectingStartedAt.isEmpty else { return }
        if pendingInvites.isEmpty, pickInviteCandidate() == nil {
            // 招待できる相手が 1 台もいないときだけ Bonjour 探索を張り直す
            if now.timeIntervalSince(lastDiscoveryRefresh) > Self.discoveryRefreshInterval {
                refreshDiscovery()
            }
            return
        }
        tryInviteNextCandidateIfIdle()
    }

    /// 2 台のうちどちらか一方だけが代表して行う処理（招待、接続時の設定同期など）を
    /// 自分が担当するかどうか。displayName の比較なので両端末で必ず一方だけ true になる
    func isDesignatedLeader(vs peer: MCPeerID) -> Bool {
        myPeerID.displayName > peer.displayName
    }

    /// 接続試行が何も進行していなければ、候補を 1 台選んで招待する。候補のロックは
    /// 招待を送る（= 試行が始まる）時点で行い、試行の終了（notConnected・喪失・
    /// watchdog・受諾への切替）で解除される。
    private func tryInviteNextCandidateIfIdle() {
        if let candidatePeer, connectedPeer == nil, connectingStartedAt.isEmpty, pendingInvites.isEmpty {
            // 試行が終わったのに残った迷子のロックは、招待が止まり続ける前に解除する
            clearCandidateIfIdle(candidatePeer)
        }
        guard candidatePeer == nil,
              connectedPeer == nil,
              session.connectedPeers.isEmpty,
              connectingStartedAt.isEmpty,
              pendingInvites.isEmpty,
              let candidate = pickInviteCandidate()
        else { return }
        // 通常は代表側だけが招待する。非代表側は、探索が片方向しか成功していない
        // 場合の保険として、発見から猶予時間を過ぎたら招待する
        guard isDesignatedLeader(vs: candidate.peer)
                || Date().timeIntervalSince(candidate.entry.firstSeen) > Self.inviteGracePeriod
        else { return }
        guard let context = invitationMetadataData() else {
            log.error("invite: metadata encode 失敗")
            return
        }
        candidatePeer = candidate.peer
        candidateInstanceID = candidate.entry.instanceID
        connectionAttemptID = UUID()
        pendingInvites[candidate.peer] = Date()
        log.info("invite send: peer=\(candidate.peer.displayName, privacy: .public) transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public) leader=\(self.isDesignatedLeader(vs: candidate.peer))")
        browser.invitePeer(candidate.peer, to: session, withContext: context, timeout: Self.inviteTimeout)
    }

    /// .connecting のまま callback が止まった接続試行を検出して作り直す。
    @discardableResult
    private func recoverFromConnectingTimeoutIfNeeded() -> Bool {
        let now = Date()
        guard connectingStartedAt.contains(where: { now.timeIntervalSince($0.value) > Self.connectingTimeout }) else {
            return false
        }
        let stalePeers = Array(connectingStartedAt.keys)
        log.warning("connecting watchdog: \(Int(Self.connectingTimeout)) 秒遷移なし transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
        rebuildTransport(reason: "connecting timeout")
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
                self.log.info("stale state callback: peer=\(peerID.displayName, privacy: .public)")
                return
            }
            switch state {
            case .connecting:
                guard self.candidatePeer == peerID else {
                    self.log.warning("state: unexpected connecting peer=\(peerID.displayName, privacy: .public)、接続試行を中止")
                    self.session.cancelConnectPeer(peerID)
                    return
                }
                self.log.info("state: connecting peer=\(peerID.displayName, privacy: .public) transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
                if self.connectingStartedAt[peerID] == nil {
                    self.connectingStartedAt[peerID] = Date()
                }
                self.onPeerConnecting?(peerID)
            case .connected:
                let hasUnexpectedPeer = self.candidatePeer != peerID
                    || (self.connectedPeer != nil && self.connectedPeer != peerID)
                    || self.session.connectedPeers.contains(where: { $0 != peerID })
                guard !hasUnexpectedPeer else {
                    let stalePeers = self.session.connectedPeers
                    self.log.error("state: unexpected connected peer=\(peerID.displayName, privacy: .public)、1台固定のため再構築")
                    self.rebuildTransport(reason: "unexpected peer connected")
                    for stalePeer in stalePeers {
                        self.onPeerDisconnected?(stalePeer)
                    }
                    return
                }
                self.log.info("state: connected peer=\(peerID.displayName, privacy: .public) transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
                let isDuplicate = self.connectedPeer == peerID
                self.connectedPeer = peerID
                self.connectingStartedAt.removeAll()
                self.consecutiveFailures = 0
                self.consecutiveSendFailures = 0
                self.pendingInvites.removeAll()
                self.recentInviteFailures.removeAll()
                // 接続後の第三者招待や古い広告の取り込みを防ぎ、電波利用も減らす。
                self.browser.stopBrowsingForPeers()
                self.advertiser.stopAdvertisingPeer()
                self.startKeepalive(with: peerID)
                if !isDuplicate {
                    self.onPeerConnected?(peerID)
                }
            case .notConnected:
                self.log.warning("state: notConnected peer=\(peerID.displayName, privacy: .public) transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
                let wasConnecting = self.connectingStartedAt.removeValue(forKey: peerID) != nil
                let wasConnected = self.connectedPeer == peerID
                if wasConnected { self.connectedPeer = nil }
                // 失敗が確定したので、次のリトライで即座に再招待できるようにする
                let invitedAt = self.pendingInvites.removeValue(forKey: peerID)
                // handshake に一度も入らないまま招待がタイムアウトした相手は、終了済み
                // アプリの古い広告の可能性が高い。しばらく候補から外して次の候補を試す
                //（即時の拒否は相手が生きている証拠なので除外しない）
                if !wasConnecting, !wasConnected,
                   let invitedAt,
                   Date().timeIntervalSince(invitedAt) >= Self.unansweredInviteThreshold {
                    self.markInviteFailure(peerID)
                }
                if self.session.connectedPeers.isEmpty {
                    self.keepaliveTask?.cancel()
                }
                self.clearCandidateIfIdle(peerID)
                if wasConnecting || wasConnected {
                    self.onPeerDisconnected?(peerID)
                }
                // handshake まで進んだ接続の失敗が続くときは MC の内部状態が壊れている
                // 可能性があるため作り直す。招待の再試行と候補の切替は retry loop が行う
                if self.session.connectedPeers.isEmpty, wasConnecting || wasConnected {
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures >= 3 {
                        self.rebuildTransport(reason: "three connection failures")
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
                self.log.info("stale data callback: peer=\(peerID.displayName, privacy: .public)")
                return
            }
            guard self.connectedPeer == peerID else {
                self.log.warning("data ignore: 接続候補以外 peer=\(peerID.displayName, privacy: .public)")
                return
            }
            self.lastReceiveUptime = ProcessInfo.processInfo.systemUptime
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
                self.log.info("stale invitation reject: peer=\(peerID.displayName, privacy: .public)")
                invitationHandler(false, nil)
                return
            }

            guard let context,
                  let metadata = try? JSONDecoder().decode(InvitationMetadata.self, from: context),
                  metadata.protocolVersion == Self.protocolVersion,
                  metadata.instanceID != self.localInstanceID
            else {
                self.log.warning("invite reject: incompatible metadata peer=\(peerID.displayName, privacy: .public)")
                self.onServiceError?("相手とアプリの接続プロトコルが異なります。両方を同じバージョンに更新してください")
                invitationHandler(false, nil)
                return
            }
            // 招待はいま生きているプロセスからしか届かない。発見情報として記録し、
            // ゴーストと誤判定していた場合は失敗記録を取り消す
            self.recentInviteFailures.removeValue(forKey: metadata.instanceID)
            self.recordDiscoveredPeer(peerID, instanceID: metadata.instanceID, source: "invitation")

            guard self.connectedPeer == nil, self.session.connectedPeers.isEmpty else {
                self.log.info("invite reject: already connected peer=\(peerID.displayName, privacy: .public)")
                invitationHandler(false, nil)
                return
            }

            let isFresh: (Date?) -> Bool = { startedAt in
                guard let startedAt else { return false }
                return Date().timeIntervalSince(startedAt) < Self.connectingTakeoverProtection
            }
            if let candidatePeer = self.candidatePeer, candidatePeer != peerID {
                // 別候補への試行中。handshake が実際に進み始めた直後だけは守り、
                // 進んでいない（応答しない広告への招待を待っているだけ、または
                // .connecting のまま停滞している）試行は、いま招待してきた
                // 生きている相手を優先して乗り換える
                if isFresh(self.connectingStartedAt[candidatePeer]) {
                    self.log.info("invite reject: 別候補と handshake 進行中 peer=\(peerID.displayName, privacy: .public) candidate=\(candidatePeer.displayName, privacy: .public)")
                    invitationHandler(false, nil)
                    return
                }
                if self.candidateInstanceID != metadata.instanceID {
                    self.markInviteFailure(candidatePeer)
                }
                self.log.info("candidate switch: 停滞した試行を破棄して招待を受ける old=\(candidatePeer.displayName, privacy: .public) new=\(peerID.displayName, privacy: .public)")
            } else {
                // 同じ相手との同時招待は、displayName が大きい代表側の「生きている」
                // 送信を優先する。停滞した試行（応答のない招待・進まない .connecting）
                // は、相手が改めて招待してきた時点で相手側にはもう存在しないので、
                // 拒否し続けず受諾に切り替える
                let hasFreshOutgoingAttempt = isFresh(self.pendingInvites[peerID])
                    || isFresh(self.connectingStartedAt[peerID])
                if hasFreshOutgoingAttempt, self.isDesignatedLeader(vs: peerID) {
                    self.log.info("invite reject: simultaneous attempt、leader側の送信を優先 peer=\(peerID.displayName, privacy: .public)")
                    invitationHandler(false, nil)
                    return
                }
            }
            if !self.pendingInvites.isEmpty || !self.connectingStartedAt.isEmpty {
                // 送信側の試行が残った MCSession で受諾すると、遅延した cancel 由来の
                // callback で確立後の接続まで落ちることがあるため差し替える
                self.replaceSessionForIncomingInvitation(from: peerID)
                self.log.info("invite receive: 受諾専用 session へ切替 peer=\(peerID.displayName, privacy: .public)")
            }

            self.candidatePeer = peerID
            self.candidateInstanceID = metadata.instanceID
            self.connectionAttemptID = UUID()
            self.connectingStartedAt[peerID] = Date()
            self.log.info("invite accept: peer=\(peerID.displayName, privacy: .public) transport=\(self.transportGeneration) attempt=\(self.shortAttemptID, privacy: .public)")
            self.onPeerConnecting?(peerID)
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let callbackAdvertiserID = ObjectIdentifier(advertiser)
        Task { @MainActor in
            guard callbackAdvertiserID == ObjectIdentifier(self.advertiser) else { return }
            self.log.error("advertising start failure: transport=\(self.transportGeneration) \(Self.errorDetails(error), privacy: .public)")
            self.onServiceError?("接続の待受を開始できません: \(error.localizedDescription)")
        }
    }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let callbackBrowserID = ObjectIdentifier(browser)
        Task { @MainActor in
            guard callbackBrowserID == ObjectIdentifier(self.browser) else {
                self.log.info("stale foundPeer callback: peer=\(peerID.displayName, privacy: .public)")
                return
            }
            guard info?[Self.protocolVersionKey] == String(Self.protocolVersion) else {
                let remoteVersion = info?[Self.protocolVersionKey] ?? "missing"
                self.log.warning("foundPeer ignore: incompatible peer=\(peerID.displayName, privacy: .public) remoteVersion=\(remoteVersion, privacy: .public)")
                self.onServiceError?("相手とアプリの接続プロトコルが異なります。両方を同じバージョンに更新してください")
                return
            }
            guard let instanceIDText = info?[Self.instanceIDKey],
                  let instanceID = UUID(uuidString: instanceIDText)
            else {
                self.log.warning("foundPeer ignore: malformed instance ID peer=\(peerID.displayName, privacy: .public)")
                return
            }
            guard instanceID != self.localInstanceID else {
                self.log.info("foundPeer ignore: self advertisement")
                return
            }
            self.recordDiscoveredPeer(peerID, instanceID: instanceID, source: "discovery")
            self.tryInviteNextCandidateIfIdle()
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let callbackBrowserID = ObjectIdentifier(browser)
        Task { @MainActor in
            guard callbackBrowserID == ObjectIdentifier(self.browser) else { return }
            self.log.info("lostPeer: peer=\(peerID.displayName, privacy: .public) transport=\(self.transportGeneration)")
            self.discovered.removeValue(forKey: peerID)
            self.pendingInvites.removeValue(forKey: peerID)
            self.clearCandidateIfIdle(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let callbackBrowserID = ObjectIdentifier(browser)
        Task { @MainActor in
            guard callbackBrowserID == ObjectIdentifier(self.browser) else { return }
            self.log.error("browsing start failure: transport=\(self.transportGeneration) \(Self.errorDetails(error), privacy: .public)")
            self.onServiceError?("相手の探索を開始できません: \(error.localizedDescription)")
        }
    }
}
