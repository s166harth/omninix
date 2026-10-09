// tests/js/units.js — runtime-agnostic test body for the two pure-JS units of nixmarchy.
//
// Invoked by tests/js.test.sh with argv: <AppSearch.js> <BorderGeometry.js>.
// Works on node, bun and deno (no npm, no QML host): each file is read, its
// `.pragma` directive is stripped, and the source is evaluated in-process, so
// `Qt` stays undefined and the helpers take their JS-string code paths.
//
// Emits one tab-separated line per case — "PASS<TAB>name<TAB>", "FAIL<TAB>name<TAB>reason",
// "SKIP<TAB>name<TAB>reason" — then a final "DONE" marker; exits non-zero on failure.

const isDeno = typeof globalThis.Deno !== "undefined" && typeof globalThis.Deno.readTextFileSync === "function";
let readText, argv, doExit;
if (isDeno) {
  readText = (p) => globalThis.Deno.readTextFileSync(p);
  argv = globalThis.Deno.args;
  doExit = (c) => globalThis.Deno.exit(c);
} else {
  const fs = require("fs");
  readText = (p) => fs.readFileSync(p, "utf8");
  argv = process.argv.slice(2);
  doExit = (c) => process.exit(c);
}

let pass = 0, fail = 0, skipc = 0;
const clean = (s) => String(s == null ? "" : s).replace(/[\t\r\n]+/g, " ").slice(0, 400);
const repr = (v) => { try { return JSON.stringify(v); } catch (e) { return String(v); } };

function P(name) { pass++; console.log("PASS\t" + name + "\t"); }
function F(name, detail) { fail++; console.log("FAIL\t" + name + "\t" + clean(detail)); }
function S(name, detail) { skipc++; console.log("SKIP\t" + name + "\t" + clean(detail)); }

function tcase(name, fn) {
  try { fn(); P(name); } catch (e) { F(name, (e && e.message) || String(e)); }
}
function eq(actual, expected, what) {
  if (actual !== expected) throw new Error((what || "value") + ": expected " + repr(expected) + " got " + repr(actual));
}
function assert(cond, what) { if (!cond) throw new Error(what || "expected truthy"); }
function approx(actual, expected, eps, what) {
  if (!(Math.abs(actual - expected) <= eps)) throw new Error((what || "value") + ": expected ~" + expected + " got " + actual);
}
function deep(actual, expected, what) {
  const a = repr(actual), b = repr(expected);
  if (a !== b) throw new Error((what || "value") + ": expected " + b + " got " + a);
}

function loadUnit(src) {
  const body = src.split(/\r?\n/).filter((l) => !/^\s*\.pragma\b/.test(l)).join("\n");
  const names = [];
  const re = /^function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/gm;
  let m;
  while ((m = re.exec(body)) !== null) names.push(m[1]);
  const api = new Function(body + "\nreturn { " + names.join(", ") + " };\n")();
  api.__names = names;
  return api;
}

let A = null, BG = null;
const specs = [["AppSearch.js", argv[0]], ["BorderGeometry.js", argv[1]]];
const loaded = [];
for (const [label, path] of specs) {
  try {
    if (!path) throw new Error("no path given");
    const u = loadUnit(readText(path));
    if (!u.__names.length) throw new Error("no function declarations found");
    loaded.push(u);
  } catch (e) {
    F("load " + label, (e && e.message) || String(e));
    loaded.push(null);
  }
}
A = loaded[0];
BG = loaded[1];

