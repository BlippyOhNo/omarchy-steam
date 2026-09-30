#!/usr/bin/env python3
"""Steam data for the blip.steam bar widget, read from the local Steam client.

  steam.py games    -> {"user": {...}, "games": [...]}   (recent + library)
  steam.py friends  -> {"friends": [...]}                 (live online status)
  steam.py downloads -> {"downloads": [...]}              (active/paused downloads)
  steam.py storelists -> {"top": ..., "upcoming": ..., "new": ...}  (the store's lists, 50 each)
  steam.py store APPID -> {...}                           (a game's store page)

Games come from Steam's own caches, so no API key or sign-in is needed:
appinfo.vdf for names and types, the image cache (Steam keeps art for every
game in your library) for ownership, localconfig.vdf for last-played and
playtime, and the library folders for what's installed. Friends are the
account's cached friend list in localconfig.vdf, their status scraped from each
friend's public Steam Community mini-profile -- or, when STEAM_API_KEY is set,
the real friend list and presence from the Steam Web API.
"""
import html
import json
import os
import re
import struct
import sys
import threading
import time
import urllib.request
from urllib.parse import urlsplit



def find_steam():
    """The Steam install that has an account on it: native (~/.steam/root points at it) or Flatpak."""
    candidates = [
        os.path.realpath(os.path.expanduser("~/.steam/root")),
        os.path.expanduser("~/.local/share/Steam"),
        os.path.expanduser("~/.var/app/com.valvesoftware.Steam/.local/share/Steam"),
        os.path.realpath(os.path.expanduser("~/.steam/steam")),
    ]
    for path in candidates:
        if os.path.isfile(os.path.join(path, "config", "loginusers.vdf")):
            return path
    return candidates[1]


STEAM = find_steam()
CACHE = os.path.expanduser("~/.cache/blip-steam")
STEAMID64_BASE = 76561197960265728


# ---------- network ----------
# Byte ceilings per response. Timeouts only bound time, so a huge (or
# hostile) answer could otherwise fill memory here and then in the shell
# that collects this script's output.
KB, MB = 1024, 1024 * 1024
MAX_PROFILE = 256 * KB      # a friend's mini-profile page
MAX_JSON = 4 * MB           # Web API and store JSON answers
MAX_SEARCH = 2 * MB         # one page of store search results
MAX_IMAGE = 16 * MB         # description art converted from AVIF
MAX_OUTPUT = 8 * MB         # everything printed for the widget


def fetch(url, timeout=10, limit=MAX_JSON):
    """A URL's body, refused once it passes `limit` bytes."""
    with urllib.request.urlopen(url, timeout=timeout) as r:
        length = r.headers.get("Content-Length")
        if length and length.isdigit() and int(length) > limit:
            raise ValueError("response too large (%s bytes)" % length)
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("response too large (over %d bytes)" % limit)
    return data


# Description HTML is supplied by game publishers, so image URLs must stay on
# Steam's image CDNs. Redirects are checked too: validating only the first URL
# would still allow an approved host to redirect a request to localhost.
STEAM_IMAGE_HOSTS = frozenset({
    "cdn.akamai.steamstatic.com",
    "shared.akamai.steamstatic.com",
    "shared.fastly.steamstatic.com",
    "cdn.cloudflare.steamstatic.com",
    "shared.cloudflare.steamstatic.com",
    "steamcdn-a.akamaihd.net",
    "steamuserimages-a.akamaihd.net",
})


def validate_steam_image_url(url):
    """Reject non-HTTPS and non-Steam destinations in publisher content."""
    try:
        parsed = urlsplit(url)
        host = (parsed.hostname or "").lower().rstrip(".")
        port = parsed.port
    except (AttributeError, TypeError, ValueError):
        raise ValueError("invalid Steam image URL")
    if (parsed.scheme != "https" or host not in STEAM_IMAGE_HOSTS
            or parsed.username is not None or parsed.password is not None
            or port not in (None, 443)):
        raise ValueError("image URL is not on an approved Steam CDN")


class SteamImageRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_steam_image_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_steam_image(url, timeout=15, limit=MAX_IMAGE):
    """Fetch a bounded image only from approved Steam CDN URLs."""
    validate_steam_image_url(url)
    opener = urllib.request.build_opener(SteamImageRedirectHandler())
    with opener.open(url, timeout=timeout) as r:
        length = r.headers.get("Content-Length")
        if length and length.isdigit() and int(length) > limit:
            raise ValueError("response too large (%s bytes)" % length)
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("response too large (over %d bytes)" % limit)
    return data


def fetch_json(url, timeout=10, limit=MAX_JSON):
    data = json.loads(fetch(url, timeout, limit))
    if not isinstance(data, dict):
        raise ValueError("unexpected response")
    return data


def clip(value, n):
    """A string from a response, cut to n characters."""
    return value[:n] if isinstance(value, str) else ""


def obj(value):
    """A dict from a response, or an empty one."""
    return value if isinstance(value, dict) else {}


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def seq(value, n):
    """A list from a response, cut to n items."""
    return value[:n] if isinstance(value, list) else []


