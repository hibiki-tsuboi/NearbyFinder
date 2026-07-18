//
//  GameManager.swift
//  NearbyFinder
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// ゲーム全体の状態遷移（ロビー → 隠す → 探索 → 決着）を管理する。
final class GameManager: ObservableObject {
    /// 先にこのラウンド数を取ったほうがシリーズ優勝
    static let seriesTarget = 3

    @Published private(set) var phase: GamePhase = .lobby
    @Published private(set) var role: PlayerRole?
    @Published private(set) var outcome: GameOutcome?
    @Published private(set) var hideSecondsRemaining: Int
    /// 隠す猶予（秒）。ロビーで変更でき、相手と同期して UserDefaults に保存される
    @Published private(set) var hideDuration: Int
    /// 探索の制限時間（秒）。時間切れは宝役の勝ち
    @Published private(set) var huntDuration: Int
    /// このシリーズで自分／相手が取ったラウンド数（ロビーに戻るとリセット）
    @Published private(set) var myRoundWins = 0
    @Published private(set) var peerRoundWins = 0
    @Published private(set) var huntStartDate: Date?
    @Published private(set) var huntDeadline: Date?
    @Published private(set) var finishDate: Date?
    @Published private(set) var stats = GameStats.load()
    @Published private(set) var isNewBest = false
    /// 探索中の距離の推移（リザルトの接近グラフ用、1 秒 1 サンプル）
    @Published private(set) var distanceHistory: [DistanceSample] = []

    let nearby = NearbySessionManager()

