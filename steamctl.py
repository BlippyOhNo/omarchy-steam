#!/usr/bin/env python3
"""Control the running Steam client through its CEF debugging port.

Steam's UI runs in an embedded browser; with the flag file
~/.local/share/Steam/.cef-enable-remote-debugging present it listens on
localhost:8080, and its SharedJSContext page exposes the SteamClient API the
client's own UI uses. This is how Decky Loader talks to Steam too.

  steamctl.py folders               -> Steam library folders with free space
  steamctl.py overview              -> live download overview (speed, ETA, paused)
  steamctl.py pause <appid>         -> pause a download
  steamctl.py resume <appid>        -> resume a download
  steamctl.py install <appid> <folder index>
                                    -> install without Steam's window
  steamctl.py uninstall <appid>     -> uninstall a game (no confirmation dialog)
  steamctl.py friends               -> friend list with live presence and unread counts
  steamctl.py chat <accountid> [read]
                                    -> recent messages with a friend ("read" marks them read)
  steamctl.py send <accountid>      -> send the chat message read from stdin
                                       (never argv, where other users can see it)
  steamctl.py wizard-state          -> install wizard state (8 = showing a EULA)
  steamctl.py eval '<js>'           -> JSON result of the expression

Every command prints {"ok": true, "value": ...} or {"ok": false, "error": ...}.
"""
import base64
import json
import os
import socket
import struct
import sys
import urllib.error
import urllib.request

PORT = 8080
# Byte ceilings for what Steam's debug port hands back, and for what's
# printed to the widget.
MAX_TARGETS = 1024 * 1024
MAX_MESSAGE = 16 * 1024 * 1024
MAX_OUTPUT = 8 * 1024 * 1024


def target_ws():
    with urllib.request.urlopen("http://127.0.0.1:%d/json" % PORT, timeout=3) as r:
        pages = r.read(MAX_TARGETS + 1)
    if len(pages) > MAX_TARGETS:
        raise RuntimeError("Steam's debug target list is too large")
    pages = json.loads(pages)
    if not isinstance(pages, list):
        raise RuntimeError("Steam's SharedJSContext isn't available")
    for p in pages:
        if isinstance(p, dict) and p.get("title") == "SharedJSContext":
            return p["webSocketDebuggerUrl"]
    raise RuntimeError("Steam's SharedJSContext isn't available")


class WebSocket:
    """Just enough RFC 6455 for CDP: text frames, client masking, no extensions."""

    def __init__(self, url):
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key)
        ).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise RuntimeError("websocket handshake failed")
            head += chunk
            if len(head) > 16384:
                raise RuntimeError("websocket handshake failed")
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise RuntimeError("websocket handshake refused")

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("websocket closed")
            buf += chunk
        return buf

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            header = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 65536:
            header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._recv(2)
            n = b2 & 0x7F
            if n == 126:
                n, = struct.unpack("!H", self._recv(2))
            elif n == 127:
                n, = struct.unpack("!Q", self._recv(8))
            if len(message) + n > MAX_MESSAGE:
                raise RuntimeError("Steam's answer was too large")
            payload = self._recv(n)
            op = b1 & 0x0F
            if op == 8:
                raise RuntimeError("websocket closed")
            if op in (0, 1, 2):
                message += payload
                if b1 & 0x80:
                    return message.decode("utf-8", "replace")


def evaluate(js, timeout=15):
    ws = WebSocket(target_ws())
    ws.sock.settimeout(timeout)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {
        "expression": js, "awaitPromise": True, "returnByValue": True}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == 1:
            break
    result = msg.get("result", {})
    if "exceptionDetails" in result:
        d = result["exceptionDetails"]
        raise RuntimeError(d.get("exception", {}).get("description") or d.get("text", "JS error"))
    return result.get("result", {}).get("value")