# ---------- text VDF ----------
def parse_text_vdf(text):
    tokens = re.finditer(r'"((?:[^"\\]|\\.)*)"|([{}])', text)
    root, stack, key = {}, [], None
    cur = root
    for m in tokens:
        if m.group(2) == "{":
            new = {}
            cur[key] = new
            stack.append(cur)
            cur, key = new, None
        elif m.group(2) == "}":
            cur = stack.pop() if stack else cur
        elif key is None:
            key = m.group(1)
        else:
            cur[key] = m.group(1).replace('\\"', '"').replace("\\\\", "\\")
            key = None
    return root


def read_vdf(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return parse_text_vdf(f.read())
    except OSError:
        return {}


def ci(d, key):
    """Case-insensitive dict lookup (Steam isn't consistent about key case)."""
    if not isinstance(d, dict):
        return {}
    if key in d:
        return d[key]
    low = key.lower()
    for k, v in d.items():
        if k.lower() == low:
            return v
    return {}


# ---------- binary appinfo.vdf ----------
def read_appinfo():
    path = os.path.join(STEAM, "appcache", "appinfo.vdf")
    with open(path, "rb") as f:
        d = f.read()
    magic, _ = struct.unpack_from("<II", d, 0)
    off, strtab = 8, None
    if magic >= 0x07564429:  # v29+: keys live in a string table at the end
        so, = struct.unpack_from("<q", d, 8)
        off = 16
        n, = struct.unpack_from("<I", d, so)
        pos, strtab = so + 4, []
        for _ in range(n):
            e = d.index(b"\0", pos)
            strtab.append(d[pos:e].decode("utf-8", "replace"))
            pos = e + 1

    def rkey(pos):
        if strtab is not None:
            i, = struct.unpack_from("<I", d, pos)
            return strtab[i], pos + 4
        e = d.index(b"\0", pos)
        return d[pos:e].decode("utf-8", "replace"), e + 1

    def rkv(pos):
        o = {}
        while True:
            t = d[pos]
            pos += 1
            if t == 8:
                return o, pos
            k, pos = rkey(pos)
            if t == 0:
                v, pos = rkv(pos)
            elif t == 1:
                e = d.index(b"\0", pos)
                v = d[pos:e].decode("utf-8", "replace")
                pos = e + 1
            elif t == 2:
                v, = struct.unpack_from("<i", d, pos)
                pos += 4
            elif t == 7:
                v, = struct.unpack_from("<Q", d, pos)
                pos += 8
            else:
                raise ValueError("appinfo value type %d" % t)
            o[k] = v

    # v28+ entry header: appid, size, infostate, lastupdated, token, sha1, changenumber, binary sha1
    header = 4 + 4 + 4 + 4 + 8 + 20 + 4 + (20 if magic >= 0x07564428 else 0)
    apps = {}
    while True:
        aid, = struct.unpack_from("<I", d, off)
        if aid == 0:
            break
        size, = struct.unpack_from("<I", d, off + 4)
        try:
            kv, _ = rkv(off + header)
            common = kv.get("appinfo", {}).get("common", {})
            apps[aid] = {"name": common.get("name", ""), "type": str(common.get("type", "")).lower()}
        except (ValueError, IndexError, struct.error):
            pass
        off += 8 + size
    return apps


# ---------- account ----------
def current_user():
    users = ci(read_vdf(os.path.join(STEAM, "config", "loginusers.vdf")), "users")
    best = None
    for sid, u in users.items():
        if not isinstance(u, dict):
            continue
        recent = ci(u, "MostRecent") == "1"
        ts = int(ci(u, "Timestamp") or 0)
        rank = (recent, ts)
        if best is None or rank > best[0]:
            best = (rank, sid, u)
    if not best:
        return None
    sid64 = int(best[1])
    return {
        "steamid": str(sid64),
        "accountid": str(sid64 - STEAMID64_BASE),
        "name": ci(best[2], "PersonaName") or ci(best[2], "AccountName") or "",
    }


def localconfig(user):
    return read_vdf(os.path.join(STEAM, "userdata", user["accountid"], "config", "localconfig.vdf"))


# ---------- images ----------
def art_for(appid):
    """Header (wide capsule) and icon images, local from Steam's library cache
    when it has them, else the store CDN."""
    base = os.path.join(STEAM, "appcache", "librarycache", str(appid))
    header = icon = ""
    try:
        for entry in os.scandir(base):
            if entry.is_dir():
                for name in ("header.jpg", "library_header.jpg"):
                    h = os.path.join(entry.path, name)
                    if not header and os.path.exists(h):
                        header = h
            elif entry.name == "header.jpg":
                header = entry.path
            elif re.fullmatch(r"[0-9a-f]{40}\.jpg", entry.name):
                icon = entry.path  # top-level <sha1>.jpg is the small app icon
    except OSError:
        pass
    if not header:
        header = "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/%d/header.jpg" % appid
    return header, icon


# ---------- games ----------
def installed_apps():
    out = set()
    folders = ci(read_vdf(os.path.join(STEAM, "steamapps", "libraryfolders.vdf")), "libraryfolders")
    paths = [STEAM] + [ci(v, "path") for v in folders.values() if isinstance(v, dict)]
    for p in paths:
        if not isinstance(p, str) or not p:
            continue
        try:
            for name in os.listdir(os.path.join(p, "steamapps")):
                m = re.match(r"appmanifest_(\d+)\.acf$", name)
                if m:
                    out.add(int(m.group(1)))
        except OSError:
            pass
    return out


def games():
    user = current_user()
    if not user:
        return {"error": "No Steam account found on this computer"}
    info = read_appinfo()
    apps = ci(ci(ci(ci(ci(localconfig(user), "UserLocalConfigStore"), "Software"), "Valve"), "Steam"), "apps")
    played = {}
    for k, v in apps.items() if isinstance(apps, dict) else []:
        if k.isdigit() and isinstance(v, dict):
            lp = int(ci(v, "LastPlayed") or 0)
            pt = int(ci(v, "Playtime") or 0)
            if lp or pt:
                played[int(k)] = (lp, pt)
    installed = installed_apps()
    try:
        cached = {int(x) for x in os.listdir(os.path.join(STEAM, "appcache", "librarycache")) if x.isdigit()}
    except OSError:
        cached = set()

    out = []
    for aid in cached | set(played) | installed:
        meta = info.get(aid)
        if not meta or meta["type"] != "game" or not meta["name"]:
            continue
        lp, pt = played.get(aid, (0, 0))
        header, icon = art_for(aid)
        out.append({
            "appid": aid,
            "name": meta["name"],
            "lastPlayed": lp,
            "playtime": pt,
            "installed": aid in installed,
            "header": header,
            "icon": icon,
        })
    out.sort(key=lambda g: (-g["lastPlayed"], g["name"].lower()))
    return {"user": user, "games": out}


# ---------- friends ----------
def fetch_status(accountid):
    # Keep urllib's default User-Agent: Steam answers custom and browser-like
    # ones with HTTP 500.
    req = urllib.request.Request("https://steamcommunity.com/miniprofile/%s" % accountid)
    page = fetch(req, timeout=8, limit=MAX_PROFILE).decode("utf-8", "replace")
    state = re.search(r'class="persona\s+([\w-]+)"', page)
    name = re.search(r'class="persona[^"]*">([^<]*)<', page)
    status = re.search(r'class="friend_status_[\w-]+">([^<]*)<', page)
    game = re.search(r'class="miniprofile_game_name">([^<]*)<', page)
    state = state.group(1)[:32] if state else "offline"
    status_text = html.unescape(status.group(1)).strip() if status else ""
    if state == "online" and re.search(r"away|snooze", status_text, re.I):
        state = "away"
    return {
        "state": state,
        "name": clip(html.unescape(name.group(1)).strip(), MAX_NAME) if name else "",
        "statusText": clip(status_text, MAX_NAME),
        "game": clip(html.unescape(game.group(1)).strip(), MAX_NAME) if game else "",
    }


API = "https://api.steampowered.com"
MAX_FRIENDS = 2000   # well past Steam's own friend limit
MAX_NAME = 256
MAX_URL = 2048
PERSONA = {0: "offline", 1: "online", 2: "busy", 3: "away", 4: "away", 5: "online", 6: "online"}


def api_get(path, **params):
    q = "&".join("%s=%s" % (k, urllib.request.quote(str(v))) for k, v in params.items())
    return fetch_json("%s/%s?%s" % (API, path, q))


def friends_from_api(key, user):
    """Friend list and presence from the Steam Web API (one request per 100)."""
    listing = api_get("ISteamUser/GetFriendList/v1/", key=key, steamid=user["steamid"], relationship="friend")
    ids = [str(f["steamid"]) for f in seq(listing.get("friendslist", {}).get("friends"), MAX_FRIENDS)
           if isinstance(f, dict) and str(f.get("steamid", "")).isdigit()]
    people = []
    for i in range(0, len(ids), 100):
        chunk = api_get("ISteamUser/GetPlayerSummaries/v2/", key=key, steamids=",".join(ids[i:i + 100]))
        for p in seq(chunk.get("response", {}).get("players"), 100):
            if not isinstance(p, dict) or not str(p.get("steamid", "")).isdigit():
                continue
            persona = p.get("personastate", 0)
            state = "in-game" if p.get("gameextrainfo") else \
                PERSONA.get(persona, "online") if isinstance(persona, int) else "online"
            people.append({
                "steamid": str(p["steamid"]),
                "accountid": str(int(p["steamid"]) - STEAMID64_BASE),
                "name": clip(p.get("personaname"), MAX_NAME),
                "avatar": clip(p.get("avatarmedium"), MAX_URL),
                "state": state,
                "statusText": {"in-game": "In-Game", "offline": "Offline", "away": "Away", "busy": "Busy"}.get(state, "Online"),
                "game": clip(p.get("gameextrainfo"), MAX_NAME),
                "lastOnline": p.get("lastlogoff", 0) if isinstance(p.get("lastlogoff"), int) else 0,
            })
    return people


def friends_from_community(user):
    """Friends cached by the Steam client, with status scraped one at a time
    from each public mini-profile. Steam answers bursts with HTTP 500, so the
    fetches are spaced out and stop at the first refusal; statuses that
    weren't refreshed this round keep their last known value."""
    cfg = ci(ci(localconfig(user), "UserLocalConfigStore"), "friends")
    people = []
    for k, v in cfg.items() if isinstance(cfg, dict) else []:
        if k.isdigit() and isinstance(v, dict) and k != user["accountid"]:
            avatar = ci(v, "avatar")
            if len(people) >= MAX_FRIENDS:
                break
            people.append({
                "accountid": k,
                "steamid": str(int(k) + STEAMID64_BASE),
                "name": clip(ci(v, "name"), MAX_NAME) or k,
                "avatar": "https://avatars.fastly.steamstatic.com/%s_medium.jpg" % avatar[:64]
                          if isinstance(avatar, str) and avatar else "",
            })

    os.makedirs(CACHE, exist_ok=True)
    cache_path = os.path.join(CACHE, "friends.json")
    try:
        with open(cache_path) as f:
            known = json.load(f)
    except (OSError, ValueError):
        known = {}

    # Oldest-checked first, so a round cut short still makes progress.
    order = sorted(people, key=lambda p: known.get(p["accountid"], {}).get("checked", 0))
    for n, p in enumerate(order):
        if n:
            time.sleep(0.35)
        try:
            s = fetch_status(p["accountid"])
        except Exception:
            break
        s["checked"] = int(time.time())
        known[p["accountid"]] = s

    for p in people:
        s = known.get(p["accountid"], {})
        p["state"] = s.get("state", "unknown")
        p["statusText"] = s.get("statusText", "")
        p["game"] = s.get("game", "")
        if s.get("name"):
            p["name"] = s["name"]

    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(known, f)
    os.replace(tmp, cache_path)
    return people


def friends():
    user = current_user()
    if not user:
        return {"error": "No Steam account found on this computer"}
    key = os.environ.get("STEAM_API_KEY", "").strip()
    error = ""
    people = None
    if key:
        try:
            people = friends_from_api(key, user)
        except Exception as e:
            error = "Steam Web API: %s" % e
    if people is None:
        people = friends_from_community(user)
    rank = {"in-game": 0, "online": 1, "busy": 2, "away": 2}
    people.sort(key=lambda p: (rank.get(p["state"], 3), p["name"].lower()))
    out = {"friends": people, "source": "api" if key and not error else "community"}
    if error:
        out["error"] = error
    return out


# ---------- downloads ----------
def library_paths():
    folders = ci(read_vdf(os.path.join(STEAM, "steamapps", "libraryfolders.vdf")), "libraryfolders")
    paths = [STEAM] + [ci(v, "path") for v in folders.values() if isinstance(v, dict)]
    seen, out = set(), []
    for p in paths:
        if isinstance(p, str) and p and os.path.realpath(p) not in seen:
            seen.add(os.path.realpath(p))
            out.append(p)
    return out


def log_states():
    """Latest per-app state, phase and update totals from Steam's content log.
    Steam only rewrites app manifests on state changes, so this log is the
    live source for what's downloading."""
    path = os.path.join(STEAM, "logs", "content_log.txt")
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 400000))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return {}
    apps = {}
    for m in re.finditer(r"^\[[^\]]+\] AppID (\d+) (state changed|App update changed|update started) : (.*)$", text, re.M):
        a = apps.setdefault(int(m.group(1)), {})
        kind, value = m.group(2), m.group(3).strip()
        if kind == "state changed":
            a["state"] = value
        elif kind == "App update changed":
            a["phase"] = value
        else:
            nums = dict((k, (int(x), int(y))) for k, x, y in re.findall(r"(\w+) (\d+)/(\d+)", value))
            a["download"] = nums.get("download", (0, 0))[1]
            a["stage"] = nums.get("stage", (0, 0))[1]
    return apps


