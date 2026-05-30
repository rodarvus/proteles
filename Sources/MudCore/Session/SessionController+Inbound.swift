import Foundation

/// Inbound wire-byte processing: feed received bytes through the
/// ``LinePipeline``, dispatch negotiation replies, GMCP, and lines, and the
/// once-per-connection GMCP handshake. Split out of ``SessionController`` to
/// keep the core actor file within the file-length budget.
extension SessionController {
    /// Append one event to the timestamped debug transcript (no-op when not
    /// recording). The single funnel every transcript tap in the session calls.
    func logTranscript(_ category: SessionTranscript.Category, _ text: String) {
        transcript?.log(category, text)
    }

    func processChunk(_ wireBytes: [UInt8]) async {
        // Tee to the recorder before doing any parser work — we want
        // the *wire* bytes on disk so a replay re-runs the full
        // protocol stack (MCCP2 included) deterministically.
        try? recorder?.record(wireBytes)

        let output: LinePipeline.Output
        do {
            output = try pipeline.consume(wireBytes)
        } catch {
            // Corrupt MCCP stream — drop the session. Future phases
            // will surface a user-visible error rather than bail
            // silently.
            await disconnect()
            return
        }

        // Negotiation replies go out before line appends so the server
        // sees them promptly.
        for response in output.responses {
            try? await connection?.send(response)
        }
        // Track the server's ECHO toggle (password prompts) so we don't
        // locally echo typed input while the server is echoing.
        if let serverWillEcho = output.serverWillEcho {
            serverEcho = serverWillEcho
        }

        // The server enabled GMCP — send our handshake once so it starts
        // streaming Char/Comm/Room modules.
        if output.enabledGMCP {
            await sendGMCPHandshake()
        }
        // Process this chunk's GMCP *before* its lines, so state (vitals,
        // comm.channel, …) is current when triggers and native plugins see
        // the lines — e.g. Chat Echo needs the comm.channel for a line
        // cached before deciding whether to gag that line from the main
        // window.
        for message in output.gmcp {
            await dispatchGMCP(message)
        }
        for line in output.lines {
            // Transcript the raw MUD line (pre-gag) so S&D scrape output the
            // window omits is still on disk for debugging.
            logTranscript(.recv, line.text)
            await appendLineThroughScripts(line)
        }

        await advanceAutologin(newLines: output.lines)
        await persistVariablesIfDirty()
    }

    /// Extract Aardwolf's `state` from a `char.status` GMCP payload (≥ 3 = in
    /// the game). `nil` if absent/unparseable.
    nonisolated static func charStatusState(_ json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let state = object["state"] as? Int { return state }
        if let state = object["state"] as? NSNumber { return state.intValue }
        return nil
    }

    /// Route one GMCP message to the GMCP state, chat, mapper, script engine,
    /// and the S&D host. Split out of ``processChunk`` for the complexity
    /// budget. Also reused by the `injectGMCP` effect (synthesized config
    /// packets from the native GMCP handler) so they take the same path.
    func dispatchGMCP(_ message: GMCPMessage) async {
        logTranscript(.gmcp, "\(message.package) \(message.json)")
        latestGMCPByPackage[message.package.lowercased()] = message.json
        await gmcpState.apply(message)
        if let chatLine = await chatStore.ingest(message) { await notifyForChat(chatLine) }
        if let mapper {
            for packet in await mapper.ingest(package: message.package, json: message.json) {
                try? await sendRaw(GMCPMessage.encode(payload: packet)) // e.g. "request area"
            }
        }
        // On each room.info (post-login), refresh Rich Exits and one-shot enable
        // any tag options whose features are on.
        if message.package.lowercased() == "room.info" {
            if richExitsEnabled { await refreshRichExits() }
            if helpCaptureEnabled, !sentHelpsTagOption {
                sentHelpsTagOption = true
                await setAardwolfTagOption(3, on: true) // TELOPT_HELPS
            }
        }
        // Hold `char.status` plugin delivery until the character is in-game
        // (state ≥ 3), matching MUSHclient: a transitional mid-login char.status
        // (state 2) otherwise makes plugins act prematurely — e.g. Hadar's
        // spellup-list request fires before login completes, fails, and recovers
        // too slowly, so spell tracking never works. The native HUD (gmcpState,
        // above) still updates throughout.
        let isCharStatus = message.package.lowercased() == "char.status"
        if isCharStatus, !seenCharInGame, (Self.charStatusState(message.json) ?? 0) >= 3 {
            seenCharInGame = true
        }
        let holdCharStatus = isCharStatus && !seenCharInGame
        if let scriptEngine, !holdCharStatus {
            await applyScriptEffects(scriptEngine.applyGMCP(package: message.package, json: message.json))
            // MUSHclient also hands the raw GMCP to OnPluginTelnetSubnegotiation
            // (option 201); dinv's config detection reads only that path.
            await applyScriptEffects(scriptEngine.deliverGMCPSubnegotiation(
                package: message.package, json: message.json
            ))
            // A plugin's OnPluginBroadcast may have scheduled a one-shot (e.g. a
            // wait.time resume timer); re-arm the loop so it fires when idle.
            await rearmTimerLoopIfScriptScheduled()
        }
        if let searchAndDestroy {
            await applyScriptEffects(searchAndDestroy.applyGMCP(package: message.package, json: message.json))
            await rearmTimerLoopIfSnDScheduled()
        }
        // Load the armed dinv once the character is active (its init keys off the
        // first char.base broadcast it sees while active — see D-32).
        if armedDinvShouldLoad(for: message) { await loadPendingDinv() }
    }

