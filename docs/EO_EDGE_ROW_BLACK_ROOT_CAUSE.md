# The four black rows at the EO panorama top edge

**Cause: the row-window gate math, not the fold address.** Two constraints bind
the same variable simultaneously and, for the top four rows, exclude each other.

## The contradiction

`EoV19StreamingRendererII1.v`:

```verilog
wire [10:0] gate_need_row = gate_max_row + 11'd2;          // bilinear safety
wire gate_lower_ok = (rows0 >= gate_need_row || ...);      // must wait for this
wire gate_upper_ok = ... (rows0 <= gate_min_row + 11'd62); // residency guard
```

For logical row 0 of the 2026-08-06 EO maps:

```
row_min_y0[0] = 46      row_max_y0[0] = 107      span = 61

must wait until   rows >= 107 + 2  = 109
must also satisfy rows <= 46  + 62 = 108
```

Empty set. The renderer cannot satisfy both, treats the row as an overrun, and
emits black rather than sampling cache rows that may already have been
overwritten -- which is the correct thing for it to do.

## It is exactly four rows, and only at the top

Checked over all 480 entries of the table:

| logical y | min | max | span | need | guard |
|---:|---:|---:|---:|---:|---:|
| 0 | 46 | 107 | 61 | >= 109 | <= 108 |
| 1 | 48 | 109 | 61 | >= 111 | <= 110 |
| 2 | 50 | 111 | 61 | >= 113 | <= 112 |
| 3 | 52 | 113 | 61 | >= 115 | <= 114 |

Rows 0-3 are the **only** rows in the table with no feasible `rows` value, and
61 is the **maximum span anywhere**. The bottom edge is nowhere near it: rows
476-479 span 54, 53, 52, 50 and pass comfortably. The steep top-edge
cylindrical warp is what needs the extra row of cache lifetime.

**The effective rule is `span <= 60`, not `span <= 62`.** The `+2` bilinear
lead is spent out of the same 62-row residency budget, so the usable window is
two rows narrower than the guard constant suggests. Span 61 fails by one row.

## Why it looks like a fold-boundary problem

The 3840x480 logical canvas is folded into 1920x960: physical row y is the
LEFT half of logical row y, physical row 480+y is the RIGHT half. Four blacked
logical rows therefore appear as a black band at the top of each physical half
-- one at the top of the image and one immediately below the fold seam -- which
reads as a separator or fold artifact. The fold address arithmetic is correct
(`fold_jump_fwd/back` are exact for half = 480) and is not involved.

## Fixes, with the arithmetic

Feasibility requires `span + 2 <= guard_offset`.

| option | result | cost |
|---|---|---|
| Guard `+62` -> `+63` | span 61 gives exactly ONE valid `rows` value | zero margin; a single row of sampling skew re-blackens it |
| Guard `+62` -> `+64` | the true ring bound (64 entries hold `[R-64, R-1]`) | removes the deliberate 2-row implementation margin entirely |
| `CACHE_LINES` 64 -> 128 | `rows <= min + 126`, ample margin | ~4 Mbit more BRAM (6 cams x 64 lines x 655 px x 16 bit) |
| Regenerate maps so edge span <= 60 | no RTL change, keeps all margin | needs the top-edge warp requantised |

The last two are the ones that keep real margin. Widening the guard alone
trades a visible defect for a marginal one.
