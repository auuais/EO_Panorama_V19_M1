// Customer-facing latency and frame-rate analysis for the six-camera EO/IR
// panorama.
//
// Every figure is one of: a constant read out of the RTL, a simulation result,
// an ILA measurement taken in fabric, or an optical measurement taken off the
// SDI output.  The basis slide says which is which and names the build and the
// date.  Keep that truthful if you edit this.
//
//   node docs/latency/build_deck.js

const pptxgen = require("pptxgenjs");

const C = {
  ink:      "0E1C36",
  ink2:     "16233A",
  body:     "27374F",
  muted:    "6B7C97",
  paper:    "FFFFFF",
  panel:    "F2F5FA",
  line:     "D3DCEA",
  eo:       "1C7293",
  eoLite:   "DCEAF0",
  ir:       "C1663A",
  irLite:   "F6E7DE",
  good:     "02A37A",
  goodLite: "DAF2EB",
  warn:     "C2A33B",
  warnLite: "F7F0D8",
  bad:      "B4443A",
  badLite:  "F6E2E0",
  code:     "1B2A45",
  white:    "FFFFFF",
};

const FH = "Cambria";
const FB = "Calibri";
const FM = "Consolas";

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE";
pres.author = "EO/IR Panorama V19";
pres.title  = "Latency and Frame Rate Analysis";

// ------------------------------------------------------------------ helpers

function darkSlide() {
  const s = pres.addSlide();
  s.background = { color: C.ink };
  return s;
}

function lightSlide(title, kicker) {
  const s = pres.addSlide();
  s.background = { color: C.paper };
  if (kicker) {
    s.addText(kicker.toUpperCase(), {
      x: 0.6, y: 0.34, w: 11, h: 0.26, fontSize: 11, bold: true,
      color: C.muted, fontFace: FB, charSpacing: 2, margin: 0,
    });
  }
  s.addText(title, {
    x: 0.6, y: kicker ? 0.60 : 0.44, w: 12.2, h: 0.6,
    fontSize: 30, bold: true, color: C.ink, fontFace: FH, margin: 0,
  });
  return s;
}

function note(s, text, y) {
  s.addText(text, {
    x: 0.6, y: y, w: 12.15, h: 0.5, fontSize: 11.5, color: C.muted,
    fontFace: FB, margin: 0, italic: true, valign: "top",
  });
}

function statCard(s, x, y, w, big, label, tone) {
  s.addShape(pres.ShapeType.roundRect, {
    x, y, w, h: 1.42, rectRadius: 0.06,
    fill: { color: C.panel }, line: { color: C.line, width: 1 },
  });
  const fs = big.length <= 4 ? 32 : big.length <= 7 ? 24 : 19;
  s.addText(big, {
    x: x + 0.06, y: y + 0.14, w: w - 0.12, h: 0.66, fontSize: fs, bold: true,
    color: tone || C.ink, align: "center", fontFace: FH, margin: 0, valign: "middle",
  });
  s.addText(label, {
    x: x + 0.1, y: y + 0.84, w: w - 0.2, h: 0.5, fontSize: 10,
    color: C.body, align: "center", fontFace: FB, margin: 0, valign: "top",
  });
}

// Monospace evidence block, for RTL excerpts and tool output.
function codeBlock(s, x, y, w, h, lines, tone) {
  s.addShape(pres.ShapeType.roundRect, {
    x, y, w, h, rectRadius: 0.05,
    fill: { color: C.code }, line: { color: tone || C.ink2, width: 1.25 },
  });
  s.addText(lines.map((t, i) => ({
    text: t === "" ? " " : t,
    options: { breakLine: i < lines.length - 1,
               color: t.trim().startsWith("//") ? "7E93B5" : "D8E4F5" },
  })), {
    x: x + 0.16, y: y + 0.12, w: w - 0.32, h: h - 0.24,
    fontSize: 10, fontFace: FM, margin: 0, valign: "top", lineSpacingMultiple: 1.06,
  });
}

// ---------------------------------------------------------------------------
// CONCURRENT TIMELINE.
//
// The whole point of this helper: stages that OVERLAP in time are drawn on
// their own lane at their true offset against one shared axis, so nobody can
// read the picture as a chain of durations to be added up.  Drawing capture,
// render and scan-out end to end is what makes a 74 ms path look like 108.
// ---------------------------------------------------------------------------
function timeAxis(s, x0, y0, w, spanMs, tickMs, label) {
  s.addShape(pres.ShapeType.line, {
    x: x0, y: y0, w: w, h: 0,
    line: { color: C.muted, width: 1 },
  });
  for (let t = 0; t <= spanMs + 0.01; t += tickMs) {
    const x = x0 + (t / spanMs) * w;
    s.addShape(pres.ShapeType.line, {
      x, y: y0 - 0.09, w: 0, h: 0.09, line: { color: C.muted, width: 1 },
    });
    // Labels sit ABOVE the axis so the dashed moment guides, which run
    // downwards from it, cannot strike through them.
    s.addText(t.toFixed(1), {
      x: x - 0.42, y: y0 - 0.34, w: 0.84, h: 0.24, fontSize: 8.5,
      color: C.muted, align: "center", fontFace: FB, margin: 0,
    });
  }
  if (label) {
    s.addText(label, {
      x: x0 + w - 3.6, y: y0 + 0.06, w: 3.6, h: 0.24, fontSize: 9, color: C.muted,
      align: "right", fontFace: FB, margin: 0, italic: true,
    });
  }
}

