# EO Panorama V19: FPGA Architecture, Implementation Results, and Hardware Evidence

**Report date:** 2026-07-16  
**Target venue:** IEEE Transactions on Circuits and Systems for Video Technology (TCSVT)  
**Vivado project:** `E:\Xylinx\EO_Panorama_V19_M1`  
**FPGA:** AMD/Xilinx Kintex UltraScale+ `xcku15p-ffve1517-2-i`  
**Tool:** Vivado 2025.2, build 6299465  
**Latest diagnostic bitstream:** generated 2026-07-15 23:18 KST

## 1. Purpose and claim discipline

This document consolidates the algorithm-to-RTL plan, the implemented V19
hardware, Vivado synthesis/implementation results, DDR4 capacity and bandwidth
analysis, USB/HD-SDI observations, and ILA measurements. It is written as a
source for the hardware section of a TCSVT paper.

The report deliberately separates four evidence classes:

- **Measured hardware evidence:** observed after programming the physical
  FPGA, through ILA, DDR4, HD-SDI, or the USB grabber.
- **Implementation evidence:** reported by Vivado from the placed/routed
  design.
- **RTL/model fact:** directly encoded in source files or generated manifests.
- **Analytical estimate:** calculated from dimensions, clock frequencies, and
  interface widths; it is not presented as a measured latency or bandwidth.

The present hardware proves the FPGA processing, memory, output, and diagnostic
infrastructure. It does **not** yet prove a geometrically correct six-camera
stabilized panorama, because the camera manufacturer has confirmed that the EO
camera does not provide synchronized BT.1120 raster output. External triggering
can align sensor exposure while each ISP emits its BT.1120 raster at a different
phase. The current six-input two-line-cache path therefore cannot consume the
six live rasters without an input de-skew stage or raster-genlocked cameras.

## 2. Defensible paper-level conclusions

The following conclusions are supported by the evidence in this report:

1. A six-input fixed-point YUV422 V19 panorama datapath has been synthesized,
   placed, routed, converted to a bitstream, and programmed on the target
   Kintex UltraScale+ FPGA.
2. The programmed system accepts real EO video, exercises the RowRun/cache
   renderer, transfers frames through external DDR4, generates a BT.1120/HD-SDI
   raster, and is observable through a USB grabber and on-chip ILAs.
3. A phase-aligned diagnostic in which camera 0 feeds all six renderer lanes
   produces source-derived imagery across the panorama layout. This isolates
   the remaining real-six-camera failure from the DDR folding and output chain.
4. ILA measurements show that the six physical camera output rasters are not
   line/frame aligned. The latest STROBE-derived trigger experiment measured a
   follower frame-start span of approximately 16.002--16.007 ms, equivalent to
   540.06--540.24 nominal 1080p line periods, and a simultaneous row-counter
   spread of 776--777 rows.
5. The no-stabilization geometry package is reproducible: two Q16.16 base maps,
   two alpha LUTs, a versioned RowRun index, and 1,502,118 packed RowRun records
   have fixed dimensions and SHA-256 hashes.
6. The shared V19 memory organization is sized by the six-camera EO panorama,
   which is the worst-case supported mode. The other panorama and single-camera
   modes can reuse the same memories with fewer active lanes, bypassed blending,
   and reduced address bounds; they do not require parallel duplication of the
   EO-panorama memory system.
7. At the currently configured DDR4 rate, the conservative verified payload
   ceiling is about 7.468 GB/s. Even a deliberately pessimistic DDR de-skew
   extension remains below 35% of that ceiling at 30 frame/s.

Claims that are **not** yet supported are listed in Section 14.

## 3. Algorithm and deployment boundary

### 3.1 Milestone-1 algorithm

The first V19 hardware milestone implements EO panorama without stabilization,
corresponding to C-model mode `0x03`:

- six EO camera inputs;
- native packed YUV422/YCbCr 4:2:2 video;
- logical panorama size `3840 x 480`;
- fixed-point map coordinates and bilinear sampling;
- 49-pixel luma overlap target with separate luma/chroma alpha LUTs;
- fold-on-write into an HD deployment raster;
- double-buffered DDR output and BT.1120/HD-SDI scan-out.

The C/C++ implementation is the numerical reference and asset generator. It is
not a static image source for the FPGA. Live camera pixels must pass through the
hardware sampler, blender, row retirement, push buffering, DDR writer, and
output reader for every frame.

### 3.2 Verified geometry

The regenerated map package and RTL parameter header agree on:

