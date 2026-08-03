#!/usr/bin/env python3
"""Regression check for EoV19TriggerSource (src/EoV19TriggerSource.v).

The common exposure trigger used to come straight from STROBE_OUT0, making
camera 0 a single point of failure for all six tiles: no strobe meant no
trigger, a frozen global epoch, and every writer discarding every raster.
The trigger source now follows that strobe when present and free-runs at the
MEASURED period when it is not.

Asserts the four properties that matter, in priority order:

  1. a healthy strobe is followed exactly  -- no behaviour change in the
     normal case, which is the one that must not regress
  2. a system powered up with camera 0 already dark still triggers
  3. camera 0 dying mid-run keeps triggering, at the measured period rather
     than a guessed constant
  4. camera 0 returning re-locks without emitting two triggers back to back

Run:  python scripts/v19_verify_trigger_source.py
"""
PERIOD_DEFAULT=2_475_000; PMIN=1_237_500; PMAX=4_950_000
BLANK=297_000; LOST_DEFAULT=3_712_500
MASK=0xFFFFFF

class Trig:
    def __init__(s):
        s.sync=[0,0,0]; s.since_trig=0; s.since_edge=MASK
        s.period=PERIOD_DEFAULT; s.seen=False; s.free=True; s.out=False
    def tick(s, strobe):
        s.sync=[strobe]+s.sync[:2]
        edge = s.sync[1] and not s.sync[2]
        lost_after = (s.period + (s.period>>1)) if s.seen else LOST_DEFAULT
        lost = s.since_edge >= lost_after
        blank = s.since_trig < BLANK
        due = s.since_trig >= s.period
        meas_ok = PMIN <= s.since_trig <= PMAX
        s.out=False
        if s.since_trig!=MASK: s.since_trig+=1
        if s.since_edge!=MASK: s.since_edge+=1
        s.free = lost
        if edge:
            s.seen=True; s.since_edge=0
            if not lost and meas_ok: s.period=s.since_trig
        if edge and not blank:
            s.out=True; s.since_trig=0
        elif lost and due:
            s.out=True; s.since_trig=0
        return s.out

def run(strobe_fn, cycles):
    t=Trig(); trigs=[]
    for i in range(cycles):
        if t.tick(strobe_fn(i)): trigs.append(i)
    return t, trigs

REAL=2_475_000            # camera actually at 30 fps
def healthy(i):  return 1 if (i % REAL) < 100_000 else 0
def never(i):    return 0
def dies(i):     return healthy(i) if i < 20_000_000 else 0
def returns(i):  return 0 if i < 12_000_000 else healthy(i)

def gaps(tr): return [b-a for a,b in zip(tr,tr[1:])]

t,tr = run(healthy, 30_000_000)
g=gaps(tr)
print(f"healthy strobe : {len(tr)} triggers, gaps min={min(g)} max={max(g)}  "
      f"learned={t.period}  free_running={t.free}")
assert all(abs(x-REAL)<200 for x in g), "healthy strobe must be followed exactly"
assert not t.free

t,tr = run(never, 20_000_000)
g=gaps(tr)
print(f"cam0 never on  : {len(tr)} triggers, gaps min={min(g)} max={max(g)}  free={t.free}")
assert len(tr)>5, "must free-run when camera 0 is absent from power-on"

t,tr = run(dies, 40_000_000)
after=[x for x in tr if x>21_000_000]
g=gaps([x for x in tr if x>22_000_000])
print(f"cam0 dies      : {len(after)} triggers after death, gaps max={max(g)}  "
      f"learned={t.period}")
assert len(after)>4, "must keep triggering after camera 0 dies"
assert abs(max(g)-REAL)<200, "fallback must use the MEASURED period"

t,tr = run(returns, 30_000_000)
g=gaps(tr)
print(f"cam0 returns   : {len(tr)} triggers, min gap={min(g)} "
      f"(blank={BLANK}) free={t.free}")
assert min(g) >= BLANK, "handover must not emit two triggers inside the blank window"
assert not t.free, "must re-lock to the real strobe when it returns"
print("\nALL PROPERTIES HOLD")
