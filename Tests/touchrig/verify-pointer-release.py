#!/usr/bin/env python3
"""Check real UIKit touch-rig output for movement/click exclusivity and balanced buttons."""
import json
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
assert 'RIG done' in text, 'touch run did not finish'
cases = {name: body for name, body in re.findall(r'=== TRACKPAD (.*?)\n(.*?)(?=\n===|\nRIG done)', text, re.S)}
assert len(cases) == 12, f'expected 12 cases, got {len(cases)}'
counts = {name: {kind: len(re.findall(r'pointer\.' + kind + r'\(', body))
                 for kind in ('leftDown', 'leftUp', 'rightDown', 'rightUp', 'move')}
          for name, body in cases.items()}
if '--baseline' in sys.argv:
    assert any(counts[name]['leftDown'] for name in ('short move 3', 'short move 8', 'move then return', 'slow short move')), \
        'baseline did not reproduce movement-triggered click'
    print('REPRODUCED: original touch recognizers click during a pointer stroke')
else:
    for name, count in counts.items():
        expected_left = 1 if name in ('tap', 'tiny stationary tap', 'hold drag', 'tap after move') else 0
        expected_right = 1 if name == 'right tap' else 0
        assert count['leftDown'] == count['leftUp'] == expected_left, (name, count)
        assert count['rightDown'] == count['rightUp'] == expected_right, (name, count)
        if name in ('short move 3', 'short move 8', 'move then return', 'slow short move', 'normal move', 'hold drag'):
            assert count['move'] > 0, f'{name}: pointer failed to move'
    print('PASS: 12 native touch scenarios; pointer strokes never click; taps, right click and held drag remain balanced')
print(json.dumps(counts, indent=2))
