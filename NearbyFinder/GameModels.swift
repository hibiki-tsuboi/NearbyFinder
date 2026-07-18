//
//  GameModels.swift
//  NearbyFinder
//

import Foundation

enum PlayerRole: String, Codable {
    case treasure   // 宝役（この iPhone を隠す）
    case hunter     // ハンター役（探す側）

    var opposite: PlayerRole { self == .treasure ? .hunter : .treasure }
}

enum GamePhase: Equatable {
    case lobby      // 役割選択
    case hiding     // 隠す猶予時間
    case hunting    // 探索中
    case finished   // 決着
}

enum GameOutcome: Equatable {
    case hunterWon    // ハンターが制限時間内に発見
    case treasureWon  // 時間切れで宝役が逃げ切り
}

/// MultipeerConnectivity で 2 台間を流れるメッセージ。
/// priority は両者が同時に同じ役を選んだときのタイブレークに使う。
enum GameMessage: Codable {
    case discoveryToken(Data)
    case roleSelected(PlayerRole, priority: UInt32)
    case gameStarted
    case found
    case timeUp
    case playAgain
    /// 自分のペアの Apple Watch の NI トークン（相手 iPhone が Watch と測距するために送る）
    case watchToken(Data)
    /// 上記への返信。相手 iPhone が Watch 用に作ったセッションのトークン（Watch の持ち主経由で Watch へ渡す）
    case watchPeerToken(Data)
}

/// 端末ローカルに保存する戦績。決着時に両端末がそれぞれ自分の分を更新する。
struct GameStats: Codable, Equatable {
    var hunterWins = 0
    var treasureWins = 0
    var bestClearSeconds: Int?

    private static let key = "gameStats"

    static func load() -> GameStats {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stats = try? JSONDecoder().decode(GameStats.self, from: data) else {
            return GameStats()
        }
        return stats
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// 戦績を反映し、ベストタイム更新なら true を返す
    mutating func record(outcome: GameOutcome, clearSeconds: Int?) -> Bool {
        switch outcome {
        case .hunterWon: hunterWins += 1
        case .treasureWon: treasureWins += 1
        }
        if let clearSeconds, clearSeconds < (bestClearSeconds ?? .max) {
            bestClearSeconds = clearSeconds
            return true
        }
        return false
    }
}
