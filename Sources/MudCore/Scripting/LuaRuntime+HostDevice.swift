extension LuaRuntime {
    nonisolated static func deviceCaps(_ index: Int) -> Int {
        switch index {
        case 88, 90: 96 // LOGPIXELSX / LOGPIXELSY: MUSHclient's common baseline.
        case 8, 10: 4096 // HORZRES / VERTRES: harmless large defaults for probes.
        default: 0
        }
    }
}
