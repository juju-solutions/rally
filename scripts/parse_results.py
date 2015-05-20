#!/usr/bin/env python

import os
import sys
import json

from charmbenchmark import Benchmark

if not sys.argv[1] or not os.path.exists(sys.argv[1]):
    sys.exit(1)

with open(sys.argv[1]) as f:
    results = json.loads(f.read())

# We only handle 1 scenario ATM

result = results[0]

b = Benchmark()

b.set_data({'results.full_duration.value': result['full_duration']})
b.set_data({'results.full_duration.units': 'seconds'})
b.set_data({'results.full_duration.direction': 'asc'})

b.set_data({'results.load_duration.value': result['load_duration']})
b.set_data({'results.full_duration.units': 'seconds'})
b.set_data({'results.full_duration.direction': 'asc'})

actions = {'total': 0}
total = len(result['result'])

for r in result['result']:
    actions['total'] += r.duration
    for a, v in r['atomic_actions'].iteritems():
        if a not in actions:
            actions[a] = 0

        actions[a] += v

for a, v in actions:
    b.set_data({'results.%s.value' % a, round(v / total, 3)})
    b.set_data({'results.%s.units' % a, 'seconds'})
    b.set_data({'results.%s.direction' % a, 'asc'})