// Display frame edges: the grid a finished frame may be published on.  Its
// phase against the camera is free-running and not controllable, which is the
// whole reason a best and a worst case exist.
function edgeLane(s, x0, y, w, spanMs, phase, periodMs, name) {
  s.addText(name, {
    x: x0 - 2.47, y: y - 0.02, w: 2.35, h: 0.34, fontSize: 10.5, color: C.body,
    align: "right", fontFace: FB, margin: 0, valign: "middle",
  });
  for (let t = phase; t <= spanMs + 0.01; t += periodMs) {
    if (t < 0) continue;
    const x = x0 + (t / spanMs) * w;
    s.addShape(pres.ShapeType.rect, {
      x: x - 0.035, y, w: 0.07, h: 0.32,
      fill: { color: C.ink2 }, line: { width: 0 },
    });
  }
  s.addShape(pres.ShapeType.line, {
    x: x0, y: y + 0.16, w: w, h: 0,
    line: { color: C.line, width: 1, dashType: "sysDot" },
  });
}

function lane(s, x0, y, w, spanMs, name, segs, nameW) {
  s.addText(name, {
    x: x0 - (nameW || 2.35) - 0.12, y: y - 0.02, w: nameW || 2.35, h: 0.34,
    fontSize: 10.5, color: C.body, align: "right", fontFace: FB,
    margin: 0, valign: "middle",
  });
  segs.forEach((sg) => {
    const bx = x0 + (sg.t0 / spanMs) * w;
    const bw = Math.max(0.06, (sg.dur / spanMs) * w);
    s.addShape(pres.ShapeType.roundRect, {
      x: bx, y, w: bw, h: 0.32, rectRadius: 0.03,
      fill: { color: sg.color }, line: { color: sg.edge || sg.color, width: 1 },
    });
    if (sg.label && bw > 0.7) {
      s.addText(sg.label, {
        x: bx, y, w: bw, h: 0.32, fontSize: 9, bold: true, color: sg.ink || C.white,
        align: "center", valign: "middle", fontFace: FB, margin: 0,
      });
    }
  });
}

// Vertical guide at a moment in time, across the whole lane stack.
function moment(s, x0, yTop, yBot, w, spanMs, t, label, color) {
  const x = x0 + (t / spanMs) * w;
  s.addShape(pres.ShapeType.line, {
    x, y: yTop, w: 0, h: yBot - yTop,
    line: { color: color || C.bad, width: 1.25, dashType: "dash" },
  });
  if (label) {
    s.addText(label, {
      x: x - 1.0, y: yTop - 0.3, w: 2.0, h: 0.26, fontSize: 9, bold: true,
      color: color || C.bad, align: "center", fontFace: FB, margin: 0,
    });
  }
  return x;
}

// A capture-to-display arrow for ONE row, drawn under the lanes.
function rowArrow(s, x0, y, w, spanMs, tStart, tEnd, text, color) {
  const bx = x0 + (tStart / spanMs) * w;
  const bw = ((tEnd - tStart) / spanMs) * w;
  s.addShape(pres.ShapeType.rightArrow, {
    x: bx, y, w: bw, h: 0.28,
    fill: { color }, line: { color, width: 0 },
  });
  s.addText(text, {
    x: bx, y, w: bw, h: 0.28, fontSize: 9, bold: true, color: C.white,
    align: "center", valign: "middle", fontFace: FB, margin: 0,
  });
}

// Horizontal bar chart of repeat-run counts from the optical measurement.
function runChart(s, x, y, w, h, title, bars, tone) {
  s.addText(title, {
    x, y, w, h: 0.3, fontSize: 12, bold: true, color: C.ink, fontFace: FB, margin: 0,
  });
  const maxV = Math.max(...bars.map((b) => b.v));
  const rowH = (h - 0.42) / bars.length;
  bars.forEach((b, i) => {
    const by = y + 0.4 + i * rowH;
    s.addText(b.k, {
      x, y: by, w: 1.15, h: rowH - 0.06, fontSize: 9.5, color: C.body,
      align: "right", fontFace: FB, margin: 0, valign: "middle",
    });
    const bw = Math.max(0.03, (b.v / maxV) * (w - 1.9));
    s.addShape(pres.ShapeType.rect, {
      x: x + 1.25, y: by + 0.03, w: bw, h: rowH - 0.14,
      fill: { color: b.hot ? C.bad : tone }, line: { color: b.hot ? C.bad : tone, width: 0 },
    });
    s.addText(String(b.v), {
      x: x + 1.3 + bw, y: by, w: 0.6, h: rowH - 0.06, fontSize: 9,
      color: C.muted, fontFace: FB, margin: 0, valign: "middle",
    });
  });
}

function table(s, x, y, w, headers, rows, colW, opts) {
  const o = opts || {};
  const rowH = o.rowH || 0.38;
  let cx = x;
  headers.forEach((hd, i) => {
    s.addText(hd, {
      x: cx, y, w: colW[i], h: 0.34, fontSize: 10.5, bold: true, color: C.muted,
      fontFace: FB, margin: 0, valign: "middle", align: i === 0 ? "left" : (o.align || "center"),
    });
    cx += colW[i];
  });
  s.addShape(pres.ShapeType.line, {
    x, y: y + 0.36, w, h: 0, line: { color: C.line, width: 1 },
  });
  rows.forEach((r, ri) => {
    const ry = y + 0.44 + ri * rowH;
    if (ri % 2 === 1) {
      s.addShape(pres.ShapeType.rect, {
        x: x - 0.08, y: ry - 0.03, w: w + 0.16, h: rowH - 0.02,
        fill: { color: C.panel }, line: { width: 0 },
      });
    }
    let tx = x;
    r.forEach((cell, ci) => {
      const val = typeof cell === "object" ? cell.t : cell;
      const col = typeof cell === "object" ? (cell.c || C.body) : C.body;
      const bold = typeof cell === "object" ? !!cell.b : false;
      s.addText(String(val), {
        x: tx, y: ry, w: colW[ci], h: rowH - 0.04, fontSize: 10.5, color: col,
        bold, fontFace: FB, margin: 0, valign: "middle",
        align: ci === 0 ? "left" : (o.align || "center"),
      });
      tx += colW[ci];
    });
  });
  return y + 0.44 + rows.length * rowH;
}

