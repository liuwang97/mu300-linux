#!/usr/bin/env python3
"""Summarise pm-run.sh runs collected from /tmp/pm (FINDINGS 239).

    python3 tools/power/pm-summary.py DIR LABEL...

Per run: the mean of the samples, the coulomb counter's mean (K mA per count/s, from runs where both were steady),
the current's p10/p50/p90 and the bytes on the bearer and the hotspot. Samples from the first negative one on are
left out (the charger came out of HIZ). With the modem bursting into RRC-connected at random, the mean of a 2-minute
run is noisy (two identical runs differed by 280 mW); p10 is the floor with the modem idle.
"""
import re
import sys
from pathlib import Path

K = 0.742  # mA per coulomb-counter count/s on the U30 Air (481 mA <-> 648 counts/s, 321 mA <-> 426)


def net(text, which):
    part = text.split('net1:')[0].split('net0:')[1] if which == 0 else text.split('net1:')[1].split('\n')[0]
    return {m[0]: (int(m[1]), int(m[2])) for m in re.findall(r'(\w+):(\d+):(\d+)', part)}


def run(d, name):
    csv, summ = d / f'{name}.csv', d / f'{name}.sum'
    if not csv.exists() or not summ.exists():
        return f'{name:10s} (no data)'
    rows = [list(map(int, line.split(','))) for line in csv.read_text().split() if line.count(',') == 3]
    cut = next((i for i, r in enumerate(rows) if r[1] < 0), None)
    note = f'  (cut at sample {cut}: charging)' if cut is not None else ''
    rows = rows[:cut] if cut else rows
    if not rows:
        return f'{name:10s} (no valid samples)'
    v = sorted(r[1] for r in rows)
    p = lambda q: v[min(len(v) - 1, int(q * len(v)))]
    s = summ.read_text()
    clb = re.search(r'clb_per_s_x100=(-?\d+)', s)
    clb_ma = -int(clb.group(1)) / 100 * K if clb else float('nan')
    n0, n1 = net(s, 0), net(s, 1)
    dn = lambda i: tuple((b - a) // 1024 for a, b in zip(n0.get(i, (0, 0)), n1.get(i, (0, 0)))) \
        if i in n0 and i in n1 and n1[i][0] >= n0[i][0] else (0, 0)
    c, w = dn('sipa_eth8'), dn('wlan0')
    return (f'{name:10s} n={len(rows):3d} {sum(v) / len(v):4.0f} mA {sum(r[3] for r in rows) / len(rows):5.0f} mW'
            f'  clb {clb_ma:4.0f} mA  p10/p50/p90 {p(.1)}/{p(.5)}/{p(.9)}'
            f'  cell rx/tx {c[0]}/{c[1]} KB  wlan rx/tx {w[0]}/{w[1]} KB{note}')


if __name__ == '__main__':
    d = Path(sys.argv[1])
    for label in sys.argv[2:]:
        print(run(d, label))
