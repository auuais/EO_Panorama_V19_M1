from __future__ import annotations

import csv
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(r"C:\SVNProjects\IMU_Stabilize_v40\EO_IR_TestCases")
STRETCH_DIR = ROOT / "EO_Test4C_R_0.75_P_-5" / "comp" / "stretch_analysis"
SUMMARY_CSV = STRETCH_DIR / "EO_IR_object_based_stretch_summary.csv"
EO_SOURCE = ROOT / "EO_Test4C_R_0.75_P_-5" / "comp" / "Stab_false.bmp"

OUT_DIR = Path(r"E:\Xylinx\EO_Panorama_V19_M1\output\pdf\assets")
OUT_DIR.mkdir(parents=True, exist_ok=True)
FIG_PATH = OUT_DIR / "customer_local_overlap_warp_demo.png"
QUARTER_TILE_FIG_PATH = OUT_DIR / "customer_quarter_tile_warp_demo.png"
METRICS_PATH = OUT_DIR / "customer_local_overlap_warp_metrics.csv"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf",
        r"C:\Windows\Fonts\segoeuib.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


FONT_TITLE = font(34, True)
FONT_HEAD = font(24, True)
FONT_BODY = font(20)
FONT_SMALL = font(16)


def read_measurements() -> dict[str, dict[str, float | str]]:
    rows: dict[str, dict[str, float | str]] = {}
    with SUMMARY_CSV.open(newline="") as f:
        reader = csv.reader(f)
        next(reader)
        for row in reader:
            rows[row[0]] = {
                "source": row[1],
                "target": row[2],
                "method": row[3],
                "good_matches": float(row[6]),
                "inliers": float(row[7]),
                "median_error_px": float(row[8]),
                "x_scale": float(row[9]),
                "y_scale": float(row[10]),
                "x_stretch_pct": float(row[11]),
                "y_stretch_pct": float(row[12]),
            }
    return rows


def local_warp_numbers(global_scale: float, active_width: float, overlap_px: float, seams: int = 5) -> tuple[float, float, float]:
    overlap_fraction = seams * overlap_px / active_width
    flat_avg_scale = 1.0 + (global_scale - 1.0) / overlap_fraction
    smooth_peak_scale = 1.0 + 2.0 * (global_scale - 1.0) / overlap_fraction
    return overlap_fraction, flat_avg_scale, smooth_peak_scale


def make_scale_profile(width: int, global_scale: float, seam_centers: list[float], overlap_width: float) -> np.ndarray:
    profile = np.zeros(width, dtype=np.float64)
    radius = overlap_width / 2.0
    for center in seam_centers:
        x0 = max(0, int(np.floor(center - radius)))
        x1 = min(width, int(np.ceil(center + radius)))
        if x1 <= x0:
            continue
        xs = np.arange(x0, x1, dtype=np.float64)
        t = (xs - (center - radius)) / max(overlap_width, 1.0)
        window = np.sin(np.pi * np.clip(t, 0.0, 1.0)) ** 2
        profile[x0:x1] = np.maximum(profile[x0:x1], window)

    area = float(profile.sum())
    if area <= 0.0:
        return np.ones(width, dtype=np.float64)

    amplitude = (global_scale - 1.0) * width / area
    return 1.0 + amplitude * profile


def make_quarter_tile_profile(width: int, global_scale: float, tile_count: int = 6) -> tuple[np.ndarray, float, float]:
    tile_width = width / tile_count
    edge_width = tile_width * 0.25
    seam_band_width = edge_width * 2.0
    seam_centers = [i * tile_width for i in range(tile_count + 1)]
    return make_scale_profile(width, global_scale, seam_centers, seam_band_width), edge_width, seam_band_width


def column_vertical_scale(img: Image.Image, scale_by_x: np.ndarray) -> Image.Image:
    arr = np.asarray(img.convert("RGB"), dtype=np.float32)
    h, w, c = arr.shape
    out = np.empty_like(arr)
    center = (h - 1) / 2.0
    yy = np.arange(h, dtype=np.float64)
    for x in range(w):
        scale = float(scale_by_x[x])
        src_y = (yy - center) / scale + center
        y0 = np.floor(src_y).astype(np.int32)
        y0 = np.clip(y0, 0, h - 1)
        y1 = np.clip(y0 + 1, 0, h - 1)
        frac = (src_y - y0).astype(np.float32)[:, None]
        out[:, x, :] = arr[y0, x, :] * (1.0 - frac) + arr[y1, x, :] * frac
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")


