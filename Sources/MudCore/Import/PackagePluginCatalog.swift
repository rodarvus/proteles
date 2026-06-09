import Foundation

/// The plugin set shipped in **aardwolfclientpackage** — the standard Aardwolf
/// MUSHclient package. Proteles provides this functionality itself, so the
/// importer SKIPS these (by plugin id or filename) and offers the rest. Baked
/// snapshot (regenerated from the `aardwolfclientpackage/` submodule); ids are
/// the actual `<plugin id>` attribute (not the first id in the file — plugins
/// reference other plugins' ids via CallPlugin). Matched by id OR filename.
public enum PackagePluginCatalog {
    /// 24-hex `<plugin id>` values shipped in the package.
    public static let ids: Set<String> = [
        "04d9e64f835452b045b427a7",
        "0cbb10309587f0ee15ba78ce",
        "0f4ddde78206d78b41bb365b",
        "0f66211eb132e555af92697f",
        "162bba4a5ecef2bb32b5652f",
        "1b55534e1fa021cf093aaa6d",
        "23832d1089f727f5f34abad8",
        "3e7dedbe37e44942dd46d264",
        "3f498d929793c12cb70fb59e",
        "402d5b187f593a46bc68beb9",
        "462b665ecb569efbf261422f",
        "463242566069ebfd1b379ec1",
        "48f867c18f6ff1d6d3b52918",
        "50f4e1fc89999ce02a216a3c",
        "520bc4f29806f7af0017985f",
        "55616ea13339bc68e963e1f8",
        "6000a4c6f0e71d31fecf523d",
        "60840c9013c7cc57777ae0ac",
        "60ad15b3cb2a5757d2611c28",
        "636a1df5adb9fb54adb38d8b",
        "74524d1272786aaf04e9487d",
        "87a0ec3649ab9a04d5ea618d",
        "9f796334ab9ed476ef44f1dc",
        "9f796334ab9ed476ef44f1dd",
        "a1965272c8ca966b76f36fa3",
        "abc1a0944ae4af7586ce88dc",
        "b14162092957e88ec16d99e7",
        "b555825a4a5700c35fa80780",
        "b6eae87ccedd84f510b74714",
        "b9315e040989d3f81f4328d6",
        "bb6a05ed7534b5db1ed40511",
        "c293f9e7f04dde889f65cb90",
        "d2fa45d390d935d947cdc169",
        "d7b7347aefd339a96abb78b0",
        "e50b1d08a0cfc0ee9c44947b",
        "edb75e5e80221bfb1a83a234",
        "ef4a86dbc9cd4dd6f4c69385",
        "ef4a86dbc9cd4dd6f4c69386",
        "f178e68512c685b3be1e9b07",
        "f2194205952c5eefa4f380b8",
        "f553c80154d48ea139b1d192",
        "fefc7923b4db9e0ee3add286"
    ]

    /// Plugin filenames (lowercased) shipped in the package.
    public static let filenames: Set<String> = [
        "aard_ascii_map.xml",
        "aard_channels_fiendish.xml",
        "aard_chat_echo.xml",
        "aard_command_tag_handler.xml",
        "aard_copy_colour_codes.xml",
        "aard_gmcp_handler.xml",
        "aard_gmcp_mapper.xml",
        "aard_group_monitor_gmcp.xml",
        "aard_health_bars_gmcp.xml",
        "aard_help.xml",
        "aard_ingame_help_window.xml",
        "aard_inventory_serials.xml",
        "aard_keyboard_lockout.xml",
        "aard_layout.xml",
        "aard_miniwindow_z_order_monitor.xml",
        "aard_new_connection.xml",
        "aard_new_connection_no_ui.xml",
        "aard_note_mode.xml",
        "aard_package_update_checker.xml",
        "aard_prompt_fixer.xml",
        "aard_repaint_buffer.xml",
        "aard_requirements.xml",
        "aard_soundpack.xml",
        "aard_splitscreen_scrollback.xml",
        "aard_statmon_gmcp.xml",
        "aard_text_substitution.xml",
        "aard_theme_controller.xml",
        "aard_translate_foreign_friends.xml",
        "aard_vi_command_output.xml",
        "aard_vi_review_buffers.xml",
        "aard_vital_shortcuts.xml",
        "aardwolf_bigmap_graphical.xml",
        "aardwolf_tick_timer.xml",
        "automatic_backup.xml",
        "config_option_changer.xml",
        "hyperlink_url2.xml",
        "mushclient_help.xml",
        "omit_blank_lines.xml",
        "plugin_list.xml",
        "plugin_summary.xml",
        "sapi.xml",
        "time.xml",
        "universal_text_to_speech.xml"
    ]

    /// Whether an enabled plugin (by id and/or filename) belongs to the package.
    public static func contains(id: String?, filename: String) -> Bool {
        if let id, ids.contains(id.lowercased()) { return true }
        return filenames.contains(filename.lowercased())
    }
}
