# Voxen network: put the relay online

The relay is what makes `myserver.voxen.yourdomain.com` work for everyone, with no router settings and no VPN.
Every Voxen Server connects *out* to it when you press Start (home routers never block outgoing connections),
and players' connections come back through that tunnel. You set it up once; everyone who uses your Voxen build uses it.

What you need: a domain, and a small always-on Linux server (VPS) with a public IPv4 address.

## 1. Domain
Buy one from any registrar (below it's called `yourdomain.com`). The same domain can later hold the Voxen website
(`yourdomain.com` / `www.yourdomain.com`), since the relay only uses the subdomains below.

## 2. VPS
Any provider works (Hetzner, DigitalOcean, Vultr, OVH; Oracle Cloud's "Always Free" tier also works).
1 CPU and 1 GB of RAM is enough for many servers. What matters is **bandwidth**: all game traffic passes
through the relay, roughly 50–150 kbit/s per player. Pick a location close to your players.

## 3. DNS (at your registrar or at Cloudflare)
| Type | Name | Value |
|---|---|---|
| A | `relay` | your VPS IP |
| A | `*.voxen` | your VPS IP |

With Cloudflare, set both to **DNS only (grey cloud)**. Cloudflare's proxy can't carry Minecraft.

## 4. Install the relay on the VPS (Ubuntu/Debian)
```bash
sudo apt update && sudo apt install -y python3
sudo mkdir -p /opt/voxen-relay
sudo cp voxen_relay.py /opt/voxen-relay/
sudo cp voxen-relay.service /etc/systemd/system/
# the service file is set to voxen.eu.org; change --domain if you use another domain:
sudo nano /etc/systemd/system/voxen-relay.service
sudo systemctl daemon-reload
sudo systemctl enable --now voxen-relay
sudo ufw allow 25565/tcp && sudo ufw allow 25500/tcp     # if ufw is on
```
If your provider has a cloud firewall, also allow TCP 25565 and 25500 there.
Check it runs: `journalctl -u voxen-relay -f` should show `Voxen Relay ready`.

## 5. Point Voxen Server at it
Either in the app: **⚙ Voxen network** → relay `relay.yourdomain.com`, port `25500`, domain `voxen.yourdomain.com`,

or, so every copy you share has it built in, edit `voxen-network.json` before building:
```json
{ "relay": "relay.yourdomain.com", "port": 25500, "domain": "voxen.yourdomain.com" }
```
Players then join **`<address name>.voxen.yourdomain.com`**, e.g. `myserver.voxen.yourdomain.com`. No port is needed,
because the relay listens on Minecraft's default port 25565.

## How names work
- Each server's address name (Options → Address name) is claimed on the relay the first time it starts.
  The relay gives that PC a secret key, so nobody else can take the name over.
- A server list ping to a name that isn't running shows **● Offline** with a message.
- Data lives in `/var/lib/voxen-relay/names.json`. Delete a line there to free a name.

## Security notes
- Voxen servers run with `online-mode=false` so Voxen's offline players can join. Anyone who knows an address can
  join with any name. Tell users to turn on the **Whitelist** (Options) and add their friends (Players).
- The tunnel connection isn't encrypted (same as normal Minecraft traffic, which isn't either). The per-name key only
  stops other people from claiming your name.
- `--max-online` (default 200) limits how many servers can be online through the relay at once.
