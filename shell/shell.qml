// nixmarchy-shell: Omarchy-4-compatible third-party plugin host.
//
// A minimal Quickshell host that runs Nix-managed Omarchy plugins with the
// contract they were written against (see omacom/omarchy `docs/omarchy-shell.md`):
//   - discovery:  $XDG_CONFIG_HOME/nixmarchy/plugins/<anything>/manifest.json
//   - enabled:    id listed in $XDG_STATE_HOME/nixmarchy/shell.json `plugins[]`
//   - injection:  `shell` facade, `manifest` object on every entry point
//   - entry:      open(payloadJson)/close(); host reads `opened`
//   - control:    qs IPC target "shell": ping/list/summon/hide/toggle/rescan
//   - summon default: shell.toggle(id, payload) semantics
//
// Facade provided per plugin (defensively read by both target plugins):
//   shell.hide(id), shell.summon(id, payloadJson), shell.toggle(id, payloadJson),
//   shell.isOpen(id), shell.idleConfig {screensaver,lock}, shell.env passthrough.
// `manifest` is the parsed manifest.json object (so manifest.id resolves).
// OMARCHY_PATH-equivalent: the plugin's own dir + NIXMARCHY_BIN providing
// `nixmarchy-notification-send` fallback (grim-missing toast path).
//
// Commons: plugins import `qs.Commons` (Color.*, Style.*). We do NOT shadow
// the user's `Commons` module: the host expects the portal redirect
// `NIXMARCHY_COMMONS_DIR/qmldir` (`module qs.Commons`, singleton
// Color/Style + extra Util) placed on the QML import path AHEAD of the
// config dir by the launcher (qs -I). See ../Commons.qs/qmldir.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

