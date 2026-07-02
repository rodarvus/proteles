import Foundation

/// The ambient information a script/plugin can query about its environment —
/// the backing for the MUSHclient `GetInfo(N)` / `GetPluginID` surface the
/// Phase-6 shim maps onto (ARCHITECTURE.md §8.7).
///
/// A plain value type the host sets per plugin (the loader builds one with
/// the plugin's id + directories; the user's own scripts get ``default``).
/// ``info(_:now:)`` resolves only the `GetInfo` numbers the Aardwolf corpus
/// actually uses — mostly path/dir lookups plus world identity, time, and a
/// few flags. Window-geometry numbers (only meaningful once miniwindows
/// exist) return sane stubs so non-window plugins that read them don't crash;
/// everything unrecognised returns `nil` (≈ MUSHclient returning nil).
public struct PluginContext: Sendable, Equatable {
    /// A resolved `GetInfo` value, typed so the bridge can push the right
    /// Lua type (string / number / boolean).
    public enum InfoValue: Sendable, Equatable {
        case text(String)
        case number(Double)
        case flag(Bool)
    }

    public var pluginID: String
    public var pluginName: String
    /// The plugin's version string (from its `<plugin version="…">`); surfaced
    /// via `GetPluginInfo(id, 19)`, which plugins print on install.
    public var version: String
    /// The plugin's `<description>` body, surfaced as `GetPluginInfo(id, 3)`.
    public var pluginDescription: String
    /// Full path to the loaded plugin XML file, surfaced as `GetPluginInfo(id, 6)`.
    public var pluginSourceFile: String
    /// Directory the plugin was loaded from (its own files live here).
    public var pluginDirectory: String
    public var worldName: String
    /// Directory of the world/profile's files and per-world databases.
    public var worldDirectory: String
    /// The app's support directory (≈ MUSHclient application directory).
    public var appDirectory: String
    /// Where plugin state (persisted variables, etc.) is written.
    public var stateDirectory: String
    public var soundsDirectory: String
    public var logDirectory: String

    /// The shared `~/Documents/Proteles/Sounds/` path (trailing slash) every
    /// context resolves `GetInfo(74)` to by default, so a plugin's
    /// `PlaySound(0, GetInfo(74) .. "x.wav", …)` (S&D's cues, the reference
    /// soundpack idiom) finds the user's cue files. Empty if the data home
    /// can't be created. Evaluated once, lazily (path lookup + mkdir).
    public static let defaultSoundsPath: String = {
        guard let url = try? ProtelesPaths.soundsDirectory() else { return "" }
        return url.path + "/"
    }()

    public init(
        pluginID: String,
        pluginName: String,
        version: String = "",
        pluginDescription: String = "",
        pluginSourceFile: String = "",
        pluginDirectory: String = "",
        worldName: String = "Aardwolf",
        worldDirectory: String = "",
        appDirectory: String = "",
        stateDirectory: String = "",
        soundsDirectory: String = PluginContext.defaultSoundsPath,
        logDirectory: String = ""
    ) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.version = version
        self.pluginDescription = pluginDescription
        self.pluginSourceFile = pluginSourceFile
        self.pluginDirectory = pluginDirectory
        self.worldName = worldName
        self.worldDirectory = worldDirectory
        self.appDirectory = appDirectory
        self.stateDirectory = stateDirectory
        self.soundsDirectory = soundsDirectory
        self.logDirectory = logDirectory
    }

    /// The context for the user's own (non-plugin) scripts.
    public static let `default` = PluginContext(
        pluginID: "_user",
        pluginName: "User Scripts"
    )

    /// Resolve a MUSHclient `GetInfo` number. Returns `nil` for codes we
    /// don't implement, matching MUSHclient's nil-for-unknown behaviour.
    /// (Numbers per `submodules/mushclient/scripting/methods/methods_info.cpp`.)
    public func info(_ code: Int, now: Date = Date()) -> InfoValue? {
        if let text = textInfo(code) { return .text(text) }
        if let flag = flagInfo(code) { return .flag(flag) }
        if let number = numberInfo(code, now: now) { return .number(number) }
        return nil
    }

    /// Path/identity codes. Codes 1/19 double as `GetPluginInfo` name/version
    /// for the current plugin (the compat shim routes them here); our `GetInfo`
    /// doesn't otherwise use them.
    private func textInfo(_ code: Int) -> String? {
        switch code {
        case 1: pluginName // GetPluginInfo: name
        case 19: version // GetPluginInfo: version
        case 2: worldName // world name
        // GetInfo(56) ("application path name") maps to the plugin's OWN folder,
        // not the per-character data dir — a Proteles divergence from MUSHclient
        // (where 56 is the shared install root). This gives a plugin a stable,
        // global-across-characters, hand-editable home for flat-file config it
        // reads via `GetInfo(56) .. "x.txt"` (e.g. the message gagger's gag
        // list). DB-backed plugins keep per-character storage via 66/85 below.
        case 66: appDirectory // application directory (per-character data dir)
        case 58: logDirectory // log files directory
        case 56, 60, 64: pluginDirectory // app path / plugin path / current dir
        case 67: worldDirectory // world file directory
        case 74: soundsDirectory // sounds directory
        case 85: stateDirectory // state files directory
        default: nil
        }
    }

    /// Boolean status codes.
    private func flagInfo(_ code: Int) -> Bool? {
        switch code {
        case 113: true // world is active
        case 114: false // output paused/frozen
        case 120: true // scroll bar visible
        default: nil
        }
    }

    /// Numeric codes (time). Output-window geometry (`GetInfo(280/281)`) is
    /// answered live by ``LuaRuntime`` from the real output-view size (#30), not
    /// here — it isn't a per-plugin constant.
    private func numberInfo(_ code: Int, now: Date) -> Double? {
        switch code {
        case 304: now.timeIntervalSince1970
        default: nil
        }
    }
}