// ---------------------------------------------------------------- AppSearch.js
if (A) {
  tcase("AppSearch exposes its documented function inventory", () => {
    for (const n of ["entryName", "entrySubtext", "entrySortKey", "keywordText", "entrySearchText",
      "wordText", "words", "entryAcronym", "termMatches", "allTermsMatch", "fuzzyScore", "sortedEntries"])
      eq(typeof A[n], "function", "export " + n);
    assert(A.__names.length >= 12, "function count " + A.__names.length);
  });

  tcase("entryName falls back name→id→'' and coerces", () => {
    eq(A.entryName({ name: "Firefox", id: "x" }), "Firefox");
    eq(A.entryName({ id: "org.mozilla.Firefox" }), "org.mozilla.Firefox");
    eq(A.entryName({ name: "", id: "i" }), "i");
    eq(A.entryName({ name: 0, id: "i" }), "i");
    eq(A.entryName({ name: 0 }), "");
    eq(A.entryName(null), "");
    eq(A.entryName(undefined), "");
  });

  tcase("entrySubtext/entrySortKey/keywordText", () => {
    eq(A.entrySubtext({ genericName: "Web Browser" }), "Web Browser");
    eq(A.entrySubtext({ name: "X" }), "");
    eq(A.entrySubtext(null), "");
    eq(A.entrySortKey({ name: "Zed" }), "zed");
    eq(A.entrySortKey({ id: "Org.Mozilla.Firefox" }), "org.mozilla.firefox");
    eq(A.keywordText({ keywords: ["web", "browser"] }), "web browser");
    eq(A.keywordText({ keywords: [] }), "");
    eq(A.keywordText({ keywords: "web" }), "");
    eq(A.keywordText({ keywords: { join: function () { throw new Error("boom"); } } }), "");
    eq(A.keywordText(null), "");
  });

  tcase("entrySearchText lowercases the name/generic/comment/keywords/id join", () => {
    eq(A.entrySearchText({ name: "Firefox", genericName: "Web Browser", comment: "Fast", keywords: ["web"], id: "Org.Mozilla.Firefox" }),
      "firefox web browser fast web org.mozilla.firefox");
    eq(A.entrySearchText(null), "");
    eq(A.entrySearchText({ name: "Only" }).trim(), "only");
    assert(!A.entrySearchText({ name: "Only" }).includes("undefined"), "no 'undefined' padding");
  });

  tcase("wordText splits camelCase/digits and separator runs, then lowercases", () => {
    eq(A.wordText("FireFox"), "fire fox");
    eq(A.wordText("Parse2HTML"), "parse2 html");
    eq(A.wordText("HTTPServer"), "httpserver");
    eq(A.wordText("foo_bar-baz.qux:zap/quux\\corge"), "foo bar baz qux zap quux corge");
    eq(A.wordText(null), "");
    eq(A.wordText(0), "");
  });

  tcase("words drops empties and lowercases tokens", () => {
    deep(A.words("foo_bar baz"), ["foo", "bar", "baz"]);
    deep(A.words("  "), []);
    deep(A.words("A-B"), ["a", "b"]);
  });

  tcase("entryAcronym takes the first letter of every word", () => {
    eq(A.entryAcronym({ name: "Visual Studio Code" }), "vsc");
    eq(A.entryAcronym({ name: "Firefox" }), "f");
    eq(A.entryAcronym(null), "");
  });

  tcase("termMatches checks name/id/haystack, with a ≤5-char acronym fallback", () => {
    const viz = { name: "Visual Studio Code", genericName: "Editor", comment: "code editor", keywords: ["ide"], id: "com.visualstudio.code" };
    eq(A.termMatches(viz, ""), true);
    eq(A.termMatches(viz, "code"), true);
    eq(A.termMatches(viz, "visual"), true);
    eq(A.termMatches(viz, "editor"), true);
    eq(A.termMatches(viz, "visualstudio"), true); // matches the id "com.visualstudio.code"
    eq(A.termMatches(viz, "vsczzz"), false);
    eq(A.termMatches(viz, "vsc"), true);
    eq(A.termMatches(viz, "vscc"), false);
    eq(A.termMatches(viz, "zzz"), false);
    eq(A.termMatches(viz, "CODE"), false); // term is expected pre-lowercased by allTermsMatch
    eq(A.termMatches({ name: "Alpha Beta Gamma Delta Echo Foxtrot" }, "abgd"), true);
    eq(A.termMatches({ name: "Alpha Beta Gamma Delta Echo Foxtrot" }, "abgdef"), false);
  });

  tcase("allTermsMatch requires every whitespace term, case-insensitively", () => {
    const e = { name: "Visual Studio Code", genericName: "Editor" };
    eq(A.allTermsMatch(e, "VISUAL editor"), true);
    eq(A.allTermsMatch(e, "visual zzz"), false);
    eq(A.allTermsMatch(e, ""), true);
    eq(A.allTermsMatch(e, "   "), true);
    eq(A.allTermsMatch(e, "visual  studio"), true);
  });

  tcase("fuzzyScore: 0 on empty query, -1 on no match", () => {
    eq(A.fuzzyScore({ name: "Code" }, ""), 0);
    eq(A.fuzzyScore({ name: "Code" }, "   "), 0);
    eq(A.fuzzyScore({ name: "Zed" }, "code"), -1);
  });

  tcase("fuzzyScore ranking tiers: name-prefix beats id-prefix beats contains", () => {
    eq(A.fuzzyScore({ name: "Code", id: "zzzzzzzzzz" }, "code"), 10000 - 4);
    eq(A.fuzzyScore({ name: "Editor", id: "code-editor" }, "code"), 9500 - "code-editor".length);
    eq(A.fuzzyScore({ name: "My Code", id: "zzzzzzzzzz" }, "code"), 8000 - 3 * 10 - "my code".length);
    eq(A.fuzzyScore({ name: "Editor", id: "my-code" }, "code"), 7600 - 3 * 10 - "my-code".length);
    eq(A.fuzzyScore({ name: "Editor", genericName: "code thing" }, "code"), 6000 - 7);
  });

  tcase("fuzzyScore acronym tiers then name-length fallback", () => {
    eq(A.fuzzyScore({ name: "Alpha Beta" }, "ab"), 5000 - 2);
    eq(A.fuzzyScore({ name: "Zulu Alpha Bravo" }, "ab"), 4600 - 1 * 10 - 3);
    eq(A.fuzzyScore({ name: "Alpha Beta Gamma" }, "beta alpha"), 4000 - "alpha beta gamma".length);
  });

  tcase("sortedEntries drops falsy/nameless/noDisplay/hidden/non-matching rows", () => {
    const junk = [{ name: "Ok" }, null, undefined, { noDisplay: true, name: "Nope" }, { genericName: "no name" }, 0, ""];
    eq(A.sortedEntries(junk, "").length, 1);
    deep(A.sortedEntries([{ name: "Zed" }], "qqq"), []);
    const hidden = A.sortedEntries([{ name: "Zed" }, { name: "Aaa" }], "", (e) => e.name === "Zed");
    deep(hidden.map((r) => r.entry.name), ["Aaa"]);
  });

  tcase("sortedEntries sorts alphabetically by key for an empty query (id-only entries included)", () => {
    const apps = [
      { name: "Zed", id: "dev.zed" },
      { name: "Firefox", id: "org.mozilla.firefox" },
      { name: "Files", id: "io.files", noDisplay: true },
      { name: "Hidden App", id: "io.hidden" },
      { id: "io.idonly" },
    ];
    const rows = A.sortedEntries(apps, "", (e) => e.id === "io.hidden");
    eq(rows.length, 3);
    deep(rows.map((r) => r.key), ["firefox", "io.idonly", "zed"]);
  });

  tcase("sortedEntries ranks by descending score for a query", () => {
    const rank = [
      { name: "Code", id: "zzz" },
      { name: "Editor", id: "code-editor" },
      { name: "My Code", id: "zzz" },
      { name: "Editor", id: "my-code" },
      { name: "Editor", genericName: "code thing" },
      { name: "Alpha Beta" },
    ];
    const rows = A.sortedEntries(rank, "code");
    deep(rows.map((r) => r.entry.id === "zzz" && r.entry.name === "Code" ? "Code" : r.entry.name),
      ["Code", "Editor", "My Code", "Editor", "Editor"]);
    assert(rows[0].score > rows[1].score && rows[1].score > rows[2].score, "scores descend");
  });

  tcase("sortedEntries ties break by key, then name", () => {
    const rows = A.sortedEntries([{ name: "Ac", id: "z" }, { name: "Ab", id: "z" }], "a");
    eq(rows[0].score, rows[1].score);
    deep(rows.map((r) => r.key), ["ab", "ac"]);
  });

  tcase("sortedEntries row shape is {entry,score,key,name}", () => {
    const rows = A.sortedEntries([{ name: "Zed" }], "");
    eq(rows.length, 1);
    eq(rows[0].entry.name, "Zed");
    eq(rows[0].key, "zed");
    eq(rows[0].name, "zed");
    eq(rows[0].score, 0);
  });
}