// ============================================================ 1. title
{
  const s = darkSlide();
  s.addText("Latency and Frame Rate", {
    x: 0.9, y: 2.05, w: 11.5, h: 0.9, fontSize: 46, bold: true,
    color: C.white, fontFace: FH, margin: 0,
  });
  s.addText("Six-camera EO / IR panorama  ·  V19 Milestone 1", {
    x: 0.9, y: 3.0, w: 11.5, h: 0.44, fontSize: 19, color: "9FB4D4",
    fontFace: FB, margin: 0,
  });
  s.addText("Measured three independent ways: the RTL and its simulation, an in-fabric timing probe read over JTAG, and the SDI output captured and analysed frame by frame.",
    { x: 0.9, y: 3.62, w: 10.4, h: 0.7, fontSize: 13.5, color: "7E93B5", fontFace: FB, margin: 0 });

  [["RTL + simulation", C.eo], ["ILA / in-fabric probe", C.warn], ["Optical capture (Python)", C.good]]
    .forEach(([t, col], i) => {
      const x = 0.9 + i * 3.6;
      s.addShape(pres.ShapeType.roundRect, {
        x, y: 5.0, w: 3.3, h: 0.66, rectRadius: 0.08,
        fill: { color: "16294A" }, line: { color: col, width: 1.4 },
      });
      s.addText(t, { x, y: 5.0, w: 3.3, h: 0.66, fontSize: 12.5, bold: true,
        color: C.white, align: "center", valign: "middle", fontFace: FB, margin: 0 });
    });
  s.addText("2026-08-20", { x: 0.9, y: 6.45, w: 4, h: 0.3, fontSize: 11,
    color: "6B7C97", fontFace: FB, margin: 0 });
}

// ============================================================ 2. headline
{
  const s = lightSlide("What the system does today", "Summary");

  statCard(s, 0.6, 1.35, 2.42, "30", "frames/s published\nIR single", C.good);
  statCard(s, 3.12, 1.35, 2.42, "30", "frames/s published\nIR panorama", C.good);
  statCard(s, 5.64, 1.35, 2.42, "30", "frames/s published\nEO single, all six", C.good);
  statCard(s, 8.16, 1.35, 2.42, "22.9", "frames/s published\nEO panorama", C.warn);
  statCard(s, 10.68, 1.35, 2.07, "71 ms", "capture to display\nEO panorama, best", C.ink);

  s.addText("Latency is a fixed number per mode, not a range", {
    x: 0.6, y: 3.05, w: 12.15, h: 0.34, fontSize: 15, bold: true,
    color: C.ink, fontFace: FB, margin: 0 });
  s.addText([
    { text: "Every row of the picture has the SAME capture-to-display latency. ", options: { bold: true } },
    { text: "A row captured early waits longest for its frame to complete, and is then scanned out first; a row captured last waits least and is scanned out last. The two offsets cancel exactly. This is shown on the next slide and is the reason no \"typical\" figure appears anywhere in this deck: there is no spread to average over." },
  ], { x: 0.6, y: 3.42, w: 12.15, h: 0.8, fontSize: 12.5, color: C.body, fontFace: FB, margin: 0 });

  s.addText("Where the remaining work is", {
    x: 0.6, y: 4.35, w: 12.15, h: 0.34, fontSize: 15, bold: true,
    color: C.ink, fontFace: FB, margin: 0 });
  s.addText([
    { text: "Seven of the eight measured configurations publish at the rate their cameras produce. EO panorama publishes 22.9 against a 30 fps source: 78% of its frames arrive on the full 33.3 ms cadence and 22% slip by one or two frame periods. The cause is identified and is not the output stage - see the last two slides." },
  ], { x: 0.6, y: 4.72, w: 12.15, h: 0.8, fontSize: 12.5, color: C.body, fontFace: FB, margin: 0 });

  note(s, "Frame rates: optical measurement, 2026-08-20, three-bank build 00e0c57. Latency: in-fabric timing probe, 2026-08-19, build 67955bc. Both are identified on the basis slide.", 5.72);
}

// ============================================================ 3. concurrency
{
  const s = lightSlide("Why the stages must not be added up", "The key picture");
  s.addText("Capture, render and scan-out overlap. Drawn end to end they read as 105 ms; drawn against one clock they are 71.5 ms.",
    { x: 0.6, y: 1.24, w: 12.15, h: 0.34, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  const X = 3.45, W = 8.9, SPAN = 120, yAx = 2.15;

  timeAxis(s, X, yAx, W, SPAN, 33.333, "milliseconds — one shared clock");

  const L0 = yAx + 0.30, L1 = L0 + 0.44, L2 = L1 + 0.44, L3 = L2 + 0.44, L4 = L3 + 0.44;

  edgeLane(s, X, L0, W, SPAN, 4.9, 33.333, "Display frame edges");
  lane(s, X, L1, W, SPAN, "Camera exposes and transfers", [
    { t0: 0, dur: 33.333, label: "frame N   row 0 first → row 1079 last", color: C.eo },
  ]);
  lane(s, X, L2, W, SPAN, "FPGA aligns, renders, writes", [
    { t0: 33.333, dur: 38.2, label: "align + render into a free bank", color: C.ir },
  ]);
  lane(s, X, L3, W, SPAN, "Published on the next edge", [
    { t0: 71.53, dur: 1.4, label: "", color: C.good },
  ]);
  lane(s, X, L4, W, SPAN, "Display scans the frame out", [
    { t0: 71.53, dur: 33.333, label: "row 0 first → row 1079 last", color: C.good },
  ]);

  moment(s, X, L0 - 0.10, L4 + 0.36, W, SPAN, 33.333, "frame complete", C.ink);
  moment(s, X, L0 - 0.10, L4 + 0.36, W, SPAN, 71.53, "published", C.good);

  const A1 = L4 + 0.58, A2 = A1 + 0.40;
  rowArrow(s, X, A1, W, SPAN, 0,      71.53,  "row 0     →  71.5 ms", C.ink2);
  rowArrow(s, X, A2, W, SPAN, 33.333, 104.86, "row 1079  →  71.5 ms", C.ink2);
  s.addText("same length,\ndifferent start", {
    x: 0.6, y: A1 + 0.04, w: 2.6, h: 0.72, fontSize: 10, bold: true, italic: true,
    color: C.ink2, align: "right", fontFace: FB, margin: 0, valign: "middle" });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: A2 + 0.58, w: 12.15, h: 0.98, rectRadius: 0.06,
    fill: { color: C.goodLite }, line: { color: C.good, width: 1.25 } });
  s.addText([
    { text: "The arithmetic. ", options: { bold: true, color: C.ink } },
    { text: "For row r of N:  age when the frame completes = (1 − r/N) × 33.3,  scan-out position = (r/N) × 33.3.  These sum to 33.3 for every r — the row that waits longest to be captured is displayed first. Total = 33.3 + render-and-publish, identical for every row. Checked over all 1080 rows: spread 0.00 ms." },
  ], { x: 0.85, y: A2 + 0.70, w: 11.6, h: 0.76, fontSize: 12, color: C.body, fontFace: FB, margin: 0, valign: "middle" });

  s.addNotes("Exact for the single-camera modes, where output row r comes from source row r. In the panorama modes the warp lets a source row land within a band of output rows, so the cancellation is approximate - bounded by the row-window span of about 13 source rows, under 0.5 ms.");
}

