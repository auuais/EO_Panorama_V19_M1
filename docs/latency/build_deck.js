// Customer-facing latency analysis deck for the six-camera EO/IR panorama.
//
// Every number here is either a design constant read out of the RTL/assets, a
// measurement taken on the board, or an explicitly-labelled assumption.  The
// basis slide at the end says which is which; keep it truthful if you edit.

const pptxgen = require("pptxgenjs");

const C = {
  ink:      "0E1C36",   // deep navy, dark backgrounds
  ink2:     "16233A",
  body:     "27374F",
  muted:    "6B7C97",
  paper:    "FFFFFF",
  panel:    "F2F5FA",
  line:     "D3DCEA",
  eo:       "1C7293",   // EO = visible, cool teal
  eoLite:   "DCEAF0",
  ir:       "C1663A",   // IR = thermal, warm
  irLite:   "F6E7DE",
  good:     "02A37A",
  goodLite: "DAF2EB",
  warn:     "C2A33B",
  white:    "FFFFFF",
};

const FH = "Cambria";   // headers
const FB = "Calibri";   // body

const W = 13.333, H = 7.5;
const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE";
pres.author = "EO/IR Panorama V19";
pres.title = "Latency Analysis";

// ---------------------------------------------------------------- helpers

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
      x: 0.6, y: 0.36, w: 9, h: 0.26, fontSize: 11, bold: true,
      color: C.muted, fontFace: FB, charSpacing: 2, margin: 0,
    });
  }
  s.addText(title, {
    x: 0.6, y: kicker ? 0.62 : 0.45, w: 12.1, h: 0.62,
    fontSize: 32, bold: true, color: C.ink, fontFace: FH, margin: 0,
  });
  return s;
}

// A horizontal pipeline: array of {n, label, sub, ms, tone}
// tone: "src" | "proc" | "out" | "skip"
function pipeline(slide, stages, x0, y0, totalW, boxH) {
  const gap = 0.26;
  const n = stages.length;
  const bw = (totalW - gap * (n - 1)) / n;
  stages.forEach((st, i) => {
    const x = x0 + i * (bw + gap);
    const fill = st.tone === "skip" ? C.panel
               : st.tone === "src" ? C.eoLite
               : st.tone === "out" ? C.goodLite : C.irLite;
    const edge = st.tone === "skip" ? C.line
               : st.tone === "src" ? C.eo
               : st.tone === "out" ? C.good : C.ir;
    slide.addShape(pres.ShapeType.roundRect, {
      x, y: y0, w: bw, h: boxH, rectRadius: 0.08,
      fill: { color: fill }, line: { color: edge, width: 1.25 },
    });
    slide.addShape(pres.ShapeType.ellipse, {
      x: x + 0.12, y: y0 + 0.12, w: 0.3, h: 0.3,
      fill: { color: edge }, line: { color: edge, width: 0 },
    });
    slide.addText(String(st.n), {
      x: x + 0.12, y: y0 + 0.12, w: 0.3, h: 0.3, fontSize: 11, bold: true,
      color: C.white, align: "center", valign: "middle", fontFace: FB, margin: 0,
    });
    slide.addText(st.label, {
      x: x + 0.5, y: y0 + 0.11, w: bw - 0.62, h: 0.34,
      fontSize: 12.5, bold: true, color: C.ink, fontFace: FB, margin: 0, valign: "middle",
    });
    slide.addText(st.sub, {
      x: x + 0.14, y: y0 + 0.5, w: bw - 0.28, h: boxH - 0.95,
      fontSize: 10, color: C.body, fontFace: FB, margin: 0, valign: "top",
    });
    slide.addText(st.ms, {
      x: x + 0.14, y: y0 + boxH - 0.42, w: bw - 0.28, h: 0.3,
      fontSize: 12, bold: true, color: edge, fontFace: FB, margin: 0,
    });
    if (i < n - 1) {
      slide.addShape(pres.ShapeType.rightArrow, {
        x: x + bw + 0.03, y: y0 + boxH / 2 - 0.09, w: gap - 0.06, h: 0.18,
        fill: { color: C.line }, line: { color: C.line, width: 0 },
      });
    }
  });
  return y0 + boxH;
}