    private let feedback = ProximityFeedback()
    private var countdownTask: Task<Void, Never>?
    private var huntTimerTask: Task<Void, Never>?
    private var myRolePriority: UInt32 = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let savedHide = UserDefaults.standard.integer(forKey: "hideDuration")
        let savedHunt = UserDefaults.standard.integer(forKey: "huntDuration")
        hideDuration = savedHide > 0 ? savedHide : 60
        huntDuration = savedHunt > 0 ? savedHunt : 300
        hideSecondsRemaining = savedHide > 0 ? savedHide : 60
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
        // 接続確立時、代表側（両端末で必ず一方だけ）が自分の設定を送って表示を揃える。
        // タイトル画面で各自が別々に設定したまま接続すると、誰かがピッカーを触るまで
        // 両端末のロビー表示が食い違ったままになるため
        nearby.onConnected = { [weak self] isLeader in
            guard let self, isLeader, self.phase == .lobby else { return }
            self.nearby.send(.settingsChanged(hideDuration: self.hideDuration, huntDuration: self.huntDuration))
        }
    }

    func start() {
        nearby.start()
    }

    /// タイトル画面へ戻るとき、ゲーム状態をリセットして通信を止める
    func stop() {
        resetToLobby()
        nearby.stop()
    }

    // MARK: - UI からの操作

    func selectRole(_ selected: PlayerRole) {
        guard phase == .lobby, role == nil, nearby.status == .ranging else { return }
        role = selected
        myRolePriority = UInt32.random(in: .min ... .max)
        nearby.send(.roleSelected(selected, priority: myRolePriority, hideDuration: hideDuration, huntDuration: huntDuration))
        startHiding()
    }

    /// ロビーでの設定変更。相手にも同期し、次回のために保存する
    func updateSettings(hideDuration: Int, huntDuration: Int, broadcast: Bool = true) {
        self.hideDuration = hideDuration
        self.huntDuration = huntDuration
        if phase == .lobby {
            hideSecondsRemaining = hideDuration
        }
        UserDefaults.standard.set(hideDuration, forKey: "hideDuration")
        UserDefaults.standard.set(huntDuration, forKey: "huntDuration")
        if broadcast {
            nearby.send(.settingsChanged(hideDuration: hideDuration, huntDuration: huntDuration))
        }
    }

    /// 役割を交代して次のラウンドを始める
    func rematch() {
        guard phase == .finished else { return }
        nearby.send(.rematch)
        startNextRound()
    }

    /// 宝役が隠し終えたとき、猶予時間を待たずに探索を開始する
    func startHuntEarly() {
        guard phase == .hiding, role == .treasure else { return }
        nearby.send(.gameStarted)
        beginHunt()
    }

    /// 宝の iPhone を物理的に見つけたハンターが、宝側の画面のスライドで発見を確定する
    func confirmFound() {
        guard phase == .hunting, role == .treasure else { return }
        nearby.send(.found)
        finish(with: .hunterWon)
    }

    func playAgain() {
        nearby.send(.playAgain)
        resetToLobby()
    }

    // MARK: - 状態遷移

    private func startHiding() {
        phase = .hiding
        hideSecondsRemaining = hideDuration
        syncWatch()
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
        huntDeadline = Date().addingTimeInterval(TimeInterval(huntDuration))
        distanceHistory = []
        syncWatch()
        if role == .hunter {
            feedback.startProximityLoop()
        }
        // 時間切れの判定は「みつけた！」ボタンを持つ宝側が代表して行い、結果を相手へ送る
        if role == .treasure {
            let duration = huntDuration
            huntTimerTask?.cancel()
            huntTimerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Double(duration)))
                guard let self, !Task.isCancelled, self.phase == .hunting else { return }
                self.nearby.send(.timeUp)
                self.finish(with: .treasureWon)
            }
        }
    }

    private func finish(with outcome: GameOutcome) {
        guard phase == .hunting else { return }
        phase = .finished
        self.outcome = outcome
        finishDate = Date()
        huntTimerTask?.cancel()
        feedback.stopProximityLoop()

        var updated = stats
        isNewBest = updated.record(outcome: outcome, clearSeconds: outcome == .hunterWon ? elapsedSeconds : nil)
        updated.save()
        stats = updated

        // シリーズのラウンド集計（自分の役割が勝ったかで判定するため両端末で一致する）
        if let role {
            let iWon = (outcome == .hunterWon && role == .hunter) || (outcome == .treasureWon && role == .treasure)
            if iWon { myRoundWins += 1 } else { peerRoundWins += 1 }
        }
        syncWatch()

        switch outcome {
        case .hunterWon: feedback.playVictory()
        case .treasureWon: feedback.playTimeUp()
        }
    }

    private func resetToLobby() {
        countdownTask?.cancel()
        huntTimerTask?.cancel()
        feedback.shutdown()
        phase = .lobby
        role = nil
        outcome = nil
        isNewBest = false
        hideSecondsRemaining = hideDuration
        huntStartDate = nil
        huntDeadline = nil
        finishDate = nil
        distanceHistory = []
        myRoundWins = 0
        peerRoundWins = 0
        syncWatch()
    }

    /// 役割を入れ替えて次のラウンドへ。シリーズ決着後なら勝敗カウントをリセットする
    private func startNextRound() {
        if myRoundWins >= Self.seriesTarget || peerRoundWins >= Self.seriesTarget {
            myRoundWins = 0
            peerRoundWins = 0
        }
        role = role?.opposite
        outcome = nil
        isNewBest = false
        huntStartDate = nil
        huntDeadline = nil
        finishDate = nil
        distanceHistory = []
        startHiding()
    }

    /// ペアの Apple Watch へゲーム状態を中継する（探索中以外は Watch 側が距離を隠す）
    private func syncWatch() {
        let phaseName = switch phase {
        case .lobby: "lobby"
        case .hiding: "hiding"
        case .hunting: "hunting"
        case .finished: "finished"
        }
        let outcomeName: String? = switch outcome {
        case .some(.hunterWon): "hunterWon"
        case .some(.treasureWon): "treasureWon"
        case nil: nil
        }
        nearby.relayGameStateToWatch(phase: phaseName, role: role?.rawValue, deadline: huntDeadline, outcome: outcomeName)
    }

    private func handle(_ message: GameMessage) {
        switch message {
        case .discoveryToken, .watchToken, .watchPeerToken:
            break   // NearbySessionManager が処理済み
        case .roleSelected(let peerRole, let peerPriority, let hide, let hunt):
            if role == nil {
                guard phase == .lobby else { break }
                // 役割を選んだ側の設定をそのラウンドの正とする
                updateSettings(hideDuration: hide, huntDuration: hunt, broadcast: false)
                role = peerRole.opposite
                startHiding()
            } else if peerRole == role, peerPriority > myRolePriority {
                // 両者が同時に同じ役を選んだ場合は優先度の高い側に譲る
                role = peerRole.opposite
            }
        case .settingsChanged(let hide, let hunt):
            updateSettings(hideDuration: hide, huntDuration: hunt, broadcast: false)
        case .gameStarted:
            beginHunt()
        case .found:
            finish(with: .hunterWon)
        case .timeUp:
            finish(with: .treasureWon)
        case .playAgain:
            resetToLobby()
        case .rematch:
            if phase == .finished {
                startNextRound()
            }
        }
    }

    private func distanceUpdated(_ distance: Float?) {
        feedback.distance = distance
        guard phase == .hunting, let distance, let start = huntStartDate else { return }
        // 接近グラフ用に 1 秒 1 サンプルで記録する（両端末とも自分の測定値を記録）
        let seconds = Int(Date().timeIntervalSince(start))
        if distanceHistory.last?.seconds != seconds {
            distanceHistory.append(DistanceSample(seconds: seconds, distance: distance))
        }
    }

    // MARK: - 表示用

    private var elapsedSeconds: Int {
        guard let start = huntStartDate else { return 0 }
        return max(0, Int((finishDate ?? Date()).timeIntervalSince(start)))
    }

    /// 探索開始からの経過時間（決着後は決着までのタイム）
    var elapsedText: String { Self.timeString(elapsedSeconds) }

    var bestTimeText: String? {
        stats.bestClearSeconds.map(Self.timeString)
    }

    func remainingSeconds(now: Date) -> Int {
        guard let deadline = huntDeadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSince(now).rounded()))
    }

    nonisolated static func timeString(_ seconds: Int) -> String {
        String(format: "%d分%02d秒", seconds / 60, seconds % 60)
    }
}

#if os(iOS)
/// 距離に応じて間隔と強さが変わる振動＋ソナー音のパルス（近いほど速く・強く・大きく）と、
/// 決着時の演出を出す。
final class ProximityFeedback {
    var distance: Float?

    private let audio = GameAudio()
    private var task: Task<Void, Never>?
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    func startProximityLoop() {
        stopProximityLoop()
        impact.prepare()
        audio.start()
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
                self.audio.playPing(volume: Float(1.0 - 0.65 * t))
                try? await Task.sleep(for: .seconds(0.08 + 1.1 * t))
            }
        }
    }

    func stopProximityLoop() {
        task?.cancel()
        task = nil
    }

    func playVictory() {
        notification.notificationOccurred(.success)
        audio.start()
        audio.playFanfare()
    }

    func playTimeUp() {
        notification.notificationOccurred(.warning)
        audio.start()
        audio.playTimeUp()
    }

    func shutdown() {
        stopProximityLoop()
        audio.stop()
    }
}
#else
final class ProximityFeedback {
    var distance: Float?
    func startProximityLoop() {}
    func stopProximityLoop() {}
    func playVictory() {}
    func playTimeUp() {}
    func shutdown() {}
}
#endif