// ---------------------------------------------------------- BorderGeometry.js
if (BG) {
  tcase("BorderGeometry exposes its documented function inventory", () => {
    for (const n of ["clamp", "clampAlpha", "padHex", "qmlHexColor", "canonicalColor", "parseWidthSpec",
      "withSideOverrides", "parseGradientSpec", "isUniform", "maxWidth", "needsOverlay", "canUseNative",
      "normalizeRadii", "roundedRectPath", "borderBoundary", "borderPaths", "ringPath", "gradientEndpoints",
      "stopColor", "stopPosition", "radiiFit"])
      eq(typeof BG[n], "function", "export " + n);
  });

  tcase("clamp/clampAlpha clamp to range, non-finite collapses to min", () => {
    eq(BG.clamp(5, 0, 10), 5);
    eq(BG.clamp(-1, 0, 10), 0);
    eq(BG.clamp(20, 0, 10), 10);
    eq(BG.clamp("4", 0, 10), 4);
    eq(BG.clamp(NaN, 3, 9), 3);
    eq(BG.clamp(Infinity, 3, 9), 3);
    eq(BG.clamp(-Infinity, 3, 9), 3);
    eq(BG.clamp(undefined, 2, 4), 2);
    eq(BG.clamp("abc", 1, 2), 1);
    eq(BG.clampAlpha(-1), 0);
    eq(BG.clampAlpha(2), 1);
    eq(BG.clampAlpha(0.5), 0.5);
  });

  tcase("padHex rounds and clamps to 00..ff", () => {
    eq(BG.padHex(0), "00");
    eq(BG.padHex(5), "05");
    eq(BG.padHex(16), "10");
    eq(BG.padHex(15.4), "0f");
    eq(BG.padHex(15.5), "10");
    eq(BG.padHex(255), "ff");
    eq(BG.padHex(256), "ff");
    eq(BG.padHex(-3), "00");
  });

  tcase("qmlHexColor returns #rrggbb[aa] when Qt is absent", () => {
    eq(BG.qmlHexColor("00ff00", 255), "#00ff00");
    eq(BG.qmlHexColor("#00ff00", 255), "#00ff00");
    eq(BG.qmlHexColor("00ff00", 128), "#00ff0080");
    eq(BG.qmlHexColor("00ff00", 0), "#00ff0000");
    eq(BG.qmlHexColor("00ff00", 999), "#00ff00");
    eq(BG.qmlHexColor("00ff00"), "#00ff0000");
  });

  tcase("canonicalColor parses #rgb/#rrggbb/#rrggbbaa and scales alpha", () => {
    eq(BG.canonicalColor("#fff"), "#ffffff");
    eq(BG.canonicalColor("#ABC"), "#AABBCC");
    eq(BG.canonicalColor(" #abc "), "#aabbcc");
    eq(BG.canonicalColor("#fff", 0.5), "#ffffff80");
    eq(BG.canonicalColor("#123456"), "#123456");
    eq(BG.canonicalColor("#123456", 0.5), "#12345680");
    eq(BG.canonicalColor("#12345680"), "#12345680");
    eq(BG.canonicalColor("#12345680", 0.5), "#12345640");
  });

  tcase("canonicalColor parses RGB()/RGBA()/rgb()/rgba()/0xAARRGGBB", () => {
    eq(BG.canonicalColor("RGB(ff0000)"), "#ff0000");
    eq(BG.canonicalColor("RGBA(a0ff0080)"), "#a0ff0080");
    eq(BG.canonicalColor("RGBA(a0ff00ff)"), "#a0ff00");
    eq(BG.canonicalColor("rgb(255,0,0)"), "#ff0000");
    eq(BG.canonicalColor("rgba(255,0,0,0.5)"), "#ff000080");
    eq(BG.canonicalColor("0x80ff0000"), "#ff000080");
    eq(BG.canonicalColor("red"), "red");
    eq(BG.canonicalColor(""), "");
    eq(BG.canonicalColor(null), "");
    eq(BG.canonicalColor("#ffff"), "#ffff");
  });

  tcase("parseWidthSpec maps 1–4 CSS-like values onto the four sides", () => {
    deep(BG.parseWidthSpec("", 2), { top: 2, right: 2, bottom: 2, left: 2 });
    deep(BG.parseWidthSpec(null, 3), { top: 3, right: 3, bottom: 3, left: 3 });
    deep(BG.parseWidthSpec(undefined, 0), { top: 0, right: 0, bottom: 0, left: 0 });
    deep(BG.parseWidthSpec("4", 0), { top: 4, right: 4, bottom: 4, left: 4 });
    deep(BG.parseWidthSpec("2.5px", 0), { top: 2.5, right: 2.5, bottom: 2.5, left: 2.5 });
    deep(BG.parseWidthSpec("1 2", 0), { top: 1, right: 2, bottom: 1, left: 2 });
    deep(BG.parseWidthSpec("1 2 3", 0), { top: 1, right: 2, bottom: 3, left: 2 });
    deep(BG.parseWidthSpec("1 2 3 4", 0), { top: 1, right: 2, bottom: 3, left: 4 });
    deep(BG.parseWidthSpec("1 2 3 4 5", 0), { top: 1, right: 2, bottom: 3, left: 4 });
    deep(BG.parseWidthSpec("0 -5 3", 0), { top: 0, right: 0, bottom: 3, left: 0 });
    deep(BG.parseWidthSpec("abc", 7), { top: 7, right: 7, bottom: 7, left: 7 });
    deep(BG.parseWidthSpec("", -2), { top: 0, right: 0, bottom: 0, left: 0 });
  });

  tcase("withSideOverrides copies base widths and applies only defined, non-empty overrides", () => {
    const base = { top: 1, right: 2, bottom: 3, left: 4 };
    deep(BG.withSideOverrides(base, 9), { top: 9, right: 2, bottom: 3, left: 4 });
    deep(BG.withSideOverrides(base, 9, 8, 7, 6), { top: 9, right: 8, bottom: 7, left: 6 });
    deep(BG.withSideOverrides(base, undefined, "", null, 5), { top: 1, right: 2, bottom: 3, left: 5 });
    deep(BG.withSideOverrides(base, -3, "x"), { top: 0, right: 0, bottom: 3, left: 4 });
    deep(BG.withSideOverrides(null, 2), { top: 2, right: 0, bottom: 0, left: 0 });
    deep(BG.withSideOverrides({ top: "5", right: null, bottom: undefined, left: NaN }, 1), { top: 1, right: 0, bottom: 0, left: 0 });
  });

  tcase("parseGradientSpec splits angles/colors, falls back, enables only on 2+ colors", () => {
    const g1 = BG.parseGradientSpec("900deg #f00 #00f");
    eq(g1.angle, 900);
    deep(g1.colors, ["#ff0000", "#0000ff"]);
    eq(g1.enabled, true);
    const g2 = BG.parseGradientSpec("#fff");
    eq(g2.angle, 0);
    deep(g2.colors, ["#ffffff"]);
    eq(g2.enabled, false);
    const g3 = BG.parseGradientSpec("", "#123456");
    deep(g3.colors, ["#123456"]);
    eq(g3.enabled, false);
    const g4 = BG.parseGradientSpec("", null);
    deep(g4.colors, []);
    eq(g4.enabled, false);
    const g5 = BG.parseGradientSpec("-45deg #000 #fff", null, 0.5);
    eq(g5.angle, -45);
    deep(g5.colors, ["#00000080", "#ffffff80"]);
    const g6 = BG.parseGradientSpec("45deg");
    eq(g6.angle, 45);
    deep(g6.colors, []);
  });

  tcase("isUniform/maxWidth/needsOverlay/canUseNative", () => {
    eq(BG.isUniform(null), true);
    eq(BG.isUniform(undefined), true);
    eq(BG.isUniform({ top: 1, right: 1, bottom: 1, left: 1 }), true);
    eq(BG.isUniform({ top: 1, right: 2, bottom: 1, left: 1 }), false);
    eq(BG.isUniform({ top: 1, right: "1", bottom: 1, left: 1 }), false);
    eq(BG.maxWidth(null), 0);
    eq(BG.maxWidth({ top: 1, right: 5, bottom: 2, left: 3 }), 5);
    eq(BG.maxWidth({ top: -5, right: -2, bottom: 1, left: -3 }), 1);
    eq(BG.maxWidth({ top: -5, right: -2, bottom: -1, left: -3 }), -1);
    eq(BG.needsOverlay(null), false);
    eq(BG.needsOverlay({ widths: { top: 0, right: 0, bottom: 0, left: 0 } }), false);
    eq(BG.needsOverlay({ widths: { top: 1, right: 1, bottom: 1, left: 1 } }), false);
    eq(BG.needsOverlay({ widths: { top: 1, right: 2, bottom: 1, left: 1 } }), true);
    eq(BG.needsOverlay({ widths: { top: 1, right: 1, bottom: 1, left: 1 }, gradient: { enabled: true } }), true);
    eq(BG.canUseNative(null), false);
    eq(BG.canUseNative({}), false);
    eq(BG.canUseNative({ widths: { top: 0, right: 0, bottom: 0, left: 0 } }), false);
    eq(BG.canUseNative({ widths: { top: 1, right: 1, bottom: 1, left: 1 } }), true);
    eq(BG.canUseNative({ widths: { top: 1, right: 2, bottom: 1, left: 1 } }), false);
  });

  tcase("normalizeRadii clamps negatives and scales to fit the box", () => {
    const full = { tlrx: 10, tlry: 10, trrx: 10, trry: 10, brrx: 10, brry: 10, blrx: 10, blry: 10 };
    const r0 = BG.normalizeRadii(100, 50, full);
    deep(r0, { tl: { rx: 10, ry: 10 }, tr: { rx: 10, ry: 10 }, br: { rx: 10, ry: 10 }, bl: { rx: 10, ry: 10 } });
    eq(typeof r0.tl.rx, "number");
    const r1 = BG.normalizeRadii(10, 100, { tlrx: 8, tlry: 0, trrx: 8, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 });
    eq(r1.tl.rx, 5);
    eq(r1.tr.rx, 5);
    const r2 = BG.normalizeRadii(100, 10, { tlrx: 0, tlry: 8, trrx: 0, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 8 });
    eq(r2.tl.ry, 5);
    eq(r2.bl.ry, 5);
    const r3 = BG.normalizeRadii(10, 10, { tlrx: 8, tlry: 8, trrx: 8, trry: 8, brrx: 8, brry: 8, blrx: 8, blry: 8 });
    eq(r3.tl.rx, 5);
    eq(r3.tl.ry, 5);
    deep(BG.normalizeRadii(10, 10, { tlrx: -5, tlry: -5, trrx: 0, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 }),
      { tl: { rx: 0, ry: 0 }, tr: { rx: 0, ry: 0 }, br: { rx: 0, ry: 0 }, bl: { rx: 0, ry: 0 } });
    eq(BG.normalizeRadii(0, 0, full).tl.rx, 0);
  });

  tcase("appendArc emits an arc token only when both radii are positive", () => {
    const p1 = []; BG.appendArc(p1, 5, 4, 1, { x: 10, y: 20 });
    deep(p1, ["A", 5, 4, 0, 0, 1, 10, 20]);
    const p2 = []; BG.appendArc(p2, 0, 4, 1, { x: 10, y: 20 });
    deep(p2, ["L", 10, 20]);
    const p3 = []; BG.appendArc(p3, 5, 0, 0, { x: 1, y: 2 });
    deep(p3, ["L", 1, 2]);
  });

  tcase("roundedRectPath is empty for degenerate sizes and exact for square corners", () => {
    const z = { tlrx: 0, tlry: 0, trrx: 0, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 };
    eq(BG.roundedRectPath(0, 0, 0, 10, z), "");
    eq(BG.roundedRectPath(0, 0, 10, -1, z), "");
    eq(BG.roundedRectPath(0, 0, 10, 10, z), "M 0 0 H 10 L 10 0 V 10 L 10 10 H 0 L 0 10 V 0 L 0 0 Z");
    const big = { tlrx: 8, tlry: 8, trrx: 8, trry: 8, brrx: 8, brry: 8, blrx: 8, blry: 8 };
    assert(BG.roundedRectPath(0, 0, 10, 10, big).startsWith("M 5 0"), "radii normalized before pathing");
  });

  tcase("roundedRectPath emits one arc per rounded corner offset", () => {
    const r = { tlrx: 5, tlry: 5, trrx: 5, trry: 5, brrx: 5, brry: 5, blrx: 5, blry: 5 };
    const s = BG.roundedRectPath(0, 0, 100, 100, r);
    assert(s.startsWith("M 5 0 H 95 A 5 5 0 0 1 100 5 V 95"), s.slice(0, 40));
    eq(s.split(" ").filter((t) => t === "A").length, 4);
    eq(s.slice(-1), "Z");
  });

  tcase("borderBoundary emits 4 start/end points and tr/br/bl/tl corners", () => {
    const z = { tlrx: 0, tlry: 0, trrx: 0, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 };
    const b = BG.borderBoundary(0, 0, 10, 10, z);
    deep(b.start, [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]);
    deep(b.end, [{ x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }, { x: 0, y: 0 }]);
    eq(b.corner.length, 4);
    const r = BG.normalizeRadii(10, 10, { tlrx: 2, tlry: 2, trrx: 0, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 });
    const b2 = BG.borderBoundary(0, 0, 10, 10, r);
    eq(b2.start[0].x, 2);
    eq(b2.start[0].y, 0);
    eq(b2.end[3].y, 2);
    assert(b2.corner[0] === r.tr && b2.corner[3] === r.tl, "corner order tr,br,bl,tl");
  });

  tcase("reverseBoundaryPath walks the boundary in reverse with zero radii", () => {
    const z = { tlrx: 0, tlry: 0, trrx: 0, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 };
    const b = BG.borderBoundary(0, 0, 10, 10, z);
    eq(BG.reverseBoundaryPath(b), "M 0 0 L 0 0 L 0 10 L 0 10 L 10 10 L 10 10 L 10 0 L 10 0 L 0 0 Z");
  });

  tcase("borderPaths/ringPath topology: empty cases", () => {
    const zero = { top: 0, right: 0, bottom: 0, left: 0 };
    deep(BG.borderPaths(0, 0, 0, { top: 1, right: 1, bottom: 1, left: 1 }), []);
    eq(BG.ringPath(0, 10, 0, zero), "");
    eq(BG.ringPath(10, 0, 0, { top: 1, right: 1, bottom: 1, left: 1 }), "");
    eq(BG.ringPath(10, 10, 0, zero), "");
    eq(BG.ringPath(10, 10, 0, { top: -5, right: -5, bottom: -5, left: -5 }), "");
    eq(BG.ringPath("x", "y", 0, { top: 1, right: 1, bottom: 1, left: 1 }), "");
  });

  tcase("borderPaths/ringPath topology: connected sides share one contour", () => {
    const mCount = (s) => s.split(" ").filter((t) => t === "M").length;
    const uni = BG.borderPaths(10, 10, 0, { top: 1, right: 1, bottom: 1, left: 1 });
    eq(uni.length, 1);
    eq(mCount(uni[0]), 2);
    const ring = BG.ringPath(10, 10, 0, { top: 1, right: 1, bottom: 1, left: 1 });
    assert(ring.startsWith("M 0 0"), ring.slice(0, 12));
    assert(ring.includes(" M 1 1 "), "inner loop present: " + ring.slice(0, 40));
    eq(BG.borderPaths(10, 10, 0, { top: 1, right: 2, bottom: 1, left: 2 }).length, 1);
    eq(BG.borderPaths(10, 10, 0, { top: 1, right: 1, bottom: 0, left: 0 }).length, 1);
    eq(BG.borderPaths(10, 10, 0, { top: 1, right: 0, bottom: 0, left: 0 }).length, 1);
    eq(mCount(BG.ringPath(10, 10, 0, { top: 1, right: 0, bottom: 0, left: 0 })), 1);
    eq(BG.borderPaths(10, 10, 0, { top: 1, right: 0, bottom: 1, left: 0 }).length, 2);
  });

  tcase("borderPaths collapses to the outer contour when the interior vanishes", () => {
    const collapsed = BG.borderPaths(10, 10, 0, { top: 1, right: 5, bottom: 1, left: 5 });
    eq(collapsed.length, 1);
    eq(collapsed[0].split(" ").filter((t) => t === "M").length, 1);
    assert(BG.ringPath(1e6, 1e6, 100, { top: 10, right: 10, bottom: 10, left: 10 }).length > 0, "huge sizes");
  });

  tcase("gradientEndpoints centers a line across the box", () => {
    const g0 = BG.gradientEndpoints(100, 50, 0);
    eq(g0.x1, 0); eq(g0.y1, 25); eq(g0.x2, 100); eq(g0.y2, 25);
    const g180 = BG.gradientEndpoints(100, 50, 180);
    approx(g180.x1, 100, 1e-9); approx(g180.y1, 25, 1e-9);
    approx(g180.x2, 0, 1e-9); approx(g180.y2, 25, 1e-9);
    const g90 = BG.gradientEndpoints(100, 50, 90);
    approx(g90.x1, 50, 1e-9); approx(g90.y1, 0, 1e-9);
    approx(g90.x2, 50, 1e-9); approx(g90.y2, 50, 1e-9);
    const gd = BG.gradientEndpoints(0, 0, 0);
    eq(gd.x1, 0); eq(gd.y1, 0.5); eq(gd.x2, 1); eq(gd.y2, 0.5);
    const gn = BG.gradientEndpoints("x", "y", "z");
    approx(gn.x1, 0, 1e-9); approx(gn.x2, 1, 1e-9);
  });

  tcase("stopColor/stopPosition pick gradient stops", () => {
    eq(BG.stopColor([], 0), "transparent");
    eq(BG.stopColor(null, 3), "transparent");
    eq(BG.stopColor(["a", "b", "c"], 0), "a");
    eq(BG.stopColor(["a", "b", "c"], 2), "c");
    eq(BG.stopColor(["a", "b", "c"], 5), "c");
    eq(BG.stopPosition(["a", "b", "c"], 0), 0);
    eq(BG.stopPosition(["a", "b", "c"], 1), 0.5);
    eq(BG.stopPosition(["a", "b", "c"], 2), 1);
    eq(BG.stopPosition(["a", "b", "c"], 9), 1);
    eq(BG.stopPosition(["a"], 0), 0);
    eq(BG.stopPosition(["a"], 1), 1);
    eq(BG.stopPosition(null, 0), 0);
    eq(BG.stopPosition(null, 1), 1);
  });

  tcase("radiiFit rejects corners whose radii overflow either axis", () => {
    eq(BG.radiiFit(10, 10, { tlrx: 5, tlry: 5, trrx: 5, trry: 5, brrx: 5, brry: 5, blrx: 5, blry: 5 }), true);
    eq(BG.radiiFit(10, 10, { tlrx: 6, tlry: 0, trrx: 6, trry: 0, brrx: 0, brry: 0, blrx: 0, blry: 0 }), false);
    eq(BG.radiiFit(10, 10, { tlrx: 0, tlry: 0, trrx: 0, trry: 6, brrx: 0, brry: 6, blrx: 0, blry: 0 }), false);
  });
}

console.log("DONE");
doExit(fail > 0 ? 1 : 0);