def disk_bytes(path):
    """Bytes actually written under path (preallocated files count only what's filled)."""
    total = 0
    for dirpath, _, files in os.walk(path):
        for name in files:
            try:
                st = os.lstat(os.path.join(dirpath, name))
            except OSError:
                continue
            total += min(st.st_size, st.st_blocks * 512)
    return total


def steam_reachable():
    try:
        urllib.request.urlopen("http://127.0.0.1:8080/json/version", timeout=1).close()
        return True
    except Exception:
        return False


def steam_overview():
    """Live download overview from the running client, or None when Steam's
    debugging port isn't available (see steamctl.py)."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import steamctl
        return steamctl.evaluate(steamctl.OVERVIEW_JS)
    except Exception:
        return None


TOOL_TYPES = ("tool", "config")


def fold_tools(out, order):
    """Show runtimes and other tools (Steam Linux Runtime, redistributables)
    as part of the game they're downloading for, like Steam does. A tool
    downloading on its own still gets its own entry."""
    games = [d for d in out if d.get("type") not in TOOL_TYPES]
    if not games:
        return out
    game = games[0]
    for t in out:
        if t.get("type") not in TOOL_TYPES:
            continue
        game["total"] += t["total"]
        game["staged"] += t["staged"]
        # While the tool is the one actually moving, the game is too.
        if order.get(t["status"], 3) < order.get(game["status"], 3):
            game["status"] = t["status"]
        if t.get("speed") and not game.get("speed"):
            game["speed"] = t["speed"]
            game["eta"] = t.get("eta", 0)
    if game["total"]:
        game["progress"] = min(1.0, game["staged"] / game["total"])
    return games


def downloads():
    states = log_states()
    info = None
    out = []
    for lib in library_paths():
        apps_dir = os.path.join(lib, "steamapps")
        try:
            names = os.listdir(apps_dir)
        except OSError:
            continue
        for name in names:
            m = re.match(r"appmanifest_(\d+)\.acf$", name)
            if not m:
                continue
            aid = int(m.group(1))
            st = states.get(aid, {})
            state = st.get("state", "")
            if not ("Update Started" in state or "Update Running" in state) or "Update delayed" in state:
                continue
            if "(Suspended)" in state:
                status = "paused"
            elif "Update Running" not in state:
                status = "queued"
            else:
                phase = st.get("phase", "")
                status = ("installing" if "Committing" in phase or "Running Script" in phase
                          else "verifying" if "Verifying" in phase
                          else "preparing" if "Preallocating" in phase or "Reconfiguring" in phase
                          else "downloading")
            manifest = ci(read_vdf(os.path.join(apps_dir, name)), "AppState")
            total = st.get("stage") or int(ci(manifest, "BytesToStage") or 0)
            staged = disk_bytes(os.path.join(apps_dir, "downloading", str(aid)))
            if info is None:
                info = read_appinfo()
            meta = info.get(aid, {})
            header, icon = art_for(aid)
            out.append({
                "appid": aid,
                "name": ci(manifest, "name") or meta.get("name") or str(aid),
                "type": meta.get("type", ""),
                "status": status,
                "installed": bool(int(ci(manifest, "StateFlags") or 0) & 4),
                "staged": min(staged, total) if total else staged,
                "total": total,
                "progress": min(1.0, staged / total) if total else 0,
                "header": header,
                "icon": icon,
            })
    live = steam_overview() if out else None
    for d in out:
        d["controllable"] = live is not None
        if live and live.get("appid") == d["appid"] and d["status"] == "downloading":
            # Steam's own figures: network speed and its time-left estimate.
            d["speed"] = live.get("networkBytesPerSecond") or 0
            d["eta"] = live.get("eta") if (live.get("eta") or -1) > 0 else 0
        # Nothing on disk and nothing coming in: Steam is between steps (a
        # finished download's follow-up update, reconfiguring), not downloading.
        if d["status"] == "downloading" and not d["staged"] and not d.get("speed"):
            d["status"] = "preparing"
    order = {"downloading": 0, "installing": 0, "verifying": 0, "preparing": 0, "queued": 1, "paused": 2}
    out.sort(key=lambda d: (order.get(d["status"], 3), d["name"].lower()))
    out = fold_tools(out, order)
    return {"downloads": out, "time": time.time(), "controllable": steam_reachable()}


# ---------- store lists ----------
LIST_COUNT = 50
LIST_MAX_AGE = 3600
# kind -> store search query, the same ones the Steam client's store tabs use
STORE_LISTS = {
    "top": "filter=topsellers",
    "upcoming": "filter=popularcomingsoon",
    "new": "filter=popularnew&sort_by=Released_DESC&os=win,linux",  # Popular New Releases, newest first
}


def store_list(kind):
    """One of the store's lists (top sellers, popular upcoming, popular new
    releases), with names, art and prices from the store API; hardware and
    DLC are skipped. Both endpoints are public. Cached for an hour, and the
    last good copy is used when Steam can't be reached."""
    query = STORE_LISTS[kind]
    os.makedirs(CACHE, exist_ok=True)
    cache_path = os.path.join(CACHE, "store-%s.json" % kind)
    try:
        with open(cache_path) as f:
            cached = json.load(f)
    except (OSError, ValueError):
        cached = None
    if cached and time.time() - cached.get("time", 0) < LIST_MAX_AGE:
        return cached

    try:
        rows, seen = [], set()
        for page in range(6):
            url = ("https://store.steampowered.com/search/results/?%s&infinite=1"
                   "&count=100&start=%d&cc=us&l=english" % (query, page * 100))
            results = clip(fetch_json(url, limit=MAX_SEARCH).get("results_html"), MAX_SEARCH)
            # Bundles list several appids; only single apps are ranked here.
            found = re.findall(r'<a [^>]*data-ds-appid="(\d+)"[^>]*>(.*?)</a>', results, re.S)
            for aid, inner in found:
                released = re.search(r'search_released[^>]*>\s*([^<]*?)\s*<', inner)
                released = clip(html.unescape(released.group(1)), 64) if released else ""
                if int(aid) in seen:
                    continue
                seen.add(int(aid))
                rows.append((int(aid), released))
            # A few extra make up for hardware and DLC dropped below.
            rows = rows[:LIST_COUNT + 15]
            if len(rows) >= LIST_COUNT + 15 or len(found) < 50:
                break
        request = {
            "ids": [{"appid": a} for a, _ in rows],
            "context": {"language": "english", "country_code": "US"},
            "data_request": {"include_assets": True},
        }
        items = api_get("IStoreBrowseService/GetItems/v1/", input_json=json.dumps(request))
    except Exception as e:
        if cached:
            return cached
        return {"error": "Couldn't reach the Steam store: %s" % e}

    store = {i.get("appid"): i for i in seq(items.get("response", {}).get("store_items"), len(rows))
             if isinstance(i, dict) and i.get("success") == 1}
    out = []
    for aid, released in rows:
        item = store.get(aid)
        if not item or item.get("type", 0) != 0 or not item.get("name"):  # type 0 = game
            continue
        assets = item.get("assets") if isinstance(item.get("assets"), dict) else {}
        fmt = clip(assets.get("asset_url_format"), MAX_URL)
        header = ("https://shared.fastly.steamstatic.com/store_item_assets/" + fmt.replace("${FILENAME}", clip(assets["header"], 256))
                  if fmt and assets.get("header") else art_for(aid)[0])
        offer = item.get("best_purchase_option") if isinstance(item.get("best_purchase_option"), dict) else {}
        out.append({
            "appid": aid,
            "name": clip(item["name"], MAX_NAME),
            "rank": len(out) + 1,
            "free": bool(item.get("is_free")),
            "price": "Free" if item.get("is_free") else clip(offer.get("formatted_final_price"), 64),
            "discount": number(offer.get("discount_pct")),
            "released": released,
            "header": header,
        })
        if len(out) >= LIST_COUNT:
            break
    result = {"games": out, "time": time.time()}
    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(result, f)
    os.replace(tmp, cache_path)
    return result


