# V19 panorama: a camera that is powered back on never rejoins

**Status 2026-08-02.** Reproducible, isolated, instrumented, **not fixed**.
Everything below was measured on hardware, not inferred.

---

## 1. The problem

Six EO cameras feed a DDR-de-skewed panorama. Powering one camera **down** is
handled correctly. Powering it **back up** is not: that camera never rejoins,
and in the more severe variant the whole raster collapses to green and only a
JTAG reprogram recovers it.

Reproduced on camera 4 and independently on camera 1, so it is not
camera-specific.

## 2. What is already fixed (do not re-litigate)

Committed on `main`: `ad5f171`, `5d09137`, `b41b790`.

| Defect | Fix | Evidence |
|---|---|---|
| Epoch counted in each camera's own pixel-clock domain, so a dark camera fell behind for ever | Count once in `ui_clk`, broadcast Gray-coded (`v19_global_epoch` in `PanoramaBase_DdrBlackFrame.v`) | offset was unbounded; now 0 |
| `trigger_pending` offset the epoch and never drained (warm-up backlog is a fixed point at equal trigger/frame rates) | A frame consumes **two** queued triggers while behind | measured offset 11 → **0** |
| Presence meant "pixel clock running" (row counter), and `activity_pulse` was wired to undeclared symbols so it was constant 0 | Presence judged from the completion descriptor, 300 ms timeout | a non-publishing camera is now shed instead of wedging everything |
| All six cameras' beats in one DRAM bank (all bases ≡ 0 mod 128; bank bits are `app_addr[6:3]`) | `V19_SRC_CAM_STRIDE` 4147200 → 4147208, banks 4..9 | `app_rdy` 21%→58%, replay grant 6.9%→28.0% |

Net effect: **the crash is gone.** A camera going away leaves its tile black
with the other five live, and the panorama keeps running.

## 3. The remaining failure, precisely

Measured with camera 1 (`captures/usb0_v19/ila_cam_on_crash_c1_20260802_204349.csv`):

```
cam_present            111101      camera 1 shed (correct)
free_ready             111111      all FREE-token FIFOs ready
lease_valid            2048/2048   manager leasing on the other five
state                  WAIT
descriptor_collision_seen 0
descriptor_valid_map   cam0:1101 cam1:0000 cam2:1101 cam3:1101 cam4:1101 cam5:1101
cam0 - cam4 epoch offset  0        <- epoch machinery is correct now
capture FIFO peaks     all six pinned at 1024 (= FIFO_PROG_FULL_THRESH)
```

**The returning camera publishes no completion descriptor, ever.** Everything
else behaves. The epoch fix is working (offset 0), the manager sheds the
camera correctly and keeps the panorama alive on five.

### Hypotheses already eliminated

- **Epoch divergence.** Fixed; offset is 0 and cam0/cam4 agree exactly.
- **Token loss / needs re-seeding.** *Disproved.* A re-seed was implemented
  (clear `seeded[n]` when a camera is absent with an empty ring). It latched
  `descriptor_collision_seen = 1` immediately and drove the raster green,
  which proves the writer **still privately owns its bank**. Reverted; do not
  retry this without first proving the writer has released the bank.
- **Presence misjudged.** Fixed; `cam_present` correctly reads 0 for the
  returning camera because it genuinely publishes nothing.
- **Manager deadlock.** No: `lease_valid` is high and `state` is `WAIT`.

### The surviving hypothesis (unverified)

The writer is stuck in its retry loop in `src/EoV19DdrDesync.v`. At
`frame_start` it publishes only via

```verilog
if (frame_seen && !drop_frame && have_bank) begin ... publish ... end
else if (have_bank) begin            // retry path
    if (!fifo_prog_full && !fifo_full && frame_epoch_available)
        drop_frame <= 1'b0;
    else
        drop_frame <= 1'b1;
end
```

and mid-frame the soft watermark re-arms it:

```verilog
end else if (!drop_frame && have_bank && fifo_prog_full && cam_active &&
             (pix_x < `EO_V19_INPUT_W)) begin
    drop_frame <= 1'b1;     // stop accepting this frame
```

If that camera's capture FIFO reaches `prog_full` mid-frame on every frame,
`drop_frame` is set again before the frame completes, no marker is emitted,
the bank is rewritten from row zero next frame, and the cycle repeats for
ever — burning full write bandwidth for a frame that is never published. All
six FIFO peaks pinned at 1024 is consistent with this.

**This is a hypothesis. It has not been confirmed, and the last three times a
hypothesis in this area was acted on without measurement, the design
regressed.** Confirm it before changing RTL.

## 4. What to instrument next

`EoV19DdrCamWriter` state is not observable. Export and probe, per camera:

- `have_bank`, `drop_frame` (cam_clk — sync to `ui_clk`, they are slow status bits)
- `free_bank_empty`, `fifo_prog_full`, `fifo_full`
- `fifo_level_ui[11:0]` (already exists as `v19_capN_level`, just not probed)
- `frame_epoch_available`, `trigger_pending[3:0]`

A free ILA slot exists: `probe11` currently carries
`{c0_ddr4_app_rd_data[383:368], c0_ddr4_app_rd_data[15:0]}` (32 bits), which
has little remaining diagnostic value. Keeping a probe's **width** unchanged
avoids regenerating the ILA IP — that is how `probe19` was repurposed into the
frame-set diagnostic word (see `PanoramaBase_DdrBlackFrame.v`, search
`4'hA signature`).

The question to answer: *when the returning camera fails to publish, is
`drop_frame` stuck at 1, and is `fifo_prog_full` the reason?*

