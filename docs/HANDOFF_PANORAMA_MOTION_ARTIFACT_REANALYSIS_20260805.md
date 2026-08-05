# EO Panorama V19 Motion-Artifact Reanalysis and Engineering Handoff

Date: 2026-08-05

Target: Xilinx Kintex UltraScale+ XCKU15P-2FFVE1517I, Vivado 2025.2

Repository: E:/Xylinx/EO_Panorama_V19_M1

Branch at review: main

Reviewed HEAD: 26b34352620854db590056ffc4094b6d128543bd

Reviewed origin/main: 47b01b91b90b975bee3104a93f416333bc493969

## 1. Purpose

This document hands off the current investigation of horizontal tearing, short noisy horizontal lines, and moving-scene corruption in the six-camera V19 panorama. It consolidates the earlier hardware evidence, rechecks the current RTL ownership paths, corrects conclusions in HANDOFF_PANORAMA_MOTION_ARTIFACT_20260805.md that are not fully supported by the RTL, and defines the next implementation and validation sequence.

The image is largely clean for static scenes. Motion exposes intermittent short horizontal discontinuities and occasional split-like corruption. Lens mismatch explains geometric seam quality, but it does not explain these temporal artifacts.

## 2. Executive conclusion

The problem is still most likely a DDR transaction-integrity or scheduling problem, not a map, lens, blend, or YUV color-conversion problem.

The strongest known bisection remains valid: the first clearly artifact-producing change was capture batching introduced by commit d5c7078. However, the earlier explanation that an aborted retry bank is routinely replayed while the camera writer is still writing that same bank is not reachable through the intended token and descriptor ownership path. A bank is not published to the frame-set manager until its successful marker is accepted. Before that event, the manager cannot lease that bank for replay.

There is nevertheless a real ownership weakness: source-bank release is tied to final output completion, not explicitly to proof that all replay commands and read returns for the frame set are quiescent. Today that is assumed indirectly. It should become an explicit invariant and an enforced release fence.

The current 32-beat capture batch is too large for diagnosis and likely contributes to bursty pressure. The safest next hardware comparison is:

1. Set V19_CAP_BATCH to 1.
2. Keep replay batching at its current value of 8 initially.
3. Add exact per-bank write auditing, read/write collision monitors, and replay-quiescence assertions before changing more architecture.
4. Run a controlled A/B test against the current 32-beat build.

Do not begin by changing MIG ordering, removing output ping-pong, enlarging FIFOs, or restoring unconditional capture-first arbitration. Those changes either lack evidence or have already produced starvation elsewhere.

## 3. Repository and build state at handoff

The working tree was already dirty before this document was created. Preserve all existing changes and untracked files; they may contain the user's current experiments.

Observed state:

    ## main...origin/main [ahead 19]
     M EO_Panorama_V19_M1.xpr
     M src/EoV19StreamingRenderer.v
    ?? .build_sweep.lock
    ?? .tmpCRC/
    ?? build_margin_console.txt
    ?? build_margin_result.txt
    ?? build_progress.txt
    ?? build_sweep_console.txt
    ?? build_sweep_result.txt
    ?? docs/ALTERNATE_V19_SOURCE_DRIVEN_ROWWINDOW_ARCHITECTURE_20260804.md
    ?? hs_err_pid53576.dmp
    ?? scripts/v19_mig_nobuffer.tcl
    ?? tight_setup_hold_pins.txt

The routed timing report reviewed was:

    EO_Panorama_V19_M1.runs/impl_1/
    KintexTop_EO_IR_HD_SDI_panorama_base_timing_summary_routed.rpt

Its summary is timing-clean:

| Metric | Result |
|---|---:|
| WNS | +0.038 ns |
| TNS | 0.000 ns |
| WHS | +0.010 ns |
| THS | 0.000 ns |
| WPWS | +0.002 ns |
| TPWS | 0.000 ns |

No current bitstream or LTX file was found directly in impl_1 during this review. Historical bitstreams exist under builds/. Do not assume the programmed hardware corresponds to the current source or the current routed report without recording the exact bitstream path and Git commit.

The dirty change in src/EoV19StreamingRenderer.v is not on the instantiated datapath. PanoramaBase_DdrBlackFrame.v currently instantiates EoV19StreamingRendererII1.

