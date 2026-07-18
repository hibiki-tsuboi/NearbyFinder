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
    case found      // 発見
}

/// MultipeerConnectivity で 2 台間を流れるメッセージ。
/// priority は両者が同時に同じ役を選んだときのタイブレークに使う。
enum GameMessage: Codable {
    case discoveryToken(Data)
    case roleSelected(PlayerRole, priority: UInt32)
    case gameStarted
    case found
    case playAgain
}
