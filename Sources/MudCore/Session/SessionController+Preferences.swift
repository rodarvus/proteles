import Foundation

/// Live, user-facing preference setters pushed from the UI's persisted toggles
/// (the Preferences window / View menu). Kept together so the settings surface
/// is easy to find and extend.
public extension SessionController {
    /// Set the blank-line omission preference (drop completely-empty lines).
    func setOmitBlankLines(_ enabled: Bool) {
        omitBlankLines = enabled
    }

    /// Push the user's configured output font name into the scripting runtime so
    /// `GetAlphaOption("output_font_name")` reports the real font (not a default).
    func setOutputFontName(_ name: String) async {
        await scriptEngine?.setOutputFontName(name)
    }

    /// Withhold leftover Aardwolf tag lines (`{rname}`/`{coords}`/…) from the
    /// live window. Display-only + post-processing: plugins still see the line.
    /// Whether script errors also appear as red notes in the main output
    /// (Settings ▸ Input ▸ Scripting, #16); the Lua Console sees them always.
    func setScriptErrorsInOutput(_ enabled: Bool) async {
        await scriptEngine?.setErrorNotesVisible(enabled)
    }

    func setGagTagLines(_ enabled: Bool) {
        gagTagLines = enabled
    }

    /// Enable/disable auto-reconnect. Maps to the standard backoff policy or
    /// none; takes effect on the next drop.
    func setReconnectEnabled(_ enabled: Bool) {
        reconnectPolicy = enabled ? .standard : .disabled
    }

    /// Enable/disable automatic session recording. Takes effect on the next
    /// connection.
    func setAutoRecord(_ enabled: Bool) {
        autoRecord = enabled
    }

    /// Enable/disable the anti-idle keep-alive (telnet NOP). Applies on the
    /// next cadence tick; the loop keeps running so re-enabling needs no
    /// reconnect.
    func setKeepAliveEnabled(_ enabled: Bool) {
        keepAliveEnabled = enabled
    }

    /// Enable/disable Rich Exits (clickable exit hyperlinks in the main output).
    /// Enabling turns on Aardwolf's exits tag + caches the current room's exits;
    /// disabling turns the tag back off so the raw `{exits}` line never shows.
    func setRichExitsEnabled(_ enabled: Bool) async {
        guard richExitsEnabled != enabled else { return }
        richExitsEnabled = enabled
        if enabled {
            await refreshRichExits()
        } else {
            if sentExitsTag {
                sentExitsTag = false
                try? await dispatchCommand("tags exits off")
            }
            richExitsCardinals = []
            richExitsCustomExits = []
        }
    }

    /// Enable/disable in-game Help capture (the Help panel). Enabling turns on
    /// Aardwolf's HELPS tag option so `help` output arrives tagged; disabling
    /// turns it off and discards any partial capture.
    func setHelpCaptureEnabled(_ enabled: Bool) async {
        guard helpCaptureEnabled != enabled else { return }
        helpCaptureEnabled = enabled
        if enabled {
            if !sentHelpsTagOption {
                sentHelpsTagOption = true
                await setAardwolfTagOption(3, on: true) // TELOPT_HELPS
            }
        } else {
            if sentHelpsTagOption {
                sentHelpsTagOption = false
                await setAardwolfTagOption(3, on: false)
            }
            helpCaptureActive = false
            helpCaptureBuffer = []
        }
    }

    /// Enable/disable Marketplace capture. When enabled, `lbid` / `market`
    /// command responses are withheld from main output and published to the
    /// native Marketplace window.
    func setMarketCaptureEnabled(_ enabled: Bool) {
        guard marketCaptureEnabled != enabled else { return }
        marketCaptureEnabled = enabled
        if !enabled {
            marketTagCaptureActive = false
            marketTagCaptureBuffer = []
            marketCommandCapture = nil
            queuedMarketCommandCaptures = []
        }
    }
}