## 4. Current architecture relevant to the fault

The active V19 path is:

1. Six asynchronous BT.1120 camera inputs are captured in their camera clock domains.
2. Each EoV19DdrCamWriter packs pixels and crosses payload and marker information into ui_clk.
3. Captured frames are written to per-camera DDR banks.
4. EoV19FrameSetManager collects successful descriptors and selects a coherent frame set.
5. Leased source banks are replayed from DDR to six line caches.
6. The RowRun renderer samples the six line caches, blends into the shared output path, and folds the 3840 by 480 logical panorama into a 1920 by 1080 raster.
7. The inactive output frame is written to DDR and the opposite frame is scanned out to HD-SDI.

The relevant shared DDR clients are:

- camera capture writes;
- six-camera source replay reads;
- panorama/output frame writes;
- HD-SDI scan-out reads.

This design must protect both bandwidth and transaction identity. Aggregate DDR bandwidth alone is not enough; a single missing, duplicated, stale, or misaddressed beat can become a short horizontal artifact.

## 5. Evidence that should be retained

### 5.1 The symptom is temporal

The moving-scene capture shows sparse horizontal corruption and local line discontinuities. Static geometry and most of the panorama remain stable. That pattern fits frame, row, or DDR-beat integrity faults more closely than a persistent mapping error.

### 5.2 The first regression was capture batching

The previous bisection identified d5c7078 as the first artifact-producing change and linked it to capture batching. That is useful causal evidence. It does not, by itself, prove which internal batching failure mechanism is responsible.

### 5.3 Timing closure is currently positive

The reviewed routed report has positive setup, hold, and pulse-width margins. A timing failure is therefore not the leading explanation for the observed deterministic motion-sensitive artifact, although programmed-image provenance must still be tracked.

### 5.4 Camera raster outputs are not synchronized

The camera manufacturer confirmed that the cameras do not support synchronized BT.1120 output. Sensor exposure triggering does not guarantee aligned ISP/raster timing. The per-camera DDR capture and later frame-set alignment architecture is therefore required.

### 5.5 Capture-first was not a sustainable fix

Earlier long-run validation recorded all FIFOs overflowing and showed that unconditional capture-first priority could starve replay. A short clean run under that policy is not sufficient acceptance evidence.

## 6. Correction to the previous retry-bank theory

The current writer and frame-set-manager handshake should prevent the commonly stated direct collision:

1. A camera writer owns a local bank while capturing or retrying that frame.
2. A successful descriptor is not published until the successful frame marker reaches the UI side and the marker is popped.
3. EoV19FrameSetManager can only acquire a bank that arrived through such a descriptor.
4. The manager then leases the selected bank for replay and later returns a release token.
5. The writer cannot normally reuse a leased bank until it receives that release token.

The relevant code is in:

- src/EoV19DdrDesync.v, successful marker and retry ownership logic around lines 393-470;
- src/EoV19DdrDesync.v, descriptor publication around lines 608-612;
- src/EoV19FrameSetManager.v, descriptor insertion around lines 452-484;
- src/EoV19FrameSetManager.v, bank lease and release handling around lines 644-711.

Therefore, a pressure-aborted frame that has not published a successful descriptor is not available to the manager and should not be replayed concurrently. Any future claim of a capture/replay same-bank collision must be supported by an actual address-and-bank monitor, not only by inference from the retry counter.

This correction does not clear the batching implementation. The batching change can still cause corruption through command/data association, bank-boundary handling, marker ordering, address sequencing, or pressure behavior.

## 7. The real source-bank lifecycle hole

The current source-bank lifetime is closed by v19_consumer_done in PanoramaBase_DdrBlackFrame.v. That signal is derived from completion of the final output write path.

This is only safe if final output completion necessarily occurs after all of the following are true:

- every source replay command for the active frame set has been accepted;
- every replay read return has arrived;
- every replay FIFO and line-cache transaction associated with that set has drained;
- no request from the old frame set remains in a command skid, pending queue, or MIG return path.

That ordering is plausible in the current sequential pipeline, but it is not represented as a direct protocol guarantee. Optimizations, retry paths, or future overlap can violate the assumption.