// ============================================================ 4. latency
{
  const s = lightSlide("Latency: best case and worst case", "Measured");
  s.addText("A finished frame may only be published on a display frame edge. The camera and the display free-run against each other, so the wait for that edge is anywhere from nothing to a full frame period. That is the entire difference between the two columns.",
    { x: 0.6, y: 1.24, w: 12.15, h: 0.5, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  const rows = [
    ["EO single",   "10.1 ms", { t: "43.4 ms", b: true, c: C.good }, { t: "76.8 ms", b: true, c: C.warn }, "49.7 ms"],
    ["EO panorama", "38.2 ms", { t: "71.5 ms", b: true, c: C.good }, { t: "104.9 ms", b: true, c: C.warn }, "74.4 ms"],
    ["IR single",   "25.8 ms", { t: "59.1 ms", b: true, c: C.good }, { t: "92.5 ms", b: true, c: C.warn }, "83.4 ms"],
    ["IR panorama", "41.6 ms", { t: "74.9 ms", b: true, c: C.good }, { t: "108.3 ms", b: true, c: C.warn }, "78.3 ms"],
  ];
  table(s, 0.6, 1.86, 12.15,
    ["Mode", "Frame complete → render done\n(ILA, measured)",
     "BEST CASE\ncapture → display", "WORST CASE\ncapture → display", "One measured sample\n(sits between, as it must)"],
    rows, [2.7, 2.85, 2.2, 2.2, 2.2], { rowH: 0.46 });

  s.addText("Best case = 33.3 ms of fixed capture-and-scan-out geometry + the measured render.   Worst case = that + one 33.3 ms frame period.",
    { x: 0.6, y: 4.22, w: 12.15, h: 0.3, fontSize: 11.5, color: C.muted, fontFace: FB, margin: 0, italic: true });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 4.62, w: 12.15, h: 1.48, rectRadius: 0.06,
    fill: { color: C.warnLite }, line: { color: C.warn, width: 1.25 } });
  s.addText("Why the worst case occurs", {
    x: 0.88, y: 4.72, w: 11.6, h: 0.3, fontSize: 14, bold: true, color: C.ink,
    fontFace: FB, margin: 0 });
  s.addText([
    { text: "The render finishes at some moment inside the display's 33.3 ms cycle, and it cannot choose that moment: its start is locked to the camera, and the camera is not locked to the display. Finish a hair before an edge and the frame goes out immediately — best case. Finish a hair after one and it is held for a whole further period — worst case.", options: { breakLine: true } },
    { text: "This is a continuous drift, not an occasional fault. Over minutes the phase walks through the whole range, so latency wanders between the two columns rather than sitting at either. There is no single \"typical\" value to quote, which is why none is given.", options: { breakLine: true, italic: true, color: C.body } },
    { text: "Shortening the render moves BOTH columns down. Locking the camera exposure to the display raster would collapse the range to one value.", options: { bold: true, color: C.ink } },
  ], { x: 0.88, y: 5.04, w: 11.6, h: 1.0, fontSize: 11, color: C.body, fontFace: FB, margin: 0 });

  note(s, "Camera sensor and ISP delay excluded - vendor specification. The sample column is a single interval read from the probe; every one lands inside its predicted best-to-worst window, which is a check on the model rather than a separate result.", 6.24);
}