| Parameter | Value |
|---|---:|
| EO input raster | `1920 x 1080` per camera |
| Resize used by calibration model | `960 x 540` |
| Crop | `696 x 378` at `(132,81)` |
| Per-camera panorama heights | 378 rows |
| Per-camera widths | `{680,681,681,681,681,681}` |
| Target overlap | 49 pixels |
| Vertical panorama padding | 51 rows above and below content |
| Logical output | `3840 x 480` |

The horizontal identity is:

```text
680 + 5*681 - 5*49 = 3840 pixels.
```

### 3.3 Fixed-point and YUV422 contracts

- Base X/Y coordinates are little-endian signed Q16.16 integers.
- RowRun starting coordinates are signed Q16.16.
- RowRun increments are signed Q12.4 and are promoted to Q16.16 by a 12-bit
  left shift.
- A packed RowRun record is 18 bytes:
  `uint16 sy`, `uint16 ox0`, `uint16 len`, `int32 ax0_q16`,
  `int32 ay0_q16`, `int16 dax_q12_4`, `int16 day_q12_4`.
- The hardware pixel word is 16 bits, carrying one luma and one alternating
  chroma byte. Neutral black is `16'h1080` (`Y=0x10`, `C=0x80`).
- Luma and chroma feathering use different Q0.16 LUTs because chroma operates
  on YUV422 pairs.

## 4. Intended streaming architecture

The full V19 dataflow is:

```text
6 EO BT.1120/YUV422 inputs
  -> per-camera ingress and frame/row epoch tracking
  -> per-camera source-row caches
  -> six source-row RowRun buckets/render lanes
  -> six preblend placeholders
  -> deterministic camera-order Y/C feather merge
  -> one shared 180-row destination RowWindow
  -> two 32-row logical panorama push buffers
  -> 3840x480 to 1920x1080 fold/black-pad formatter
  -> inactive DDR frame bank writer
  -> opposite DDR frame bank reader
  -> BT.1120/HD-SDI and USB grabber.
```

Configuration is intended to be MCU-controlled. Geometry, seams, blend enable,
alpha tables, crop, output layout, and stabilization pose are written to shadow
registers and committed atomically at a frame boundary. Static assets are
loaded from QSPI or JTAG at startup, checked by version and CRC/hash, and placed
in DDR/BRAM.

For stabilization, each camera receives frame-pose parameters
`c15_i`, `s15_i`, and `Delta_y_i`. These change source coordinates and therefore
the RowRun schedule. Full stabilized RowRuns cannot be precomputed once at
startup; they must be generated per frame or per active source bucket from the
base maps. The full precomputed RowRun package is valid only for static
identity/no-stabilization operation.

### 4.1 Planned-versus-implemented status

The latest bitstream is an integration/diagnostic prototype, not yet the final
production realization of every block in the plan:

| Architectural block | Latest integrated status | Evidence level |
|---|---|---|
| Six EO decoders and physical camera inputs | implemented | hardware/ILA |
| Camera trigger/STROBE monitor | implemented for diagnosis | hardware/ILA |
| Per-camera asynchronous raster de-skew | not implemented | required for current cameras |
| Source-row cache | implemented as 64-line tagged diagnostic cache | RTL/hardware |
| Final two-line cache contract | planned after de-skew/genlock | architecture |
| Base-map and alpha asset package | generated and hashed | model/artifact |
| Full 27 MB static RowRun pool/index | generated and hashed | model/artifact |
| DDR reader for full static RowRun pool | not integrated | planned |
| Compact 24,948-record schedule ROM | implemented | synthesis/hardware |
| Six-lane fixed-point sampler | implemented | synthesis/hardware |
| Y/C alpha blend arithmetic | implemented, not golden-pixel accepted | RTL |
| Six preblend placeholders | represented by pipelined sample/valid/weight state | RTL |
| Shared `ACTIVE_BUFFER=180` RowWindow | parameterized/planned, not instantiated in live path | architecture |
| Two `PING_PONG_PUSH_BUFFER=32` row buffers | parameterized/planned; current build uses pixel FIFO/packer | architecture |
| `3840x480` fold to `1920x960` | implemented | hardware/USB |
| DDR inactive-bank writer/opposite-bank reader | implemented | hardware/ILA/USB |
| Rows 960--1079 black padding | generated during HD scan-out | hardware/USB |
| Sixteen-mode V19 mode descriptor/control | designed, not fully integrated/validated | architecture |

Consequently, the placed resource table in Section 11 characterizes the latest
diagnostic implementation. The 1.92 MB RowWindow/push-buffer budget in Section
7 characterizes the final shared-memory architecture.

## 5. Sixteen-mode shared-memory architecture

The architectural mode set contains 16 active video modes:

