# RokidLiveView

*English: [README.md](README.md)*

Rokid Glasses の**カメラ映像とグラス表示をリアルタイムに合成して見せる** macOS アプリ。

「黒＝素通し」の見え方を再現するスクリーン合成で、装着者が見ている景色をその場で
プロジェクタや Zoom の画面共有に出せる。

```
[グラス] --scrcpy(表示)--> ┐
                          ├--> ScreenCaptureKit --> screen 合成 --> プレビュー / mp4
[グラス] --scrcpy(カメラ)--> ┘
```

## これは近似であって、装着者に見えているものそのものではない

出力は実機の見え方に**似せて調整してある**だけで、忠実な再現ではない。実機での視認性や
可読性を判断する材料には使えない。

- グラスは**光学シースルー**なので、実際の印象は周囲の明るさと目の順応に左右される。
  カメラのセンサーはそのどちらも再現しない。
- カメラの画角と肉眼の画角は一致しないため、景色に対する HUD の位置と大きさは
  **手で合わせた近似**（`hudFrac` / `hudDX` / `hudDY`）。
- 緑の単色表示は光学系から撮ったものではなく、フレームバッファに単色化とゲインを掛けた
  **エミュレーション**。
- `hudDensity` は物理的な素通しからあえて外している。映像上で文字が読めるように HUD の下の
  背景を暗くする処理で、実機は背景を暗くすることなどできない。

デモや記録のための伝達手段であって、計測の道具ではない。

## 前提

- macOS 14 以降
- `scrcpy`（Homebrew）、`ffmpeg`（音声の多重化に使用）
- Android SDK platform-tools の `adb`
- **画面収録の許可**（システム設定 → プライバシーとセキュリティ → 画面収録）

## 使い方

```bash
./build.sh          # ビルドして ~/Applications/RokidLiveView.app に配置
./build.sh --run    # 配置して起動
```

1. グラスを adb で接続する（アプリが自動検出する）
2. アプリを起動して **Start**
   - scrcpy のウィンドウが 2 枚出る（表示用・カメラ用）
   - ステータスが *Running* になり、プレビューに合成映像が出る
3. **Record / Stop Recording** で `~/Movies/RokidLiveView/live-*.av.mp4` に保存
4. **Full Screen** でプロジェクタや外部ディスプレイへ

### ウィンドウ配置のコツ

scrcpy の 2 枚は**最小化しないこと**。他のウィンドウに完全に覆われていてもキャプチャは
約 30fps を維持する（実測で確認済み）が、最小化するとフレームが止まる。

プロジェクタ運用なら「ノート画面＝scrcpy 2 枚＋操作 UI」「外部ディスプレイ＝プレビュー全画面」
という分け方が自然。Zoom では画面共有でプレビューウィンドウを選ぶ。

### スモークテスト

```bash
open -a ~/Applications/RokidLiveView.app --args --selftest
```

開始 → ウィンドウ検出 → 合成 → 静止画保存 → 6 秒録画 → 終了、までを人手なしで通す。
scrcpy を強制終了させたときの復帰確認まで含む。結果は `~/Movies/RokidLiveView/selftest.log` と同ディレクトリの
`selftest-*.png` に出る。

## 設定

調整 UI は持たない。変えたいときは UserDefaults で上書きする
（[Config.swift](Sources/RokidLiveView/Config.swift) 参照）。値は起動時に一度だけ読むので、
変更後は**アプリを再起動**すること。

```bash
defaults write com.hacha.rokidliveview hudFrac -float 0.6       # HUD の高さ / 出力の高さ
defaults write com.hacha.rokidliveview hudDY -float 200         # HUD の垂直位置（下が正）
defaults write com.hacha.rokidliveview hudGain -float 1.8       # HUD をもっと明るく
defaults write com.hacha.rokidliveview hudDensity -float 0.5    # 素通し寄りに戻す
defaults write com.hacha.rokidliveview serial -string XXXX      # 別のグラスを使う
defaults delete com.hacha.rokidliveview hudGain                 # 既定に戻す
```

| キー | 既定 | 意味 |
|---|---|---|
| `serial` | 自動検出 | グラスのシリアル。`adb devices -l` の `model:RG_glasses` から拾う。複数台繋いでいるときに指定する |
| `hudFrac` | `0.40` | HUD の高さ / 出力の高さ |
| `hudDX` | `0` | HUD 位置の中央からの水平オフセット px |
| `hudDY` | `360` | HUD 位置の中央からの垂直オフセット px（下が正） |
| `hudTint` | `00ff44` | HUD の単色化カラー。`none` でフルカラー |
| `hudGain` | `1.5` | HUD の輝度ゲイン（単色化の後に掛ける） |
| `hudDensity` | `1.0` | HUD の濃さ 0…1。HUD の場所だけ背景を暗くしてから合成する。0 で素通し重視 |
| `scrcpyPath` / `adbPath` / `ffmpegPath` | 自動検出 | 実行ファイルの場所 |
| `outputDirectory` | `~/Movies/RokidLiveView` | 録画の保存先 |

### HUD が実機の印象より薄いとき

`hudGain` を上げる。グラスのフレームバッファは**もともと緑で描かれていて**（文字画素の平均 RGB =
80.7, 201.9, 101.0 実測）、単色化の `hue=s=0` 相当が通す luma 変換で緑の係数 0.587 のぶん暗くなる
（文字の G 最大が 255 → 186.2）。1.37 前後でこの損失が戻り、そこから上げるとさらに強調できる。

