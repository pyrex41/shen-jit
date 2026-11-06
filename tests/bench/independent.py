"""Times workloads that were never used for tuning, to tell gains that hold
for Shen code in general from fitting the benchmarks.

    python3 tests/bench/independent.py [--rounds N] [--kernel DIR] [--stlib DIR]
                                       [--scheme BIN] BIN...

The workloads are the kernel's test suite and its extension tests (from the
kernel sources in --kernel), installing the standard library (--stlib, its
StLib directory, if given; Tk is left out, as it needs Tcl), this repository's
contract examples, and starting the executable. They mostly load, compile
and typecheck code, so they also show compile time, which benchmarks
hardly measure. The THORN rows are the other way round: they mostly run, as
that prover searches on the kernel's problems, those of tests/thorn.expected
that take it long enough to time, with its wall-clock limit taken away. Each
binary runs each workload once per round, in an order that rotates between
rounds; the table gives the median wall time in ms and each binary's time over
the first's. With --scheme, Shen/Scheme runs the workloads it can too: the
standard library defines concat*, which its port already has, and the contract
examples are shen-jit's. Every run's output is checked, THORN's against
tests/thorn.expected; contract examples that fail are only reported, since an
older binary predates some of them."""
import os, re, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
THORN_PROBLEMS = ('set', 'L', 'schubert', 'ec')


def stlib_copy(stlib):
    """A copy of StLib whose install stops before Tk, and its load count."""
    work = Path(tempfile.mkdtemp(prefix='shen-jit-stlib-'))
    shutil.copytree(stlib, work / 'StLib')
    lines = (work / 'StLib' / 'install.shen').read_text().splitlines()
    end = next((i for i, l in enumerate(lines) if l.startswith('(cd "")')), len(lines))
    (work / 'StLib' / 'install-notk.shen').write_text('\n'.join(lines[:end]) + '\n')
    return work, sum(l.startswith('(load ') for l in lines[:end])


def kernel_copy(kernel, bins):
    """A copy of the kernel's extension tests, which write where they run, and
    of THORN to run in, and for each binary one with the standard library, which
    THORN needs, made by that binary."""
    work = Path(tempfile.mkdtemp(prefix='shen-jit-kernel-'))
    shutil.copytree(kernel / 'tests', work / 'tests')
    shutil.copytree(kernel / 'extensions', work / 'extensions')
    shutil.copytree(kernel / 'lib' / 'thorn', work / 'thorn')
    shutil.copy(REPO / 'tests' / 'thorn-setup.shen', work / 'thorn' / 'setup.shen')
    with_stlib = {}
    for i, b in enumerate(bins):
        with_stlib[b] = str(work / f'stlib-{i}{Path(b).suffix}')
        subprocess.run([b, 'script', str(REPO / 'tools' / 'stlib.shen'), str(kernel / 'klambda' / 'stlib.kl'),
                        with_stlib[b]], check=True, capture_output=True)
    return work, with_stlib


def thorn_expected():
    """What each problem in tests/thorn.expected should print."""
    expected, lines = {}, None
    for line in (REPO / 'tests' / 'thorn.expected').read_text().splitlines():
        if line != 'finished' and re.fullmatch(r'[A-Za-z]+', line):
            lines = expected[line] = []
        else:
            lines.append(line)
    return expected


def thorn_ok(lines):
    """Whether a run prints those lines, picked out as tests/thorn.sh does."""
    def ok(out):
        got = [l for l in out.replace('\r', '').splitlines() if re.search(r' inferences,|is unproved|^finished$', l)]
        return [re.sub(r', equality.*', '', l) for l in got] == lines
    return ok