// ============================================================ 5. worst case
{
  const s = lightSlide("Best and worst, drawn on the same clock", "Mechanism");
  s.addText("Identical camera, identical render. The only difference is where the display's edge grid happens to fall — which nothing in the system controls.",
    { x: 0.6, y: 1.24, w: 12.15, h: 0.34, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  const X = 3.45, W = 8.9, SPAN = 150;

  // ---- best
  s.addText("BEST CASE — the render lands just before an edge", {
    x: 0.6, y: 1.72, w: 12.15, h: 0.28, fontSize: 12.5, bold: true, color: C.good, fontFace: FB, margin: 0 });
  const yA = 2.14;
  edgeLane(s, X, yA, W, SPAN, 4.9, 33.333, "Display edges");
  lane(s, X, yA + 0.40, W, SPAN, "Camera frame N", [
    { t0: 0, dur: 33.333, label: "", color: C.eo }]);
  lane(s, X, yA + 0.80, W, SPAN, "Align + render", [
    { t0: 33.333, dur: 38.2, label: "38.2 ms", color: C.ir }]);
  lane(s, X, yA + 1.20, W, SPAN, "On screen", [
    { t0: 71.53, dur: 33.333, label: "71.5 ms after capture", color: C.good }]);
  moment(s, X, yA - 0.10, yA + 1.56, W, SPAN, 71.53, "published", C.good);

  // ---- worst
  s.addText("WORST CASE — the same render lands just after one", {
    x: 0.6, y: 4.00, w: 12.15, h: 0.28, fontSize: 12.5, bold: true, color: C.bad, fontFace: FB, margin: 0 });
  const yB = 4.42;
  edgeLane(s, X, yB, W, SPAN, 4.9 + 33.333 - 0.35, 33.333, "Display edges");
  lane(s, X, yB + 0.40, W, SPAN, "Camera frame N", [
    { t0: 0, dur: 33.333, label: "", color: C.eo }]);
  lane(s, X, yB + 0.80, W, SPAN, "Align + render", [
    { t0: 33.333, dur: 38.2, label: "38.2 ms — the same", color: C.ir }]);
  lane(s, X, yB + 1.20, W, SPAN, "Held, then on screen", [
    { t0: 71.53, dur: 33.33, label: "held a whole frame period", color: C.badLite, edge: C.bad, ink: C.bad },
    { t0: 104.86, dur: 33.333, label: "104.9 ms after capture", color: C.warn }]);
  moment(s, X, yB - 0.10, yB + 1.56, W, SPAN, 71.18, "edge missed by 0.35 ms", C.bad);
  moment(s, X, yB - 0.10, yB + 1.56, W, SPAN, 104.86, "next edge", C.warn);

  timeAxis(s, X, yB + 1.94, W, SPAN, 33.333, null);

  note(s, "With the earlier two-bank output framebuffer a missed edge cost more than a late frame: the frame waiting to be published also blocked the NEXT render from starting, so one miss threw away a whole camera frame and the mode settled at half rate. The third output bank removes that blocking - the render behind it now proceeds regardless.", 6.5);
}

// ============================================================ 6. rates
{
  const s = lightSlide("Frame rate, measured off the SDI output", "Optical evidence");
  s.addText("Grab the output at 60 fps, hash each frame, and count how often the picture changes. Repeat runs of 2 mean 30 fps; runs of 4 mean 15.",
    { x: 0.6, y: 1.26, w: 12.15, h: 0.34, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  const rows = [
    ["IR single",        "30", { t: "29.81", b: true, c: C.good }, "2 × 352", { t: "at source rate", c: C.good }],
    ["IR panorama",      "30", { t: "29.97", b: true, c: C.good }, "2 × 359", { t: "at source rate", c: C.good }],
    ["EO single  cam 1", "30", { t: "29.89", b: true, c: C.good }, "2 × 357", { t: "at source rate", c: C.good }],
    ["EO single  cam 2", "30", { t: "29.06", b: true, c: C.good }, "2 × 337,  4 × 11", { t: "at source rate", c: C.good }],
    ["EO single  cam 3", "30", { t: "29.23", b: true, c: C.good }, "2 × 344,  4 × 5", { t: "at source rate", c: C.good }],
    ["EO single  cam 4", "30", { t: "29.56", b: true, c: C.good }, "2 × 349,  4 × 5", { t: "at source rate", c: C.good }],
    ["EO single  cam 5", "30", { t: "29.73", b: true, c: C.good }, "2 × 356,  4 × 2", { t: "at source rate", c: C.good }],
    ["EO single  cam 6", "30", { t: "29.56", b: true, c: C.good }, "2 × 351,  4 × 4", { t: "at source rate", c: C.good }],
    ["EO panorama",      "30", { t: "22.90", b: true, c: C.warn }, "2 × 274,  4 × 55,  6 × 22", { t: "22% of frames slip", c: C.bad, b: true }],
  ];
  table(s, 0.6, 1.72, 12.15,
    ["Mode", "Camera delivers", "New frames/s on screen", "Repeat-run distribution", "Verdict"],
    rows, [2.7, 1.85, 2.35, 3.35, 1.9], { rowH: 0.375 });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.35, w: 12.15, h: 1.15, rectRadius: 0.06,
    fill: { color: C.panel }, line: { color: C.line, width: 1 } });
  s.addText([
    { text: "The instrument was checked before the results were believed. ", options: { bold: true, color: C.ink } },
    { text: "A USB3 capture card can duplicate or drop frames on its own. IR single returns repeat runs of exactly 2 at a 59.9 fps grab, 352 times in a row, so the card resolves 30 distinct frames per second cleanly. Lower resolution and MJPEG change nothing. A duplicate would hash the same and count once; a dropped frame would make this under-count, never over-count." },
  ], { x: 0.88, y: 5.48, w: 11.6, h: 0.9, fontSize: 11.5, color: C.body, fontFace: FB, margin: 0, valign: "middle" });
}

// ============================================================ 7. RTL evidence
{
  const s = lightSlide("Evidence 1 — the RTL", "Where the limit was written");
  s.addText("The output framebuffer held two banks. A finished frame occupied one until it was displayed, and the rule below refused to start another render until then.",
    { x: 0.6, y: 1.26, w: 12.15, h: 0.34, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  s.addText("BEFORE", { x: 0.6, y: 1.76, w: 5.9, h: 0.26, fontSize: 11, bold: true,
    color: C.bad, fontFace: FB, charSpacing: 2, margin: 0 });
  codeBlock(s, 0.6, 2.06, 5.95, 1.55, [
    "wire copy_bank_available =",
    "        !pending_valid &&",
    "        (!frame_valid || (wr_bank != rd_bank));",
    "",
    "// !pending_valid = \"nothing is waiting to be shown\"",
  ], C.bad);

  s.addText("AFTER", { x: 6.85, y: 1.76, w: 5.9, h: 0.26, fontSize: 11, bold: true,
    color: C.good, fontFace: FB, charSpacing: 2, margin: 0 });
  codeBlock(s, 6.85, 2.06, 5.9, 1.55, [
    "wire [2:0] out_bank_busy =",
    "        (1 << rd_bank) |",
    "        (pending_valid ? (1 << pending_bank) : 0);",
    "",
    "// three banks, so a free one always exists",
  ], C.good);

  s.addText("Why that rule cost a whole frame rather than a few milliseconds", {
    x: 0.6, y: 3.78, w: 12.15, h: 0.3, fontSize: 14, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  s.addText([
    { text: "A render cannot be started whenever convenient — its start is locked to the source. For IR panorama the renderer reads the live camera line caches, so it may only begin while the row gate is satisfied:", options: { breakLine: true } },
  ], { x: 0.6, y: 4.12, w: 12.15, h: 0.4, fontSize: 12, color: C.body, fontFace: FB, margin: 0 });

  codeBlock(s, 0.6, 4.56, 7.3, 1.05, [
    "wire row_window_ok = (rows_max <= gate_min_row + 30);",
    "wire row_ready_now = (rows_min >= need_row) && row_window_ok;",
    "// rows 34..64 of 512  ->  1.95 ms, once per 33.3 ms camera frame",
  ]);

  s.addShape(pres.ShapeType.roundRect, {
    x: 8.15, y: 4.56, w: 4.6, h: 1.05, rectRadius: 0.06,
    fill: { color: C.badLite }, line: { color: C.bad, width: 1.25 } });
  s.addText([
    { text: "Miss that 1.95 ms window and the next chance is a full camera frame away. ", options: { bold: true, color: C.ink } },
    { text: "That is how a few milliseconds of commit delay turned into exactly half rate." },
  ], { x: 8.4, y: 4.66, w: 4.1, h: 0.85, fontSize: 10.5, color: C.body, fontFace: FB, margin: 0, valign: "middle" });

  note(s, "src/PanoramaBase_DdrBlackFrame.v and src/IrV19StreamingRenderer.v. The third bank required moving one address region; it was moved by exactly 8100 × 128 addresses so every camera keeps its DRAM bank assignment.", 5.85);
}

// ============================================================ 8. simulation
{
  const s = lightSlide("Evidence 2 — simulation across the phase", "Reproduced, not assumed");
  s.addText("The offset between the camera clock and the display clock is not adjustable on hardware, so it was swept in simulation. Render 26.6 ms against a 33.3 ms frame edge.",
    { x: 0.6, y: 1.26, w: 12.15, h: 0.34, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  const rows = [
    ["0 µs",      { t: "29.85", c: C.good }, "0",   { t: "29.85", c: C.good }, "0"],
    ["4 166 µs",  { t: "30.00", c: C.good }, "0",   { t: "30.00", c: C.good }, "0"],
    ["8 332 µs",  { t: "15.00", b: true, c: C.bad }, { t: "100 of 200", c: C.bad }, { t: "29.85", c: C.good }, "0"],
    ["12 498 µs", { t: "15.00", b: true, c: C.bad }, { t: "100 of 200", c: C.bad }, { t: "29.85", c: C.good }, "0"],
    ["16 664 µs", { t: "15.00", b: true, c: C.bad }, { t: "100 of 200", c: C.bad }, { t: "29.85", c: C.good }, "0"],
    ["20 830 µs", { t: "15.00", b: true, c: C.bad }, { t: "100 of 200", c: C.bad }, { t: "29.85", c: C.good }, "0"],
    ["24 996 µs", { t: "15.00", b: true, c: C.bad }, { t: "100 of 200", c: C.bad }, { t: "29.85", c: C.good }, "0"],
    ["29 162 µs", { t: "15.00", b: true, c: C.bad }, { t: "100 of 200", c: C.bad }, { t: "29.85", c: C.good }, "0"],
  ];
  table(s, 0.6, 1.76, 9.4,
    ["Camera-to-display phase", "TWO banks\nfps", "source frames\nlost", "THREE banks\nfps", "source frames\nlost"],
    rows, [2.7, 1.75, 1.85, 1.75, 1.35], { rowH: 0.4 });

  s.addShape(pres.ShapeType.roundRect, {
    x: 10.25, y: 1.76, w: 2.5, h: 3.6, rectRadius: 0.06,
    fill: { color: C.goodLite }, line: { color: C.good, width: 1.25 } });
  s.addText("6 of 8", { x: 10.4, y: 2.0, w: 2.2, h: 0.6, fontSize: 30, bold: true,
    color: C.bad, align: "center", fontFace: FH, margin: 0 });
  s.addText("phases lose exactly half the source frames with two banks", {
    x: 10.4, y: 2.6, w: 2.2, h: 0.8, fontSize: 11, color: C.body, align: "center",
    fontFace: FB, margin: 0 });
  s.addText("0 of 8", { x: 10.4, y: 3.5, w: 2.2, h: 0.6, fontSize: 30, bold: true,
    color: C.good, align: "center", fontFace: FH, margin: 0 });
  s.addText("lose anything with three banks, and no bank is ever written while displayed",
    { x: 10.4, y: 4.1, w: 2.2, h: 1.1, fontSize: 11, color: C.body, align: "center",
      fontFace: FB, margin: 0 });

  s.addText([
    { text: "The two phases that already worked are the ones where the display edge happens to fall in the narrow gap between the render finishing and the next source window opening. That is the stated mechanism reproducing itself, which is what makes this a demonstration rather than an argument.", options: {} },
  ], { x: 0.6, y: 5.55, w: 9.4, h: 0.7, fontSize: 11.5, color: C.body, fontFace: FB, margin: 0 });

  note(s, "sim/tb_V19OutputBankRate.v. The same testbench asserts on every render start that the chosen bank is neither being displayed nor holding an unshown frame: zero violations across all sixteen configurations.", 6.35);
}

// ============================================================ 9. ILA
{
  const s = lightSlide("Evidence 3 — the in-fabric timing probe", "ILA");
  s.addText("An ILA window is 8.8 µs and carries no timestamps, so a 33 ms interval cannot be recovered from a capture however it is triggered. The intervals are therefore measured in the FPGA and only the results are read out.",
    { x: 0.6, y: 1.26, w: 12.15, h: 0.5, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  codeBlock(s, 0.6, 1.92, 6.1, 1.95, [
    "V19TimingProbe  u_v19_timing (",
    "    .in_frame_ev  (camera frame available),",
    "    .copy_start_ev(render begins),",
    "    .copy_done_ev (render complete),",
    "    .commit_ev    (published to the display),",
    "    .out_edge_ev  (output raster boundary));",
    "",
    "// tick = ui_clk / 64 = 274.2 ns, 24 bits = 4.6 s",
  ]);

  s.addText("Measured intervals", { x: 7.0, y: 1.92, w: 5.75, h: 0.3, fontSize: 13,
    bold: true, color: C.ink, fontFace: FB, margin: 0 });
  table(s, 7.0, 2.24, 5.75,
    ["Mode", "frame → render done", "frame → on screen"],
    [
      ["EO single",   "10.1 ms", { t: "16.4 ms", b: true }],
      ["EO panorama", "38.2 ms", { t: "41.1 ms", b: true }],
      ["IR single",   "25.8 ms", { t: "50.1 ms", b: true }],
      ["IR panorama", "41.6 ms", { t: "45.0 ms", b: true }],
    ], [2.05, 1.9, 1.8], { rowH: 0.36 });

  s.addText("Two ways this measurement lied before it was trusted", {
    x: 0.6, y: 4.15, w: 12.15, h: 0.3, fontSize: 14, bold: true, color: C.ink, fontFace: FB, margin: 0 });

  const traps = [
    ["A capture triggered on activity cannot see idleness",
     "Arming the ILA on \"render active\" reported the render occupying 84% of every frame. Sampling with no trigger condition at all gave 25-40%. Every duty figure in this deck is from an untriggered capture."],
    ["An interval register reports the LAST interval, not a rate",
     "A pipeline that has stopped keeps reporting whatever it last managed - one stalled mode read as a healthy 33.3 ms while publishing nothing. Rates here are counted over a wall-clock gap, or measured optically, never read from an interval."],
  ];
  traps.forEach(([t, d], i) => {
    const x = 0.6 + i * 6.25;
    s.addShape(pres.ShapeType.roundRect, { x, y: 4.5, w: 5.9, h: 1.5, rectRadius: 0.06,
      fill: { color: C.warnLite }, line: { color: C.warn, width: 1.25 } });
    s.addText(t, { x: x + 0.22, y: 4.62, w: 5.5, h: 0.5, fontSize: 11.5, bold: true,
      color: C.ink, fontFace: FB, margin: 0 });
    s.addText(d, { x: x + 0.22, y: 5.1, w: 5.5, h: 0.82, fontSize: 10.5,
      color: C.body, fontFace: FB, margin: 0 });
  });

  note(s, "src/V19TimingProbe.v, calibrated against known intervals in sim/tb_V19TimingProbe.v — 10 of 10 checks pass. Captures via scripts/capture_v19_untriggered.tcl.", 6.2);
}

// ============================================================ 10. optical
{
  const s = lightSlide("Evidence 4 — the output, analysed frame by frame", "Python / optical");
  s.addText("The FPGA counter says a frame was published. Only this says the picture actually changed — and on one occasion the two disagreed, correctly.",
    { x: 0.6, y: 1.26, w: 12.15, h: 0.34, fontSize: 13, color: C.body, fontFace: FB, margin: 0 });

  codeBlock(s, 0.6, 1.78, 6.0, 1.75, [
    "cap.set(cv2.CAP_PROP_FOURCC, YUY2)   # 1920x1080",
    "h = blake2b(frame.tobytes()).digest()",
    "#  two reads of one output frame are bit-identical",
    "#  two different frames differ by sensor noise alone",
    "#  (~1.35 LSB/px over 2.07 M px) - no threshold,",
    "#  no moving target needed",
  ]);
  s.addText("scripts/measure_output_rate.py", { x: 0.6, y: 3.56, w: 6.0, h: 0.24,
    fontSize: 9.5, color: C.muted, fontFace: FM, margin: 0 });

  runChart(s, 6.95, 1.78, 2.85, 1.95, "EO panorama — two banks",
    [{ k: "33 ms", v: 188 }, { k: "67 ms", v: 55, hot: true },
     { k: "100 ms", v: 37, hot: true }, { k: "133 ms", v: 7, hot: true },
     { k: "200 ms", v: 1, hot: true }], C.eo);

  runChart(s, 10.0, 1.78, 2.85, 1.95, "EO panorama — three banks",
    [{ k: "33 ms", v: 274 }, { k: "67 ms", v: 55, hot: true },
     { k: "100 ms", v: 22, hot: true }, { k: "133 ms", v: 0 },
     { k: "200 ms", v: 0 }], C.good);

  s.addText("How long each frame stayed on screen. The long stalls disappear; most frames move to the full 33 ms cadence.",
    { x: 6.95, y: 3.78, w: 5.9, h: 0.4, fontSize: 10, color: C.muted, fontFace: FB, margin: 0, italic: true });

  s.addText("What the third output bank changed", {
    x: 0.6, y: 4.3, w: 12.15, h: 0.3, fontSize: 14, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  table(s, 0.6, 4.62, 12.15,
    ["", "Two banks", "Three banks", "Change"],
    [
      ["EO panorama (main branch)",  "17.7 fps", { t: "22.3 fps", b: true, c: C.good }, { t: "+26%", b: true, c: C.good }],
      ["EO panorama (IR-DDR branch)", "19.7 fps", { t: "22.9 fps", b: true, c: C.good }, { t: "+16%", b: true, c: C.good }],
      ["EO single, IR single, IR panorama", "30 fps", { t: "30 fps", c: C.body }, "unchanged"],
    ], [4.6, 2.5, 2.5, 2.55], { rowH: 0.38 });

  note(s, "Three runs per side, alternating bitstreams on the same board minutes apart. The unchanged row is the control: whatever was already at source rate stayed there.", 6.15);
}

// ============================================================ 11. remaining
{
  const s = lightSlide("EO panorama: the one mode still short", "Remaining work");

  statCard(s, 0.6, 1.3, 2.7, "22.9", "published now", C.warn);
  statCard(s, 3.4, 1.3, 2.7, "30", "cameras deliver", C.good);
  statCard(s, 6.2, 1.3, 2.7, "78%", "frames on the full\n33 ms cadence", C.good);
  statCard(s, 9.0, 1.3, 3.75, "22%", "slip by one or two frame periods", C.bad);

  s.addText("It is not the output stage, and it is not the cameras", {
    x: 0.6, y: 2.95, w: 12.15, h: 0.3, fontSize: 15, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  s.addText([
    { text: "Switching the EO cameras from triggered to free-running changed the rate by 0.5 fps — within the run-to-run spread. That removes the shared exposure trigger entirely, so the limit is internal. And the profile is not a mode stuck at half rate; it is a mode that mostly keeps up and intermittently misses.", options: {} },
  ], { x: 0.6, y: 3.3, w: 12.15, h: 0.6, fontSize: 12.5, color: C.body, fontFace: FB, margin: 0 });

  s.addText("The mechanism, and the fix", {
    x: 0.6, y: 4.0, w: 12.15, h: 0.3, fontSize: 15, bold: true, color: C.ink, fontFace: FB, margin: 0 });

  const X = 3.6, W = 8.8, SPAN = 80, yL = 4.55;
  lane(s, X, yL, W, SPAN, "Render frame N", [
    { t0: 0, dur: 24.9, label: "24.9 ms", color: C.ir }], 2.9);
  lane(s, X, yL + 0.42, W, SPAN, "Manager releases, then searches", [
    { t0: 24.9, dur: 10.5, label: "serialised — starts only when the render ends", color: C.badLite, edge: C.bad, ink: C.bad }], 2.9);
  lane(s, X, yL + 0.84, W, SPAN, "Render frame N+1", [
    { t0: 35.4, dur: 24.9, label: "starts late", color: C.warn }], 2.9);
  moment(s, X, yL - 0.12, yL + 1.2, W, SPAN, 33.333, "edge", C.muted);
  timeAxis(s, X, yL + 1.3, W, SPAN, 20, "milliseconds");

  s.addText([
    { text: "An EO panorama render needs a matched frame from all six cameras. The frame-set manager holds that set until the render completes, then walks four bank slots with a handshake to each camera before it can look for the next matched set. None of it overlaps the render. Acquiring the next set while the current render is still running is the targeted fix.", options: {} },
  ], { x: 0.6, y: 6.35, w: 12.15, h: 0.7, fontSize: 11.5, color: C.body, fontFace: FB, margin: 0 });
}

// ============================================================ 12. basis
{
  const s = lightSlide("Basis of every figure", "Provenance");

  const cols = [
    ["Measured on hardware", C.good, [
      "Frame rates: SDI output grabbed at 60 fps, distinct frames counted by exact hash. 2026-08-20, build 00e0c57.",
      "Render and publish latency: in-fabric probe on a ui_clk/64 tick, read over JTAG. 2026-08-19, build 67955bc.",
      "How often the worst case occurs: counted from the on-screen dwell distribution, same optical capture.",
    ]],
    ["Design constants", C.eo, [
      "Output raster 1920x1080p30 - one frame period is 33.333 ms.",
      "Capture-plus-scan-out geometry sums to exactly one frame period for every row; verified over all 1080 rows, spread 0.00 ms.",
      "Render start windows read from the RTL: 1.95 ms per camera frame for IR panorama, matched six-camera set for EO panorama.",
    ]],
    ["Limits and exclusions", C.warn, [
      "Camera sensor and ISP delay excluded throughout - vendor specification.",
      "Latency and frame rate come from different builds and different days; each is labelled. The three-bank change improves EO panorama's rate and was not re-measured for latency.",
      "Row cancellation is exact for the single-camera modes and approximate for the panoramas, bounded by the row-window span (under 0.5 ms).",
    ]],
  ];
  cols.forEach(([title, col, lines], i) => {
    const x = 0.6 + i * 4.13;
    s.addShape(pres.ShapeType.roundRect, { x, y: 1.5, w: 3.88, h: 3.9, rectRadius: 0.06,
      fill: { color: C.white }, line: { color: col, width: 1.5 } });
    s.addShape(pres.ShapeType.ellipse, { x: x + 0.28, y: 1.76, w: 0.32, h: 0.32,
      fill: { color: col }, line: { width: 0 } });
    s.addText(title, { x: x + 0.72, y: 1.74, w: 3.0, h: 0.36, fontSize: 13, bold: true,
      color: C.ink, fontFace: FB, margin: 0, valign: "middle" });
    s.addText(lines.map((t, j) => ({ text: t, options: { bullet: true, breakLine: j < lines.length - 1 } })),
      { x: x + 0.3, y: 2.24, w: 3.3, h: 3.0, fontSize: 10.5, color: C.body,
        fontFace: FB, margin: 0, paraSpaceAfter: 9, valign: "top" });
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.6, w: 12.15, h: 0.95, rectRadius: 0.06,
    fill: { color: C.panel }, line: { color: C.line, width: 1 } });
  s.addText([
    { text: "Not claimed: a certified sensor-to-display figure. ", options: { bold: true, color: C.ink } },
    { text: "Everything here is bounded by what can be observed at the camera interface and at the SDI output. An end-to-end number would need an external optical reference - a pulsed source into the lens and a photodiode on the display - which has not been run." },
  ], { x: 0.88, y: 5.74, w: 11.6, h: 0.7, fontSize: 11.5, color: C.body, fontFace: FB, margin: 0, valign: "middle" });
}

pres.writeFile({ fileName: "EO_IR_Panorama_Latency_Analysis.pptx" })
  .then((f) => console.log("wrote " + f));
