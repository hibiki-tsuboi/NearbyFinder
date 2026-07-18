//
//  ContentView.swift
//  NearbyFinder
//

import SwiftUI

struct ContentView: View {
    @StateObject private var game = GameManager()

    var body: some View {
        Group {
            switch game.phase {
            case .lobby:
                LobbyView(game: game)
            case .hiding:
                HidingView(game: game)
            case .hunting:
                if game.role == .hunter {
                    HuntingView(game: game)
                } else {
                    TreasureWaitView(game: game)
                }
            case .finished:
                ResultView(game: game)
            }
        }
        .animation(.default, value: game.phase)
        .onAppear {
            game.start()
            #if os(iOS)
            // 隠した端末が画面ロックすると測距が止まるため、自動ロックを無効にする
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
    }
}

// MARK: - ロビー（役割選択）

struct LobbyView: View {
    @ObservedObject var game: GameManager

    private var isReady: Bool { game.nearby.status == .ranging }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("NearbyFinder")
                .font(.largeTitle.bold())
            Text("iPhone かくれんぼ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            statusRow
                .padding(.top, 8)
            Spacer()
            roleButtons
            if !isReady {
                Text("もう1台の iPhone でもアプリを開くと役割を選べます")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let note = game.nearby.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
                .frame(height: 24)
        }
        .padding()
    }

    @ViewBuilder
    private var statusRow: some View {
        switch game.nearby.status {
        case .unsupported:
            Label("この端末は Nearby Interaction (UWB) に対応していません", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .denied:
            Label("Nearby Interaction の使用が許可されていません", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                Text("近くの相手を探しています…")
            }
            .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                Text("\(game.nearby.peerName ?? "相手")と接続中…")
            }
            .foregroundStyle(.secondary)
        case .ranging:
            Label("\(game.nearby.peerName ?? "相手")と接続済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var roleButtons: some View {
        VStack(spacing: 12) {
            Button {
                game.selectRole(.treasure)
            } label: {
                roleLabel(icon: "shippingbox.fill", title: "宝になる", subtitle: "この iPhone を隠す")
            }
            .buttonStyle(.borderedProminent)
            Button {
                game.selectRole(.hunter)
            } label: {
                roleLabel(icon: "figure.walk.motion", title: "ハンターになる", subtitle: "この iPhone で宝を探す")
            }
            .buttonStyle(.bordered)
        }
        .disabled(!isReady)
        .padding(.horizontal)
    }

    private func roleLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 隠す猶予時間

struct HidingView: View {
    @ObservedObject var game: GameManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(game.role == .treasure ? "iPhone を隠そう！" : "相手が iPhone を隠しています")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("\(game.hideSecondsRemaining)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
            if game.role == .treasure {
                Text("画面は点けたまま、伏せて置くのがおすすめ。\n時間切れかスタートで探索開始！")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    game.startHuntEarly()
                } label: {
                    Text("隠し終わった！探索スタート")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            } else {
                Text("目を閉じて待とう…\nカウントが 0 になったら探索開始！")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .animation(.default, value: game.hideSecondsRemaining)
    }
}

// MARK: - 宝側の待機画面（探索中）

struct TreasureWaitView: View {
    @ObservedObject var game: GameManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                PulseRings()
                    .frame(width: 160, height: 160)
                Text("ハンターが探しています…")
                    .font(.title3)
                    .foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("残り \(GameManager.timeString(game.remainingSeconds(now: context.date))) 逃げ切ろう！")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text("見つかるまでこのままにしてね")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                HoldAndSlideButton(
                    title: "みつけた！",
                    hint: "この iPhone を見つけたハンターが長押し → 右へスライド"
                ) {
                    game.confirmFound()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

/// 長押しでロック解除してから右端までスライドで確定する誤操作防止ボタン。
/// 隠し場所で布や体が画面に触れても、この2段階の操作は偶然には成立しない。
struct HoldAndSlideButton: View {
    let title: String
    let hint: String
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isArmed = false

    private let thumbSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let maxOffset = geo.size.width - thumbSize - 8
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(isArmed ? 0.3 : 0.15))
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(offset > 10 ? 0.2 : 0.8))
                        .frame(maxWidth: .infinity)
                    Circle()
                        .fill(.white)
                        .overlay {
                            Image(systemName: "chevron.right.2")
                                .font(.title3.bold())
                                .foregroundStyle(.black)
                        }
                        .frame(width: thumbSize, height: thumbSize)
                        .scaleEffect(isArmed ? 1.1 : 1.0)
                        .offset(x: 4 + offset)
                        .gesture(confirmGesture(maxOffset: maxOffset))
                }
            }
            .frame(height: 64)
            .sensoryFeedback(.impact, trigger: isArmed) { _, newValue in newValue }
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private func confirmGesture(maxOffset: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture())
            .onChanged { value in
                switch value {
                case .first(true):
                    withAnimation(.easeOut(duration: 0.15)) { isArmed = true }
                case .second(true, let drag):
                    offset = min(max(0, drag?.translation.width ?? 0), maxOffset)
                default:
                    break
                }
            }
            .onEnded { _ in
                let confirmed = offset >= maxOffset * 0.9
                withAnimation(.spring(duration: 0.3)) {
                    offset = 0
                    isArmed = false
                }
                if confirmed { action() }
            }
    }
}

// MARK: - 決着（発見 or 時間切れ）

struct ResultView: View {
    @ObservedObject var game: GameManager

    private var hunterWon: Bool { game.outcome == .hunterWon }

    private var backgroundColor: Color {
        hunterWon ? Color(hue: 0.36, saturation: 0.75, brightness: 0.6)
                  : Color(hue: 0.72, saturation: 0.55, brightness: 0.55)
    }

    private var emoji: String {
        switch (game.outcome, game.role) {
        case (.hunterWon?, _): "🎉"
        case (.treasureWon?, .treasure?): "🏆"
        default: "⏰"
        }
    }

    private var title: String {
        switch (game.outcome, game.role) {
        case (.hunterWon?, .hunter?): "発見！"
        case (.hunterWon?, _): "見つかった！"
        case (.treasureWon?, .treasure?): "逃げ切った！"
        default: "時間切れ…"
        }
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Text(emoji)
                    .font(.system(size: 90))
                Text(title)
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                if hunterWon {
                    Text("タイム: \(game.elapsedText)")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                    if game.isNewBest {
                        Text("🏅 ベスト更新！")
                            .font(.headline)
                            .foregroundStyle(.yellow)
                    } else if let best = game.bestTimeText {
                        Text("ベスト: \(best)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Text("ハンター \(game.stats.hunterWins) 勝 ・ 宝 \(game.stats.treasureWins) 勝")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
                Spacer()
                Button {
                    game.playAgain()
                } label: {
                    Text("もう一度遊ぶ")
                        .font(.headline)
                        .foregroundStyle(backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }
}

#Preview {
    ContentView()
}
