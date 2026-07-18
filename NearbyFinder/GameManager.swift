//
//  GameManager.swift
//  NearbyFinder
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// ゲーム全体の状態遷移（ロビー → 隠す → 探索 → 発見）を管理する。
final class GameManager: ObservableObject {
    static let hideDuration = 60

    @Published private(set) var phase: GamePhase = .lobby
    @Published private(set) var role: PlayerRole?
    @Published private(set) var hideSecondsRemaining = GameManager.hideDuration
    @Published private(set) var huntStartDate: Date?
    @Published private(set) var foundDate: Date?

    let nearby = NearbySessionManager()

    private let haptics = HapticPulser()
    private var countdownTask: Task<Void, Never>?
    private var myRolePriority: UInt32 = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // ネストした ObservableObject の変更をビューへ伝搬させる
        nearby.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        nearby.$distance
            .sink { [weak self] distance in self?.distanceUpdated(distance) }
            .store(in: &cancellables)
        nearby.$status
            .sink { [weak self] status in
                guard let self else { return }
                // 相手との接続が切れたらゲームを中断してロビーに戻す
                if status == .searching, self.phase != .lobby {
                    self.resetToLobby()
                }
            }
            .store(in: &cancellables)
        nearby.onGameMessage = { [weak self] message in self?.handle(message) }
    }

    func start() {
        nearby.start()
    }

    // MARK: - UI からの操作

    func selectRole(_ selected: PlayerRole) {
        guard phase == .lobby, role == nil, nearby.status == .ranging else { return }
        role = selected
        myRolePriority = UInt32.random(in: .min ... .max)
        nearby.send(.roleSelected(selected, priority: myRolePriority))
        startHiding()
    }

    /// 宝役が隠し終えたとき、猶予時間を待たずに探索を開始する
    func startHuntEarly() {
        guard phase == .hiding, role == .treasure else { return }
        nearby.send(.gameStarted)
        beginHunt()
    }

    /// 宝の iPhone を物理的に見つけたハンターが、宝側の画面の長押しボタンで発見を確定する
    func confirmFound() {
        guard phase == .hunting, role == .treasure else { return }
        finishGame(notifyPeer: true)
    }

    func playAgain() {
        nearby.send(.playAgain)
        resetToLobby()
    }

    // MARK: - 状態遷移

    private func startHiding() {
        phase = .hiding
        hideSecondsRemaining = Self.hideDuration
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.hideSecondsRemaining -= 1
                if self.hideSecondsRemaining <= 0 {
                    self.beginHunt()   // 時間切れで自動スタート（両端末がそれぞれ実行する）
                    return
                }
            }
        }
    }

    private func beginHunt() {
        guard phase == .hiding else { return }
        countdownTask?.cancel()
        phase = .hunting
        huntStartDate = Date()
        if role == .hunter { haptics.start() }
    }

    private func finishGame(notifyPeer: Bool) {
        guard phase == .hunting else { return }
        phase = .found
        foundDate = Date()
        haptics.stop()
        haptics.playSuccess()
        if notifyPeer { nearby.send(.found) }
    }

    private func resetToLobby() {
        countdownTask?.cancel()
        haptics.stop()
        phase = .lobby
        role = nil
        hideSecondsRemaining = Self.hideDuration
        huntStartDate = nil
        foundDate = nil
    }

    private func handle(_ message: GameMessage) {
        switch message {
        case .discoveryToken:
            break   // NearbySessionManager が処理済み
        case .roleSelected(let peerRole, let peerPriority):
            if role == nil {
                guard phase == .lobby else { break }
                role = peerRole.opposite
                startHiding()
            } else if peerRole == role, peerPriority > myRolePriority {
                // 両者が同時に同じ役を選んだ場合は優先度の高い側に譲る
                role = peerRole.opposite
            }
        case .gameStarted:
            beginHunt()
        case .found:
            finishGame(notifyPeer: false)
        case .playAgain:
            resetToLobby()
        }
    }

    private func distanceUpdated(_ distance: Float?) {
        haptics.distance = distance
    }

    /// 探索開始からの経過時間（発見後は発見までのタイム）
    var elapsedText: String {
        guard let start = huntStartDate else { return "" }
        let end = foundDate ?? Date()
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d分%02d秒", seconds / 60, seconds % 60)
    }
}

#if os(iOS)
/// 距離に応じて間隔と強さが変わる振動パルス（近いほど速く・強く）。
final class HapticPulser {
    var distance: Float?

    private var task: Task<Void, Never>?
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    func start() {
        stop()
        impact.prepare()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let distance = self.distance else {
                    // 信号なしの間はパルスを打たずに待つ
                    try? await Task.sleep(for: .seconds(0.5))
                    continue
                }
                let clamped = min(max(distance, 0.35), 8.0)
                let t = Double((clamped - 0.35) / (8.0 - 0.35))   // 0 = 近い, 1 = 遠い
                self.impact.impactOccurred(intensity: 1.0 - 0.6 * t)
                try? await Task.sleep(for: .seconds(0.08 + 1.1 * t))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func playSuccess() {
        notification.notificationOccurred(.success)
    }
}
#else
final class HapticPulser {
    var distance: Float?
    func start() {}
    func stop() {}
    func playSuccess() {}
}
#endif
