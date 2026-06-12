// Generates the bundled default map textures (#11 / #6 adjacent): one
// seamless 128x128 PNG per area-texture filename the Aardwolf mapper DB
// references, from seeded noise/patterns ONLY — no external assets, so the
// set carries zero licensing provenance (see DefaultMapTextures/PROVENANCE.md).
//
// Deterministic: fixed seeds, same output every run. Regenerate with
//     swift scripts/generate-map-textures.swift
// from anywhere (output lands next to this script's repo). The user's own
// files in ~/Documents/Proteles/MapImages/ always override these defaults
// (MapTextureCache), mirroring the DefaultSounds pattern (#10).
//
// The shapes/palettes were tuned by side-by-side comparison against the
// MUSHclient package's texture set so areas keep their familiar character —
// comparison only; no pixels were copied or derived from those (GPLv3) files.
import AppKit
import GameplayKit

let size = 128
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // repo root
let outDir = repoRoot
    .appendingPathComponent("apps/ProtelesApp_macOS/Resources/DefaultMapTextures").path
try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true
)

typealias RGB = (r: Double, g: Double, b: Double)
struct Stop { let t: Double; let c: RGB }

func gradient(_ value: Double, _ stops: [Stop]) -> RGB {
    let t = max(0, min(1, (value + 1) / 2))
    var lo = stops.first!, hi = stops.last!
    for s in stops {
        if s.t <= t { lo = s }
        if s.t >= t { hi = s; break }
    }
    let f = hi.t > lo.t ? (t - lo.t) / (hi.t - lo.t) : 0
    return (lo.c.r + (hi.c.r - lo.c.r) * f,
            lo.c.g + (hi.c.g - lo.c.g) * f,
            lo.c.b + (hi.c.b - lo.c.b) * f)
}

enum NoiseKind { case perlin, billow, ridged, voronoi(distance: Bool) }
func makeMap(_ kind: NoiseKind, freq: Double, octaves: Int = 4, seed: Int32) -> GKNoiseMap {
    let source: GKNoiseSource = switch kind {
    case .perlin: GKPerlinNoiseSource(
        frequency: freq, octaveCount: octaves, persistence: 0.5, lacunarity: 2.0, seed: seed
    )
    case .billow: GKBillowNoiseSource(
        frequency: freq, octaveCount: octaves, persistence: 0.55, lacunarity: 2.1, seed: seed
    )
    case .ridged: GKRidgedNoiseSource(
        frequency: freq, octaveCount: octaves, lacunarity: 2.2, seed: seed
    )
    case .voronoi(let distance): GKVoronoiNoiseSource(
        frequency: freq, displacement: 1.0, distanceEnabled: distance, seed: seed
    )
    }
    return GKNoiseMap(
        GKNoise(source), size: vector_double2(1, 1), origin: vector_double2(0, 0),
        sampleCount: vector_int2(Int32(size), Int32(size)), seamless: true
    )
}
func value(_ map: GKNoiseMap, _ x: Int, _ y: Int) -> Double {
    let wx = ((x % size) + size) % size
    let wy = ((y % size) + size) % size
    return Double(map.value(at: vector_int2(Int32(wx), Int32(wy))))
}

/// Deterministic per-cell tone hash (tiles/planks/bricks).
func cellHash(_ a: Int, _ b: Int, _ seed: Int) -> Double {
    var h = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ seed &* 83_492_791))
    h = (h ^ (h >> 33)) &* 0xFF51_AFD7_ED55_8CCD
    h = (h ^ (h >> 33)) &* 0xC4CE_B9FE_1A85_EC53
    return Double(h % 1000) / 1000.0
}

func writePNG(_ name: String, _ pixel: (Int, Int) -> RGB) {
    var data = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let c = pixel(x, y)
            let i = (y * size + x) * 4
            data[i] = UInt8(max(0, min(255, c.r * 255)))
            data[i + 1] = UInt8(max(0, min(255, c.g * 255)))
            data[i + 2] = UInt8(max(0, min(255, c.b * 255)))
        }
    }
    let provider = CGDataProvider(data: Data(data) as CFData)!
    let image = CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