| Class | Mode values | Cameras | Dynamic schedule | Blend |
|---|---|---:|---|---|
| EO panorama stabilized | `0x01` | 6 | yes | yes |
| IR panorama stabilized | `0x02` | 6 | yes | yes |
| EO panorama no stabilization | `0x03` | 6 | no/static | yes |
| IR panorama no stabilization | `0x06` | 6 | no/static | yes |
| EO single-camera undistort | `0x07`--`0x0C` | 1 of 6 | no/static | bypass |
| IR single-camera undistort | `0x0D`--`0x12` | 1 of 6 | no/static | bypass |

EO panorama is the memory worst case because it simultaneously activates six
source lanes, the widest logical output, all overlap placeholders, blending,
the shared destination RowWindow, and both 32-row push buffers. The architecture
does not allocate separate full memory systems per mode:

- single-camera modes use one cache/render lane and bypass the five-camera
  merge path;
- panorama modes share the same six lanes and common RowWindow;
- the same push buffers and DDR frame banks serve all output layouts;
- mode descriptors change address bounds, map selection, camera count, blend
  enable, crop, fold, and black-padding behavior;
- a mode transition is accepted at SOF so an in-flight frame is not torn.

This is an architectural reuse claim. The current diagnostic bitstream has not
yet been used to validate all 16 algorithmic modes on hardware.

## 6. Map, LUT, and RowRun evidence

### 6.1 Runtime base package

| Asset | Bytes | Interpretation |
|---|---:|---|
| `eo_base_x_q16.bin` | 1,029,672 | 257,418 signed Q16.16 X entries |
| `eo_base_y_q16.bin` | 1,029,672 | 257,418 signed Q16.16 Y entries |
| `eo_blend_alpha_y_q16_lut.bin` | 98 | 49 luma weights |
| `eo_blend_alpha_c_q16_lut.bin` | 48 | 24 chroma weights |
| **Base-map/LUT package** | **2,059,490** | loaded once at startup |

The base maps contain `681 x 378 = 257,418` coordinates per axis. Intermediate
undistortion/cylindrical construction maps are PC-side calibration artifacts;
they are not required by the milestone-1 runtime datapath.

### 6.2 Full no-stabilization RowRun package

| Artifact | Count | Bytes |
|---|---:|---:|
| RowRun records | 1,502,118 | 27,038,124 |
| RowRun index entries | 6,474 | 51,792 |
| Row-retirement entries | 378 | 756 |
| **Total static schedule package** |  | **27,090,672** |

The index is `6 x 1079` entries. Each entry contains a 32-bit record offset and
a 32-bit count. The measured peak bucket contains 628 RowRuns, or 11,304 bytes
of packed records for one `(camera,y0)` key. These are control/schedule records,
not panorama pixels.

### 6.3 Compact currently implemented ROM

The current renderer uses `24,948 = 6 x 378 x 11` 144-bit affine records, one
record per 64-pixel segment, plus 378-entry row-min and row-max tables. This ROM
was introduced to bring up the real streaming renderer without requiring a
27 MB schedule reader. It is useful hardware evidence, but it is an
approximation and is not yet accepted as bit-exact to the C model. A final
paper-quality implementation must either validate its coordinate error bound
against the C oracle or replace it with the true source-row bucket schedule.

## 7. Memory footprint

### 7.1 Planned worst-case on-chip working memory

| Structure | Formula | Bytes |
|---|---:|---:|
| Six two-line YUV422 caches | `6*2*1920*2` | 46,080 |
| Shared active RowWindow | `180*3840*2` | 1,382,400 |
| Two 32-row panorama push buffers | `2*32*3840*2` | 491,520 |
| **Core pixel-storage subtotal** |  | **1,920,000** |

The subtotal excludes small metadata, alpha LUTs, schedule bucket storage,
FIFOs, BRAM/URAM width rounding, the DDR controller, and ILA memory. The C model
reported approximately 1.84 MiB after its own packing assumptions, equivalent
to approximately 53 URAM288 blocks. The target `xcku15p` provides 128 URAMs, so
the shared-memory form is feasible without six full destination RowWindows.

The current diagnostic RTL intentionally uses 64 cached source lines per
camera, not the final two-line cache, to investigate raster phase and residency.
Those six caches alone hold `6*64*1920*2 = 1,474,560` raw bytes before memory
primitive rounding.

### 7.2 Output frame memory

A full packed YUV422 `1920 x 1080` frame requires:

```text
1920*1080*2 = 4,147,200 bytes.
```

