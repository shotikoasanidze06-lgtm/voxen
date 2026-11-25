#!/usr/bin/env bash
# Voxen Relay one-command setup for an Ubuntu server (e.g. Oracle Cloud Always Free).
#
#   curl -fsSL https://raw.githubusercontent.com/shotikoasanidze06-lgtm/voxen/main/relay/setup_relay.sh | sudo bash -s -- voxenmc YOUR_DUCKDNS_TOKEN
#
# Argument 1: DuckDNS name (voxenmc) or a full domain (voxen.eu.org).   Default: voxenmc
# Argument 2: your DuckDNS token (optional). With it, the script points the DuckDNS name at this server
#             and keeps it updated every 5 minutes.
set -euo pipefail

NAME="${1:-voxenmc}"
TOKEN="${2:-}"
REPO_RAW="https://raw.githubusercontent.com/shotikoasanidze06-lgtm/voxen/main/relay"
if [[ "$NAME" == *.* ]]; then DOMAIN="$NAME"; else DOMAIN="$NAME.duckdns.org"; fi

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo:  ... | sudo bash -s -- $NAME"; exit 1; }

say "Installing what the relay needs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 curl iptables-persistent >/dev/null 2>&1 || apt-get install -y -qq python3 curl >/dev/null

say "Downloading the Voxen relay"
mkdir -p /opt/voxen-relay
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
if [[ -f "$here/voxen_relay.py" ]]; then
  cp "$here/voxen_relay.py" /opt/voxen-relay/
else
  curl -fsSL "$REPO_RAW/voxen_relay.py" -o /opt/voxen-relay/voxen_relay.py
fi
python3 -m py_compile /opt/voxen-relay/voxen_relay.py

say "Starting it as a service (restarts by itself, starts on boot)"
cat > /etc/systemd/system/voxen-relay.service <<EOF
[Unit]
Description=Voxen Relay (lets anyone join Voxen servers by name)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/voxen-relay/voxen_relay.py --domain $DOMAIN --data /var/lib/voxen-relay
WorkingDirectory=/opt/voxen-relay
Restart=always
RestartSec=3
DynamicUser=yes
StateDirectory=voxen-relay

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now voxen-relay >/dev/null
systemctl restart voxen-relay

say "Opening ports 25565 and 25500 on this server"
for p in 25565 25500; do
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT
done
if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; fi
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 25565/tcp >/dev/null; ufw allow 25500/tcp >/dev/null; fi

if [[ -n "$TOKEN" && "$DOMAIN" == *.duckdns.org ]]; then
  say "Pointing $DOMAIN at this server (DuckDNS)"
  SUB="${DOMAIN%.duckdns.org}"
  ans=$(curl -fsS "https://www.duckdns.org/update?domains=$SUB&token=$TOKEN&ip=")
  if [[ "$ans" == "OK" ]]; then echo "DuckDNS: OK"; else echo "DuckDNS said: $ans  (check the name and token on duckdns.org)"; fi
  echo "*/5 * * * * root curl -fsS 'https://www.duckdns.org/update?domains=$SUB&token=$TOKEN&ip=' >/dev/null 2>&1" > /etc/cron.d/voxen-duckdns
  chmod 600 /etc/cron.d/voxen-duckdns
fi

sleep 2
IP=$(curl -fsS https://api.ipify.org || echo "?")
if systemctl is-active --quiet voxen-relay; then
  say "Done! The Voxen relay is running."
  echo "  This server's public IP : $IP"
  echo "  Server addresses        : <name>.$DOMAIN   (e.g. myserver.$DOMAIN)"
  echo "  Relay for Voxen Server  : $DOMAIN, port 25500"
  [[ -z "$TOKEN" && "$DOMAIN" == *.duckdns.org ]] && echo "  Now set $DOMAIN to $IP on duckdns.org (or rerun this with your DuckDNS token)."
  echo
  echo "  Last step: in the Oracle console, allow TCP 25565 and 25500 in the subnet's Security List (see the guide)."
  echo "  Live log:  journalctl -u voxen-relay -f"
else
  echo "The relay didn't start. Log:"; journalctl -u voxen-relay -n 30 --no-pager; exit 1
fi