FOLDERS_JS = """
SteamClient.InstallFolder.GetInstallFolders().then(f => f.filter(x => x.bIsMounted).map(x => ({
  index: x.nFolderIndex, path: x.strFolderPath, label: x.strUserLabel, drive: x.strDriveName,
  free: x.nFreeSpace, capacity: x.nCapacity, isDefault: x.bIsDefaultFolder })))
"""

OVERVIEW_JS = """
new Promise((resolve, reject) => {
  const h = SteamClient.Downloads.RegisterForDownloadOverview(o => {
    h.unregister()
    resolve({ appid: o.update_appid, state: o.update_state, paused: o.paused,
      networkBytesPerSecond: o.update_network_bytes_per_second,
      diskBytesPerSecond: o.update_disc_bytes_per_second,
      percent: o.overall_percent_complete, eta: o.overall_estimated_time_remaining_sec })
  })
  setTimeout(() => reject(new Error("no download overview from Steam")), 3000)
})
"""

# Steam's own Downloads page pauses the running download by pausing the whole
# queue, and pauses anything else by taking it out of the queue.
PAUSE_JS = """
new Promise(resolve => {
  const h = SteamClient.Downloads.RegisterForDownloadOverview(o => {
    h.unregister()
    if (o.update_appid === %(appid)d) SteamClient.Downloads.EnableAllDownloads(false, "0")
    else SteamClient.Downloads.PauseAppUpdate(%(appid)d, "0")
    resolve("paused")
  })
})
"""

RESUME_JS = """
SteamClient.Downloads.ResumeAppUpdate(%(appid)d, "0");
SteamClient.Downloads.EnableAllDownloads(true, "0");
"resumed"
"""

# Installing goes through Steam's install wizard: open it, wait until it's
# asking where to install (state 7), pick the folder and continue. Windows
# Steam opens meanwhile (the wizard dialog, and the main window if Steam
# brings it up to host the dialog) are hidden the moment they're created, via
# a popup-created hook installed once per Steam session.
#
# A game with a licence agreement then moves to state 8: the wizard dialog is
# shown with the EULA, and this waits (up to 10 minutes) for it to be
# accepted or declined there. If the wizard stops anywhere else it's left
# showing so it can be finished by hand.
INSTALL_JS = """
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  const hide = p => { try { p.window.SteamClient.Window.HideWindow() } catch (e) {} }
  const show = p => { try { p.window.SteamClient.Window.ShowWindow(); p.window.SteamClient.Window.BringToFront() } catch (e) {} }
  // Versioned so a changed hook installs even if an older one is loaded.
  if (!window.__blipSteamHook3) {
    window.__blipSteamHook3 = true
    g_PopupManager.AddPopupCreatedCallback(p => {
      if (window.__blipQuietUntil > Date.now() && !/contextmenu/.test(p.m_strName || "")) hide(p)
    })
  }
  const S = { None: 0, ShowConfig: 7, ShowEULAs: 8, Complete: 14, Failed: 15, Canceled: 16 }
  const desk = () => g_PopupManager.GetExistingPopup("SP Desktop_uid0")
  const mainWasVisible = !!desk() && !desk().window.document.hidden
  const wizard = () => Array.from(g_PopupManager.GetPopups()).filter(p => /Install/.test(p.m_strName || ""))
  // Steam re-shows its (already existing) main window to host the wizard,
  // which the popup hook can't catch, so keep it hidden while working quietly.
  let quiet = true
  const guard = setInterval(() => {
    if (!quiet) return
    const d = desk()
    if (d && !mainWasVisible && !d.window.document.hidden) hide(d)
  }, 30)
  const finish = result => {
    quiet = false
    clearInterval(guard)
    window.__blipQuietUntil = 0
    if (result !== "needs-steam") {
      for (const p of wizard()) hide(p)
      const d = desk()
      if (d && !mainWasVisible) hide(d)
    }
    return result
  }
  const reveal = () => {
    quiet = false
    window.__blipQuietUntil = 0
    const d = desk()
    if (d) show(d)
    for (const p of wizard()) show(p)
  }
  const state = async () => (await SteamClient.Installs.GetInstallManagerInfo()).eInstallState
  const waitUntil = async (done, ms) => {
    const end = Date.now() + ms
    let s = await state()
    while (!done(s) && Date.now() < end) { await sleep(100); s = await state() }
    return s
  }
  // Licence agreement: that's for you to accept, so show it and wait.
  const eula = async () => {
    reveal()
    const s = await waitUntil(s => s !== S.ShowEULAs, 600000)
    quiet = true
    window.__blipQuietUntil = Date.now() + 5000
    return s
  }
  const ended = s => s === S.None || s === S.Complete || s === S.Failed || s === S.Canceled

  window.__blipQuietUntil = Date.now() + 5000
  SteamClient.Installs.OpenInstallWizard([%(appid)d])
  let s = await waitUntil(s => s === S.ShowConfig || s === S.ShowEULAs || ended(s), 8000)
  if (s === S.ShowEULAs) {
    await eula()
    s = await waitUntil(s => s === S.ShowConfig || ended(s), 8000)
  }
  if (s === S.ShowEULAs || (s !== S.ShowConfig && !ended(s))) { reveal(); return finish("needs-steam") }
  if (s !== S.ShowConfig) return finish(s === S.Failed ? "failed" : "cancelled")

  window.__blipQuietUntil = Date.now() + 5000
  SteamClient.Installs.SetInstallFolder(%(folder)d)
  SteamClient.Installs.ContinueInstall()
  // Starting an install also starts the queue, so make that explicit.
  SteamClient.Downloads.EnableAllDownloads(true, "0")
  s = await waitUntil(s => s === S.ShowEULAs || ended(s), 8000)
  if (s === S.ShowEULAs) s = await eula()
  s = await waitUntil(ended, 8000)
  if (!ended(s)) { reveal(); return finish("needs-steam") }
  await sleep(300)
  if (s === S.Failed) return finish("failed")
  if (s === S.Complete) return finish("installing")
  // Declined or closed: check whether it made it into the download queue.
  const listed = await new Promise(resolve => {
    const h = SteamClient.Downloads.RegisterForDownloadItems((paused, items) => {
      h.unregister()
      resolve((items || []).some(c => (c.item_data || []).some(i => i.appid === %(appid)d && !i.completed)))
    })
    setTimeout(() => resolve(false), 2000)
  })
  return finish(listed ? "installing" : "cancelled")
})()
"""