// Proportional time bar. segs: [{label, ms, color}]
function timebar(slide, segs, x0, y0, totalW, scaleMs, caption) {
  let x = x0;
  segs.forEach((sg) => {
    const w = Math.max(0.14, (sg.ms / scaleMs) * totalW);
    slide.addShape(pres.ShapeType.rect, {
      x, y: y0, w, h: 0.4,
      fill: { color: sg.color }, line: { color: C.white, width: 1 },
    });
    if (w > 0.62) {
      slide.addText(sg.label, {
        x, y: y0, w, h: 0.4, fontSize: 9.5, bold: true, color: C.white,
        align: "center", valign: "middle", fontFace: FB, margin: 0,
      });
    }
    x += w;
  });
  if (caption) {
    slide.addText(caption, {
      x: x0, y: y0 + 0.46, w: totalW, h: 0.26,
      fontSize: 10, color: C.muted, fontFace: FB, margin: 0, italic: true,
    });
  }
  return x;
}

function statCard(slide, x, y, w, big, label, tone) {
  slide.addShape(pres.ShapeType.roundRect, {
    x, y, w, h: 1.5, rectRadius: 0.06,
    fill: { color: C.panel }, line: { color: C.line, width: 1 },
  });
  // Size to the string: at 34pt "133 ms" wraps in a 1.62" card and lands on
  // top of its own label.
  const fs = big.length <= 4 ? 34 : big.length <= 6 ? 25 : 21;
  slide.addText(big, {
    x: x + 0.06, y: y + 0.16, w: w - 0.12, h: 0.72, fontSize: fs, bold: true,
    color: tone || C.ink, align: "center", fontFace: FH, margin: 0, valign: "middle",
  });
  slide.addText(label, {
    x: x + 0.12, y: y + 0.92, w: w - 0.24, h: 0.48, fontSize: 10.5,
    color: C.body, align: "center", fontFace: FB, margin: 0, valign: "top",
  });
}

// ---------------------------------------------------------------- 1 title
{
  const s = darkSlide();
  s.addText("Latency Analysis", {
    x: 0.9, y: 2.25, w: 11.5, h: 0.95, fontSize: 48, bold: true,
    color: C.white, fontFace: FH, margin: 0,
  });
  s.addText("Six-camera EO / IR panorama  ·  V19 Milestone 1", {
    x: 0.9, y: 3.25, w: 11.5, h: 0.44, fontSize: 19, color: "9FB4D4",
    fontFace: FB, margin: 0,
  });
  s.addText("End-to-end timing for all four display modes, with the pipeline stage that sets each one.",
    { x: 0.9, y: 3.9, w: 9.6, h: 0.5, fontSize: 13, color: "7E93B5", fontFace: FB, margin: 0 });

  [["EO single", C.eo], ["EO panorama", C.eo], ["IR single", C.ir], ["IR panorama", C.ir]]
    .forEach(([t, col], i) => {
      const x = 0.9 + i * 2.62;
      s.addShape(pres.ShapeType.roundRect, {
        x, y: 5.15, w: 2.35, h: 0.62, rectRadius: 0.08,
        fill: { color: "16294A" }, line: { color: col, width: 1.25 },
      });
      s.addText(t, { x, y: 5.15, w: 2.35, h: 0.62, fontSize: 13, bold: true,
        color: C.white, align: "center", valign: "middle", fontFace: FB, margin: 0 });
    });
  s.addText("2026-08-19", { x: 0.9, y: 6.5, w: 4, h: 0.3, fontSize: 11,
    color: "6B82A8", fontFace: FB, margin: 0 });
  s.addNotes("All four modes share one output stage. The differences are entirely in how each mode gets a finished frame into the output framebuffer.");
}

