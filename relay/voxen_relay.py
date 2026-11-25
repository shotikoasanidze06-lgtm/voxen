#!/usr/bin/env python3
"""
Voxen Relay — lets anyone join a Minecraft server hosted at home, with no router settings and no VPN.

How it works
  * Each Voxen Server connects OUT to this relay (outgoing connections are never blocked by home routers)
    and claims a name, e.g. "myserver".
  * Players join  myserver.<domain>  (e.g. myserver.voxen.example.com). DNS sends every *.<domain> to this
    machine. Minecraft puts the address the player typed into its first packet (the handshake), so the relay
    reads the name from it and passes the connection through that server's tunnel.
  * Status pings for servers that aren't running get a friendly "Offline" answer.

Run:   python3 voxen_relay.py --domain voxen.example.com
Needs: Python 3.9+, no extra packages. Ports: 25565 (players) and 25500 (Voxen Server tunnels), TCP.
"""
import argparse
import asyncio
import hashlib
import json
import logging
import os
import re
import secrets
import struct
import time

log = logging.getLogger("voxen-relay")
NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$")
RESERVED = {"www", "relay", "api", "mail", "admin", "voxen", "status"}


# ------------------------------------------------------------------ Minecraft protocol helpers
def varint(n):
    out = bytearray()
    n &= 0xFFFFFFFF
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


async def read_varint(reader, raw):
    n, shift = 0, 0
    for _ in range(5):
        b = await reader.readexactly(1)
        raw += b
        n |= (b[0] & 0x7F) << shift
        if not b[0] & 0x80:
            return n
        shift += 7
    raise ValueError("bad varint")


def parse_varint(buf, i):
    n, shift = 0, 0
    for _ in range(5):
        b = buf[i]
        i += 1
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            return n, i
        shift += 7
    raise ValueError("bad varint")


def packet(pid, payload):
    body = varint(pid) + payload
    return varint(len(body)) + body


def mc_string(s):
    b = s.encode("utf-8")
    return varint(len(b)) + b


# ------------------------------------------------------------------ relay
class Tunnel:
    def __init__(self, name, writer):
        self.name, self.writer = name, writer
        self.pending = {}          # connection id -> Future(data StreamReader/Writer)
        self.last_seen = time.time()
        self.players = 0

    async def send(self, obj):
        self.writer.write((json.dumps(obj) + "\n").encode())
        await self.writer.drain()


