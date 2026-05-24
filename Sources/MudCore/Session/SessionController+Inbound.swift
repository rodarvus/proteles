import Foundation

/// Inbound wire-byte processing: feed received bytes through the
/// ``LinePipeline``, dispatch negotiation replies, GMCP, and lines, and the
/// once-per-connection GMCP handshake. Split out of ``SessionController`` to
/// keep the core actor file within the file-length budget.
extension SessionController {
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
            await gmcpState.apply(message)
            await chatStore.ingest(message)
            if let mapper {
                for packet in await mapper.ingest(package: message.package, json: message.json) {
                    try? await sendRaw(GMCPMessage.encode(payload: packet)) // e.g. "request area"
                }
            }
            if let scriptEngine {
                await applyScriptEffects(
                    scriptEngine.applyGMCP(package: message.package, json: message.json)
                )
            }
            if let searchAndDestroy {
                await applyScriptEffects(
                    searchAndDestroy.applyGMCP(package: message.package, json: message.json)
                )
                await rearmTimerLoopIfSnDScheduled()
            }
        }
        for line in output.lines {
            await appendLineThroughScripts(line)
        }

        await advanceAutologin(newLines: output.lines)
        await persistVariablesIfDirty()
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
