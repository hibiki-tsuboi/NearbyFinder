//
//  WatchHuntView.swift
//  NearbyFinderWatch
//

import SwiftUI
import WatchKit

/// ゲームの進行に合わせて表示を切り替え、探索中は宝までの距離＋手首ハプティクスで誘導する。
/// iPhone から状態が届いていないとき（gamePhase == nil）は距離をそのまま表示する。
struct WatchHuntView: View {
    @StateObject private var ranger = WatchRanger()

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            content
                .padding()
        }
        .onAppear { ranger.start() }
        .task { await hapticLoop() }
    }

    /// 探索中（またはゲーム状態未受信）だけ距離を見せる
    private var shouldShowDistance: Bool {
        ranger.gamePhase == nil || ranger.gamePhase == "hunting"
    }

    @ViewBuilder
    private var content: some View {
        if ranger.state == .unsupported {
            Text("この Apple Watch は UWB に対応していません\n（Series 6 以降 / Ultra が必要）")
                .font(.footnote)
                .multilineTextAlignment(.center)
        } else if ranger.gamePhase == "finished" {
            resultContent
        } else if ranger.gamePhase == "hiding" {
            VStack(spacing: 8) {
                Text("🤫")
                    .font(.system(size: 40))
                Text(ranger.gameRole == "treasure" ? "iPhone を隠そう！" : "相手が隠しています…\n目を閉じて待とう")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        } else if ranger.gamePhase == "lobby" {
            VStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title2)
                Text("iPhone で役割を選ぶと\nゲームが始まるよ")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        } else {
            rangingContent
        }
    }

    @ViewBuilder
    private var rangingContent: some View {
        switch ranger.state {
        case .waitingForPhone:
            VStack(spacing: 8) {
                ProgressView()
                Text("iPhone のアプリと接続中…")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        case .waitingForPeer:
            VStack(spacing: 8) {
                ProgressView()
                Text("相手の iPhone を待っています…\n両方の iPhone でアプリを開いてね")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        default:
            if let distance = ranger.distance {
                VStack(spacing: 4) {
                    if let deadline = ranger.deadline {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("残り \(remainingText(deadline: deadline, now: context.date))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(distanceText(distance))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(ranger.gameRole == "treasure" ? "ハンターまでの距離" : "宝までの距離")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("信号をさがしています…\n歩き回ってみよう")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        let hunterWon = ranger.outcome == "hunterWon"
        let isTreasure = ranger.gameRole == "treasure"
        VStack(spacing: 8) {
            Text(hunterWon ? "🎉" : (isTreasure ? "🏆" : "⏰"))
                .font(.system(size: 40))
            Text(hunterWon ? (isTreasure ? "見つかった！" : "発見！")
                           : (isTreasure ? "逃げ切った！" : "時間切れ…"))
                .font(.headline)
            Text("次のゲームは iPhone から")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func distanceText(_ distance: Float) -> String {
        distance < 1 ? "\(Int((distance * 100).rounded()))cm" : String(format: "%.1fm", distance)
    }

    private func remainingText(deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 近いほど緑に光る（iPhone の探索画面と同じ表現）
    private var background: Color {
        guard shouldShowDistance, let distance = ranger.distance, distance < 1.5 else { return .black }
        let t = 1 - Double((min(max(distance, 0.35), 1.5) - 0.35) / 1.15)
        return Color(hue: 0.36, saturation: 0.85, brightness: 0.5 * t)
    }

    /// 距離に応じて間隔が変わる手首ハプティクス（探索中のみ）
    private func hapticLoop() async {
        while !Task.isCancelled {
            guard shouldShowDistance, ranger.state == .ranging, let distance = ranger.distance else {
                try? await Task.sleep(for: .seconds(0.5))
                continue
            }
            let clamped = min(max(distance, 0.35), 8.0)
            let t = Double((clamped - 0.35) / (8.0 - 0.35))   // 0 = 近い, 1 = 遠い
            WKInterfaceDevice.current().play(t < 0.1 ? .notification : .click)
            try? await Task.sleep(for: .seconds(0.15 + 1.2 * t))
        }
    }
}

#Preview {
    WatchHuntView()
}
