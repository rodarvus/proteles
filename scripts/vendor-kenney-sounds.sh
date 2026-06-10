#!/bin/bash
# Vendor the bundled default soundpack cues (#10) from Kenney's CC0
# "Interface Sounds" pack (https://kenney.nl/assets/interface-sounds).
#
# Downloads the pack, decodes the curated cues (ogg → PCM wav — AVAudioPlayer
# has no Vorbis decoder), and installs them into the app's
# Resources/DefaultSounds/ named after the MUSHclient soundpack's default wav
# filenames (tell.wav, level_up.wav, …) so the cue player resolves purely by
# filename: the user's ~/Documents/Proteles/Sounds/ copy of a name always
# wins; the bundled file is the out-of-the-box default.
#
# CC0 means redistribution is unrestricted — see Resources/DefaultSounds/
# PROVENANCE.md (kept up to date by hand alongside this script).
#
# Requires: oggdec (brew install vorbis-tools), curl, unzip.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/apps/ProtelesApp_macOS/Resources/DefaultSounds"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The download URL embeds a content hash; resolve it from the asset page so
# the script survives pack re-uploads.
PAGE_URL="https://kenney.nl/assets/interface-sounds"
ZIP_URL=$(curl -sL "$PAGE_URL" \
    | grep -oE "href='https://kenney\.nl/media/pages/assets/interface-sounds/[^']+\.zip'" \
    | head -1 | sed "s/^href='//; s/'$//")
if [ -z "$ZIP_URL" ]; then
    echo "error: could not resolve the Interface Sounds zip URL from $PAGE_URL" >&2
    exit 1
fi

echo "Downloading $ZIP_URL"
curl -sL -o "$WORK/pack.zip" "$ZIP_URL"
unzip -q "$WORK/pack.zip" -d "$WORK/pack"
SRC="$WORK/pack/Audio"

# The curation: MUSHclient default wav name → Kenney cue. Chosen to match
# each event's character (alerts harsh, finds sparkly, channels distinct by
# ear — channels matter most for VI players, who track conversations by
# cue). gquest_declare/gquest_start share global_quest.wav and
# sh_powerup shares level_up.wav, both reference parity (same default file).
# remote_sound has no default in the reference (none.wav) and ships nothing.
MAPPING="
zone_repop:maximize_001
info:tick_001
personal_note:pluck_001
gq_win:glass_005
special_find:glass_006
bonus_item:glass_004
manor_doorbell:bong_001
follow:maximize_002
stop_follow:minimize_002
warfare:error_005
restore:glass_001
global_quest:open_002
aarch_prof:open_004
quest_target_found:select_001
quest_target_killed:drop_001
quest_ready:question_001
quest_start:open_001
quest_complete:confirmation_004
quest_warning:error_001
death:error_008
cp_mob_dead:drop_002
double_end:minimize_001
double_exp:maximize_006
gq_mob_dead:drop_003
channel_off:switch_002
channel_on:switch_001
answer:question_002
auction:scroll_002
rauction:scroll_001
barter:scroll_004
claninfo:tick_002
clantalk:select_002
curse:error_007
debate:back_002
epic:maximize_004
ftalk:select_003
gametalk:toggle_003
gclan:back_001
gossip:toggle_001
gratz:glass_002
gsocial:toggle_002
gtell:select_004
helper:question_004
immtalk:glitch_002
inform:tick_004
level_up:confirmation_001
level_up_sh:confirmation_002
ltalk:select_005
market:scroll_003
music:glass_003
newbie:click_002
nobletalk:select_006
pokerinfo:click_003
question:question_003
quote:scratch_002
racetalk:select_007
rp:scratch_003
say:click_001
scry:glitch_001
spouse:maximize_003
tech:glitch_004
tiertalk:select_008
wangrp:switch_003
tell:pluck_002
yell:error_006
whisper:scratch_001
"

mkdir -p "$DEST"
count=0
for entry in $MAPPING; do
    name="${entry%%:*}"
    cue="${entry##*:}"
    src="$SRC/$cue.ogg"
    if [ ! -f "$src" ]; then
        echo "error: $cue.ogg missing from the pack (mapping for $name)" >&2
        exit 1
    fi
    oggdec --quiet -o "$DEST/$name.wav" "$src"
    count=$((count + 1))
done

echo "Installed $count cues into $DEST"
du -sh "$DEST"
