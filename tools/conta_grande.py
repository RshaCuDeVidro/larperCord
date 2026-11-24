"""A big fake Discord account for tools/discord_falso.py --conta grande (QA_SUITE=conta-grande,
tools/ram_conta_grande.sh).

The size follows the account that showed the real memory cost (52 servers, ~2,450 channels):
the READY has the servers with their channels, roles, emojis and stickers, a few hundred DMs
and group DMs, friends, read states and per-server notification settings; READY_SUPPLEMENTAL
has the presences and members; opening a channel answers op 14 with a 100-member list, op 8
with the members asked for, and the history with pages of 50 messages (replies, mentions,
reactions, embeds, image attachments). While connected there is background traffic: presences,
member list updates, messages and typing, at the pace of a busy account.

Everything is generated from a seed: the same seed gives the same account, no real data. The
images (avatars, icons, emojis, attachments) are small PNGs made here, served by the fake server
on 127.0.0.1 (the QA build sends the CDN there; see src/net/enderecos.zig).
"""
import datetime
import random
import struct
import zlib

EPOCH = 1420070400000
# Snowflakes of the account: the servers were joined over the years, messages are recent.
T_OLD = 1_500_000_000_000
T_NOW = 1_795_000_000_000

SYLL = ["ka", "lu", "mi", "ro", "ta", "ne", "vo", "si", "da", "pe", "zu", "bri", "chi", "fo", "gal",
        "jun", "ke", "lin", "mar", "nox", "pi", "qua", "ru", "sol", "tri", "vel", "xa", "yo", "zen"]
WORDS = ("o a de que e do da em um para é com não uma os no se na por mais as dos como mas foi ao ele "
         "das tem à seu sua ou ser quando muito há nos já está eu também só pelo pela até isso ela entre "
         "era depois sem mesmo aos ter seus quem nas me esse eles estão você tinha foram essa num nem "
         "suas meu às minha têm numa pelos elas havia seja qual será nós tenho lhe deles essas esses "
         "build release servidor canal mensagem jogo partida ranked patch bug log commit deploy tema "
         "mapa fase boss loot raid stream clipe meme print arquivo config teste amanhã hoje agora").split()
GAMES = ["Hollow Lantern", "Starfall Tactics", "Pixel Kart 3", "Deep Rock Drill", "Moonlit Farm",
         "Arena of Echoes", "Signal Lost", "Cobalt Racing", "Dungeon Bakery", "Orbital Drift"]
FEATURES = ["COMMUNITY", "NEWS", "INVITE_SPLASH", "ANIMATED_ICON", "BANNER", "ROLE_ICONS", "WELCOME_SCREEN_ENABLED",
            "MEMBER_VERIFICATION_GATE_ENABLED", "PREVIEW_ENABLED", "THREADS_ENABLED", "AUTO_MODERATION",
            "SOUNDBOARD", "GUILD_ONBOARDING", "VANITY_URL", "DISCOVERABLE", "ENABLED_DISCOVERABLE_BEFORE",
            "GUILD_SERVER_GUIDE", "CHANNEL_ICON_EMOJIS_GENERATED", "NEW_THREAD_PERMISSIONS", "TEXT_IN_VOICE_ENABLED"]
UNICODE_EMOJI = ["👍", "😂", "❤️", "🔥", "😭", "👀", "🎉", "💀", "🙏", "✅", "🤔", "😎"]


def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).isoformat(timespec="microseconds")


def snow(ms, n):
    return ((int(ms) - EPOCH) << 22) | (n & 0x3FFFFF)


def ms_of(sid):
    return (sid >> 22) + EPOCH


def name(r, parts=(2, 4)):
    return "".join(r.choice(SYLL) for _ in range(r.randint(*parts)))


def sentence(r, lo, hi):
    return " ".join(r.choice(WORDS) for _ in range(r.randint(lo, hi)))


def hash32(r):
    return "%032x" % r.getrandbits(128)


def perms(r):
    return str(r.getrandbits(48))