Two full ping-pong banks require 8,294,400 bytes. The current implementation
stores the `1920 x 960` folded active region and synthesizes rows 960--1079 as
black during scan-out, using 3,686,400 bytes per bank and 7,372,800 bytes for
two banks. Reserving the full 1080-row banks is preferred in the general
multimode address map because it makes every mode use the same stride.

### 7.3 External static assets

The two base maps, alpha LUTs, full RowRun pool, index, and retirement table
together occupy 29,150,162 bytes. This is small relative to the active DDR
capacity and is suitable for a versioned QSPI/JTAG startup package.

## 8. DDR4 configuration, capacity, and bandwidth

### 8.1 Device and implemented controller

The board uses Micron `MT40A512M16TB-062E` devices. Micron specifies each device
as 8 Gb, `512M x 16`, 1.2 V, and capable of 3200 MT/s. The current Vivado MIG
configuration is deliberately below the component maximum:

| MIG property | Routed build value |
|---|---:|
| Physical data width | 48 bits |
| DDR time period | 1.071 ns |
| Effective transfer rate | approximately 1867 MT/s |
| PHY/UI ratio | 4:1 |
| UI clock | 233.380 MHz |
| UI data width | 384 bits |
| Input reference clock | 200.040 MHz |

The x48 controller uses three x16 components in parallel, giving 3 GiB nominal
addressable capacity. Hardware investigation identified the UI slice
`app_data[383:256]`, corresponding to one x16 component across BL8, as
unreliable. The verified image path therefore carries useful data only in
`app_data[255:0]` and writes zeros to the upper 128 bits. This yields an
effective robust image width of 32 physical bits and approximately 2 GiB of
useful capacity at the same row/column depth. The capacity still exceeds the
complete V19 asset and frame allocation by a wide margin.

Micron part reference: <https://www.micron.com/products/memory/dram-components/ddr4-sdram/part-catalog/part-detail/mt40a512m16tb-062e-r>

### 8.2 Peak bandwidth

Physical pin-rate peak:

```text
48 bits * 1.86704e9 transfers/s / 8 = 11.202 GB/s.
```

Conservative verified payload ceiling, accounting for the 256 useful bits in
each 384-bit UI beat:

```text
256 bits * 233.380e6 cycles/s / 8 = 7.468 GB/s.
```

These are interface ceilings, not measured sustained application bandwidth.
Refresh, row activation, arbitration, command bubbles, and read/write turnarounds
reduce achievable sustained bandwidth. The V19 budget below is therefore
compared with the lower 7.468 GB/s ceiling.

### 8.3 Required useful bandwidth at 30 frame/s

| Traffic component | Useful bandwidth |
|---|---:|
| Six full YUV422 camera frames, one direction | 746.496 MB/s |
| Full 1080p output bank write + read | 248.832 MB/s |
| Current 960-row output bank write + read | 221.184 MB/s |
| Full static RowRun pool read once per frame | 811.144 MB/s |
| RowRun index read once per frame | 1.554 MB/s |
| Base-map pair read once per stabilized frame | 61.780 MB/s |

The synchronized-camera architecture keeps source pixels on chip, so its
conservative static-schedule total is:

```text
output write/read + RowRuns + index
= 248.832 + 811.144 + 1.554
= 1,061.529 MB/s, or 14.2% of 7.468 GB/s.
```

If non-genlocked cameras require per-camera DDR raster de-skew, a deliberately
pessimistic budget writes and rereads all six input frames:

| De-skew case | Total | Fraction of verified ceiling |
|---|---:|---:|
| Static no-stabilization schedule | 2,554.521 MB/s | 34.2% |
| Dynamic stabilization using base maps | 1,803.604 MB/s | 24.2% |

The two cases are mutually exclusive: no-stabilization consumes the full static
RowRun schedule, while stabilization consumes the base maps and dynamically
generates its active schedule. The calculations conservatively assume complete
input-frame reads; a row-selective renderer can use less. The measured DDR
configuration therefore has sufficient bandwidth headroom for either a
genlocked two-line design or a DDR de-skew extension.

## 9. Throughput

### 9.1 Renderer

`EoV19StreamingRendererII1` is pipelined for initiation interval `II=1`: after
pipeline fill, it can accept/emit one packed YUV422 panorama pixel per 233.380
MHz UI clock when downstream `ready` remains asserted.

Peak renderer throughput:

```text
233.380 Mpixel/s = 466.760 MB/s of packed 16-bit YUV422.
```

The logical panorama contains 1,843,200 pixels, so the no-stall service time is:

```text
1,843,200 / 233.380e6 = 7.898 ms.
```

The required logical panorama rate at 30 frame/s is 55.296 Mpixel/s, so the
ideal pixel-rate utilization is 23.7%. This margin covers row waits, FIFO
backpressure, and DDR command gaps, provided that source rows are resident.

