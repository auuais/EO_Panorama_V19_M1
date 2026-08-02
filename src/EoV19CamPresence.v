`timescale 1ns/1ps

// Per-camera participation watchdog for the V19 panorama path.
//
// Every "is the frame set ready" decision in the V19 pipeline was an
// unconditional six-way AND: EoV19FrameSetManager will only lease a frame set
// whose epoch is present for all six cameras, and the renderer/parent row
// gates reduce over all six row counters.  Powering one camera down therefore
// stopped the entire panorama.  This module produces the cam_present bit those
// decisions need so a non-contributing camera is excluded instead of blocking.
//
// WHAT "PRESENT" HAS TO MEAN
//
// It must mean "this camera is contributing completed frames", NOT "this
// camera's pixel clock is running".  The two differ exactly when it matters.
// Measured 2026-08-02, one off/on cycle on camera 4:
//
//   cam_present         111111    camera 4 counted present
//   free_ready          111111
//   descriptor_valid_map cam4:0000  camera 4 had published nothing
//   lease_valid         0/2048
//
// A camera that is streaming rows but has not published a completion
// descriptor cannot satisfy epoch_presentN(), so no frame set is ever found.
// That wedge is self-sustaining and cannot recover on its own: no lease means
// no ST_RELEASE, which means no bank tokens are returned to ANY camera, so the
// other five fill their rings and stall as well.  All six capture FIFOs pin at
// their prog_full watermark and the panorama only comes back by reprogramming.
//
// Judging liveness from the camera's row counter -- which keeps advancing on
// line_end whether or not the writer owns a bank -- is precisely the reading
// that produces that state.  Judge it from the completion descriptor instead:
// a camera that cannot publish is excluded, the manager keeps leasing on the
// remaining cameras, releases keep returning tokens, and the stalled camera
// gets a bank back and rejoins by itself.
//
// Liveness is evaluated in the ui_clk domain.  It deliberately does NOT run on
// the camera's own clock: a powered-down camera has no clock at all, so
// anything clocked by it simply freezes and can never report its own absence.
//
// The age counter saturates rather than wrapping, so a long absence stays
// absent instead of aliasing back to present.
module EoV19CamPresence #(
    // ui_clk cycles without a completion descriptor before a camera is
    // declared absent.  ~300 ms at the 233.4 MHz MIG ui_clk, i.e. about nine
    // frame periods at 30 fps.  This is deliberately longer than the old
    // 100 ms row-activity timeout: descriptors are per frame, not per line, and
    // the DDR path can legitimately go a few frames without retiring one under
    // burst pressure.  Too short would drop a healthy camera during a stall;
    // too long only delays shedding a stuck one.
    parameter integer TIMEOUT_CYCLES = 70_020_000,
    parameter integer ACT_W = 11
) (
    input  wire               clk,
    input  wire               rst,
    // Retained for probe/debug use.  NOT used to judge presence -- see above:
    // the row counter advances even when the writer owns no bank and can
    // publish nothing, which is the failure this module exists to shed.
    input  wire [ACT_W-1:0]   activity,
    // Completion-descriptor strobe for this camera, in clk.  One pulse per
    // frame actually published to the frame-set manager.
    input  wire               activity_pulse,
    output reg                present
);
    localparam integer AGE_W = $clog2(TIMEOUT_CYCLES + 1);

    reg [AGE_W-1:0]  age;

    always @(posedge clk) begin
        if (rst) begin
            // Come out of reset ABSENT, not present.  Claiming presence for a
            // camera that has never published would let the frame-set manager
            // wait forever for descriptors that are not coming.  Seeding of
            // FREE bank tokens is keyed on FIFO readiness, never on presence,
            // so starting absent cannot stall the bring-up.
            age     <= TIMEOUT_CYCLES[AGE_W-1:0];
            present <= 1'b0;
        end else begin
            if (activity_pulse) begin
                age     <= {AGE_W{1'b0}};
                present <= 1'b1;
            end else if (age != TIMEOUT_CYCLES[AGE_W-1:0]) begin
                age     <= age + {{(AGE_W-1){1'b0}}, 1'b1};
            end else begin
                present <= 1'b0;
            end
        end
    end
endmodule