    /// Refresh the cached Rich Exits data from the current GMCP room (cardinals)
    /// and the mapper graph (custom exits), and — on the first call per session —
    /// enable Aardwolf's exits tag so the exits line becomes detectable. Safe to
    /// call when disconnected (caches clear; the tag command is a no-op).
    func refreshRichExits() async {
        let exits = await gmcpState.state.room?.exits
        richExitsCardinals = RichExits.cardinals(fromExits: exits)
        richExitsCustomExits = await mapper?.currentRoomCustomExits() ?? []
        if !sentExitsTag {
            sentExitsTag = true
            try? await dispatchCommand("tags exits on")
        }
    }

    /// Feed an incoming line to the Help-capture state machine. Returns `true`
    /// if the line was consumed (a tag marker or a buffered body line) so the
    /// caller skips normal output/script processing. On the closing tag, the
    /// buffered block is published to the Help panel as a ``HelpArticle``.
    func captureHelpLine(_ line: Line) -> Bool {
        if helpCaptureActive {
            if HelpParser.isCloseTag(line.text) {
                helpCaptureActive = false
                let article = HelpParser.makeArticle(from: helpCaptureBuffer, isSearch: helpCaptureIsSearch)
                helpCaptureBuffer = []
                helpArticlesContinuation.yield(article)
                return true
            }
            helpCaptureBuffer.append(line)
            return true
        }
        if let isSearch = HelpParser.openTag(line.text) {
            helpCaptureActive = true
            helpCaptureIsSearch = isSearch
            helpCaptureBuffer = []
            return true
        }
        return false
    }

    /// Toggle an Aardwolf "tag" telnet option via the option-102 subnegotiation
    /// (`IAC SB 102 <option> <1=on|2=off> IAC SE`) — exactly as
    /// `telnet_options.lua`'s `TelnetOption` does. Used to enable HELPS (3) tags
    /// so help output arrives wrapped in `{help}…{/help}`.
    func setAardwolfTagOption(_ option: UInt8, on: Bool) async {
        let aardwolfTelopt: UInt8 = 102
        let payload: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, aardwolfTelopt,
            option, on ? 1 : 2,
            TelnetCommand.iac, TelnetCommand.se
        ]
        try? await sendRaw(payload)
    }

    /// Apply the Rich Exits transform to an outgoing line: when enabled, rewrite
    /// the tagged exits line into clickable directions (from the cached
    /// cardinals + custom exits) and flag the tag-toggle confirmation for
    /// gagging. Returns the line to append + whether it should be suppressed.
    func applyRichExits(_ line: Line, source: Line) -> (line: Line, gag: Bool) {
        guard richExitsEnabled else { return (line, false) }
        if RichExits.isTagConfirmation(line.text) { return (line, true) }
        guard RichExits.isTaggedExitsLine(line.text) else { return (line, false) }
        let rendered = RichExits.render(
            cardinals: richExitsCardinals,
            customExits: richExitsCustomExits,
            id: source.id,
            timestamp: source.timestamp
        )
        return (rendered, false)
    }

    /// True when dinv is armed-but-unloaded and `message` is an active
    /// `char.status` (Aardwolf state 3 = "Active"/ready — parsed leniently).
    private func armedDinvShouldLoad(for message: GMCPMessage) -> Bool {
        guard !dinvLoaded, pendingDinvStateDirectory != nil,
              message.package.lowercased() == "char.status",
              let data = message.json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["state"] as? Int) == 3 || (object["state"] as? String) == "3"
    }

    /// Send the Aardwolf GMCP handshake (Core.Hello, Core.Supports.Set,
    /// then the config/request batch). Sent at most once per connection.
    func sendGMCPHandshake() async {
        guard !gmcpHandshakeSent else { return }
        gmcpHandshakeSent = true
        for packet in GMCPMessage.aardwolfHandshake(clientVersion: MudCore.version) {
            try? await connection?.send(packet)
        }
    }

    func flushOnDisconnect() async {
        let trailing = pipeline.flush()
        for line in trailing {
            await scrollbackStore.append(line)
        }
    }
}
