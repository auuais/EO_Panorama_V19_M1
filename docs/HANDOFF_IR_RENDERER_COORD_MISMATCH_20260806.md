# IR renderer vs golden model — open coordinate mismatch

Date: 2026-08-06
Status: **RTL complete and compiling; bench failing. Not built, not programmed.**
Nothing in this work is wired into a bitstream yet, so the EO path on the board
is unaffected.

## Where it stands

| Piece | State |
|---|---|
| `IrV19PanoramaParams.vh` | done, every constant verified against the package |
| `IrV19LineCache.v` | done, compiles, XPM model runs |
| `IrV19RunRom.v` | done, 96-bit records |
| `IrV19StreamingRenderer.v` | done, compiles, runs, **output wrong** |
| Stage 2 mode 0x14 integration | done, compositor + top compile clean |
| `scripts/ir_golden_rows.py` | done, independent model |
| `sim/tb_IrV19StreamingRenderer.v` | done, dumps `ir_seen.mem` |
| Build / program / hardware verify | **not started** |

## The failure

`3 rows x 3840 px = 11,520` compared, **7,213 mismatches**.

Run it with:

```
cd .xsim_ir/run && xsim irtb3 -R
```

The sim MUST run from a directory two levels below the project root — the RTL's
`$readmemh` paths are `../../assets/...`, written for Vivado's `runs/synth_1`.
Run it one level down and the row tables silently load as X, `need_row` becomes
X, and the renderer sits in `ST_ROW_WAIT` forever with `got=0`. That is a bench
setup trap, not an RTL bug, and it cost a debugging cycle.

## What is known, precisely

Row 0, column 0: got `6e80`, expected `6780`.

* `6780` = luma 103 = sampling source x=36. `ax0` for (row 0, cam 0, seg 0) is
  36.81, so at `lx=0` the correct `qx` is 36.
* `6e80` = luma 110 = sampling source x=**37**, which is `qx` for `lx=1`.

So the renderer's first output pixel carries the coordinate of the *second*.
The first six pixels of every row match the golden model under a uniform `+1`
shift.

But it is **not** a uniform shift. Under the best-fit `+1`, row 0 still has
1,818 mismatches out of 3,839. The error is position-dependent:

* first bad indices are **13, 29, 45, 61** — spacing **16** — then contiguous
  from 63 onward.
* 16 is significant: `dax = 15/16 = 0.9375`, so `qx` advances 15 per 16 output
  pixels and stalls at exactly one position in each group of 16. The failures
  sit on that sub-pixel rounding boundary.
* mismatches are spread evenly across position-within-segment (see the
  histogram in the session), so this is **not** a segment-boundary or
  camera-boundary bug and not a ROM addressing bug.

Row starts also misbehave, differently per row, which is a second symptom and
possibly a second cause:

| row | first seen | first golden | trailing black starts |
|---|---|---|---|
| 0 | `6e80` (= gold[1]) | `6780` | 3576 (correct) |
| 1 | `6f80` then `6f80` again (duplicate) | `6880` | 3577 (one late) |
| 2 | `1080` (black — row 1's tail) | `6880` | 3577 (one late) |

Row 2 beginning with row 1's black tail pixel means a pixel leaks across the
row boundary. Suspect the `ST_OUT -> ST_ROW_WAIT -> ST_OUT` transition: the
pipeline holds 6 in-flight pixels when a row ends, and `ST_ROW_WAIT` may be
re-entered and exited faster than the drain.

## Ruled out by inspection

* ROM record decode. Hand-checked: record 0 unpacks to ax0=36.81, ay0=27.94,
  dax=0.9375, day=0, all inside the map's measured 25.9..611.2 x 24.6..465.5
  range.
* Map decode / ROM addressing. The golden model derives the camera split from
  the package geometry independently and agrees with the RTL's if-chain; index
  arithmetic `(sy*6+cam)*SEGS+seg` is identical in both.
* Alignment of `lxa_o[1]` with `rom_a` — both are written by the same clock
  edge from the same `pano_x`, so they are the same stage.

## Next step

Stop inferring and trace. Add to the bench a dump of, for the first ~20 valid
pixels: `pano_x`, `lxa_o[1]`, `rom_a` (ax0/dax), `cxa`, `qxa`, and the stage
each belongs to. Compare against the model's numbers for the same `lx`. The
one-pixel offset at row start and the period-16 rounding errors are probably
the same defect seen from two angles, but that is a guess and should be
confirmed rather than acted on.

Two specific things worth checking first:

1. `clampx`/`clampy` take `c[33:16]` of a signed 34-bit value into a signed
   18-bit temp. Verify the sign handling and that `cx` never exceeds 18 bits
   after the `<<< 12`.
2. `advance` gates the ROM, the caches and the pipeline registers, but the
   `state` transitions in `ST_ROW_WAIT`/`ST_DRAIN` are **not** gated by it.
   That asymmetry is the most likely source of the row-boundary leak.

## Defects already found and fixed while writing this

Recorded because they are the same family — things invisible unless stalled or
at a boundary:

* ROM and line-cache read enables were tied high; the renderer stalls whenever
  its downstream FIFO fills.
* Seam alpha was looked up from `apos[3]`, landing on stage 4 while `va`/`vb`
  land on stage 5 — a one-pixel shift of the whole 29-px ramp.
* `advance` was referenced above its declaration — a silent 1-bit implicit net.
* XPM `ADDR_WIDTH` must equal `clog2(MEMORY_SIZE/WRITE_DATA_WIDTH)`. The IR
  memory is 640 deep (10 bits); inheriting the EO cache's 11 aborts the XPM
  behavioural model at time 0. The EO cache is self-consistent only because
  `clog2(1920) = 11` happens to equal its `AW`.
