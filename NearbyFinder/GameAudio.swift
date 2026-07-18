//
//  GameAudio.swift
//  NearbyFinder
//

#if os(iOS)
import AVFoundation

/// AVAudioEngine で正弦波から合成したソナー音・決着音を再生する。音源ファイル不要。
final class GameAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var isRunning = false

    // (周波数 Hz, 開始秒, 長さ秒) を重ねて 1 つのバッファに合成する
    private lazy var pingBuffer = Self.makeBuffer(format: format, decay: 26, notes: [
        (1318.5, 0.00, 0.15),   // E6 の短いピン
    ])
    private lazy var fanfareBuffer = Self.makeBuffer(format: format, decay: 5, notes: [
        (523.25, 0.00, 0.20),   // C5
        (659.25, 0.15, 0.20),   // E5
        (783.99, 0.30, 0.20),   // G5
        (1046.50, 0.45, 0.60),  // C6
    ])
    private lazy var timeUpBuffer = Self.makeBuffer(format: format, decay: 4, notes: [
        (392.00, 0.00, 0.30),   // G4
        (329.63, 0.30, 0.30),   // E4
        (261.63, 0.60, 0.70),   // C4
    ])

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard !isRunning else { return }
        // マナーモードに従い、他アプリの音とミックスされる控えめなカテゴリを使う
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
    }

    func playPing(volume: Float) {
        play(pingBuffer, volume: volume)
    }

    func playFanfare() {
        play(fanfareBuffer, volume: 1.0)
    }

    func playTimeUp() {
        play(timeUpBuffer, volume: 1.0)
    }

    private func play(_ buffer: AVAudioPCMBuffer, volume: Float) {
        guard isRunning else { return }
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    private static func makeBuffer(format: AVAudioFormat, decay: Double, notes: [(freq: Double, start: Double, dur: Double)]) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let totalSeconds = notes.map { $0.start + $0.dur }.max() ?? 0.2
        let frameCount = AVAudioFrameCount(sampleRate * totalSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        guard let samples = buffer.floatChannelData?[0] else { return buffer }
        for note in notes {
            let startFrame = Int(note.start * sampleRate)
            let noteFrames = Int(note.dur * sampleRate)
            for i in 0..<noteFrames where startFrame + i < Int(frameCount) {
                let t = Double(i) / sampleRate
                // クリックノイズ防止の短いアタック + 自然な減衰のエンベロープ
                let envelope = exp(-t * decay) * min(1.0, t * 400)
                samples[startFrame + i] += Float(sin(2 * .pi * note.freq * t) * envelope * 0.5)
            }
        }
        return buffer
    }
}
#endif
