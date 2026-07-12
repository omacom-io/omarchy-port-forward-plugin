import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Headless controller for the Port Forwarding widget.
//
// Each forward is defined by the user and persisted to
// ~/.config/omarchy/port-forwards.json. Turning a forward on launches its
// `ssh -N -L ...` inside a TRANSIENT SYSTEMD USER SERVICE
// (omarchy-pf-<id>.service via `systemd-run --user`). That deliberately
// decouples the tunnel's lifetime from omarchy-shell: the tunnel survives a
// shell reload or crash, and on startup we reconcile our UI against what
// systemd reports is actually running — so a tunnel that outlived the shell is
// picked back up instead of colliding with itself.
//
// systemd is the source of truth for liveness. We poll it (plus an `ss` check
// that the local port is really listening) and derive a status per forward:
// "inactive" | "connecting" | "auth" | "active" | "error". `statusRevision`
// bumps on every change so QML rows can force a re-read of the plain
// `statuses` map, which QML does not deep-observe on its own.
//
// "auth" covers the case where ssh is alive but blocked on an out-of-band
// step the user must complete — in practice Tailscale SSH's check mode, which
// prints "To authenticate, visit: https://login.tailscale.com/..." to stderr
// and waits. That lands in the unit's journal, so the poll greps the CURRENT
// invocation for the URL and we surface it as a click-to-open action. Host
// key problems are the other prompt-shaped failure: BatchMode makes them fail
// fast, and we classify them (new vs CHANGED key) so the UI can offer
// "trust & retry" for new keys while never auto-trusting a changed one.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string storePath: home + "/.config/omarchy/port-forwards.json"

  // Normalized list of forward definitions.
  property var forwards: []
  property bool loaded: false
  property bool sshAvailable: true

  // Runtime state, keyed by forward id.
  property var statuses: ({})
  property var errors: ({})
  property var authUrls: ({})      // id -> pending approval URL (Tailscale check mode)
  property var hostKeyIssues: ({}) // id -> "new" | "changed"
  property int statusRevision: 0
  property int activeCount: 0
  property int authCount: 0

  // Transient one-line status shown in the panel header.
  property string notice: ""

  // Header error line, derived from current state so it clears the moment the
  // offending forward is stopped, retried, or deleted (no sticky string).
  function currentErrorText() {
    for (var i = 0; i < forwards.length; i++) {
      var id = String(forwards[i].id)
      if (statusOf(id) === "error") return forwardTitle(forwards[i]) + ": " + errorOf(id)
    }
    return ""
  }

  // Header attention line for forwards blocked on user approval.
  function currentAuthText() {
    for (var i = 0; i < forwards.length; i++) {
      var id = String(forwards[i].id)
      if (statusOf(id) === "auth") return forwardTitle(forwards[i]) + ": approval required — click the key icon to authenticate"
    }
    return ""
  }

  property bool _autostarted: false
  property int _idCounter: 0
  property var _startedAt: ({}) // id -> ms, grace window so a just-started forward reads "connecting"

  signal changed()

  function statusOf(id) { return statuses[String(id)] || "inactive" }
  function errorOf(id) { return errors[String(id)] || "" }
  function authUrlOf(id) { return authUrls[String(id)] || "" }
  function hostKeyIssueOf(id) { return hostKeyIssues[String(id)] || "" }
  function isActive(id) { var s = statusOf(id); return s === "active" || s === "connecting" || s === "auth" }

  function findForward(id) {
    var key = String(id)
    for (var i = 0; i < forwards.length; i++) if (String(forwards[i].id) === key) return forwards[i]
    return null
  }

  function unitName(id) {
    return "omarchy-pf-" + String(id).replace(/[^A-Za-z0-9_-]/g, "_")
  }

  // --- definition model ----------------------------------------------------

  function genId() {
    _idCounter += 1
    return "f" + Date.now().toString(36) + _idCounter.toString(36)
  }

  function normalizeForward(raw) {
    if (!raw || typeof raw !== "object") return null
    var lp = parseInt(raw.localPort, 10)
    if (!isFinite(lp) || lp <= 0) return null
    var target = String(raw.sshTarget || "").trim()
    if (target === "") return null
    var rp = parseInt(raw.remotePort, 10)
    if (!isFinite(rp) || rp <= 0) rp = lp
    return {
      id: String(raw.id || "").trim() || genId(),
      label: String(raw.label || "").trim(),
      localPort: lp,
      sshTarget: target,
      remoteHost: String(raw.remoteHost || "").trim() || "localhost",
      remotePort: rp,
      autostart: raw.autostart === true,
      extraOptions: String(raw.extraOptions || "").trim()
    }
  }

  function forwardTitle(f) {
    if (!f) return ""
    if (f.label && f.label !== "") return f.label
    return f.localPort + " → " + f.sshTarget
  }

  function forwardSubtitle(f) {
    if (!f) return ""
    var dest = (f.remoteHost || "localhost") + ":" + f.remotePort
    return "localhost:" + f.localPort + "  →  " + f.sshTarget + " (" + dest + ")"
  }

  // --- persistence ---------------------------------------------------------

  function _loadFrom(txt) {
    var list = []
    var raw = String(txt || "").trim()
    if (raw !== "") {
      try {
        var parsed = JSON.parse(raw)
        if (parsed && Array.isArray(parsed.forwards)) list = parsed.forwards
      } catch (e) {
        console.warn("port-forward: could not parse", storePath, e)
      }
    }
    var normalized = []
    for (var i = 0; i < list.length; i++) {
      var n = normalizeForward(list[i])
      if (n) normalized.push(n)
    }
    forwards = normalized
    loaded = true
    changed()
    // Reconcile against systemd immediately: this is what picks up tunnels
    // that outlived a previous shell. Autostart runs after the first poll so
    // we never double-start an already-live tunnel.
    schedulePoll(0)
  }

  function save() {
    var payload = { version: 1, forwards: forwards }
    store.setText(JSON.stringify(payload, null, 2) + "\n")
  }

  function addForward(def) {
    var n = normalizeForward({
      id: genId(), label: def.label, localPort: def.localPort, sshTarget: def.sshTarget,
      remoteHost: def.remoteHost, remotePort: def.remotePort, autostart: def.autostart, extraOptions: def.extraOptions
    })
    if (!n) { flash("Local port and SSH host are required"); return null }
    forwards = forwards.concat([n])
    save()
    changed()
    return n.id
  }

  function updateForward(id, def) {
    var key = String(id)
    var wasActive = isActive(key)
    var next = []
    var updated = null
    for (var i = 0; i < forwards.length; i++) {
      if (String(forwards[i].id) === key) {
        updated = normalizeForward({
          id: key, label: def.label, localPort: def.localPort, sshTarget: def.sshTarget,
          remoteHost: def.remoteHost, remotePort: def.remotePort, autostart: def.autostart, extraOptions: def.extraOptions
        })
        if (!updated) { flash("Local port and SSH host are required"); return false }
        next.push(updated)
      } else {
        next.push(forwards[i])
      }
    }
    forwards = next
    save()
    changed()
    if (wasActive && updated) { stop(key); start(updated) } // re-establish with new destination
    return true
  }

  function removeForward(id) {
    var key = String(id)
    stop(key)
    forwards = forwards.filter(function(f) { return String(f.id) !== key })
    save()
    changed()
  }

  // --- tunnels (systemd transient units) -----------------------------------

  function forwardCommand(f, trustHostKey) {
    var rh = (f.remoteHost && String(f.remoteHost).length) ? String(f.remoteHost) : "localhost"
    var spec = f.localPort + ":" + rh + ":" + f.remotePort
    var cmd = ["ssh", "-N", "-T",
      "-o", "BatchMode=yes",
      "-o", "ExitOnForwardFailure=yes",
      "-o", "ServerAliveInterval=30",
      "-o", "ServerAliveCountMax=3",
      "-o", "ConnectTimeout=10",
      "-L", spec]
    // One-shot opt-in from the "Trust host key & retry" action. accept-new
    // records unknown hosts but still hard-fails if a known key CHANGED.
    if (trustHostKey === true) cmd.push("-o", "StrictHostKeyChecking=accept-new")
    var extra = String(f.extraOptions || "").trim()
    if (extra !== "") {
      var parts = extra.split(/\s+/)
      for (var i = 0; i < parts.length; i++) if (parts[i] !== "") cmd.push(parts[i])
    }
    cmd.push(String(f.sshTarget))
    return cmd
  }

  function start(f, trustHostKey) {
    if (!f) return
    if (!sshAvailable) { flash("ssh is not installed or not on PATH"); return }
    var unit = unitName(f.id)
    var ssh = forwardCommand(f, trustHostKey === true)
    var quoted = ssh.map(function(a) { return Util.shellQuote(a) }).join(" ")
    var desc = "omarchy port forward: " + forwardTitle(f)

    // Stop any other active forward on the same local port FIRST, in the same
    // command, and wait for the port to actually free before binding the new
    // tunnel — otherwise bouncing a port between hosts races on the bind.
    var stopPart = ""
    var conflicts = []
    for (var i = 0; i < forwards.length; i++) {
      var other = forwards[i]
      if (String(other.id) === String(f.id)) continue
      if (other.localPort === f.localPort && isActive(other.id)) {
        conflicts.push(Util.shellQuote(unitName(other.id)))
        _setOne(other.id, "inactive", "")
      }
    }
    if (conflicts.length > 0) {
      var q = conflicts.join(" ")
      stopPart = "systemctl --user stop " + q + " 2>/dev/null; systemctl --user reset-failed " + q + " 2>/dev/null; "
               + "for i in $(seq 1 40); do ss -Hltn 2>/dev/null | grep -q ':" + f.localPort + " ' || break; sleep 0.1; done; "
    }

    // reset-failed clears any prior failed unit of the same name; systemd-run
    // then registers the tunnel as a fresh transient service. No --collect: a
    // failed unit must linger in "failed" state long enough for us to read its
    // error; reset-failed (here and on stop) cleans it up.
    var cmd = stopPart
            + "systemctl --user reset-failed " + Util.shellQuote(unit) + " 2>/dev/null; "
            + "exec systemd-run --user --unit=" + Util.shellQuote(unit)
            + " --description=" + Util.shellQuote(desc)
            + " -- " + quoted
    var started = Object.assign({}, _startedAt); started[String(f.id)] = Date.now(); _startedAt = started
    _setOne(f.id, "connecting", "")
    Quickshell.execDetached(["bash", "-c", cmd])
    schedulePoll(800)
  }

  function stop(id) {
    var key = String(id)
    var unit = unitName(key)
    var started = Object.assign({}, _startedAt); delete started[key]; _startedAt = started
    Quickshell.execDetached(["bash", "-c",
      "systemctl --user stop " + Util.shellQuote(unit) + " 2>/dev/null; "
      + "systemctl --user reset-failed " + Util.shellQuote(unit) + " 2>/dev/null"])
    _setOne(key, "inactive", "")
    schedulePoll(500)
  }

  function toggle(f) {
    if (!f) return
    if (isActive(f.id)) stop(f.id)
    else start(f)
  }

  // Open the pending approval URL (e.g. Tailscale check) in the browser. The
  // waiting ssh proceeds on its own once the user approves; the next poll
  // flips the row to "active".
  function openAuth(id) {
    var url = authUrlOf(id)
    if (url === "") return
    Qt.openUrlExternally(url)
    flash("Opened approval page — finish in the browser, the tunnel resumes automatically")
  }

  // Retry a forward that failed on an unknown host key, accepting it this
  // time (TOFU). Never offered for a CHANGED key.
  function trustAndRetry(f) {
    if (!f) return
    flash("Accepting new host key and retrying…")
    start(f, true)
  }

  // --- polling / status ----------------------------------------------------

  function schedulePoll(delayMs) {
    if (delayMs && delayMs > 0) { pollDelay.interval = delayMs; pollDelay.restart(); return }
    runPoll()
  }

  function runPoll() {
    if (pollProc.running) { pollPending = true; return }
    if (forwards.length === 0) {
      _commit({}, {})
      _maybeAutostart()
      return
    }
    // One shell round-trip reports every forward's systemd state, whether its
    // local port is listening, plus (failed units) a base64 error line and a
    // host-key classification, and (running-but-not-listening units) any
    // approval URL ssh printed to stderr. Journal reads are scoped to the
    // unit's CURRENT invocation where possible so a stale URL or error from a
    // previous run is never resurfaced. "-" is the empty-field placeholder so
    // the line always splits into six columns.
    var specs = []
    for (var i = 0; i < forwards.length; i++) {
      specs.push(Util.shellQuote(forwards[i].id + "|" + unitName(forwards[i].id) + "|" + forwards[i].localPort))
    }
    var script =
      'for e in ' + specs.join(" ") + '; do ' +
      'IFS="|" read -r id unit port <<< "$e"; ' +
      'state=$(systemctl --user is-active "$unit" 2>/dev/null); ' +
      'listen=no; ss -Hltn 2>/dev/null | grep -q ":$port " && listen=yes; ' +
      'msg=-; hk=-; url=-; ' +
      'inv=$(systemctl --user show -p InvocationID --value "$unit" 2>/dev/null); ' +
      'if [ "$state" = failed ]; then ' +
      'j=$(journalctl --user -u "$unit" ${inv:+_SYSTEMD_INVOCATION_ID=$inv} --no-pager -n 200 -o cat 2>/dev/null); ' +
      'if printf %s "$j" | grep -q "IDENTIFICATION HAS CHANGED"; then hk=changed; ' +
      'elif printf %s "$j" | grep -qi "host key verification failed"; then hk=new; fi; ' +
      'm=$(printf %s "$j" | grep -iE "ssh:|bind|cannot|denied|refused|timed out|could not|already in use|forbidden|no route|host key|authentication" | tail -1 | base64 -w0); ' +
      '[ -n "$m" ] && msg=$m; ' +
      'elif [ "$state" = active ] && [ "$listen" = no ]; then ' +
      'u=$(journalctl --user -u "$unit" ${inv:+_SYSTEMD_INVOCATION_ID=$inv} --no-pager -o cat 2>/dev/null | grep -oE "https://login[.]tailscale[.]com/[A-Za-z0-9/_.-]+" | tail -1); ' +
      '[ -n "$u" ] && url=$u; ' +
      'fi; ' +
      'echo "$id ${state:-unknown} $listen $msg $hk $url"; ' +
      'done'
    pollProc.command = ["bash", "-c", script]
    pollProc.running = true
  }

  function _applyPoll(text) {
    var lines = String(text || "").split("\n")
    var newStatus = {}
    var newErr = {}
    var newAuth = {}
    var newHk = {}
    var now = Date.now()
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      var parts = line.split(" ")
      var id = parts[0]
      var state = parts[1] || "unknown"
      var listen = parts[2] === "yes"
      var msgB64 = (parts[3] && parts[3] !== "-") ? parts[3] : ""
      var hk = (parts[4] && parts[4] !== "-") ? parts[4] : ""
      var url = (parts[5] && parts[5] !== "-") ? parts[5] : ""
      var status = "inactive"
      if (state === "active") {
        if (listen) status = "active"
        else if (url !== "") status = "auth" // ssh is waiting on out-of-band approval
        else status = "connecting"
      }
      else if (state === "activating" || state === "reloading") status = "connecting"
      else if (state === "failed") status = "error"
      else status = "inactive"
      // Grace window: a just-started tunnel may not be registered yet.
      if (status === "inactive" && _startedAt[id] && (now - _startedAt[id]) < 4000) status = "connecting"
      if (status === "auth") newAuth[id] = url
      if (hk !== "") newHk[id] = hk
      if (status === "error") {
        if (hk === "changed") newErr[id] = "Host key CHANGED — possible MITM; verify and fix ~/.ssh/known_hosts"
        else if (hk === "new") newErr[id] = "Host key not trusted yet"
        else newErr[id] = Util.decodeBase64(msgB64) || "ssh forwarding failed"
      }
      newStatus[id] = status
    }
    _commit(newStatus, newErr, newAuth, newHk)
    _maybeAutostart()
  }

  function _maybeAutostart() {
    if (_autostarted || !loaded) return
    _autostarted = true
    for (var i = 0; i < forwards.length; i++) {
      if (forwards[i].autostart && statusOf(forwards[i].id) === "inactive") start(forwards[i])
    }
  }

  // Set a single forward's status optimistically (poll will confirm/correct).
  function _setOne(id, status, err) {
    var key = String(id)
    var s = Object.assign({}, statuses); s[key] = status
    var e = Object.assign({}, errors)
    if (err && err !== "") e[key] = err; else delete e[key]
    var a = Object.assign({}, authUrls); delete a[key]
    var h = Object.assign({}, hostKeyIssues); delete h[key]
    _commit(s, e, a, h)
  }

  function _commit(newStatus, newErr, newAuth, newHk) {
    statuses = newStatus
    errors = newErr
    authUrls = newAuth || {}
    hostKeyIssues = newHk || {}
    var count = 0
    var auths = 0
    for (var k in newStatus) {
      if (newStatus[k] === "active" || newStatus[k] === "connecting" || newStatus[k] === "auth") count += 1
      if (newStatus[k] === "auth") auths += 1
    }
    activeCount = count
    authCount = auths
    statusRevision += 1
  }

  function flash(message) {
    notice = String(message || "")
    if (notice !== "") noticeTimer.restart()
  }

  function refresh() {
    store.reload()
    schedulePoll(0)
  }

  // --- IPC helpers ---------------------------------------------------------

  function ipcForwardByRef(ref) {
    var key = String(ref || "").trim()
    if (key === "") return null
    var byId = findForward(key)
    if (byId) return byId
    for (var i = 0; i < forwards.length; i++) {
      if (forwards[i].label === key || String(forwards[i].localPort) === key) return forwards[i]
    }
    return null
  }

  // --- wiring --------------------------------------------------------------

  property bool pollPending: false

  Component.onCompleted: whichSsh.running = true

  Process {
    id: whichSsh
    command: ["which", "ssh"]
    running: false
    onExited: function(code) { root.sshAvailable = (code === 0) }
  }

  Process {
    id: pollProc
    running: false
    command: []
    stdout: StdioCollector { id: pollOut; waitForEnd: true }
    onExited: function(code, status) {
      root._applyPoll(pollOut.text)
      if (root.pollPending) { root.pollPending = false; root.runPoll() }
    }
  }

  FileView {
    id: store
    path: root.storePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root._loadFrom(text())
    onLoadFailed: function(error) {
      root.forwards = []
      root.loaded = true
      root.changed()
      root.schedulePoll(0)
    }
  }

  // Steady-state reconcile: catches tunnels that die on their own (network
  // drop, remote reboot) and external `systemctl` changes.
  Timer {
    id: pollTimer
    interval: 4000
    repeat: true
    running: true
    onTriggered: root.runPoll()
  }

  Timer {
    id: pollDelay
    interval: 500
    repeat: false
    onTriggered: root.runPoll()
  }

  Timer {
    id: noticeTimer
    interval: 3200
    repeat: false
    onTriggered: root.notice = ""
  }
}
