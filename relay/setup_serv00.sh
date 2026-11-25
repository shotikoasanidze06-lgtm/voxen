#!/bin/sh
# Voxen Relay setup for a free serv00.com account (FreeBSD, no admin rights needed).
#
#   curl -fsSL https://raw.githubusercontent.com/shotikoasanidze06-lgtm/voxen/main/relay/setup_serv00.sh | sh -s -- voxenmc YOUR_DUCKDNS_TOKEN
#
# Argument 1: DuckDNS name (voxenmc) or a full domain (voxen.eu.org).  Default: voxenmc
# Argument 2: your DuckDNS token (optional): points the name at this server and keeps it updated.
# Safe to run again: it reuses the ports it reserved before.
set -eu

NAME="${1:-voxenmc}"
TOKEN="${2:-}"
REPO_RAW="https://raw.githubusercontent.com/shotikoasanidze06-lgtm/voxen/main/relay"
case "$NAME" in *.*) DOMAIN="$NAME" ;; *) DOMAIN="$NAME.duckdns.org" ;; esac
DIR="$HOME/voxen-relay"
mkdir -p "$DIR/data"

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

say "Allowing your own programs on this account"
devil binexec on >/dev/null 2>&1 || true

say "Downloading the Voxen relay"
curl -fsSL "$REPO_RAW/voxen_relay.py" -o "$DIR/voxen_relay.py"
PY="$(command -v python3 || command -v python3.11 || command -v python3.12 || true)"
[ -n "$PY" ] || { echo "Python 3 not found on this server."; exit 1; }
"$PY" -m py_compile "$DIR/voxen_relay.py"

say "Finding this server's public IP"
IP="$(devil vhost list public 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)"
[ -n "$IP" ] || IP="$("$PY" -c 'import socket; print(socket.gethostbyname(socket.gethostname()))')"
echo "IP: $IP"

reserve() {  # $1 = preferred port, $2 = description; prints the reserved port
  if devil port add tcp "$1" "$2" >/dev/null 2>&1; then echo "$1"; return; fi
  before="$(devil port list 2>/dev/null | grep -i tcp | grep -Eo '[0-9]{4,5}' | sort -u)"
  devil port add tcp random "$2" >/dev/null 2>&1 || { echo "ERROR"; return; }
  after="$(devil port list 2>/dev/null | grep -i tcp | grep -Eo '[0-9]{4,5}' | sort -u)"
  for p in $after; do echo "$before" | grep -qx "$p" || { echo "$p"; return; }; done
  echo "ERROR"
}

if [ -f "$DIR/ports.env" ]; then
  . "$DIR/ports.env"
  say "Using the ports reserved before: players $PLAYER_PORT, Voxen Server $TUNNEL_PORT"
else
  say "Reserving two ports (trying 25565 and 25500 first)"
  PLAYER_PORT="$(reserve 25565 voxen-players)"
  TUNNEL_PORT="$(reserve 25500 voxen-tunnel)"
  if [ "$PLAYER_PORT" = "ERROR" ] || [ "$TUNNEL_PORT" = "ERROR" ]; then
    echo "Couldn't reserve ports. Check 'devil port list' (the free plan allows 3) and try again."; exit 1
  fi
  printf 'PLAYER_PORT=%s\nTUNNEL_PORT=%s\n' "$PLAYER_PORT" "$TUNNEL_PORT" > "$DIR/ports.env"
  echo "players: $PLAYER_PORT   Voxen Server: $TUNNEL_PORT"
fi

say "Creating the start script (keeps the relay running)"
cat > "$DIR/run.sh" <<EOF
#!/bin/sh
# starts the Voxen relay unless it's already running (cron calls this every 5 minutes)
pgrep -f "voxen_relay.py --domain" >/dev/null 2>&1 && exit 0
cd "$DIR" && nohup "$PY" "$DIR/voxen_relay.py" --domain "$DOMAIN" --host "$IP" \\
  --player-port "$PLAYER_PORT" --tunnel-port "$TUNNEL_PORT" --data "$DIR/data" >> "$DIR/relay.log" 2>&1 &
EOF
chmod +x "$DIR/run.sh"
pkill -f "voxen_relay.py --domain" 2>/dev/null || true
sleep 1
"$DIR/run.sh"

say "Adding it to cron (restarts after reboots or if it stops)"
CRON_TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -v "voxen-relay" > "$CRON_TMP" || true
echo "*/5 * * * * $DIR/run.sh # voxen-relay" >> "$CRON_TMP"
echo "@reboot $DIR/run.sh # voxen-relay" >> "$CRON_TMP"
case "$DOMAIN" in
  *.duckdns.org)
    if [ -n "$TOKEN" ]; then
      SUB="${DOMAIN%.duckdns.org}"
      say "Pointing $DOMAIN at $IP (DuckDNS)"
      ans="$(curl -fsS "https://www.duckdns.org/update?domains=$SUB&token=$TOKEN&ip=$IP" || echo FAILED)"
      echo "DuckDNS: $ans"
      echo "*/30 * * * * curl -fsS 'https://www.duckdns.org/update?domains=$SUB&token=$TOKEN&ip=$IP' >/dev/null 2>&1 # voxen-relay" >> "$CRON_TMP"
    fi ;;
esac
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

sleep 3
if pgrep -f "voxen_relay.py --domain" >/dev/null 2>&1; then
  say "Done! The Voxen relay is running."
  if [ "$PLAYER_PORT" = "25565" ]; then ADDR="myserver.$DOMAIN"; else ADDR="myserver.$DOMAIN:$PLAYER_PORT"; fi
  echo "  Server addresses will look like:  $ADDR"
  echo
  echo "  Send these settings to Claude (they go on the Voxen website as network.json):"
  echo "  {\"relay\": \"$DOMAIN\", \"port\": $TUNNEL_PORT, \"player_port\": $PLAYER_PORT, \"domain\": \"$DOMAIN\"}"
  echo
  echo "  Log: tail -f $DIR/relay.log"
else
  echo "The relay didn't start. Last lines of the log:"; tail -n 20 "$DIR/relay.log"; exit 1
fi
