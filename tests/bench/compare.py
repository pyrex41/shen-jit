"""Compares two runs of tests/bench/suite.shen: the best sample of each
benchmark, the ratio of the first run to the second, and geometric means by
group. Benchmarks under 2 ms in either run are listed but not compared."""
import sys, math, collections
def load(p):
    best, res, tag = {}, {}, {}
    for line in open(p, errors='replace'):
        f = line.rstrip('\n').split('|')
        if len(f) != 7 or f[0].startswith('"') or f[0] == 'mode':
            continue
        mode, sample, t, desc, power, secs, result = f
        key = (t, desc)
        s = float(secs)
        best[key] = min(best.get(key, s), s)
        res[key] = result
        tag[key] = t
    return best, res
ss, ssr = load(sys.argv[1])
sc, scr = load(sys.argv[2])
keys = [k for k in ss if k in sc]
groups = collections.defaultdict(list)
rows = []
for k in keys:
    a, b = ss[k], sc[k]
    if b < 0.002 or a < 0.002:   # too short to compare
        rows.append((k, a, b, None)); continue
    r = a / b
    rows.append((k, a, b, r))
    groups[k[0]].append(r)
for k, a, b, r in sorted(rows, key=lambda x: (x[0][0], -(x[3] or 0))):
    print(f"{k[0]:16} {k[1][:46]:46} {a*1000:9.1f} {b*1000:9.1f} {('%.2f' % r) if r else '  -  ':>6}")
print()
allr = []
for t, rs in sorted(groups.items()):
    g = math.exp(sum(map(math.log, rs)) / len(rs)); allr += rs
    print(f"{t:16} n={len(rs):3} geomean {g:.2f}  min {min(rs):.2f}  max {max(rs):.2f}")
g = math.exp(sum(map(math.log, allr)) / len(allr))
print(f"{'all':16} n={len(allr):3} geomean {g:.2f}  median {sorted(allr)[len(allr)//2]:.2f}")
print("skipped (under 2 ms):", sum(1 for r in rows if r[3] is None))
diff = [k for k in keys if ssr[k] != scr[k]]
print("result differences:", len(diff))
for k in diff[:20]: print("  ", k, ssr[k][:60], "|", scr[k][:60])
print("only in one:", [k for k in ss if k not in sc], [k for k in sc if k not in ss])
