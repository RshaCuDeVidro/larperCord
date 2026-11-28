#!/usr/bin/env python3
"""Fake Discord for the network QA suite (QA_SUITE=rede, run by tools/qa_rede.sh).

larperCord's other QA suites swap the whole network layer for src/net/fake_gateway.zig.
This server lets the REAL src/net/discord.zig run instead: it speaks the actual wire
protocol on 127.0.0.1, so the WebSocket gateway, zlib-stream, IDENTIFY, heartbeat,
RESUME, reconnects, op 7 / op 9, READY parsing, REST requests and 429 handling are all
exercised without a Discord account and without leaving the machine.

  * Gateway: WebSocket on any path (the resume_gateway_url it hands out is /retomar),
    compress=zlib-stream exactly like Discord: one zlib context per connection, every
    payload ends with the Z_SYNC_FLUSH suffix 00 00 ff ff. HELLO asks for a tiny
    heartbeat interval (HB_MS) so the heartbeat and zombie checks take a second.
  * REST: /api/v10 and /api/v9, the paths the app uses at startup and in the suite
    (history, send, acks, settings); anything else is a logged 404.
  * Auth: only the fixed fake TOKEN below (deliberately not shaped like a Discord token).
    Any other token gets 401 on REST and close 4004 on the gateway.

Plain http/ws only, no TLS and no pip packages: the WebSocket handshake and framing are
written here. The QA build of the app reaches it through LARPER_QA_DISCORD (see
src/net/enderecos.zig; that override does not exist in release builds).

Control channel (same port, used by src/qa_rede.zig; all GET, answers JSON):
  /ctl/message?channel=ID&text=T        MESSAGE_CREATE now (from Bia)
  /ctl/burst?channel=ID&n=N&prefix=P    N MESSAGE_CREATEs back to back, same zlib stream
  /ctl/big?channel=ID&text=T            one MESSAGE_CREATE of ~200 KB (spans many reads)
  /ctl/split?parts=N                    the next dispatch goes out as N WebSocket messages
  /ctl/fragment?parts=N                 the next dispatch goes out as one message in N frames
  /ctl/close?code=C&missed=N&channel=ID close the socket with C, then queue N events that
                                        only a RESUME replays
  /ctl/op7                              send op 7 RECONNECT
  /ctl/op9?resumable=0|1                send op 9 INVALID_SESSION
  /ctl/noack                            stop acking heartbeats on the current connection
  /ctl/rate429?channel=ID&count=N&retry_after=S   next N history GETs answer 429
  /ctl/echo?ms=N                        delay the MESSAGE_CREATE echo of a sent message
  /ctl/voz?user=ID                      VOICE_STATE_UPDATE: that bot joins #voz, member and user included
  /ctl/check/<name>?...                 {"ok": bool, "why": "..."} (see CHECKS)
  /ctl/summary                          checks whose last answer was not ok, unknown paths
  /ctl/state                            connections, heartbeats and requests (debugging)

Big account (--conta grande, tools/conta_grande.py; QA_SUITE=conta-grande and
tools/ram_conta_grande.sh): the READY is the 52-server account, followed by READY_SUPPLEMENTAL;
op 14 gets the member list, op 8 the members asked for, the history has older pages
(`before`), the CDN (/cdn/<host>/...) serves generated PNGs, and background traffic
(presences, member list updates, messages, typing) runs while connected.
  /ctl/trafego?on=0|1                   pause or resume the background traffic
  /ctl/conta                            counters of what the big account sent

Usage: discord_falso.py [--conta grande] [--semente N]
       (prints the port it listens on, then serves until killed)
"""
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import random
import re
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TOKEN = "larper-qa-token-falso-nao-e-do-discord"
HB_MS = 250
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EPOCH = 1420070400000

# The same IDs are in src/qa_rede.zig.
ME, BIA, CAIO = 1180000000000000001, 1180000000000000002, 1180000000000000003
GUILD, CAT, GERAL, LIMITE = 1190000000000000010, 1190000000000000011, 1190000000000000012, 1190000000000000013
DM = 1190000000000000020
# #voz: BOT is already in it at READY (voice_states and merged_members with the ID only, like
# Discord), BOT2 joins later with /ctl/voz. Neither ever wrote, so only the op 8 answer or the
# VOICE_STATE_UPDATE's member brings the user.
VOZ, BOT, BOT2 = 1190000000000000014, 1180000000000000004, 1180000000000000005

lock = threading.RLock()
T0 = time.monotonic()
PORT = 0


def now():
    return time.monotonic() - T0


def iso(ms=None):
    ms = time.time() * 1000 if ms is None else ms
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).isoformat(timespec="microseconds")


class Session:
    def __init__(self):
        self.id = os.urandom(16).hex()
        self.seq = 0
        self.events = []
        self.valid = True


state = {
    "session": None,
    "live": None,
    "conns": [],
    "requests": [],
    "echo_ms": 0,
    "split": 0,
    "fragment": 0,
    "rate429": {},
    "trigger": None,
    "op8": [],
    "checks": {},
    "last_id": 0,
    # Big account (--conta grande).
    "sub": None,
    "trafego": True,
    "sent": {},
}

# The big account (tools/conta_grande.py), or None for the small one of the rede suite.
CONTA = None


