"""End-to-end panorama update rate: fraction of consecutive captured frames
that differ, averaged over several grabs.  The capture card runs at a fixed
rate, so a higher changed-fraction means the panorama is committing new frames
more often."""
import subprocess, sys, re, statistics
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
fracs = []
for i in range(runs):
    r = subprocess.run([sys.executable, "scripts/v19_grab_panorama.py", "--frames", "30"],
                       capture_output=True, text=True, timeout=300)
    m = re.findall(r"moved=(\d+)/(\d+)", r.stdout)
    if m:
        f = statistics.mean(int(a)/int(b) for a, b in m)
        fracs.append(f)
        print(f"  grab {i}: {100*f:.0f}% of frame pairs changed")
if fracs:
    print(f"  MEAN: {100*statistics.mean(fracs):.1f}%  (sd {100*statistics.stdev(fracs) if len(fracs)>1 else 0:.1f})")