class Relay:
    def __init__(self, domain, data_dir, max_tunnels):
        self.domain = domain.lower().strip(".")
        self.tunnels = {}
        self.data_dir = data_dir
        self.max_tunnels = max_tunnels
        os.makedirs(data_dir, exist_ok=True)
        self.names_path = os.path.join(data_dir, "names.json")
        try:
            with open(self.names_path, encoding="utf-8") as f:
                self.names = json.load(f)   # name -> sha256(token)
        except Exception:
            self.names = {}

    def _save_names(self):
        tmp = self.names_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.names, f)
        os.replace(tmp, self.names_path)

    def address(self, name):
        return f"{name}.{self.domain}"

    # ---------- tunnel (Voxen Server) side
    async def handle_control(self, reader, writer):
        peer = writer.get_extra_info("peername")
        try:
            line = await asyncio.wait_for(reader.readline(), 15)
            msg = json.loads(line or b"{}")
        except Exception:
            writer.close()
            return
        if msg.get("op") == "data":
            await self._attach_data(msg, reader, writer)
            return
        if msg.get("op") != "hello":
            writer.close()
            return
        name = str(msg.get("name", "")).lower()
        token = str(msg.get("token") or "")

        async def fail(text):
            writer.write((json.dumps({"op": "error", "msg": text}) + "\n").encode())
            await writer.drain()
            writer.close()

        if not NAME_RE.match(name) or name in RESERVED:
            return await fail("That address name isn't allowed. Use letters, digits and dashes.")
        h = hashlib.sha256(token.encode()).hexdigest()
        if name in self.names and self.names[name] != h:
            return await fail(f"The address {self.address(name)} belongs to someone else. Pick another name.")
        if name not in self.names:
            if len(self.names) >= self.max_tunnels * 50:
                return await fail("This relay is full.")
            token = secrets.token_hex(24)
            self.names[name] = hashlib.sha256(token.encode()).hexdigest()
            self._save_names()
        old = self.tunnels.get(name)
        if old:
            old.writer.close()
        if len(self.tunnels) >= self.max_tunnels and name not in self.tunnels:
            return await fail("This relay has too many servers online right now. Try again later.")
        t = Tunnel(name, writer)
        self.tunnels[name] = t
        await t.send({"op": "welcome", "address": self.address(name), "token": token})
        log.info("tunnel up: %s from %s", name, peer)
        try:
            while True:
                line = await asyncio.wait_for(reader.readline(), 75)
                if not line:
                    break
                t.last_seen = time.time()
        except Exception:
            pass
        finally:
            if self.tunnels.get(name) is t:
                del self.tunnels[name]
            for fut in t.pending.values():
                if not fut.done():
                    fut.cancel()
            writer.close()
            log.info("tunnel down: %s", name)

    async def _attach_data(self, msg, reader, writer):
        t = self.tunnels.get(str(msg.get("name", "")).lower())
        cid = str(msg.get("id", ""))
        if not t or self.names.get(t.name) != hashlib.sha256(str(msg.get("token", "")).encode()).hexdigest():
            writer.close()
            return
        fut = t.pending.get(cid)
        if fut and not fut.done():
            fut.set_result((reader, writer))
        else:
            writer.close()

    async def heartbeat(self):
        while True:
            await asyncio.sleep(25)
            for t in list(self.tunnels.values()):
                try:
                    await t.send({"op": "ping"})
                except Exception:
                    pass

    # ---------- player side
    async def handle_player(self, reader, writer):
        raw = bytearray()
        try:
            first = await asyncio.wait_for(reader.readexactly(1), 10)
            if first[0] == 0xFE:          # pre-1.7 server list ping
                writer.close()
                return
            raw += first
            # first byte belongs to the packet-length varint
            n, shift, b = first[0] & 0x7F, 7, first[0]
            while b & 0x80:
                nb = await reader.readexactly(1)
                raw += nb
                b = nb[0]
                n |= (b & 0x7F) << shift
                shift += 7
            if n > 1024:
                writer.close()
                return
            body = await asyncio.wait_for(reader.readexactly(n), 10)
            raw += body
            pid, i = parse_varint(body, 0)
            proto, i = parse_varint(body, i)
            slen, i = parse_varint(body, i)
            host = body[i:i + slen].decode("utf-8", "replace")
            i += slen + 2
            next_state, i = parse_varint(body, i)
        except Exception:
            writer.close()
            return
        host = host.split("\x00")[0].rstrip(".").lower()
        name = host[: -len(self.domain) - 1] if host.endswith("." + self.domain) else ""
        t = self.tunnels.get(name) if NAME_RE.match(name or "-") else None
        if not t:
            await self._offline(reader, writer, proto, next_state, name)
            return
        cid = secrets.token_hex(8)
        fut = asyncio.get_running_loop().create_future()
        t.pending[cid] = fut
        try:
            await t.send({"op": "open", "id": cid})
            dreader, dwriter = await asyncio.wait_for(fut, 10)
        except Exception:
            t.pending.pop(cid, None)
            await self._offline(reader, writer, proto, next_state, name, "The server didn't answer. Try again.")
            return
        t.pending.pop(cid, None)
        dwriter.write(bytes(raw))
        await dwriter.drain()
        if next_state == 2:
            t.players += 1
        try:
            await asyncio.gather(self._pipe(reader, dwriter), self._pipe(dreader, writer))
        finally:
            if next_state == 2:
                t.players -= 1

    @staticmethod
    async def _pipe(src, dst):
        try:
            while True:
                data = await src.read(65536)
                if not data:
                    break
                dst.write(data)
                await dst.drain()
        except Exception:
            pass
        finally:
            try:
                dst.close()
            except Exception:
                pass

    async def _offline(self, reader, writer, proto, next_state, name, reason=None):
        try:
            if name and name in self.names:
                text = reason or "This Voxen server is offline. Ask the owner to press Start in Voxen Server."
            else:
                text = "There's no Voxen server with this address."
            if next_state == 1:                           # server list: show it as offline
                await reader.readexactly((await read_varint(reader, bytearray())))   # status request
                status = {"version": {"name": "Offline", "protocol": -1},
                          "players": {"max": 0, "online": 0},
                          "description": {"text": "● Offline", "color": "red",
                                          "extra": [{"text": "\n" + text, "color": "gray"}]}}
                writer.write(packet(0x00, mc_string(json.dumps(status))))
                await writer.drain()
                ln = await asyncio.wait_for(read_varint(reader, bytearray()), 5)   # ping
                ping = await reader.readexactly(ln)
                writer.write(varint(len(ping)) + ping)
                await writer.drain()
            else:                                          # joining: disconnect with a message
                writer.write(packet(0x00, mc_string(json.dumps({"text": text}))))
                await writer.drain()
        except Exception:
            pass
        finally:
            writer.close()


async def main():
    ap = argparse.ArgumentParser(description="Voxen Relay")
    ap.add_argument("--domain", required=True, help="e.g. voxen.example.com (players join <name>.voxen.example.com)")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--player-port", type=int, default=25565)
    ap.add_argument("--tunnel-port", type=int, default=25500)
    ap.add_argument("--data", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "relay-data"))
    ap.add_argument("--max-online", type=int, default=200, help="max servers online at once")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    r = Relay(a.domain, a.data, a.max_online)
    s1 = await asyncio.start_server(r.handle_player, a.host, a.player_port)
    s2 = await asyncio.start_server(r.handle_control, a.host, a.tunnel_port)
    log.info("Voxen Relay ready: players -> *.%s:%d, tunnels on :%d", r.domain, a.player_port, a.tunnel_port)
    asyncio.create_task(r.heartbeat())
    async with s1, s2:
        await asyncio.gather(s1.serve_forever(), s2.serve_forever())


if __name__ == "__main__":
    asyncio.run(main())