### 9.2 DDR frame traffic

The packer places 16 packed pixels in each useful 256-bit payload. The active
`1920 x 960` folded panorama contains 115,200 useful beats. At an ideal one
accepted UI beat per cycle, its DDR transfer floor is 0.494 ms per direction.
A full `1920 x 1080` frame contains 129,600 beats and has a 0.555 ms floor.

In the actual streaming path, the renderer supplies one pixel per cycle and
the packer produces one beat every 16 pixel cycles. Therefore the renderer,
not DDR pin bandwidth, determines the no-stall panorama service time.

### 9.3 Source-row deadline

For a nominal 74.25 MHz, 2200-clock 1080-line timing raster:

```text
one line = 2200 / 74.25e6 = 29.63 us
two lines = 59.26 us.
```

In the intended source-driven architecture, all RowRuns belonging to source
row pair `(y,y+1)` must consume that pair before it is overwritten. The six
camera lanes operate in parallel, and the shared RowWindow decouples destination
row completion order from the source-row deadline. `ACTIVE_BUFFER=180` is a
destination-row lifetime bound; it does not compensate for hundreds of rows of
camera raster phase difference.

## 10. Latency

Latency must be reported at explicit boundaries. A single number would mix
camera ISP delay, source-row arrival, FPGA processing, DDR bank phase, and
display scan position.

### 10.1 Deterministic FPGA components

| Component | Value | Status |
|---|---:|---|
| One nominal source line | 29.63 us | analytical |
| Two-line source window | 59.26 us | analytical |
| II=1 full logical panorama service | 7.898 ms | analytical from routed UI clock |
| Fill 32 logical rows at II=1 | 0.527 ms | analytical upper fill interval |
| Ideal active-bank DDR transfer floor | 0.494 ms/direction | analytical; overlapped |
| Output bank publication phase at 30 Hz | 0--33.33 ms | architectural bound |

The 32-row fill time is not fully additive to the 7.898 ms renderer time; push
buffer fill, DDR writes, and rendering overlap. Likewise, the ideal DDR floor
is not a measured transfer latency.

### 10.2 Synchronized-input architecture

Once the required source row is available, the renderer can complete a logical
frame in approximately 7.9 ms without stalls. The visible output then waits for
the safe inactive-to-active DDR bank swap. Depending on the phase at which the
copy finishes, this adds between nearly zero and one 30-Hz frame period, with an
average phase wait of approximately 16.67 ms.

Source-row availability adds a content-dependent delay because each output row
has a maximum required source `y0`. That delay is bounded by the input raster
schedule and is not included in the 7.9 ms service time. Camera exposure-to-data
ISP latency has not been measured and must not be folded into an FPGA-only
latency claim.

### 10.3 Asynchronous-raster extension

The manufacturer-confirmed lack of synchronized BT.1120 output requires either
raster-genlocked cameras or a per-camera de-skew layer. A robust de-skew design
writes each camera into an independently clocked DDR ring, tags frames with a
trigger/frame epoch and SOF timestamp, and reads a common epoch into the small
RowRun caches. This adds at least the selected de-skew margin and normally one
frame of deterministic buffering. It does not alter the renderer's II=1
throughput and fits the bandwidth budget in Section 8.

Until that stage is implemented, a measured sensor-to-HD-SDI panorama latency
cannot be claimed.

## 11. Latest synthesis and implementation results

### 11.1 Synthesis

The latest integrated STROBE-derived, 2-ms follower-trigger diagnostic build
completed synthesis with:

| Result | Value |
|---|---:|
| Errors | 0 |
| Critical warnings | 0 |
| Reported synthesis warnings | 125 |

The dominant warnings note that optional output registers could not be merged
into some line-cache BRAM instances, which is consistent with the small setup
shortfall later seen on the DDR UI clock.

### 11.2 Placed resource utilization

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| CLB LUTs | 24,846 | 522,720 | 4.75% |
| LUTs as logic | 21,906 | 522,720 | 4.19% |
| LUTs as memory | 2,940 | 161,280 | 1.82% |
| CLB registers | 27,965 | 1,045,440 | 2.67% |
| CLBs | 6,296 | 65,340 | 9.64% |
| Block RAM tiles | 533 | 984 | 54.17% |
| RAMB36/FIFO36 | 531 | 984 | 53.96% |
| RAMB18 | 4 | 1,968 | 0.20% |
| URAM | 0 | 128 | 0% |
| DSP48E2 | 19 | 1,968 | 0.97% |
| Bonded I/O | 281 | 512 | 54.88% |
| BUFGCE | 11 | 280 | 3.93% |
| PLL | 3 | 22 | 13.64% |
| MMCM | 1 | 11 | 9.09% |

