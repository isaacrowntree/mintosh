#!/usr/bin/env bash
# Run on the new Mint install as the normal user (NOT sudo):
#   bash 2-restore-files.sh
# Expects the reorganised, de-duplicated copy next to this folder: ../organized/{Desktop,Documents,Pictures,Music,Videos}
# (made by 2-organize/organize.py). Copies it into the user's folders; existing files are never overwritten.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(dirname "$HERE")/organized"
[ -d "$SRC/Documents" ] || { echo "Missing $SRC"; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
bad=""

for pair in "Desktop DESKTOP" "Documents DOCUMENTS" "Pictures PICTURES" "Music MUSIC" "Videos VIDEOS"; do
  set -- $pair
  dest="$(xdg-user-dir "$2")"
  log "$1 -> $dest"
  rsync -a --ignore-existing "$SRC/$1/" "$dest/" || { echo "!! COPY FAILED for $1 - keep ~/mac-setup, fix and re-run"; bad=1; }
done

log "Make sure accented names are in Linux form (NFC)"
for d in DESKTOP DOCUMENTS PICTURES MUSIC VIDEOS; do
  convmv -r -f utf8 -t utf8 --nfc --notest "$(xdg-user-dir $d)" >/dev/null 2>&1 || true
done

log "Summary"
for d in DESKTOP DOCUMENTS PICTURES MUSIC VIDEOS; do
  p="$(xdg-user-dir $d)"; printf '%8s files  %6s  %s\n' "$(find "$p" -type f | wc -l)" "$(du -sh "$p" | cut -f1)" "$p"
done
log "Check: every file in the copy is now in the home folder, same size"
# Names are compared after the NFC step above (Mac copies may still be NFD), so normalise both sides
missing=$(cd "$SRC" && find Desktop Documents Pictures Music Videos -type f -printf '%s %p\n' 2>/dev/null | python3 -c '
import os, sys, unicodedata
dirs = {d: os.popen(f"xdg-user-dir {d.upper()}").read().strip() for d in ("Desktop","Documents","Pictures","Music","Videos")}
n = 0
for line in sys.stdin:
    size, rel = line.rstrip("\n").split(" ", 1)
    top, _, rest = rel.partition("/")
    p = os.path.join(dirs[top], unicodedata.normalize("NFC", rest))
    if not os.path.exists(p) or os.path.getsize(p) != int(size):
        n += 1
        if n <= 20: print("   missing or different:", p, file=sys.stderr)
print(n)')
if [ -z "$bad" ] && [ "$missing" = 0 ]; then
  echo "   All files are in place. ~/mac-setup can be deleted (keep another copy first: it is the only other one)."
else
  echo "!! $missing file(s) missing or different - do NOT delete ~/mac-setup"; bad=1
fi

echo
echo "Next by hand: open Chrome and sign in to the Google account (bookmarks/passwords sync back)."
echo "Old Safari bookmarks: Chrome > Bookmarks > Import > Documents/From the Mac/safari-bookmarks.html (if converted)"
[ -z "$bad" ]
