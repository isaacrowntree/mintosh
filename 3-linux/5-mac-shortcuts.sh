#!/usr/bin/env bash
# Run as the normal user (NOT sudo), inside the desktop session, after scripts 3 and 4:
#   bash 5-mac-shortcuts.sh
# Mac keyboard shortcuts everywhere with Toshy (github.com/RedBearAK/toshy): ⌘C/⌘V/⌘X/⌘Z, ⌘Q quit, ⌘W close,
# ⌘Tab switch apps, ⌘Space search, ⌘⇧3/⌘⇧4 screenshots. Swapping Ctrl and ⌘ alone would break ⌘Tab.
# It asks for the password once (sudo) to install packages and the keyboard rules. Restart afterwards.
set -uo pipefail
T="$HOME/.cache/toshy-src"
[ -d "$T" ] || git clone -q --depth 1 https://github.com/RedBearAK/toshy.git "$T"
cd "$T" || exit 1
# --skip-update-check: the system was fully updated by script 1. --admin-capable: this user has sudo.
# (Both are the answers bootstrap.sh normally passes; the installer otherwise stops to ask.)
python3 ./setup_toshy.py install --skip-update-check --admin-capable yes
# Accents the Mac way: ⌥e then e = é, ⌥n then n = ñ, ⌥u then u = ü (Toshy's "Option-key Special Characters",
# U.S. layout; off by default). The tray menu can change it.
python3 - <<'PY'
import os, sqlite3
db = os.path.expanduser("~/.config/toshy/toshy_user_preferences.sqlite")
if os.path.exists(db):
    c = sqlite3.connect(db)
    c.execute("update config_preferences set value='US' where name='optspec_layout'")
    c.commit()
PY
echo
echo "Done. Restart the computer (Toshy changes input permissions), then try ⌘C / ⌘V and ⌘Tab. Toshy's icon in the top bar can pause it."
