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
import time
import urllib.request



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
    with urllib.request.urlopen(req, timeout=8) as r:
        page = r.read().decode("utf-8", "replace")
    state = re.search(r'class="persona\s+([\w-]+)"', page)
    name = re.search(r'class="persona[^"]*">([^<]*)<', page)
    status = re.search(r'class="friend_status_[\w-]+">([^<]*)<', page)
    game = re.search(r'class="miniprofile_game_name">([^<]*)<', page)
    state = state.group(1) if state else "offline"
    status_text = html.unescape(status.group(1)).strip() if status else ""
    if state == "online" and re.search(r"away|snooze", status_text, re.I):
        state = "away"
    return {
        "state": state,
        "name": html.unescape(name.group(1)).strip() if name else "",
        "statusText": status_text,
        "game": html.unescape(game.group(1)).strip() if game else "",
    }


API = "https://api.steampowered.com"
PERSONA = {0: "offline", 1: "online", 2: "busy", 3: "away", 4: "away", 5: "online", 6: "online"}


def api_get(path, **params):
    q = "&".join("%s=%s" % (k, urllib.request.quote(str(v))) for k, v in params.items())
    with urllib.request.urlopen("%s/%s?%s" % (API, path, q), timeout=10) as r:
        return json.load(r)


def friends_from_api(key, user):
    """Friend list and presence from the Steam Web API (one request per 100)."""
    listing = api_get("ISteamUser/GetFriendList/v1/", key=key, steamid=user["steamid"], relationship="friend")
    ids = [f["steamid"] for f in listing.get("friendslist", {}).get("friends", [])]
    people = []
    for i in range(0, len(ids), 100):
        chunk = api_get("ISteamUser/GetPlayerSummaries/v2/", key=key, steamids=",".join(ids[i:i + 100]))
        for p in chunk.get("response", {}).get("players", []):
            state = "in-game" if p.get("gameextrainfo") else PERSONA.get(p.get("personastate", 0), "online")
            people.append({
                "steamid": p["steamid"],
                "accountid": str(int(p["steamid"]) - STEAMID64_BASE),
                "name": p.get("personaname", ""),
                "avatar": p.get("avatarmedium", ""),
                "state": state,
                "statusText": {"in-game": "In-Game", "offline": "Offline", "away": "Away", "busy": "Busy"}.get(state, "Online"),
                "game": p.get("gameextrainfo", ""),
                "lastOnline": p.get("lastlogoff", 0),
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
            people.append({
                "accountid": k,
                "steamid": str(int(k) + STEAMID64_BASE),
                "name": ci(v, "name") or k,
                "avatar": "https://avatars.fastly.steamstatic.com/%s_medium.jpg" % avatar if isinstance(avatar, str) and avatar else "",
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
            with urllib.request.urlopen(url, timeout=10) as r:
                results = json.load(r).get("results_html", "")
            # Bundles list several appids; only single apps are ranked here.
            found = re.findall(r'<a [^>]*data-ds-appid="(\d+)"[^>]*>(.*?)</a>', results, re.S)
            for aid, inner in found:
                released = re.search(r'search_released[^>]*>\s*([^<]*?)\s*<', inner)
                released = html.unescape(released.group(1)) if released else ""
                if int(aid) in seen:
                    continue
                seen.add(int(aid))
                rows.append((int(aid), released))
            # A few extra make up for hardware and DLC dropped below.
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

    store = {i.get("appid"): i for i in items.get("response", {}).get("store_items", []) if i.get("success") == 1}
    out = []
    for aid, released in rows:
        item = store.get(aid)
        if not item or item.get("type", 0) != 0 or not item.get("name"):  # type 0 = game
            continue
        assets = item.get("assets", {})
        fmt = assets.get("asset_url_format", "")
        header = ("https://shared.fastly.steamstatic.com/store_item_assets/" + fmt.replace("${FILENAME}", assets["header"])
                  if fmt and assets.get("header") else art_for(aid)[0])
        offer = item.get("best_purchase_option", {})
        out.append({
            "appid": aid,
            "name": item["name"],
            "rank": len(out) + 1,
            "free": bool(item.get("is_free")),
            "price": "Free" if item.get("is_free") else offer.get("formatted_final_price", ""),
            "discount": offer.get("discount_pct", 0),
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


def fetch_json(url, timeout=10):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def tag_names():
    """Steam's tag id -> name table, cached for a week."""
    path = os.path.join(CACHE, "tags.json")
    try:
        if time.time() - os.path.getmtime(path) < 7 * 86400:
            with open(path) as f:
                return {int(k): v for k, v in json.load(f).items()}
    except (OSError, ValueError):
        pass
    tags = {t["tagid"]: t["name"] for t in api_get("IStoreService/GetTagList/v1/", language="english")
            .get("response", {}).get("tags", [])}
    with open(path + ".tmp", "w") as f:
        json.dump(tags, f)
    os.replace(path + ".tmp", path)
    return tags


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
        with urllib.request.urlopen(url, timeout=15) as r:
            data = r.read()
        subprocess.run(["magick", "avif:-", out + ".tmp.webp"], input=data, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        os.replace(out + ".tmp.webp", out)
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


def description_blocks(markup):
    """The About section as text, image and video blocks in page order."""
    blocks, pos = [], 0
    media = re.compile(r"<img\b[^>]*>|<video\b.*?</video>", re.S | re.I)
    for m in list(media.finditer(markup)) + [None]:
        text = markup[pos:m.start()] if m else markup[pos:]
        text = styled(text)
        if plain(text):
            blocks.append({"type": "text", "text": text})
        if not m:
            break
        pos = m.end()
        tag = m.group(0)
        size = lambda k: int((re.search(k + r'\s*=\s*"?(\d+)', tag) or [0, 0])[1])
        if tag.lower().startswith("<img"):
            src = re.search(r'src\s*=\s*"([^"]+)"', tag)
            if src:
                blocks.append({"type": "image", "src": src.group(1), "w": size("width"), "h": size("height")})
        else:
            srcs = re.findall(r'<source[^>]*src\s*=\s*"([^"]+)"', tag)
            poster = re.search(r'poster\s*=\s*"([^"]+)"', tag)
            mp4 = [x for x in srcs if ".mp4" in x] or srcs
            if mp4:
                blocks.append({"type": "video", "src": mp4[0], "poster": poster.group(1) if poster else "",
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
            d = next(iter(details.result().values()))
        except Exception as e:
            return {"error": "Couldn't load the store page: %s" % e}
        if not d.get("success"):
            return {"error": "This game has no store page in your region"}
        d = d["data"]
        item, names, top = {}, {}, {}
        try:
            item = browse.result()["response"]["store_items"][0]
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

    price = d.get("price_overview", {})
    summary = item.get("reviews", {}).get("summary_filtered", {})
    english = item.get("reviews", {}).get("summary_language_specific", {})
    platforms = item.get("platforms", {})
    release = d.get("release_date", {})
    movies = []
    for m in d.get("movies", []):
        src = m.get("hls_h264") or m.get("mp4", {}).get("max") or m.get("webm", {}).get("max")
        if src:
            movies.append({"type": "video", "src": src, "thumb": m.get("thumbnail", ""), "name": m.get("name", "")})
    shots = [{"type": "image", "src": s["path_full"], "thumb": s["path_thumbnail"]} for s in d.get("screenshots", [])]
    reqs = d.get("pc_requirements") or {}
    if not isinstance(reqs, dict):
        reqs = {}
    result = {
        "appid": appid,
        "name": d.get("name", ""),
        "header": d.get("header_image", ""),
        "short": plain(d.get("short_description", "")),
        "free": bool(d.get("is_free")),
        "price": "Free to Play" if d.get("is_free") else price.get("final_formatted", ""),
        "initialPrice": price.get("initial_formatted", ""),
        "discount": price.get("discount_percent", 0),
        "comingSoon": bool(release.get("coming_soon")),
        "releaseDate": release.get("date", ""),
        "earlyAccess": bool(item.get("is_early_access")),
        "developers": d.get("developers", []),
        "publishers": d.get("publishers", []),
        "reviews": {"label": summary.get("review_score_label", ""), "percent": summary.get("percent_positive", 0),
                    "count": summary.get("review_count", 0)},
        "englishReviews": {"label": english.get("review_score_label", ""), "percent": english.get("percent_positive", 0),
                           "count": english.get("review_count", 0)},
        "topReviews": [{
            "up": bool(r.get("voted_up")),
            "text": r.get("review", "")[:700].strip() + ("…" if len(r.get("review", "")) > 700 else ""),
            "hours": round(r.get("author", {}).get("playtime_forever", 0) / 60, 1),
            "helpful": r.get("votes_up", 0),
            "date": r.get("timestamp_created", 0),
        } for r in top.get("reviews", [])],
        "tags": [names[t["tagid"]] for t in item.get("tags", []) if t.get("tagid") in names],
        "genres": [g["description"] for g in d.get("genres", [])],
        "features": list(dict.fromkeys(c["description"] for c in d.get("categories", []))),
        "platforms": d.get("platforms", {}),
        "deck": DECK.get(platforms.get("steam_deck_compat_category", 0), ""),
        "steamos": DECK.get(platforms.get("steam_os_compat_category", 0), ""),
        "languages": re.sub(r"\s*\*?\s*languages with full audio support$", "", plain(d.get("supported_languages", "")))
                     .replace(" *", "*").rstrip("* "),
        "achievements": d.get("achievements", {}).get("total", 0),
        "dlc": len(d.get("dlc", [])),
        "contentNotes": (d.get("content_descriptors") or {}).get("notes") or "",
        "media": movies + shots,
        "about": about,
        "minimum": styled(reqs.get("minimum", "")),
        "recommended": styled(reqs.get("recommended", "")),
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
        result = {"error": str(e)}
    json.dump(result, sys.stdout, ensure_ascii=False)
