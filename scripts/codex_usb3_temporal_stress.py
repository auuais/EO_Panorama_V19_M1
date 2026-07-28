#!/usr/bin/env python3
"""Low-overhead HD-SDI/USB temporal-integrity stress capture.

The panorama raster contains two active 1920x378 image bands separated by
intentional black padding.  This tool continuously reads the USB grabber,
learns the normal horizontal-edge profile, and saves only frames that acquire
a new wide horizontal discontinuity or a one-row temporal corruption event.
"""

import argparse
import json
import time
from pathlib import Path

import cv2
import numpy as np


def parse_spans(text, height):
    spans = []
    for item in text.split(","):
        first, last = item.split(":", 1)
        first = max(0, int(first))
        last = min(height, int(last))
        if last - first < 4:
            raise ValueError(f"active span is too short: {item}")
        spans.append((first, last))
    return spans


def active_row_mask(height, spans):
    mask = np.zeros(height, dtype=bool)
    for first, last in spans:
        # Exclude the two rows nearest each intentional black/image boundary.
        mask[first + 2 : last - 2] = True
    return mask


def save_jpeg(path, frame):
    if not cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, 94]):
        raise RuntimeError(f"could not write {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=int, default=0)
    parser.add_argument("--frames", type=int, default=1800)
    parser.add_argument("--warmup", type=int, default=30)
    parser.add_argument("--baseline-frames", type=int, default=60)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--fps", type=float, default=30.0)
    parser.add_argument("--active-spans", default="51:429,531:909")
    parser.add_argument("--sample-every", type=int, default=300)
    parser.add_argument("--max-saved-anomalies", type=int, default=20)
    parser.add_argument("--outdir", required=True)
    args = parser.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(args.index, cv2.CAP_DSHOW)
    if not cap.isOpened():
        raise SystemExit(f"could not open video index {args.index}")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    cap.set(cv2.CAP_PROP_FPS, args.fps)

    for _ in range(args.warmup):
        ok, _ = cap.read()
        if not ok:
            cap.release()
            raise SystemExit("grabber failed during warmup")

    ok, first = cap.read()
    if not ok or first is None:
        cap.release()
        raise SystemExit("grabber returned no frame")

    height, width = first.shape[:2]
    spans = parse_spans(args.active_spans, height)
    row_mask = active_row_mask(height, spans)
    edge_mask = row_mask[:-1] & row_mask[1:]

    # Fractions are measured across a center crop so SDI blanking at the left
    # and right raster edges cannot look like a full-width corruption line.
    x0 = max(0, width // 40)
    x1 = min(width, width - width // 40)
    prev_gray = cv2.cvtColor(first, cv2.COLOR_BGR2GRAY)[:, x0:x1]
    baseline_edge_max = np.zeros(height - 1, dtype=np.float32)

    anomaly_count = 0
    temporal_row_events = 0
    spatial_boundary_events = 0
    duplicate_frames = 0
    saved_anomalies = 0
    max_temporal_fraction = 0.0
    max_temporal_row = -1
    max_spatial_fraction = 0.0
    max_spatial_row = -1
    processed = 0
    start = time.time()

    for frame_index in range(args.frames):
        if frame_index == 0:
            frame = first
        else:
            ok, frame = cap.read()
            if not ok or frame is None:
                break

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)[:, x0:x1]
        temporal = cv2.absdiff(gray, prev_gray)
        temporal_fraction = np.mean(temporal > 42, axis=1)

        spatial = cv2.absdiff(gray[1:, :], gray[:-1, :])
        spatial_fraction = np.mean(spatial > 48, axis=1)

        active_temporal = np.where(row_mask, temporal_fraction, 0.0)
        active_spatial = np.where(edge_mask, spatial_fraction, 0.0)
        temporal_peak_row = int(np.argmax(active_temporal))
        spatial_peak_row = int(np.argmax(active_spatial))
        temporal_peak = float(active_temporal[temporal_peak_row])
        spatial_peak = float(active_spatial[spatial_peak_row])

        if temporal_peak > max_temporal_fraction:
            max_temporal_fraction = temporal_peak
            max_temporal_row = temporal_peak_row
        if spatial_peak > max_spatial_fraction:
            max_spatial_fraction = spatial_peak
            max_spatial_row = spatial_peak_row

        if float(np.mean(temporal)) < 0.05:
            duplicate_frames += 1

        if frame_index < args.baseline_frames:
            baseline_edge_max = np.maximum(baseline_edge_max, active_spatial)
            temporal_event = False
            spatial_event = False
        else:
            # A corrupted line changes most of one raster row while the rows
            # immediately around it remain normal. Broad real-scene motion is
            # intentionally rejected by the neighbour test.
            t0 = max(0, temporal_peak_row - 2)
            t1 = min(height, temporal_peak_row + 3)
            temporal_neighbours = np.delete(
                active_temporal[t0:t1], temporal_peak_row - t0
            )
            temporal_neighbour_peak = (
                float(np.max(temporal_neighbours))
                if temporal_neighbours.size
                else 0.0
            )
            temporal_event = (
                temporal_peak >= 0.60 and temporal_neighbour_peak <= 0.35
            )

            # A mid-frame epoch boundary creates a new wide adjacent-row edge.
            # Require it to exceed both an absolute threshold and the learned
            # per-row maximum by a large margin.
            spatial_event = (
                spatial_peak >= 0.48
                and spatial_peak
                >= float(baseline_edge_max[spatial_peak_row]) + 0.22
            )

        if temporal_event:
            temporal_row_events += 1
        if spatial_event:
            spatial_boundary_events += 1
        if temporal_event or spatial_event:
            anomaly_count += 1
            if saved_anomalies < args.max_saved_anomalies:
                tag = []
                if temporal_event:
                    tag.append(f"temporal_y{temporal_peak_row}")
                if spatial_event:
                    tag.append(f"boundary_y{spatial_peak_row}")
                save_jpeg(
                    outdir / f"anomaly_{frame_index:06d}_{'_'.join(tag)}.jpg",
                    frame,
                )
                saved_anomalies += 1

        if args.sample_every > 0 and frame_index % args.sample_every == 0:
            save_jpeg(outdir / f"sample_{frame_index:06d}.jpg", frame)

        prev_gray = gray
        processed += 1

    elapsed = time.time() - start
    cap.release()

    result = {
        "capture_dir": str(outdir.resolve()),
        "video_index": args.index,
        "requested_frames": args.frames,
        "processed_frames": processed,
        "elapsed_s": elapsed,
        "measured_fps": processed / elapsed if elapsed else 0.0,
        "active_spans": spans,
        "baseline_frames": args.baseline_frames,
        "anomaly_count": anomaly_count,
        "temporal_row_events": temporal_row_events,
        "spatial_boundary_events": spatial_boundary_events,
        "saved_anomalies": saved_anomalies,
        "duplicate_frames": duplicate_frames,
        "max_temporal_fraction": max_temporal_fraction,
        "max_temporal_row": max_temporal_row,
        "max_spatial_fraction": max_spatial_fraction,
        "max_spatial_row": max_spatial_row,
    }
    (outdir / "temporal_stress_summary.json").write_text(
        json.dumps(result, indent=2), encoding="utf-8"
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
