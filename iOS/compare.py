"""Compare two or more device reports case by case.

Usage: python3 iOS/compare.py report-a.json report-b.json [report-c.json ...]

The first report is the reference. Each following report is reported against the
one before it, so a sequence of runs reads as consecutive differences rather
than as one baseline against everything. Absolute times on a single phone drift
by more than 100% as it throttles, so the thermal mix of every case is printed
next to the times and the differences are the only numbers worth comparing.
"""
import json
import statistics
import sys
from pathlib import Path

thermal_names = ["nominal", "fair", "serious", "critical"]


def load(path):
    report = json.loads(Path(path).read_text())
    cases = {}
    for case in report['cases']:
        samples = case['samples']
        if not samples:
            continue
        values = [s['processingMS'] for s in samples]
        elapsed = samples[-1]['elapsedSeconds']
        budget = case['budgetMS']
        nominal = 1000.0 / budget
        thermal = {}
        for s in samples:
            name = thermal_names[s['thermalState']] if 0 <= s['thermalState'] < 4 else 'unknown'
            thermal[name] = thermal.get(name, 0) + 1
        cases[(case['system'], case['scenario'])] = dict(
            label=Path(path).name, hardware=report.get('hardware', '?'),
            profile=report.get('chainProfile', '?'), workers=report.get('parallelWorkers', '?'),
            qos=report.get('dspQoS', '?'), frames=len(values),
            mean=statistics.mean(values), p95=sorted(values)[min(len(values)-1, int((len(values)-1) * .95))],
            rate=budget / statistics.mean(values) * 100,
            delivered=(len(values) / elapsed / nominal * 100) if elapsed > 0 else 0,
            thermal=' '.join(f"{k} {v / len(values):.0%}" for k, v in sorted(thermal.items())))
    return report, cases


if len(sys.argv) < 3:
    print(__doc__)
    raise SystemExit(2)

reports = [load(path) for path in sys.argv[1:]]
for report, cases in reports:
    print(f"{cases and next(iter(cases.values()))['label']}: {report.get('hardware')} | "
          f"profile={report.get('chainProfile')} workers={report.get('parallelWorkers')} "
          f"qos={report.get('dspQoS')} | completed={report.get('completed')} | started={report.get('startedAt')}")

order = [key for key in reports[0][1] if all(key in cases for _, cases in reports)]
for system, scenario in order:
    print()
    print(f"### {system} / {scenario}")
    print('| run | frames | mean ms | p95 ms | rate | delivered | thermal | Δ mean vs previous |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: |')
    previous = None
    for _, cases in reports:
        row = cases[(system, scenario)]
        delta = '' if previous is None else f"{row['mean'] - previous:+.2f} ms ({row['mean'] / previous * 100 - 100:+.1f}%)"
        print(f"| {row['label']} | {row['frames']} | {row['mean']:.2f} | {row['p95']:.2f} | {row['rate']:.0f}% | "
              f"{row['delivered']:.0f}% | {row['thermal']} | {delta} |")
        previous = row['mean']
