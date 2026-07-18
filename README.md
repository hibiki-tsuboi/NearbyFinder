# NearbyFinder

iPhone 2 台で遊ぶ宝探しゲームです。片方の iPhone を「宝」として隠し、もう片方の「ハンター」が Nearby Interaction（UWB）のリアルタイム距離・方向表示を頼りに探し出します。Find My の「探す」画面のような矢印 UI、距離に連動したソナー音とハプティクス、AR での発見演出、Apple Watch でのハンター補助表示に対応しています。

## 遊び方

1. 両方の iPhone でアプリを起動し、タイトル画面で「はじめる」をタップすると自動でペアリングされます（ロビー）。タイトル画面には通算成績と「あそびかた」も表示されます
2. ロビーでモード（かくれんぼ / 逃走中）・隠す時間（30/60/90 秒）・制限時間（3/5/10 分）を設定し、役割を選択
3. 宝側が iPhone を隠し（逃走中モードでは iPhone を持って逃げ）、ハントを開始
4. ハンターは矢印と距離表示、音・振動を頼りに捜索。制限時間切れは宝側の勝ち
5. かくれんぼ: 見つけたら **宝側デバイスの画面** のスライダーを操作して発見を確定。逃走中: 1m 以内まで追い詰めたら自動で「確保！」
6. リザルト画面に接近グラフ（距離の推移）と勝敗が表示されます
7. 「交代して再戦」で役割を入れ替えて連戦。先に 3 勝したほうがシリーズ優勝です

### 逃走中モード

宝役が「逃走者」になり、iPhone を持ったまま逃げ回るリアルタイム鬼ごっこです。逃走者の画面にはハンターまでの距離が表示され、近づくと画面が赤く警告＋振動（音は鳴らないので居場所はバレません）。ハンターが 1m 以内まで追い詰めると自動で確保となります。

発見の確定を「距離が近づいたら自動」ではなく物理的なスライド操作にしているのは意図的です。UWB の近接判定は本体を実際に見つける前に反応してしまうため、また隠した iPhone が布や肌に触れて誤タップが起きるため、電話応答式のスライド操作を採用しています。

## 動作要件

- UWB（U1/U2 チップ）搭載の iPhone 2 台 — iPhone 11 以降（SE は非対応）
- iOS 26.5 以降
- 両方のアプリがフォアグラウンドにあること（バックグラウンドに回ると NI セッションが一時停止します）
- （任意）Apple Watch — ハンター側の手元に距離を表示（watchOS の NI は距離のみで方向は取得できません）

Xcode プロジェクトはマルチプラットフォーム（iOS / macOS / visionOS）ですが、Nearby Interaction は iOS でのみ動作します。他プラットフォームはスタブに対してコンパイルされ、「非対応」画面が表示されます。Xcode では、起動済みシミュレータ 2 台の間で NI をシミュレートすることもできます。

## ビルド

```sh
xcodebuild -project NearbyFinder.xcodeproj -scheme NearbyFinder \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

- macOS のコンパイル確認: `-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- Watch アプリ単体: `-scheme NearbyFinderWatch -destination 'generic/platform=watchOS Simulator'`

外部依存（Swift Package）はありません。

## 仕組み

```
┌─ iPhone A ─────────────┐        ┌─ iPhone B ─────────────┐
│ MultipeerSession        │◀──MC──▶│ MultipeerSession        │  発見・メッセージ交換
│ NearbySessionManager    │◀─UWB──▶│ NearbySessionManager    │  距離・方向の測距
│ GameManager             │        │ GameManager             │  ゲーム状態機械
└────────┬───────────────┘        └────────────────────────┘
         │ WatchConnectivity
┌─ Apple Watch ──────────┐
│ WatchRanger             │◀─UWB──▶ iPhone B（直接測距）
└────────────────────────┘
```

- **`MultipeerSession`** — MultipeerConnectivity の薄いラッパー。ピアの発見と JSON メッセージの交換を担当。接続の安定化（招待の衝突回避、片方向発見のフォールバック、失敗時のトランスポート再構築）を内蔵
- **`NearbySessionManager`** — `NISession` を所有し、`distance` / `direction` を publish。ディスカバリートークンの交換、中断・復帰、カメラアシスタンスによる方向精度向上、AR 用の `peerWorldTransform` の提供を担当
- **`GameManager`** — ゲーム状態機械（`lobby → hiding → hunting → finished`）。役割の同期、制限時間の監視（宝側が権威）、距離連動ハプティクス、接近グラフ用の距離履歴の記録、Watch への状態中継
- **`GameAudio`** — 効果音は AVAudioEngine で実行時に合成（音声アセットなし）。マナーモードを尊重する `.ambient` カテゴリ
- **Views** — `ContentView`（フェーズ切替）、`HuntingView`（矢印の捜索 UI）、`ARTreasureView`（RealityKit の AR 演出）
- **Watch 対応** — watchOS には MultipeerConnectivity がないため、トークンを Watch → 自分の iPhone → 相手の iPhone と中継し、相手 iPhone が Watch 用の第 2 `NISession` を開いて Watch ↔ iPhone 間で直接 UWB 測距します

詳しい設計上の制約・経緯は [CLAUDE.md](CLAUDE.md) を参照してください。

## プロジェクト構成

```
NearbyFinder/            iOS アプリ本体（macOS/visionOS はスタブ）
NearbyFinderWatch/       watchOS コンパニオンアプリ
Info.plist               NSBonjourServices など INFOPLIST_KEY_* で表現できないキー
NearbyFinder.xcodeproj
```

テストターゲットは未整備です。
