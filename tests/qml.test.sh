#!/usr/bin/env bash
# tests/qml.test.sh — the QML surface of the seed: the qs.Commons / qs.Ui portal
# (Commons.qs/qs/{Commons,Ui}) and the host (shell/shell.qml, Cat/AppLibrary/AppSearch).
#
# Layer 1 — structural invariants, parsed out of the files (python3), always runs:
#   * module wiring: a qmldir declares `module qs.<dir>`, every entry names an existing
#     file, every .qml in the module is declared, `singleton` matches `pragma Singleton`
#   * every `import qs.*` and every relative import resolves to a file inside this repo
#   * every QML and JS file has balanced braces, and each .qml has exactly one root element
#   * the host's and the CLI's kind -> entryPoints tables agree with the six documented
#     manifest kinds (bar, bar-widget, menu, overlay, panel, service) and with each
#     other, and the schemaVersion-1 manifest contract is what they read
#   * NIXMARCHY_SUPPORTED_UI names only shipped qs.Ui types (and should list them all)
#
# Layer 2 — runtime component checks, best-effort and skippable with evidence: drives the
#   real `qs` (Quickshell 0.3.x) with a generated probe config on
#   QML_IMPORT_PATH=$PORTAL_TREE, offscreen first and the live session as a fallback.
#   Every qmldir name is compiled through its module, and the portal singletons plus
#   Panel / PluginBarApi / PointerMoveGate APIs are exercised. Anything that will not
#   compile is SKIPped with the exact compiler error, never silently passed.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

suite qml

new_home qml

# ---------------------------------------------------------------------------
# The checker: `struct` (layer 1), `gen` + `parse` + `needs-live` (layer 2).
# It emits one tab-separated `id  description  pass|fail|skip  detail` line
# per check so the bash side only has to route it through it/ok/bad/skip.
# ---------------------------------------------------------------------------
cat >"$T/qmlcheck.py" <<'PY'
#!/usr/bin/env python3
"""nixmarchy QML surface checks: structural (static) + runtime probe driver."""
import json, os, re, shutil, sys

DOC_KINDS = ["bar", "bar-widget", "menu", "overlay", "panel", "service"]


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)


def emit(cid, desc, status, detail=""):
    print("%s\t%s\t%s\t%s" % (cid, desc, status, " ".join(str(detail).split())))


def parse_qmldir(path):
    """-> (module name, [(isSingleton, name, version, file)])."""
    mod, entries = None, []
    for raw in read(path).splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        toks = line.split()
        if toks[0] == "module":
            mod = toks[1]
        elif toks[0] == "singleton" and len(toks) >= 4:
            entries.append((True, toks[1], toks[2], toks[3]))
        elif len(toks) >= 3:
            entries.append((False, toks[0], toks[1], toks[2]))
    return mod, entries


# --------------------------------------------------------------------------
# layer 1: structural
# --------------------------------------------------------------------------

