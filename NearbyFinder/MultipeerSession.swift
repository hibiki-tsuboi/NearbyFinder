//
//  MultipeerSession.swift
//  NearbyFinder
//

import Foundation
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif

/// MultipeerConnectivity で近くのピアを自動発見・自動接続し、
/// discovery token などの小さなデータを交換するための薄いラッパー。
///
/// 探索は片方向しか成功しないことがあるため、発見したら無条件で招待し、
/// 未接続の間は定期的に再招待してデッドロックを防ぐ。
final class MultipeerSession: NSObject {
    static let serviceType = "nearbyfinder"

    var onPeerConnecting: ((MCPeerID) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?
    var onPeerDisconnected: ((MCPeerID) -> Void)?
    var onDataReceived: ((Data, MCPeerID) -> Void)?
    var onServiceError: ((String) -> Void)?

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var discoveredPeers: Set<MCPeerID> = []
    private var retryTask: Task<Void, Never>?

    override init() {
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = ProcessInfo.processInfo.hostName
        #endif
        // 同名デバイス（iOS 16+ は一律 "iPhone"）を区別できるようランダムな接尾辞を付ける
        myPeerID = MCPeerID(displayName: "\(deviceName)#\(UInt16.random(in: 1000...9999))")
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startRetryLoop()
    }

    func stop() {
        retryTask?.cancel()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func send(_ data: Data) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    // MARK: - 招待

    /// 未接続の間、発見済みピアへ定期的に再招待する。
    /// 招待の同時衝突や取りこぼしがあっても、次の周期で回復できる。
    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 両端末が同時に招待し合う衝突を避けるため周期をランダムに揺らす
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...4.0)))
                guard let self, !Task.isCancelled else { return }
                self.inviteDiscoveredPeersIfNeeded()
            }
        }
    }

    private func inviteDiscoveredPeersIfNeeded() {
        guard session.connectedPeers.isEmpty else { return }
        for peer in discoveredPeers {
            browser.invitePeer(peer, to: session, withContext: nil, timeout: 10)
        }
    }
}

extension MultipeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connecting: self.onPeerConnecting?(peerID)
            case .connected: self.onPeerConnected?(peerID)
            case .notConnected: self.onPeerDisconnected?(peerID)
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
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
        Task { @MainActor in
            // 接続済みのときは受けない（二重セッション防止）
            let accept = self.session.connectedPeers.isEmpty
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.onServiceError?("接続の待受を開始できません: \(error.localizedDescription)")
        }
    }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            self.discoveredPeers.insert(peerID)
            self.inviteDiscoveredPeersIfNeeded()
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredPeers.remove(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.onServiceError?("相手の探索を開始できません: \(error.localizedDescription)")
        }
    }
}
