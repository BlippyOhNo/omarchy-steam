import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Steam popup: recently played games, the rest of the library, friends with
// their online status, downloads, and the store's top sellers, popular
// upcoming and new releases (50 each), whose store pages open in a pane
// beside the list. Tabs run down a rail on the popup's left edge. Everything comes from steam.py, which
// reads the local Steam client's caches (no sign-in needed); friend status is
// fetched from Steam Community, or the Web API when an apiKey is set.
// Installing, pausing and resuming go through steamctl.py, which drives the
// running Steam client over its CEF debugging port so no Steam window opens.
Panel {
  id: root
  moduleName: "blip.steam"
  ipcTarget: "blip.steam"
  manageIpc: false

  property string tab: "recent"
  readonly property var tabOrder: ["store", "recent", "library", "friends"]
  // The Store tab's own lists, shown as sub-tabs above its rows.
  property string storeKind: "top"
  readonly property var storeKinds: ["top", "upcoming", "new"]
  property int rowIndex: 0
  property bool cursorActive: false
  property var games: []
  property var friends: []
  property bool gamesLoaded: false
  property bool friendsLoaded: false
  property var storeLists: ({})
  property bool storeListsLoaded: false
  property string errorText: ""
  property string friendsError: ""
  property string filterText: ""
  // Library ticks under the search field: most played first (played
  // games only) and uninstalled only.
  property bool mostPlayed: false
  property bool uninstalledOnly: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string script: Qt.resolvedUrl("steam.py").toString().replace(/^file:\/\//, "")
  readonly property int recentCount: Math.max(1, Number(setting("recentCount", 10)))
  readonly property string apiKey: String(setting("apiKey", "") || "")
  readonly property string installDrive: String(setting("installDrive", "") || "")
  readonly property string ctlScript: Qt.resolvedUrl("steamctl.py").toString().replace(/^file:\/\//, "")

  // Steam library folders (steamctl.py folders) and whether the running
  // client accepts commands (its debugging port is up). Without it, installs
  // fall back to Steam's own dialog and pause/resume are hidden.
  property var folders: []
  property bool controllable: false
  property string actionError: ""
  readonly property var preferredFolder: {
    var want = installDrive.trim().toLowerCase()
    var fallback = null
    for (var i = 0; i < folders.length; i++) {
      var f = folders[i]
      if (want !== "" && f.path.toLowerCase().indexOf(want) >= 0) return f
      if (f.isDefault) fallback = f
    }
    return fallback || (folders.length ? folders[0] : null)
  }

  // Steam's own presence colours; the theme accent is too grey to read as "online".
  readonly property color inGameColor: "#90ba3c"
  readonly property color onlineColor: "#57cbde"
  // The theme's urgent colour is grey here too, so uninstall gets a real red.
  readonly property color dangerColor: "#e0524d"

  readonly property var recentGames: {
    var out = []
    for (var i = 0; i < games.length && out.length < recentCount; i++)
      if (games[i].lastPlayed > 0 && games[i].installed) out.push(games[i])
    return out
  }

  readonly property var libraryGames: {
    var q = filterText.trim().toLowerCase()
    var out = []
    for (var j = 0; j < games.length; j++) {
      var g = games[j]
      if (q !== "" && g.name.toLowerCase().indexOf(q) < 0) continue
      if (uninstalledOnly && g.installed) continue
      if (mostPlayed && !(g.playtime > 0)) continue
      out.push(g)
    }
    // Most played: by hours. Otherwise installed first, then by name.
    out.sort(function(a, b) {
      if (mostPlayed && a.playtime !== b.playtime) return b.playtime - a.playtime
      if (!mostPlayed && a.installed !== b.installed) return a.installed ? -1 : 1
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    })
    return out
  }

  // The selected store list, marked with what you own and have installed so
  // those rows act like library rows.
  readonly property var storeRows: {
    var list = storeLists[storeKind] && storeLists[storeKind].games ? storeLists[storeKind].games : []
    var mine = {}
    for (var i = 0; i < games.length; i++) mine[games[i].appid] = games[i]
    var out = []
    for (var j = 0; j < list.length; j++) {
      var p = list[j], g = mine[p.appid]
      out.push(Object.assign({}, p, { owned: !!g, installed: !!g && g.installed, icon: g ? g.icon : "" }))
    }
    return out
  }

  readonly property int friendsOnline: {
    var n = 0
    for (var i = 0; i < friends.length; i++)
      if (friends[i].state !== "offline" && friends[i].state !== "unknown") n++
    return n
  }

  readonly property var rows: tab === "recent" ? recentGames : tab === "library" ? libraryGames
    : tab === "store" ? storeRows : friends

  // Active/queued/paused downloads from `steam.py downloads`, each with a
  // smoothed `speed` (bytes/s) worked out here from successive samples.
  property var downloads: []
  // The Downloads section above the list folds down to its header (d).
  property bool downloadsExpanded: true
  property var downloadSamples: ({})
  readonly property var downloadsById: {
    var map = {}
    for (var i = 0; i < downloads.length; i++) map[downloads[i].appid] = downloads[i]
    return map
  }
  readonly property var activeDownload: {
    for (var i = 0; i < downloads.length; i++)
      if (downloads[i].status !== "paused" && downloads[i].status !== "queued") return downloads[i]
    return null
  }

  function refreshDownloads() { if (!downloadsProc.running) downloadsProc.running = true }

  function updateDownloads(list, now) {
    var prev = downloadSamples
    var next = {}
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      var p = prev[d.appid]
      var speed = 0
      if (p && d.status === "downloading" && now > p.time) {
        var instant = Math.max(0, (d.staged - p.staged) / (now - p.time))
        // Light smoothing: Steam writes in bursts.
        speed = p.speed > 0 ? p.speed * 0.6 + instant * 0.4 : instant
        // Stalled or restarted: don't let the smoothing trail off forever.
        if (d.staged < p.staged || speed < 1024) speed = 0
      }
      d.speed = speed
      next[d.appid] = { staged: d.staged, time: now, speed: speed }
    }
    downloadSamples = next
    downloads = list
  }

  function sizeLabel(bytes) {
    if (bytes >= 1e9) return (bytes / 1e9).toFixed(bytes >= 1e10 ? 0 : 1) + " GB"
    if (bytes >= 1e6) return Math.round(bytes / 1e6) + " MB"
    return Math.round(bytes / 1e3) + " KB"
  }

  // Steam's own estimate when we have it, else from the bytes still to go.
  function downloadEta(d) {
    return d.eta > 0 ? d.eta : (d.total - d.staged) / d.speed
  }

  function etaLabel(seconds) {
    if (seconds < 60) return "<1 min left"
    if (seconds < 3600) return Math.round(seconds / 60) + " min left"
    var h = Math.floor(seconds / 3600)
    var m = Math.round((seconds % 3600) / 60)
    return h + " h " + (m ? m + " min " : "") + "left"
  }

  function downloadLine(d, withEta) {
    if (d.status === "paused") return "Paused · " + Math.floor(d.progress * 100) + "%"
    if (d.status === "queued") return "Queued"
    if (d.status === "installing") return "Installing…"
    if (d.status === "verifying") return "Verifying…"
    if (d.status === "preparing") return "Preparing…"
    if (!d.total) return "Downloading…"
    var done = sizeLabel(d.staged), total = sizeLabel(d.total)
    // "1.2 / 3.4 GB" when both share a unit, to keep the line short.
    if (done.slice(-2) === total.slice(-2)) done = done.slice(0, -3)
    var parts = [done + " / " + total]
    if (d.speed > 0) {
      parts.push(sizeLabel(d.speed) + "/s")
      var eta = downloadEta(d)
      if (withEta !== false && isFinite(eta) && eta < 30 * 86400) parts.push(etaLabel(eta))
    }
    return parts.join(" · ")
  }

  // Library filter checkbox: filled box when on, empty and dimmed when off.
  component FilterTick: Item {
    id: tick
    property string label: ""
    property bool checked: false
    property color foreground
    property color dim
    property string fontFamily
    signal toggled()
    implicitWidth: tickRow.implicitWidth

    Row {
      id: tickRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        text: tick.checked ? "󰄲" : "󰄱"
        color: tick.checked || tickMouse.containsMouse ? tick.foreground : tick.dim
        font.family: tick.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: tick.label
        textFormat: Text.PlainText
        color: tick.checked || tickMouse.containsMouse ? tick.foreground : tick.dim
        font.family: tick.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: tickMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tick.toggled()
    }
  }

  onTabChanged: { rowIndex = 0; armedUninstall = 0; list.positionViewAtBeginning(); if (tab === "store") refreshStoreLists() }
  onStoreKindChanged: { rowIndex = 0; list.positionViewAtBeginning() }
  onFilterTextChanged: rowIndex = 0
  onMostPlayedChanged: { rowIndex = 0; list.positionViewAtBeginning() }
  onUninstalledOnlyChanged: { rowIndex = 0; list.positionViewAtBeginning() }

  // ---------- data ----------
  function refreshGames() { if (!gamesProc.running) gamesProc.running = true }
  // steam.py caches the lists for an hour, so this is cheap to call often.
  function refreshStoreLists() { if (!storeListsProc.running) storeListsProc.running = true }
  // With Steam controllable the friend list comes live from the client
  // (presence, what they're playing, unread chats); otherwise steam.py.
  property bool friendsCtlBusy: false

  function refreshFriends() {
    if (controllable) {
      if (friendsCtlBusy) return
      friendsCtlBusy = true
      runCtl(["friends"], function(ok, value) {
        root.friendsCtlBusy = false
        if (!ok) return
        root.friends = root.sortFriends(value || [])
        root.friendsLoaded = true
        root.friendsError = ""
        root.syncChatFriend()
      })
      return
    }
    if (friendsProc.running) return
    friendsProc.environment = { "STEAM_API_KEY": root.apiKey }
    friendsProc.running = true
  }

  function sortFriends(list) {
    var rank = { "in-game": 0, "online": 1, "busy": 2, "away": 2 }
    return list.slice().sort(function(a, b) {
      if (!!a.unread !== !!b.unread) return a.unread ? -1 : 1
      var ra = rank[a.state] === undefined ? 3 : rank[a.state]
      var rb = rank[b.state] === undefined ? 3 : rank[b.state]
      if (ra !== rb) return ra - rb
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    })
  }

  onControllableChanged: if (controllable) refreshFriends()

  // ---------- chat ----------
  // Clicking a friend widens the popup to the right with a chat pane that
  // reads and sends through the Steam client (steamctl.py chat/send).
  property var chatFriend: null
  property var chatMessages: []
  property string chatSignature: ""
  property bool chatTyping: false
  property bool chatLoaded: false
  property string chatError: ""
  readonly property bool chatOpen: !!chatFriend
  readonly property real railWidth: Style.space(64)
  readonly property real listWidth: railWidth + Style.space(340)
  readonly property var tabInfo: ({
    store: { icon: "󰓜", label: "Store" },
    recent: { icon: "󰋚", label: "Recent" },
    library: { icon: "󰓓", label: "Library" },
    friends: { icon: "󰡉", label: "Friends" }
  })
  readonly property real chatWidth: Style.space(330)
  readonly property int unreadTotal: {
    var n = 0
    for (var i = 0; i < friends.length; i++) n += friends[i].unread || 0
    return n
  }

  function openChat(friend) {
    if (!friend) return
    closeStore()
    if (!controllable) { launch("steam://friends/message/" + friend.steamid); return }
    if (!chatFriend || chatFriend.accountid !== friend.accountid) {
      chatFriend = friend
      chatMessages = []
      chatSignature = ""
      chatLoaded = false
      chatTyping = false
      chatError = ""
      refreshChat()
    }
    Qt.callLater(function() { chatInput.forceActiveFocus() })
  }

  function closeChat() {
    chatFriend = null
    chatMessages = []
    chatSignature = ""
    keyCatcher.forceActiveFocus()
  }

  // ---------- store page ----------
  // Clicking a game you don't own in Store (or pressing i on any game) widens
  // the popup with its store page from `steam.py store`. Buying still
  // happens in Steam.
  property var storeGame: null
  property var storePage: null
  property string storeError: ""
  property int storeWanted: 0
  property int mediaIndex: 0
  property bool storeMuted: true
  readonly property bool storeOpen: !!storeGame
  readonly property real storeWidth: Style.space(460)
  readonly property var storeMedia: storePage && storePage.media ? storePage.media : []
  readonly property var storeOwned: {
    if (!storeGame) return null
    for (var i = 0; i < games.length; i++) if (games[i].appid === storeGame.appid) return games[i]
    return null
  }

  function openStore(game) {
    if (!game) return
    if (chatFriend) { chatFriend = null; chatMessages = []; chatSignature = "" }
    if (storeGame && storeGame.appid === game.appid) return
    storeGame = game
    storeError = ""
    mediaIndex = 0
    if (!storePage || storePage.appid !== game.appid) storePage = null
    storeWanted = game.appid
    loadStore()
  }

  function closeStore() {
    storeGame = null
    storeWanted = 0
  }

  function loadStore() {
    if (storeProc.running || !storeWanted) return
    storeProc.appid = storeWanted
    storeProc.command = ["python3", root.script, "store", String(storeWanted)]
    storeProc.running = true
  }

  function stepMedia(delta) {
    var n = storeMedia.length
    if (n) mediaIndex = (mediaIndex + delta + n) % n
  }

  function buyInSteam() {
    if (storeGame) launch("steam://store/" + storeGame.appid)
  }

  function reviewColor(percent) {
    return percent >= 70 ? "#66c0f4" : percent >= 40 ? "#b9a074" : "#c35c2c"
  }

  function reviewLine(r) {
    if (!r || !r.count) return ""
    return r.label + " · " + r.percent + "% of " + Number(r.count).toLocaleString(Qt.locale(), "f", 0)
  }

  // Keep the header's status current as the friend list refreshes.
  function syncChatFriend() {
    if (!chatFriend) return
    for (var i = 0; i < friends.length; i++)
      if (friends[i].accountid === chatFriend.accountid) { chatFriend = friends[i]; return }
  }

  function refreshChat() {
    if (!chatFriend || chatProc.running) return
    chatProc.account = chatFriend.accountid
    chatProc.command = ["python3", root.ctlScript, "chat", chatFriend.accountid, "read"]
    chatProc.running = true
  }

  function sendChat(text) {
    text = String(text || "").trim()
    if (!text || !chatFriend) return
    chatError = ""
    // Shown straight away (dimmed) until Steam's copy comes back.
    chatMessages = chatMessages.concat([{ mine: true, text: text, ts: Date.now() / 1000,
      key: "local:" + Date.now(), pending: true, failed: false, showTime: false }])
    runCtl(["send", chatFriend.accountid, text], function(ok, value, error) {
      if (!ok) root.chatError = "Couldn't send: " + error
      root.refreshChat()
    })
  }

  function chatTime(ts) {
    var d = new Date(ts * 1000)
    var now = new Date()
    if (d.toDateString() === now.toDateString()) return Qt.formatTime(d, "HH:mm")
    return Qt.formatDateTime(d, d.getFullYear() === now.getFullYear() ? "d MMM, HH:mm" : "d MMM yyyy, HH:mm")
  }

  // Native `steam` when installed, otherwise the Flatpak.
  readonly property var steamCommand: ["sh", "-c",
    "if command -v steam >/dev/null; then exec steam \"$@\"; else exec flatpak run com.valvesoftware.Steam \"$@\"; fi", "steam"]

  function launch(command) {
    Quickshell.execDetached(steamCommand.concat([command]))
    root.close()
  }

  function activateRow(item) {
    if (!item) return
    if (root.tab === "friends") openChat(item)
    else if (root.tab === "store" && !item.owned) openStore(item)
    else if (item.installed) launch("steam://rungameid/" + item.appid)
    else if (downloadsById[item.appid]) toggleDownload(downloadsById[item.appid])
    else installGame(item, preferredFolder)
  }

  // ---------- Steam client commands (steamctl.py) ----------
  property var ctlQueue: []

  function runCtl(args, onDone) {
    ctlQueue = ctlQueue.concat([{ args: args, onDone: onDone }])
    if (!ctlProc.running) nextCtl()
  }

  function nextCtl() {
    if (!ctlQueue.length || ctlProc.running) return
    var job = ctlQueue[0]
    ctlQueue = ctlQueue.slice(1)
    ctlProc.job = job
    ctlProc.command = ["python3", root.ctlScript].concat(job.args)
    ctlProc.running = true
  }

  function refreshFolders() {
    runCtl(["folders"], function(ok, value) {
      root.controllable = ok
      if (ok) root.folders = value || []
    })
  }

  function folderName(f) {
    if (!f) return ""
    if (f.label) return f.label
    if (f.path.indexOf("/.local/share/Steam") >= 0) return "Home"
    var parts = String(f.drive || f.path).split("/").filter(function(x) { return !!x })
    return parts.length ? parts[parts.length - 1] : f.path
  }

  // Installs run one at a time in their own process, since one can sit
  // waiting for a licence agreement to be accepted in Steam. Until Steam's
  // log shows the download, it's listed from pendingInstalls.
  property var installQueue: []
  property var pendingInstalls: ({})
  property var installing: null
  // Last drawn progress-bar position per appid (see ProgressGlide).
  property var glideState: ({})

  function installGame(game, folder) {
    if (!game) return
    if (!controllable || !folder) { launch("steam://install/" + game.appid); return }
    if (pendingInstalls[game.appid] || downloadsById[game.appid]) return
    if (opened) reopenUntil = Date.now() + 6000
    actionError = ""
    var pending = Object.assign({}, pendingInstalls)
    pending[game.appid] = { appid: game.appid, name: game.name, status: "preparing", staged: 0, total: 0,
      progress: 0, header: game.header, icon: game.icon, speed: 0, since: Date.now() }
    pendingInstalls = pending
    downloads = mergePending(downloads)
    installQueue = installQueue.concat([{ game: game, folder: folder }])
    nextInstall()
  }

  function nextInstall() {
    if (installProc.running || !installQueue.length) return
    installing = installQueue[0]
    installQueue = installQueue.slice(1)
    installProc.command = ["python3", root.ctlScript, "install", String(installing.game.appid), String(installing.folder.index)]
    installProc.running = true
    eulaHint.restart()
  }

  function dropPending(appid) {
    var pending = Object.assign({}, pendingInstalls)
    delete pending[appid]
    pendingInstalls = pending
  }

  // Keep a just-started install listed until Steam reports it (or 30s pass).
  function mergePending(list) {
    var seen = {}
    for (var i = 0; i < list.length; i++) seen[list[i].appid] = true
    var out = list.slice()
    var now = Date.now()
    for (var id in pendingInstalls) {
      var p = pendingInstalls[id]
      var waiting = installing && installing.game.appid === p.appid
      if (seen[p.appid] || (!waiting && now - p.since > 30000)) { dropPending(p.appid); continue }
      out.push(p)
    }
    return out
  }

  // ---------- uninstalling ----------
  // appid -> true while Steam removes it; cleared once the library no longer
  // lists it as installed. armedUninstall is the game whose X was clicked
  // once and now asks for a second click to confirm.
  property var uninstalling: ({})
  property int armedUninstall: 0

  function uninstallGame(game) {
    if (!game || !game.installed || !controllable || uninstalling[game.appid]) return
    armedUninstall = 0
    actionError = ""
    var busy = Object.assign({}, uninstalling)
    busy[game.appid] = true
    uninstalling = busy
    runCtl(["uninstall", String(game.appid)], function(ok, value, error) {
      if (!ok) {
        root.actionError = "Couldn't uninstall " + game.name + ": " + error
        var b = Object.assign({}, root.uninstalling)
        delete b[game.appid]
        root.uninstalling = b
      }
      root.refreshGames()
    })
  }

  // X on the keyboard: first press arms the selected game, second uninstalls.
  function uninstallSelected() {
    if (!cursorActive || tab === "friends") return
    var game = rows[rowIndex]
    if (!game || !game.installed) return
    if (armedUninstall === game.appid) uninstallGame(game)
    else armedUninstall = game.appid
  }

  onRowIndexChanged: armedUninstall = 0

  // Watch the library until Steam has finished removing each game.
  Timer {
    interval: 1500
    repeat: true
    running: Object.keys(root.uninstalling).length > 0
    onTriggered: root.refreshGames()
  }

  onGamesChanged: {
    var ids = Object.keys(uninstalling)
    if (!ids.length) return
    var still = {}
    for (var i = 0; i < games.length; i++)
      if (uninstalling[games[i].appid] && games[i].installed) still[games[i].appid] = true
    if (Object.keys(still).length !== ids.length) uninstalling = still
  }

  function setDownloadStatus(appid, status) {
    var list = []
    for (var i = 0; i < downloads.length; i++) {
      var d = downloads[i]
      if (d.appid === appid) { d = Object.assign({}, d); d.status = status; d.speed = 0 }
      list.push(d)
    }
    downloads = list
  }

  function toggleDownload(d) {
    if (!d || !controllable) { launch("steam://open/downloads"); return }
    var pausing = d.status !== "paused"
    setDownloadStatus(d.appid, pausing ? "paused" : "preparing")
    runCtl([pausing ? "pause" : "resume", String(d.appid)], function(ok, value, error) {
      if (!ok) root.actionError = error
      settleTimer.restart()
    })
  }

  function imageSource(path) {
    if (!path) return ""
    return path.indexOf("http") === 0 ? path : "file://" + path
  }

  function storeLine(g) {
    var price = g.price ? g.price + (g.discount ? " (−" + g.discount + "%)" : "") : ""
    var mine = root.uninstalling[g.appid] ? "Uninstalling…" : g.installed ? "Installed" : g.owned ? "In library" : ""
    var released = String(g.released || "").replace(", " + new Date().getFullYear(), "")
    var parts = storeKind === "upcoming" ? ["#" + g.rank, released, mine || price]
      : storeKind === "new" ? [released, mine || price]
      : ["#" + g.rank, mine || price]
    return parts.filter(function(x) { return !!x }).join(" · ")
  }

  function playedLabel(ts) {
    if (!ts) return "Never played"
    var now = new Date()
    var then = new Date(ts * 1000)
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var day = new Date(then.getFullYear(), then.getMonth(), then.getDate()).getTime()
    var days = Math.round((today - day) / 86400000)
    if (days <= 0) return "Today"
    if (days === 1) return "Yesterday"
    if (days < 7) return days + " days ago"
    if (days < 30) return Math.floor(days / 7) + (days < 14 ? " week ago" : " weeks ago")
    if (then.getFullYear() === now.getFullYear()) return Qt.formatDate(then, "d MMMM")
    return Qt.formatDate(then, "d MMM yyyy")
  }

  function playtimeLabel(minutes) {
    if (!minutes) return ""
    if (minutes < 60) return minutes + " min"
    var h = minutes / 60
    return (h < 10 ? h.toFixed(1) : Math.round(h)) + " h"
  }

  function stateColor(state) {
    if (state === "in-game") return inGameColor
    if (state === "online") return onlineColor
    if (state === "away" || state === "busy") return Qt.darker(onlineColor, 1.6)
    return dim
  }

  function friendLine(f) {
    if (f.state === "in-game") return f.game ? "Playing " + f.game : "In-Game"
    if (f.state === "unknown") return "Status unavailable"
    return f.statusText || (f.state.charAt(0).toUpperCase() + f.state.slice(1))
  }

  // ---------- keyboard ----------
  // Left/Right walk the store's lists, then the other tabs.
  function switchTab(delta) {
    var views = storeKinds.map(function(k) { return "store:" + k }).concat(tabOrder.slice(1))
    var i = views.indexOf(tab === "store" ? "store:" + storeKind : tab) + delta
    if (i < 0 || i >= views.length) return
    var v = views[i].split(":")
    tab = v[0]
    if (v[1]) storeKind = v[1]
  }

  function moveRow(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (tab === "library" && delta < 0 && rowIndex === 0) { focusFilter(); return }
    var n = rows.length
    if (!n) return
    rowIndex = Math.max(0, Math.min(n - 1, rowIndex + delta))
    list.positionViewAtIndex(rowIndex, ListView.Contain)
    if (storeOpen && tab !== "friends") openStore(rows[rowIndex])
  }

  function focusFilter() {
    if (tab !== "library") tab = "library"
    filterField.forceActiveFocus()
    cursorActive = false
  }

  // ---------- routing (open on the main monitor, like the other widgets) ----------
  readonly property string screenName: {
    var w = button.QsWindow.window
    return w && w.screen ? String(w.screen.name) : ""
  }
  property string mainMonitor: ""

  function instances() {
    return bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) || [root] : [root]
  }

  function mainInstance() {
    mainMonitorProc.running = true  // refresh for next time
    var items = instances()
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].screenName === mainMonitor) return items[i]
    return root
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.mainInstance().open() }
    function close(): void { var items = root.instances(); for (var i = 0; i < items.length; i++) items[i].close() }
    function show(): void { root.mainInstance().open() }
    function hide(): void { var items = root.instances(); for (var i = 0; i < items.length; i++) items[i].close() }
    function toggle(): void { root.mainInstance().toggle() }
    function tab(name: string): void { var t = root.mainInstance(); t.tab = name; t.open() }
    function chat(account: string): void {
      var t = root.mainInstance()
      for (var i = 0; i < t.friends.length; i++)
        if (String(t.friends[i].accountid) === account) { t.tab = "friends"; t.open(); t.openChat(t.friends[i]); return }
    }
    function store(appid: string): void {
      var t = root.mainInstance()
      t.tab = "store"
      t.open()
      var list = t.storeRows.concat(t.games)
      for (var i = 0; i < list.length; i++)
        if (String(list[i].appid) === appid) { t.openStore(list[i]); return }
      t.openStore({ appid: Number(appid), name: "" })
    }
    function state(): string {
      var t = root.mainInstance()
      return JSON.stringify({ opened: t.opened, reopenIn: Math.round(t.reopenUntil - Date.now()), installing: !!t.installing,
        controllable: t.controllable, folders: t.folders.length, preferred: t.preferredFolder ? t.preferredFolder.path : null, downloads: t.downloads.map(function(d) { return d.name + ":" + d.status }), error: t.actionError })
    }
  }

  Process {
    id: mainMonitorProc
    command: ["sh", "-c", "hyprctl getoption cursor:default_monitor -j | jq -r '.str // empty'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text || "").trim()
        root.mainMonitor = name === "[[EMPTY]]" ? "" : name
      }
    }
  }

  Component.onCompleted: { mainMonitorProc.running = true; refreshGames(); refreshDownloads(); refreshFolders() }

  // Downloads: quick checks while one is running or the popup is open (the
  // bar icon shows progress too), a slow check otherwise to notice new ones.
  Timer {
    interval: root.opened || root.activeDownload ? 2000 : 10000
    running: true
    repeat: true
    onTriggered: root.refreshDownloads()
  }

  Process {
    id: installProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var job = root.installing
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "no reply" } }
        eulaHint.stop()
        if (job) {
          var name = job.game.name
          if (!r.ok) root.actionError = "Couldn't install " + name + ": " + (r.error || "no reply")
          else if (r.value === "needs-steam") root.actionError = "Steam needs you to finish installing " + name + " in its window."
          else if (r.value === "failed") root.actionError = "Steam couldn't install " + name + "."
          else if (r.value === "cancelled") root.actionError = ""
          else if (root.actionError.indexOf("licence") >= 0) root.actionError = ""
          if (!r.ok || r.value === "cancelled" || r.value === "needs-steam" || r.value === "failed") {
            root.dropPending(job.game.appid)
            root.downloads = root.downloads.filter(function(d) { return d.appid !== job.game.appid || d.total > 0 })
          } else {
            // Restart the grace period from when Steam actually took it.
            var p = root.pendingInstalls[job.game.appid]
            if (p) p.since = Date.now()
          }
        }
        root.installing = null
        settleTimer.restart()
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextInstall)
  }

  // An install still waiting after a few seconds is at a licence agreement.
  Timer {
    id: eulaHint
    interval: 4000
    onTriggered: if (root.installing)
      root.actionError = "Accept the licence agreement for " + root.installing.game.name + " in Steam's window to start the download."
  }

  Process {
    id: ctlProc
    property var job: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var job = ctlProc.job
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "no reply" } }
        if (job && job.onDone) job.onDone(!!r.ok, r.value, r.error || "")
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextCtl)
  }

  // Steam takes a moment to report a pause/resume/install in its log.
  Timer {
    id: settleTimer
    interval: 1200
    onTriggered: root.refreshDownloads()
  }

  Process {
    id: downloadsProc
    command: ["python3", root.script, "downloads"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          var wasDownloading = root.downloads.length > 0
          if (d.controllable !== undefined && d.controllable !== root.controllable) {
            root.controllable = d.controllable
            if (d.controllable) root.refreshFolders()
          }
          if (d.downloads) root.updateDownloads(root.mergePending(d.downloads), d.time || Date.now() / 1000)
          // A finished download changes what's installed.
          if (wasDownloading && root.downloads.length === 0) root.refreshGames()
        } catch (e) {}
      }
    }
  }

  // Steam's install dialog flashes up for a moment even when hidden, taking
  // keyboard focus and so closing this popup. While a quiet install is
  // starting, reopen it -- unless you closed it, or Steam is now showing a
  // licence agreement you need to see.
  property real reopenUntil: 0
  property bool reopening: false

  Timer {
    id: reopenTimer
    interval: 400
    onTriggered: root.runCtl(["wizard-state"], function(ok, state) {
      if (root.opened || Date.now() > root.reopenUntil || (ok && state === 8)) return
      root.reopening = true
      root.open()
    })
  }

  onOpenedChanged: {
    if (!opened) { armedUninstall = 0; chatFriend = null; chatMessages = []; chatSignature = ""; closeStore() }
    if (!opened && Date.now() < reopenUntil) { reopenTimer.restart(); return }
    if (opened && reopening) { reopening = false; return }
    if (opened) {
      refreshGames()
      refreshFriends()
      refreshDownloads()
      refreshFolders()
      actionError = ""
      cursorActive = false
      rowIndex = 0
    } else if (filterText !== "") {
      filterText = ""
      filterField.text = ""
    }
  }

  // Friends: live from Steam every few seconds while open (and slowly while
  // closed, for the bar's unread dot). Without Steam control, only while
  // open: the API is cheap, the per-profile fallback isn't.
  Timer {
    interval: root.controllable ? (root.opened ? 5000 : 20000) : (root.apiKey !== "" ? 30000 : 90000)
    running: root.opened || root.controllable
    repeat: true
    onTriggered: root.refreshFriends()
  }

  Timer {
    interval: 1500
    running: root.opened && root.chatOpen
    repeat: true
    onTriggered: root.refreshChat()
  }

  Process {
    id: chatProc
    property string account: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.chatFriend || root.chatFriend.accountid !== chatProc.account) return
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "no reply" } }
        if (!r.ok) { root.chatError = r.error || "Couldn't load the chat"; return }
        var v = r.value || {}
        root.chatTyping = !!v.typing
        root.chatLoaded = true
        var list = v.messages || []
        var sig = JSON.stringify(list)
        if (sig === root.chatSignature) return
        root.chatSignature = sig
        // A time label above the first message and after 5+ quiet minutes.
        for (var i = 0; i < list.length; i++)
          list[i].showTime = i === 0 || list[i].ts - list[i - 1].ts > 300
        root.chatMessages = list
      }
    }
  }

  Process {
    id: gamesProc
    command: ["python3", root.script, "games"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.errorText = d.error || ""
          if (d.games) root.games = d.games
        } catch (e) {
          root.errorText = "Couldn't read your Steam library"
        }
        root.gamesLoaded = true
      }
    }
  }

  Process {
    id: storeProc
    property int appid: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(String(text || "{}")) } catch (e) { d = { error: "Couldn't read the store page" } }
        if (storeProc.appid === root.storeWanted) {
          root.storeError = d.error || ""
          root.storePage = d.error ? null : d
          root.mediaIndex = 0
        }
      }
    }
    // Moving through the list while a page loads: fetch the latest one next.
    onRunningChanged: if (!running && root.storeWanted && root.storeWanted !== appid) Qt.callLater(root.loadStore)
  }

  Process {
    id: storeListsProc
    command: ["python3", root.script, "storelists"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          if (!d.error) root.storeLists = d
        } catch (e) {
          root.storeLists = { error: "Couldn't load the store" }
        }
        root.storeListsLoaded = true
      }
    }
  }

  Process {
    id: friendsProc
    command: ["python3", root.script, "friends"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.friendsError = d.error || ""
          if (d.friends) root.friends = d.friends
        } catch (e) {
          root.friendsError = "Couldn't load friends"
        }
        root.friendsLoaded = true
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓓"
    tooltipText: root.activeDownload
      ? root.activeDownload.name + " · " + (root.activeDownload.status === "downloading" && root.activeDownload.total
          ? Math.floor(root.activeDownload.progress * 100) + "% · " + root.downloadLine(root.activeDownload)
          : root.downloadLine(root.activeDownload))
      : root.recentGames.length ? "Steam · last played " + root.recentGames[0].name : "Steam"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) Quickshell.execDetached(steamCommand)
      else if (buttonCode === Qt.MiddleButton && root.recentGames.length) root.launch("steam://rungameid/" + root.recentGames[0].appid)
      else { root.reopenUntil = 0; root.toggle() }
    }
  }

  // Unread Steam chats: a small dot on the icon.
  Rectangle {
    visible: root.unreadTotal > 0
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.onlineColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: Style.space(3)
    anchors.topMargin: Style.space(4)
  }

  // Thin progress line under the icon while something downloads.
  Rectangle {
    visible: !!root.activeDownload
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(2)
    width: Style.space(16)
    height: Style.space(2)
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

    Rectangle {
      width: parent.width * barGlide.value
      height: parent.height
      radius: parent.radius
      color: root.foreground
    }

    ProgressGlide { id: barGlide; download: root.activeDownload; active: parent.visible }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // The chat and store panes widen the popup beside the list.
    contentWidth: root.listWidth + (root.chatOpen ? root.chatWidth : root.storeOpen ? root.storeWidth : 0)
    contentHeight: Style.space(500)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: filterField.activeFocus || chatInput.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.storeOpen) root.stepMedia(dx)
        else if (dx !== 0) root.switchTab(dx)
        else root.moveRow(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateRow(root.rows[root.rowIndex])
      onCloseRequested: {
        if (root.storeOpen) { root.closeStore(); return }
        root.reopenUntil = 0
        root.close()
      }
      onDeleteRequested: root.uninstallSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.focusFilter()
        else if (t === "1") root.tab = "store"
        else if (t === "2") root.tab = "recent"
        else if (t === "3") root.tab = "library"
        else if (t === "4") root.tab = "friends"
        else if (t === "i" && root.tab !== "friends" && root.cursorActive) {
          if (root.storeOpen) root.closeStore(); else root.openStore(root.rows[root.rowIndex])
        }
        else if (t === "d" && root.downloads.length) root.downloadsExpanded = !root.downloadsExpanded
        else if (t === "r") { root.refreshGames(); root.refreshFriends(); root.refreshStoreLists() }
      }

      // ---------- tab rail ----------
      Column {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        width: root.railWidth
        spacing: Style.space(4)

        Text {
          width: parent.width
          height: Style.space(56)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "󰓓"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        Repeater {
          model: root.tabOrder

          Rectangle {
            id: railTab
            required property string modelData
            readonly property bool selected: root.tab === modelData
            readonly property int badge: modelData === "friends" ? (root.unreadTotal || root.friendsOnline) : 0
            width: rail.width
            height: Style.space(54)
            radius: Style.space(6)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
              selected ? 0.12 : railMouse.containsMouse ? 0.06 : 0)
            border.width: selected ? 1 : 0
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)

            Column {
              anchors.centerIn: parent
              spacing: Style.space(3)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.tabInfo[railTab.modelData].icon
                color: railTab.selected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.tabInfo[railTab.modelData].label
                color: railTab.selected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: railTab.selected
              }
            }

            // Friends online, or unread chats (in Steam's in-game green).
            Rectangle {
              visible: railTab.badge > 0
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(4)
              width: Math.max(height, badgeText.implicitWidth + Style.space(8))
              height: badgeText.implicitHeight + Style.space(2)
              radius: height / 2
              color: root.unreadTotal ? root.inGameColor : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)

              Text {
                id: badgeText
                anchors.centerIn: parent
                text: railTab.badge
                color: root.unreadTotal ? "black" : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption * 0.9
                font.bold: true
              }
            }

            MouseArea {
              id: railMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.tab = railTab.modelData
            }
          }
        }
      }

      Rectangle {
        anchors.left: rail.right
        anchors.leftMargin: Style.space(8)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      }

      ColumnLayout {
        id: listPane
        anchors.left: rail.right
        anchors.leftMargin: Style.space(17)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.listWidth - root.railWidth - Style.space(17) - panel.padding * 2
        spacing: Style.space(10)

        // ---------- header (lines up with the rail's logo) ----------
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(56)

          Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.tabInfo[root.tab] ? root.tabInfo[root.tab].label : "Steam"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: (root.games.length + " GAMES") + (root.friendsLoaded ? " · " + root.friendsOnline + " FRIENDS ONLINE" : "")
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
        }

        ButtonGroup {
          Layout.fillWidth: true
          visible: root.tab === "store"
          focusable: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          value: root.storeKind
          options: [
            { value: "top", label: "Top Sellers" },
            { value: "upcoming", label: "Upcoming" },
            { value: "new", label: "New Releases" }
          ]
          onChanged: function(v) { root.storeKind = v }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.tab === "library"
          spacing: Style.space(6)

          TextField {
            id: filterField
            Layout.fillWidth: true
            placeholderText: "Search " + root.games.length + " games  (/)"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onTextEdited: root.filterText = text
            onVisibleChanged: if (!visible && activeFocus) keyCatcher.forceActiveFocus()
  
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text !== "") { text = ""; root.filterText = "" }
                else root.close()
                event.accepted = true
              } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                keyCatcher.forceActiveFocus()
                root.cursorActive = true
                root.rowIndex = 0
                if (event.key !== Qt.Key_Down && root.rows.length) root.activateRow(root.rows[0])
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                keyCatcher.forceActiveFocus()
                root.switchPanel(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                event.accepted = true
              }
            }
          }

          RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(14)

          FilterTick {
            label: "Most played"
            implicitHeight: filterField.height
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
            checked: root.mostPlayed
            onToggled: root.mostPlayed = !root.mostPlayed
          }

          FilterTick {
            label: "Uninstalled"
            implicitHeight: filterField.height
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
            checked: root.uninstalledOnly
            onToggled: root.uninstalledOnly = !root.uninstalledOnly
          }

          Item { Layout.fillWidth: true }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          textFormat: Text.PlainText
          text: root.tab === "friends" ? root.friendsError
            : root.tab === "store" ? (root.actionError || (root.storeLists[root.storeKind] || {}).error || root.storeLists.error || "")
            : (root.actionError || root.errorText)
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- downloads ----------
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.tab !== "friends" && root.downloads.length > 0
          spacing: Style.space(6)

          // Header doubles as the toggle; folded, it keeps a one-line summary.
          Item {
            Layout.fillWidth: true
            implicitHeight: dlHeader.implicitHeight

            RowLayout {
              id: dlHeader
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "DOWNLOADS" + (root.downloads.length > 1 ? " · " + root.downloads.length : "")
                foreground: dlToggle.containsMouse ? Qt.lighter(root.foreground, 1.2) : root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                visible: !root.downloadsExpanded
                textFormat: Text.PlainText
                text: {
                  var d = root.activeDownload || root.downloads[0]
                  return d ? d.name + " · " + root.downloadLine(d) : ""
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Item { Layout.fillWidth: true; visible: root.downloadsExpanded }

              Text {
                text: root.downloadsExpanded ? "󰅀" : "󰅂"
                color: dlToggle.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: dlToggle
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.downloadsExpanded = !root.downloadsExpanded
            }

            PanelToolTip {
              visible: dlToggle.containsMouse
              text: root.downloadsExpanded ? "Collapse downloads (d)" : "Show downloads (d)"
            }
          }

          Repeater {
            model: root.downloadsExpanded ? root.downloads.slice(0, 3) : []
            DownloadRow {
              required property var modelData
              Layout.fillWidth: true
              download: modelData
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.downloadsExpanded && root.downloads.length > 3
            textFormat: Text.PlainText
            text: "and " + (root.downloads.length - 3) + " more in the queue"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            leftPadding: Style.space(6)
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
        }

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          model: root.rows
          ScrollBar.vertical: ScrollBar { id: listBar; policy: ScrollBar.AsNeeded }

          delegate: Loader {
            required property var modelData
            required property int index
            // Leave a gutter for the scrollbar so it doesn't sit on the row's buttons.
            width: list.width - (list.contentHeight > list.height ? listBar.width + Style.space(2) : 0)
            sourceComponent: root.tab === "friends" ? friendRow : root.tab === "recent" ? recentRow
              : root.tab === "store" ? storeRow : libraryRow
            property var entry: modelData
            property int rowIdx: index
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: root.rows.length === 0
            textFormat: Text.PlainText
            text: root.tab === "friends"
              ? (root.friendsLoaded ? "No friends found" : "Checking who's online…")
              : root.tab === "store" ? (root.storeListsLoaded ? "Couldn't load the store" : "Loading the Steam store…")
              : !root.gamesLoaded ? "Reading your library…"
              : root.tab === "library" && root.filterText !== "" ? "No games match “" + root.filterText + "”"
              : root.tab === "library" && (root.mostPlayed || root.uninstalledOnly) ? "No games match these filters"
              : root.tab === "recent" ? "No recently played games" : "No games"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      // ---------- chat pane ----------
      Item {
        id: chatPane
        visible: root.chatOpen
        anchors.left: listPane.right
        anchors.leftMargin: panel.padding * 2
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        Rectangle {
          anchors.right: parent.left
          anchors.rightMargin: panel.padding
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            ClippingRectangle {
              Layout.preferredWidth: Style.space(32)
              Layout.preferredHeight: Style.space(32)
              radius: Style.space(4)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

              Image {
                anchors.fill: parent
                source: root.chatFriend ? root.chatFriend.avatar : ""
                sourceSize.width: 64
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.chatFriend ? root.chatFriend.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.chatTyping ? "typing…" : root.chatFriend ? root.friendLine(root.chatFriend) : ""
                color: root.chatFriend && root.chatFriend.state !== "offline" ? root.stateColor(root.chatFriend.state) : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              iconText: "󰓓"
              tooltipText: "Open in Steam"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: if (root.chatFriend) root.launch("steam://friends/message/" + root.chatFriend.steamid)
            }

            PanelActionButton {
              iconText: "󰅖"
              tooltipText: "Close chat (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.closeChat()
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Newest message at the bottom, like any chat.
          ListView {
            id: chatList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.space(4)
            verticalLayoutDirection: ListView.BottomToTop
            boundsBehavior: Flickable.StopAtBounds
            model: root.chatMessages.slice().reverse()
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: ChatBubble {
              required property var modelData
              width: chatList.width
              message: modelData
            }

            Text {
              anchors.centerIn: parent
              width: parent.width - Style.space(20)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              visible: root.chatMessages.length === 0
              textFormat: Text.PlainText
              text: root.chatLoaded ? "No recent messages with " + (root.chatFriend ? root.chatFriend.name : "") + ". Say hi!" : "Loading chat…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            Layout.fillWidth: true
            visible: text !== ""
            textFormat: Text.PlainText
            text: root.chatError
            color: root.dangerColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: chatInput
            Layout.fillWidth: true
            placeholderText: root.chatFriend ? "Message " + root.chatFriend.name : ""
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.sendChat(text)
                text = ""
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                if (text !== "") text = ""
                else root.closeChat()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }
          }
        }
      }

      // ---------- store pane ----------
      Item {
        id: storePane
        visible: root.storeOpen
        anchors.left: listPane.right
        anchors.leftMargin: panel.padding * 2
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        readonly property var page: root.storePage
        readonly property var current: root.storeMedia.length ? root.storeMedia[Math.min(root.mediaIndex, root.storeMedia.length - 1)] : null

        Rectangle {
          anchors.right: parent.left
          anchors.rightMargin: panel.padding
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.storeGame && root.storeGame.name ? root.storeGame.name : root.storePage ? root.storePage.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: "󰓓"
              tooltipText: "Open store page in Steam"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.buyInSteam()
            }

            PanelActionButton {
              iconText: "󰅖"
              tooltipText: "Close (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.closeStore()
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          Text {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !storePane.page
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.storeError || "Loading store page…"
            color: root.storeError ? root.dangerColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Flickable {
            id: storeFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !!storePane.page
            clip: true
            contentWidth: width
            contentHeight: storeContent.implicitHeight + Style.space(12)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { id: storeBar; policy: ScrollBar.AsNeeded }

            Connections {
              target: root
              function onStoreGameChanged() { storeFlick.contentY = 0 }
            }

            function scrollPage(delta) {
              contentY = Math.max(0, Math.min(contentHeight - height, contentY + delta * height * 0.85))
            }

            Shortcut {
              sequences: [StandardKey.MoveToNextPage]
              enabled: root.storeOpen && root.opened
              onActivated: storeFlick.scrollPage(1)
            }

            Shortcut {
              sequences: [StandardKey.MoveToPreviousPage]
              enabled: root.storeOpen && root.opened
              onActivated: storeFlick.scrollPage(-1)
            }

            ColumnLayout {
              id: storeContent
              width: storeFlick.width - storeBar.width - Style.space(4)
              spacing: Style.space(10)

              // ----- trailers and screenshots -----
              ClippingRectangle {
                id: viewer
                Layout.fillWidth: true
                Layout.preferredHeight: width * 9 / 16
                radius: Style.space(4)
                color: "black"

                readonly property bool isVideo: !!storePane.current && storePane.current.type === "video"

                Image {
                  anchors.fill: parent
                  visible: !viewer.isVideo || trailer.playbackState === MediaPlayer.StoppedState || !trailer.hasVideo
                  source: storePane.current ? (viewer.isVideo ? storePane.current.thumb : storePane.current.src) : ""
                  sourceSize.width: 920
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  cache: true
                }

                Video {
                  id: trailer
                  anchors.fill: parent
                  visible: viewer.isVideo
                  source: viewer.isVideo && root.opened && root.storeOpen ? storePane.current.src : ""
                  muted: root.storeMuted
                  volume: 0.6
                  fillMode: VideoOutput.PreserveAspectFit
                  onSourceChanged: if (source != "") play()
                  onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState && position > 0 && duration > 0
                                              && position >= duration - 500) root.stepMedia(1)
                }

                MouseArea {
                  id: viewerMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: viewer.isVideo ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: if (viewer.isVideo) {
                    if (trailer.playbackState === MediaPlayer.PlayingState) trailer.pause(); else trailer.play()
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: viewer.isVideo && trailer.playbackState !== MediaPlayer.PlayingState
                  text: "󰐊"
                  color: "white"
                  style: Text.Outline
                  styleColor: Qt.rgba(0, 0, 0, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display * 1.6
                }

                // Hover controls: previous/next and sound.
                Row {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(6)
                  spacing: Style.space(4)
                  visible: viewerMouse.containsMouse || viewerControls.hovered
                  opacity: 0.9
                  HoverHandler { id: viewerControls }

                  Repeater {
                    model: [
                      { icon: "󰒮", tip: "Previous (←)", act: "prev", show: true },
                      { icon: root.storeMuted ? "󰝟" : "󰕾", tip: root.storeMuted ? "Unmute" : "Mute", act: "mute", show: viewer.isVideo },
                      { icon: "󰒭", tip: "Next (→)", act: "next", show: true }
                    ]
                    Rectangle {
                      required property var modelData
                      visible: modelData.show
                      width: Style.space(26)
                      height: Style.space(26)
                      radius: Style.space(4)
                      color: Qt.rgba(0, 0, 0, ctrlMouse.containsMouse ? 0.8 : 0.55)
                      Text {
                        anchors.centerIn: parent
                        text: modelData.icon
                        color: "white"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        id: ctrlMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: modelData.act === "mute" ? root.storeMuted = !root.storeMuted : root.stepMedia(modelData.act === "next" ? 1 : -1)
                      }
                    }
                  }
                }

                Text {
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(8)
                  visible: root.storeMedia.length > 0
                  text: (root.mediaIndex + 1) + " / " + root.storeMedia.length
                  color: "white"
                  style: Text.Outline
                  styleColor: Qt.rgba(0, 0, 0, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              ListView {
                id: thumbs
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(46)
                orientation: ListView.Horizontal
                spacing: Style.space(4)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.storeMedia
                currentIndex: root.mediaIndex
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: ClippingRectangle {
                  required property var modelData
                  required property int index
                  width: Style.space(80)
                  height: Style.space(45)
                  radius: Style.space(3)
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                  border.width: index === root.mediaIndex ? 2 : 0
                  border.color: root.foreground
                  opacity: index === root.mediaIndex || thumbMouse.containsMouse ? 1 : 0.6

                  Image {
                    anchors.fill: parent
                    anchors.margins: index === root.mediaIndex ? 2 : 0
                    source: modelData.thumb || ""
                    sourceSize.width: 160
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: modelData.type === "video"
                    text: "󰐊"
                    color: "white"
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.6)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  MouseArea {
                    id: thumbMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.mediaIndex = index
                  }
                }
              }

              // ----- summary -----
              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: storePane.page ? storePane.page.short : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }

              GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Style.space(12)
                rowSpacing: Style.space(3)

                Repeater {
                  model: {
                    var p = storePane.page
                    if (!p) return []
                    var out = []
                    if (p.reviews.count) out.push({ k: "ALL REVIEWS", v: root.reviewLine(p.reviews), c: root.reviewColor(p.reviews.percent) })
                    if (p.englishReviews.count && p.englishReviews.count !== p.reviews.count)
                      out.push({ k: "ENGLISH", v: root.reviewLine(p.englishReviews), c: root.reviewColor(p.englishReviews.percent) })
                    if (p.releaseDate) out.push({ k: "RELEASE", v: p.releaseDate + (p.earlyAccess ? " · Early Access" : "") })
                    if (p.developers.length) out.push({ k: "DEVELOPER", v: p.developers.join(", ") })
                    if (p.publishers.length) out.push({ k: "PUBLISHER", v: p.publishers.join(", ") })
                    if (p.deck) out.push({ k: "STEAM DECK", v: p.deck, c: p.deck === "Verified" ? root.inGameColor : p.deck === "Playable" ? "#e0b84c" : root.dim })
                    var os = []
                    if (p.platforms.windows) os.push("Windows")
                    if (p.platforms.mac) os.push("macOS")
                    if (p.platforms.linux) os.push("Linux")
                    if (os.length) out.push({ k: "PLATFORMS", v: os.join(", ") })
                    return out
                  }

                  delegate: Item {
                    required property var modelData
                    required property int index
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    implicitHeight: Math.max(infoKey.implicitHeight, infoValue.implicitHeight)

                    Text {
                      id: infoKey
                      width: Style.space(86)
                      text: modelData.k
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1
                    }

                    Text {
                      id: infoValue
                      anchors.left: infoKey.right
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: modelData.v
                      color: modelData.c || root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }

              Flow {
                Layout.fillWidth: true
                spacing: Style.space(4)
                visible: !!storePane.page && storePane.page.tags.length > 0

                Repeater {
                  model: storePane.page ? storePane.page.tags : []
                  Rectangle {
                    required property string modelData
                    width: tagText.implicitWidth + Style.space(12)
                    height: tagText.implicitHeight + Style.space(6)
                    radius: Style.space(3)
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                    Text {
                      id: tagText
                      anchors.centerIn: parent
                      text: modelData
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              // ----- buy box -----
              Rectangle {
                Layout.fillWidth: true
                implicitHeight: buyRow.implicitHeight + Style.space(20)
                radius: Style.space(5)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                visible: !!storePane.page

                RowLayout {
                  id: buyRow
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: !storePane.page ? ""
                      : root.storeOwned ? (root.storeOwned.installed ? "Installed" : "In your library")
                      : (storePane.page.comingSoon ? "Coming soon: " : storePane.page.free ? "Play " : "Buy ") + storePane.page.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }

                  Rectangle {
                    visible: !root.storeOwned && !!storePane.page && storePane.page.discount > 0
                    implicitWidth: discountText.implicitWidth + Style.space(10)
                    implicitHeight: discountText.implicitHeight + Style.space(6)
                    color: "#4c6b22"
                    Text {
                      id: discountText
                      anchors.centerIn: parent
                      text: storePane.page ? "−" + storePane.page.discount + "%" : ""
                      color: "#beee11"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }

                  ColumnLayout {
                    visible: !root.storeOwned && !!storePane.page && storePane.page.price !== ""
                    spacing: 0
                    Text {
                      Layout.alignment: Qt.AlignRight
                      visible: !!storePane.page && storePane.page.discount > 0 && storePane.page.initialPrice !== ""
                      text: storePane.page ? storePane.page.initialPrice : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.strikeout: true
                    }
                    Text {
                      Layout.alignment: Qt.AlignRight
                      text: storePane.page ? storePane.page.price : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Rectangle {
                    implicitWidth: buyText.implicitWidth + Style.space(18)
                    implicitHeight: buyText.implicitHeight + Style.space(10)
                    radius: Style.space(3)
                    color: buyMouse.containsMouse ? "#79b82b" : "#5c9a1c"
                    Text {
                      id: buyText
                      anchors.centerIn: parent
                      text: root.storeOwned ? (root.storeOwned.installed ? "󰐊 Play" : "󰇚 Install")
                        : storePane.page && storePane.page.comingSoon ? "Wishlist in Steam"
                        : storePane.page && storePane.page.free ? "Get in Steam" : "Buy in Steam"
                      color: "white"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    MouseArea {
                      id: buyMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var g = root.storeOwned
                        if (!g) root.buyInSteam()
                        else if (g.installed) root.launch("steam://rungameid/" + g.appid)
                        else root.installGame(g, root.preferredFolder)
                      }
                    }
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: {
                  var p = storePane.page
                  if (!p) return ""
                  var bits = []
                  if (p.dlc) bits.push(p.dlc + " DLC")
                  if (p.achievements) bits.push(p.achievements + " achievements")
                  return bits.concat(p.features).join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ----- about -----
              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.about.length > 0
                text: "ABOUT THIS GAME"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: storePane.page ? storePane.page.about : []

                delegate: Item {
                  id: block
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: modelData.type === "text" ? aboutText.implicitHeight
                    : modelData.w && modelData.h ? width * modelData.h / modelData.w
                    : aboutImage.status === Image.Ready && aboutImage.sourceSize.width ? width * aboutImage.sourceSize.height / aboutImage.sourceSize.width
                    : Style.space(40)

                  // Description videos loop silently, like the store, while on screen.
                  readonly property bool onScreen: {
                    storeFlick.contentY
                    storeFlick.height
                    var p = block.mapToItem(storeContent, 0, 0)
                    return p.y + height > storeFlick.contentY && p.y < storeFlick.contentY + storeFlick.height
                  }

                  Text {
                    id: aboutText
                    width: parent.width
                    visible: block.modelData.type === "text"
                    textFormat: Text.StyledText
                    text: block.modelData.type === "text" ? block.modelData.text : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    lineHeight: 1.15
                  }

                  AnimatedImage {
                    id: aboutImage
                    anchors.fill: parent
                    visible: block.modelData.type === "image" || (block.modelData.type === "video"
                      && !(videoLoader.item && videoLoader.item.playbackState === MediaPlayer.PlayingState && videoLoader.item.hasVideo))
                    source: block.modelData.type === "image" ? root.imageSource(block.modelData.src)
                      : block.modelData.type === "video" ? root.imageSource(block.modelData.poster) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    playing: visible && block.onScreen && root.opened
                  }

                  Loader {
                    id: videoLoader
                    anchors.fill: parent
                    active: block.modelData.type === "video" && block.onScreen && root.opened
                    sourceComponent: Video {
                      source: block.modelData.src
                      muted: true
                      loops: MediaPlayer.Infinite
                      fillMode: VideoOutput.PreserveAspectFit
                      Component.onCompleted: play()
                    }
                  }
                }
              }

              // ----- details -----
              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.contentNotes !== ""
                text: "MATURE CONTENT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: storePane.page ? storePane.page.contentNotes.trim() : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              PanelSectionHeader {
                visible: !!storePane.page && (storePane.page.minimum !== "" || storePane.page.recommended !== "")
                text: "SYSTEM REQUIREMENTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: storePane.page ? [storePane.page.minimum, storePane.page.recommended].filter(function(x) { return !!x }) : []
                Text {
                  required property string modelData
                  Layout.fillWidth: true
                  textFormat: Text.StyledText
                  text: modelData
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.languages !== ""
                text: "LANGUAGES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: storePane.page && storePane.page.languages ? storePane.page.languages
                  + (storePane.page.languages.indexOf("*") >= 0 ? "\n* with full audio" : "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ----- reviews -----
              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.topReviews.length > 0
                text: "MOST HELPFUL REVIEWS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: storePane.page ? storePane.page.topReviews : []
                Rectangle {
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: reviewCol.implicitHeight + Style.space(16)
                  radius: Style.space(4)
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)

                  ColumnLayout {
                    id: reviewCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: (modelData.up ? "󰔓 Recommended" : "󰔑 Not Recommended") + "  ·  " + modelData.hours + " hrs on record"
                        + (modelData.helpful ? "  ·  " + modelData.helpful + " found helpful" : "")
                      color: modelData.up ? "#66c0f4" : "#c35c2c"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: modelData.text.replace(/\[\/?[a-z0-9*]+(=[^\]]*)?\]/gi, "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------- rows ----------
  // Recent: the game's wide header art, when you last played, and total time.
  Component {
    id: recentRow
    RowSurface {
      id: r
      readonly property var game: parent ? parent.entry : null
      rowIdx: parent ? parent.rowIdx : 0
      implicitHeight: Style.space(58)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Item {
          Layout.preferredWidth: Style.space(98)
          Layout.preferredHeight: Style.space(46)

          ClippingRectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            opacity: r.game && root.uninstalling[r.game.appid] ? 0.4 : 1

            Image {
              anchors.fill: parent
              source: r.game ? root.imageSource(r.game.header) : ""
              sourceSize.width: 196
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: r.game ? r.game.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: !r.game ? "" : root.uninstalling[r.game.appid] ? "Uninstalling…"
              : [root.playedLabel(r.game.lastPlayed), root.playtimeLabel(r.game.playtime)]
              .filter(function(x) { return !!x }).join(" · ")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        UninstallBadge {
          game: r.game
          rowActive: r.hasCursor
        }

        Text {
          text: r.game && !r.game.installed ? "󰇚" : "󰐊"
          color: r.hasCursor ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }
    }
  }

  // Library: small icon, name, playtime; uninstalled games are dimmed.
  Component {
    id: libraryRow
    RowSurface {
      id: l
      readonly property var game: parent ? parent.entry : null
      readonly property var download: game ? root.downloadsById[game.appid] || null : null
      readonly property bool showActions: hasCursor && !!game && !game.installed && root.controllable
        && (!download || ["downloading", "paused", "queued", "preparing"].indexOf(download.status) >= 0)
      rowIdx: parent ? parent.rowIdx : 0
      implicitHeight: Style.space(34)

      ProgressLine {
        visible: !!l.download
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(38)
        anchors.rightMargin: Style.space(8)
        anchors.bottomMargin: Style.space(3)
        download: l.download
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)
        opacity: l.game && (l.game.installed || l.download) ? 1 : 0.6

        Item {
          Layout.preferredWidth: Style.space(22)
          Layout.preferredHeight: Style.space(22)

          ClippingRectangle {
            anchors.fill: parent
            radius: Style.space(3)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            opacity: l.game && root.uninstalling[l.game.appid] ? 0.4 : 1

            Image {
              anchors.fill: parent
              source: l.game ? root.imageSource(l.game.icon) : ""
              sourceSize.width: 44
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: l.game ? l.game.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          visible: text !== ""
          text: l.game && root.uninstalling[l.game.appid] ? "Uninstalling…"
            : l.download ? (l.download.status === "paused" ? "Paused" : l.download.total ? Math.floor(l.download.progress * 100) + "%" : "")
            : l.game ? root.playtimeLabel(l.game.playtime) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        UninstallBadge {
          game: l.game
          rowActive: l.hasCursor
          small: true
        }

        Text {
          visible: !l.showActions
          text: l.hasCursor ? (l.game && l.game.installed ? "󰐊" : "󰇚") : (l.game && l.game.installed ? "" : "󰇚")
          Layout.preferredWidth: Style.font.icon
          horizontalAlignment: Text.AlignHCenter
          color: l.hasCursor ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Hovered and not installed: pause/resume if it's downloading,
        // otherwise one install button per Steam library drive (the
        // preferred one bright).
        PanelActionButton {
          readonly property bool paused: !!l.download && l.download.status === "paused"
          visible: l.showActions && !!l.download
          iconText: paused ? "󰐊" : "󰏤"
          tooltipText: paused ? "Resume download" : "Pause download"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.toggleDownload(l.download)
        }

        Repeater {
          model: l.showActions && !l.download ? root.folders : []
          PanelActionButton {
            required property var modelData
            readonly property bool preferred: root.preferredFolder && root.preferredFolder.index === modelData.index
            iconText: root.folderName(modelData) === "Home" ? "󰋜" : "󰋊"
            tooltipText: "Install to " + root.folderName(modelData) + " · " + root.sizeLabel(modelData.free) + " free"
            foreground: preferred ? root.foreground : root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.installGame(l.game, modelData)
          }
        }
      }
    }
  }

  // Store lists: header art, rank, price or release date, or whether you have it.
  // Owned games play/install like library rows; others open their store page.
  Component {
    id: storeRow
    RowSurface {
      id: t
      readonly property var game: parent ? parent.entry : null
      rowIdx: parent ? parent.rowIdx : 0
      implicitHeight: Style.space(58)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Item {
          Layout.preferredWidth: Style.space(98)
          Layout.preferredHeight: Style.space(46)

          ClippingRectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

            Image {
              anchors.fill: parent
              source: t.game ? root.imageSource(t.game.header) : ""
              sourceSize.width: 196
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: t.game ? t.game.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: t.game ? root.storeLine(t.game) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        UninstallBadge {
          game: t.game
          rowActive: t.hasCursor
        }

        Text {
          text: !t.game ? "" : t.game.installed ? "󰐊" : t.game.owned ? "󰇚" : "󰓜"
          color: t.hasCursor ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }
    }
  }

  // Friends: avatar with a presence dot, name, and what they're doing.
  Component {
    id: friendRow
    RowSurface {
      id: f
      readonly property var friend: parent ? parent.entry : null
      readonly property bool isOffline: !friend || friend.state === "offline" || friend.state === "unknown"
      rowIdx: parent ? parent.rowIdx : 0
      current: !!friend && !!root.chatFriend && root.chatFriend.accountid === friend.accountid
      implicitHeight: Style.space(44)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Item {
          Layout.preferredWidth: Style.space(32)
          Layout.preferredHeight: Style.space(32)

          ClippingRectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            opacity: f.isOffline ? 0.45 : 1

            Image {
              anchors.fill: parent
              source: f.friend ? f.friend.avatar : ""
              sourceSize.width: 64
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
          }

          Rectangle {
            visible: !f.isOffline
            width: Style.space(10)
            height: width
            radius: width / 2
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -Style.space(2)
            anchors.bottomMargin: -Style.space(2)
            color: f.friend ? root.stateColor(f.friend.state) : root.dim
            border.width: Style.space(2)
            border.color: Color.background
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: f.friend ? f.friend.name : ""
            color: f.isOffline ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: !f.isOffline
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: f.friend ? root.friendLine(f.friend) : ""
            color: f.friend && !f.isOffline ? root.stateColor(f.friend.state) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Rectangle {
          visible: !!f.friend && f.friend.unread > 0
          Layout.preferredHeight: Style.space(16)
          Layout.preferredWidth: Math.max(height, unreadLabel.implicitWidth + Style.space(10))
          radius: height / 2
          color: root.onlineColor

          Text {
            id: unreadLabel
            anchors.centerIn: parent
            text: f.friend ? String(f.friend.unread) : ""
            color: "black"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          visible: f.hasCursor && !(f.friend && f.friend.unread > 0)
          text: "󰭹"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  // One download: art, name, bytes/speed/time left, and a progress bar.
  // Clicking opens Steam's Downloads page (pause/resume live there).
  component DownloadRow: CursorSurface {
    id: dl
    property var download: null
    foreground: root.foreground
    implicitHeight: dlInner.implicitHeight + Style.space(12)

    MouseArea {
      id: dlMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.launch("steam://open/downloads")
    }
    hasCursor: dlMouse.containsMouse

    RowLayout {
      id: dlInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      ClippingRectangle {
        Layout.preferredWidth: Style.space(72)
        Layout.preferredHeight: Style.space(34)
        radius: Style.space(4)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
        opacity: dl.download && dl.download.status === "paused" ? 0.5 : 1

        Image {
          anchors.fill: parent
          source: dl.download ? root.imageSource(dl.download.header) : ""
          sourceSize.width: 144
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: dl.download ? dl.download.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            visible: !!dl.download && dl.download.total > 0 && dl.download.status !== "queued"
            text: dl.download ? Math.floor(dl.download.progress * 100) + "%" : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        ProgressLine {
          Layout.fillWidth: true
          download: dl.download
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: dl.download ? root.downloadLine(dl.download, false) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            readonly property var d: dl.download
            visible: text !== ""
            text: d && d.status === "downloading" && d.speed > 0 && d.total && root.downloadEta(d) < 30 * 86400 ? root.etaLabel(root.downloadEta(d)).replace(" left", "") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelActionButton {
        readonly property bool paused: !!dl.download && dl.download.status === "paused"
        visible: !!dl.download && root.controllable
          && ["downloading", "paused", "queued", "preparing"].indexOf(dl.download.status) >= 0
        iconText: paused ? "󰐊" : "󰏤"
        tooltipText: paused ? "Resume download" : "Pause download"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.toggleDownload(dl.download)
      }
    }
  }

  // Round X that pops out beside the play button while the row is hovered or
  // selected. The first click turns it into a red "Uninstall" pill; clicking
  // that uninstalls. Moving to another row disarms it.
  component UninstallBadge: Item {
    id: badge
    property var game: null
    property bool rowActive: false
    property bool small: false
    readonly property bool armed: !!game && root.armedUninstall === game.appid
    readonly property bool busy: !!game && !!root.uninstalling[game.appid]
    readonly property bool available: !!game && game.installed && root.controllable && !busy
    readonly property bool shown: available && (rowActive || badgeMouse.containsMouse || armed)
    readonly property real size: small ? Style.space(18) : Style.space(22)

    visible: shown
    implicitWidth: pill.width
    implicitHeight: size
    Layout.preferredWidth: pill.width
    Layout.preferredHeight: size

    onShownChanged: if (!shown && armed) root.armedUninstall = 0

    Rectangle {
      id: pill
      height: badge.size
      width: badge.armed ? label.implicitWidth + badge.size : badge.size
      radius: height / 2
      color: badge.armed || badgeMouse.containsMouse ? root.dangerColor : Color.background
      border.width: 1
      border.color: badge.armed || badgeMouse.containsMouse ? root.dangerColor : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
      anchors.right: parent.right
      scale: badge.shown ? 1 : 0
      transformOrigin: Item.Right
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
      Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 120 } }

      Row {
        anchors.centerIn: parent
        spacing: Style.space(3)

        Text {
          text: "󰅖"
          color: badge.armed || badgeMouse.containsMouse ? "white" : root.foreground
          font.family: root.fontFamily
          font.pixelSize: badge.small ? Style.font.caption : Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: label
          visible: badge.armed
          text: "Uninstall"
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    MouseArea {
      id: badgeMouse
      anchors.fill: pill
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (badge.armed) root.uninstallGame(badge.game)
        else root.armedUninstall = badge.game.appid
      }
    }

    PanelToolTip {
      visible: badgeMouse.containsMouse && !!badge.game
      text: badge.armed ? "Click again to uninstall " + badge.game.name : "Uninstall " + (badge.game ? badge.game.name : "")
    }
  }

  // One chat message: yours on the right, theirs on the left, with a time
  // label over the first of each burst. Unsent messages are dimmed; failed
  // ones get a red outline.
  component ChatBubble: Item {
    id: cb
    property var message: null
    readonly property bool mine: !!message && message.mine
    readonly property real padX: Style.space(10)
    readonly property real padY: Style.space(6)
    height: bubble.y + bubble.height

    Text {
      id: timeLabel
      visible: !!cb.message && !!cb.message.showTime
      anchors.horizontalCenter: parent.horizontalCenter
      text: cb.message ? root.chatTime(cb.message.ts) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: bubble
      y: timeLabel.visible ? timeLabel.implicitHeight + Style.space(4) : 0
      x: cb.mine ? cb.width - width : 0
      width: Math.min(msgText.implicitWidth + cb.padX * 2, cb.width * 0.82)
      height: msgText.implicitHeight + cb.padY * 2
      radius: Style.space(10)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, cb.mine ? 0.18 : 0.07)
      border.width: cb.message && cb.message.failed ? 1 : 0
      border.color: root.dangerColor
      opacity: cb.message && cb.message.pending ? 0.55 : 1

      Text {
        id: msgText
        x: cb.padX
        y: cb.padY
        width: bubble.width - cb.padX * 2
        // steamctl.py sends a StyledText copy with links and emoticons; the
        // local echo of a message you just sent is plain until Steam's arrives.
        textFormat: cb.message && cb.message.html !== undefined ? Text.StyledText : Text.PlainText
        text: !cb.message ? "" : cb.message.html !== undefined ? cb.message.html : cb.message.text
        wrapMode: Text.Wrap
        color: root.foreground
        linkColor: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        onLinkActivated: function(link) { Qt.openUrlExternally(link) }

        HoverHandler {
          cursorShape: msgText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
      }
    }
  }

  // Smoothed progress for a download. Steam's figures arrive every couple of
  // seconds and in bursts, so between samples this runs ahead at the current
  // speed (at most a few seconds' worth) and eases toward that each frame.
  component ProgressGlide: Item {
    id: glide
    property var download: null
    property bool active: true
    property real value: 0
    property real sampledAt: 0
    readonly property real progress: download ? download.progress : 0

    // Rows are rebuilt on every poll, so carry the position over per appid
    // instead of starting again from zero.
    function restore() {
      var st = download ? root.glideState[download.appid] : null
      if (st && Math.abs(st.progress - progress) < 0.0001) { value = st.value; sampledAt = st.sampledAt }
      else {
        if (!st || Math.abs(st.value - progress) > 0.05) value = progress
        else value = st.value
        sampledAt = Date.now() / 1000
      }
    }
    Component.onCompleted: restore()
    onDownloadChanged: restore()
    onActiveChanged: if (active) restore()

    FrameAnimation {
      running: glide.active && (Math.abs(glide.value - glide.progress) > 0.0001
        || (!!glide.download && glide.download.status === "downloading" && glide.download.speed > 0))
      onTriggered: {
        var g = glide, d = g.download
        var target = g.progress
        if (d && d.status === "downloading" && d.speed > 0 && d.total > 0) {
          var ahead = Math.min(Date.now() / 1000 - g.sampledAt, 3)
          target = Math.min(1, g.progress + d.speed * ahead / d.total)
        }
        // Never slide backwards over a small overshoot; do follow a real drop.
        if (!(target < g.value && g.value - target < 0.03 && d && d.status === "downloading"))
          g.value += (target - g.value) * Math.min(1, frameTime * 3)
        if (d) root.glideState[d.appid] = { value: g.value, progress: g.progress, sampledAt: g.sampledAt }
      }
    }
  }

  component ProgressLine: Rectangle {
    property var download: null
    readonly property bool busy: !!download && (download.status === "installing" || download.status === "verifying"
      || download.status === "preparing" || (download.status === "downloading" && !download.total))
    implicitHeight: Style.space(3)
    height: implicitHeight
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
    clip: true

    Rectangle {
      visible: !parent.busy
      width: parent.width * lineGlide.value
      height: parent.height
      radius: parent.radius
      color: parent.download && parent.download.status === "paused" ? root.dim : root.inGameColor
    }

    ProgressGlide { id: lineGlide; download: parent.download; active: parent.visible && !parent.busy }

    // Indeterminate sweep while Steam is preparing, verifying or installing.
    Rectangle {
      id: sweep
      visible: parent.busy
      width: parent.width * 0.3
      height: parent.height
      radius: parent.radius
      color: root.inGameColor
      NumberAnimation on x {
        running: sweep.visible
        loops: Animation.Infinite
        from: -sweep.width
        to: sweep.parent ? sweep.parent.width : 0
        duration: 1200
      }
    }
  }

  component RowSurface: CursorSurface {
    id: surface
    property int rowIdx: 0
    width: parent ? parent.width : 0
    hasCursor: root.cursorActive && root.rowIndex === rowIdx
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.rowIndex = surface.rowIdx }
      onClicked: root.activateRow(root.rows[surface.rowIdx])
    }
  }
}
