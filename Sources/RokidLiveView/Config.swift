import Foundation

/// 設定値。調整 UI は持たず、値を変えたいときは UserDefaults で上書きする:
///   defaults write com.hacha.rokidliveview hudFrac -float 0.6
enum Config {
    /// 対象のグラスのシリアル。未設定なら adb から自動検出する。
    /// 検出できなければ空文字を返すので、呼び出し側で案内を出すこと。
    static let serial: String = {
        if let override = UserDefaults.standard.string(forKey: "serial"), !override.isEmpty {
            return override
        }
        return detectGlasses() ?? ""
    }()

    /// `adb devices -l` からグラスを探す。
    /// エミュレータやスマホが同時に繋がっていることがあるので、まず model で絞り、
    /// 該当が無ければ「接続が 1 台だけ」のときにそれを使う。
    private static func detectGlasses() -> String? {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["devices", "-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let online = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(" device ") || $0.contains("\tdevice ") }

        func serial(of line: String) -> String? {
            line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        // RG-glasses は model:RG_glasses / product:glasses として現れる (実機確認)
        if let glasses = online.first(where: { $0.contains("model:RG_glasses") || $0.contains("product:glasses") }) {
            return serial(of: glasses)
        }
        return online.count == 1 ? serial(of: online[0]) : nil
    }

    /// HUD の高さ / 出力の高さ
    static let hudFrac = double("hudFrac", default: 0.40)
    /// HUD 位置の中央からのオフセット px。DY は下方向が正 (ffmpeg 側の座標系に合わせる)
    static let hudDX = double("hudDX", default: 0)
    static let hudDY = double("hudDY", default: 360)
    /// HUD の単色化カラー。実機は緑単色ディスプレイなのでそれを再現する。"none" でフルカラーのまま
    static let hudTint = string("hudTint", default: "00ff44")

    /// HUD の輝度ゲイン。単色化の後に掛ける。
    ///
    /// グラスのフレームバッファはもともと緑で描かれており (文字画素の平均 RGB = 80.7, 201.9, 101.0)、
    /// hue=s=0 相当の luma 変換を通すと緑の係数 0.587 のぶん暗くなる (文字の G 最大 255 → 186.2)。
    /// 255 / 186.2 ≒ 1.37 でピークが戻る。そこから上げると実機の印象に寄せて強調できる。
    static let hudGain = double("hudGain", default: 1.5)

    /// HUD の濃さ (0…1)。HUD がある場所だけ背景を暗くしてから screen 合成する。
    ///
    /// screen 合成 (1-(1-a)(1-b)) は背景を明るくすることしかできないので、背景が明るいほど
    /// 白に寄って緑が薄まる。ゲインを上げても白飛びが増えるだけで「濃く」はならない。
    /// そこで HUD の輝度をマスクとして背景を落とし、R と B を引いて緑を立たせる。
    /// 0 = 従来どおり素通し重視 / 1 = HUD の色で背景をほぼ置き換える。
    static let hudDensity = double("hudDensity", default: 1)

    /// scrcpy ウィンドウの配置とサイズ (pt)。
    /// キャプチャ解像度 = このサイズ × Retina 倍率 なので、画質に直結する。
    /// カメラ側のキャプチャ解像度がそのまま合成出力の解像度になる。
    static let displayWindow = WindowGeometry(x: 20, y: 60, width: 480, height: 640)
    static let cameraWindow = WindowGeometry(x: 520, y: 60, width: 540, height: 960)

    /// カメラ映像の回転。RG-glasses FW 1.21 実測でカメラは横向きに出るため 270 で正立させる
    static let cameraOrientation = string("cameraOrientation", default: "270")

    static let scrcpyPath: String = {
        if let override = UserDefaults.standard.string(forKey: "scrcpyPath") { return override }
        for candidate in ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/opt/homebrew/bin/scrcpy"
    }()

    static let adbPath: String = {
        if let override = UserDefaults.standard.string(forKey: "adbPath") { return override }
        return NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
    }()

    static let ffmpegPath: String = {
        if let override = UserDefaults.standard.string(forKey: "ffmpegPath") { return override }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/opt/homebrew/bin/ffmpeg"
    }()

    /// 録画とスモークテストの出力先
    static let outputDirectory: URL = {
        if let override = UserDefaults.standard.string(forKey: "outputDirectory") {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Movies/RokidLiveView")
    }()

    /// 出力先を作ってから返す。初回起動ではディレクトリがまだ無いので、書き込む側は必ずこちらを使う。
    @discardableResult
    static func ensureOutputDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory
    }

    /// ウィンドウ特定用のタイトル。scrcpy の --window-title がそのまま SCWindow.title に載る (実測確認済)
    static let displayTitle = "RLV-DISPLAY"
    static let cameraTitle = "RLV-CAMERA"

    /// HUD 単色化の RGB 係数。none のときは nil
    static var hudTintComponents: (r: Double, g: Double, b: Double)? {
        let hex = hudTint.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.lowercased() != "none", hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }
        return (
            Double((value >> 16) & 0xff) / 255.0,
            Double((value >> 8) & 0xff) / 255.0,
            Double(value & 0xff) / 255.0
        )
    }

    private static func string(_ key: String, default fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    private static func double(_ key: String, default fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) != nil
            ? UserDefaults.standard.double(forKey: key) : fallback
    }
}

struct WindowGeometry {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}