## 5. Test harness

All scripts are in `scripts/`. **COM13** is the STM32 master's PC UI link
(USART3, PB10/PB11, 115200 8N1). COM6 is the ST-Link VCP and is **not**
connected to it.

### Camera power — `eo_cam_power.py`

The board speaks the **customer ICD protocol**, not the legacy COBS/CRC
protocol in `proto_uart.c`. A COBS frame gets no reply at all. Framing:

```
SOM  uint32 LE 0x70717883
msgId uint16 LE       seq uint32 LE       len uint32 LE
time uint64 LE (ms since Unix epoch)
payload[len]
crc  uint16 LE  CRC16/CCITT-FALSE over the PAYLOAD ONLY
EOM  uint32 LE 0x83787170
```

Camera power is `ICD_RITA_PIPA_CAMERA_CONTROL` (0x2202), 5-byte payload
`[eo_id, eo_action, ir_id, ir_nuc, ir_action]`, id **1-based** (FPGA camera N
is ICD id N+1), action `1 = ON, 2 = OFF`.

**The firmware ignores camera commands unless it is in Basic operation.**
Every command is preceded by `MODE_CONTROL` (0x2201) payload `3`.

```bash
python scripts/eo_cam_power.py --cam 4 --off
python scripts/eo_cam_power.py --cam 4 --on
python scripts/eo_cam_power.py --cam all --on
python scripts/eo_cam_power.py --status
```

### Full test — `v19_camloss_test.py`

```bash
python scripts/v19_camloss_test.py --cam 4 --cycles 6 --settle 12
```

Programs over JTAG, sets Basic mode, checks baseline, then cycles off/on,
recording a PNG and an ILA capture per step into `captures/camloss_<stamp>/`.
It reprograms every run because the failure does not self-clear. Exit code 2
means reproduced.

**Judge rejoin on per-tile liveness, never colour.** A blacked tile
classifies as "image" on colour alone (`mean_y 2.95, std 21.96` from the blend
seams) and produced a false 6/6 pass earlier.

### Observation

```bash
python scripts/v19_grab_panorama.py --frames 20 --out shot.png   # per-tile colour + liveness
python scripts/v19_decode_capture.py <ila.csv>                   # pipeline stages
python scripts/v19_decode_frameset.py <ila.csv>                  # frame-set ownership
python scripts/v19_verify_epoch_rejoin.py                        # epoch regression, no hardware
```

### ILA capture

```bash
vivado -mode batch -source scripts/capture_v19_named.tcl -tclargs <label> [program]
vivado -mode batch -source scripts/probe_ui_alive.tcl -tclargs 15    # trigger-armed liveness
vivado -mode batch -source scripts/probe_trigger_alive.tcl -tclargs 15
```

**Free-running captures prove almost nothing here.** The `ui_clk` window is
~8.8 us and the `hd_clk` window ~110 us. A 60 Hz trigger, a 30 fps descriptor
or any bursty signal is usually missed, and reading "0/2048" as "dead" caused
two wrong conclusions in this session. Use the trigger-armed probes to ask
"does this signal ever assert?".

## 6. Build procedure and traps

```bash
bash scripts/build_sweep.sh          # sweeps place_design directives, writes build_done.txt
vivado -mode batch -source scripts/impl_v19_full_rebuild.tcl -tclargs <directive> [reuse-synth]
```

- **MIG-internal timing is a placement lottery.** Paths from
  `u_ddr_mc_wr_bit/dReg_reg[*]` to `xiphy_rxtx_bitslice/D[*]` have **zero
  logic levels and ~98% route delay**; any unrelated logic edit can flip one
  negative (seen as `WNS -0.051`, `WNS -0.154`, and `WPWS -0.269` on three
  different builds). Re-running an identical build is pointless — Vivado is
  deterministic. Sweep directives instead. The durable fix is a **floorplan**
  pinning the MIG controller near its I/O banks; this design has **no pblocks
  at all**.
- **Never** put `set_false_path`/`set_max_delay` on MIG-internal paths or
  bypass `assert_nonnegative_timing`. Those carry real DDR write data.
- `reuse-synth` re-implements from the existing checkpoint. Only valid when
  the RTL has not changed.
- **Wait on process completion, not log text.** A failure raised by the
  script's own `error` produces no `ERROR:` line, which once left a waiter
  spinning for 11 hours. `build_sweep.sh` writes `build_done.txt` with the
  exit code.
- A stale Vivado GUI session can clobber the `.xpr` fileset;
  `scripts/v19_fileset.tcl` re-asserts it at every entry point.

## 7. Known-good bitstreams

| Build | State |
|---|---|
| `builds/drainfix_20260802/` | **current best** — crash fixed, graceful degradation, no rejoin |
| `builds/bankstagger_20260731/` | before the presence/drain fixes |
| `builds/camloss_20260731/` | older fallback |

## 8. Open items beyond this bug

- **`STROBE_OUT0` is the master trigger** (`KintexTop_...v` ~line 216–237),
  i.e. camera 0's strobe. Losing camera 0 stops capture on *all six*. Last
  cam0 single-point dependency; blocks true full loss tolerance.
- **V19 compositing is not rate-limited.** It is the only source whose
  `copy_start_trig` is a bare level (`v19_replay_banks_ready`) rather than a
  display frame edge, so it free-runs against a 60 Hz display. Gating on
  `frame_edge && v19_replay_banks_ready` would free bandwidth.
- **DDR margin is still thin** even after the bank stagger. Next levers:
  batch the arbiter round-robin (16–32 beats/camera) instead of rotating per
  command; have replay fetch a whole row before switching camera.