// MARK: - Materials

func mottle(_ kind: NoiseKind, freq: Double, octaves: Int = 4, seed: Int32, _ stops: [Stop])
    -> (Int, Int) -> RGB {
    let map = makeMap(kind, freq: freq, octaves: octaves, seed: seed)
    return { x, y in gradient(value(map, x, y), stops) }
}

func blend(maskFreq: Double, maskSeed: Int32, threshold: Double, soft: Double = 0.15,
           _ a: @escaping (Int, Int) -> RGB, _ b: @escaping (Int, Int) -> RGB)
    -> (Int, Int) -> RGB {
    let mask = makeMap(.perlin, freq: maskFreq, octaves: 3, seed: maskSeed)
    return { x, y in
        let m = value(mask, x, y)
        if m < threshold - soft { return a(x, y) }
        if m > threshold + soft { return b(x, y) }
        let f = (m - (threshold - soft)) / (2 * soft)
        let ca = a(x, y), cb = b(x, y)
        return (ca.r + (cb.r - ca.r) * f, ca.g + (cb.g - ca.g) * f, ca.b + (cb.b - ca.b) * f)
    }
}

func water(seed: Int32, _ stops: [Stop], foamCutoff: Double, foam: RGB) -> (Int, Int) -> RGB {
    let swell = makeMap(.perlin, freq: 6, octaves: 4, seed: seed)
    let flecks = makeMap(.ridged, freq: 18, octaves: 3, seed: seed &+ 1)
    return { x, y in
        let base = gradient(value(swell, x, y), stops)
        return value(flecks, x, y) > foamCutoff ? foam : base
    }
}

/// Voronoi cells: per-cell tone from `tone` map, shaded by distance map —
/// `centerBright` lifts cell centers (pebbles) instead of just darkening edges.
func pebbles(freq: Double, seed: Int32, _ stops: [Stop], gap: RGB,
             gapWidth: Double = 0.20, centerBright: Double = 0.35) -> (Int, Int) -> RGB {
    let tone = makeMap(.voronoi(distance: false), freq: freq, seed: seed)
    let dist = makeMap(.voronoi(distance: true), freq: freq, seed: seed)
    let grain = makeMap(.perlin, freq: 30, octaves: 2, seed: seed &+ 1)
    return { x, y in
        // distance map: -1 at seed points rising toward cell borders.
        let d = (value(dist, x, y) + 1) / 2 // 0 center … 1 border
        if d > 1 - gapWidth { return gap }
        var c = gradient(value(tone, x, y), stops)
        let lift = 1 + centerBright * (1 - d / (1 - gapWidth)) // bright center → dim rim
        let g = value(grain, x, y) * 0.05
        c = (c.r * lift + g, c.g * lift + g, c.b * lift + g)
        return c
    }
}

/// Rectangular tiles/bricks: per-cell tone, dark grout, optional row offset.
func bricks(w: Int, h: Int, offset: Bool, seed: Int, _ stops: [Stop],
            grout: Double = 0.35, groutWidth: Int = 2) -> (Int, Int) -> RGB {
    let grain = makeMap(.perlin, freq: 26, octaves: 2, seed: Int32(seed))
    return { x, y in
        let row = y / h
        let shifted = offset ? (x + (row % 2) * w / 2) % size : x
        let col = shifted / w
        let inGrout = (shifted % w) < groutWidth || (y % h) < groutWidth
        let tone = cellHash(col, row, seed) * 2 - 1
        var c = gradient(tone, stops)
        let g = value(grain, x, y) * 0.05
        c = (c.r + g, c.g + g, c.b + g)
        return inGrout ? (c.r * grout, c.g * grout, c.b * grout) : c
    }
}

