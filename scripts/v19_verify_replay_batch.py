"""Model the batched replay fetch: address order, buffering, and shift order.

Checks that every (camera, beat) pair is fetched exactly once per row, that the
demux by in-order returns puts each beat in the right slot, and that the shift
phase presents the same six-camera-per-beat sequence the old engine did.
"""
RBATCH = 8
RTOTAL = 6 * RBATCH
BEATS_PER_ROW = 120
BEAT_STRIDE = 8

def addr(cam, bx):            # relative address within a camera's row
    return cam * 10_000_000 + bx * BEAT_STRIDE

def run_new():
    presented = []            # (beat_x, [cam0..cam5 data]) in shift order
    issued = []
    beat_x = 0
    while True:
        # ST_REQ: issue RTOTAL requests, camera-major
        batch = []
        for req_idx in range(RTOTAL):
            cam, k = req_idx >> 3, req_idx & 7
            a = addr(cam, beat_x + k)
            issued.append(a); batch.append(a)
        # returns arrive in issue order -> demux into cbuf[cam][k]
        cbuf = [[None]*RBATCH for _ in range(6)]
        for ret_idx, data in enumerate(batch):
            cbuf[ret_idx >> 3][ret_idx & 7] = data
        # ST_LOAD/ST_SHIFT: present beat k of all six cameras
        for k in range(RBATCH):
            presented.append((beat_x + k, [cbuf[c][k] for c in range(6)]))
        if beat_x + RBATCH >= BEATS_PER_ROW:
            break
        beat_x += RBATCH
    return issued, presented

def run_old():
    presented = []; issued = []
    for bx in range(BEATS_PER_ROW):
        beats = []
        for cam in range(6):
            a = addr(cam, bx); issued.append(a); beats.append(a)
        presented.append((bx, beats))
    return issued, presented

ni, npres = run_new()
oi, opres = run_old()

print(f"reads per row: old={len(oi)}  new={len(ni)}")
assert len(ni) == len(oi) == 720, "must fetch the same total data"
assert sorted(ni) == sorted(oi), "must fetch exactly the same address set"
print("same address set fetched: OK")

assert npres == opres, "shift order must be identical to the old engine"
print(f"shift order identical across all {len(npres)} beats: OK")

# Row-locality: count camera switches in issue order (each = a DRAM row change)
def switches(seq):
    cams = [a // 10_000_000 for a in seq]
    return sum(1 for a, b in zip(cams, cams[1:]) if a != b)
so, sn = switches(oi), switches(ni)
print(f"\ncamera switches per row (= row activations):")
print(f"  old {so:4d} of {len(oi)} reads ({100*so/len(oi):5.1f}%)")
print(f"  new {sn:4d} of {len(ni)} reads ({100*sn/len(ni):5.1f}%)")
print(f"  reduction: {so/max(sn,1):.1f}x")

# Sequential-run length within a camera
runs = []; cur = 1
cams = [a // 10_000_000 for a in ni]
for a, b in zip(cams, cams[1:]):
    if a == b: cur += 1
    else: runs.append(cur); cur = 1
runs.append(cur)
print(f"  mean sequential run per camera: {sum(runs)/len(runs):.1f} beats")
print("\nOK")