These totals include the DDR4 controller/PHY, six camera interfaces, IR and
legacy mode infrastructure retained in the common top level, FIFOs, two ILAs,
the 64-line diagnostic caches, the compact render ROM, and the HD output path.
They are not the area of the V19 arithmetic core alone.

### 11.3 Routing, DRC, and timing

Routing completed for all 62,652 routable nets, with zero unrouted nets and
zero routing errors. Bitstream DRC completed with zero errors, and
`write_bitstream` completed successfully.

Latest routed timing:

| Metric | Value |
|---|---:|
| WNS | -0.081 ns |
| TNS | -2.758 ns |
| Failing setup endpoints | 59 of 91,193 total setup endpoints |
| WHS | +0.011 ns |
| THS | 0 ns |
| Failing hold endpoints | 0 |
| WPWS | +0.022 ns |
| TPWS | 0 ns |

All reported setup failures are in the 233.380 MHz DDR UI clock group
`mmcm_clkout0`; the camera and input system-clock groups have positive setup
slack. The latest diagnostic bitstream is therefore fully routed and
programmable but **not timing-closed**. Its setup deficit is 0.081 ns against a
4.285 ns period, approximately 1.9% of the UI period.

An earlier, less-instrumented camera-edge V19 build closed timing with WNS
`+0.019 ns`, TNS `0`, WHS `+0.011 ns`, and zero setup/hold failures. This proves
that the architecture can reach the target clock, but it must not be substituted
for the latest build's negative timing result in a final implementation table.

### 11.4 Power estimate

Vivado's vectorless routed estimate reports 3.505 W total on-chip power
(2.366 W dynamic and 1.139 W static). The report marks confidence **Low**;
therefore this number is suitable only as a preliminary engineering estimate,
not a measured TCSVT power result.

## 12. Hardware evidence

### 12.1 Programming and observability

- The latest bitstream programmed successfully over JTAG.
- Vivado reported FPGA startup status `HIGH`.
- Hardware Manager detected two ILA cores and one MIG core.
- The post-program message that DDR calibration was still in progress was
  emitted immediately after configuration; later ILA triggers and video
  captures demonstrate an operating design. Earlier DDR bring-up experiments
  separately recorded successful calibration and sustained frame traffic.

### 12.2 Known-good output/memory control

The pre-V19 EO-stack control bitstream produced all six camera tiles in color
through the same physical DDR, BT.1120/HD-SDI, and USB0 chain. A direct USB
capture stored three nonuniform `1920 x 1080` frames with all six sources
visible. This is the control that isolates the V19 source-row renderer from the
already working board-level memory and output path.

### 12.3 Phase-aligned V19 renderer proof

With diagnostic `V19_DIAG_REPLICATE_CAM0=1`, camera 0 was deliberately connected
to all six V19 renderer lanes. Eight USB frames were captured; all eight were
classified as real/nonuniform rather than diagnostic frames, and visible
camera-derived content occupied the repeated panorama spans. This proves that
the following chain is live when source-row phases agree:

```text
line cache -> compact RowRun coordinate path -> bilinear/preblend pipeline
-> fold/write -> DDR ping-pong -> HD reader -> USB grabber.
```

This diagnostic is not a six-camera panorama and is not an image-quality result.
The build retained cache-miss substitution and did not meet timing, so its
periodic artifacts are not evidence of final algorithm quality.

### 12.4 Real six-camera phase evidence

With the real six lanes enabled, earlier V19 ILA data showed:

```text
rows_min = 227
rows_max = 971
spread   = 744 rows.
```

That is far beyond the 64-line diagnostic cache, the final two-line cache, and
the 180-row destination RowWindow. A start-alignment gate correctly refused to
begin a pass when the cameras were in incompatible raster phases.

### 12.5 Common-trigger and STROBE-derived experiments

Two experiments removed ambiguity about the FPGA trigger route:

1. A common FPGA-generated pulse was sent to the five follower trigger inputs.
   The follower output rasters remained separated by roughly 147 rows in the
   simultaneous row snapshot and up to about 150 nominal lines in the corrected
   frame-start measurement.
2. The latest build synchronized camera-1 `STROBE_OUT0` into the FPGA, detected
   its edge, and stretched it to a 2-ms active-high pulse sent to physical
   cameras 2--6. All five followers were seen, but their BT.1120 frame starts
   spanned:

```text
1,188,141 to 1,188,522 clocks at 74.25 MHz
= 16.0019 to 16.0070 ms
= 540.06 to 540.24 nominal 2200-clock line periods.
```

