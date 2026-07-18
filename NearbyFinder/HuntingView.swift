//
//  HuntingView.swift
//  NearbyFinder
//

import SwiftUI
import simd

/// 「探す」アプリの Precision Finding 風の探索画面。
/// 黒背景 + 大きな矢印で誘導し、1m を切ると緑にフェードして接近モードになる。
struct HuntingView: View {
    @ObservedObject var game: GameManager
    @State private var showAR = false

    private static let nearRange: Float = 1.0

    private var distance: Float? { game.nearby.distance }
    private var direction: simd_float3? { game.nearby.direction }
    private var isNear: Bool { (distance ?? .infinity) < Self.nearRange }

    /// 矢印の回転角（ラジアン、正 = 右）。U1 世代（iPhone 11〜13）は 3D の direction から、
    /// iPhone 14 以降は camera assistance の horizontalAngle から得る。
    /// direction はカメラ座標系（+x 右 / -z 前方）なので atan2 で方位角に変換する
    private var arrowAngle: Double? {
        if let direction { return Double(atan2(direction.x, -direction.z)) }
        if let angle = game.nearby.horizontalAngle { return Double(angle) }
        return nil
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            if showAR {
                ARTreasureView(arSession: game.nearby.arSession, peerTransform: game.nearby.peerWorldTransform)
                    .ignoresSafeArea()
                arHUD
            } else {
                normalContent
            }
            #else
            normalContent
            #endif
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: distance)
    }

    private var normalContent: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                Spacer()
                centerContent
                Spacer()
                footer
            }
            .padding(24)
        }
    }

    #if os(iOS)
    /// AR モード中のオーバーレイ（距離チップ・ガイド・閉じるボタン）
    private var arHUD: some View {
        VStack(spacing: 12) {
            HStack {
                if let text = distanceText {
                    Text("あと \(text)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                Button {
                    showAR = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            if game.nearby.peerWorldTransform == nil {
                Text("iPhone をゆっくり動かして宝の位置を特定中…")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            Spacer()
        }
        .padding()
    }
    #endif

    // MARK: - 各パーツ

    private var header: some View {
        VStack(spacing: 4) {
            Text(game.mode == .chase ? "逃走者を追え！" : "宝を探せ！")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = game.remainingSeconds(now: context.date)
                VStack(spacing: 2) {
                    Text("残り \(GameManager.timeString(remaining))")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(remaining <= 30 ? Color.red : Color.white)
                    Text("経過 \(game.elapsedText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if let note = game.nearby.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if isNear {
            VStack(spacing: 20) {
                PulseRings()
                    .frame(width: 140, height: 140)
                Text("もうすぐ！")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(game.mode == .chase
                     ? "あと少し！1m 以内まで追い詰めて確保！"
                     : "見つけたら宝の iPhone の画面の\nスライダーを右へスライドして発見確定！")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else if let arrowAngle {
            Image(systemName: "arrow.up")
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.radians(arrowAngle))
                .animation(.easeInOut(duration: 0.2), value: arrowAngle)
        } else if distance != nil {
            VStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.7))
                Text(game.nearby.directionHint ?? "iPhone を前にかざして、ゆっくり\n左右に動かすと矢印が出るよ")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else {
            VStack(spacing: 20) {
                PulseRings()
                    .frame(width: 140, height: 140)
                Text("信号をさがしています…\n歩き回ってみよう")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("あと")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Text(distanceText ?? "—")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(distanceText == nil ? .white.opacity(0.3) : .white)
            }
            Spacer()
            #if os(iOS)
            Button {
                showAR = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arkit")
                        .font(.title)
                    Text("ARで見る")
                        .font(.caption2)
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
            #endif
        }
    }

    // MARK: - 計算

    private var distanceText: String? {
        guard let distance else { return nil }
        if distance < 1 { return "\(Int((distance * 100).rounded())) cm" }
        return String(format: "%.1f m", distance)
    }

    /// 黒 → 1.5m を切ったあたりから緑へフェード
    private var background: Color {
        guard let distance, distance < 1.5 else { return .black }
        let t = 1 - Double((min(max(distance, 0.35), 1.5) - 0.35) / 1.15)   // 0 = 遠い, 1 = 近い
        return Color(hue: 0.36, saturation: 0.85, brightness: 0.5 * t)
    }

}

/// 外へ広がる波紋アニメーション。
struct PulseRings: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(.white.opacity(0.6), lineWidth: 2)
                    .scaleEffect(animate ? 2.4 : 0.6)
                    .opacity(animate ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.8)
                        .repeatForever(autoreverses: false)
                        .delay(Double(index) * 0.6),
                        value: animate
                    )
            }
            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
        }
        .onAppear { animate = true }
    }
}