/// Irregular masonry: rows of hash-jittered variable-width blocks, per-block
/// tone, dark joints, optional moss tint creeping over the stone.
func masonry(rowHeight: Int, nominalWidth: Int, seed: Int, _ stops: [Stop],
             joint: Double = 0.30, moss: RGB? = nil) -> (Int, Int) -> RGB {
    let rows = size / rowHeight
    var rowCuts: [[Int]] = []
    for r in 0..<rows {
        var cuts: [Int] = []
        var cursor = -Int(cellHash(r, 13, seed) * Double(nominalWidth)) // row phase
        var i = 0
        while cursor < size {
            let jitterWidth = Double(nominalWidth) * 0.7
            let w = nominalWidth + Int((cellHash(r, i, seed) - 0.5) * jitterWidth)
            cursor += max(8, w)
            if cursor > 0, cursor < size { cuts.append(cursor) }
            i += 1
        }
        rowCuts.append(cuts)
    }
    let grain = makeMap(.perlin, freq: 28, octaves: 3, seed: Int32(seed))
    let mossMap = makeMap(.billow, freq: 14, octaves: 3, seed: Int32(seed) &+ 5)
    return { x, y in
        let r = y / rowHeight
        let cuts = rowCuts[min(r, rowCuts.count - 1)]
        var block = 0
        var inJoint = (y % rowHeight) < 2 || x < 2 // tile seam doubles as a joint
        for cut in cuts {
            if x >= cut { block += 1 }
            if x - cut >= 0, x - cut < 2 { inJoint = true }
        }
        let tone = cellHash(r, block, seed &+ 99) * 2 - 1
        var c = gradient(tone, stops)
        let g = value(grain, x, y) * 0.08
        c = (c.r + g, c.g + g, c.b + g)
        if let moss {
            let m = value(mossMap, x, y)
            if m > 0.3 {
                let f = min(1.0, (m - 0.3) * 1.6) * 0.45
                c = (c.r + (moss.r - c.r) * f, c.g + (moss.g - c.g) * f,
                     c.b + (moss.b - c.b) * f)
            }
        }
        return inJoint ? (c.r * joint, c.g * joint, c.b * joint) : c
    }
}

/// Bevelled square tiles: per-tile tone + grunge, light top/left edge,
/// shadowed bottom/right edge (the worn dungeon-floor look).
func bevelTiles(tile t: Int, seed: Int, _ stops: [Stop], grout: Double = 0.25)
    -> (Int, Int) -> RGB {
    let grunge = makeMap(.billow, freq: 18, octaves: 3, seed: Int32(seed))
    return { x, y in
        let lx = x % t, ly = y % t
        let tone = cellHash(x / t, y / t, seed) * 2 - 1
        var c = gradient(tone, stops)
        let g = value(grunge, x, y) * 0.10
        c = (c.r + g, c.g + g * 0.9, c.b + g * 0.7)
        if lx < 1 || ly < 1 { return (c.r * grout, c.g * grout, c.b * grout) }
        if lx < 3 || ly < 3 { return (c.r * 1.3, c.g * 1.3, c.b * 1.3) }
        if lx >= t - 2 || ly >= t - 2 { return (c.r * 0.55, c.g * 0.55, c.b * 0.55) }
        return c
    }
}

/// Vertical planks: per-plank tone + stretched vertical grain.
func planks(width: Int, seed: Int, _ stops: [Stop]) -> (Int, Int) -> RGB {
    let grain = makeMap(.perlin, freq: 40, octaves: 3, seed: Int32(seed))
    return { x, y in
        let plank = x / width
        let tone = cellHash(plank, 0, seed) * 2 - 1
        var c = gradient(tone, stops)
        let g = value(grain, x * 3, y) * 0.10
        c = (c.r + g, c.g + g * 0.8, c.b + g * 0.6)
        if x % width < 1 { c = (c.r * 0.5, c.g * 0.5, c.b * 0.5) }
        return c
    }
}