The row counters captured on the STROBE-derived edge were approximately:

```text
[1047, 810, 320, 559, 271, 813]
```

with 776--777 rows of spread over repeated captures. The corrected decoder
interprets Vivado ILA CSV fields as hexadecimal; treating them as decimal had
previously produced incorrect smaller spans.

The board schematic and XDC were also cross-checked: camera 1 provides
`STROBE_OUT0`, while FPGA outputs `TRIG_IN1..5` drive physical cameras 2--6.
No FPGA-controlled trigger input exists for physical camera 1 on the current
schematic.

### 12.6 Manufacturer confirmation

The camera manufacturer has stated that the camera does not support synchronized
BT.1120 output and that the measured output timing is therefore expected.
This reconciles the hardware observations: exposure can be externally
triggered, yet ISP processing and raster emission remain independently phased.
The trigger-level shifter and board trace delays cannot explain stable
millisecond-scale raster offsets, and the same result under an FPGA-generated
common trigger rules out camera-1 STROBE generation as the principal cause.

## 13. Required architecture completion

Two valid completion paths remain:

### 13.1 Use raster-genlocked cameras

If camera hardware with synchronized BT.1120/parallel raster output is adopted,
the intended two-line source-driven design remains valid. The trigger/strobe
epoch still provides frame association, while all six line caches advance within
the allowable two-line window.

### 13.2 Add asynchronous raster capture and DDR de-skew

For the current cameras, add this stage ahead of the V19 caches:

```text
per-camera BT.1120 decoder
  -> async FIFO / independent clock-domain writer
  -> per-camera DDR frame or row ring
  -> {trigger epoch, SOF timestamp, frame index, row count} metadata
  -> common-epoch read scheduler
  -> small two-line renderer caches.
```

This converts six independent raster phases into a common logical frame without
changing the map, blending, shared RowWindow, push buffers, or HD-SDI output
architecture. Section 8 shows that the current DDR interface has sufficient
bandwidth for a conservative full-frame de-skew implementation.

Additional completion items independent of camera synchronization are:

- restore strict black/stall behavior on every line-cache tag miss;
- remove the active diagnostic cache-hit bypass;
- validate YUV422 pair-phase chroma sampling;
- validate the compact 64-pixel schedule against the C model or replace it with
  the full source-row bucket schedule;
- pipeline the remaining 233.380 MHz setup paths until WNS and TNS are nonnegative;
- run and archive stage-level and end-to-end golden-vector regressions;
- validate all 16 modes and atomic MCU register updates on hardware.

## 14. Claims not yet permitted in the paper

Do not currently state that:

- a correct six-camera stabilized panorama has been demonstrated on hardware;
- the six EO BT.1120 rasters are synchronized by `STROBE_OUT/TRIG_IN`;
- the latest integrated design meets all timing constraints;
- the compact render ROM is bit-exact to the C V19 RowRun algorithm;
- final YUV422 chroma interpolation and feather blending have passed a golden
  pixel comparison;
- all 16 modes have been implemented and validated in the latest bitstream;
- the 3.505 W Vivado value is measured power;
- 7.468 GB/s is measured sustained DDR bandwidth;
- sensor-to-display latency has been measured.

## 15. TCSVT-ready wording

### 15.1 Supported implementation paragraph

> The proposed fixed-point streaming architecture was prototyped on a Kintex
> UltraScale+ XCKU15P FPGA using Vivado 2025.2. The instrumented six-input design
> occupied 24,846 LUTs (4.75%), 27,965 registers (2.67%), 533 BRAM tiles
> (54.17%), and 19 DSP48E2 blocks (0.97%); the BRAM count includes six enlarged
> 64-line diagnostic caches, the DDR4 controller, FIFOs, compact map/schedule
> ROMs, and ILA storage. The routed design used a 233.38-MHz, 384-bit DDR4 user
> interface. Its latest diagnostic build was fully routed and passed bitstream
> DRC, with WNS/TNS of -0.081/-2.758 ns confined to 59 setup endpoints; an
> earlier less-instrumented renderer build closed at +0.019 ns WNS.

### 15.2 Supported bandwidth paragraph

> The implemented x48 DDR4-1867 interface provides an 11.20-GB/s physical peak.
> Because the verified image path conservatively uses 256 of each 384 user-interface
> bits, the corresponding useful ceiling is 7.47 GB/s. At 30 frame/s, output
> frame ping-pong plus a complete static RowRun fetch requires approximately
> 1.06 GB/s. A conservative extension that writes and rereads all six asynchronous
> camera frames requires approximately 2.55 GB/s, retaining more than 65% of the
> verified payload ceiling for refresh, arbitration, and access inefficiency.