FRIENDS_JS = """
(() => {
  const app = g_FriendsUIApp
  const states = ["offline", "online", "busy", "away", "away", "online", "online"]
  return Array.from(app.FriendStore.all_friends || []).map(f => {
    const p = f.m_persona || {}
    const appid = p.m_unGamePlayedAppID || 0
    const inGame = appid > 0 || (p.m_gameid && p.m_gameid !== "0")
    let game = p.m_strGameExtraInfo || ""
    if (!game && appid) {
      try { game = (app.AppInfoStore.GetAppInfo(appid) || {}).name || "" } catch (e) {}
    }
    const chat = app.ChatStore.GetFriendChat(f.accountid, false)
    return {
      accountid: String(f.accountid),
      steamid: String(p.m_steamid && p.m_steamid.ConvertTo64BitString ? p.m_steamid.ConvertTo64BitString() : ""),
      name: f.m_strNickname || p.m_strPlayerName || String(f.accountid),
      avatar: p.m_strAvatarHash ? "https://avatars.fastly.steamstatic.com/" + p.m_strAvatarHash + "_medium.jpg" : "",
      state: inGame && (p.m_ePersonaState || 0) !== 0 ? "in-game" : states[p.m_ePersonaState || 0] || "online",
      game: game,
      lastOnline: p.m_rtLastSeenOnline || 0,
      unread: chat ? chat.unread_message_count || 0 : 0,
      lastMessage: chat ? chat.time_last_message || 0 : 0,
    }
  })
})()
"""