Required invariant:

    source_bank_release(camera, bank, epoch)
      is legal only when
      replay_commands_outstanding(camera, bank, epoch) == 0
      and replay_return_words_pending(camera, bank, epoch) == 0
      and no queued request still names that bank and epoch.

Recommended implementation:

- Tag every accepted replay request internally with camera, bank, and epoch.
- Increment an outstanding count on accepted command issue.
- Decrement it only on the corresponding final returned word.
- Track pending/skid entries separately if the arbiter can hold a request before acceptance.
- Gate manager release on renderer/output completion and replay_quiescent for all six cameras.
- Assert that no released bank appears in a replay request or replay return.

The release fence should be added even if V19_CAP_BATCH=1 removes the visible artifact, because it turns an implicit timing dependency into an enforceable ownership rule.

## 8. Why the previous bandwidth calculation does not prove retry traffic

The script scripts/v19_measure_bandwidth.py filters samples to short active-copy windows using copy_active and derives bandwidth from write_retiring. That counter combines more than one write client and the selected window is not a complete frame interval.

Consequently, the reported 26-29 percent apparent write excess cannot be converted directly into a retry-frame percentage. It may include:

- camera capture writes;
- output-frame writes;
- phase-dependent client overlap;
- a partial interval rather than a frame;
- retries or duplicate issues, if present.

The number remains a warning sign, not a proof.

Replace this with full-frame or fixed-time accounting:

- capture commands and accepted beats per camera;
- capture successful, aborted, retried, and dropped frames per camera;
- replay commands and returned beats per camera;
- output write commands and beats;
- scan-out commands and beats;
- arbitration grant count and maximum wait per client;
- FIFO high-water marks and overflows;
- outstanding read count by camera, bank, and epoch.

The camera writer packs 16 YUV422 pixels into a 256-bit payload and places that payload in the low 256 bits of each 384-bit DDR application word. A complete 1920 by 1080 camera frame therefore contains exactly 129,600 accepted capture transactions. That count should be checked independently for every successfully published bank. It is intentionally larger than the 86,400 transactions that a fully packed 384-bit datapath would require.

## 9. Current batching and arbitration risk

PanoramaBase_DdrBlackFrame.v currently defines V19_CAP_BATCH as 32. The arbiter order around the reviewed code is scan-out, replay, output, then capture.

The earlier validation history is important:

- unconditional capture priority reduced one visible failure mode in a short run;
- sustained testing later produced replay starvation and FIFO overflow;
- the current ordering was introduced to protect consumers;
- the 32-beat capture quantum makes capture service burstier and makes latency to the next client larger.

This means the correct recovery step is not to reinstall permanent capture-first priority. It is to reduce capture quantum to one accepted beat for an A/B test while keeping the rest of the arbitration stable.

The one-beat configuration is diagnostically valuable:

- it most closely resembles the pre-regression request behavior;
- it limits the damage of a stale client selection;
- it exposes per-beat address or accounting errors;
- it reduces head-of-line blocking for scan, replay, and output.

If batch=1 is clean over a long moving-scene run, increase only after instrumentation proves exact capture sequencing.

## 10. MIG ordering assessment

The current DDR4 IP configuration uses:

- APP_DATA_WIDTH = 384;
- C0.DDR4_DataWidth = 48;
- C0.DDR4_Ordering = Normal;
- address mapping ROW_COLUMN_BANK.

AMD PG150 states that user-interface read data is returned in request order. In Normal ordering mode, the controller may reorder requests across memory-controller groups, while same-group requests are not reordered; identical addresses map to the same group.

References:

- AMD PG150, Read Path: https://docs.amd.com/r/en-US/pg150-ultrascale-memory-ip/Read-Path
- AMD PG150, Normal request ordering: https://docs.amd.com/api/khub/documents/4NxD7M2Y93Rcq1IgnPK0gA/content

Therefore, Normal ordering alone does not explain arbitrary mixing of replay-return data if the RTL issues requests and consumes returns in the required order. The higher-probability failure is local transaction accounting or command/data association.

Do not change MIG to Strict ordering as the first fix. It can be used later as a controlled experiment after internal monitors are present.

## 11. Verification gap that must be closed