def load_conta(seed):
    # Loaded by path: under python -I the script's folder is not on sys.path. No __pycache__
    # left next to it in the repo.
    sys.dont_write_bytecode = True
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("conta_grande", os.path.join(here, "conta_grande.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, mod.Conta(seed=seed)


CG = None


def next_id(ms=None):
    ms = int(time.time() * 1000) if ms is None else int(ms)
    with lock:
        state["last_id"] = max(state["last_id"] + 1, (ms - EPOCH) << 22)
        return state["last_id"]


NAMES = {ME: ("qa.eu", "QA Eu"), BIA: ("bia.falsa", "Bia Falsa"), CAIO: ("caio.falso", "Caio Falso"),
         BOT: ("musica.bot", None), BOT2: ("radio.bot", None)}


def user(uid):
    un, gn = NAMES[uid]
    u = {"id": str(uid), "username": un, "global_name": gn, "avatar": None, "discriminator": "0",
         "public_flags": 0, "avatar_decoration_data": None}
    if uid in (BOT, BOT2):
        u["bot"] = True
    return u


def voice_state(uid):
    return {"user_id": str(uid), "channel_id": str(VOZ), "session_id": "falso", "deaf": False, "mute": False,
            "self_deaf": False, "self_mute": False, "self_video": False, "suppress": False,
            "request_to_speak_timestamp": None}


def member():
    return {"roles": [], "joined_at": iso(time.time() * 1000 - 86400_000 * 30), "nick": None, "flags": 0,
            "deaf": False, "mute": False}


def message(cid, author, content, nonce=None, ms=None):
    m = {"id": str(next_id(ms)), "channel_id": str(cid), "author": user(author), "content": content,
         "timestamp": iso(ms), "edited_timestamp": None, "tts": False, "mention_everyone": False,
         "mentions": [], "mention_roles": [], "attachments": [], "embeds": [], "components": [],
         "pinned": False, "type": 0, "flags": 0}
    if nonce is not None:
        m["nonce"] = nonce
    return m


def as_event(m):
    """REST messages have no guild_id/member; the gateway's MESSAGE_CREATE does."""
    e = dict(m)
    if m["channel_id"] == str(DM):
        e["channel_type"] = 1
    else:
        e["guild_id"] = str(GUILD)
        e["member"] = member()
    return e


_t = time.time() * 1000
messages = {
    GERAL: [message(GERAL, BIA, "primeira do histórico", ms=_t - 3_600_000),
            message(GERAL, CAIO, "segunda do histórico", ms=_t - 3_000_000),
            message(GERAL, BIA, "terceira do histórico", ms=_t - 2_400_000)],
    LIMITE: [message(LIMITE, CAIO, "histórico depois do 429", ms=_t - 1_800_000)],
    DM: [message(DM, BIA, "oi, é a dm falsa", ms=_t - 1_200_000)],
}


def guild():
    joined = iso(time.time() * 1000 - 86400_000 * 30)
    chan = lambda cid, name, pos, kind=0, parent=CAT: {  # noqa: E731
        "id": str(cid), "type": kind, "name": name, "position": pos, "permission_overwrites": [],
        **({"parent_id": str(parent)} if parent else {}),
        **({"topic": "canal do QA de rede", "rate_limit_per_user": 0, "nsfw": False,
            "last_message_id": messages[cid][-1]["id"]} if kind == 0 else {})}
    return {
        "id": str(GUILD),
        "properties": {"id": str(GUILD), "name": "Servidor Falso", "icon": None, "banner": None,
                       "owner_id": str(ME), "description": None, "features": [], "preferred_locale": "pt-BR"},
        "channels": [chan(CAT, "Texto", 0, kind=4, parent=None), chan(GERAL, "geral", 0), chan(LIMITE, "limite", 1),
                     chan(VOZ, "voz", 2, kind=2)],
        "roles": [{"id": str(GUILD), "name": "@everyone", "permissions": "2248473465835073", "position": 0,
                   "color": 0, "managed": False, "mentionable": False, "hoist": False}],
        "emojis": [], "stickers": [], "threads": [], "voice_states": [voice_state(BOT)], "member_count": 4,
        "joined_at": joined, "lazy": True, "large": False, "data_mode": "full", "version": 1,
        "premium_subscription_count": 0,
    }


def ready_payload(s):
    me = dict(user(ME), email=None, verified=True, mfa_enabled=False, premium_type=0, flags=0, bot=False)
    if CONTA is not None:
        me["id"] = str(CONTA.me)
        return CONTA.ready(s.id, f"ws://127.0.0.1:{PORT}/retomar", me)
    return {
        "v": 10, "user": me, "session_id": s.id, "session_type": "normal",
        "resume_gateway_url": f"ws://127.0.0.1:{PORT}/retomar",
        "guilds": [guild()],
        "private_channels": [{"id": str(DM), "type": 1, "recipient_ids": [str(BIA)], "flags": 0,
                              "last_message_id": messages[DM][-1]["id"]}],
        "users": [user(BIA), user(CAIO)],
        "relationships": [{"id": str(BIA), "user_id": str(BIA), "type": 1, "nickname": None,
                           "since": iso(time.time() * 1000 - 86400_000 * 90)}],
        "merged_members": [[{"user_id": str(ME), **member()}]],
        "read_state": {"entries": [], "partial": False, "version": 1},
        "user_guild_settings": {"entries": [], "partial": False, "version": 1},
        "sessions": [], "country_code": "BR", "guild_join_requests": [], "connected_accounts": [],
        "analytics_token": "falso", "auth_session_id_hash": "falso", "api_code_version": 1,
    }


# --- WebSocket ------------------------------------------------------------------------


def frame(opcode, payload, fin=True):
    b0 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        hdr = struct.pack("!BB", b0, n)
    elif n < 65536:
        hdr = struct.pack("!BBH", b0, 126, n)
    else:
        hdr = struct.pack("!BBQ", b0, 127, n)
    return hdr + payload


def read_exact(rfile, n):
    data = rfile.read(n) if n else b""
    if len(data) < n:
        raise EOFError
    return data


def read_frame(rfile):
    b0, b1 = read_exact(rfile, 2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack("!H", read_exact(rfile, 2))[0]
    elif n == 127:
        n = struct.unpack("!Q", read_exact(rfile, 8))[0]
    mask = read_exact(rfile, 4) if b1 & 0x80 else None
    data = read_exact(rfile, n)
    if mask and n:
        m = (mask * (n // 4 + 1))[:n]
        data = (int.from_bytes(data, "big") ^ int.from_bytes(m, "big")).to_bytes(n, "big")
    return bool(b0 & 0x80), b0 & 0x0F, data, mask is not None


class Conn:
    def __init__(self, handler, path, query):
        self.sock = handler.connection
        self.path, self.query = path, query
        self.opened = now()
        self.hello_at = None
        self.first_op = None
        self.identify = None
        self.resume = None
        self.resumed = False
        self.replayed = 0
        self.invalid_sent = None
        self.heartbeats = []
        self.ops = []
        self.unmasked = 0
        self.client_close = None
        self.server_close = None
        self.closed = None
        self.noack_at = None
        self.ready = False
        self.last_sent_seq = None
        self.comp = zlib.compressobj()
        self.wlock = threading.Lock()
        with lock:
            self.n = len(state["conns"])
            state["conns"].append(self)

    def send(self, obj, split=0, fragment=0, prefix=b""):
        data = json.dumps(obj, separators=(",", ":")).encode()
        with self.wlock:
            if self.closed is not None or self.server_close is not None:
                return False
            z = self.comp.compress(data) + self.comp.flush(zlib.Z_SYNC_FLUSH)
            assert z.endswith(b"\x00\x00\xff\xff")
            if split > 1:
                k = max(1, len(z) // split)
                cuts = [z[i * k:(i + 1) * k] for i in range(split - 1)] + [z[(split - 1) * k:]]
                out = b"".join(frame(2, p) for p in cuts if p)
            elif fragment > 1:
                k = max(1, len(z) // fragment)
                parts = [z[i * k:(i + 1) * k] for i in range(fragment - 1)] + [z[(fragment - 1) * k:]]
                out = b"".join(frame(2 if i == 0 else 0, p, fin=i == len(parts) - 1) for i, p in enumerate(parts))
            else:
                out = frame(2, z)
            try:
                self.sock.sendall(prefix + out)
            except OSError:
                return False
            if obj.get("s") is not None:
                self.last_sent_seq = obj["s"]
            return True

    def close(self, code, reason=""):
        with self.wlock:
            if self.closed is not None or self.server_close is not None:
                return
            self.server_close = code
            try:
                self.sock.sendall(frame(8, struct.pack("!H", code) + reason.encode()))
                self.sock.shutdown(2)
            except OSError:
                pass


def dispatch(t, d, only_store=False):
    with lock:
        s = state["session"]
        if s is None:
            return None
        s.seq += 1
        p = {"op": 0, "t": t, "s": s.seq, "d": d}
        state["sent"][t] = state["sent"].get(t, 0) + 1
        s.events.append(p)
        c = state["live"]
        if c is not None and c.ready and not only_store:
            split, frag = state["split"], state["fragment"]
            state["split"] = state["fragment"] = 0
            c.send(p, split=split, fragment=frag)
        return p


def on_identify(conn, d):
    conn.identify = d
    if d.get("token") != TOKEN:
        return conn.close(4004, "Authentication failed.")
    if conn.ready:
        return conn.close(4005, "Already authenticated.")
    with lock:
        if state["session"] is not None:
            state["session"].valid = False
        s = Session()
        state["session"] = s
        state["live"] = conn
        conn.ready = True
        dispatch("READY", ready_payload(s))
        dispatch("READY_SUPPLEMENTAL", CONTA.supplemental() if CONTA is not None else supplemental())


def on_resume(conn, d):
    conn.resume = d
    if d.get("token") != TOKEN:
        return conn.close(4004, "Authentication failed.")
    with lock:
        s = state["session"]
        seq = d.get("seq")
        ok = (s is not None and s.valid and d.get("session_id") == s.id and isinstance(seq, int)
              and 0 <= seq <= s.seq)
        if not ok:
            if s is not None:
                s.valid = False
            conn.invalid_sent = now()
            conn.send({"op": 9, "d": False})
            return
        missed = [p for p in s.events if p["s"] > seq]
        for p in missed:
            conn.send(p)
        conn.replayed = len(missed)
        conn.resumed = True
        conn.ready = True
        state["live"] = conn
        dispatch("RESUMED", {"_trace": ["discord-falso"]})


def on_text(conn, data):
    try:
        obj = json.loads(data)
    except ValueError:
        return conn.close(4002, "Decode error.")
    op, d = obj.get("op"), obj.get("d")
    conn.ops.append((now(), op, d))
    if conn.first_op is None and op in (2, 6):
        conn.first_op = op
    if op == 1:
        conn.heartbeats.append((now(), d, conn.last_sent_seq))
        if conn.noack_at is None:
            conn.send({"op": 11})
    elif op == 2:
        on_identify(conn, d or {})
    elif op == 6:
        on_resume(conn, d or {})
    elif CONTA is not None and op == 14 and isinstance(d, dict):
        on_lazy(d)
    elif CONTA is not None and op == 8 and isinstance(d, dict):
        on_members(d)
    elif op == 8 and isinstance(d, dict):
        on_members_small(d)


def supplemental():
    """READY_SUPPLEMENTAL of the small account: who is in #voz, with the member by ID only."""
    return {"guilds": [{"id": str(GUILD), "voice_states": [voice_state(BOT)], "embedded_activities": []}],
            "merged_members": [[{"user_id": str(BOT), **member()}]],
            "merged_presences": {"friends": [], "guilds": [[]]}, "lazy_private_channels": [], "disclose": []}


def on_members_small(d):
    """op 8 of the small account: the members it knows among the IDs asked for."""
    ids = [int(x) for x in d.get("user_ids") or [] if str(x).isdigit()]
    with lock:
        state["op8"].append(ids)
    found = [i for i in ids if i in NAMES]
    dispatch("GUILD_MEMBERS_CHUNK", {
        "guild_id": str(GUILD), "members": [{"user": user(i), **member()} for i in found],
        "chunk_index": 0, "chunk_count": 1, "not_found": [str(i) for i in ids if i not in NAMES],
        **({"nonce": d["nonce"]} if d.get("nonce") else {})})


def on_lazy(d):
    """op 14: the member list of the channel (the first 100 rows), like Discord."""
    try:
        gid = int(d.get("guild_id"))
        cid = int(next(iter((d.get("channels") or {}).keys())))
    except (TypeError, ValueError, StopIteration):
        return
    with lock:
        state["sub"] = (gid, cid)
    lst = CONTA.member_list(gid, cid)
    if lst is not None:
        dispatch("GUILD_MEMBER_LIST_UPDATE", lst)


def on_members(d):
    """op 8: the members asked for by ID (the authors of a history page) or by name."""
    try:
        gid = int(d.get("guild_id"))
    except (TypeError, ValueError):
        return
    ids = d.get("user_ids")
    if ids is None and isinstance(d.get("query"), str):
        q = d["query"].lower()
        g = CONTA.guilds.get(gid)
        ids = [u for u in (g["pool"] if g else []) if CONTA.user(u)["username"].startswith(q)][:int(d.get("limit") or 10)]
    chunk = CONTA.members_chunk(gid, ids or [], d.get("nonce"))
    if chunk is not None:
        dispatch("GUILD_MEMBERS_CHUNK", chunk)


def trafego():
    """Background traffic of a busy account, while a connection is live: presences and
    member list updates in the server being viewed, messages across the servers and DMs,
    typing in the open channel. Deterministic order (a seeded RNG), the clock decides the rest."""
    r = random.Random(f"{CONTA.seed}:trafego")
    texts = [cid for cid, (g, k, last) in CONTA.channel_info.items() if k in (0, 1, 3) and last is not None]
    tick = 0
    while True:
        time.sleep(0.1)
        tick += 1
        with lock:
            on, sub = state["trafego"], state["sub"]
            live = state["live"] is not None and state["live"].ready
        if not on or not live:
            continue
        if sub is not None:
            gid, cid = sub
            pool = CONTA.guilds[gid]["pool"]
            # ~4 presences per second in the server on screen.
            if r.random() < 0.4:
                uid = r.choice(pool)
                p = CONTA.presence(uid, random.Random(f"{CONTA.seed}:p:{tick}"))
                p["guild_id"] = str(gid)
                dispatch("PRESENCE_UPDATE", p)
            # A row of the member list changes every ~2 s.
            if r.random() < 0.05:
                uid = r.choice(pool)
                m = CONTA.member(gid, uid)
                m["presence"] = CONTA.presence(uid, random.Random(f"{CONTA.seed}:p:{tick}"))
                dispatch("GUILD_MEMBER_LIST_UPDATE", {"guild_id": str(gid), "id": "everyone", "member_count": CONTA.guilds[gid]["member_count"],
                                                      "online_count": len(pool), "groups": [{"id": "online", "count": len(pool)}],
                                                      "ops": [{"op": "UPDATE", "index": r.randint(1, 60), "item": {"member": m}}]})
            if r.random() < 0.03:
                dispatch("TYPING_START", {"channel_id": str(cid), "guild_id": str(gid), "user_id": str(r.choice(pool)),
                                          "timestamp": int(time.time()), "member": CONTA.member(gid, r.choice(pool))})
        # ~2 messages per second across the account, a third of them in the channel on screen.
        if r.random() < 0.2:
            cid = sub[1] if sub is not None and r.random() < 0.33 else r.choice(texts)
            m = CONTA.live_message(cid, next_id(), random.Random(f"{CONTA.seed}:m:{tick}"))
            dispatch("MESSAGE_CREATE", m)


def gateway(handler, path, query):
    key = handler.headers.get("Sec-WebSocket-Key", "")
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    switch = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode()
    conn = Conn(handler, path, query)
    # HELLO in the same write as the 101, as a real server often does: the client may read
    # it during the handshake, before it ever polls the socket.
    # The big account uses Discord's own interval: its READY takes longer than 250 ms to read.
    conn.send({"op": 10, "d": {"heartbeat_interval": HB_MS if CONTA is None else 41250, "_trace": ["discord-falso"]}}, prefix=switch)
    conn.hello_at = now()
    msg = bytearray()
    try:
        while True:
            fin, op, data, masked = read_frame(handler.rfile)
            if not masked:
                conn.unmasked += 1
            if op == 8:
                conn.client_close = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 1005
                with conn.wlock:
                    try:
                        conn.sock.sendall(frame(8, data[:2]))
                    except OSError:
                        pass
                break
            if op == 9:
                with conn.wlock:
                    conn.sock.sendall(frame(10, data))
                continue
            if op == 10:
                continue
            if op in (1, 2):
                msg = bytearray(data)
            elif op == 0:
                msg += data
            if fin:
                on_text(conn, bytes(msg))
                msg = bytearray()
    except (EOFError, OSError, ValueError):
        pass
    finally:
        with lock:
            conn.closed = now()
            if state["live"] is conn:
                state["live"] = None
            # Like Discord: a client that closes with 1000/1001 ends its session (no RESUME).
            if conn.client_close in (1000, 1001) and state["session"] is not None:
                state["session"].valid = False
    handler.close_connection = True


# --- Checks (asked by src/qa_rede.zig) -------------------------------------------------


def q1(q, name, default=None):
    return q.get(name, [default])[0]


def last_identify():
    with lock:
        for c in reversed(state["conns"]):
            if c.identify is not None:
                return c
    return None


def chk_identify(q):
    c = last_identify()
    if c is None:
        return False, "nenhum IDENTIFY"
    d, bad = c.identify, []
    if parse_qs(c.query) != {"v": ["10"], "encoding": ["json"], "compress": ["zlib-stream"]}:
        bad.append(f"query do gateway: {c.query!r}")
    if d.get("token") != TOKEN:
        bad.append("token")
    props = d.get("properties")
    if not isinstance(props, dict):
        bad.append("sem properties")
    else:
        need = ["os", "browser", "device", "system_locale", "browser_user_agent", "browser_version",
                "os_version", "release_channel", "client_build_number"]
        miss = [k for k in need if k not in props]
        if miss:
            bad.append(f"properties sem {miss}")
        if not isinstance(props.get("client_build_number"), int):
            bad.append("client_build_number não é número")
    if not isinstance(d.get("capabilities"), int) or d["capabilities"] <= 0:
        bad.append("capabilities")
    if "intents" in d:
        bad.append("conta de usuário não manda intents")
    if d.get("compress") is not False:
        bad.append("compress deveria ser false (a compressão é a do transporte)")
    pres = d.get("presence")
    if not isinstance(pres, dict) or pres.get("status") not in ("online", "idle", "dnd", "invisible") \
            or not isinstance(pres.get("activities"), list) or "since" not in pres or "afk" not in pres:
        bad.append(f"presence: {pres!r}")
    if not isinstance(d.get("client_state"), dict):
        bad.append("client_state")
    if c.first_op != 2:
        bad.append(f"primeiro op depois do HELLO foi {c.first_op}")
    bad += slow_start(c)
    return not bad, "; ".join(bad) or "ok"


FIRST_OP_MS = 400


def slow_start(c):
    """IDENTIFY/RESUME has to follow HELLO right away (the client only waits on itself)."""
    first = next((t for t, op, _ in c.ops if op in (2, 6)), None)
    if first is None:
        return []
    ms = (first - c.hello_at) * 1000
    return [f"o primeiro op saiu {ms:.0f} ms depois do HELLO"] if ms > FIRST_OP_MS else []


def chk_heartbeat(q):
    with lock:
        c = state["live"]
    if c is None:
        return False, "sem conexão"
    hb = list(c.heartbeats)
    if len(hb) < 3:
        return False, f"só {len(hb)} heartbeat(s)"
    bad = []
    first = (hb[0][0] - c.hello_at) * 1000
    if first > HB_MS * 1.2 + 100:
        bad.append(f"primeiro heartbeat {first:.0f} ms depois do HELLO (intervalo {HB_MS})")
    gaps = [(b[0] - a[0]) * 1000 for a, b in zip(hb, hb[1:])]
    off = [round(g) for g in gaps if not HB_MS * 0.6 <= g <= HB_MS * 2.0]
    if off:
        bad.append(f"intervalos fora de {HB_MS} ms: {off}")
    for t, d, sent in hb:
        if sent is None:
            if d is not None:
                bad.append(f"heartbeat com d={d} antes de qualquer seq")
        elif not isinstance(d, int) or d > sent or d < 1:
            bad.append(f"heartbeat com d={d!r}, último seq enviado {sent}")
    return not bad, "; ".join(bad) or "ok"


def api_requests():
    with lock:
        return [r for r in state["requests"] if r["path"].startswith("/api/")]


def chk_rest(q):
    reqs = api_requests()
    c = last_identify()
    if not reqs or c is None:
        return False, "nenhum pedido REST"
    props = c.identify.get("properties")
    bad = []
    for r in reqs:
        h = r["headers"]
        if h.get("authorization") != TOKEN:
            bad.append(f"{r['path']}: Authorization")
        try:
            sp = json.loads(base64.b64decode(h.get("x-super-properties", "")))
        except ValueError:
            sp = None
        if sp != props:
            bad.append(f"{r['path']}: X-Super-Properties diferente das properties do IDENTIFY")
        if isinstance(props, dict) and h.get("user-agent") != props.get("browser_user_agent"):
            bad.append(f"{r['path']}: User-Agent diferente do browser_user_agent")
    return not bad, "; ".join(sorted(set(bad))) or f"ok ({len(reqs)} pedidos)"


def history_reqs(cid):
    return [r for r in api_requests() if r["method"] == "GET" and r["path"] == f"/api/v10/channels/{cid}/messages"]


def chk_history(q):
    cid = q1(q, "channel")
    hits = [r for r in history_reqs(cid) if parse_qs(r["query"]).get("limit") == ["50"]]
    return bool(hits), f"{len(hits)} GET /channels/{cid}/messages?limit=50"


def chk_sent(q):
    cid, text = q1(q, "channel"), q1(q, "text")
    for r in api_requests():
        if r["method"] != "POST" or r["path"] != f"/api/v10/channels/{cid}/messages":
            continue
        try:
            b = json.loads(r["body"])
        except ValueError:
            continue
        if b.get("content") != text:
            continue
        bad = []
        if not isinstance(b.get("nonce"), str) or not b["nonce"].isdigit():
            bad.append(f"nonce {b.get('nonce')!r}")
        if b.get("tts") is not False:
            bad.append("tts")
        if not r["headers"].get("content-type", "").startswith("application/json"):
            bad.append("Content-Type")
        return not bad, "; ".join(bad) or "ok"
    return False, f"nenhum POST com {text!r}"


def after_trigger(kind):
    with lock:
        t = state["trigger"]
        if t is None or t["kind"] != kind:
            return None, None, f"sem gatilho {kind}"
        later = [c for c in state["conns"] if c.n > t["conn"]]
        return t, later, None


def resume_problems(t, c, old):
    bad = []
    if c.first_op != 6:
        bad.append(f"a conexão nova começou com op {c.first_op}, não RESUME")
        return bad
    r = c.resume or {}
    if r.get("token") != TOKEN:
        bad.append("token do RESUME")
    if r.get("session_id") != t["session"]:
        bad.append("session_id do RESUME")
    if r.get("seq") != t["seq"]:
        bad.append(f"seq do RESUME {r.get('seq')} (o último entregue foi {t['seq']})")
    if c.path.rstrip("/") != "/retomar":
        bad.append(f"RESUME em {c.path!r}, não no resume_gateway_url")
    if parse_qs(c.query) != {"v": ["10"], "encoding": ["json"], "compress": ["zlib-stream"]}:
        bad.append(f"query {c.query!r}")
    if old.client_close in (1000, 1001):
        bad.append(f"a conexão velha fechou com {old.client_close} (o Discord encerra a sessão)")
    bad += slow_start(c)
    if not c.resumed:
        bad.append("o servidor recusou o RESUME")
    elif c.replayed != t.get("missed", 0) + t.get("extra", 0):
        bad.append(f"{c.replayed} evento(s) reenviados, esperava {t.get('missed', 0)}")
    return bad


def chk_resume(q):
    t, later, err = after_trigger(q1(q, "kind"))
    if err:
        return False, err
    if not later:
        return False, "ainda não reconectou"
    with lock:
        old = state["conns"][t["conn"]]
    bad = resume_problems(t, later[0], old)
    if len(later) > 1:
        bad.append(f"{len(later)} conexões depois do gatilho")
    return not bad, "; ".join(bad) or f"ok ({(later[0].opened - t['t']) * 1000:.0f} ms)"


def chk_fresh(q):
    t, later, err = after_trigger("op9")
    if err:
        return False, err
    if not later:
        return False, "ainda não reconectou"
    c, bad = later[0], []
    if c.first_op != 2:
        bad.append(f"a conexão nova começou com op {c.first_op}, não IDENTIFY")
    if c.path != "/":
        bad.append(f"IDENTIFY em {c.path!r}: sessão nova vai no gateway, não no resume_gateway_url")
    bad += slow_start(c)
    gap = (c.opened - t["t"]) * 1000
    if gap < float(q1(q, "min_ms", "0")):
        bad.append(f"voltou {gap:.0f} ms depois do op 9 (sem esperar)")
    with lock:
        s = state["session"]
    if s is None or s.id == t["session"] or not c.ready:
        bad.append("sem sessão nova")
    return not bad, "; ".join(bad) or f"ok ({gap:.0f} ms)"


def chk_zombie(q):
    t, later, err = after_trigger("noack")
    if err:
        return False, err
    with lock:
        old = state["conns"][t["conn"]]
    if old.closed is None:
        return False, "a conexão sem ACK continua aberta"
    bad = []
    unacked = [h for h in old.heartbeats if h[0] >= t["t"]]
    if not unacked:
        bad.append("nenhum heartbeat sem ACK")
    elif (old.closed - unacked[0][0]) * 1000 > HB_MS * 2.5:
        bad.append(f"demorou {(old.closed - unacked[0][0]) * 1000:.0f} ms para largar a conexão")
    if len(unacked) > 1:
        bad.append(f"{len(unacked)} heartbeats sem ACK antes de largar")
    if old.server_close is not None:
        bad.append("quem fechou foi o servidor")
    if not later:
        bad.append("ainda não reconectou")
    else:
        bad += resume_problems(t, later[0], old)
    return not bad, "; ".join(bad) or "ok"


def chk_ratelimit(q):
    cid, ms = q1(q, "channel"), float(q1(q, "ms", "0"))
    with lock:
        armed = state["rate429"].get(f"/channels/{cid}/messages", {}).get("armed", 1e9)
    reqs = [r for r in history_reqs(cid) if r["t"] >= armed]
    if len(reqs) < 2:
        return False, f"{len(reqs)} pedido(s)"
    bad = []
    if len(reqs) != 2:
        bad.append(f"{len(reqs)} pedidos (esperava 2: o 429 e a nova tentativa)")
    if reqs[0].get("status") != 429 or reqs[1].get("status") != 200:
        bad.append(f"respostas {[r.get('status') for r in reqs]}")
    gap = (reqs[1]["t"] - reqs[0]["t"]) * 1000
    if gap < ms:
        bad.append(f"tentou de novo {gap:.0f} ms depois (retry_after {ms:.0f} ms)")
    if reqs[1]["headers"].get("x-failed-requests") != "1":
        bad.append(f"X-Failed-Requests {reqs[1]['headers'].get('x-failed-requests')!r}")
    return not bad, "; ".join(bad) or f"ok ({gap:.0f} ms)"


def chk_no_reconnect(q):
    t, later, err = after_trigger("close")
    if err:
        return False, err
    if t["code"] != 4004:
        return False, "o último gatilho não foi o 4004"
    if later:
        return False, f"{len(later)} conexão(ões) depois do 4004"
    waited = (now() - t["t"]) * 1000
    if waited < float(q1(q, "min_ms", "0")):
        return False, f"só {waited:.0f} ms desde o 4004"
    return True, f"ok ({waited:.0f} ms sem conexão)"


def chk_op8(q):
    """op 8: `user` was asked for in exactly `times` requests (0 = never asked)."""
    uid, times = int(q1(q, "user", "0")), int(q1(q, "times", "1"))
    with lock:
        n = sum(1 for ids in state["op8"] if uid in ids)
        seen = list(state["op8"])
    if n != times:
        return False, f"pedido em {n} op 8 (esperado {times}); op 8 recebidos: {seen}"
    return True, f"ok ({n})"


CHECKS = {"identify": chk_identify, "heartbeat": chk_heartbeat, "rest": chk_rest, "history": chk_history,
          "sent": chk_sent, "resume": chk_resume, "fresh": chk_fresh, "zombie": chk_zombie,
          "ratelimit": chk_ratelimit, "no_reconnect": chk_no_reconnect, "op8": chk_op8}


# --- Control actions -------------------------------------------------------------------


def set_trigger(kind, **extra):
    s, c = state["session"], state["live"]
    state["trigger"] = {"kind": kind, "conn": c.n if c else len(state["conns"]) - 1, "t": now(),
                        "seq": s.seq if s else None, "session": s.id if s else None, **extra}
    return c


def ctl(name, q):
    cid = int(q1(q, "channel", str(GERAL)))
    if name == "message":
        return dispatch("MESSAGE_CREATE", as_event(remember(message(cid, BIA, q1(q, "text", "")))))
    if name == "burst":
        with lock:
            for i in range(int(q1(q, "n", "10"))):
                dispatch("MESSAGE_CREATE", as_event(remember(message(cid, CAIO, f"{q1(q, 'prefix', 'rajada')} {i + 1}"))))
        return True
    if name == "voz":
        uid = int(q1(q, "user", str(BOT2)))
        return dispatch("VOICE_STATE_UPDATE", {**voice_state(uid), "guild_id": str(GUILD),
                                               "member": {"user": user(uid), **member()}})
    if name == "big":
        e = as_event(remember(message(cid, BIA, q1(q, "text", "grande"))))
        e["x_padding"] = base64.b64encode(os.urandom(150_000)).decode()
        return dispatch("MESSAGE_CREATE", e)
    if name in ("split", "fragment"):
        with lock:
            state[name] = int(q1(q, "parts", "3"))
        return True
    if name == "close":
        code, missed = int(q1(q, "code", "4000")), int(q1(q, "missed", "0"))
        with lock:
            c = set_trigger("close", code=code, missed=missed)
            state["live"] = None
            if c:
                c.close(code, "falso")
            for i in range(missed):
                dispatch("MESSAGE_CREATE", as_event(remember(message(cid, BIA, f"perdida {i + 1}"))), only_store=True)
        return c is not None
    if name == "op7":
        with lock:
            c = set_trigger("op7")
            return c is not None and c.send({"op": 7, "d": None})
    if name == "op9":
        resumable = q1(q, "resumable", "0") == "1"
        with lock:
            c = set_trigger("op9")
            if not resumable and state["session"] is not None:
                state["session"].valid = False
            return c is not None and c.send({"op": 9, "d": resumable})
    if name == "noack":
        with lock:
            c = set_trigger("noack")
            if c:
                c.noack_at = now()
        return c is not None
    if name == "rate429":
        with lock:
            state["rate429"][f"/channels/{cid}/messages"] = {
                "count": int(q1(q, "count", "1")), "retry_after": float(q1(q, "retry_after", "0.5")), "armed": now()}
        return True
    if name == "echo":
        state["echo_ms"] = int(q1(q, "ms", "0"))
        return True
    if name == "trafego":
        with lock:
            state["trafego"] = q1(q, "on", "1") == "1"
        return True
    return None


def remember(m):
    with lock:
        messages.setdefault(int(m["channel_id"]), []).append(m)
    return m


def summary():
    lines = []
    with lock:
        for name, (ok, why) in sorted(state["checks"].items()):
            if not ok:
                lines.append(f"check {name}: {why}")
        unknown = sorted({f"{r['method']} {r['path']}" for r in state["requests"] if r.get("status") == 404})
        lines += [f"unknown REST path (404): {u}" for u in unknown]
        lines.append(f"{len(state['conns'])} gateway connection(s), {len(api_requests())} REST request(s)")
    return lines


# --- HTTP ------------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, obj=None, headers=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlsplit(self.path)
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return gateway(self, u.path, u.query)
        if u.path.startswith("/ctl/"):
            return self.control(u)
        if u.path.startswith("/cdn/") and CONTA is not None:
            return self.cdn(u)
        self.rest("GET", u)

    def cdn(self, u):
        """The CDN and the media proxy (the QA build sends cdn.discordapp.com and
        media.discordapp.net here): a generated PNG of the size asked for."""
        q = parse_qs(u.query)
        m = re.search(r"_(\d+)x(\d+)\.png$", u.path)
        w, h = (int(m.group(1)), int(m.group(2))) if m else (128, 128)
        if "width" in q and "height" in q:
            w, h = int(q1(q, "width")), int(q1(q, "height"))
        elif "size" in q:
            w = h = int(q1(q, "size"))
        with lock:
            state["sent"]["cdn"] = state["sent"].get("cdn", 0) + 1
        body = CG.png(w, h, u.path)
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rest("POST", urlsplit(self.path))

    def do_PUT(self):
        self.rest("PUT", urlsplit(self.path))

    def do_PATCH(self):
        self.rest("PATCH", urlsplit(self.path))

    def do_DELETE(self):
        self.rest("DELETE", urlsplit(self.path))

    def control(self, u):
        q = parse_qs(u.query)
        name = u.path[len("/ctl/"):]
        if name.startswith("check/"):
            f = CHECKS.get(name[len("check/"):])
            if f is None:
                return self.reply(404, {"ok": False, "why": "check desconhecido"})
            ok, why = f(q)
            key = name[len("check/"):] + ("?" + u.query if u.query else "")
            with lock:
                state["checks"][key] = (ok, why)
            return self.reply(200, {"ok": ok, "why": why})
        if name == "summary":
            return self.reply(200, {"lines": summary()})
        if name == "conta":
            with lock:
                return self.reply(200, {"ok": CONTA is not None, "sent": dict(state["sent"]), "sub": state["sub"],
                                        "requests": len(state["requests"])})
        if name == "state":
            with lock:
                conns = [{"n": c.n, "path": c.path, "opened": round(c.opened, 3), "hello": c.hello_at,
                          "first_op": c.first_op, "hb": [(round(t, 3), d, s) for t, d, s in c.heartbeats],
                          "ops": [(round(t, 3), op) for t, op, _ in c.ops], "client_close": c.client_close,
                          "server_close": c.server_close, "closed": c.closed, "resumed": c.resumed}
                         for c in state["conns"]]
                reqs = [{"t": round(r["t"], 3), "m": r["method"], "p": r["path"], "q": r["query"],
                         "s": r.get("status")} for r in state["requests"]]
            return self.reply(200, {"conns": conns, "requests": reqs})
        r = ctl(name, q)
        if r is None:
            return self.reply(404, {"ok": False})
        self.reply(200, {"ok": bool(r)})

    def rest(self, method, u):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        rec = {"t": now(), "method": method, "path": u.path, "query": u.query,
               "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body.decode(errors="replace")}
        with lock:
            state["requests"].append(rec)
        status, obj, headers, after = self.route(method, u, body)
        rec["status"] = status
        rl = {"X-RateLimit-Limit": "5", "X-RateLimit-Remaining": "4", "X-RateLimit-Reset-After": "1.000",
              "X-RateLimit-Bucket": "falso"}
        rl.update(headers)
        self.reply(status, obj, rl)
        if after:
            after()

    def route(self, method, u, body):
        if self.headers.get("Authorization") != TOKEN:
            return 401, {"message": "401: Unauthorized", "code": 0}, {}, None
        p = u.path
        if p.startswith("/api/v10/"):
            p = p[len("/api/v10"):]
        elif p.startswith("/api/v9/"):
            p = p[len("/api/v9"):]
        else:
            return 404, {"message": "404: Not Found", "code": 0}, {}, None
        parts = p.strip("/").split("/")
        with lock:
            rl = state["rate429"].get(p)
            if method == "GET" and rl and rl["count"] > 0:
                rl["count"] -= 1
                ra = rl["retry_after"]
                return 429, {"message": "You are being rate limited.", "retry_after": ra, "global": False, "code": 0}, \
                    {"Retry-After": str(max(1, int(ra + 0.999))), "X-RateLimit-Remaining": "0",
                     "X-RateLimit-Reset-After": f"{ra:.3f}", "X-RateLimit-Scope": "user"}, None
        if CONTA is not None and len(parts) == 3 and parts[0] == "channels" and parts[2] == "messages" and method == "GET":
            cid = int(parts[1]) if parts[1].isdigit() else 0
            if cid not in CONTA.channel_info:
                return 404, {"message": "Unknown Channel", "code": 10003}, {}, None
            q = parse_qs(u.query)
            if "after" in q or "around" in q:
                return 200, [], {}, None
            return 200, CONTA.history(cid, before=q1(q, "before"), limit=min(100, int(q1(q, "limit", "50")))), {}, None
        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "messages":
            cid = int(parts[1]) if parts[1].isdigit() else 0
            if cid not in messages:
                return 404, {"message": "Unknown Channel", "code": 10003}, {}, None
            if method == "GET":
                q = parse_qs(u.query)
                if any(k in q for k in ("before", "after", "around")):
                    return 200, [], {}, None
                return 200, list(reversed(messages[cid][-50:])), {}, None
            if method == "POST":
                try:
                    b = json.loads(body)
                except ValueError:
                    return 400, {"message": "Invalid JSON", "code": 50109}, {}, None
                m = remember(message(cid, ME, b.get("content", ""), nonce=b.get("nonce")))
                ev = as_event(m)

                def echo():
                    ms = state["echo_ms"]
                    if ms:
                        threading.Timer(ms / 1000, dispatch, ("MESSAGE_CREATE", ev)).start()
                    else:
                        dispatch("MESSAGE_CREATE", ev)
                return 200, m, {}, echo
        if len(parts) == 5 and parts[0] == "channels" and parts[2] == "messages" and parts[4] == "ack":
            return 200, {"token": None}, {}, None
        if p == "/read-states/ack-bulk":
            return 204, None, {}, None
        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "typing":
            return 204, None, {}, None
        if p.startswith("/users/@me/settings-proto/"):
            return 200, {"settings": ""}, {}, None
        if p == "/sticker-packs":
            return 200, {"sticker_packs": []}, {}, None
        if p.startswith("/users/@me/mentions"):
            return 200, [], {}, None
        return 404, {"message": "404: Not Found", "code": 0}, {}, None


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def main():
    global PORT, CONTA, CG
    args = sys.argv[1:]
    if "--conta" in args:
        if args[args.index("--conta") + 1] != "grande":
            sys.exit("--conta: só existe a grande")
        seed = int(args[args.index("--semente") + 1]) if "--semente" in args else 52
        CG, CONTA = load_conta(seed)
        threading.Thread(target=trafego, daemon=True).start()
    server = Server(("127.0.0.1", 0), Handler)
    PORT = server.server_address[1]
    print(PORT, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