ShellRoot {
  id: root

  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string nmState: stateDir + "/nixmarchy"
  readonly property string shellJsonPath: nmState + "/shell.json"
  readonly property string pluginRoot: {
    var c = Quickshell.env("NIXMARCHY_PLUGIN_DIR");
    if (c) return c;
    var h = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config");
    return h + "/nixmarchy/plugins";
  }
  readonly property string shellDir: {
    var u = String(Qt.resolvedUrl("shell.qml"));
    return u.replace(/^file:\/\//, "").replace(/\/shell\.qml$/, "");
  }
  // id -> { dir, manifest(var), component(var|null), instance(var|null),
  //         kinds[], enabled, priority, installedAt, error }
  property var plugins: ({})
  property var enabledOrder: []
  // DesktopEntries-backed app library exposed to plugins as shell.appLibrary
  // (Omarchy injects an equivalent). evindor.keystroke's Applications provider
  // resolves installed apps through it; without it the palette shows none.
  AppLibrary { id: hostAppLibrary }
  function log(msg) { console.log("nixmarchy-shell: " + msg) }
  function warn(msg) { console.warn("nixmarchy-shell: " + msg) }
  // Synchronous file reads via one-shot `cat` processes (FileView's QML
  // wrapper fails to instantiate under this host; Process+StdioCollector
  // is proven). readFileSync(path, cb) delivers text ("" on missing).
  function readFileSync(path, cb) {
    // Cat.qml ships beside shell.qml; resolve through the --path config dir
    // (NIXMARCHY_SHELL_DIR), never Qt.resolvedUrl (yields qs:@ pseudo-URLs
    // under --path launches).
    var base = Quickshell.env("NIXMARCHY_SHELL_DIR") || "";
    if (!base) {
      var h = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config");
      base = h + "/nixmarchy-shell";
    }
    var comp = Qt.createComponent("file://" + base + "/Cat.qml");
    if (comp.status === Component.Error) { root.warn("cat component: " + comp.errorString()); cb(""); return }
    var inst = comp.createObject(root, {});
    if (!inst) { cb(""); return }
    inst.filePath = String(path || "");
    inst.done.connect(function(text) { cb(text); try { inst.destroy() } catch (e) {} });
    inst.go();
  }
  // --- discovery -----------------------------------------------------------
  Process {
    id: scanner
    running: false
    property var pendingCb: null
    stdout: StdioCollector {}
    onExited: function(code) {
      var cb = scanner.pendingCb; scanner.pendingCb = null;
      if (code !== 0) { root.warn("scan failed: " + scanner.stdout.text); if (cb) cb(null); return }
      var data = null;
      try { data = JSON.parse(scanner.stdout.text) } catch (e) { root.warn("scan parse: " + e); if (cb) cb(null); return }
      if (cb) cb(data);
    }
    function run(cb) {
      scanner.pendingCb = cb;
      // One manifest.json per plugin dir; entryPoints resolved by the loader.
      scanner.command = ["bash", "-lc",
        "set -e; root='" + String(root.pluginRoot).replace(/'/g, "'\\''") + "'; " +
        "echo '['; first=1; " +
        "for m in \"$root\"/*/manifest.json; do [ -f \"$m\" ] || continue; " +
        "d=$(dirname \"$m\"); id=$(jq -r '.id // empty' \"$m\"); [ -n \"$id\" ] || continue; " +
        "if [ $first -eq 1 ]; then first=0; else echo ','; fi; " +
        "jq -c --arg dir \"$d\" --arg id \"$id\" '. + {__dir: $dir, __id: $id}' \"$m\"; done; " +
        "echo ']'"];
      scanner.running = true;
    }
    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
  }

  function readStateJson(cb) {
    root.readFileSync(root.shellJsonPath, function(raw) {
      if (!raw) { cb(null); return }
      try { cb(JSON.parse(raw)) } catch (e) { root.warn("shell.json parse: " + e); cb(null) }
    });
  }
  function readServicesJson(cb) {
    root.readFileSync(root.nmState + "/services.json", function(raw) {
      if (!raw) { cb(null); return }
      try { cb(JSON.parse(raw)) } catch (e) { root.warn("services.json parse: " + e); cb(null) }
    });
  }
  // precedence B inputs, written by nixmarchy alongside shell.json:
  // $state/priority/<id> (number) and $state/installedAt/<id> (ISO string).
  function prioAtOf(ids, cb) {
    var out = {};
    var i = 0;
    function step() {
      if (i >= ids.length) { cb(out); return }
      var id = ids[i++];
      var pid = String(id);
      root.readFileSync(root.nmState + "/priority/" + pid, function(praw) {
        root.readFileSync(root.nmState + "/installedAt/" + pid, function(araw) {
          var n = Number((praw || "").trim());
          out[pid] = { prio: isFinite(n) ? n : 0, at: (araw || "").trim() };
          step();
        });
      });
    }
    step();
  }
  // Slot exclusion: plugins declaring the same manifest barWidget.slot —
  // only the precedence-B winner mounts; losers unload with a warning.
  function excludeSlotLosers(order, next) {
    var seen = {};
    var kept = [];
    for (var i = 0; i < order.length; i++) {
      var id = order[i].id;
      var slot = "";
      try { slot = (next[id].manifest.barWidget && next[id].manifest.barWidget.slot) || "" } catch (e) { slot = "" }
      if (slot && seen[slot]) {
        root.warn("slot " + slot + ": " + id + " loses to " + seen[slot] + " (precedence B); not mounting");
        root.unloadPlugin(id);
        continue;
      }
      if (slot) seen[slot] = id;
      kept.push(id);
    }
    return kept;
  }
  function rescan(cb) {
    scanner.run(function(list) {
      if (!list) { if (cb) cb(false); return }
      root.readStateJson(function(sj) {
        sj = sj || {};
        root.readServicesJson(function(services) {
          root.cachedServices = services || {};
          var enabledIds = sj.plugins || [];
          var next = {};
          var order = [];
          for (var i = 0; i < list.length; i++) {
            var m = list[i];
            var id = m.__id, dir = m.__dir;
            var on = enabledIds.indexOf(id) !== -1;
            var prev = root.plugins[id];
            next[id] = {
              dir: dir, manifest: m, enabled: on,
              kinds: m.kinds || [],
              component: (prev && prev.dir === dir) ? prev.component : null,
              instance: null, error: ""
            };
            if (on) order.push(id);
          }
          // destroy instances of removed/disabled plugins
          for (var oldId in root.plugins) {
            if (!next[oldId] || !next[oldId].enabled) root.unloadPlugin(oldId);
          }
          root.plugins = next;
          root.prioAtOf(order, function(pa) {
            var rich = order.map(function(id) {
              return { id: id, prio: (pa[id] || {}).prio || 0, at: (pa[id] || {}).at || "" };
            });
            // precedence B: explicit priority wins (highest first); ties break
            // by installedAt (last-installed wins); id asc for determinism.
            // Slot collisions resolve by exclusion: only the winner mounts.
            rich.sort(function(a, b) {
              if (b.prio !== a.prio) return b.prio - a.prio;
              if (b.at !== a.at) return b.at < a.at ? -1 : 1;
              return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
            });
            root.enabledOrder = root.excludeSlotLosers(rich, next);
            root.mountEnabled();
            if (cb) cb(true);
          });
        });
      });
    });
  }

  function unloadPlugin(id) {
    var p = root.plugins[id];
    if (p && p.instance) { try { p.instance.destroy() } catch (e) {} }
  }

  function mountEnabled() {
    for (var i = 0; i < root.enabledOrder.length; i++) {
      var id = root.enabledOrder[i];
      var p = root.plugins[id];
      if (!p || p.instance) continue;
      root.loadPlugin(id);
    }
  }

  function entryFile(p, kind, key) {
    var eps = p.manifest.entryPoints || {};
    var rel = eps[key || kind];
    if (!rel) return "";
    return p.dir + "/" + rel;
  }

  function loadPlugin(id) {
    var p = root.plugins[id];
    if (!p) { root.warn("load: unknown " + id); return false }
    // Service kinds mount headless; overlay/panel/menu mount hidden until open().
    for (var k = 0; k < p.kinds.length; k++) {
      var kind = p.kinds[k];
      if (["overlay", "service", "panel", "menu"].indexOf(kind) === -1) {
        root.warn("load: " + id + ": kind '" + kind + "' not hosted (need bar host)");
        continue;
      }
      var key = { "overlay": "overlay", "service": "service", "panel": "panel", "menu": "menu" }[kind];
      var file = root.entryFile(p, kind, key);
      if (!file) { p.error = "missing entryPoints." + key; root.warn("load: " + id + ": " + p.error); continue }
      var comp = Qt.createComponent("file://" + file);
      if (comp.status === Component.Error) {
        p.error = comp.errorString();
        root.warn("load: " + id + " " + kind + ": " + p.error);
        continue;
      }
      var inst = comp.createObject(root, { shell: root.shellFacade(id), manifest: p.manifest });
      if (!inst) { p.error = "createObject failed"; root.warn("load: " + id + " " + kind + ": " + p.error); continue }
      if (!p.instance) p.instance = inst; // first UI kind is the summon target
    }
    return !!p.instance;
  }

  // --- scoped shell facade (one per plugin id) ------------------------------
  // idleConfig is a live binding over cached state (refreshed each rescan);
  // Service.qml reads shell.idleConfig.screensaver defensively with a 150s
  // fallback, so a first-mount race only ever yields the default.
  property var cachedIdle: null
  // --- service capability routing ------------------------------------------
  // ~/.local/state/nixmarchy/services.json maps "omarchy.<name>" ids to a
  // provider this host implements (builtin/stub/reject). shellFacade gains
  // serviceFor() + firstPartyServiceFor() returning a narrow proxy, so a
  // plugin's calls route to host implementations without plugin edits.
  property var cachedServices: ({})
  property var serviceProxies: ({})
  function serviceFor(requestedId) {
    var key = String(requestedId || "");
    var route = root.cachedServices[key];
    if (!route) {
      if (root.serviceProxies["__reject:" + key]) return root.serviceProxies["__reject:" + key];
      var rej = root.makeRejectProxy(key, "not routed");
      var n = {}; for (var k in root.serviceProxies) n[k] = root.serviceProxies[k];
      n["__reject:" + key] = rej; root.serviceProxies = n;
      return rej;
    }
    var cached = root.serviceProxies[key];
    if (cached) return cached;
    var proxy = (route.provider === "builtin") ? root.makeBuiltinProxy(key, route)
      : (route.provider === "stub") ? root.makeStubProxy(key, route)
      : root.makeRejectProxy(key, route.reason || "unknown provider");
    var next = {}; for (var k2 in root.serviceProxies) next[k2] = root.serviceProxies[k2];
    next[key] = proxy; root.serviceProxies = next;
    return proxy;
  }
  function firstPartyServiceFor(requestedId) { return root.serviceFor(requestedId) }
  function makeRejectProxy(requestedId, reason) {
    root.warn("service route reject: " + requestedId + " (" + reason + ")");
    return Qt.createQmlObject(
      'import QtQuick\nimport Quickshell\nQtObject { property string serviceId: "'
      + requestedId + '"\nproperty string reason: "' + String(reason).replace(/"/g, '\\"')
      + '"\nproperty bool enabled: false\nproperty bool stayAwake: false\n'
      + 'property bool doNotDisturb: false\nproperty var activePlayer: null\n'
      + 'property var sourcePlayers: []\n'
      + 'function setIdleEnabled(v) {}\nfunction setNightlight(v) {}\n'
      + 'function setDoNotDisturb(v) {}\nfunction runAction(a, f, p) {}\n'
      + 'function playerKey(p) { return "" }\nfunction selectPlayer(p) {} }',
      root, "rejectProxy");
  }
  function makeStubProxy(requestedId, route) {
    var props = "";
    for (var pk in route) {
      if (pk === "provider") continue;
      var v = route[pk];
      if (typeof v === "boolean") props += "property bool " + pk + ": " + v + "; ";
      else if (typeof v === "number") props += "property real " + pk + ": " + v + "; ";
      else if (v === null) props += "property var " + pk + ": null; ";
      else props += "property string " + pk + ": " + JSON.stringify(String(v)) + "; ";
    }
    return Qt.createQmlObject(
      'import QtQuick\nimport Quickshell\nQtObject { property string serviceId: "'
      + requestedId + '"\n' + props
      + 'function setIdleEnabled(v) {}\nfunction setNightlight(v) {}\n'
      + 'function setDoNotDisturb(v) {}\nfunction runAction(a, f, p) {}\n'
      + 'function playerKey(p) { return "" }\nfunction selectPlayer(p) {} }',
      root, "stubProxy");
  }
  function makeBuiltinProxy(requestedId, route) {
    if (route.impl === "hyprsunset") return root.hyprsunsetProxy(requestedId);
    if (route.impl === "mpris") return root.mprisProxy(requestedId);
    root.warn("service route: unknown builtin impl " + route.impl + " for " + requestedId);
    return root.makeRejectProxy(requestedId, "unknown builtin impl");
  }

  // --- builtin: hyprsunset night light (omarchy.nightlight) ------------------
  // Mirrors omacom/omarchy plugins/services/nightlight: hyprctl probes the
  // live temperature; setNightlight applies 4000K (night) / 6500K (day) and
  // launches hyprsunset if not running. uwsm-app is not used on nixmarchy.
  property var nightlightState: ({ temperature: null, loaded: false, pending: 0, hasPending: false, applying: false })
  readonly property int nightTemperature: 4000
  readonly property int dayTemperature: 6500
  function isNightlightTemp(t) { return t !== null && t !== undefined && t < 6000 }
  property QtObject hyprsunsetSelf: null
  function hyprsunsetProxy(requestedId) {
    root.hyprsunsetSelf = Qt.createQmlObject(
      'import QtQuick\nimport Quickshell\nQtObject {'
      + ' property string serviceId: "' + requestedId + '"'
      + '\nproperty bool enabled: false'
      + '\nproperty bool stayAwake: false\nproperty bool doNotDisturb: false'
      + '\nproperty var activePlayer: null\nproperty var sourcePlayers: []'
      + '\nproperty var self: null'
      + '\nfunction setIdleEnabled(v) {}\nfunction setDoNotDisturb(v) {}'
      + '\nfunction runAction(a, f, p) {}\nfunction playerKey(p) { return "" }'
      + '\nfunction selectPlayer(p) {}\n'
      + 'function setNightlight(v) { if (self) self.applyNightlight(v) }'
      + '}', root, "hyprsunsetProxy");
    var proxy = root.hyprsunsetSelf;
    proxy.self = root;
    proxy.enabled = Qt.binding(function() {
      return root.nightlightState.loaded && root.isNightlightTemp(root.nightlightState.temperature);
    });
    root.hyprsunsetRefresh();
    return proxy;
  }
  function applyNightlight(value) {
    var temp = value ? root.nightTemperature : root.dayTemperature;
    var st = root.nightlightState;
    st.temperature = temp; st.loaded = true;
    if (st.applying) { st.pending = temp; st.hasPending = true; return; }
    st.applying = true;
    root.hyprsunsetApplyRun(temp);
  }
  function hyprsunsetApplyRun(temp) {
    var st = root.nightlightState;
    hyprsunsetApply.command = ["bash", "-lc",
      "pgrep -x hyprsunset >/dev/null || { setsid hyprsunset >/dev/null 2>&1 & sleep 1; }; "
      + "hyprctl hyprsunset temperature " + Number(temp)];
    hyprsunsetApply.running = true;
  }
  Process {
    id: hyprsunsetApply
    running: false
    onExited: function(exitCode) {
      var st = root.nightlightState;
      st.applying = false;
      if (st.hasPending) { st.hasPending = false; root.hyprsunsetApplyRun(st.pending); return; }
      root.hyprsunsetRefresh();
    }
  }
  function hyprsunsetRefresh() {
    if (!hyprsunsetProbe.running) hyprsunsetProbe.running = true;
  }
  Process {
    id: hyprsunsetProbe
    running: false
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector { id: hyprsunsetOut }
    onExited: function(exitCode) {
      var st = root.nightlightState;
      if (exitCode !== 0) { st.temperature = null; st.loaded = true; return; }
      var m = String(hyprsunsetOut.text).match(/[0-9]+/);
      st.temperature = m ? Number(m[0]) : null;
      st.loaded = true;
    }
  }

  // --- builtin: MPRIS media (omarchy.media) ----------------------------------
  // Wraps Quickshell.Services.Mpris (present in quickshell 0.3.0) with the
  // narrow surface plugins read: activePlayer/sourcePlayers + runAction
  // (play/pause/next/previous), playerKey, selectPlayer.
  property var mediaPlayers: []
  property QtObject mprisSelf: null
  function mprisProxy(requestedId) {
    root.mprisSelf = Qt.createQmlObject(
      'import QtQuick\nimport Quickshell\nQtObject {'
      + ' property string serviceId: "' + requestedId + '"'
      + '\nproperty bool enabled: true'
      + '\nproperty bool stayAwake: false\nproperty bool doNotDisturb: false'
      + '\nproperty var activePlayer: null\nproperty var sourcePlayers: []'
      + '\nproperty var self: null'
      + '\nfunction setIdleEnabled(v) {}\nfunction setNightlight(v) {}\n'
      + 'function setDoNotDisturb(v) {}\n'
      + 'function runAction(a, f, p) { if (self) self.mediaRunAction(a, p) }'
      + '\nfunction playerKey(p) { return self ? self.mediaPlayerKey(p) : "" }'
      + '\nfunction selectPlayer(p) { if (self) self.mediaSelectPlayer(p) }'
      + '}', root, "mprisProxy");
    var proxy = root.mprisSelf;
    proxy.self = root;
    proxy.activePlayer = Qt.binding(function() { return root.mediaActivePlayer() });
    proxy.sourcePlayers = Qt.binding(function() { return root.mediaPlayers });
    return proxy;
  }
  property string preferredPlayerKey: ""
  function mediaPlayerKey(player) {
    if (!player) return "";
    return String(player.desktopEntry || player.identity || "");
  }
  function mediaActivePlayer() {
    var players = root.mediaPlayers;
    if (!players || !players.length) return null;
    if (root.preferredPlayerKey) {
      for (var i = 0; i < players.length; i++) {
        if (root.mediaPlayerKey(players[i]) === root.preferredPlayerKey) return players[i];
      }
    }
    return players[0];
  }
  function mediaSelectPlayer(key) {
    root.preferredPlayerKey = String(key || "");
  }
  function mediaRunAction(action, targetKey) {
    var player = null;
    if (targetKey) {
      for (var i = 0; i < root.mediaPlayers.length; i++) {
        if (root.mediaPlayerKey(root.mediaPlayers[i]) === String(targetKey)) { player = root.mediaPlayers[i]; break; }
      }
    }
    if (!player) player = root.mediaActivePlayer();
    if (!player) { root.warn("media action " + action + ": no player"); return }
    if (action === "next" && player.canGoNext) player.next();
    else if (action === "previous" && player.canGoPrevious) player.previous();
    else if (action === "play") player.play();
    else if (action === "pause") player.pause();
    else if (action === "playpause") player.togglePlaying();
    else root.warn("media action: unknown " + action);
  }
  // Mpris is a singleton: players is an ObjectModel (values array).
  property var mprisModel: Mpris.players
  function mprisSync() {
    var values = Mpris.players ? Mpris.players.values : [];
    var list = [];
    for (var i = 0; i < values.length; i++) list.push(values[i]);
    root.mediaPlayers = list;
  }
  Connections {
    target: Mpris.players
    function onValuesChanged() { root.mprisSync() }
  }
  function shellFacade(id) {
    return {
      hide: function(target) { return root.hide(target || id) },
      summon: function(target, payload) { return root.summon(target || id, payload || "{}") },
      toggle: function(target, payload) { return root.toggle(target || id, payload || "{}") },
      isOpen: function(target) { return root.isOpen(target || id) },
      idleConfig: root.cachedIdle || root.idleDefaults,
      appLibrary: hostAppLibrary,
      serviceFor: function(requestedId) { return root.serviceFor(requestedId) },
      firstPartyServiceFor: function(requestedId) { return root.firstPartyServiceFor(requestedId) }
    };
  }

  function targetInstance(id) {
    var p = root.plugins[id];
    return (p && p.enabled && p.instance) ? p.instance : null;
  }

  function summon(id, payloadJson) {
    var inst = root.targetInstance(id);
    if (!inst) { root.warn("summon: unknown/disabled " + id); return false }
    if (typeof inst.open === "function") { try { inst.open(payloadJson || "{}") } catch (e) { root.warn("summon " + id + ": " + e); return false } return true }
    if ("opened" in inst) { try { inst.opened = true } catch (e) { root.warn("summon " + id + ": " + e); return false } return true }
    root.warn("summon: " + id + " has no open()");
    return false;
  }

  function hide(id) {
    var inst = root.targetInstance(id);
    if (!inst) return false;
    if (typeof inst.close === "function") { try { inst.close() } catch (e) { root.warn("hide " + id + ": " + e); return false } return true }
    if ("opened" in inst) { try { inst.opened = false } catch (e) { root.warn("hide " + id + ": " + e); return false } return true }
    return false;
  }

  function isOpen(id) {
    var inst = root.targetInstance(id);
    if (!inst) return false;
    try { return !!inst.opened } catch (e) { return false }
  }

  function toggle(id, payloadJson) {
    return root.isOpen(id) ? root.hide(id) : root.summon(id, payloadJson);
  }

  // Omarchy parity: `omarchy-shell shell call <id> <fn> [argsJson]` invokes a
  // function on a plugin instance (plugins expose inspect()/state() etc.).
  function callPlugin(id, fn, argsJson) {
    var inst = root.targetInstance(id);
    if (!inst) { root.warn("call: unknown/disabled " + id); return "" }
    if (typeof inst[fn] !== "function") { root.warn("call: " + id + " has no " + fn + "()"); return "" }
    var args = [];
    try { args = JSON.parse(argsJson || "[]") } catch (e) { args = [] }
    try { return String(inst[fn].apply(inst, args)) } catch (e) { root.warn("call " + id + "." + fn + ": " + e); return "" }
  }

  // --- IPC -------------------------------------------------------------------
  IpcHandler {
    target: "shell"
    function ping(): string { return "pong" }
    function list(): string {
      var out = [];
      for (var id in root.plugins) {
        var p = root.plugins[id];
        out.push({ id: id, enabled: !!p.enabled, kinds: p.kinds,
                   name: p.manifest.name || "", open: root.isOpen(id), error: p.error || "" });
      }
      return JSON.stringify(out);
    }
    function summon(id: string, payload: string): string { return root.summon(id, payload || "{}") ? "ok" : "skip" }
    function hide(id: string): string { return root.hide(id) ? "ok" : "skip" }
    function toggle(id: string, payload: string): string { return root.toggle(id, payload || "{}") ? "ok" : "skip" }
    function isOpen(id: string): string { return root.isOpen(id) ? "true" : "false" }
    function call(id: string, fn: string, args: string): string { return root.callPlugin(id, fn, args) }
    function rescan(): string {
      root.rescan(function(ok) {});
      return "ok";
    }
  }

  Component.onCompleted: {
    root.mprisSync();
    root.log("pluginRoot=" + root.pluginRoot);
    root.rescan(function(ok) { root.log(ok ? "registry loaded" : "registry EMPTY/failed") });
  }
}
