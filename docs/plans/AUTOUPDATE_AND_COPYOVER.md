# Auto-update (Sparkle) + client-side copyover — feasibility & plan

> **Status: shipped (feature-complete for 1.0). Historical design doc — kept for the rationale and trade-offs.** Both phases landed: **Phase 1** Sparkle auto-updater (#23, closed) and **Phase 2** seamless "update now" / client-side copyover (#42, closed). The interim GitHub-hosted appcast and the `proteles.net` migration tracked under "Before 1.0" remain release-engineering follow-ups for the wider rollout.

**Tracks GH #23 (Phase 1) + #42 (Phase 2).** This doc decided *what* to build and *in what
order*; the implementation followed it (see the status banner above).

The 1.0 release-engineering gate has two parts that the user wants considered
together:

1. **Auto-updater** — ship updates to users without a manual re-download.
2. **Client-side copyover** — when an update installs, the user shouldn't *feel*
   like they got kicked off Aardwolf. (Explicitly **client-side**: it's *our app*
   relaunching for an update, not the MUD server's hot-reboot.)

---

## Part 1 — Sparkle auto-updater

### Why Sparkle

It's the de-facto standard for non-MAS macOS apps, actively maintained, supports
**EdDSA-signed** appcasts, delta updates, and a hardened-runtime + notarization
story. We already ship a **notarized Developer-ID** build (since v0.4.5) and are
**non-sandboxed** (`Proteles.entitlements`), which is the easy case for Sparkle.

### Integration outline

- **Dependency:** add `Sparkle` (2.x) via SwiftPM to the app target only (not
  MudCore — keep the core platform-agnostic and dependency-light).
- **Entitlements / hardened runtime:** Sparkle 2 ships XPC services + an
  Installer/Downloader that must be **signed with our Developer-ID and the right
  hardened-runtime exceptions** and stapled inside the bundle. `scripts/release.sh`
  already does Developer-ID signing + notarize + staple; it gains a step to sign
  the embedded Sparkle XPC services before the outer sign.
- **Appcast:** an `appcast.xml` (EdDSA-signed) hosted on **GitHub Releases** (we
  already publish the notarized zip there per release). `release.sh` generates +
  signs the appcast entry (`generate_appcast`) and uploads it as a release asset.
- **Keys:** the Sparkle **EdDSA private key** lives only on the release machine
  (same posture as the notary profile — *never committed*). The public key goes
  in `Info.plist` (`SUPublicEDKey`).
- **UI:** standard Sparkle "Check for Updates…" menu item + automatic background
  checks (opt-in on first launch). Settings ▸ a small "Updates" control
  (auto-check on/off, channel).
- **`MudCore.version`** already reads `MARKETING_VERSION`; Sparkle compares
  `CFBundleVersion` (the build number) — both are bumped in `project.yml` today.

### Risk / unknowns

- Embedded-XPC signing under our `release.sh` flow needs a careful first pass
  (Sparkle's `codesign` requirements are specific); budget one notarization
  round-trip to get it right.
- Appcast hosting on GitHub Releases is fine but the URL must be stable across
  releases (use a fixed `appcast.xml` asset name or a `gh-pages`/raw URL).

---

## Part 2 — Client-side copyover

**Goal:** installing an update should not make the user re-do their login or lose
their place. The MUD-server *copyover* keeps player sockets open across an
`exec()`; the client analogue is "relaunch the app without the player feeling
disconnected."

### Option A — true socket/FD preservation (rejected)

Keep the live TCP socket open across the relaunch (pass the FD to the new
process, MUD-server style).

**Why it doesn't work for us:**

- Sparkle installs by **quitting the running app and launching the new bundle**
  via a separate installer process. Our process exits → the socket closes.
- Even with FD-passing gymnastics (a helper holding the FD across the relaunch),
  the **session state that matters lives in-process and mid-stream**: the
  **MCCP2 (zlib) decompression context** is a continuous stream with no resync
  point, plus telnet negotiation state, GMCP module state, the Lua runtimes
  (dinv/S&D/native plugins), trigger/timer state, and the mapper actor. None of
  that survives `exec()` without a full serialize/restore that's far more complex
  and fragile than reconnecting.
- **Reference check:** Mudlet itself does **not** preserve the socket on
  client restart — its `cTelnet::reconnect()` (`submodules/mudlet/src/ctelnet.cpp`,
  and `mAutoReconnect`) just drop
  and re-establish. The established MUD-client pattern for resilience is **fast
  reconnect**, not FD preservation. We should follow the reference.

### Option B — seamless reconnect on update-relaunch (recommended)

Make the relaunch *feel* seamless by reconnecting fast and restoring context.
Aardwolf keeps character state server-side, so a brief reconnect mid-play loses
nothing real — the cost is purely the re-login + scrollback gap, which we can
hide.

**We already have most of the pieces:**

| Need | Existing building block |
|---|---|
| Re-establish the connection | `ReconnectPolicy` + the autoreconnect loop (`SessionController+Reconnect.swift`) |
| Log back in automatically | `SessionController+Autologin.swift` + `CredentialStore` |
| Restore the screen | `ScrollbackPersistence` (persists every line; reload on launch) |
| Restore the map | native mapper reads the per-world `Aardwolf.db` from disk |
| Plugin state | plugins re-init on connect (already the reconnect path) |

**What's new for copyover specifically:**

1. On a Sparkle-initiated relaunch, write a small **"resume token"** (world id +
   "was connected" + optional "reconnect immediately") so the new launch knows to
   auto-open that world and connect, rather than showing the Worlds picker.
2. **Reconnect-and-login on launch** when the token says so — reuse the autologin
   path; show a brief "Reconnecting after update…" banner.
3. **Restore scrollback** into the output view on launch (we persist it; wire the
   restore on a resume launch) so the screen isn't empty.
4. **Consent / safety (mid-combat guard):** never force a relaunch-reconnect out
   from under someone mid-combat. Default to Sparkle's **"install on quit"**
   (deferred) — the safest copyover is "update applies next time you quit
   anyway." Offer **"Update now (briefly reconnects)"** only when the character is
   in a safe state.

   The safe-state check reads Aardwolf's `char.status` GMCP, which carries both a
   numeric **`state`** and a string **`pos`** (verified against live recordings +
   the reference mapper, *not* guessed):

   | field | meaning | source |
   |---|---|---|
   | `state` 8 / `pos` "Fighting" | in combat — **block** | mapper `myState == 8` |
   | `state` 12 | running / speedwalking — **block** | mapper `myState == 12` |
   | `enemy` non-empty + `enemypct` | engaged — **block** | `CharStatus.combatTarget` (already modelled) |
   | `state` 3 / `pos` "Standing" | active, idle — allow | most common live state |
   | `state` 5 | note-mode (writing) — block (don't yank the editor) | aard_note_mode etc. |
   | `pos` "Resting"/"Sitting"/"Sleeping" | at rest — allow | prompt position |

   **Design (robust to unknown `pos` strings): deny-list, not allow-list.** Offer
   "update now" unless `state ∈ {8, 12, 5}` **or** `combatTarget != nil`. That
   blocks the genuinely-unsafe cases (combat, speedwalk, note editor) and allows
   every idle/at-rest position — including a longer capture's `pos` values we
   haven't enumerated yet. Matches the user's "idle or sleep" intent without
   needing the full `pos` vocabulary up front. (`state` values are confirmed from
   live `char.status`; `pos` is advisory/secondary.)

### Recommended phasing

- **Phase 1 — Sparkle, deferred install (no copyover).** Ship the updater with
  **install-on-quit** as the default. This alone closes the #23 release-eng gate:
  users get updates, applied at a natural boundary, with zero session disruption.
  Lowest risk; no new reconnect logic.
- **Phase 2 — seamless "update now."** Add the resume-token + reconnect-on-launch
  + scrollback-restore path for users who choose to update immediately. Builds on
  Phase 1 and the existing reconnect/autologin/persistence stack.

This sequencing means **the 1.0 updater gate is met by Phase 1**; Phase 2 is the
polish that delivers the "copyover feel."

---

## Decisions (resolved with the user)

1. **Appcast hosting → own domain `proteles.net`, fronted by GitHub Pages
   initially.** The Sparkle feed URL (`SUFeedURL` in `Info.plist`) is baked into
   every shipped binary and is **effectively immutable** — it can't be changed for
   copies already installed in the wild. So the feed URL must be the most durable
   address we'll ever control: **`https://proteles.net/appcast.xml`**, a domain we
   own — *not* `rodarvus.github.io` (which would chain the update channel to GitHub
   forever or strand installed clients on a move).

   Hosting and URL are **decoupled**, which lets us ship before the full site
   exists:
   - **Register `proteles.net` before the first Sparkle build** so the baked URL is
     final.
   - **Initially** serve the appcast via **GitHub Pages with a custom domain**
     (`CNAME` → proteles.net). `release.sh` runs `generate_appcast` and publishes
     to the Pages branch.
   - **Later** move the appcast to the real proteles.net server with **zero client
     impact** — the URL never changed.
   - **Download (`enclosure`) URLs are per-appcast-item, not baked in** — so the
     `.zip` can stay on GitHub Releases (free CDN bandwidth) and migrate to
     proteles.net independently, whenever.

   **Interim (now → pre-1.0):** `proteles.net` isn't registered yet and there is
   currently a **single user** (the author), so the "immutable URL" risk is moot —
   there's no installed base to strand. Ship Phase 1 now against a **GitHub feed
   URL** (`https://rodarvus.github.io/proteles/appcast.xml` via GitHub Pages), with
   a **disclaimer in the release notes** that auto-update is interim/GitHub-hosted
   and will move to `proteles.net`. **Before 1.0:** register `proteles.net`, repoint
   `SUFeedURL` (the author re-downloads once — the only client), confirm end-to-end,
   and only then widen distribution. Migration checklist lives in §"Before 1.0".

   The **EdDSA signing key is the same "decide once" forever decision** — its
   public key is baked into the app and every future update must be signed with the
   matching private key. Generate the keypair once, back it up alongside the notary
   credentials, **never rotate it, never commit it**. Independent of the feed URL,
   so the interim→proteles.net move does not touch it.
2. **Cadence → both.** Background auto-check (opt-in prompt on first launch) **and**
   a manual "Check for Updates…" menu item.
3. **Phasing → prove Phase 1, then Phase 2 fast-follow.** Ship Sparkle with
   install-on-quit first and confirm it works end-to-end; the seamless-reconnect
   copyover follows immediately after. Phase 1 satisfies the 1.0 updater gate.
4. **Mid-combat guard → gate on `char.status` (`state`/`pos`).** Deny-list:
   suppress "update now" when `state ∈ {8 fighting, 12 running, 5 note-mode}` or a
   combat target is set; allow every idle/at-rest position otherwise. See Part 2 §4
   for the verified field table.