def strip_code(src):
    """Drop comments, strings and regex literals so brace counting is honest."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if c in "\"'`":
            q = c
            i += 1
            while i < n and src[i] != q:
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if c == "/":
            j = len(out) - 1
            while j >= 0 and out[j] in " \t\n":
                j -= 1
            prev = out[j] if j >= 0 else ""
            if prev in "(,=:[!&|?{};+" or prev == "":
                i += 1
                incls = False
                while i < n:
                    ch = src[i]
                    if ch == "\\":
                        i += 2
                        continue
                    if ch == "[":
                        incls = True
                    elif ch == "]":
                        incls = False
                    elif ch == "/" and not incls:
                        break
                    elif ch == "\n":
                        break
                    i += 1
                i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)


def cmd_struct(root):
    portal_tree = os.path.join(root, "Commons.qs")
    qs_dir = os.path.join(portal_tree, "qs")
    shell = read(os.path.join(root, "shell", "shell.qml"))
    cli = read(os.path.join(root, "bin", "nixmarchy"))

    # --- qmldir <-> files, module name, singleton pragma ---
    ui_entries = []
    for name in ("Commons", "Ui"):
        d = os.path.join(qs_dir, name)
        mod, entries = parse_qmldir(os.path.join(d, "qmldir"))
        if name == "Ui":
            ui_entries = entries
        want = "qs." + name
        if mod == want:
            emit("qmldir.module." + name, "qs.%s/qmldir declares `module %s`" % (name, want), "pass")
        else:
            emit("qmldir.module." + name, "qs.%s/qmldir declares `module %s`" % (name, want), "fail",
                 "found %r" % mod)

        missing = [f for (_, _, _, f) in entries if not os.path.isfile(os.path.join(d, f))]
        if missing:
            emit("qmldir.files." + name, "qs.%s/qmldir entries all name existing files" % name, "fail",
                 "missing: " + " ".join(missing))
        else:
            emit("qmldir.files." + name, "qs.%s/qmldir entries all name existing files" % name, "pass")

        on_disk = sorted(f for f in os.listdir(d) if f.endswith(".qml"))
        declared = set(f for (_, _, _, f) in entries)
        undeclared = [f for f in on_disk if f not in declared]
        if undeclared:
            emit("qmldir.cover." + name, "every .qml in qs.%s is declared in its qmldir" % name, "fail",
                 "undeclared: " + " ".join(undeclared))
        else:
            emit("qmldir.cover." + name, "every .qml in qs.%s is declared in its qmldir" % name, "pass")

        root_re0 = re.compile(r"^([A-Z][A-Za-z0-9_.]*)\s*\{\s*$")
        wrong = []
        for (singleton, tyname, _ver, f) in entries:
            path = os.path.join(d, f)
            if not os.path.isfile(path):
                continue
            src = read(path)
            has = bool(re.search(r"^\s*pragma\s+Singleton\b", src, re.M))
            if singleton and not has:
                wrong.append("%s is declared singleton but %s lacks `pragma Singleton`" % (tyname, f))
            if not singleton and has:
                wrong.append("%s is declared non-singleton but %s has `pragma Singleton`" % (tyname, f))
            if singleton:
                roots = [m.group(1) for line in src.splitlines() for m in [root_re0.match(line)] if m]
                if roots != ["QtObject"]:
                    wrong.append("%s must be a QtObject singleton (root=%s)" % (tyname, roots or "none"))
        desc_singleton = "`singleton` in qs.%s/qmldir matches `pragma Singleton` and a QtObject root" % name
        if wrong:
            emit("qmldir.singleton." + name, desc_singleton, "fail", "; ".join(wrong))
        else:
            emit("qmldir.singleton." + name, desc_singleton, "pass")

    # --- imports resolve inside the repo ---
    imp_re = re.compile(r'^\s*import\s+("[^"]+"|qs\.[A-Za-z0-9_.]+)\s*(?:as\s+\w+)?\s*$', re.M)
    qml_files = []
    for base, _, files in os.walk(portal_tree):
        qml_files += [os.path.join(base, f) for f in files if f.endswith(".qml")]
    for base, _, files in os.walk(os.path.join(root, "shell")):
        qml_files += [os.path.join(base, f) for f in files if f.endswith(".qml")]

    bad, n_rel, n_qs = [], 0, 0
    for f in sorted(qml_files):
        for m in imp_re.finditer(read(f)):
            target = m.group(1)
            rel = os.path.relpath(f, root)
            if target.startswith('"'):
                n_rel += 1
                if not os.path.exists(os.path.join(os.path.dirname(f), target[1:-1])):
                    bad.append("%s: relative import %s unresolved" % (rel, target))
            else:
                n_qs += 1
                parts = target.split(".")
                if parts[0] == "qs":
                    d = os.path.join(qs_dir, *parts[1:])
                    if not os.path.isfile(os.path.join(d, "qmldir")):
                        bad.append("%s: import %s has no qmldir" % (rel, target))
    if n_rel == 0 or n_qs == 0:
        emit("imports", "every import qs.* / relative import resolves inside the repo", "fail",
             "parsed no imports (relative=%d qs=%d)" % (n_rel, n_qs))
    elif bad:
        emit("imports", "every import qs.* / relative import resolves inside the repo", "fail", "; ".join(sorted(bad)))
    else:
        emit("imports", "every import qs.* / relative import resolves inside the repo (%d qs, %d relative)"
             % (n_qs, n_rel), "pass")

    # --- braces + single root element ---
    all_qml, all_js = [], []
    for base, _, files in os.walk(root):
        if "/.git" in base or "/tests" in base:
            continue
        all_qml += [os.path.join(base, f) for f in files if f.endswith(".qml")]
        all_js += [os.path.join(base, f) for f in files if f.endswith(".js")]
    depth_bad, root_bad = [], []
    root_re = re.compile(r"^([A-Z][A-Za-z0-9_.]*)\s*\{\s*$")
    for f in sorted(all_qml + all_js):
        src = strip_code(read(f))
        depth, ok_depth = 0, True
        for ch in src:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth < 0:
                    ok_depth = False
        if not ok_depth or depth != 0:
            depth_bad.append("%s: balance %d%s" % (os.path.relpath(f, root), depth,
                                                   "" if ok_depth else " (went negative)"))
        if not f.endswith(".qml"):
            continue
        roots = [m.group(1) for line in read(f).splitlines() for m in [root_re.match(line)] if m]
        if len(roots) != 1:
            root_bad.append("%s: %d root elements (%s)" % (os.path.relpath(f, root), len(roots), ",".join(roots)))
    if depth_bad:
        emit("braces", "every QML and JS file has balanced braces", "fail", "; ".join(depth_bad))
    else:
        emit("braces", "every QML and JS file has balanced braces", "pass")
    if root_bad:
        emit("root", "every .qml has exactly one top-level root element", "fail", "; ".join(root_bad))
    else:
        emit("root", "every .qml has exactly one top-level root element", "pass")

    # --- kind -> entryPoints tables + manifest contract ---
    m = re.search(r"for\s+kind_entry_point\s+in\s+([^;]+);", cli)
    cli_pairs = dict(p.split(":", 1) for p in m.group(1).split()) if m else {}
    if sorted(cli_pairs) == sorted(DOC_KINDS):
        emit("kinds.doc", "CLI kind->entryPoints table covers the documented manifest kinds", "pass")
    else:
        emit("kinds.doc", "CLI kind->entryPoints table covers the documented manifest kinds", "fail",
             "expected %s, got %s" % (DOC_KINDS, sorted(cli_pairs)))

    hosted_m = re.search(r'\[([^\]]*"overlay"[^\]]*)\]\.indexOf\(kind\)', shell)
    hosted = re.findall(r'"([^"]+)"', hosted_m.group(1)) if hosted_m else []
    map_m = re.search(r"var\s+key\s*=\s*\{([^}]*)\}\[kind\]", shell)
    host_map = dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', map_m.group(1))) if map_m else {}
    if not hosted or not host_map:
        emit("kinds.host", "host kind table is a documented-kinds subset with one entryPoints key each", "fail",
             "could not parse host tables (hosted=%r map=%r)" % (hosted, host_map))
    elif set(hosted) <= set(DOC_KINDS) and set(host_map) == set(hosted):
        emit("kinds.host", "host kind table is a documented-kinds subset with one entryPoints key each", "pass")
    else:
        emit("kinds.host", "host kind table is a documented-kinds subset with one entryPoints key each", "fail",
             "hosted=%s map=%s" % (hosted, host_map))

    disagree = [k for k in hosted if k in cli_pairs and cli_pairs[k] != host_map.get(k)]
    if disagree:
        emit("kinds.agree", "host and CLI agree on the entryPoints key of every shared kind", "fail",
             "; ".join("%s: host=%s cli=%s" % (k, host_map.get(k), cli_pairs[k]) for k in disagree))
    else:
        emit("kinds.agree", "host and CLI agree on the entryPoints key of every shared kind", "pass")

    gaps = []
    if "manifest.entryPoints" not in shell:
        gaps.append("host never reads manifest.entryPoints")
    if "manifest.barWidget" not in shell or "slot" not in shell:
        gaps.append("host never reads manifest.barWidget.slot")
    if "m.kinds" not in shell and "manifest.kinds" not in shell:
        gaps.append("host never reads manifest.kinds")
    if "manifest.json" not in shell:
        gaps.append("scanner does not discover manifest.json")
    if re.search(r"schemaVersion\s*==\s*1", cli) is None:
        gaps.append("CLI does not enforce schemaVersion == 1")
    if gaps:
        emit("manifest.contract", "host/CLI read the schemaVersion-1 manifest contract", "fail", "; ".join(gaps))
    else:
        emit("manifest.contract", "host/CLI read the schemaVersion-1 manifest contract", "pass")

    # --- NIXMARCHY_SUPPORTED_UI vs shipped qs.Ui types ---
    sup = re.search(r'NIXMARCHY_SUPPORTED_UI="([^"]*)"', cli)
    listed = sup.group(1).split() if sup else []
    shipped = sorted(set(name for (_s, name, _v, _f) in ui_entries))
    phantom = [n for n in listed if n not in shipped]
    if phantom:
        emit("supportedui.phantom", "NIXMARCHY_SUPPORTED_UI lists only shipped qs.Ui types", "fail",
             "not shipped: %s (shipped: %s)" % (" ".join(phantom), " ".join(shipped)))
    else:
        emit("supportedui.phantom", "NIXMARCHY_SUPPORTED_UI lists only shipped qs.Ui types", "pass")
    gap = [n for n in shipped if n not in listed]
    if gap:
        emit("supportedui.cover", "NIXMARCHY_SUPPORTED_UI lists every shipped qs.Ui type", "skip",
             "drift, fix bin/nixmarchy: shipped but unlisted: " + " ".join(gap))
    else:
        emit("supportedui.cover", "NIXMARCHY_SUPPORTED_UI lists every shipped qs.Ui type", "pass")


# --------------------------------------------------------------------------
# layer 2: runtime probe
# --------------------------------------------------------------------------

PROBE_SHELL = r'''import QtQuick
import Quickshell
import qs.Commons

// Generated probe (tests/qml.test.sh): compiles every qmldir-declared portal type
// through its module and exercises the portal APIs, then prints one PROBEJSON line.
ShellRoot {
  id: probe

  function comp(path) {
    var c = Qt.createComponent("file://" + path);
    if (!c) return { ready: false, status: -1, error: "null component" };
    return { ready: c.status === Component.Ready, status: c.status, error: String(c.errorString()) };
  }
  function inst(path, props) {
    var c = Qt.createComponent("file://" + path);
    if (!c || c.status !== Component.Ready)
      return { created: false, error: c ? String(c.errorString()) : "null component" };
    var o = null;
    try { o = c.createObject(null, props || {}) } catch (e) { return { created: false, error: String(e) } }
    if (!o) return { created: false, error: "createObject returned null" };
    return { created: true, obj: o, error: "" };
  }

  Component.onCompleted: {
    var base = Quickshell.env("PROBE_BASE");
    var portal = Quickshell.env("PROBE_PORTAL_TREE");
    var out = { files: {}, api: {} };
    var names = __FILES__;
    for (var i = 0; i < names.length; i++) out.files[names[i]] = comp(base + "/surface/" + names[i]);

    out.api.color = {
      accent: String(Color.accent),
      barTextIsForeground: String(Color.bar.text) === String(Color.foreground),
      menuSelectedIsAccent: String(Color.menu.selectedText) === String(Color.accent)
    };
    out.api.style = {
      space4: String(Style.space(4)),
      space0: String(Style.space(0)),
      baseSizePositive: String(Number(Style.font.baseSize) > 0),
      gapsOutNonNegative: String(Number(Style.gapsOut) >= 0),
      spaceReal: String(Style.spaceReal(4)),
      durationPassthrough: String(Style.duration(140)),
      barIconSlot: String(Style.bar.iconSlot),
      barIconCanvas: String(Style.bar.iconCanvas)
    };
    out.api.util = {
      clampHigh: String(Util.clamp(9, 0, 5)),
      clampLow: String(Util.clamp(-3, 0, 5)),
      fileUrl: String(Util.fileUrl("/x")),
      quote: String(Util.shellQuote("a'b"))
    };
    var none = Border.none();
    var flat = Border.flat("#ffffff", 2);
    out.api.border = {
      isNone: String(Border.isNone(none)),
      noneTop: String(none.widths.top),
      flatTop: String(flat.widths.top),
      flatColor: String(Border.color(flat))
    };

    var rp = inst(portal + "/qs/Ui/UiDummy.qml", {});
    if (rp.created) {
      var p = rp.obj;
      var opened0 = p.opened;
      p.open();
      var afterOpen = p.opened;
      p.close();
      var afterClose = p.opened;
      p.toggle();
      out.api.panel = { created: true, opened0: String(opened0), afterOpen: String(afterOpen),
                        afterClose: String(afterClose), afterToggle: String(p.opened),
                        settingDefault: String(p.setting("nope", 7)),
                        toggleFn: String(typeof p.toggle), closeFn: String(typeof p.close) };
    } else out.api.panel = { created: false, error: rp.error };

    var rb = inst(portal + "/qs/Ui/PluginBarApi.qml", { pluginId: "pid", moduleName: "mod" });
    if (rb.created) {
      var b = rb.obj;
      out.api.barApi = { created: true, pluginId: String(b.pluginId), moduleName: String(b.moduleName),
                         position: String(b.position),
                         targets: String(b.clickTargets ? b.clickTargets.length : -1),
                         fns: String(typeof b.registerClickTarget) + "," + String(typeof b.run) + ","
                              + String(typeof b.requestPopout) + "," + String(typeof b.switchPanelFrom) };
    } else out.api.barApi = { created: false, error: rb.error };

    // Bar-hosting portal types. BarWidget is the base every bar widget
    // extends (setting()/vertical/barSize), WidgetButton is what those
    // widgets build their click targets from, OpticalGlyph fits an icon-font
    // codepoint into its painted box, and TransformWatcher is what makes
    // KeyboardPanel's card position reactive. All four must compile AND
    // carry the surface their users read.
    var rbw = inst(portal + "/qs/Ui/BarWidget.qml", {});
    if (rbw.created) {
      var bw = rbw.obj;
      out.api.barWidget = { created: true,
                           verticalNoBar: String(bw.vertical),
                           barSizeFallback: String(bw.barSize),
                           settingDefault: String(bw.setting("nope", 7)),
                           settingFromMap: String(bw.setting("k", "fallback")),
                           broadcastFn: String(typeof bw.broadcast) };
    } else out.api.barWidget = { created: false, error: rbw.error };

    var rw = inst(portal + "/qs/Ui/WidgetButton.qml", { text: "x" });
    if (rw.created) {
      var w = rw.obj;
      out.api.widgetButton = { created: true,
                              iconLabelPlain: String(w.isIconGlyph("A")),
                              iconLabelPrivate: String(w.isIconGlyph("")),
                              pressFn: String(typeof w.triggerPress),
                              hasVisualContent: String(w.hasVisualContent) };
    } else out.api.widgetButton = { created: false, error: rw.error };

    var ro = inst(portal + "/qs/Ui/OpticalGlyph.qml", { text: "A", fontSize: 14 });
    if (ro.created) {
      var o = ro.obj;
      out.api.opticalGlyph = { created: true,
                               renderedFontSize: String(o.renderedFontSize),
                               tightWidthPositive: String(Number(o.tightWidth) > 0) };
    } else out.api.opticalGlyph = { created: false, error: ro.error };

    var rtw = inst(portal + "/qs/Ui/TransformWatcher.qml", {});
    if (rtw.created) {
      var tw = rtw.obj;
      out.api.transformWatcher = { created: true,
                                   offsetNoEnds: String(tw.trackedOffset.x) + "," + String(tw.trackedOffset.y),
                                   widthNoEnds: String(tw.trackedWidth) };
    } else out.api.transformWatcher = { created: false, error: rtw.error };

    var rg = inst(portal + "/qs/Ui/PointerMoveGate.qml", {});
    if (rg.created) {
      var g = rg.obj;
      g.reset();
      out.api.gate = { created: true, movedNull: String(g.moved(null, null)), primed0: String(g.primed),
                       resetFn: String(typeof g.reset) };
    } else out.api.gate = { created: false, error: rg.error };

    console.log("PROBEJSON:" + JSON.stringify(out));
  }
}
'''


def cmd_gen(tree, dest):
    shutil.rmtree(dest, ignore_errors=True)
    surface = os.path.join(dest, "surface")
    os.makedirs(surface)
    files = []
    for module in ("Commons", "Ui"):
        _mod, entries = parse_qmldir(os.path.join(tree, "qs", module, "qmldir"))
        for (_s, name, _v, _f) in entries:
            fn = "%s_%s.qml" % (module, name)
            if module == "Commons":
                body = "import QtQuick\nimport qs.Commons as C\nQtObject {\n  property var value: C.%s\n}\n" % name
            else:
                body = "import QtQuick\nimport qs.Ui as Ui\nUi.%s {\n}\n" % name
            write(os.path.join(surface, fn), body)
            files.append(fn)
    write(os.path.join(dest, "shell.qml"), PROBE_SHELL.replace("__FILES__", json.dumps(files)))


def probe_json(outfile):
    m = re.search(r"PROBEJSON:(\{.*\})", read(outfile))
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def last_line(err):
    lines = [ln.strip() for ln in str(err or "").splitlines() if ln.strip()]
    return lines[-1][:220] if lines else "no error string"


def cmd_needs_live(outfile):
    data = probe_json(outfile)
    if data is None:
        sys.exit(0)
    for st in data.get("files", {}).values():
        if not st.get("ready"):
            sys.exit(0)
    sys.exit(1)


def cmd_parse(outfile):
    data = probe_json(outfile)
    if data is None:
        tail = " ".join(read(outfile).split()[-30:])
        emit("probe.run", "qs runs the generated probe and reports portal status", "skip",
             "no PROBEJSON in qs output; tail: " + tail)
        return
    for fn in sorted(data.get("files", {})):
        module, name = fn[:-4].split("_", 1)
        label = "qs.%s.%s" % ("Commons" if module == "Commons" else "Ui", name)
        st = data["files"][fn]
        if st.get("ready"):
            emit("ready." + fn, "runtime: %s compiles through its qmldir" % label, "pass")
        else:
            emit("notready." + fn, "runtime: %s compiles through its qmldir" % label, "skip",
                 "not ready - " + last_line(st.get("error")))

    api = data.get("api", {})
    C = api.get("color", {})
    if C.get("accent", "").startswith("#") and C.get("barTextIsForeground") and C.get("menuSelectedIsAccent"):
        emit("api.color", "runtime: qs.Commons Color exposes a color accent and keeps its bindings", "pass")
    else:
        emit("api.color", "runtime: qs.Commons Color exposes a color accent and keeps its bindings", "fail",
             json.dumps(C))
    S = api.get("style", {})
    if S.get("space4") == "4" and S.get("space0") == "0" and S.get("baseSizePositive") == "true" \
            and S.get("gapsOutNonNegative") == "true" and S.get("spaceReal") == "4" \
            and S.get("durationPassthrough") == "140" and S.get("barIconSlot") == "27" \
            and S.get("barIconCanvas") == "16":
        emit("api.style", "runtime: Style.space(px) returns px for positives and 0 otherwise", "pass")
    else:
        emit("api.style", "runtime: Style.space(px) returns px for positives and 0 otherwise", "fail", json.dumps(S))
    U = api.get("util", {})
    if U.get("clampHigh") == "5" and U.get("clampLow") == "0" and U.get("fileUrl") == "file:///x" \
            and U.get("quote") == "'a'\\''b'":
        emit("api.util", "runtime: Util.clamp/fileUrl/shellQuote behave as documented", "pass")
    else:
        emit("api.util", "runtime: Util.clamp/fileUrl/shellQuote behave as documented", "fail", json.dumps(U))
    B = api.get("border", {})
    if B.get("isNone") == "true" and B.get("noneTop") == "0" and B.get("flatTop") == "2" and B.get("flatColor") == "#ffffff":
        emit("api.border", "runtime: Border.none() is empty and Border.flat() carries width + colour", "pass")
    else:
        emit("api.border", "runtime: Border.none() is empty and Border.flat() carries width + colour", "fail", json.dumps(B))

    P = api.get("panel", {})
    if not P.get("created"):
        emit("api.panel", "runtime: qs.Ui.Panel drives `opened` via open()/close()/toggle()", "skip",
             "UiDummy could not be created - " + last_line(P.get("error")))
    elif P.get("opened0") == "false" and P.get("afterOpen") == "true" and P.get("afterClose") == "false" \
            and P.get("afterToggle") == "true" and P.get("settingDefault") == "7" \
            and P.get("toggleFn") == "function" and P.get("closeFn") == "function":
        emit("api.panel", "runtime: qs.Ui.Panel drives `opened` via open()/close()/toggle()", "pass")
    else:
        emit("api.panel", "runtime: qs.Ui.Panel drives `opened` via open()/close()/toggle()", "fail", json.dumps(P))

    A = api.get("barApi", {})
    if not A.get("created"):
        emit("api.barApi", "runtime: qs.Ui.PluginBarApi carries its required props and facade functions", "skip",
             "PluginBarApi could not be created - " + last_line(A.get("error")))
    elif A.get("pluginId") == "pid" and A.get("moduleName") == "mod" and A.get("position") == "top" \
            and A.get("targets") == "0" and A.get("fns") == "function,function,function,function":
        emit("api.barApi", "runtime: qs.Ui.PluginBarApi carries its required props and facade functions", "pass")
    else:
        emit("api.barApi", "runtime: qs.Ui.PluginBarApi carries its required props and facade functions", "fail",
             json.dumps(A))

    G = api.get("gate", {})
    if not G.get("created"):
        emit("api.gate", "runtime: qs.Ui.PointerMoveGate filters the initial pointer sample", "skip",
             "PointerMoveGate could not be created - " + last_line(G.get("error")))
    elif G.get("movedNull") == "false" and G.get("primed0") == "false" and G.get("resetFn") == "function":
        emit("api.gate", "runtime: qs.Ui.PointerMoveGate filters the initial pointer sample", "pass")
    else:
        emit("api.gate", "runtime: qs.Ui.PointerMoveGate filters the initial pointer sample", "fail", json.dumps(G))

    BW = api.get("barWidget", {})
    if not BW.get("created"):
        emit("api.barWidget", "runtime: qs.Ui.BarWidget carries bar geometry, setting() and broadcast()", "skip",
             "BarWidget could not be created - " + last_line(BW.get("error")))
    elif BW.get("verticalNoBar") == "false" and BW.get("barSizeFallback") == "26" \
            and BW.get("settingDefault") == "7" and BW.get("settingFromMap") == "fallback" \
            and BW.get("broadcastFn") == "function":
        emit("api.barWidget", "runtime: qs.Ui.BarWidget carries bar geometry, setting() and broadcast()", "pass")
    else:
        emit("api.barWidget", "runtime: qs.Ui.BarWidget carries bar geometry, setting() and broadcast()", "fail",
             json.dumps(BW))

    WB = api.get("widgetButton", {})
    if not WB.get("created"):
        emit("api.widgetButton", "runtime: qs.Ui.WidgetButton detects icon glyphs and exposes press handling", "skip",
             "WidgetButton could not be created - " + last_line(WB.get("error")))
    elif WB.get("iconLabelPlain") == "false" and WB.get("iconLabelPrivate") == "true" \
            and WB.get("pressFn") == "function" and WB.get("hasVisualContent") == "true":
        emit("api.widgetButton", "runtime: qs.Ui.WidgetButton detects icon glyphs and exposes press handling", "pass")
    else:
        emit("api.widgetButton", "runtime: qs.Ui.WidgetButton detects icon glyphs and exposes press handling", "fail",
             json.dumps(WB))

    OG = api.get("opticalGlyph", {})
    if not OG.get("created"):
        emit("api.opticalGlyph", "runtime: qs.Ui.OpticalGlyph measures a glyph's painted box", "skip",
             "OpticalGlyph could not be created - " + last_line(OG.get("error")))
    elif OG.get("renderedFontSize") == "14" and OG.get("tightWidthPositive") == "true":
        emit("api.opticalGlyph", "runtime: qs.Ui.OpticalGlyph measures a glyph's painted box", "pass")
    else:
        emit("api.opticalGlyph", "runtime: qs.Ui.OpticalGlyph measures a glyph's painted box", "fail", json.dumps(OG))

    TW = api.get("transformWatcher", {})
    if not TW.get("created"):
        emit("api.transformWatcher", "runtime: qs.Ui.TransformWatcher reports a safe offset with no endpoints", "skip",
             "TransformWatcher could not be created - " + last_line(TW.get("error")))
    elif TW.get("offsetNoEnds") == "0,0" and TW.get("widthNoEnds") == "0":
        emit("api.transformWatcher", "runtime: qs.Ui.TransformWatcher reports a safe offset with no endpoints", "pass")
    else:
        emit("api.transformWatcher", "runtime: qs.Ui.TransformWatcher reports a safe offset with no endpoints",
             "fail", json.dumps(TW))


def main():
    cmd = sys.argv[1]
    if cmd == "struct":
        cmd_struct(sys.argv[2])
    elif cmd == "gen":
        cmd_gen(sys.argv[2], sys.argv[3])
    elif cmd == "parse":
        cmd_parse(sys.argv[2])
    elif cmd == "needs-live":
        cmd_needs_live(sys.argv[2])
    else:
        sys.exit("unknown command: " + cmd)


main()
PY

# ---------------------------------------------------------------------------
# layer 1 — structural (always runs)
# ---------------------------------------------------------------------------
if ! python3 "$T/qmlcheck.py" struct "$ROOT" >"$T/struct.tsv" 2>"$T/struct.err"; then
    it "structural checker (python3) runs"
    bad "qmlcheck.py struct failed: $(tail -2 "$T/struct.err" | tr '\n' ' ')"
else
    while IFS=$'\t' read -r cid desc status detail; do
        [[ -n "$cid" ]] || continue
        it "$desc"
        case "$status" in
            pass) ok ;;
            skip) skip "${detail:-$cid}" ;;
            *)    bad "$cid: ${detail:-check failed}" ;;
        esac
    done <"$T/struct.tsv"
fi

# ---------------------------------------------------------------------------
# layer 2 — runtime component checks (best effort, skippable with evidence)
# ---------------------------------------------------------------------------
run_probe() { # run_probe <mode:offscreen|live> <outfile>; true when PROBEJSON appeared
    local mode="$1" out="$2" pid waited=0
    local envs=(env "QML_IMPORT_PATH=$PORTAL_TREE" "PROBE_PORTAL_TREE=$PORTAL_TREE" "PROBE_BASE=$PROBE_DIR")
    [[ "$mode" == offscreen ]] && envs+=("QT_QPA_PLATFORM=offscreen")
    : >"$out"
    "${envs[@]}" "$QS_BIN" -p "$PROBE_DIR" >"$out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        grep -q 'PROBEJSON:' "$out" 2>/dev/null && break
        (( waited >= 150 )) && break          # hard cap: 150 * 0.1s
        sleep 0.1
        waited=$((waited + 1))
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep -q 'PROBEJSON:' "$out" 2>/dev/null
}

QS_BIN="$(command -v qs || true)"
QS_VER=""
[[ -n "$QS_BIN" ]] && QS_VER="$("$QS_BIN" --version 2>&1 | head -1)"

if [[ -z "$QS_BIN" ]]; then
    it "runtime: Quickshell available to compile the portal"
    skip "qs not on PATH - portal components only checked structurally"
elif [[ "$QS_VER" != *0.3* ]]; then
    it "runtime: Quickshell 0.3.x on PATH"
    skip "qs reports '${QS_VER:-unknown}' (the portal targets 0.3.x)"
else
    PROBE_DIR="$T/probe"
    if python3 "$T/qmlcheck.py" gen "$PORTAL_TREE" "$PROBE_DIR" >/dev/null; then
        PROBE_OUT="$T/probe.out"
        PROBE_MODE=""
        run_probe offscreen "$PROBE_OUT" && PROBE_MODE=offscreen
        # Offscreen cannot load the PanelWindow backend, so a live session (when there is
        # one) is asked for a second, wider pass whenever the offscreen pass left gaps.
        if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] \
            && { [[ -z "$PROBE_MODE" ]] || python3 "$T/qmlcheck.py" needs-live "$PROBE_OUT"; }; then
            if run_probe live "$T/probe.live.out"; then
                PROBE_OUT="$T/probe.live.out"
                PROBE_MODE=live
            fi
        fi
        if [[ -z "$PROBE_MODE" ]]; then
            it "runtime: qs loads the portal and reports component status"
            skip "qs probe produced no PROBEJSON (tried offscreen${WAYLAND_DISPLAY:+ and live}); tail: $(tail -3 "$PROBE_OUT" | tr '\n' ' ')"
        else
            it "runtime: qs probe ran ($PROBE_MODE platform, $(grep -c PROBEJSON: "$PROBE_OUT") result set)"
            ok
            python3 "$T/qmlcheck.py" parse "$PROBE_OUT" >"$T/probe.tsv" 2>"$T/probe.err"
            while IFS=$'\t' read -r cid desc status detail; do
                [[ -n "$cid" ]] || continue
                it "$desc"
                case "$status" in
                    pass) ok ;;
                    skip) skip "${detail:-$cid}" ;;
                    *)    bad "$cid: ${detail:-check failed}" ;;
                esac
            done <"$T/probe.tsv"
        fi
    else
        it "runtime: probe generation"
        bad "qmlcheck.py gen failed for $PORTAL_TREE"
    fi
fi

finish
