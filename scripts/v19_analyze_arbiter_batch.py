"""Model the batched capture arbiter: fairness and row-miss rate."""
BATCH = 32
N = 6

def run(batch, cycles=200_000, fill_rate=1.0, empty_cam=None):
    rr = 0; ctr = 0
    served = [0]*N
    row_misses = 0
    last_cam = None
    # every camera always has data except empty_cam
    for _ in range(cycles):
        sel = None
        for k in range(N):
            c = (rr + k) % N
            if c == empty_cam:
                continue
            sel = c; break
        if sel is None:
            break
        served[sel] += 1
        if sel != last_cam:
            row_misses += 1          # camera switch = different DRAM row
        last_cam = sel
        if sel != rr:
            rr = sel; ctr = 1
        elif ctr >= batch - 1:
            rr = (sel + 1) % N; ctr = 0
        else:
            ctr += 1
    return served, row_misses

for b in (1, 8, 16, 32, 64):
    served, misses = run(b)
    spread = max(served) - min(served)
    print(f"  batch={b:<3} row-misses={misses:>7} ({100*misses/sum(served):5.2f}% of cmds)"
          f"  per-cam spread={spread}")

print()
served, misses = run(BATCH, empty_cam=3)
print(f"  cam3 FIFO empty: served={served}  (cam3 starved of service, others equal)")
assert served[3] == 0
assert max(s for i,s in enumerate(served) if i!=3) - \
       min(s for i,s in enumerate(served) if i!=3) <= BATCH, "fairness broken"
print("  fairness holds with a camera absent")

served, misses = run(BATCH)
assert max(served) - min(served) <= BATCH, "fairness broken"
print(f"  all six present: max-min served = {max(served)-min(served)} (<= batch)")
print("\nOK")
