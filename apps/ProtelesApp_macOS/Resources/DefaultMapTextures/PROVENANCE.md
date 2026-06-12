# Default map textures — provenance

Every PNG in this directory is **generated from scratch** by
`scripts/generate-map-textures.swift`: seeded procedural noise
(GameplayKit Perlin/billow/ridged/Voronoi) and arithmetic patterns
(grids, planks, checkerboards) rendered to seamless 128×128 tiles.

- **No external assets**: no photographs, no downloaded textures, no
  third-party files of any provenance. Every pixel is computed.
- **Deterministic**: fixed seeds — re-running the script reproduces this
  set byte-for-byte intent (PNG encoding details aside).
- The filenames match the `areas.texture` values Aardwolf mapper
  databases reference (`grass1.png`, `ocean3.png`, …), so imported and
  community maps pick up backgrounds without configuration. The
  shapes/palettes were tuned by *visual side-by-side comparison* with the
  MUSHclient package's set so areas keep their familiar character; no
  pixels were copied or derived from those (GPLv3) files.
- A same-named file in `~/Documents/Proteles/MapImages/` always
  overrides the bundled default (`MapTextureCache`), same as the
  DefaultSounds pattern.

License: these files are part of Proteles and MIT-licensed with it.