`hudTint` を `none` にしても明るさは戻るが、元の緑は R,B 成分を持つのでやや白っぽくなる。
実機の緑に寄せたいなら単色化は残したまま `hudGain` で調整する方がよい。

### 「明るさ」ではなく「濃さ」が足りないとき

`hudDensity` を上げる。screen 合成（`1-(1-a)(1-b)`）は**背景を明るくすることしかできない**ので、
背景が明るいほど白へ寄って緑が薄まる。ここで `hudGain` を上げても白飛びが増えるだけで濃くならない。

`hudDensity` は HUD の輝度をマスクにして**その場所の背景を先に暗くしてから**合成する。R と B が
引かれるぶん緑が立つ。HUD が黒い（＝素通しの）場所はマスクが 0 なので背景はそのまま残る。

これは素通しとのトレードオフで、値を上げるほど明るい HUD 部分に実質的な暗い裏板が入る。
マスクは画素単位なので、文字は濃くなる一方で何も表示していない領域は透けたまま。

```bash
defaults write com.hacha.rokidliveview hudDensity -float 1.0   # 最も濃い（背景をほぼ置き換え）
defaults write com.hacha.rokidliveview hudDensity -float 0.0   # 素通し重視（物理的な見え方に忠実）
```

## 既知の注意点

### adb サーバの奪い合いで scrcpy が落ちることがある

Unity（6.x）は独自の adb（36.0.0）を同梱していて、platform-tools（34.0.4）が動かしている
adb サーバを掴み直すことがある。その瞬間 scrcpy は
`could not install *smartsocket* listener: Address already in use` で起動失敗し、
グラスが一時的に `adb devices` から消える。

- アプリ側は scrcpy の停止を検知して自動再起動し、**キャプチャも繋ぎ直す**（最大 5 回）。
  再起動後のウィンドウは windowID が変わるため、繋ぎ直さないと映像が最後のフレームで固まる。
  `--selftest` はこの復帰まで自動で確認する
- **デモ前に Unity を閉じておくのが確実**
- `adb kill-server` はしないこと（scrcpy などを巻き添えにする）。数秒待てば復帰する
- どうしても同居させたい場合は無線 adb（`adb tcpip 5555` → `adb connect <ip>:5555`）にすると、
  TCP 経由なので複数の adb サーバから並行して掴める

なお `ANDROID_ADB_SERVER_PORT` でサーバを分離しても解決しない。USB のデバイスは 1 つの
adb サーバしか claim できず（`LIBUSB_ERROR_ACCESS`）、奪い合いの場所が変わるだけ。

### 画面収録の許可はビルドの度に外れることがある

TCC の許可は「アプリの署名 + 配置場所」に紐づく。`build.sh` は Apple Development 証明書を
自動で拾って署名し、`~/Applications/RokidLiveView.app` に置くのでこれが保たれる。
証明書が無い環境では ad-hoc 署名になり、ビルドの度に再許可を求められることがある。

### アプリを強制終了すると scrcpy が残る

通常の終了（ウィンドウを閉じる / **Stop**）では scrcpy も片付くが、強制終了やクラッシュでは
残ることがある。`pkill -f "window-title=RLV-"` で消せる。

### 画質は scrcpy ウィンドウのサイズが上限

キャプチャ解像度 = ウィンドウの実ピクセル数。既定ではカメラ側 540x960 pt を Retina 2x で
取り込むので合成出力は 1080x1920。これ以上が要るなら
[Config.swift](Sources/RokidLiveView/Config.swift) の `cameraWindow` を大きくする
（そのぶん画面を占有する）。

## 設計メモ

- **なぜ scrcpy のウィンドウを取り込むのか**: ウィンドウは常に最後のフレームを保持しているので、
  「各ソースの最新フレームを毎回合成する」だけでよく、オフライン合成で必要になる
  birthtime による頭合わせが不要になる。カメラ側は `--orientation=270` で scrcpy が既に正立
  描画しているので transpose 処理も要らない。
- **なぜ ffmpeg 単体でライブ合成しないのか**: グラス表示は静止するとフレームが来ない（VFR）ため、
  `blend` の framesync が両入力の前進を待って映像全体が止まる。
- **SCK は静止中のフレームに画素を載せない**（status=idle）。最後に受け取った画素バッファを
  保持し続ける実装が必須。
- **色管理は切ってある**（`workingColorSpace = NSNull`）。CoreImage は既定でリニア空間に変換して
  合成するため、そのままだとガンマ空間で screen 合成する ffmpeg と絵が変わる。
- **合成は screen（`1-(1-a)(1-b)`）で、alpha blend ではない**。黒が寄与しない＝素通し。
  そのぶん背景が明るいほど白へ潰れるので、`hudGain` と `hudDensity` で補う。
- **録画は固定 30fps CFR**。プレビューは 60fps で回るが、実カメラが約 30fps なので重複フレームを
  書かない。音声はグラスのマイクを scrcpy の 3 本目で別録りし、停止時に ffmpeg で多重化する
  （起動遅れは `-itsoffset` で補正）。

## 注記

Rokid とは無関係の個人プロジェクトであり、Rokid による承認・提携は受けていない。
"Rokid" / "Rokid Glasses" は各権利者に帰属する。本ツールは `adb` と scrcpy 経由で
端末を扱う独立したツール。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