# Messages are BBCode; turn the common tags into plain text for the widget.
CHAT_JS = """
(async () => {
  const chat = g_FriendsUIApp.ChatStore.GetFriendChat(%(account)d, true)
  if (!chat.m_bChatLogsLoaded) await chat.LoadChatLogs()
  if (%(read)s) chat.OnActivate()
  const me = g_FriendsUIApp.FriendStore.self.accountid
  // Escaped brackets (\\[) are literal text: park them while tags are stripped.
  const plain = s => String(s || "")
    .replace(/\\\\\\[/g, "\\u0001")
    .replace(/\\[emoticon\\](.*?)\\[\\/emoticon\\]/g, ":$1:")
    .replace(/\\[sticker[^\\]]*\\](.*?)\\[\\/sticker\\]/g, "(sticker)")
    .replace(/\\[url=([^\\]]*)\\](.*?)\\[\\/url\\]/g, "$2 ($1)")
    .replace(/\\[img[^\\]]*\\](.*?)\\[\\/img\\]/g, "(image) $1")
    .replace(/\\[\\/?[a-z]+[^\\]]*\\]/gi, "")
    .replace(/\\u0001/g, "[")
  const html = %(html)s
  const msgs = chat.chat_messages.slice(-80).map(m => ({
    mine: m.unAccountID === me,
    text: plain(m.strMessage !== undefined ? m.strMessage : m.strMessageInternal),
    html: html(m.strMessage !== undefined ? m.strMessage : m.strMessageInternal),
    ts: m.rtTimestamp,
    key: m.rtTimestamp + ":" + m.unOrdinal + ":" + (m.m_iLocalEchoID || 0),
    pending: m.unAccountID === me && !m.m_bServerAcknowledged && m.unOrdinal < 0,
    failed: !!(m.eErrorSending || m.eErrorSendingObservable),
  }))
  return { messages: msgs, typing: !!chat.is_friend_typing, unread: chat.unread_message_count || 0 }
})()
"""

# The same BBCode as Qt StyledText for the chat bubble: clickable links
# (tagged and bare), inline emoticons and stickers, basic bold/italic.
HTML_JS = r"""(s => {
  const CDN = "https://steamcommunity-a.akamaihd.net/economy/"
  const KNOWN = /^(spoiler|code|quote|pre|noparse|strike|s|h[1-6]|list|olist|table|tr|td|th|hr|flip|random|lobbyinvite|gameinvite|tradeoffer|broadcastinvite|giphy|video|og|embed|mention|roomeffect|reply|sticker|emoticon|img|url)$/
  const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  const link = (href, label) => /^(https?|steam):/i.test(href)
    ? '<a href="' + esc(href) + '">' + label + '</a>' : label
  const text = t => t.split(/(https?:\/\/[^\s<>"\[\]]+)/i).map((part, i) => {
    if (i % 2 === 0) return esc(part).replace(/\n/g, "<br>")
    const trail = (part.match(/[.,;:!?)']+$/) || [""])[0]
    const url = part.slice(0, part.length - trail.length)
    return link(url, esc(url)) + esc(trail)
  }).join("")
  const img = (src, size) => '<img src="' + esc(src) + '" width="' + size + '" height="' + size + '" align="middle">'
  // Escaped brackets (\[) are literal text: park them while tags are handled.
  s = String(s || "").replace(/\\\[/g, "\u0001")
  const out = []
  const re = /\[(\/?)([a-z]+)((?:=[^\]]*)|(?:\s[^\]]*))?\]/gi
  let last = 0, m, inUrl = null
  const flush = end => {
    const chunk = s.slice(last, end).replace(/\u0001/g, "[")
    if (inUrl) inUrl.label += chunk
    else out.push(text(chunk))
  }
  const arg = (a, key) => {
    const r = new RegExp(key + '="([^"]*)"').exec(a || "")
    return r ? r[1] : ""
  }
  while ((m = re.exec(s))) {
    flush(m.index)
    last = re.lastIndex
    const close = m[1] === "/", tag = m[2].toLowerCase(), a = m[3] || ""
    if (tag === "emoticon" && !close) {
      const end = s.indexOf("[/emoticon]", last)
      const name = s.slice(last, end < 0 ? s.length : end)
      out.push(img(CDN + "emoticon/" + encodeURIComponent(name), 20))
      last = re.lastIndex = end < 0 ? s.length : end + 11
    } else if (tag === "sticker" && !close) {
      const end = s.indexOf("[/sticker]", last)
      out.push((out.join("") ? "<br>" : "") + img(CDN + "sticker/" + encodeURIComponent(arg(a, "type")), 96))
      last = re.lastIndex = end < 0 ? last : end + 10
    } else if (tag === "img" && !close) {
      const end = s.indexOf("[/img]", last)
      const src = arg(a, "src") || s.slice(last, end < 0 ? s.length : end)
      out.push(link(src, "(image)"))
      last = re.lastIndex = end < 0 ? s.length : end + 6
    } else if (tag === "url") {
      if (!close) inUrl = { href: a.charAt(0) === "=" ? a.slice(1).replace(/^"|"$/g, "") : "", label: "" }
      else if (inUrl) {
        const href = inUrl.href || inUrl.label
        out.push(link(href, esc(inUrl.label || href)))
        inUrl = null
      }
    } else if (["b", "i", "u"].indexOf(tag) >= 0) {
      if (!inUrl) out.push("<" + (close ? "/" : "") + tag + ">")
    } else if (!KNOWN.test(tag)) {
      // Not Steam markup (e.g. "[brb]"): keep it as typed.
      last = m.index
      flush(re.lastIndex)
      last = re.lastIndex
    }
  }
  flush(s.length)
  if (inUrl) out.push(link(inUrl.href || inUrl.label, esc(inUrl.label || inUrl.href)))
  return out.join("")
})"""

