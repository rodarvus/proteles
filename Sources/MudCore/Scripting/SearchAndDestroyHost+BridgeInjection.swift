import Foundation

/// The `[Proteles bridge]` — the model-publishing block at the top of S&D's
/// `xg_draw_window()` that feeds the native Search & Destroy panel and
/// early-returns past the original MUSHclient miniwindow drawing.
///
/// Injected into the S&D source **at load time** (#53): the bridge reads the
/// script's file-scope locals (`main_target_list`, `current_activity`,
/// `quest_target`, …), so it must compile inside the same chunk — but baking
/// it into the packaged `core.lua` at release time is what let the package
/// ship a stale core beside a current XML (the autonav skew). Load-time
/// injection works on ANY S&D source: our packaged split, the plugin XML's
/// own `<script>` CDATA, or a user's imported copy.
extension SearchAndDestroyHost {
    /// Insert the bridge at the top of `xg_draw_window()`. Idempotent: a
    /// source that already carries the bridge (the pre-#53 packaged core.lua)
    /// is returned untouched, as is one without the anchor (the plugin then
    /// runs un-bridged — its own drawing is harmless, just unseen).
    static func injectingBridge(into source: String) -> String {
        guard !source.contains("[Proteles bridge]") else { return source }
        guard let anchor = source.range(of: "function xg_draw_window()") else { return source }
        // Insert after the anchor's line break. Upstream S&D files are CRLF
        // (Windows), our split core.lua is LF — and Swift folds "\r\n" into
        // ONE Character, so searching for "\n" would MISS a CRLF terminator;
        // `isNewline` matches the whole grapheme either way.
        guard let newline = source[anchor.upperBound...].firstIndex(where: \.isNewline)
        else { return source }
        let insertAt = source.index(after: newline)
        // The trailing newline matters: the body's last line ends in a `--`
        // comment, which would otherwise swallow the function's first
        // original statement.
        return String(source[..<insertAt]) + bridgeBody + "\n" + String(source[insertAt...])
    }

    /// The bridge body, verbatim (indented for the function it lands in).
    static let bridgeBody = """
        -- [Proteles bridge] publish the current model to the native panel. Runs in
        -- core.lua's scope so it can read the display locals (main_target_list,
        -- current_activity, …); the original Window* drawing below is a no-op here.
        if proteles and proteles.publish and json then
            local targets = {}
            if type(main_target_list) == "table" then
                for i, t in ipairs(main_target_list) do
                    local express, current = false, false
                    pcall(function() express = is_express_target(t) and true or false end)
                    pcall(function() current = target_matches_current_target(t, i) and true or false end)
                    targets[#targets + 1] = {
                        index = i,
                        mob = t.mob or t.name,
                        room = t.room_name or t.roomName or t.room,
                        area = t.arid or t.area,
                        location = t.location,
                        link_type = t.link_type,
                        qty = tonumber(t.qty),
                        duplicates = tonumber(t.duplicates),
                        dup_index = tonumber(t.index),
                        unlikely = t.unlikely and true or false,
                        express = express,
                        current = current,
                        dead = (t.is_dead == "yes"),
                    }
                end
            end
            -- [Proteles bridge] quest + global-quest state, read from core.lua's
            -- scope. quest_target.qstat: "0" off-quest/can-request, "1" off/cooldown,
            -- "2" on-quest target alive, "3" on-quest target killed.
            local quest = nil
            if type(quest_target) == "table" and quest_target.qstat then
                quest = {
                    status = quest_target.qstat,
                    mob = quest_target.mob,
                    area = quest_target.arid,
                    area_name = quest_target.areaName,
                    room = quest_target.room,
                    killed = (quest_target.qstat == "3"),
                }
            end
            local ok, encoded = pcall(json.encode, {
                version = current_sd_version,
                activity = current_activity,
                player_on_cp = (player_on_cp == "yes"),
                player_on_gq = (player_on_gq == "yes"),
                target_count = #targets,
                targets = targets,
                quest = quest,
                can_request_quest = (type(quest_target) == "table" and quest_target.qstat == "0") or false,
                gq_id = ((player_on_gq == "yes") and gqid_joined) or nil,
                -- Unix time when a new quest can be requested (set from q.wait/q.timer);
                -- the panel shows the remaining wait while on quest cooldown (qstat 1).
                next_quest_time = next_quest_time,
            })
            if ok and encoded then proteles.publish(encoded) end
            return -- the native panel renders the model; skip the MUSHclient drawing
        end
    """
}