Several existing writer testbenches are stale. They still connect the removed trigger_ref interface and do not drive the newer join_enable and global_epoch_gray_ui ports. The manager testbench also does not cover the current cam_present and forfeit behavior.

Affected tests include:

- sim/tb_EoV19DdrCamWriterDrop.v;
- sim/tb_EoV19DdrCamWriterMarker.v;
- sim/tb_EoV19DdrCamWriterAdmission.v;
- sim/tb_EoV19DdrCamWriterEpoch.v;
- sim/tb_EoV19DdrCamWriterMidframePressure.v;
- the current frame-set-manager testbench.

Until these tests compile against the current RTL and exercise batching, retry, marker, epoch, and release paths, the batching logic is not regression-protected.

Minimum simulation matrix:

| Test | Required checks |
|---|---|
| Clean frame, batch 1 | 129,600 unique sequential beats, one success descriptor |
| Clean frame, batch 32 | Same exact result as batch 1 |
| Mid-frame pressure abort | No success descriptor, no stale marker, same bank retained for retry |
| Retry then success | Old attempt discarded, one descriptor only, exact final bank contents |
| Marker FIFO backpressure | Payload completion cannot publish a mismatched descriptor |
| Epoch change | Old-epoch bank cannot join a new set |
| Delayed release | Writer cannot reuse leased bank |
| Replay outstanding at output done | Bank release remains blocked |
| Simultaneous DDR clients | No command duplication, omission, or response-owner mismatch |

## 12. Ranked failure hypotheses

| Rank | Hypothesis | Why it fits | How to prove or reject |
|---:|---|---|---|
| 1 | Capture batching command/address association defect | First regression follows batching; horizontal artifacts match isolated beat damage | Per-bank exact write sequence monitor and batch 1 versus 32 A/B |
| 2 | Source-bank release before complete replay quiescence | Lifecycle is implicit, not fenced; can expose reused data under overlap | Outstanding read counters and release assertion |
| 3 | Arbiter request persistence or grant accounting error | Multi-client UI with batching is sensitive to accepted-versus-presented semantics | Log every request, acceptance, owner, address, and return owner |
| 4 | Replay return routing/counting defect | A wrong return owner can corrupt a short row interval | Read scoreboard per camera/bank/epoch |
| 5 | Marker/payload CDC skew under pressure | Success metadata is separate from payload and failures are intermittent | Stress marker FIFO, compare expected terminal address and beat count |
| 6 | Output row-ready or bank-swap violation | Can create horizontal split-like artifacts | Assert scan never reads unready row and swap only after complete frame |
| 7 | Camera-side malformed frame | Possible but less consistent with batching bisection | Count line lengths, rows, SAV/EAV errors before DDR |
| 8 | MIG Normal ordering | Low probability given documented UI ordering | Strict-mode A/B only after internal checks |
| 9 | Map, blend, or lens calibration | Explains seams, not sparse motion-dependent noisy rows | Static synthetic patterns and renderer-only simulation |

## 13. Instrumentation design

### 13.1 Capture transaction identity

The payload FIFO record already contains bank and epoch fields, but the current payload write initializes those fields to zero. Populate them at enqueue:

    {beat_addr, is_marker, wr_bank, frame_epoch, packed_payload}

On ui_clk, maintain per-camera and per-bank state:

- expected next address;
- accepted beat count;
- first and last address;
- active epoch;
- duplicate address flag;
- skipped address flag;
- bank or epoch transition before marker flag;
- successful marker with non-129,600 beat count flag.

Latch the first failing expected and observed addresses for ILA visibility.

### 13.2 Replay transaction identity

For every accepted read:

- record client, camera, bank, epoch, start address, and requested length;
- increment an outstanding-word count;
- route each return using the recorded owner;
- decrement on returned words;
- assert no underflow, overflow, or owner mismatch.

If the UI protocol accepts only one command at a time, make the accepted event explicit. Do not infer acceptance from request level alone.

### 13.3 Source-bank collision monitor

Compare every accepted capture write address with:

- every outstanding replay address range;
- every queued replay request;
- every bank currently leased by the frame-set manager.

Record camera, bank, epoch, capture address, replay address, and cycle at first collision.

Also assert:

- writer may not write a leased bank;
- replay may not read an unleased bank;
- manager may not release a bank with nonzero replay outstanding count.