class Conta:
    """The account. `rng(kind, i)` gives the same numbers for the same thing every time."""

    def __init__(self, seed=52, guilds=52, channels=2450, dms=280, groups=20, friends=150):
        self.seed = seed
        r = self.rng("conta", 0)
        self.me = snow(T_OLD - 86400_000 * 400, 1)
        # Everyone who shows up somewhere (members, authors, friends): 9,000 people.
        self.people = [snow(T_OLD - r.randint(0, 86400_000 * 1500), 1000 + i) for i in range(9000)]
        self._users = {}
        self.guild_list = []
        self.channel_info = {}  # channel id -> (guild id or 0, kind, last_message_id)
        self._plan(r, guilds, channels)
        self._dms(r, dms, groups, friends)
        self._history = {}

    def rng(self, kind, i):
        return random.Random(f"{self.seed}:{kind}:{i}")

    # --- People ---------------------------------------------------------------------------

    def user(self, uid):
        u = self._users.get(uid)
        if u is None:
            r = self.rng("user", uid)
            un = name(r) + ("." + name(r, (1, 2)) if r.random() < 0.4 else "") + (str(r.randint(1, 99)) if r.random() < 0.3 else "")
            u = {"id": str(uid), "username": un[:32], "global_name": (un.capitalize() + (" " + name(r, (2, 3)).capitalize() if r.random() < 0.5 else ""))[:32] if r.random() < 0.8 else None,
                 "avatar": hash32(r) if r.random() < 0.75 else None, "discriminator": "0", "public_flags": r.choice([0, 0, 0, 64, 128, 256, 4194304]),
                 "avatar_decoration_data": {"asset": "a_" + hash32(r), "sku_id": str(snow(T_OLD, uid & 0xFF)), "expires_at": None} if r.random() < 0.08 else None,
                 "primary_guild": {"identity_guild_id": str(self.guild_list[r.randrange(len(self.guild_list))]["id"]) if self.guild_list else None,
                                   "identity_enabled": True, "tag": name(r, (1, 2))[:4].upper(), "badge": hash32(r)} if r.random() < 0.1 else None,
                 "collectibles": None, "display_name_styles": None, "clan": None, "bot": r.random() < 0.02}
            if uid == self.me:
                u.update(username="qa.eu", global_name="QA Eu", bot=False)
            self._users[uid] = u
        return u

    def presence(self, uid, r):
        status = r.choice(["online", "online", "online", "idle", "dnd"])
        acts = []
        if r.random() < 0.35:
            acts.append({"type": 4, "name": "Custom Status", "state": sentence(r, 2, 7), "id": "custom",
                         "created_at": int(T_NOW - r.randint(0, 86400_000)), "emoji": {"name": r.choice(UNICODE_EMOJI)}})
        if r.random() < 0.3:
            g = r.choice(GAMES)
            acts.append({"type": 0, "name": g, "id": hash32(r)[:16], "application_id": str(snow(T_OLD, GAMES.index(g))),
                         "created_at": int(T_NOW - r.randint(0, 3600_000)), "timestamps": {"start": int(T_NOW - r.randint(0, 7200_000))},
                         "details": sentence(r, 2, 4), "state": sentence(r, 1, 3),
                         "assets": {"large_image": str(snow(T_OLD, 7)), "large_text": g}})
        elif r.random() < 0.08:
            acts.append({"type": 2, "name": "Spotify", "id": "spotify:1", "flags": 48, "created_at": int(T_NOW),
                         "details": sentence(r, 2, 4), "state": name(r).capitalize(), "sync_id": hash32(r)[:22],
                         "timestamps": {"start": int(T_NOW - 60_000), "end": int(T_NOW + 120_000)},
                         "assets": {"large_image": "spotify:" + hash32(r)[:24], "large_text": sentence(r, 1, 3)},
                         "party": {"id": "spotify:" + str(uid)}})
        return {"user": {"id": str(uid)}, "status": status, "client_status": {r.choice(["desktop", "mobile", "web"]): status},
                "activities": acts, "broadcast": None}

    def member(self, gid, uid, r=None):
        r = r or self.rng("member", (gid, uid))
        g = self.guilds[gid]
        roles = [x["id"] for x in r.sample(g["roles"][1:], min(len(g["roles"]) - 1, r.choice([0, 1, 1, 2, 3, 5])))]
        return {"user": self.user(uid), "roles": roles, "nick": name(r).capitalize() if r.random() < 0.25 else None,
                "avatar": hash32(r) if r.random() < 0.05 else None, "banner": None,
                "joined_at": iso(T_OLD + r.randint(0, T_NOW - T_OLD)), "premium_since": iso(T_NOW - 86400_000 * 30) if r.random() < 0.03 else None,
                "deaf": False, "mute": False, "pending": False, "flags": r.choice([0, 0, 2, 10]), "communication_disabled_until": None,
                "avatar_decoration_data": None, "collectibles": None}

    # --- Servers --------------------------------------------------------------------------

    def _plan(self, r, n_guilds, n_channels):
        # A few huge communities, some large, the rest small and medium (like a real account).
        sizes = ([r.randint(180, 260) for _ in range(4)] + [r.randint(70, 120) for _ in range(8)]
                 + [r.randint(25, 50) for _ in range(15)] + [r.randint(6, 20) for _ in range(n_guilds - 27)])
        sizes = sizes[:n_guilds]
        # Exactly the channel count asked for: the difference goes to the biggest.
        sizes[0] += n_channels - sum(sizes)
        self.guilds = {}
        n = 0
        for gi, size in enumerate(sizes):
            gr = self.rng("guild", gi)
            joined = T_OLD + gr.randint(0, 86400_000 * 1200)
            gid = snow(joined - 86400_000 * gr.randint(10, 900), 100 + gi)
            tier = 3 if gi < 4 else 2 if gi < 12 else 1 if gi < 27 else 0
            members_total = [gr.randint(40, 600), gr.randint(1500, 12000), gr.randint(20000, 120000), gr.randint(200000, 900000)][tier]
            n_roles = [gr.randint(4, 15), gr.randint(20, 60), gr.randint(60, 150), gr.randint(150, 250)][tier]
            n_emojis = [gr.randint(0, 30), gr.randint(30, 100), gr.randint(100, 250), gr.randint(250, 500)][tier]
            n_stickers = [gr.randint(0, 5), gr.randint(5, 15), gr.randint(15, 30), gr.randint(30, 60)][tier]
            g = {"id": gid, "tier": tier, "joined": joined, "member_count": members_total,
                 "name": (name(gr, (2, 3)).capitalize() + " " + name(gr, (2, 3)).capitalize())[:40]}
            g["roles"] = [{"id": str(gid), "name": "@everyone", "description": None, "permissions": "2248473465835073",
                           "position": 0, "color": 0, "colors": {"primary_color": 0, "secondary_color": None, "tertiary_color": None},
                           "hoist": False, "managed": False, "mentionable": False, "icon": None, "unicode_emoji": None, "flags": 0}]
            for ri in range(n_roles):
                rid = snow(joined + ri * 1000, 200 + ri)
                color = gr.choice([0, 0, gr.getrandbits(24)])
                managed = gr.random() < 0.08
                g["roles"].append({"id": str(rid), "name": (name(gr) + (" " + name(gr) if gr.random() < 0.3 else ""))[:30],
                                   "description": None, "permissions": perms(gr), "position": n_roles - ri, "color": color,
                                   "colors": {"primary_color": color, "secondary_color": None, "tertiary_color": None},
                                   "hoist": gr.random() < 0.12, "managed": managed, "mentionable": gr.random() < 0.2,
                                   "icon": hash32(gr) if gr.random() < 0.05 else None, "unicode_emoji": None, "flags": 0,
                                   **({"tags": {"bot_id": str(self.people[gr.randrange(9000)])}} if managed else {})})
            g["emojis"] = [{"id": str(snow(joined + ei * 7000, 300 + ei)), "name": (name(gr) + ("_" + name(gr, (1, 2)) if gr.random() < 0.4 else ""))[:32],
                            "roles": [], "require_colons": True, "managed": False, "animated": gr.random() < 0.3, "available": True}
                           for ei in range(n_emojis)]
            g["stickers"] = [{"id": str(snow(joined + si * 9000, 400 + si)), "name": name(gr)[:30], "tags": gr.choice(UNICODE_EMOJI),
                              "type": 2, "format_type": gr.choice([1, 1, 2, 4]), "description": sentence(gr, 2, 8),
                              "asset": "", "available": True, "guild_id": str(gid)} for si in range(n_stickers)]
            g["channels"] = self._channels(gr, g, size, n)
            n += size
            # Who shows up in this server (authors, the member list): from the same 9,000 people.
            pool = min(members_total, [60, 400, 900, 1500][tier])
            g["pool"] = gr.sample(self.people, pool)
            self.guilds[gid] = g
            self.guild_list.append(g)

    def _channels(self, r, g, size, base):
        gid = g["id"]
        out = []
        n_cat = max(1, size // 9)
        cats = []
        ows = lambda: [{"id": r.choice(g["roles"])["id"], "type": 0, "allow": perms(r), "deny": perms(r)}  # noqa: E731
                       for _ in range(r.choice([0, 0, 1, 2, 3, 5, 8]))]
        for ci in range(n_cat):
            cid = snow(g["joined"] - 86400_000 * 5 + ci, (base + len(out)) & 0x3FFFFF)
            cats.append(cid)
            out.append({"id": str(cid), "type": 4, "name": sentence(r, 1, 2)[:25].upper(), "position": ci,
                        "permission_overwrites": ows(), "flags": 0, "version": 0})
        pos = {c: 0 for c in cats}
        while len(out) < size:
            parent = r.choice(cats)
            cid = snow(g["joined"] - 86400_000 * 4 + len(out) * 997, (base + len(out)) & 0x3FFFFF)
            kind = r.choices([0, 2, 5, 15, 13], weights=[70, 18, 4, 5, 2])[0]
            last = snow(T_NOW - r.randint(0, 86400_000 * 90), r.getrandbits(12)) if kind in (0, 5, 15) else None
            ch = {"id": str(cid), "type": kind, "name": "-".join(r.choice(WORDS) for _ in range(r.randint(1, 3)))[:30],
                  "position": pos[parent], "parent_id": str(parent), "permission_overwrites": ows(), "flags": 0, "version": 0,
                  "icon_emoji": {"id": None, "name": r.choice(UNICODE_EMOJI)}, "theme_color": None}
            pos[parent] += 1
            if kind in (0, 5):
                ch.update(topic=sentence(r, 3, 40) if r.random() < 0.6 else None, nsfw=False, rate_limit_per_user=r.choice([0, 0, 0, 5, 30]),
                          last_message_id=str(last), last_pin_timestamp=iso(T_NOW - 86400_000 * r.randint(1, 400)) if r.random() < 0.5 else None)
            elif kind == 15:
                ch.update(topic=sentence(r, 3, 20), nsfw=False, rate_limit_per_user=0, last_message_id=str(last),
                          available_tags=[{"id": str(snow(T_OLD, k)), "name": r.choice(WORDS), "moderated": False, "emoji_id": None,
                                           "emoji_name": r.choice(UNICODE_EMOJI)} for k in range(r.randint(2, 8))],
                          default_reaction_emoji={"emoji_id": None, "emoji_name": "👍"}, default_sort_order=None, default_forum_layout=0)
            else:
                ch.update(bitrate=64000, user_limit=r.choice([0, 0, 5, 10, 99]), rtc_region=None, nsfw=False, rate_limit_per_user=0,
                          last_message_id=str(last) if r.random() < 0.3 else None)
            self.channel_info[cid] = (gid, kind, last)
            out.append(ch)
        return out

    def guild_ready(self, g):
        r = self.rng("guildready", g["id"])
        gid = g["id"]
        texts = [int(c["id"]) for c in g["channels"] if c["type"] == 0]
        voices = [int(c["id"]) for c in g["channels"] if c["type"] == 2]
        vs = []
        if voices and g["tier"] >= 2:
            for k in range(r.randint(3, 25)):
                vs.append({"user_id": str(r.choice(g["pool"])), "channel_id": str(r.choice(voices)), "session_id": hash32(r),
                           "deaf": False, "mute": False, "self_deaf": r.random() < 0.2, "self_mute": r.random() < 0.4,
                           "self_video": False, "suppress": False, "request_to_speak_timestamp": None})
        return {
            "id": str(gid),
            "properties": {"id": str(gid), "name": g["name"], "icon": hash32(r), "description": sentence(r, 5, 25) if g["tier"] >= 1 else None,
                           "splash": hash32(r) if g["tier"] >= 2 else None, "discovery_splash": None, "banner": hash32(r) if g["tier"] >= 2 else None,
                           "home_header": None, "owner_id": str(r.choice(self.people)), "application_id": None, "afk_channel_id": str(voices[0]) if voices else None,
                           "afk_timeout": 300, "system_channel_id": str(texts[0]) if texts else None, "system_channel_flags": 0,
                           "rules_channel_id": str(texts[1]) if len(texts) > 1 and g["tier"] >= 1 else None, "public_updates_channel_id": None,
                           "safety_alerts_channel_id": None, "vanity_url_code": name(r) if g["tier"] >= 3 else None,
                           "verification_level": r.randint(0, 3), "default_message_notifications": 1, "explicit_content_filter": 2,
                           "mfa_level": 0, "nsfw_level": 0, "premium_tier": g["tier"], "premium_progress_bar_enabled": False,
                           "preferred_locale": "pt-BR", "max_members": 1000000, "max_video_channel_users": 25, "max_stage_video_channel_users": 50,
                           "features": r.sample(FEATURES, [2, 6, 12, 18][g["tier"]]), "hub_type": None, "nsfw": False,
                           "latest_onboarding_question_id": None, "incidents_data": None, "clan": None},
            "channels": g["channels"], "roles": g["roles"], "emojis": g["emojis"], "stickers": g["stickers"],
            "threads": [], "stage_instances": [], "voice_states": vs, "activity_instances": [], "embedded_activities": [],
            "guild_scheduled_events": [{"id": str(snow(T_NOW, k)), "guild_id": str(gid), "name": sentence(r, 2, 5), "description": sentence(r, 5, 20),
                                        "scheduled_start_time": iso(T_NOW + 86400_000 * k), "scheduled_end_time": None, "privacy_level": 2,
                                        "status": 1, "entity_type": 2, "entity_id": None, "channel_id": str(voices[0]) if voices else None,
                                        "creator_id": str(r.choice(g["pool"])), "user_count": r.randint(1, 300), "image": None}
                                       for k in range(r.randint(0, 3) if g["tier"] >= 1 else 0)],
            "soundboard_sounds": [{"sound_id": str(snow(T_OLD, k)), "name": name(r), "volume": 1.0, "emoji_id": None,
                                   "emoji_name": r.choice(UNICODE_EMOJI), "guild_id": str(gid), "available": True, "user_id": str(r.choice(g["pool"]))}
                                  for k in range([0, 8, 24, 48][g["tier"]])],
            "application_command_counts": {"1": r.randint(0, 40), "2": r.randint(0, 5), "3": r.randint(0, 5)},
            "member_count": g["member_count"], "premium_subscription_count": [0, 2, 9, 30][g["tier"]],
            "joined_at": iso(g["joined"]), "lazy": True, "large": g["member_count"] > 250, "data_mode": "full", "version": T_NOW,
        }

    # --- DMs, friends ---------------------------------------------------------------------

    def _dms(self, r, dms, groups, friends):
        self.dm_list = []
        others = r.sample(self.people, dms + groups * 6 + friends)
        self.friends = others[:friends]
        k = friends
        for i in range(dms):
            uid = others[k]
            k += 1
            cid = snow(T_OLD + r.randint(0, T_NOW - T_OLD), 0x200000 + i)
            last = snow(T_NOW - r.randint(0, 86400_000 * 365), r.getrandbits(12))
            self.channel_info[cid] = (0, 1, last)
            self.dm_list.append({"id": str(cid), "type": 1, "recipient_ids": [str(uid)], "last_message_id": str(last), "flags": 0,
                                 "is_spam": False, "is_message_request": False, "is_message_request_timestamp": None, "safety_warnings": []})
        for i in range(groups):
            members = others[k:k + r.randint(2, 6)]
            k += 6
            cid = snow(T_OLD + r.randint(0, T_NOW - T_OLD), 0x210000 + i)
            last = snow(T_NOW - r.randint(0, 86400_000 * 120), r.getrandbits(12))
            self.channel_info[cid] = (0, 3, last)
            self.dm_list.append({"id": str(cid), "type": 3, "name": sentence(r, 1, 3) if r.random() < 0.6 else "", "icon": hash32(r) if r.random() < 0.3 else None,
                                 "owner_id": str(members[0]), "recipient_ids": [str(x) for x in members], "last_message_id": str(last),
                                 "flags": 0, "blocked_user_warning_dismissed": False})
        self.dm_users = sorted({int(x) for d in self.dm_list for x in d["recipient_ids"]} | set(self.friends))

    # --- READY ----------------------------------------------------------------------------

    def ready(self, session_id, resume_url, base_user):
        r = self.rng("ready", 0)
        read = []
        for cid, (gid, kind, last) in self.channel_info.items():
            if last is None or r.random() < 0.1:
                continue
            lr = last if r.random() < 0.7 else snow(ms_of(last) - r.randint(1, 86400_000 * 10), 1)
            read.append({"id": str(cid), "last_message_id": str(lr), "mention_count": r.choice([0] * 20 + [1, 2, 5]),
                         "last_pin_timestamp": iso(T_NOW - 86400_000 * r.randint(1, 500)), "flags": 0, "last_viewed": r.randint(3000, 4000)})
        ugs = []
        for g in self.guild_list:
            gr = self.rng("ugs", g["id"])
            chans = [c for c in g["channels"] if c["type"] in (0, 4)]
            ugs.append({"guild_id": str(g["id"]), "suppress_everyone": gr.random() < 0.3, "suppress_roles": gr.random() < 0.2,
                        "muted": gr.random() < 0.25, "mute_config": None, "mobile_push": True, "message_notifications": gr.choice([1, 2]),
                        "hide_muted_channels": False, "notify_highlights": 0, "flags": 0, "version": 1, "mute_scheduled_events": False,
                        "channel_overrides": [{"channel_id": c["id"], "muted": gr.random() < 0.5, "mute_config": None,
                                               "message_notifications": 3, "collapsed": gr.random() < 0.1, "flags": 0}
                                              for c in gr.sample(chans, min(len(chans), gr.choice([0, 2, 5, 12, 40])))]})
        rels = [{"id": str(u), "type": 1 if i < len(self.friends) - 12 else r.choice([2, 3, 4]), "nickname": None,
                 "user_id": str(u), "since": iso(T_OLD + r.randint(0, T_NOW - T_OLD)), "is_spam_request": False, "user_ignored": False}
                for i, u in enumerate(self.friends)]
        return {
            "v": 10, "user": base_user, "session_id": session_id, "session_type": "normal", "resume_gateway_url": resume_url,
            "guilds": [self.guild_ready(g) for g in self.guild_list],
            "private_channels": self.dm_list,
            # Like Discord (DEDUPE_USER_OBJECTS): everyone the READY_SUPPLEMENTAL mentions by
            # user_id comes here, once.
            "users": [self.user(u) for u in sorted(set(self.dm_users) | self.supplemental_people())],
            "relationships": rels,
            "merged_members": [[{**{k: v for k, v in self.member(g["id"], self.me).items() if k != "user"}, "user_id": str(self.me)}]
                               for g in self.guild_list],
            "read_state": {"entries": read, "partial": False, "version": 4000},
            "user_guild_settings": {"entries": ugs, "partial": False, "version": 900},
            "sessions": [{"session_id": session_id, "status": "online", "activities": [], "client_info": {"client": "web", "os": "linux", "version": 0}}],
            "connected_accounts": [{"type": t, "id": str(r.getrandbits(40)), "name": name(r), "visibility": 1, "friend_sync": False,
                                    "show_activity": True, "verified": True, "two_way_link": False, "metadata_visibility": 0}
                                   for t in ("github", "spotify", "steam")],
            # The experiment lists of a real READY (only their size matters here: the app does not read them).
            "experiments": [[r.getrandbits(32), r.randint(0, 30), r.randint(-1, 4), r.randint(-1, 1), r.randint(0, 3), r.randint(0, 9),
                             0, 0, 0, 0] for _ in range(1600)],
            "guild_experiments": [[r.getrandbits(32), None, r.randint(0, 20),
                                   [[[[r.randint(-1, 5), [{"s": r.randint(0, 5000), "e": r.randint(5000, 10000)}]] for _ in range(3)],
                                     [[r.getrandbits(32), [[r.randint(0, 99), r.randint(0, 99)]]]]]],
                                   [], [], 0, 0] for _ in range(320)],
            "consents": {"personalization": {"consented": False}}, "tutorial": None, "notification_settings": {"flags": 0},
            "geo_ordered_rtc_regions": ["brazil", "us-east", "us-south", "us-central", "buenos-aires"],
            "country_code": "BR", "guild_join_requests": [], "friend_suggestion_count": 0, "auth_session_id_hash": "falso",
            "analytics_token": "falso", "api_code_version": 1, "static_client_session_id": hash32(r), "explicit_content_scan_version": 2,
            "game_relationships": [], "required_action": None, "auth": {"authenticator_types": []},
        }

    def _supp_people(self, g):
        r = self.rng("supp", g["id"])
        return r.sample(g["pool"], min(len(g["pool"]), [8, 25, 40, 60][g["tier"]]))

    def supplemental_people(self):
        return {u for g in self.guild_list for u in self._supp_people(g)} | set(self.friends[:60])

    def supplemental(self):
        guilds, merged = [], []
        for g in self.guild_list:
            people = self._supp_people(g)
            pres = []
            for uid in people:
                p = self.presence(uid, self.rng("pres", uid))
                pres.append({"user_id": str(uid), "status": p["status"], "client_status": p["client_status"],
                             "activities": p["activities"], "broadcast": None})
            guilds.append(pres)
            merged.append([{**{k: v for k, v in self.member(g["id"], u).items() if k != "user"}, "user_id": str(u)} for u in people])
        friends = []
        for u in self.friends[:60]:
            p = self.presence(u, self.rng("pres", u))
            friends.append({"user_id": str(u), "status": p["status"], "client_status": p["client_status"], "activities": p["activities"]})
        return {"merged_presences": {"guilds": guilds, "friends": friends}, "merged_members": merged,
                "lazy_private_channels": [], "game_invites": [], "disclose": [],
                "guilds": [{"id": str(g["id"]), "voice_states": [], "embedded_activities": [], "activity_instances": []} for g in self.guild_list]}

    # --- After READY ----------------------------------------------------------------------

    def member_list(self, gid, channel_id):
        """GUILD_MEMBER_LIST_UPDATE with the first 100 rows (op 14 asks [[0, 99]])."""
        g = self.guilds.get(gid)
        if g is None:
            return None
        r = self.rng("lista", (gid, channel_id))
        online = [u for u in g["pool"] if self.rng("pres", u).random() < 0.6]
        hoisted = [ro for ro in g["roles"] if ro.get("hoist")][:6]
        items, groups = [], []
        by_group = {}
        for u in online:
            m = self.member(gid, u)
            grp = next((ro["id"] for ro in hoisted if ro["id"] in m["roles"]), "online")
            by_group.setdefault(grp, []).append(m)
        for gid_s in [ro["id"] for ro in hoisted] + ["online"]:
            ms = by_group.get(gid_s, [])
            if not ms:
                continue
            groups.append({"id": gid_s, "count": len(ms)})
            items.append({"group": {"id": gid_s, "count": len(ms)}})
            for m in ms:
                if len(items) >= 100:
                    break
                p = self.presence(int(m["user"]["id"]), self.rng("pres", int(m["user"]["id"])))
                items.append({"member": {**m, "presence": p}})
        offline = g["member_count"] - len(online)
        groups.append({"id": "offline", "count": max(0, offline)})
        return {"guild_id": str(gid), "id": "everyone" if r.random() < 0.5 else str(r.getrandbits(32)),
                "member_count": g["member_count"], "online_count": len(online) + [0, 300, 4000, 30000][g["tier"]],
                "groups": groups, "ops": [{"op": "SYNC", "range": [0, 99], "items": items[:100]}]}

    def members_chunk(self, gid, user_ids, nonce):
        if gid not in self.guilds:
            return None
        return {"guild_id": str(gid), "members": [self.member(gid, int(u)) for u in user_ids if str(u).isdigit()],
                "chunk_index": 0, "chunk_count": 1, "not_found": [], "nonce": nonce}

    def authors(self, cid):
        gid, kind, _ = self.channel_info[cid]
        if gid:
            return self.guilds[gid]["pool"]
        d = next(x for x in self.dm_list if int(x["id"]) == cid)
        return [int(x) for x in d["recipient_ids"]] + [self.me]

    def message(self, cid, mid, r, older=None, pool=None):
        gid, kind, _ = self.channel_info[cid]
        pool = pool or self.authors(cid)
        author = self.me if r.random() < 0.05 else r.choice(pool)
        text = sentence(r, 1, 14) if r.random() < 0.7 else sentence(r, 15, 70)
        mentions = []
        if r.random() < 0.15:
            who = r.choice(pool)
            text = f"<@{who}> " + text
            mentions.append(self.user(who))
        if r.random() < 0.06:
            text += "\n```zig\nconst x = " + str(r.randint(0, 999)) + ";\n" + "\n".join(sentence(r, 2, 8) for _ in range(r.randint(1, 6))) + "\n```"
        if gid and r.random() < 0.1 and self.guilds[gid]["emojis"]:
            e = r.choice(self.guilds[gid]["emojis"])
            text += f" <{'a' if e['animated'] else ''}:{e['name']}:{e['id']}>"
        m = {"type": 0, "content": text, "mentions": mentions, "mention_roles": [], "attachments": [], "embeds": [],
             "timestamp": iso(ms_of(mid)), "edited_timestamp": iso(ms_of(mid) + 60_000) if r.random() < 0.05 else None,
             "flags": 0, "components": [], "id": str(mid), "channel_id": str(cid), "author": self.user(author),
             "pinned": False, "mention_everyone": False, "tts": False}
        if r.random() < 0.1:
            w, h = r.choice([(640, 480), (1280, 720), (800, 1000), (1920, 1080), (512, 512)])
            aid = snow(ms_of(mid), 77)
            path = f"attachments/{cid}/{aid}/{name(r)}_{w}x{h}.png"
            m["attachments"].append({"id": str(aid), "filename": path.rsplit("/", 1)[1], "size": w * h // 3, "width": w, "height": h,
                                     "url": f"https://cdn.discordapp.com/{path}?ex=0&is=0&hm=0", "proxy_url": f"https://media.discordapp.net/{path}?ex=0&is=0&hm=0",
                                     "content_type": "image/png", "placeholder": hash32(r)[:24], "placeholder_version": 1})
        if r.random() < 0.08:
            url = f"https://example.org/{name(r)}/{name(r)}"
            m["content"] += " " + url
            m["embeds"].append({"type": "article", "url": url, "title": sentence(r, 3, 10), "description": sentence(r, 10, 40),
                                "provider": {"name": name(r).capitalize()}, "color": r.getrandbits(24),
                                "content_scan_version": 2})
        if r.random() < 0.2:
            m["reactions"] = [{"emoji": {"id": None, "name": e}, "count": r.randint(1, 30), "count_details": {"burst": 0, "normal": 1},
                               "burst_colors": [], "me_burst": False, "burst_me": False, "me": r.random() < 0.1, "burst_count": 0}
                              for e in r.sample(UNICODE_EMOJI, r.randint(1, 4))]
        if older is not None and r.random() < 0.15:
            m["type"] = 19
            m["message_reference"] = {"type": 0, "channel_id": str(cid), "message_id": older["id"], **({"guild_id": str(gid)} if gid else {})}
            m["referenced_message"] = older
        return m

    def history(self, cid, before=None, limit=50):
        """Up to 50 messages before `before` (newest first, like the API); 6 pages per channel."""
        info = self.channel_info.get(cid)
        if info is None or info[2] is None:
            return []
        msgs = self._history.get(cid)
        if msgs is None:
            r = self.rng("hist", cid)
            last = ms_of(info[2])
            msgs = []
            t = last - 300 * r.randint(60_000, 600_000)
            prev = None
            pool = self.authors(cid)
            for i in range(300):
                t += r.randint(5_000, 600_000)
                m = self.message(cid, snow(min(t, last), i), r, older=prev, pool=pool)
                msgs.append(m)
                prev = {k: v for k, v in m.items() if k != "referenced_message"}
            self._history[cid] = msgs
        if before is not None:
            msgs = [m for m in msgs if int(m["id"]) < int(before)]
        return list(reversed(msgs[-limit:]))

    def live_message(self, cid, mid, r):
        gid = self.channel_info[cid][0]
        m = self.message(cid, mid, r)
        if gid:
            m["guild_id"] = str(gid)
            m["member"] = {k: v for k, v in self.member(gid, int(m["author"]["id"])).items() if k != "user"}
        else:
            m["channel_type"] = self.channel_info[cid][1]
        return m

    def text_channels(self, gid):
        return [int(c["id"]) for c in self.guilds[gid]["channels"] if c["type"] == 0]


# --- PNG ----------------------------------------------------------------------------------


def png(w, h, seed):
    """A w×h PNG with a few colour bands (cheap to make, decodes like a real one)."""
    r = random.Random(seed)
    w, h = max(1, min(w, 2048)), max(1, min(h, 2048))
    cols = [bytes([r.randrange(256), r.randrange(256), r.randrange(256)]) for _ in range(4)]
    rows = []
    for y in range(h):
        c = cols[(y * 4) // h]
        line = bytearray(c * w)
        # A little noise so the image does not compress to nothing.
        for k in range(0, w * 3, 97):
            line[k] = (line[k] + y * 13) & 0xFF
        rows.append(b"\x00" + bytes(line))
    raw = zlib.compress(b"".join(rows), 6)

    def chunk(t, d):
        return struct.pack("!I", len(d)) + t + d + struct.pack("!I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")