// ---------------------------------------------------------------- 2 method
{
  const s = lightSlide("What we mean by latency", "Method");
  s.addText([
    { text: "The number quoted is glass-to-glass inside the FPGA: ", options: { bold: true } },
    { text: "from the moment a camera has delivered an image row, to the moment that row leaves the HD-SDI output." },
  ], { x: 0.6, y: 1.5, w: 6.5, h: 0.75, fontSize: 14, color: C.body, fontFace: FB, margin: 0 });

  s.addText([
    { text: "Camera sensor integration and ISP delay sit in front of this and are the camera vendor's specification, not ours. ", options: { breakLine: true } },
    { text: "Add them to every figure in this deck for a true sensor-to-display number." },
  ], { x: 0.6, y: 2.35, w: 6.5, h: 0.8, fontSize: 13, color: C.muted, fontFace: FB, margin: 0, italic: true });

  s.addText("Every mode is built from the same five stages", {
    x: 0.6, y: 3.35, w: 6.5, h: 0.34, fontSize: 15, bold: true, color: C.ink, fontFace: FB, margin: 0 });

  const rows = [
    ["1", "Ingest", "Camera rows arrive and are stored"],
    ["2", "Align", "Wait until all contributing cameras agree on one moment in time"],
    ["3", "Render", "Warp, blend and write the finished output frame"],
    ["4", "Commit", "Publish that frame at the next output frame boundary"],
    ["5", "Scan-out", "Transmit the row at its position in the raster"],
  ];
  rows.forEach(([n, t, d], i) => {
    const y = 3.82 + i * 0.53;
    s.addShape(pres.ShapeType.ellipse, { x: 0.62, y: y + 0.04, w: 0.28, h: 0.28,
      fill: { color: C.ink }, line: { color: C.ink, width: 0 } });
    s.addText(n, { x: 0.62, y: y + 0.04, w: 0.28, h: 0.28, fontSize: 10.5, bold: true,
      color: C.white, align: "center", valign: "middle", fontFace: FB, margin: 0 });
    s.addText([{ text: t + "  ", options: { bold: true, color: C.ink } },
               { text: d, options: { color: C.body } }],
      { x: 1.03, y: y, w: 6.1, h: 0.38, fontSize: 12, fontFace: FB, margin: 0, valign: "middle" });
  });

  // constants panel
  s.addShape(pres.ShapeType.roundRect, { x: 7.55, y: 1.45, w: 5.2, h: 4.95, rectRadius: 0.08,
    fill: { color: C.panel }, line: { color: C.line, width: 1 } });
  s.addText("System timing constants", { x: 7.85, y: 1.68, w: 4.6, h: 0.34,
    fontSize: 14, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  const consts = [
    ["Output raster", "1920x1080p30 HD-SDI"],
    ["Output frame period", "33.33 ms  (2200x1125 @ 74.25 MHz)"],
    ["EO cameras", "6 x 1920x1080 @ 30 Hz, free-running"],
    ["IR cameras", "6 x 640x512 @ 30 Hz, FPGA-genlocked"],
    ["Measured IR genlock skew", "under 274 ns across all six"],
    ["DDR user clock", "233.4 MHz"],
  ];
  consts.forEach(([k, v], i) => {
    const y = 2.15 + i * 0.7;
    s.addText(k, { x: 7.85, y, w: 4.6, h: 0.26, fontSize: 10.5, bold: true,
      color: C.muted, fontFace: FB, margin: 0 });
    s.addText(v, { x: 7.85, y: y + 0.24, w: 4.6, h: 0.3, fontSize: 12.5,
      color: C.ink, fontFace: FB, margin: 0 });
  });
  s.addNotes("The five-stage model is what makes the four modes comparable. Stages 4 and 5 are identical everywhere; only stages 1-3 differ.");
}

// ---------------------------------------------------------------- 3 backbone
{
  const s = lightSlide("The shared output stage", "Architecture");
  s.addText("Whatever produces the picture, it lands in the same place: a double-buffered output frame store that is published on an output frame boundary and then transmitted.",
    { x: 0.6, y: 1.42, w: 12.1, h: 0.5, fontSize: 13.5, color: C.body, fontFace: FB, margin: 0 });

  pipeline(s, [
    { n: 1, label: "Camera ingest", sub: "Six EO or six IR sensors deliver rows continuously", ms: "mode-dependent", tone: "src" },
    { n: 2, label: "Alignment", sub: "Select one coherent instant across the contributing cameras", ms: "mode-dependent", tone: "src" },
    { n: 3, label: "Render", sub: "Geometric warp, seam blending, fold to the output raster", ms: "mode-dependent", tone: "proc" },
    { n: 4, label: "Commit", sub: "Finished frame published at the next output frame edge", ms: "0 - 33.3 ms", tone: "out" },
    { n: 5, label: "Scan-out", sub: "Row transmitted at its position in the HD-SDI raster", ms: "0 - 33.3 ms", tone: "out" },
  ], 0.6, 2.15, 12.1, 1.85);

  s.addShape(pres.ShapeType.roundRect, { x: 0.6, y: 4.42, w: 12.1, h: 1.0, rectRadius: 0.06,
    fill: { color: C.goodLite }, line: { color: C.good, width: 1 } });
  s.addText([
    { text: "Stages 4 and 5 are common to every mode and together contribute 33.3 ms on average. ", options: { bold: true, color: C.ink } },
    { text: "They are set by the output standard, not by the processing, so they are the floor: no mode can be faster than this without changing the output format." },
  ], { x: 0.9, y: 4.6, w: 11.5, h: 0.68, fontSize: 13, color: C.body, fontFace: FB, margin: 0, valign: "middle" });

  s.addText("Everything that separates the four modes happens in stages 1 to 3.",
    { x: 0.6, y: 5.7, w: 12.1, h: 0.4, fontSize: 14, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  s.addNotes("The commit-plus-scan tail is a property of driving a 30 Hz raster from a frame store. It averages half a frame of commit wait plus half a frame of scan position.");
}

// ---------------------------------------------------------------- mode slides
function modeSlide(cfg) {
  const s = lightSlide(cfg.title, cfg.kicker);
  s.addText(cfg.blurb, { x: 0.6, y: 1.42, w: 12.1, h: 0.46, fontSize: 13.5,
    color: C.body, fontFace: FB, margin: 0 });

  pipeline(s, cfg.stages, 0.6, 2.05, 12.1, 1.8);

  s.addText("Time budget", { x: 0.6, y: 4.12, w: 4, h: 0.3, fontSize: 13, bold: true,
    color: C.ink, fontFace: FB, margin: 0 });
  timebar(s, cfg.segs, 0.6, 4.5, 8.5, cfg.scale, cfg.caption);

  statCard(s, 9.4, 4.12, 1.62, cfg.best, "best case", C.good);
  statCard(s, 11.16, 4.12, 1.62, cfg.worst, "worst case", C.ir);
  s.addShape(pres.ShapeType.roundRect, { x: 9.4, y: 5.78, w: 3.38, h: 0.86, rectRadius: 0.06,
    fill: { color: C.ink }, line: { color: C.ink, width: 0 } });
  s.addText([{ text: cfg.typ + "  ", options: { fontSize: 22, bold: true, color: C.white, fontFace: FH } },
             { text: "typical", options: { fontSize: 12, color: "9FB4D4" } }],
    { x: 9.4, y: 5.78, w: 3.38, h: 0.86, align: "center", valign: "middle", fontFace: FB, margin: 0 });

  s.addShape(pres.ShapeType.roundRect, { x: 0.6, y: 5.42, w: 8.5, h: 1.22, rectRadius: 0.06,
    fill: { color: cfg.noteTone || C.panel }, line: { color: cfg.noteEdge || C.line, width: 1 } });
  s.addText([{ text: cfg.noteTitle + "  ", options: { bold: true, color: C.ink } },
             { text: cfg.note, options: { color: C.body } }],
    { x: 0.88, y: 5.6, w: 7.95, h: 0.9, fontSize: 12, fontFace: FB, margin: 0, valign: "middle" });
  if (cfg.notes) s.addNotes(cfg.notes);
  return s;
}

const TAIL = [
  { label: "Commit", ms: 16.7, color: C.good },
  { label: "Scan", ms: 16.7, color: "6FC2AA" },
];

// -- EO single
modeSlide({
  kicker: "Mode 0x07 - 0x0C",
  title: "EO single camera",
  blurb: "One of the six EO cameras, taken from its stored frame and presented full-raster.",
  stages: [
    { n: 1, label: "Ingest", sub: "Selected camera's full 1920x1080 frame is written to memory as it arrives", ms: "33.3 ms", tone: "src" },
    { n: 2, label: "Align", sub: "Not required - only one camera contributes", ms: "none", tone: "skip" },
    { n: 3, label: "Render", sub: "Frame read back and copied to the output frame store", ms: "33.3 ms", tone: "proc" },
    { n: 4, label: "Commit", sub: "Published at the next output frame edge", ms: "0 - 33.3 ms", tone: "out" },
    { n: 5, label: "Scan-out", sub: "Transmitted in the HD-SDI raster", ms: "0 - 33.3 ms", tone: "out" },
  ],
  segs: [{ label: "Ingest 33.3", ms: 33.3, color: C.eo },
         { label: "Render 33.3", ms: 33.3, color: C.ir }, ...TAIL],
  scale: 150,
  caption: "Bars are proportional. Commit and scan shown at their average of 16.7 ms each.",
  best: "67 ms", worst: "133 ms", typ: "100 ms",
  noteTitle: "What sets it:",
  note: "the store-and-forward round trip. The frame is fully written before any of it is read back, so ingest and render cannot overlap.",
  notes: "EO single reads back one camera's stored frame. It shares the capture path with the panorama, which is why it behaves like the panorama minus the alignment stage.",
});

// -- EO panorama
modeSlide({
  kicker: "Mode 0x15",
  title: "EO panorama",
  blurb: "All six EO cameras stitched into one wide panorama, folded into the HD output raster.",
  stages: [
    { n: 1, label: "Ingest", sub: "All six cameras write their frames to memory concurrently", ms: "33.3 ms", tone: "src" },
    { n: 2, label: "Align", sub: "Wait for a set of six frames that share one exposure instant", ms: "0 - 33.3 ms", tone: "src" },
    { n: 3, label: "Render", sub: "Six frames read back, warped, seam-blended and folded", ms: "33.3 ms", tone: "proc" },
    { n: 4, label: "Commit", sub: "Published at the next output frame edge", ms: "0 - 33.3 ms", tone: "out" },
    { n: 5, label: "Scan-out", sub: "Transmitted in the HD-SDI raster", ms: "0 - 33.3 ms", tone: "out" },
  ],
  segs: [{ label: "Ingest 33.3", ms: 33.3, color: C.eo },
         { label: "Align 16.7", ms: 16.7, color: "5C9BB5" },
         { label: "Render 33.3", ms: 33.3, color: C.ir }, ...TAIL],
  scale: 150,
  caption: "Alignment shown at its average. It is zero when the cameras happen to be in phase and a full frame when they are not.",
  best: "67 ms", worst: "167 ms", typ: "117 ms",
  noteTitle: "What sets it:",
  note: "the EO cameras cannot be genlocked - the vendor confirmed their BT.1120 output is free-running - so the system must wait for six independently-timed frames to line up.",
  notes: "The alignment stage exists purely because the EO cameras are free-running. It is the single largest difference between EO panorama and IR panorama.",
});

// -- IR single
modeSlide({
  kicker: "Modes 0x00 - 0x05, 0x0D - 0x12",
  title: "IR single camera",
  blurb: "One of the six IR cameras, held in on-chip memory and scaled into the output raster.",
  stages: [
    { n: 1, label: "Ingest", sub: "Selected camera's 640x512 frame written to on-chip memory", ms: "33.3 ms", tone: "src" },
    { n: 2, label: "Align", sub: "Not required - only one camera contributes", ms: "none", tone: "skip" },
    { n: 3, label: "Render", sub: "Read from on-chip memory into the output frame store", ms: "33.3 ms", tone: "proc" },
    { n: 4, label: "Commit", sub: "Published at the next output frame edge", ms: "0 - 33.3 ms", tone: "out" },
    { n: 5, label: "Scan-out", sub: "Transmitted in the HD-SDI raster", ms: "0 - 33.3 ms", tone: "out" },
  ],
  segs: [{ label: "Ingest 33.3", ms: 33.3, color: C.ir },
         { label: "Render 33.3", ms: 33.3, color: "D18E68" }, ...TAIL],
  scale: 150,
  caption: "IR frames are small enough to hold on-chip, so this path never touches external memory.",
  best: "67 ms", worst: "133 ms", typ: "100 ms",
  noteTitle: "What sets it:",
  note: "the same store-and-forward structure as EO single. The frame store is on-chip rather than external, which removes a bandwidth risk but not a frame of latency.",
  notes: "Keeping the IR frame on-chip was a capacity decision, not a latency one - it does not shorten the pipeline.",
});

// -- IR panorama
modeSlide({
  kicker: "Mode 0x14",
  title: "IR panorama - direct ingress",
  blurb: "All six IR cameras stitched live, with rendering overlapped onto the arriving rows instead of waiting for whole frames.",
  stages: [
    { n: 1, label: "Ingest", sub: "Rows feed rolling line buffers; rendering starts after 35 rows", ms: "2.3 ms", tone: "src" },
    { n: 2, label: "Align", sub: "Not required - the six IR cameras are genlocked by the FPGA", ms: "none", tone: "skip" },
    { n: 3, label: "Render", sub: "Warp, blend and fold, paced by the incoming rows", ms: "33.3 ms", tone: "proc" },
    { n: 4, label: "Commit", sub: "Published at the next output frame edge", ms: "0 - 33.3 ms", tone: "out" },
    { n: 5, label: "Scan-out", sub: "Transmitted in the HD-SDI raster", ms: "0 - 33.3 ms", tone: "out" },
  ],
  segs: [{ label: "2.3", ms: 2.3, color: C.ir },
         { label: "Render 33.3  -  overlapped with ingest", ms: 33.3, color: "D18E68" }, ...TAIL],
  scale: 150,
  caption: "Rendering runs concurrently with ingest rather than after it - this is where the saving comes from.",
  best: "36 ms", worst: "102 ms", typ: "69 ms",
  noteTone: C.goodLite, noteEdge: C.good,
  noteTitle: "A full frame faster.",
  note: "Genlocking removes the alignment wait, and starting the render 35 source rows in removes the store-and-forward frame. This is the architecture the other modes would adopt to close the gap.",
  notes: "35 rows is a property of the panorama geometry: producing the first output row needs source rows up to 34. Read directly from the generated row-window table.",
});

// ---------------------------------------------------------------- comparison
{
  const s = lightSlide("All four modes side by side", "Comparison");
  s.addText("Figures are FPGA-internal. Camera sensor and ISP delay is additional and is the camera vendor's specification.",
    { x: 0.6, y: 1.42, w: 12.1, h: 0.36, fontSize: 12.5, color: C.muted, fontFace: FB, margin: 0, italic: true });

  s.addChart(pres.ChartType.bar, [
    { name: "Typical latency (ms)",
      labels: ["IR panorama", "IR single", "EO single", "EO panorama"],
      values: [69, 100, 100, 117] },
  ], {
    x: 0.6, y: 1.95, w: 7.0, h: 3.5,
    barDir: "bar", showTitle: false, showLegend: false,
    chartColors: [C.ir, "D18E68", C.eo, "5C9BB5"],
    showValue: true, dataLabelPosition: "outEnd", dataLabelColor: C.ink,
    dataLabelFontSize: 12, dataLabelFontFace: FB,
    catAxisLabelColor: C.body, catAxisLabelFontSize: 12, catAxisLabelFontFace: FB,
    valAxisLabelColor: C.muted, valAxisLabelFontSize: 10, valAxisLabelFontFace: FB,
    valAxisMaxVal: 140, valGridLine: { color: C.line, size: 1 },
    catGridLine: { style: "none" },
  });

  const tbl = [
    [{ text: "Mode", options: { bold: true } }, { text: "Best", options: { bold: true } },
     { text: "Typical", options: { bold: true } }, { text: "Worst", options: { bold: true } },
     { text: "Dominant cost", options: { bold: true } }],
    ["IR panorama", "36 ms", "69 ms", "102 ms", "Output stage only"],
    ["IR single", "67 ms", "100 ms", "133 ms", "Store and forward"],
    ["EO single", "67 ms", "100 ms", "133 ms", "Store and forward"],
    ["EO panorama", "67 ms", "117 ms", "167 ms", "Camera alignment"],
  ];
  s.addTable(tbl, {
    x: 7.9, y: 1.95, w: 4.85, colW: [1.35, 0.72, 0.85, 0.8, 1.13],
    fontSize: 10.5, fontFace: FB, color: C.body, border: { type: "solid", color: C.line, pt: 1 },
    fill: { color: C.white }, rowH: 0.42, valign: "middle",
  });

  s.addShape(pres.ShapeType.roundRect, { x: 0.6, y: 5.72, w: 12.15, h: 1.05, rectRadius: 0.06,
    fill: { color: C.panel }, line: { color: C.line, width: 1 } });
  s.addText([
    { text: "The spread between best and worst is one output frame in each direction. ", options: { bold: true, color: C.ink } },
    { text: "It comes from where a frame happens to land relative to the output frame boundary, which is not controlled and varies frame to frame." },
  ], { x: 0.9, y: 5.9, w: 11.55, h: 0.7, fontSize: 12.5, color: C.body, fontFace: FB, margin: 0, valign: "middle" });
  s.addNotes("IR panorama is roughly one output frame ahead of everything else, and that gap is architectural rather than an optimisation.");
}

// ---------------------------------------------------------------- refresh
{
  const s = lightSlide("A second effect: how often the picture changes", "Measured");
  s.addText("Latency is how old the picture is. Refresh is how often it is replaced. They are separate, and on the EO paths they differ.",
    { x: 0.6, y: 1.42, w: 12.1, h: 0.4, fontSize: 13.5, color: C.body, fontFace: FB, margin: 0 });

  statCard(s, 0.6, 2.0, 2.6, "30 Hz", "HD-SDI output raster", C.ink);
  statCard(s, 3.42, 2.0, 2.6, "15.1 Hz", "measured new frames on the EO paths", C.warn);
  statCard(s, 6.24, 2.0, 2.6, "2x", "each frame is presented twice", C.warn);
  statCard(s, 9.06, 2.0, 3.7, "+33 ms", "average extra staleness this adds", C.warn);

  s.addText("Why", { x: 0.6, y: 3.85, w: 6, h: 0.32, fontSize: 15, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  s.addText([
    { text: "The render pass currently occupies almost a whole output frame period. A render that begins on one frame boundary therefore finishes during the next one, and can only be published on the boundary after that - so a new picture appears every second output frame.", options: { breakLine: true } },
    { text: "" , options: { breakLine: true } },
    { text: "This is a throughput limit, not a correctness one: no frames are lost, each is simply shown twice.", options: { italic: true, color: C.muted } },
  ], { x: 0.6, y: 4.25, w: 7.5, h: 1.5, fontSize: 12.5, color: C.body, fontFace: FB, margin: 0 });

  s.addShape(pres.ShapeType.roundRect, { x: 8.4, y: 4.15, w: 4.35, h: 2.35, rectRadius: 0.06,
    fill: { color: C.goodLite }, line: { color: C.good, width: 1 } });
  s.addText("Headroom already recovered", { x: 8.68, y: 4.35, w: 3.8, h: 0.32,
    fontSize: 13, bold: true, color: C.ink, fontFace: FB, margin: 0 });
  s.addText([
    { text: "A defect fixed in August was issuing a large fraction of memory write commands twice. ", options: { breakLine: true } },
    { text: "" , options: { breakLine: true } },
    { text: "Removing them raised measured memory write throughput from 36.7 to 94.1 commands per 1000 cycles - most of the way to what a 30 Hz refresh needs.", options: {} },
  ], { x: 8.68, y: 4.72, w: 3.8, h: 1.65, fontSize: 11.5, color: C.body, fontFace: FB, margin: 0 });
  s.addNotes("Measured by grabbing the output at 60 fps and counting distinct frames by exact hash. Four independent captures gave 14.8-15.1 Hz.");
}

// ---------------------------------------------------------------- levers
{
  const s = lightSlide("Where the remaining time is, and what would remove it", "Outlook");

  const items = [
    ["Adopt direct ingress on the EO paths",
     "Overlap rendering onto arriving rows instead of storing whole frames first, exactly as the IR panorama already does.",
     "removes ~33 ms", C.good],
    ["Fit the render inside one frame period",
     "Restores a genuine 30 Hz refresh and removes the average 33 ms of extra staleness. The memory headroom for this has largely been recovered already.",
     "removes ~33 ms", C.good],
    ["Genlock the EO cameras",
     "Would remove the alignment wait on EO panorama. Requires camera support that the current EO units do not offer.",
     "removes ~17 ms", C.warn],
    ["Output stage",
     "Commit and scan-out are fixed by driving a 30 Hz raster from a frame store. Only a change of output format would reduce this.",
     "floor: ~33 ms", C.muted],
  ];
  items.forEach(([t, d, tag, col], i) => {
    const y = 1.55 + i * 1.3;
    s.addShape(pres.ShapeType.roundRect, { x: 0.6, y, w: 12.15, h: 1.12, rectRadius: 0.06,
      fill: { color: C.panel }, line: { color: C.line, width: 1 } });
    s.addShape(pres.ShapeType.ellipse, { x: 0.88, y: y + 0.34, w: 0.44, h: 0.44,
      fill: { color: col }, line: { color: col, width: 0 } });
    s.addText(String(i + 1), { x: 0.88, y: y + 0.34, w: 0.44, h: 0.44, fontSize: 14, bold: true,
      color: C.white, align: "center", valign: "middle", fontFace: FB, margin: 0 });
    s.addText(t, { x: 1.5, y: y + 0.18, w: 8.4, h: 0.34, fontSize: 14, bold: true,
      color: C.ink, fontFace: FB, margin: 0 });
    s.addText(d, { x: 1.5, y: y + 0.53, w: 8.5, h: 0.5, fontSize: 11.5,
      color: C.body, fontFace: FB, margin: 0 });
    s.addShape(pres.ShapeType.roundRect, { x: 10.35, y: y + 0.34, w: 2.1, h: 0.46, rectRadius: 0.08,
      fill: { color: C.white }, line: { color: col, width: 1.25 } });
    s.addText(tag, { x: 10.35, y: y + 0.34, w: 2.1, h: 0.46, fontSize: 11, bold: true,
      color: col, align: "center", valign: "middle", fontFace: FB, margin: 0 });
  });
  s.addNotes("Items 1 and 2 are within the current hardware. Item 3 depends on the camera vendor. Item 4 is a property of the output standard.");
}

// ---------------------------------------------------------------- basis
{
  const s = lightSlide("Basis of these numbers", "Assurance");
  s.addText("So the figures can be audited rather than taken on trust.",
    { x: 0.6, y: 1.42, w: 12.1, h: 0.36, fontSize: 13, color: C.muted, fontFace: FB, margin: 0, italic: true });

  const cols = [
    ["Design constants", C.eo, [
      "Output frame period 33.33 ms",
      "Camera formats and frame rates",
      "35 source rows before the IR panorama can emit its first output row",
      "Read directly from the design and its generated geometry tables",
    ]],
    ["Measured on hardware", C.good, [
      "Output refresh 15.1 Hz on the EO paths, from four independent captures",
      "IR genlock skew under 274 ns across six cameras",
      "Memory write throughput before and after the August fix",
    ]],
    ["Stated assumptions", C.warn, [
      "Camera sensor and ISP delay is excluded - vendor specification",
      "Commit and scan-out quoted at their average; both range 0 to one frame",
      "Render occupancy taken as one frame period, consistent with the measured refresh",
    ]],
  ];
  cols.forEach(([title, col, lines], i) => {
    const x = 0.6 + i * 4.13;
    s.addShape(pres.ShapeType.roundRect, { x, y: 1.95, w: 3.88, h: 3.0, rectRadius: 0.06,
      fill: { color: C.white }, line: { color: col, width: 1.5 } });
    s.addShape(pres.ShapeType.ellipse, { x: x + 0.28, y: 2.22, w: 0.34, h: 0.34,
      fill: { color: col }, line: { color: col, width: 0 } });
    s.addText(title, { x: x + 0.74, y: 2.2, w: 3.0, h: 0.38, fontSize: 13.5, bold: true,
      color: C.ink, fontFace: FB, margin: 0, valign: "middle" });
    s.addText(lines.map((t, j) => ({ text: t, options: { bullet: true, breakLine: j < lines.length - 1 } })),
      { x: x + 0.3, y: 2.75, w: 3.3, h: 2.1, fontSize: 11, color: C.body,
        fontFace: FB, margin: 0, paraSpaceAfter: 8, valign: "top" });
  });

  s.addText("Latency was derived from the pipeline structure and validated against the measured refresh rate; it was not measured end to end with an external timing reference.",
    { x: 0.6, y: 5.22, w: 12.15, h: 0.5, fontSize: 11.5, color: C.muted, fontFace: FB, margin: 0, italic: true });
  s.addNotes("If the customer needs a certified end-to-end figure, that requires an external reference - an LED pulsed into the camera and a photodiode on the display - which we have not run.");
}

pres.writeFile({ fileName: "EO_IR_Panorama_Latency_Analysis.pptx" })
  .then((f) => console.log("wrote " + f));