def workloads(kernel, stlib_dir, loads, copies):
    yes = 'y\n' * 200
    jobs = {
        'startup': (REPO, ['eval', '-e', '1'], '', lambda out: out.strip().endswith('1')),
        'kernel test suite': (kernel / 'tests', ['script', 'runme.shen'], yes,
                              lambda out: re.search(r'failed \.\.\. 0\s*$', out, re.M)),
        'extension tests': (copies, ['script', str(REPO / 'tests' / 'kernel-extensions.shen')], '',
                            lambda out: re.search(r'failed \.\.\. 0\s*$', out, re.M)),
        'standard library install': (stlib_dir, ['eval', '-l', 'install-notk.shen'], '',
                                     lambda out: out.count('\nloaded') + out.startswith('loaded') == loads),
        'contract examples': (REPO, ['script', 'contract/examples.shen'], '',
                              lambda out: re.search(r'\d+ passed, \d+ failed', out)),
    }
    if not stlib_dir:
        del jobs['standard library install']
    expected = thorn_expected()
    for problem in THORN_PROBLEMS:
        jobs[f'THORN {problem}'] = (copies / 'thorn', ['eval', '-l', 'setup.shen', '-l', f'Problems/{problem}.shen',
                                                '-e', '(output "finished~%")'], '', thorn_ok(expected[problem]))
    return jobs


def main(argv):
    rounds, kernel, stlib, scheme, bins = 7, REPO / '.deps' / 'kernel', None, None, []
    while argv:
        a = argv.pop(0)
        if a == '--rounds': rounds = int(argv.pop(0))
        elif a == '--kernel': kernel = Path(argv.pop(0)).resolve()
        elif a == '--stlib': stlib = Path(argv.pop(0)).resolve()
        elif a == '--scheme': scheme = str(Path(argv.pop(0)).resolve())
        else: bins.append(str(Path(a).resolve()))
    if not bins:
        sys.exit(__doc__)
    work, loads = stlib_copy(stlib) if stlib else (None, 0)
    copies, with_stlib = kernel_copy(kernel, bins)
    try:
        jobs = workloads(kernel, work / 'StLib' if work else None, loads, copies)
        everyone = bins + ([scheme] if scheme else [])
        times = {(w, b): [] for w in jobs for b in everyone}
        for r in range(rounds):
            order = everyone[r % len(everyone):] + everyone[:r % len(everyone)]
            for w, (cwd, args, stdin, ok) in jobs.items():
                for b in (order if r % 2 == 0 else order[::-1]):
                    if b == scheme and w in ('standard library install', 'contract examples'):
                        continue
                    t = time.perf_counter()
                    exe = with_stlib.get(b, b) if w.startswith('THORN') else b
                    p = subprocess.run([exe] + args, cwd=cwd, input=stdin,
                                       capture_output=True, text=True, errors='replace')
                    times[(w, b)].append(time.perf_counter() - t)
                    if not ok(p.stdout + p.stderr):
                        sys.exit(f'{w} failed with {b}:\n{p.stdout[-2000:]}{p.stderr[-2000:]}')
                    if w == 'contract examples' and r == 0 and ' 0 failed' not in p.stdout:
                        print(f'{Path(b).name}: {p.stdout.strip().splitlines()[-1]} (examples it predates?)',
                              file=sys.stderr)
            print(f'round {r}', file=sys.stderr, flush=True)
    finally:
        shutil.rmtree(copies)
        if work:
            shutil.rmtree(work)
    names = [Path(b).name for b in bins] + (['Shen/Scheme'] if scheme else [])
    print('| Workload | ' + ' | '.join(f'{n} (ms)' for n in names) + ' |')
    print('| --- |' + ' ---: |' * len(names))
    for w in jobs:
        first = statistics.median(times[(w, bins[0])])
        cells = []
        for b in everyone:
            if not times[(w, b)]:
                cells.append('-')
                continue
            m = statistics.median(times[(w, b)])
            cells.append(f'{m * 1000:.0f}' if b in (bins[0], scheme) else f'{m * 1000:.0f} ({m / first:.2f})')
        print(f'| {w} | ' + ' | '.join(cells) + ' |')


if __name__ == '__main__':
    main(sys.argv[1:])