### 13.4 Output row-ready protection

Record row-ready state separately from frame validity. Assert:

- scan-out reads only the displayed bank;
- the displayed bank is complete;
- bank swap occurs only at the intended frame boundary;
- no output write targets the displayed bank;
- every active output row has the expected number of accepted writes before swap.

### 13.5 Full-frame counters

Expose counters through ILA or status registers:

- expected and actual capture beats per camera;
- successful and aborted frames;
- retries;
- descriptor count;
- replay requests and returns;
- source-bank releases;
- panorama rows rendered and retired;
- output writes;
- scan reads;
- maximum arbitration wait;
- FIFO high-water and sticky overflow.

Counters must span complete trigger epochs or a known number of output frames.

## 14. Staged fix plan

### Stage A: restore trustworthy verification

1. Update stale writer and frame-set-manager testbenches to the current interfaces.
2. Add a shared transaction scoreboard.
3. Prove batch 1 and batch 32 produce identical bank contents for clean input.
4. Add pressure-abort, retry, epoch transition, delayed-release, and multi-client tests.
5. Run lint and compile the active top-level hierarchy, including EoV19StreamingRendererII1.

Exit criterion: all tests compile against the active RTL and fail on intentionally injected duplicate, skipped, or stale-bank transactions.

### Stage B: instrument without changing scheduling behavior

1. Populate bank and epoch in the payload FIFO.
2. Add per-bank capture sequence checking.
3. Add replay outstanding tracking.
4. Add lease/write/read collision monitors.
5. Add output row-ready assertions and full-frame counters.
6. Build and capture a moving-scene run with V19_CAP_BATCH=32.

Exit criterion: the first hardware invariant failure is captured with camera, bank, epoch, address, and cycle.

### Stage C: one controlled recovery change

1. Change V19_CAP_BATCH from 32 to 1.
2. Leave replay batch at 8.
3. Leave MIG ordering and client priority otherwise unchanged.
4. Rebuild, program, and repeat the identical moving-scene test.

Exit criterion: no artifact, no invariant failure, no overflow, no underflow, and no unexpected retry over at least 18,000 frames.

If batch 1 is clean, commit and tag that state before any throughput optimization.

### Stage D: make bank release explicit

1. Implement replay_quiescent per camera and frame-set epoch.
2. Gate bank-release tokens with both output consumption complete and replay quiescent.
3. Hold old-set tags until all read returns drain.
4. Add assertions for any request or return after release.

Exit criterion: simulation proves delayed returns cannot touch a released or reused bank.

### Stage E: replace fixed priority with bounded-latency QoS

Use urgency plus bounded service, not unconditional fixed priority:

- scan-out urgent when its FIFO falls below a deadline watermark;
- capture urgent when any camera input FIFO exceeds its high watermark;
- replay urgent when a requested source row is near line-cache starvation;
- output write urgent when the retired-row or push FIFO exceeds its high watermark;
- otherwise round-robin among requesting clients;
- limit each grant quantum;
- force service when any client wait counter reaches its bound.

The approximate traffic ratio per panorama frame is capture:replay:scan:output = 20:18:3:3. This ratio is only a starting point. Tune with measured complete-frame counters and maximum-wait data.

### Stage F: optimize only after integrity is proven

Potential later optimizations:

- cautiously increase capture quantum from 1;
- introduce a real one-entry skid or command queue so the next request is prepared without duplicating the current request;
- prefetch replay rows based on renderer demand;
- merge adjacent address bursts where bank, epoch, and ownership are unchanged;
- use per-client credits and deadlines.

A naive same-cycle launcher reload is unsafe because sequential logic observes the old request values and can reissue the same source request.

## 15. Hardware validation procedure

Use one repeatable setup and record every artifact:

