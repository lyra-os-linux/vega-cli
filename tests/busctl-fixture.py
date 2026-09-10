#!/usr/bin/env python3
"""Closed fixture: never forwards calls to the real system bus."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
config = json.loads(Path(os.environ['FIXTURE_CONFIG']).read_text())
with Path(os.environ['FIXTURE_LOG']).open('a') as log:
    log.write(json.dumps(args) + '\n')
if 'wait' in args:
    signal = config.get('signal', [7, True, 'completed'])
    if signal is not None:
        print(json.dumps({'data': signal}))
    sys.exit(0)
if 'call' not in args or 'org.lyraos.Vega1' not in args:
    raise SystemExit('Unexpected fixture command')
method = args[args.index('call') + 4]
reply = config.get('methods', {}).get(method, config.get('default', {}))
if method == 'SetRepoEnabled' and args[-2] == 'bad':
    reply = {'error': 'Call failed: first repo failed', 'rc': 5}
if 'error' in reply:
    print(reply['error'], file=sys.stderr)
    sys.exit(reply.get('rc', 9))
print(reply.get('raw', json.dumps({'data': reply.get('data', [7])})))
