#!/usr/bin/env bash
# On THIS Mac: offer temporary SSH + password-free sudo access to a Mint machine on the same network.
#   bash tools/open-access.sh            # leave running; Ctrl+C when the other machine has run the command
# On the Mint machine (Terminal), run the wget line it prints; it asks for that user's password once.
# Undo everything afterwards with: bash tools/close-access.sh user@ip
# Forgotten? It closes itself after 48 hours (HOURS=... to change): keys expire and a timer on the Mint machine
# removes the key, the sudo rule, the tunnel and the firewall opening, and turns SSH off.
# No way in to the Mint machine (phone USB tethering, guest network)? TUNNEL=1 bash tools/open-access.sh
#   makes it hold a reverse tunnel to this Mac instead (needs Remote Login on here). Then use user@mintosh,
#   with this in ~/.ssh/config:  Host mintosh / HostName localhost / Port 2222 / HostKeyAlias mintosh
set -euo pipefail
KEY="${KEY:-$HOME/.ssh/mintosh}"
PORT="${PORT:-8765}"
HOURS="${HOURS:-48}"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C mintosh -f "$KEY"
IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
# Every address of this Mac (Wi-Fi and a USB Ethernet adapter can both be on the network); the firewall lets these in
IPS=$(ifconfig | awk '/inet / && $2 !~ /^127\./ {print $2}' | tr '\n' ' ')
UNTIL=$(date -u -v+"${HOURS}"H +%Y%m%d%H%MZ)   # OpenSSH expiry-time, UTC
UNTIL_LOCAL=$(date -v+"${HOURS}"H "+%Y-%m-%d %H:%M")
TUNNEL="${TUNNEL:-}"
if [ -n "$TUNNEL" ]; then
  nc -z -G 2 127.0.0.1 22 || { echo "Turn on Remote Login (System Settings > General > Sharing) first"; exit 1; }
  TKEY="$KEY-tunnel"
  rm -f "$TKEY" "$TKEY.pub"; ssh-keygen -q -t ed25519 -N "" -C mintosh-tunnel -f "$TKEY"   # new one each time
  # The Mint machine gets this key, so it may only open localhost:2222 here: no shell, no other forwards
  LINE="restrict,expiry-time=\"$UNTIL\",port-forwarding,permitlisten=\"localhost:2222\",permitopen=\"localhost:1\",command=\"/usr/bin/false\" $(cat "$TKEY.pub")"
  mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  sed -i '' '/ mintosh-tunnel$/d' ~/.ssh/authorized_keys
  echo "$LINE" >> ~/.ssh/authorized_keys
  MACHOST=$(cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2)   # the tunnel trusts only this Mac
fi
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
P=$(openssl rand -hex 4)    # hard-to-guess path: the script holds a key
mkdir "$D/$P"
cat > "$D/$P/g" <<EOF
#!/usr/bin/env bash
# Temporary access for setup from $(scutil --get ComputerName 2>/dev/null || hostname), until $UNTIL_LOCAL.
# Undone with tools/close-access.sh, or by itself then.
set -e
K='expiry-time="$UNTIL" $(cat "$KEY.pub")'
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys; sed -i '/ mintosh$/d' ~/.ssh/authorized_keys; echo "\$K" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "Enter the password for \$USER if asked:"
echo "\$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-mintosh-setup >/dev/null
sudo chmod 440 /etc/sudoers.d/99-mintosh-setup
sudo visudo -cf /etc/sudoers.d/99-mintosh-setup
dpkg -s openssh-server >/dev/null 2>&1 || sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
if command -v ufw >/dev/null; then
  for ip in $IPS; do sudo ufw allow from \$ip to any port 22 proto tcp comment mintosh-helper >/dev/null; done
fi
# One clean-up for every way access ends: close-access.sh runs it, and a timer runs it at the deadline
sudo tee /usr/local/sbin/mintosh-close >/dev/null <<'CLOSE'
#!/bin/sh
# mintosh: undo tools/open-access.sh - helper keys, password-free sudo, tunnel, firewall opening, SSH server
for h in /home/*; do
  [ -f "\$h/.ssh/authorized_keys" ] && sed -i '/ mintosh\$/d' "\$h/.ssh/authorized_keys"
  rm -f "\$h/.ssh/mintosh-tunnel" "\$h/.ssh/mintosh-known"
done
systemctl disable --now mintosh-tunnel 2>/dev/null
systemctl disable --now ssh.socket ssh 2>/dev/null
rm -f /etc/sudoers.d/99-mintosh-setup /etc/systemd/system/mintosh-tunnel.service
if command -v ufw >/dev/null; then
  while n=\$(ufw status numbered | grep -m1 mintosh-helper | grep -oP '^\[\s*\K[0-9]+'); do ufw --force delete "\$n" >/dev/null; done
fi
systemctl disable mintosh-close.timer 2>/dev/null
rm -f /etc/systemd/system/mintosh-close.timer /etc/systemd/system/mintosh-close.service
systemctl daemon-reload
CLOSE
sudo chmod 755 /usr/local/sbin/mintosh-close
printf '[Unit]\nDescription=mintosh: close helper access\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/mintosh-close\n' \
  | sudo tee /etc/systemd/system/mintosh-close.service >/dev/null
printf '[Unit]\nDescription=mintosh: close helper access at $UNTIL_LOCAL\n[Timer]\nOnCalendar=$(date -v+"${HOURS}"H "+%Y-%m-%d %H:%M:00")\nPersistent=true\n[Install]\nWantedBy=timers.target\n' \
  | sudo tee /etc/systemd/system/mintosh-close.timer >/dev/null
sudo systemctl daemon-reload; sudo systemctl enable --now mintosh-close.timer
EOF
[ -z "$TUNNEL" ] || cat >> "$D/$P/g" <<EOF
umask 077
cat > ~/.ssh/mintosh-tunnel <<'KEY'
$(cat "$TKEY")
KEY
echo '$IP $MACHOST' > ~/.ssh/mintosh-known
sudo tee /etc/systemd/system/mintosh-tunnel.service >/dev/null <<UNIT
[Unit]
Description=Temporary setup tunnel to $(whoami)@$IP until $UNTIL_LOCAL (tools/close-access.sh removes it)
After=network-online.target ssh.service
Wants=network-online.target
[Service]
User=\$USER
ExecStart=/usr/bin/ssh -N -i \$HOME/.ssh/mintosh-tunnel -o IdentitiesOnly=yes -o UserKnownHostsFile=\$HOME/.ssh/mintosh-known -o StrictHostKeyChecking=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -R 2222:localhost:22 $(whoami)@$IP
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now mintosh-tunnel
EOF
cat >> "$D/$P/g" <<EOF
echo
echo "Done. This computer's address: \$(hostname -I)${TUNNEL:+ (and a tunnel to $IP is running)}"
echo "Access closes by itself at $UNTIL_LOCAL."
EOF
SUM=$(shasum -a 256 "$D/$P/g" | cut -d' ' -f1)
echo "On the Mint machine, open Terminal and run:"
echo
echo "  wget -qO- $IP:$PORT/$P/g|bash"
echo
echo "(or, checking the download first: wget -qO /tmp/g $IP:$PORT/$P/g && echo '$SUM  /tmp/g' | sha256sum -c && bash /tmp/g)"
echo "Access closes by itself at $UNTIL_LOCAL."
cd "$D" && python3 -m http.server "$PORT" --bind 0.0.0.0
