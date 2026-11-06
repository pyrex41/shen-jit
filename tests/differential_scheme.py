#!/usr/bin/env python3
"""The primitives of tests/differential.shen on Shen/JIT and on another implementation, by default Shen/Scheme.

A difference is a question, not a failure: either side may be wrong, so this reports and checks nothing.
Numbers are compared by value, as they print differently. Usage: differential_scheme.py SHEN_JIT OTHER DIR"""
import os, re, subprocess, sys

NUMBER = re.compile(r"(?<![\w.\"-])-?\d+(\.\d*)?(e[-+]?\d+)?(?![\w.\"-])")
SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "differential.shen")

def number(match):
    text = match.group(0)
    if text.lstrip("-").isdigit():
        return text
    return repr(float(text))

def run(shen, prim, path):
    subprocess.run([shen, "script", SOURCE, "--portable", prim, path], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    with open(path, encoding="utf-8", errors="replace", newline="\n") as f:
        return [NUMBER.sub(number, line.rstrip("\n")) for line in f]

def main(shen, other, out):
    os.makedirs(out, exist_ok=True)
    prims = subprocess.run([shen, "script", SOURCE, "--portable"], stdin=subprocess.DEVNULL, capture_output=True,
                           text=True).stdout.split()
    for prim in prims:
        name = prim.encode().hex()
        ours = run(shen, prim, os.path.join(out, name + ".ours"))
        theirs = run(other, prim, os.path.join(out, name + ".theirs"))
        rows = [(a, b) for a, b in zip(ours, theirs) if a != b]
        print(f"{prim}: {len(ours)} calls ({len(theirs)} there), {len(rows)} differ")
        with open(os.path.join(out, name + ".diff"), "w") as f:
            for a, b in rows:
                f.write(f"{a}\n  there: {b.split(') ', 1)[-1]}\n")

main(*sys.argv[1:4])
