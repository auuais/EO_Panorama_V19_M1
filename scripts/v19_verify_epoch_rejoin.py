#!/usr/bin/env python3
"""Regression check for the V19 content-frame epoch across a camera outage.

Models the epoch bookkeeping in src/EoV19DdrDesync.v and asserts the property
the frame-set manager depends on:

    two cameras that capture the same content frame must assign it the
    same epoch, including after one of them has been powered down and
    brought back.

EoV19FrameSetManager leases a frame set only when one epoch is present for
every camera it considers present (epoch_presentN / epoch_bankN). If a
returning camera's epoch numbering is offset from the rest, that condition can
never be met again and the panorama freezes on rejoin -- which is exactly what
happened when the epoch was counted in each camera's own pixel-clock domain: a
camera with no clock stopped counting while the others carried on.

Run:  python scripts/v19_verify_epoch_rejoin.py
"""

import sys

MASK = 0xFFFF


class Camera:
    """Mirrors the cam_clk epoch block after the global-broadcast fix.

    global_epoch is the Gray-decoded broadcast count; trigger_pending is the
    only state that remains local.
    """

    def __init__(self):
        self.global_q = 0
        self.pending = 0
        self.assigned = {}

    def tick(self, global_epoch, frame_start, frame_idx=None):
        edge = global_epoch != self.global_q
        available = (self.pending != 0) or edge
        consume = frame_start and available

        if consume:
            if self.pending != 0:
                epoch = (global_epoch - self.pending + 1) & MASK
            else:
                epoch = global_epoch
            self.assigned[frame_idx] = epoch

        if edge and not consume:
            if self.pending != 0xF:
                self.pending += 1
        elif consume and not edge:
            self.pending -= 1
        # edge and consume in the same cycle: one appended, one taken.

        self.global_q = global_epoch


def simulate(frames, dark_start, dark_len):
    """One trigger and one frame start per content frame."""
    healthy, flaky = Camera(), Camera()
    global_epoch = 0
    for i in range(frames):
        global_epoch = (global_epoch + 1) & MASK  # ui_clk counts the trigger
        dark = dark_start <= i < dark_start + dark_len

        healthy.tick(global_epoch, False)
        if not dark:
            flaky.tick(global_epoch, False)  # no clock while dark: no tick

        healthy.tick(global_epoch, True, i)
        if not dark:
            flaky.tick(global_epoch, True, i)
    return healthy, flaky


def check(frames=60, dark_start=10, dark_len=8):
    healthy, flaky = simulate(frames, dark_start, dark_len)
    rejoin = dark_start + dark_len
    shared = sorted(set(healthy.assigned) & set(flaky.assigned))
    bad = [(i, healthy.assigned[i], flaky.assigned[i]) for i in shared
           if healthy.assigned[i] != flaky.assigned[i]]
    after = [b for b in bad if b[0] >= rejoin]

    print(f"outage of {dark_len} triggers starting at frame {dark_start}")
    print(f"  frames captured by both : {len(shared)}")
    print(f"  epoch mismatches after rejoin: {len(after)}")
    if after:
        for i, h, f in after[:5]:
            print(f"    frame {i}: healthy={h} returning={f}")
    return not after


def main():
    ok = True
    for dark_len in (1, 8, 100, 3000):
        for dark_start in (5, 40):
            ok &= check(frames=dark_start + dark_len + 40,
                        dark_start=dark_start, dark_len=dark_len)
            print()
    print("PASS: returning camera rejoins the epoch sequence immediately"
          if ok else
          "FAIL: returning camera never shares an epoch again")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
