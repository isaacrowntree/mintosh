#!/usr/bin/env bash
# On THIS Mac: undo tools/open-access.sh on the Mint machine and delete the key here.
#   bash tools/close-access.sh user@ip
# A few seconds later (from a systemd unit, so this SSH session isn't cut off half-way) the Mint machine removes the
# helper keys, the password-free sudo rule, the TUNNEL=1 tunnel and the firewall opening, and turns SSH off.
# Through the tunnel: bash tools/close-access.sh user@mintosh
set -euo pipefail
DEST="${1:?usage: $0 user@ip}"
KEY="${KEY:-$HOME/.ssh/mintosh}"
ssh -o IdentitiesOnly=yes -i "$KEY" "$DEST" '
  if [ -x /usr/local/sbin/mintosh-close ]; then
    sudo systemd-run --on-active=5 --unit=close-access-$(date +%s) /usr/local/sbin/mintosh-close
  else   # access opened by an older open-access.sh
    sed -i "/ mintosh\$/d" ~/.ssh/authorized_keys; rm -f ~/.ssh/mintosh-tunnel ~/.ssh/mintosh-known
    sudo systemd-run --on-active=5 --unit=close-access-$(date +%s) sh -c "systemctl disable --now mintosh-tunnel; \
      systemctl disable --now ssh.socket ssh; rm -f /etc/sudoers.d/99-mintosh-setup /etc/systemd/system/mintosh-tunnel.service; \
      systemctl daemon-reload"
  fi
  echo "Access removed on the Mint machine."'
sleep 10
if [ "${DEST#*@}" = mintosh ]; then
  if nc -z -G 3 127.0.0.1 2222 2>/dev/null; then echo "!! The tunnel is still open"; else echo "Tunnel is closed."; fi
elif nc -z -G 3 "${DEST#*@}" 22 2>/dev/null; then echo "!! SSH still answers on ${DEST#*@}"; else echo "SSH is off."; fi
sed -i '' '/ mintosh-tunnel$/d' ~/.ssh/authorized_keys 2>/dev/null || true
rm -f "$KEY-tunnel" "$KEY-tunnel.pub" "$KEY" "$KEY.pub"
echo "Keys deleted on this Mac (and the tunnel key removed from its authorized_keys)."
