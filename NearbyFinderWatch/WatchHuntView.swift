//
//  WatchHuntView.swift
//  NearbyFinderWatch
//

import SwiftUI
import WatchKit

/// 宝の iPhone までの距離を表示し、近づくほど速い手首ハプティクスを鳴らす。
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

    @ViewBuilder
    private var content: some View {
        switch ranger.state {
        case .unsupported:
            Text("この Apple Watch は UWB に対応していません\n（Series 6 以降 / Ultra が必要）")
                .font(.footnote)
                .multilineTextAlignment(.center)
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
        case .ranging:
            if let distance = ranger.distance {
                VStack(spacing: 4) {
                    Text(distanceText(distance))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("宝までの距離")
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

    private func distanceText(_ distance: Float) -> String {
        distance < 1 ? "\(Int((distance * 100).rounded()))cm" : String(format: "%.1fm", distance)
    }

    /// 近いほど緑に光る（iPhone の探索画面と同じ表現）
    private var background: Color {
        guard let distance = ranger.distance, distance < 1.5 else { return .black }
        let t = 1 - Double((min(max(distance, 0.35), 1.5) - 0.35) / 1.15)
        return Color(hue: 0.36, saturation: 0.85, brightness: 0.5 * t)
    }

    /// 距離に応じて間隔が変わる手首ハプティクス
    private func hapticLoop() async {
        while !Task.isCancelled {
            guard ranger.state == .ranging, let distance = ranger.distance else {
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