def fit(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    out = img.copy()
    out.thumbnail(size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", size, "white")
    canvas.paste(out, ((size[0] - out.width) // 2, (size[1] - out.height) // 2))
    return canvas


def label_panel(img: Image.Image, title: str, subtitle: str = "") -> Image.Image:
    top = 58 if subtitle else 42
    canvas = Image.new("RGB", (img.width, img.height + top), (248, 250, 252))
    canvas.paste(img, (0, top))
    d = ImageDraw.Draw(canvas)
    d.text((14, 9), title, fill=(18, 35, 55), font=FONT_HEAD)
    if subtitle:
        d.text((14, 36), subtitle, fill=(72, 84, 98), font=FONT_SMALL)
    return canvas


def draw_scale_plot(scale: np.ndarray, width: int, height: int, seam_centers: list[float], overlap_width: float) -> Image.Image:
    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    left, top, right, bottom = 54, 22, width - 24, height - 44
    d.rectangle([left, top, right, bottom], outline=(170, 180, 190), width=1)
    s_min = 1.0
    s_max = max(2.0, float(np.max(scale)) * 1.04)
    for val in [1.0, 1.5, 2.0, 2.5, 3.0]:
        if val > s_max:
            continue
        y = bottom - int((val - s_min) / (s_max - s_min) * (bottom - top))
        d.line([left, y, right, y], fill=(230, 235, 240), width=1)
        d.text((8, y - 8), f"{val:.1f}x", fill=(90, 95, 105), font=FONT_SMALL)
    for center in seam_centers:
        x0 = left + int((center - overlap_width / 2) / len(scale) * (right - left))
        x1 = left + int((center + overlap_width / 2) / len(scale) * (right - left))
        d.rectangle([x0, top, x1, bottom], fill=(255, 235, 235))
    pts = []
    step = max(1, len(scale) // 900)
    for x in range(0, len(scale), step):
        px = left + int(x / (len(scale) - 1) * (right - left))
        py = bottom - int((scale[x] - s_min) / (s_max - s_min) * (bottom - top))
        pts.append((px, py))
    if len(pts) > 1:
        d.line(pts, fill=(185, 45, 45), width=3)
    d.text((left, bottom + 13), "horizontal panorama position", fill=(90, 95, 105), font=FONT_SMALL)
    d.text((left + 480, bottom + 13), "red bands mark overlap zones", fill=(145, 45, 45), font=FONT_SMALL)
    return img


def draw_metrics_table(metrics: list[dict[str, str]]) -> Image.Image:
    img = Image.new("RGB", (760, 362), "white")
    d = ImageDraw.Draw(img)
    d.text((0, 0), "Measured correction forced into overlaps", fill=(18, 35, 55), font=FONT_HEAD)
    y = 48
    headers = ["Case", "overlap", "flat avg", "smooth peak"]
    xs = [0, 210, 390, 580]
    for x, h in zip(xs, headers):
        d.text((x, y), h, fill=(65, 75, 90), font=FONT_SMALL)
    y += 27
    d.line([0, y, 744, y], fill=(180, 190, 200), width=1)
    y += 10
    for row in metrics:
        d.rounded_rectangle([0, y - 7, 744, y + 52], radius=6, fill=(246, 248, 251), outline=(220, 226, 234))
        values = [row["case"], row["overlap"], row["flat"], row["peak"]]
        for x, val in zip(xs, values):
            d.text((x + 10, y + 9), val, fill=(20, 30, 45), font=FONT_BODY if x == 0 else FONT_SMALL)
        y += 70
    d.text(
        (4, y + 2),
        "Flat avg is already the minimum average local scale if interiors stay 1.00x.",
        fill=(80, 90, 100),
        font=FONT_SMALL,
    )
    d.text(
        (4, y + 24),
        "A smooth warp that returns to 1.00x at band edges needs a higher peak.",
        fill=(80, 90, 100),
        font=FONT_SMALL,
    )
    return img


def draw_quarter_tile_metrics(metrics: list[dict[str, str]]) -> Image.Image:
    img = Image.new("RGB", (760, 300), "white")
    d = ImageDraw.Draw(img)
    d.text((0, 0), "25 percent on each tile side", fill=(18, 35, 55), font=FONT_HEAD)
    y = 48
    headers = ["Case", "active support", "flat avg", "smooth peak"]
    xs = [0, 210, 410, 590]
    for x, h in zip(xs, headers):
        d.text((x, y), h, fill=(65, 75, 90), font=FONT_SMALL)
    y += 27
    d.line([0, y, 744, y], fill=(180, 190, 200), width=1)
    y += 10
    for row in metrics:
        d.rounded_rectangle([0, y - 7, 744, y + 52], radius=6, fill=(246, 248, 251), outline=(220, 226, 234))
        values = [row["case"], row["support"], row["flat"], row["peak"]]
        for x, val in zip(xs, values):
            d.text((x + 10, y + 9), val, fill=(20, 30, 45), font=FONT_BODY if x == 0 else FONT_SMALL)
        y += 70
    d.text(
        (4, y + 4),
        "Raised-cosine ramps occupy each outer quarter; every tile center remains 1.00x.",
        fill=(80, 90, 100),
        font=FONT_SMALL,
    )
    return img


def draw_profile_comparison(
    narrow_scale: np.ndarray,
    quarter_scale: np.ndarray,
    width: int,
    height: int,
) -> Image.Image:
    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    left, top, right, bottom = 54, 22, width - 24, height - 48
    d.rectangle([left, top, right, bottom], outline=(170, 180, 190), width=1)
    s_min = 1.0
    s_max = float(max(np.max(narrow_scale), np.max(quarter_scale))) * 1.04
    for val in [1.0, 1.5, 2.0, 2.5, 3.0]:
        if val > s_max:
            continue
        y = bottom - int((val - s_min) / (s_max - s_min) * (bottom - top))
        d.line([left, y, right, y], fill=(230, 235, 240), width=1)
        d.text((8, y - 8), f"{val:.1f}x", fill=(90, 95, 105), font=FONT_SMALL)

    def plot(scale: np.ndarray, color: tuple[int, int, int], line_width: int) -> None:
        pts = []
        step = max(1, len(scale) // 900)
        for x in range(0, len(scale), step):
            px = left + int(x / (len(scale) - 1) * (right - left))
            py = bottom - int((scale[x] - s_min) / (s_max - s_min) * (bottom - top))
            pts.append((px, py))
        if len(pts) > 1:
            d.line(pts, fill=color, width=line_width)

    plot(narrow_scale, (185, 45, 45), 3)
    plot(quarter_scale, (32, 105, 165), 4)
    d.text((left, bottom + 13), "red: 48.9 px overlap-only", fill=(185, 45, 45), font=FONT_SMALL)
    d.text((left + 310, bottom + 13), "blue: outer 25 percent of each tile", fill=(32, 105, 165), font=FONT_SMALL)
    return img


def build_figure() -> None:
    measurements = read_measurements()
    eo = measurements["EO"]
    ir = measurements["IR"]
    eo_scale = float(eo["y_scale"])
    ir_scale = float(ir["y_scale"])

    eo_sw_overlap_fraction, eo_sw_flat, eo_sw_peak = local_warp_numbers(eo_scale, 3840.0, 48.9)
    eo_hw_overlap_fraction, eo_hw_flat, eo_hw_peak = local_warp_numbers(eo_scale, 3840.0, 17.0)
    ir_hw_overlap_fraction, ir_hw_flat, ir_hw_peak = local_warp_numbers(ir_scale, 3576.0, 29.0)
    quarter_support_fraction = 0.5
    eo_quarter_flat = 1.0 + (eo_scale - 1.0) / quarter_support_fraction
    eo_quarter_peak = 1.0 + 2.0 * (eo_scale - 1.0) / quarter_support_fraction
    ir_quarter_flat = 1.0 + (ir_scale - 1.0) / quarter_support_fraction
    ir_quarter_peak = 1.0 + 2.0 * (ir_scale - 1.0) / quarter_support_fraction

    with METRICS_PATH.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "case",
                "measured_y_scale",
                "measured_y_stretch_pct",
                "active_width_px",
                "correction_band_width_px",
                "seam_count",
                "overlap_fraction",
                "flat_overlap_average_y_scale",
                "smooth_overlap_peak_y_scale",
                "data_source",
            ]
        )
        writer.writerow(
            [
                "EO software-test effective overlap",
                f"{eo_scale:.9f}",
                f"{float(eo['y_stretch_pct']):.6f}",
                "3840",
                "48.9",
                "5",
                f"{eo_sw_overlap_fraction:.9f}",
                f"{eo_sw_flat:.6f}",
                f"{eo_sw_peak:.6f}",
                str(SUMMARY_CSV),
            ]
        )
        writer.writerow(
            [
                "EO outer 25 percent of each tile side",
                f"{eo_scale:.9f}",
                f"{float(eo['y_stretch_pct']):.6f}",
                "3840",
                "320",
                "6",
                f"{quarter_support_fraction:.9f}",
                f"{eo_quarter_flat:.6f}",
                f"{eo_quarter_peak:.6f}",
                str(SUMMARY_CSV),
            ]
        )
        writer.writerow(
            [
                "IR outer 25 percent of each tile side",
                f"{ir_scale:.9f}",
                f"{float(ir['y_stretch_pct']):.6f}",
                "3576",
                "298",
                "6",
                f"{quarter_support_fraction:.9f}",
                f"{ir_quarter_flat:.6f}",
                f"{ir_quarter_peak:.6f}",
                str(SUMMARY_CSV),
            ]
        )
        writer.writerow(
            [
                "EO current FPGA 17 px overlap",
                f"{eo_scale:.9f}",
                f"{float(eo['y_stretch_pct']):.6f}",
                "3840",
                "17",
                "5",
                f"{eo_hw_overlap_fraction:.9f}",
                f"{eo_hw_flat:.6f}",
                f"{eo_hw_peak:.6f}",
                str(SUMMARY_CSV),
            ]
        )
        writer.writerow(
            [
                "IR current FPGA 29 px overlap",
                f"{ir_scale:.9f}",
                f"{float(ir['y_stretch_pct']):.6f}",
                "3576",
                "29",
                "5",
                f"{ir_hw_overlap_fraction:.9f}",
                f"{ir_hw_flat:.6f}",
                f"{ir_hw_peak:.6f}",
                str(SUMMARY_CSV),
            ]
        )

    source = Image.open(EO_SOURCE).convert("RGB")
    seam_centers = [640, 1280, 1920, 2560, 3200]
    scale_profile = make_scale_profile(source.width, eo_scale, seam_centers, 48.9)
    local_warp = column_vertical_scale(source, scale_profile)
    global_warp = column_vertical_scale(source, np.full(source.width, eo_scale, dtype=np.float64))

    full_source = label_panel(
        fit(source, (1650, 206)),
        "A. Baseline EO panorama from test case",
        "Source: EO_Test4C comp/Stab_false.bmp, 3840 x 480",
    )
    full_global = label_panel(
        fit(global_warp, (1650, 206)),
        "B. Same 5.75 percent correction spread globally",
        "Mild but non-metric global anisotropy",
    )
    full_local = label_panel(
        fit(local_warp, (1650, 206)),
        "C. Same correction confined to overlap bands",
        "Interiors stay 1.00x; overlap bands carry the error",
    )

    zoom_center = 1280
    zoom_w = 240
    box = (zoom_center - zoom_w // 2, 0, zoom_center + zoom_w // 2, source.height)
    zooms = []
    for title, im in [
        ("baseline seam-area zoom", source.crop(box)),
        ("global correction zoom", global_warp.crop(box)),
        ("overlap-only warp zoom", local_warp.crop(box)),
    ]:
        panel = fit(im.resize((im.width * 2, im.height * 2), Image.Resampling.NEAREST), (500, 420))
        draw = ImageDraw.Draw(panel)
        draw.rectangle([226, 5, 274, 415], outline=(205, 45, 45), width=4)
        zooms.append(label_panel(panel, title))

    metrics_img = draw_metrics_table(
        [
            {
                "case": "EO data, 48.9 px",
                "overlap": f"{eo_sw_overlap_fraction * 100:.2f}%",
                "flat": f"{eo_sw_flat:.2f}x",
                "peak": f"{eo_sw_peak:.2f}x",
            },
            {
                "case": "EO data, 17 px",
                "overlap": f"{eo_hw_overlap_fraction * 100:.2f}%",
                "flat": f"{eo_hw_flat:.2f}x",
                "peak": f"{eo_hw_peak:.2f}x",
            },
            {
                "case": "IR data, 29 px",
                "overlap": f"{ir_hw_overlap_fraction * 100:.2f}%",
                "flat": f"{ir_hw_flat:.2f}x",
                "peak": f"{ir_hw_peak:.2f}x",
            },
        ]
    )
    plot_img = draw_scale_plot(scale_profile, 860, 260, seam_centers, 48.9)

    canvas = Image.new("RGB", (1800, 1850), "white")
    d = ImageDraw.Draw(canvas)
    d.text((44, 28), "What the customer's overlap-only warp looks like on actual EO test data", fill=(15, 35, 55), font=FONT_TITLE)
    d.text(
        (44, 76),
        (
            f"Object-feature measurement: EO target/source y scale = {eo_scale:.6f} "
            f"(+{float(eo['y_stretch_pct']):.2f} percent), "
            f"{int(eo['inliers'])} inliers, median error {float(eo['median_error_px']):.2f} px."
        ),
        fill=(70, 80, 95),
        font=FONT_BODY,
    )

    y = 122
    for panel in [full_source, full_global, full_local]:
        canvas.paste(panel, (74, y))
        y += panel.height + 18

    y += 6
    x = 74
    for panel in zooms:
        canvas.paste(panel, (x, y))
        x += panel.width + 30

    canvas.paste(metrics_img, (74, 1418))
    canvas.paste(plot_img, (870, 1455))
    d.text(
        (74, 1760),
        "Interpretation: the local-overlap rule protects camera interiors only by creating a narrow, high-gain deformation field at the seams.",
        fill=(30, 45, 60),
        font=FONT_BODY,
    )
    d.text(
        (74, 1792),
        "That is visually fragile and not a calibrated 360-degree projection.",
        fill=(30, 45, 60),
        font=FONT_BODY,
    )

    canvas.save(FIG_PATH)

    quarter_profile, eo_edge_width, eo_band_width = make_quarter_tile_profile(source.width, eo_scale)
    quarter_warp = column_vertical_scale(source, quarter_profile)

    quarter_source = label_panel(
        fit(source, (1650, 206)),
        "A. Baseline EO panorama from test case",
        "Six 640 px output tiles; vertical scale is 1.00x",
    )
    quarter_global = label_panel(
        fit(global_warp, (1650, 206)),
        "B. Same 5.75 percent correction spread globally",
        "Uniform vertical scale = 1.0575x",
    )
    quarter_local = label_panel(
        fit(quarter_warp, (1650, 206)),
        "C. Correction spread over 25 percent on both sides of every tile",
        f"{eo_edge_width:.0f} px per side; {eo_band_width:.0f} px smooth seam zone; peak scale = {eo_quarter_peak:.3f}x",
    )

    quarter_zooms = []
    for title, im in [
        ("baseline seam-area zoom", source.crop(box)),
        ("48.9 px overlap-only zoom", local_warp.crop(box)),
        ("25 percent per-side zoom", quarter_warp.crop(box)),
    ]:
        panel = fit(im.resize((im.width * 2, im.height * 2), Image.Resampling.NEAREST), (500, 420))
        quarter_zooms.append(label_panel(panel, title))

    quarter_metrics = draw_quarter_tile_metrics(
        [
            {
                "case": "EO measured",
                "support": "50.0%",
                "flat": f"{eo_quarter_flat:.3f}x",
                "peak": f"{eo_quarter_peak:.3f}x",
            },
            {
                "case": "IR measured",
                "support": "50.0%",
                "flat": f"{ir_quarter_flat:.3f}x",
                "peak": f"{ir_quarter_peak:.3f}x",
            },
        ]
    )
    comparison_plot = draw_profile_comparison(scale_profile, quarter_profile, 860, 300)

    quarter_canvas = Image.new("RGB", (1800, 1760), "white")
    qd = ImageDraw.Draw(quarter_canvas)
    qd.text((44, 28), "Wider local warp: outer 25 percent of every panorama tile", fill=(15, 35, 55), font=FONT_TITLE)
    qd.text(
        (44, 76),
        (
            f"The same measured EO y correction (+{float(eo['y_stretch_pct']):.2f} percent) is redistributed over "
            "half of the panorama instead of the narrow physical overlaps."
        ),
        fill=(70, 80, 95),
        font=FONT_BODY,
    )

    qy = 122
    for panel in [quarter_source, quarter_global, quarter_local]:
        quarter_canvas.paste(panel, (74, qy))
        qy += panel.height + 18

    qy += 6
    qx = 74
    for panel in quarter_zooms:
        quarter_canvas.paste(panel, (qx, qy))
        qx += panel.width + 30

    quarter_canvas.paste(quarter_metrics, (74, 1412))
    quarter_canvas.paste(comparison_plot, (870, 1395))
    qd.text(
        (74, 1704),
        "Result: the EO transition is much less conspicuous, but scale still varies from 1.00x at tile centers to 1.23x at seams.",
        fill=(30, 45, 60),
        font=FONT_BODY,
    )
    qd.text(
        (74, 1732),
        "This is a reasonable non-metric display warp to prototype; it does not preserve a single calibrated projection.",
        fill=(30, 45, 60),
        font=FONT_BODY,
    )
    quarter_canvas.save(QUARTER_TILE_FIG_PATH)


if __name__ == "__main__":
    build_figure()
    print(FIG_PATH)
    print(QUARTER_TILE_FIG_PATH)
    print(METRICS_PATH)
