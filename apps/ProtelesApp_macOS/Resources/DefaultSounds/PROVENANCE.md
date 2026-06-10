# DefaultSounds — provenance

The bundled soundpack cues (issue #10). **Every audio file in this folder
derives from a single CC0 source** and is redistributable without
restriction:

- **Source pack:** *Interface Sounds* by Kenney — <https://kenney.nl/assets/interface-sounds>
- **License:** Creative Commons Zero (CC0 1.0 Universal) —
  <https://creativecommons.org/publicdomain/zero/1.0/>, as stated by the
  pack's own `License.txt` ("This content is free to use in personal,
  educational and commercial projects"). Credit is appreciated but not
  required; we credit Kenney here and in the app's acknowledgements.
- **Transformation:** decoded from the pack's Ogg Vorbis files to PCM WAV
  (`oggdec`) — `AVAudioPlayer` has no Vorbis decoder — and renamed to the
  MUSHclient soundpack's default cue filenames (`tell.wav`, `level_up.wav`,
  …) so file-name resolution works unchanged for migrating users.
- **Regenerating:** `scripts/vendor-kenney-sounds.sh` re-downloads the pack
  and rebuilds this folder; the event→cue curation lives in that script.

These are the **out-of-the-box defaults only.** A file of the same name in
the user's `~/Documents/Proteles/Sounds/` (their MUSHclient import, or any
manual drop) always takes precedence — the historical Aardwolf soundpack
wavs are **not** in this repo and never will be: they have no provenance or
licensing record upstream (see issue #10's analysis).
