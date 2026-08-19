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
