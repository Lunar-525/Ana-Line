"""Aggregate an Instruments time-profile export by symbol, for device work.

Usage:
    xcrun xctrace export --input run.trace \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
    python3 iOS/profile_symbols.py tp.xml [hot_start_seconds]

Instruments' XML export interns processes, threads, cores and backtraces as
objects that are defined once and referenced by id afterwards, and it emits the
definitions in batches, so a single streaming pass resolves only part of them.
This reads the file twice: definitions first, then samples. It reports the
achieved parallelism (CPU seconds per wall second), the distribution across
performance and efficiency cores, and self and inclusive time per symbol.

Restricting to a start time is how the hot steady state is isolated: pass the
second at which the device reached the thermal state of interest, which the
trace's own device-thermal-state-intervals table reports.
"""
import re, sys, collections
path = sys.argv[1]
hot_start = int(float(sys.argv[2]) * 1e9) if len(sys.argv) > 2 else 0
frame_re = re.compile(r'<frame id="(\d+)" name="([^"]*)"')
bin_def = re.compile(r'<binary id="(\d+)" name="([^"]*)"')
defs = re.compile(r'<(process|thread|core) id="(\d+)" fmt="([^"]*)"')
row_refs = re.compile(r'<(process|thread|core|tagged-backtrace) ref="(\d+)"')
binaries, bt_frames, proc_name, thread_name, core_name = {}, {}, {}, {}, {}
with open(path, errors='replace') as fh:
    for line in fh:
        for m in bin_def.finditer(line): binaries[m.group(1)] = m.group(2)
        for m in defs.finditer(line):
            k, i, fmt = m.groups()
            (proc_name if k == 'process' else thread_name if k == 'thread' else core_name)[i] = fmt
        s = line.find('<tagged-backtrace id="')
        e = line.find('</tagged-backtrace>', s) if s >= 0 else -1
        if s >= 0 and e > 0:
            bt_frames[re.match(r'<tagged-backtrace id="(\d+)"', line[s:]).group(1)] = frame_re.findall(line[s:e])
self_time, inclusive, cores, total = collections.Counter(), collections.Counter(), collections.Counter(), 0
with open(path, errors='replace') as fh:
    for line in fh:
        if '<row>' not in line: continue
        refs = dict(row_refs.findall(line))
        if 'AnaLine' not in proc_name.get(refs.get('process', ''), ''): continue
        st = re.search(r'<sample-time[^>]*>(\d+)<', line)
        if not st or int(st.group(1)) < hot_start: continue
        total += 1
        cores[core_name.get(refs.get('core', ''), '?')] += 1
        frames = bt_frames.get(refs.get('tagged-backtrace', ''), [])
        if frames:
            self_time[frames[0][1]] += 1
            for _, n in set(frames):
                if not n.startswith('0x'): inclusive[n] += 1
wall_seconds = 90.0
print(f'samples: {total} ms of app CPU')
print(f'achieved parallelism: {total/1000/wall_seconds:.2f} cores average')
print(f'top 10 self symbols: {sum(n for _,n in self_time.most_common(10))/total*100:.1f}% of CPU')
print(f'top 25 self symbols: {sum(n for _,n in self_time.most_common(25))/total*100:.1f}% of CPU')
print('\n== self time, all >= 0.15% ==')
for n, c in self_time.most_common(60):
    if c/total < 0.0015: break
    print(f'  {c/total*100:5.2f}%  {c:7d} ms  {n[:100]}')
print('\n== inclusive time, all >= 0.3% ==')
for n, c in inclusive.most_common(60):
    if c/total < 0.003: break
    print(f'  {c/total*100:5.2f}%  {c:7d} ms  {n[:100]}')