### 15.3 Supported hardware-validation paragraph

> Hardware experiments verified DDR4 frame transfer, BT.1120/HD-SDI scan-out,
> USB capture, and source-derived output from the V19 RowRun/cache renderer when
> all six lanes were driven from a phase-aligned source. With six physical
> cameras, ILA measurements instead showed output-raster phase spreads up to
> 776--777 rows and approximately 16.0 ms among triggered followers. The camera
> manufacturer independently confirmed that synchronized BT.1120 output is not
> supported. Consequently, the current camera set requires an asynchronous
> raster de-skew buffer before the proposed two-line RowRun cache; this is an
> input-interface constraint rather than a limitation of the geometric mapping
> or shared-memory renderer.

## 16. Reproducibility and evidence index

### 16.1 Primary reports and source

- `src/EoV19PanoramaParams.vh` -- geometry, buffer depths, beat widths.
- `src/EoV19LineCache.v` -- 64-line tagged diagnostic cache and epoch tracking.
- `src/EoV19StreamingRendererII1.v` -- II=1 renderer and compact schedule path.
- `src/PanoramaBase_DdrBlackFrame.v` -- x48 MIG integration, payload guard,
  frame-bank arbitration, fold/write/read, and output renderer.
- `assets/rowruns/eo_v19_startup_rowruns_manifest.json` -- geometry, counts,
  formats, and source hashes.
- `docs/EO_PANORAMA_V19_IMPLEMENTATION_STATUS.md` -- initial milestone status.
- `docs/CODEX_HANDOFF_V19_SYNC_BLOCKER_AND_CAM0REP_PROOF_20260715.md` --
  phase-aligned renderer proof and real-lane blocker.
- `docs/V19_TRIGGER_SYNC_ANALYSIS_20260715.md` -- independent trigger/ILA analysis.
- `scripts/decode_v19_trigger_sync.py` -- corrected hexadecimal CSV decoder.

### 16.2 Latest build artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `.bit` | 18,505,119 | `f4e959539561ccf1589623d10518fd69de4b2b4487ff9f35ac9be4b2f1e6c3af` |
| `.ltx` | 183,632 | `7992cd2b3aaaa83b3236929c9116ff8aeeefbfc07d2863fec46d40752c60d67f` |
| Routed timing report | 5,783,772 | `689e7da44cc496ab8a69ccd0ae601cfa48f697ab69bc7da01805776f30f99d1b` |
| Placed utilization report | 15,226 | `d329580fd1599d076b84e4e18bd8dc88911f5377aeabb553d875ad165aa9f735` |
| Compact render ROM text | 923,076 | `da998e9bdc59566563fe194bb5096d49893e631ee3f4790c46fab3b915ea9e82` |
| Full RowRun data | 27,038,124 | `5b717955f269ef2f277f06d9c2fa75599d09595134097be6d6459393a87eee38` |

### 16.3 Relevant capture sets

- `captures/usb0_control_eostk` -- known-good six-tile DDR/output control.
- `captures/usb0_v19_cam0rep` -- phase-aligned six-lane V19 renderer proof.
- `captures/usb0_v19_camedge` -- real-camera source-renderer artifact evidence.
- `captures/usb0_v19/ila_fpga_trigger_followers_00.csv` through `_05.csv` --
  follower frame-start spans.
- `captures/usb0_v19/ila_strobe_edge_00.csv` through `_05.csv` -- per-camera row
  counters at the STROBE-derived trigger edge.

## 17. Final assessment

The hardware evidence is sufficient to report a real FPGA implementation of
the V19 fixed-point sampling/blending pipeline and shared DDR output
architecture, its diagnostic-build resource cost, its clock rate, its
analytical throughput and bandwidth margins, and a carefully bounded validation
result. The final shared RowWindow and 32-row push-buffer organization remains a
capacity-verified production architecture rather than a block implemented in
the latest diagnostic bitstream. The strongest scientific conclusion is
not that the complete six-camera stabilized panorama is already finished; it is
that hardware experiments isolated the remaining system-level constraint to
unsynchronized camera output rasters and quantified it directly.

The shared memory architecture remains valid for all 16 modes. EO panorama is
the worst case, and the other modes reuse the same source caches, schedule
storage, shared RowWindow, push buffers, and frame banks. For the current
cameras, the necessary next block is an asynchronous BT.1120 capture/de-skew
layer. Its conservative bandwidth demand fits the implemented DDR4 interface,
so this correction changes latency and frame ownership but does not invalidate
the V19 renderer or its multimode memory-sharing argument.
