# Three-bank output framebuffer in the IR_DDR fork, 2026-08-20

Build `00e0c57`, routed WNS +0.048 / WHS +0.010 / WPWS +0.012, archived at
`builds/bit_archive/20260820_065300_3bank_fork_00e0c57_00e0c57/`.

All figures are optical: grab the SDI output at 60 fps and count distinct
frames by exact hash (`scripts/measure_output_rate.py`). At a 60 fps grab,
repeat runs of 2 mean 30 fps and runs of 4 mean 15.

## Result

| mode | fork, 2 banks (`94f1005`) | fork, 3 banks (`00e0c57`) | source rate |
|---|---:|---:|---:|
| IR panorama | 29.98 / 29.92 | 29.72 / 29.92 / 29.92 | 30 |
| IR single | 29.92 | 29.91 | 30 |
| EO single | 29.12 | 29.78 | 30 |
| EO panorama | 19.39 / 20.46 / 19.26 | **22.39** | 30 |

**Three of the four modes are at their source rate on this fork, and were
already.** The third bank moves EO panorama and nothing else.

## The control that matters, and what it corrects

IR panorama measures 29.98 on the fork's **two-bank** build. It was already at
30 before this change.

That is not what the main branch shows, where IR panorama runs at 14.85 with
two banks. The difference is not the output stage -- it is that this fork
feeds IR panorama through DDR input buffers instead of the live line caches.
A DDR source can be replayed at any moment, so the copy start is not confined
to the renderer's ~1.95 ms row window, and the two-bank coupling that costs
main a whole camera frame per miss never bites here.

So the honest reading of tonight's work:

* On **main**, IR panorama's 15 fps is the narrow-start-window case the
  simulation models, and the third bank is predicted to fix it -- still
  untested, because main's 0x14 does not survive a rebuild.
* On **this fork**, IR panorama was never the mode with the problem. The input
  buffering had already solved it.
* The third bank's measured benefit here is **EO panorama, 19.7 -> 22.4**,
  consistent with the +26% seen on main (17.7 -> 22.3).

## EO panorama is the mode still short

22.4 against a 30 source. Run lengths move the right way -- 2-bank shows runs
of 8, 9 and 12 (133-200 ms stalls), 3-bank shows almost none -- but a
minority of frames still slip.

The remaining limiter is the frame-set manager, and it is EO-specific, which
is why IR panorama does not share it: an EO panorama copy needs a complete
six-camera lease, and the manager holds that lease from `ST_ACQUIRE` until
`consumer_done` (copy completion), then runs a release sweep over four bank
indices with a per-camera CDC handshake before it can begin looking for the
next common epoch. None of that overlaps the copy, and the render already
takes ~24.9 ms of a 33.3 ms period.

Acquiring the next lease while the current copy is still running is the
targeted fix.

## Regression check

EO single 29.12 -> 29.78 and IR single 29.92 -> 29.91: unchanged within
measurement spread. IR panorama unchanged at 30. Nothing regressed.

---

# Addendum — EO cameras switched from Trig-in to Free-run

Same build (`00e0c57`, three banks), reprogrammed from its archive. All
figures optical, 60 fps grab, distinct frames by exact hash.

## All six EO cameras, EO single

| UI camera | new frames/s | run lengths |
|---|---:|---|
| 1 | 29.89 | 2x357 |
| 2 | 29.06 | 2x337, 4x11 |
| 3 | 29.23 | 2x344, 4x5 |
| 4 | 29.56 | 2x349, 4x5 |
| 5 | 29.73 | 2x356, 4x2 |
| 6 | 29.56 | 2x351, 4x4 |

**Every EO camera delivers 30 distinct images per second, and the pipeline
publishes all of them.** Runs of 2 dominate everywhere; the scattered 4s are a
handful of slips per 12 s, not a pattern.

Worth noting: UI camera 4 measures 29.56 here. It was described as dead in
this setup earlier in the session and is plainly producing distinct frames now.

## Free-run did not change the panorama

| mode | Trig-in | Free-run |
|---|---:|---:|
| EO panorama | 22.39 | 23.32 / 22.72 / 22.79 |
| IR panorama | 29.72 / 29.92 / 29.92 | 29.97 |
| IR single | 29.91 | 29.81 |

EO panorama is 22.9 against 22.4 -- the same number within spread.

**That is a useful negative result.** The EO panorama shortfall is not caused
by how the cameras are triggered. Free-run removes the shared exposure trigger
entirely, and the rate does not move, so the limiter is internal.

Its shape is visible in the run lengths: 274 runs of 2, 55 of 4, 22 of 6. So
78% of published frames come at the full 33 ms cadence and 22% slip by one or
two frame periods. Not a mode stuck at half rate -- a mode that mostly keeps
up and intermittently misses.

That is consistent with the frame-set manager turnaround being the remaining
cost: an EO panorama copy needs a complete six-camera lease, and the manager
holds that lease from `ST_ACQUIRE` until copy completion, then sweeps four bank
indices with a per-camera CDC handshake before it can look for the next common
epoch -- none of it overlapping a render that already takes ~24.9 ms of a
33.3 ms period. Whenever that turnaround lands past the frame edge, one publish
slips. Acquiring the next lease while the current copy still runs remains the
targeted fix.

## Status against the goal

| mode | published | source | at rate? |
|---|---:|---:|---|
| IR single | 29.81 | 30 | yes |
| IR panorama | 29.97 | 30 | yes |
| EO single, all six | 29.06 - 29.89 | 30 | yes |
| EO panorama | 22.9 | 30 | **no** |

Seven of eight measured configurations are at source rate on this fork.
EO panorama is the one outstanding case.
