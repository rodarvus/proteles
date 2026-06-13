# WebSocket transport — status

**Short version:** Proteles connects to Aardwolf over **Direct (TCP)**, the
full-featured path. A WebSocket transport exists in the codebase (it was the
intended iOS path, since iOS has no raw sockets), but it is **not offered in the
UI** as of 1.0 — Aardwolf's WebSocket gateway forwards only a subset of GMCP, so
most of the client's richer features stay dark over it.

## Why it's disabled in the UI

Aardwolf's WebSocket gateway (`wss://play.aardwolf.com:6200/`) was implemented
roughly a decade ago and forwards only a **subset** of the GMCP packages that the
raw TCP connection delivers. Audited from live session recordings, comparing
WebSocket against a TCP baseline:

| GMCP package                    | Direct (TCP) | WebSocket |
| ------------------------------- | :----------: | :-------: |
| `comm.tick`                     | ✅           | ✅        |
| `comm.repop`                    | ✅           | ✅        |
| `comm.quest`                    | ✅           | ✅        |
| `group`                         | ✅           | ✅        |
| `char.vitals`                   | ✅           | ❌        |
| `char.stats`                    | ✅           | ❌        |
| `char.status`                   | ✅           | ❌        |
| `char.base`                     | ✅           | ❌        |
| `char.worth` / `char.maxstats`  | ✅           | ❌        |
| `room.info`                     | ✅           | ❌        |
| `config`                        | ✅           | ❌        |
| `comm.channel`                  | ✅           | ❌        |

The evidence is conclusive rather than a quiet session: on connect Proteles
explicitly requests `char`, `room`, `area`, `sectors`, `quest`, and `group`.
Over WebSocket, `quest` and `group` reply immediately, but `char.base` /
`room.info` / `area` / `sectors` never arrive. Request/response packages answer
regardless of in-game activity, so the silence on the `char.*` / `room.*` /
`config` families is a gateway limitation, not a timing artefact.

### What that means in practice over WebSocket

- **Vitals HUD** — empty (no `char.vitals` / `char.stats` / `char.status`).
- **Mapper** — does not track (no `room.info`).
- **Channels panel** — empty (no `comm.channel`; channel text still arrives in
  the main stream, but the GMCP-driven panel stays dark).
- **Working:** group monitor, tick timer, repop/quest events, and raw game text.

Net: WebSocket connects and plays as raw text, but the GMCP-driven features that
make Proteles worth using are dark. **Direct (TCP) is the recommended and only
UI-exposed transport.**

## Current decision

- The transport selector in the connection editor offers **Direct (TCP) only**.
- The WebSocket code (`WebSocketConnection`, `WebSocketFraming`,
  `TransportSelector`, the `ConnectionTransport.webSocket` case) is **retained**
  but not surfaced — it's the basis for a future iOS client, and is worth
  revisiting if the gateway ever forwards the full GMCP set.
- Aardwolf's maintainer (Lasher) is aware of the gateway's GMCP limitation; it is
  a server-side constraint, not something the client can work around.

_History: tracked as GitHub issue #46 (closed)._
