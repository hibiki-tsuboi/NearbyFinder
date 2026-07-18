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

    private static let nearRange: Float = 1.0

    private var distance: Float? { game.nearby.distance }
    private var direction: simd_float3? { game.nearby.direction }
    private var isNear: Bool { (distance ?? .infinity) < Self.nearRange }

    var body: some View {
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
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: distance)
    }

    // MARK: - 各パーツ

    private var header: some View {
        VStack(spacing: 4) {
            Text("宝を探せ！")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(game.elapsedText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
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
                Text("見つけたら宝の iPhone の画面を\n長押し → スライドで発見確定！")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else if let direction {
            Image(systemName: "arrow.up")
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.radians(azimuth(of: direction)))
                .animation(.easeInOut(duration: 0.2), value: azimuth(of: direction))
        } else if distance != nil {
            VStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.7))
                Text("iPhone をゆっくり左右に動かして\n方向をさがそう")
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

    /// カメラ座標系（+x 右 / -z 前方）の方向ベクトルを画面上の回転角に変換する
    private func azimuth(of direction: simd_float3) -> Double {
        Double(atan2(direction.x, -direction.z))
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