func checker(square: Int, seed: Int, _ a: RGB, _ b: RGB) -> (Int, Int) -> RGB {
    let grain = makeMap(.perlin, freq: 30, octaves: 2, seed: Int32(seed))
    return { x, y in
        let base = ((x / square + y / square) % 2 == 0) ? a : b
        let g = value(grain, x, y) * 0.05
        return (base.r + g, base.g + g, base.b + g)
    }
}

func starfield(seed: UInt64, count: Int, _ stops: [Stop]) -> (Int, Int) -> RGB {
    let wash = makeMap(.perlin, freq: 4, octaves: 3, seed: Int32(truncatingIfNeeded: Int(seed)))
    let rng = GKMersenneTwisterRandomSource(seed: seed)
    var stars: [Int: Double] = [:]
    for _ in 0..<count {
        let x = rng.nextInt(upperBound: size), y = rng.nextInt(upperBound: size)
        stars[y * size + x] = 0.55 + Double(rng.nextUniform()) * 0.45
    }
    return { x, y in
        if let b = stars[y * size + x] { return (b, b, 1.0) }
        return gradient(value(wash, x, y), stops)
    }
}

func st(_ t: Double, _ r: Double, _ g: Double, _ b: Double) -> Stop {
    Stop(t: t, c: (r, g, b))
}

// MARK: - The set

let grassStops: (Double, Int32) -> (Int, Int) -> RGB = { brightness, seed in
    mottle(.billow, freq: 14, octaves: 5, seed: seed, [
        st(0.0, 0.05 * brightness, 0.13 * brightness, 0.04 * brightness),
        st(0.5, 0.10 * brightness, 0.24 * brightness, 0.07 * brightness),
        st(1.0, 0.20 * brightness, 0.38 * brightness, 0.13 * brightness)
    ])
}

var spec: [String: (Int, Int) -> RGB] = [:]

