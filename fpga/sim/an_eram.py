import sys

path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
rows = []
started = False
for l in lines:
    if l.startswith('+') or l.startswith('-') or not l.strip():
        continue
    if not l.startswith('|'):
        if started and len(rows) > 0:
            break
        continue
    c = [x.strip() for x in l.split('|')[1:-1]]
    if len(c) < 12:
        continue
    if c[0] == 'Instance':
        started = True
        continue
    try:
        eram = int(c[5]); lut = int(c[2]); seq = int(c[4])
    except ValueError:
        continue
    rows.append((eram, lut, seq, c[0], c[1]))

rows.sort(key=lambda r: -r[0])
print('rows:', len(rows))
for r in rows[:26]:
    print('eram=%3d lut=%6d seq=%6d  %-46s %s' % (r[0], r[1], r[2], r[3][:46], r[4][:24]))
print()
rows.sort(key=lambda r: -r[1])
print('--- by LUT ---')
for r in rows[:18]:
    print('lut=%6d eram=%3d seq=%6d  %-46s %s' % (r[1], r[0], r[2], r[3][:46], r[4][:24]))