SEND_JS = """
(() => {
  const chat = g_FriendsUIApp.ChatStore.GetFriendChat(%(account)d, true)
  chat.SendChatMessage(%(text)s)
  return "sent"
})()
"""


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "eval":
        return evaluate(argv[2])
    if cmd == "folders":
        return evaluate(FOLDERS_JS)
    if cmd == "uninstall":
        # What Steam's own "Uninstall" confirmation calls once you confirm.
        return evaluate('SteamClient.Installs.OpenUninstallWizard([%d], true); "uninstalling"' % int(argv[2]))
    if cmd == "friends":
        return evaluate(FRIENDS_JS)
    if cmd == "chat":
        read = "true" if len(argv) > 3 and argv[3] == "read" else "false"
        return evaluate(CHAT_JS % {"account": int(argv[2]), "read": read, "html": HTML_JS})
    if cmd == "send":
        return evaluate(SEND_JS % {"account": int(argv[2]), "text": json.dumps(sys.stdin.read())})
    if cmd == "wizard-state":
        return evaluate("SteamClient.Installs.GetInstallManagerInfo().then(i => i.eInstallState)")
    if cmd == "overview":
        return evaluate(OVERVIEW_JS)
    if cmd == "pause":
        return evaluate(PAUSE_JS % {"appid": int(argv[2])})
    if cmd == "resume":
        return evaluate(RESUME_JS % {"appid": int(argv[2])})
    if cmd == "install":
        return evaluate(INSTALL_JS % {"appid": int(argv[2]), "folder": int(argv[3])}, timeout=660)
    raise ValueError("unknown command: %s" % cmd)


if __name__ == "__main__":
    try:
        out = json.dumps({"ok": True, "value": main(sys.argv)})
        if len(out) > MAX_OUTPUT:
            raise RuntimeError("Steam's answer was too large to show")
        print(out)
    except Exception as e:
        # Most likely Steam isn't running, or was started before the
        # debugging flag file existed.
        msg = str(e)
        if isinstance(e, (OSError, urllib.error.URLError)):
            msg = "Can't reach Steam. Is it running?"
        print(json.dumps({"ok": False, "error": msg[:500]}))
        sys.exit(1)
