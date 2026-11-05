"""Self time by function from a macOS `sample` report of shen-jit.

Run shen-jit with SHEN_JIT_PERF_MAP=1, sample it while it runs, then name
the samples in native code with the perf map it wrote:

    SHEN_JIT_PERF_MAP=1 build/shen-jit script work.shen & pid=$!
    sample $pid 5 1 -mayDie -file sample.txt; wait $pid
    python3 tests/bench/profile.py sample.txt /tmp/perf-$pid.map

Self time is each call-tree node's count less its children's. Compiled code
does not keep native frame chains, so callers above it are not reliable, but
the innermost frame is. `sample` also loses some samples taken in compiled
code, so C functions can appear larger than they are: confirm a C cost, such
as collection, with a timing before acting on it."""
import bisect, collections, re, sys

sample, perf_map = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 30

ranges = []
for line in open(perf_map):
    address, size, name = line.split(' ', 2)
    ranges.append((int(address, 16), int(size, 16), name.strip()))
ranges.sort()
starts = [r[0] for r in ranges]

def native_name(address):
    i = bisect.bisect_right(starts, address) - 1
    if i >= 0 and address < ranges[i][0] + ranges[i][1]:
        return ranges[i][2]
    return '(stubs)'

tree = open(sample).read().split('Sort by top of stack')[0]
nodes = []
for line in tree.splitlines():
    m = re.match(r'^([\s+!:|]*)(\d+)\s+(\S+)(.*)$', line)
    if not m:
        continue
    function, rest = m.group(3), m.group(4)
    address = re.search(r'\[0x([0-9a-f]+)', rest)
    if function == '???' and address:
        name = native_name(int(address.group(1), 16))
    else:
        name = function + ' [C]'
    nodes.append((len(m.group(1)), int(m.group(2)), name))

self_time = collections.Counter()
for i, (depth, count, name) in enumerate(nodes):
    children, child_depth, j = 0, None, i + 1
    while j < len(nodes) and nodes[j][0] > depth:
        if child_depth is None:
            child_depth = nodes[j][0]
        if nodes[j][0] == child_depth:
            children += nodes[j][1]
        j += 1
    self_time[name] += count - children

total = sum(self_time.values())
print('samples:', total)
for name, count in self_time.most_common(top):
    print(f'{count:7} {100 * count / total:5.1f}%  {name}')