// — unchanged from v1 (already close) —
spec["grass1"] = grassStops(1.0, 7)
spec["grass2"] = grassStops(1.5, 8)
spec["grass3"] = mottle(.billow, freq: 14, octaves: 5, seed: 9, [
    st(0.0, 0.03, 0.14, 0.10), st(0.5, 0.06, 0.22, 0.15), st(1.0, 0.12, 0.32, 0.22)
])
spec["grass4"] = mottle(.billow, freq: 14, octaves: 5, seed: 10, [
    st(0.0, 0.08, 0.12, 0.03), st(0.5, 0.14, 0.22, 0.05), st(1.0, 0.22, 0.32, 0.08)
])
spec["forest"] = mottle(.billow, freq: 18, octaves: 5, seed: 11, [
    st(0.0, 0.01, 0.06, 0.02), st(0.5, 0.04, 0.14, 0.04), st(1.0, 0.09, 0.24, 0.08)
])
spec["forest3"] = mottle(.billow, freq: 13, octaves: 5, seed: 12, [
    st(0.0, 0.04, 0.12, 0.03), st(0.5, 0.10, 0.26, 0.08), st(1.0, 0.20, 0.42, 0.14)
])
spec["dirt"] = mottle(.billow, freq: 16, octaves: 4, seed: 13, [
    st(0.0, 0.32, 0.23, 0.14), st(0.5, 0.46, 0.34, 0.22), st(1.0, 0.62, 0.48, 0.33)
])
spec["dirt2"] = mottle(.perlin, freq: 10, octaves: 4, seed: 14, [
    st(0.0, 0.34, 0.18, 0.06), st(0.5, 0.46, 0.26, 0.10), st(1.0, 0.58, 0.34, 0.14)
])
spec["sand"] = mottle(.perlin, freq: 22, octaves: 3, seed: 18, [
    st(0.0, 0.50, 0.42, 0.24), st(0.5, 0.58, 0.50, 0.30), st(1.0, 0.66, 0.57, 0.36)
])
spec["snow"] = mottle(.perlin, freq: 8, octaves: 3, seed: 19, [
    st(0.0, 0.80, 0.82, 0.84), st(1.0, 0.95, 0.96, 0.97)
])
spec["snow2"] = mottle(.perlin, freq: 8, octaves: 3, seed: 20, [
    st(0.0, 0.84, 0.88, 0.95), st(1.0, 0.97, 0.98, 1.00)
])
spec["cloud"] = mottle(.perlin, freq: 3, octaves: 4, seed: 21, [
    st(0.0, 0.48, 0.58, 0.80), st(0.5, 0.70, 0.78, 0.92), st(1.0, 0.94, 0.96, 1.00)
])
spec["ocean1"] = water(seed: 22, [
    st(0.0, 0.04, 0.10, 0.45), st(0.6, 0.08, 0.16, 0.60), st(1.0, 0.12, 0.24, 0.72)
], foamCutoff: 0.82, foam: (0.75, 0.85, 1.0))
spec["ocean2"] = water(seed: 23, [
    st(0.0, 0.40, 0.55, 0.80), st(1.0, 0.65, 0.78, 0.93)
], foamCutoff: 0.78, foam: (0.92, 0.96, 1.0))
spec["ocean3"] = mottle(.perlin, freq: 6, octaves: 4, seed: 24, [
    st(0.0, 0.04, 0.08, 0.52), st(1.0, 0.10, 0.16, 0.70)
])
spec["ocean4"] = water(seed: 25, [
    st(0.0, 0.02, 0.04, 0.22), st(1.0, 0.06, 0.10, 0.38)
], foamCutoff: 0.90, foam: (0.45, 0.55, 0.80))
spec["gelidus"] = blend(
    maskFreq: 7, maskSeed: 26, threshold: 0.35, soft: 0.1,
    mottle(.perlin, freq: 8, octaves: 3, seed: 27, [
        st(0.0, 0.55, 0.70, 0.85), st(1.0, 0.80, 0.90, 0.98)
    ]),
    mottle(.ridged, freq: 10, octaves: 3, seed: 28, [
        st(0.0, 0.45, 0.62, 0.80), st(1.0, 0.70, 0.84, 0.95)
    ])
)
spec["space2"] = starfield(seed: 29, count: 70, [
    st(0.0, 0.02, 0.01, 0.06), st(1.0, 0.07, 0.04, 0.14)
])
spec["darkrock"] = mottle(.ridged, freq: 12, octaves: 4, seed: 34, [
    st(0.0, 0.02, 0.02, 0.02), st(0.6, 0.10, 0.10, 0.11), st(1.0, 0.26, 0.26, 0.28)
])
spec["darkstone"] = mottle(.perlin, freq: 38, octaves: 2, seed: 35, [
    st(0.0, 0.03, 0.03, 0.04), st(1.0, 0.12, 0.12, 0.14)
])
spec["rocky"] = mottle(.billow, freq: 16, octaves: 4, seed: 36, [
    st(0.0, 0.08, 0.06, 0.03), st(0.5, 0.17, 0.12, 0.07), st(1.0, 0.28, 0.21, 0.12)
])
spec["rocky2"] = mottle(.billow, freq: 12, octaves: 4, seed: 37, [
    st(0.0, 0.13, 0.11, 0.09), st(0.5, 0.24, 0.21, 0.17), st(1.0, 0.38, 0.33, 0.27)
])
spec["test3"] = mottle(.perlin, freq: 20, octaves: 3, seed: 38, [
    st(0.0, 0.02, 0.02, 0.03), st(1.0, 0.10, 0.10, 0.12)
])
// test5 is the mapper's room-level DEFAULT (every area without a texture
// name renders this) — soft charcoal felt, very low contrast.
spec["test5"] = mottle(.billow, freq: 12, octaves: 4, seed: 55, [
    st(0.0, 0.07, 0.07, 0.075), st(0.6, 0.10, 0.10, 0.105), st(1.0, 0.14, 0.14, 0.15)
])
spec["wood1"] = planks(width: 16, seed: 52, [
    st(0.0, 0.26, 0.13, 0.07), st(1.0, 0.42, 0.22, 0.12)
])
spec["chess1"] = checker(square: 16, seed: 53, (0.66, 0.15, 0.13), (0.84, 0.80, 0.76))