def store_lists():
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(len(STORE_LISTS)) as pool:
        jobs = {kind: pool.submit(store_list, kind) for kind in STORE_LISTS}
    return {kind: job.result() for kind, job in jobs.items()}


# ---------- store page ----------
STORE_MAX_AGE = 6 * 3600
DECK = {1: "Unsupported", 2: "Playable", 3: "Verified"}


def tag_names():
    """Steam's tag id -> name table, cached for a week."""
    path = os.path.join(CACHE, "tags.json")
    try:
        if time.time() - os.path.getmtime(path) < 7 * 86400:
            with open(path) as f:
                return {int(k): v for k, v in json.load(f).items()}
    except (OSError, ValueError):
        pass
    tags = {t["tagid"]: clip(t.get("name"), 64) for t in seq(api_get("IStoreService/GetTagList/v1/", language="english")
            .get("response", {}).get("tags"), 5000) if isinstance(t, dict) and isinstance(t.get("tagid"), int)}
    with open(path + ".tmp", "w") as f:
        json.dump(tags, f)
    os.replace(path + ".tmp", path)
    return tags


# A few KB of AVIF can declare a huge canvas or thousands of frames, so the
# download cap alone doesn't bound decoding. ImageMagick refuses anything past
# these before allocating pixels, never spills to disk, and prlimit backs that
# up with address-space and file-size ceilings. Steam's tallest description
# art is around 1400x8200, and animations are a few hundred small frames.
CONVERT_LIMITS = [
    "-limit", "width", "8192", "-limit", "height", "16384",
    "-limit", "area", "24MP", "-limit", "list-length", "600",
    "-limit", "memory", "256MiB", "-limit", "map", "256MiB",
    "-limit", "disk", "0", "-limit", "thread", "1", "-limit", "time", "60",
]
CONVERT_AS = 4 * 1024 * MB     # virtual; the AV1 decoder reserves a stack per core
CONVERT_FSIZE = 64 * MB
CONVERT_SLOTS = threading.Semaphore(2)   # conversions at once