1. Record Git commit, bitstream path, LTX path, Vivado run directory, and timing summary.
2. Confirm the USB grabber records native uncompressed 1920 by 1080 output without application-side resizing or compression.
3. Use a moving vertical-edge scene, a moving checkerboard or text target, and the prior moving-rig scene.
4. Run at least 18,000 output frames for acceptance.
5. Save a short clean reference and the first corrupted frame at native resolution.
6. Export the corresponding ILA capture and status-counter snapshot.
7. Verify:
   - no source-bank read/write collision;
   - exactly 129,600 accepted capture beats for every published camera frame;
   - no skipped or duplicate capture address;
   - no descriptor before final accepted payload;
   - no source-bank release with outstanding replay;
   - no replay response-owner mismatch;
   - no scan read from an incomplete bank;
   - no FIFO overflow or underflow;
   - no stale or mixed epoch;
   - positive routed setup, hold, and pulse-width timing.

## 16. Diagnostic decision tree

If a capture sequence error fires:

- keep V19_CAP_BATCH=1;
- inspect accepted command semantics and batch counter reload;
- verify address advances exactly once per accepted beat;
- verify client ownership cannot change inside an accepted beat.

If a source-bank collision or release assertion fires:

- implement the replay-quiescent release fence immediately;
- inspect release-token epoch and bank identity;
- ensure pending arbiter requests are included in outstanding accounting.

If replay return ownership fails:

- replace implicit response routing with an explicit accepted-request owner queue;
- size the queue for the maximum outstanding read depth;
- preserve camera, bank, epoch, and word count until the final return.

If output row-ready protection fails:

- repair completion and bank-swap conditions;
- keep output DDR ping-pong until direct scan-out has separately proven row deadlines.

If all monitors stay clean but artifacts remain:

- isolate the renderer with a deterministic DDR-resident source pattern;
- compare hardware rows against the C reference;
- probe BT.1120 output timing and packing;
- only then run a controlled MIG Strict-ordering A/B build.

## 17. Relationship to the alternate architecture

The document docs/ALTERNATE_V19_SOURCE_DRIVEN_ROWWINDOW_ARCHITECTURE_20260804.md describes a longer-term architecture in which asynchronous camera rows can feed a full shared 1920 by 540 destination RowWindow with explicit row readiness.

That architecture may reduce dependence on input-frame replay and output-frame buffering for selected modes. It does not eliminate the need to:

- associate every source row with camera, epoch, and source-row identity;
- fetch the correct dynamic stabilization map rows;
- prevent stale-camera data from satisfying a current frame;
- prove destination rows are complete before scan-out;
- meet deterministic HD-SDI row deadlines.

It should be treated as a separate architectural branch after the existing DDR design has a clean, instrumented baseline. Do not mix a wholesale architecture change into the current artifact root-cause experiment.

## 18. Immediate next actions

The next engineer or model should execute this exact order:

1. Preserve and inventory the current dirty tree.
2. Create a named baseline tag or record the exact current commit and programmed bitstream.
3. Repair the stale simulations.
4. Add capture bank, epoch, address, and count checking.
5. Add replay outstanding and source-bank release assertions.
6. Obtain one monitored V19_CAP_BATCH=32 reproduction.
7. Change only V19_CAP_BATCH to 1 and rebuild.
8. Run the same 18,000-frame moving-scene validation.
9. If clean, commit the recovery baseline before QoS work.
10. If not clean, follow the decision tree using the first invariant failure; do not start an uninformed build loop.

## 19. Files to read first

- docs/HANDOFF_PANORAMA_MOTION_ARTIFACT_20260805.md
- docs/V19_TEMPORAL_INTEGRITY_VALIDATION_20260728.md
- docs/ALTERNATE_V19_SOURCE_DRIVEN_ROWWINDOW_ARCHITECTURE_20260804.md
- src/EoV19DdrDesync.v
- src/EoV19FrameSetManager.v
- src/PanoramaBase_DdrBlackFrame.v
- src/EoV19StreamingRendererII1.v
- src/EoV19LineCache.v
- scripts/v19_measure_bandwidth.py
- ip/ddr4_sub64/ddr4_sub64.xci

## 20. Final handoff position

The design is close enough to produce a mostly correct static panorama and it currently meets routed timing. The remaining artifact should be treated as a transaction-integrity bug exposed by motion and by capture batching. The most defensible near-term recovery is a one-beat capture quantum plus exact transaction instrumentation and a source-bank replay-quiescence fence.

The next result must be evidence-driven: identify the first violated invariant, fix that invariant, and validate over a long moving-scene run. Avoid broad arbitration or memory-architecture changes until a clean instrumented baseline exists.