// — v2 iterations —

// dirtgrass: drab, grass-dominant, small red-brown patches (the original is
// muted olive with rust flecks, not bright leaf-green).
spec["dirtgrass"] = blend(
    maskFreq: 9, maskSeed: 15, threshold: 0.25, soft: 0.2,
    mottle(.billow, freq: 16, octaves: 5, seed: 16, [
        st(0.0, 0.07, 0.11, 0.03), st(0.5, 0.12, 0.19, 0.06), st(1.0, 0.20, 0.28, 0.10)
    ]),
    mottle(.billow, freq: 16, octaves: 4, seed: 17, [
        st(0.0, 0.20, 0.08, 0.04), st(1.0, 0.38, 0.16, 0.08)
    ])
)

// sparse: fine olive scrub + orange ground, ~50/50, higher detail frequency.
spec["sparse"] = blend(
    maskFreq: 8, maskSeed: 42, threshold: 0.0, soft: 0.12,
    mottle(.billow, freq: 20, octaves: 5, seed: 43, [
        st(0.0, 0.06, 0.12, 0.02), st(0.5, 0.12, 0.22, 0.05), st(1.0, 0.20, 0.32, 0.08)
    ]),
    mottle(.billow, freq: 20, octaves: 5, seed: 44, [
        st(0.0, 0.30, 0.15, 0.02), st(0.5, 0.48, 0.26, 0.04), st(1.0, 0.66, 0.40, 0.08)
    ])
)

// fire1: dense glowing coals — no black cracks, saturated red throughout.
spec["fire1"] = mottle(.billow, freq: 20, octaves: 5, seed: 30, [
    st(0.0, 0.25, 0.01, 0.00), st(0.4, 0.45, 0.04, 0.01),
    st(0.7, 0.70, 0.12, 0.01), st(0.9, 0.90, 0.28, 0.02), st(1.0, 1.00, 0.50, 0.06)
])

// hell: big red flagstones, glowing-ember joints, per-cell red tone + grain.
spec["hell"] = {
    let tone = makeMap(.voronoi(distance: false), freq: 6, seed: 31)
    let dist = makeMap(.voronoi(distance: true), freq: 6, seed: 31)
    let grain = makeMap(.billow, freq: 22, octaves: 3, seed: 32)
    return { x, y in
        let d = (value(dist, x, y) + 1) / 2
        if d > 0.82 { return (0.16, 0.05, 0.02) } // dark ember joint
        var c = gradient(value(tone, x, y), [
            st(0.0, 0.30, 0.06, 0.04), st(0.5, 0.42, 0.09, 0.05), st(1.0, 0.55, 0.13, 0.06)
        ])
        let g = value(grain, x, y) * 0.10
        c = (c.r + g, c.g + g * 0.4, c.b + g * 0.3)
        if d > 0.72 { c = (c.r * 0.7, c.g * 0.7, c.b * 0.7) } // rim shade into joint
        return c
    }
}()

// stone: near-black blue-grey fine grain (the original is almost uniform).
spec["stone"] = mottle(.perlin, freq: 30, octaves: 3, seed: 32, [
    st(0.0, 0.03, 0.03, 0.06), st(0.7, 0.06, 0.07, 0.11), st(1.0, 0.12, 0.13, 0.18)
])

// stones: distinct dark pebbles, lit centers, near-black gaps.
spec["stones"] = pebbles(freq: 14, seed: 33, [
    st(0.0, 0.10, 0.09, 0.09), st(0.5, 0.16, 0.15, 0.15), st(1.0, 0.24, 0.22, 0.22)
], gap: (0.02, 0.02, 0.02), gapWidth: 0.18, centerBright: 0.45)

