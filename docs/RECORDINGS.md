# Session recordings

Every connect writes two files under `~/Documents/Proteles/Recordings/`:

- a human-readable `.log` (`SessionTranscript`): RECV/SEND/INPUT/NOTE/GMCP,
  plus a `GAG` category carrying the withheld line and the reason;
- a binary `.jsonl` of the **inbound raw wire** (per-record base64 `bytes`).

Transcript timestamps are UTC (`…Z`); compare them with a local `stat` time only
after converting.

## Inspecting telnet/MCCP2 at the byte level

Use this for terminal-type/option negotiation and similar questions. The `.log`
holds only decoded text, with no telnet control bytes. The `.jsonl` holds
**inbound bytes only**: outbound is not recorded, so you can never see our
replies directly, only what the server sent.

After MCCP2 activates, the inbound stream is **zlib-compressed**, so a raw byte
search finds nothing past that point. Decompress first: find the marker
`FF FA 56 FF F0` (`IAC SB COMPRESS2 IAC SE`), inflate everything after it, and
prepend the plaintext preamble:

```python
import json, base64, zlib
raw = b"".join(base64.b64decode(json.loads(l)["bytes"]) for l in open(PATH) if '"bytes"' in l)
i = raw.find(bytes([0xFF,0xFA,0x56,0xFF,0xF0]))
full = raw[:i] + zlib.decompressobj().decompress(raw[i+5:])   # plaintext preamble + inflated
```

Then search the combined buffer for negotiation (`FF FD/FE/FB/FC <opt>`,
`FF FA <opt> … FF F0`).

**Confirming an outbound reply you can't see:** a server `SB TTYPE SEND` in the
decompressed stream proves we replied `WILL TTYPE`, because the server only
sends it after our `WILL`. The same reasoning applies to other options whose
subnegotiation follows a client `WILL`.
