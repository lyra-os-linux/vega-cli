#!/usr/bin/python3
"""Only the old Bash error-presentation suite uses this helper fixture.

The actual transaction algorithm is exercised separately against a real broker.
"""
import json
import os
from pathlib import Path
import sys

config = json.loads(Path(os.environ['FIXTURE_CONFIG']).read_text())
args = sys.argv[sys.argv.index('--') + 1:]
method = args[1]
reply = config.get('methods', {}).get(method, config.get('default', {}))
if 'error' in reply:
    result = dict(success=False, message=reply['error'], key_pending=None)
else:
    event = config.get('signal', [7, True, 'completed'])
    if event is None or event[0] != 7:
        result = dict(success=False, message='Tempo esgotado', key_pending=None)
    else:
        result = dict(success=event[1], message=event[2] or 'Falha sem detalhes', key_pending=None)
print(json.dumps(result))
sys.exit(0 if result['success'] else 1)
