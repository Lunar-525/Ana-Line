"""Summarize actual device reports; no speed assertions or fabricated results.

Every derived number is recomputed from the per-frame samples, so reports from
schema 1, 2 and 3 all summarize. When the app also stored its own summary, the
two are compared and a mismatch is reported rather than hidden.

Metric definitions:
  Rate mean     nominal frame budget / mean processing time. Above 100% means the
                chain is capable of more than the standard's frame rate,
                independent of whether the loop was paced.
  Rate P95      the same against the 95th percentile: the tail-safe rate.
  Delivered     frames actually produced per wall-clock second, as a percentage
                of the standard's frame rate. This is what a viewer would see.
  Lag           milliseconds the loop has fallen behind the ideal frame schedule.
"""
import json
import statistics
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
thermal_names = ["nominal", "fair", "serious", "critical"]


def thermal_name(state: int) -> str:
    return thermal_names[state] if 0 <= state < len(thermal_names) else "unknown"


print(f"Device: {report['hardware']} | {report['os']} | schema={report.get('schemaVersion')} | "
      f"started={report.get('startedAt')}")
print(f"Profile: {report.get('chainProfile', '?')} | workers={report.get('parallelWorkers', '?')} | "
      f"qos={report.get('dspQoS', '?')} | variant={report.get('optimizationVariant', '?')} | "
      f"completed={report['completed']}")
if report.get('failure'):
    print('Failure:', report['failure'])

print()
print('| System / scenario | Frames | Mean ms | P50 | P95 | Peak | Rate mean | Rate P95 | Delivered | Lag ms | Over budget | Locked | Peak MB | Thermal % |')
print('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |')
stages_by_case = []
for case in report['cases']:
    samples = case['samples']
    if not samples:
        continue
    values = sorted(s['processingMS'] for s in samples)
    count = len(values)
    budget = case['budgetMS']
    nominal = 1000.0 / budget
    mean = statistics.mean(values)
    median = values[count // 2]
    p95 = values[min(count - 1, int((count - 1) * .95))]
    peak = values[-1]
    elapsed = samples[-1]['elapsedSeconds']
    over = sum(v > budget for v in values)
    locked = sum(1 for s in samples if s['locked'])
    memory = max((s['memoryMB'] or 0) for s in samples)
    effective = count / elapsed if elapsed > 0 else 0
    lag = max(0.0, (elapsed - count / nominal) * 1000)
    thermal = {}
    for s in samples:
        name = thermal_name(s['thermalState'])
        thermal[name] = thermal.get(name, 0) + 1
    mix = ' '.join(f"{k} {v / count:.0%}" for k, v in sorted(thermal.items()))
    print(f"| {case['system']} / {case['scenario']} | {count} | {mean:.2f} | {median:.2f} | {p95:.2f} | "
          f"{peak:.2f} | {budget / mean * 100:.0f}% | {budget / p95 * 100:.0f}% | "
          f"{effective / nominal * 100:.0f}% | {lag:.0f} | {over} ({over / count:.0%}) | "
          f"{locked}/{count} | {memory:.1f} | {mix} |")
    assert all(s['audioValid'] for s in samples), 'Invalid audio/frame sample'
    if 'stagesMS' in samples[0]:
        stages = {key: statistics.mean(s['stagesMS'].get(key, 0) for s in samples)
                  for key in samples[0]['stagesMS']}
        stages_by_case.append((f"{case['system']} / {case['scenario']}", budget, stages))

for case in report['cases']:
    if not case.get('samples') or 'meanMS' not in case:
        continue
    stored = case['meanMS']
    actual = statistics.mean(s['processingMS'] for s in case['samples'])
    if abs(stored - actual) > 0.01:
        print(f"WARNING: stored mean for {case['system']} / {case['scenario']} is {stored:.2f} "
              f"but the samples average {actual:.2f}")

if stages_by_case:
    print()
    print('Per-stage time as a percentage of the frame budget (mean):')
    keys = list(stages_by_case[0][2].keys())
    print('| System / scenario | ' + ' | '.join(keys) + ' | sum |')
    print('| --- | ' + ' | '.join('---:' for _ in keys) + ' | ---: |')
    for name, budget, stages in stages_by_case:
        cells = [f"{stages[k] / budget * 100:.0f}%" for k in keys]
        total = sum(stages.values()) / budget * 100
        print(f'| {name} | ' + ' | '.join(cells) + f' | {total:.0f}% |')