// test4: pebble mosaic — grey-blue stones and olive-gold ground cells.
spec["test4"] = {
    let tone = makeMap(.voronoi(distance: false), freq: 16, seed: 39)
    let dist = makeMap(.voronoi(distance: true), freq: 16, seed: 39)
    let grain = makeMap(.perlin, freq: 30, octaves: 2, seed: 40)
    return { x, y in
        let d = (value(dist, x, y) + 1) / 2
        if d > 0.85 { return (0.06, 0.05, 0.03) }
        let t = (value(tone, x, y) + 1) / 2
        let g = value(grain, x, y) * 0.06
        let lift = 1 + 0.25 * (1 - d / 0.85)
        var c: RGB = t > 0.55
            ? (0.26, 0.27, 0.31) // grey-blue stone
            : (0.32, 0.24, 0.08) // olive-gold ground
        let v = (t > 0.55 ? (t - 0.55) : t) * 0.3
        c = ((c.r + v + g) * lift, (c.g + v + g) * lift, (c.b + v * 0.8 + g) * lift)
        return c
    }
}()

// temple: carved near-black blocks — pale ornament speckle inside each block.
spec["temple"] = {
    let carve = makeMap(.ridged, freq: 24, octaves: 3, seed: 61)
    let block = 32
    return { x, y in
        let lx = x % block, ly = y % block
        if lx < 2 || ly < 2 { return (0.01, 0.01, 0.012) } // deep grout
        let toneShift = cellHash(x / block, y / block, 61) * 0.03
        let base: RGB = (0.045 + toneShift, 0.045 + toneShift, 0.05 + toneShift)
        let edgeDistance = min(min(lx, ly), min(block - lx, block - ly))
        let v = value(carve, x, y)
        if v > 0.40, edgeDistance > 2 { // pale carving, fading at block rims
            let b = min(0.75, 0.30 + (v - 0.40) * 0.9)
            return (b, b, b * 1.02)
        }
        return base
    }
}()

// test: irregular mossy masonry — jittered block widths, green-grey tint.
spec["test"] = masonry(
    rowHeight: 16, nominalWidth: 26, seed: 48, [
        st(0.0, 0.20, 0.21, 0.19), st(0.5, 0.28, 0.29, 0.27), st(1.0, 0.38, 0.39, 0.36)
    ], joint: 0.30, moss: (0.16, 0.26, 0.14)
)

// tile1: big worn bevelled tiles, brown-gold, grungy.
spec["tile1"] = bevelTiles(tile: 32, seed: 49, [
    st(0.0, 0.26, 0.19, 0.08), st(0.5, 0.36, 0.27, 0.12), st(1.0, 0.48, 0.37, 0.18)
])

// tile2: not a grid at all — near-black teal wash with horizontal smear.
spec["tile2"] = {
    let wash = makeMap(.perlin, freq: 7, octaves: 4, seed: 50)
    return { x, y in
        gradient(value(wash, x, y * 3), [
            st(0.0, 0.01, 0.05, 0.06), st(0.6, 0.04, 0.11, 0.12),
            st(0.9, 0.07, 0.17, 0.18), st(1.0, 0.10, 0.24, 0.25)
        ])
    }
}()

// wood: wavy vertical bark grain — thin bright streaks on near-black.
spec["wood"] = {
    let streak = makeMap(.perlin, freq: 10, octaves: 4, seed: 51)
    let wave = makeMap(.perlin, freq: 3, octaves: 2, seed: 54)
    return { x, y in
        let offset = Int((value(wave, x, y) * 2.5).rounded())
        let v = value(streak, (x + offset) * 9, y)
        return gradient(v, [
            st(0.0, 0.06, 0.04, 0.01), st(0.55, 0.16, 0.10, 0.03),
            st(0.8, 0.38, 0.26, 0.07), st(1.0, 0.60, 0.42, 0.12)
        ])
    }
}()

for (name, pixel) in spec.sorted(by: { $0.key < $1.key }) {
    writePNG(name, pixel)
}
print("\(spec.count) textures generated → \(outDir)")