def local_image(url):
    """Qt here can't decode AVIF, which is all Steam serves for description
    art, so those are converted to WebP (animation kept) in the cache."""
    if not re.search(r"\.avif(\?|$)", url):
        return url
    import hashlib
    import subprocess
    folder = os.path.join(CACHE, "store", "img")
    os.makedirs(folder, exist_ok=True)
    out = os.path.join(folder, hashlib.sha1(url.encode()).hexdigest() + ".webp")
    if not os.path.exists(out):
        data = fetch_steam_image(url, timeout=15, limit=MAX_IMAGE)
        tmp = "%s.%d.%d.tmp.webp" % (out, os.getpid(), threading.get_ident())
        try:
            with CONVERT_SLOTS:
                subprocess.run(["prlimit", "--as=%d" % CONVERT_AS, "--fsize=%d" % CONVERT_FSIZE, "--",
                                "magick", *CONVERT_LIMITS, "avif:-", tmp], input=data, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            os.replace(tmp, out)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    return out


def styled(markup):
    """Steam's description HTML reduced to what QML's StyledText renders."""
    markup = re.sub(r"</?(span|div|a|u)\b[^>]*>", "", markup)
    markup = re.sub(r"<(/?)(\w+)\b[^>]*?(/?)>", lambda m: "<%s%s%s>" % (m.group(1), m.group(2).lower(), m.group(3)), markup)
    markup = re.sub(r"<(/?)em>", r"<\1i>", markup)
    markup = re.sub(r"<h[1-6]>", "<h3>", markup)
    markup = re.sub(r"</h[1-6]>", "</h3>", markup)
    markup = re.sub(r"<p>\s*(<br\s*/?>\s*)*</p>", "", markup)
    markup = re.sub(r"(<br\s*/?>\s*){3,}", "<br><br>", markup)
    # StyledText leaves no gap between paragraphs, so they become line breaks.
    markup = re.sub(r"</p>\s*<p>", "<br><br>", markup)
    markup = re.sub(r"</?p>", "", markup)
    markup = re.sub(r"(<br\s*/?>\s*)+(<h3>)", r"<br>\2", markup)
    # StyledText's lists are loosely spaced and indented; plain bullets read better.
    markup = re.sub(r"(<br\s*/?>\s*)*</li>", "", markup)
    markup = re.sub(r"<li>\s*", "<br>• ", markup)
    markup = re.sub(r"</?(ul|ol)>", "", markup)
    markup = re.sub(r"(<br\s*/?>\s*)+<br>• ", "<br>• ", markup)
    # Splitting around media leaves dangling paragraph tags at the edges.
    markup = re.sub(r"^\s*(</\w+>\s*)+|(<(p|li|ul|ol)>\s*)+$", "", markup.strip())
    markup = re.sub(r"(<br\s*/?>\s*)+(</?p>|$)", r"\2", markup)
    markup = re.sub(r"^(\s*<br\s*/?>)+|(<br\s*/?>\s*)+$", "", markup)
    return markup.strip()


def plain(markup):
    return html.unescape(re.sub(r"<[^>]+>", " ", markup or "")).replace(" ,", ",").strip()


MAX_ABOUT = 512 * KB   # description HTML considered
MAX_TEXT = 32 * KB     # one text block, or a requirements section
MAX_BLOCKS = 150
MAX_IMAGES = 40        # description images converted per page
MAX_MEDIA = 60         # trailers, and screenshots


def description_blocks(markup):
    """The About section as text, image and video blocks in page order."""
    blocks, pos = [], 0
    markup = markup[:MAX_ABOUT]
    media = re.compile(r"<img\b[^>]*>|<video\b.*?</video>", re.S | re.I)
    for m in list(media.finditer(markup)) + [None]:
        text = markup[pos:m.start()] if m else markup[pos:]
        text = styled(text)
        if plain(text):
            blocks.append({"type": "text", "text": text[:MAX_TEXT]})
        if not m or len(blocks) >= MAX_BLOCKS:
            break
        pos = m.end()
        tag = m.group(0)
        # Each image may be downloaded and converted, so only so many.
        if sum(b["type"] != "text" for b in blocks) >= MAX_IMAGES:
            continue
        size = lambda k: int((re.search(k + r'\s*=\s*"?(\d{1,5})', tag) or [0, 0])[1])
        if tag.lower().startswith("<img"):
            src = re.search(r'src\s*=\s*"([^"]+)"', tag)
            if src:
                blocks.append({"type": "image", "src": src.group(1)[:MAX_URL], "w": size("width"), "h": size("height")})
        else:
            srcs = re.findall(r'<source[^>]*src\s*=\s*"([^"]+)"', tag)
            poster = re.search(r'poster\s*=\s*"([^"]+)"', tag)
            mp4 = [x for x in srcs if ".mp4" in x] or srcs
            if mp4:
                blocks.append({"type": "video", "src": mp4[0][:MAX_URL], "poster": poster.group(1)[:MAX_URL] if poster else "",
                               "w": size("width"), "h": size("height")})
    return blocks


def store_page(appid):
    """Everything the widget shows for a game's store page: appdetails,
    tags/reviews/Deck status from IStoreBrowseService, and a few of the most
    helpful English reviews. Cached for six hours."""
    folder = os.path.join(CACHE, "store")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "%d.json" % appid)
    try:
        if time.time() - os.path.getmtime(path) < STORE_MAX_AGE:
            with open(path) as f:
                return json.load(f)
    except (OSError, ValueError):
        pass

    from concurrent.futures import ThreadPoolExecutor
    request = {
        "ids": [{"appid": appid}],
        "context": {"language": "english", "country_code": "US"},
        "data_request": {"include_tag_count": 15, "include_platforms": True, "include_reviews": True},
    }
    with ThreadPoolExecutor(4) as pool:
        details = pool.submit(fetch_json, "https://store.steampowered.com/api/appdetails?appids=%d&cc=us&l=english" % appid)
        browse = pool.submit(api_get, "IStoreBrowseService/GetItems/v1/", input_json=json.dumps(request))
        reviews = pool.submit(fetch_json, "https://store.steampowered.com/appreviews/%d?json=1&language=english"
                              "&filter=all&num_per_page=5&purchase_type=all" % appid)
        tags = pool.submit(tag_names)
        try:
            # Steam sometimes keys the answer by a package id instead of the app.
            d = obj(next(iter(details.result().values())))
        except Exception as e:
            return {"error": "Couldn't load the store page: %s" % e}
        if not d.get("success"):
            return {"error": "This game has no store page in your region"}
        d = obj(d.get("data"))
        item, names, top = {}, {}, {}
        try:
            item = obj(browse.result()["response"]["store_items"][0])
        except Exception:
            pass
        try:
            names = tags.result()
        except Exception:
            pass
        try:
            top = reviews.result()
        except Exception:
            pass

        about = description_blocks(d.get("about_the_game") or d.get("detailed_description") or "")
        # Convert description art and video posters in parallel.
        def convert(block):
            try:
                if block["type"] == "image":
                    block["src"] = local_image(block["src"])
                elif block.get("poster"):
                    block["poster"] = local_image(block["poster"])
            except Exception:
                block["src" if block["type"] == "image" else "poster"] = ""
        list(pool.map(convert, about))
    about = [b for b in about if b["type"] != "image" or b["src"]]

    price = obj(d.get("price_overview"))
    reviews = obj(item.get("reviews"))
    summary = obj(reviews.get("summary_filtered"))
    english = obj(reviews.get("summary_language_specific"))
    platforms = obj(item.get("platforms"))
    release = obj(d.get("release_date"))
    movies = []
    for m in seq(d.get("movies"), MAX_MEDIA):
        m = obj(m)
        src = m.get("hls_h264") or obj(m.get("mp4")).get("max") or obj(m.get("webm")).get("max")
        if isinstance(src, str) and src:
            movies.append({"type": "video", "src": clip(src, MAX_URL), "thumb": clip(m.get("thumbnail"), MAX_URL),
                           "name": clip(m.get("name"), MAX_NAME)})
    shots = [{"type": "image", "src": clip(s.get("path_full"), MAX_URL), "thumb": clip(s.get("path_thumbnail"), MAX_URL)}
             for s in seq(d.get("screenshots"), MAX_MEDIA) if isinstance(s, dict)]
    reqs = obj(d.get("pc_requirements"))
    names_of = lambda v, key, n: [clip(obj(x).get(key) if key else x, MAX_NAME) for x in seq(v, n)]
    result = {
        "appid": appid,
        "name": clip(d.get("name"), MAX_NAME),
        "header": clip(d.get("header_image"), MAX_URL),
        "short": plain(clip(d.get("short_description"), MAX_TEXT)),
        "free": bool(d.get("is_free")),
        "price": "Free to Play" if d.get("is_free") else clip(price.get("final_formatted"), 64),
        "initialPrice": clip(price.get("initial_formatted"), 64),
        "discount": number(price.get("discount_percent")),
        "comingSoon": bool(release.get("coming_soon")),
        "releaseDate": clip(release.get("date"), 64),
        "earlyAccess": bool(item.get("is_early_access")),
        "developers": names_of(d.get("developers"), None, 10),
        "publishers": names_of(d.get("publishers"), None, 10),
        "reviews": {"label": clip(summary.get("review_score_label"), 64), "percent": number(summary.get("percent_positive")),
                    "count": number(summary.get("review_count"))},
        "englishReviews": {"label": clip(english.get("review_score_label"), 64),
                           "percent": number(english.get("percent_positive")), "count": number(english.get("review_count"))},
        "topReviews": [{
            "up": bool(r.get("voted_up")),
            "text": clip(r.get("review"), 700).strip() + ("…" if len(clip(r.get("review"), 701)) > 700 else ""),
            "hours": round(number(obj(r.get("author")).get("playtime_forever")) / 60, 1),
            "helpful": number(r.get("votes_up")),
            "date": number(r.get("timestamp_created")),
        } for r in seq(top.get("reviews"), 10) if isinstance(r, dict)],
        "tags": [names[t["tagid"]] for t in seq(item.get("tags"), 50) if isinstance(t, dict) and t.get("tagid") in names],
        "genres": names_of(d.get("genres"), "description", 30),
        "features": list(dict.fromkeys(names_of(d.get("categories"), "description", 60))),
        "platforms": {k: bool(obj(d.get("platforms")).get(k)) for k in ("windows", "mac", "linux")},
        "deck": DECK.get(number(platforms.get("steam_deck_compat_category")), ""),
        "steamos": DECK.get(number(platforms.get("steam_os_compat_category")), ""),
        "languages": re.sub(r"\s*\*?\s*languages with full audio support$", "", plain(clip(d.get("supported_languages"), MAX_TEXT)))
                     .replace(" *", "*").rstrip("* "),
        "achievements": number(obj(d.get("achievements")).get("total")),
        "dlc": len(seq(d.get("dlc"), 100000)),
        "contentNotes": clip(obj(d.get("content_descriptors")).get("notes"), 4096),
        "media": movies + shots,
        "about": about,
        "minimum": styled(clip(reqs.get("minimum"), MAX_TEXT)),
        "recommended": styled(clip(reqs.get("recommended"), MAX_TEXT)),
    }
    with open(path + ".tmp", "w") as f:
        json.dump(result, f)
    os.replace(path + ".tmp", path)
    return result


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "games"
    try:
        result = (store_page(int(sys.argv[2])) if mode == "store"
                  else friends() if mode == "friends" else downloads() if mode == "downloads"
                  else store_lists() if mode == "storelists" else games())
    except Exception as e:  # report instead of crashing the widget
        result = {"error": str(e)[:500]}
    out = json.dumps(result, ensure_ascii=False)
    if len(out.encode("utf-8")) > MAX_OUTPUT:
        out = json.dumps({"error": "Steam's answer was too large to show"})
    sys.stdout.write(out)
