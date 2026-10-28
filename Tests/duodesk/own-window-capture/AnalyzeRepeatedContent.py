#!/usr/bin/env python3
"""Analyze same-marker, same-grid outputs in a saved owned-fixture timing trace.

Only compares synthetic marker IDs and grid SHA-256 hashes already in the trace. It cannot prove
whole-screen equality, compositor presentation, or that delaying an output improves frame rate.
"""
import argparse
import json
import math
from pathlib import Path

from AnalyzeSamplingTimeline import analyze, percentile


def content_repeat_stats(raw, outputs, start, end, interval=1 / 120):
    if not (math.isfinite(start) and math.isfinite(end) and end > start and interval > 0):
        raise ValueError('invalid time range')
    if any(a['arrival'] > b['arrival'] for a, b in zip(raw, raw[1:])):
        raise ValueError('unordered source arrivals')
    if any(a['delivered'] > b['delivered'] or a['rawIndex'] >= b['rawIndex']
           for a, b in zip(outputs, outputs[1:])):
        raise ValueError('reused or unordered output')
    if any(not isinstance(row.get('marker'), int) or not 0 <= row['marker'] < 4096 or
           not isinstance(row.get('centerSHA256'), str) or len(row['centerSHA256']) != 64 or
           any(c not in '0123456789abcdef' for c in row['centerSHA256']) for row in raw):
        raise ValueError('missing marker or center hash')

    def key(row):
        return row['marker'], row['centerSHA256']

    repeated = marker_grid_mismatch = changed_available = no_later = 0
    later_lag_ms = []
    active_pairs = 0
    for previous, current in zip(outputs, outputs[1:]):
        if not (start <= previous['delivered'] < end and start <= current['delivered'] < end):
            continue
        a, b = previous['rawIndex'], current['rawIndex']
        if not (isinstance(a, int) and isinstance(b, int) and 0 <= a < b < len(raw)):
            raise ValueError('output source index is missing or reused')
        left, right = raw[a], raw[b]
        same_marker = left['marker'] == right['marker']
        same_grid = left['centerSHA256'] == right['centerSHA256']
        active_pairs += 1
        if same_marker != same_grid:
            marker_grid_mismatch += 1
        if not (same_marker and same_grid):
            continue
        repeated += 1
        if any(previous['delivered'] < row['arrival'] <= current['delivered'] and key(row) != key(left)
               for row in raw[a + 1:b + 1]):
            changed_available += 1
        following = next((row for row in raw[b + 1:] if current['delivered'] < row['arrival'] < end
                          and key(row) != key(right)), None)
        if following is None:
            no_later += 1
        else:
            later_lag_ms.append((following['arrival'] - current['delivered']) * 1000)
    return {
        'activeOutputPairs': active_pairs,
        'sameMarkerAndCenterHashPairs': repeated,
        'markerAndCenterDisagreePairs': marker_grid_mismatch,
        'differentSourceArrivedSincePreviousDelivery': changed_available,
        'laterDifferentSourceObservedBeforeWindowEnd': len(later_lag_ms),
        'laterDifferentSourceWithinOneTargetInterval': sum(lag <= interval * 1000 for lag in later_lag_ms),
        'laterDifferentSourceLagMsP50': percentile(later_lag_ms, .5),
        'laterDifferentSourceLagMsP95': percentile(later_lag_ms, .95),
        'noLaterDifferentSourceBeforeWindowEnd': no_later,
        'scope': 'same synthetic marker and sampled center hash only; arrivals are callback times, not compositor presentation; no policy or FPS proof',
    }


def analyze_document(document):
    # Require the established PTS/output ordering and serial callback reconstruction first.
    baseline = analyze(document)
    reconstruction = baseline['observedDecisionReconstruction']
    if not reconstruction.get('valid') or reconstruction['matchedOutputs'] != len(document['outputs']):
        raise ValueError('observed callback reconstruction failed')
    markers = [row['marker'] for row in document['draws']]
    if len(markers) != len(set(markers)):
        raise ValueError('draw markers are ambiguous')
    known = set(markers) | {0}
    if any(row['marker'] not in known for row in document['raw']):
        raise ValueError('unknown marker')
    result = content_repeat_stats(document['raw'], document['outputs'], document['start'] + 2, document['end'])
    result['reconstructedOutputs'] = reconstruction['matchedOutputs']
    return result


def self_test():
    def row(at, marker, char):
        return {'arrival': at, 'marker': marker, 'centerSHA256': char * 64}
    raw = [row(.01, 1, 'a'), row(.02, 1, 'a'), row(.023, 2, 'b'), row(.03, 2, 'b')]
    output = [{'rawIndex': 0, 'delivered': .011}, {'rawIndex': 1, 'delivered': .021},
              {'rawIndex': 2, 'delivered': .024}, {'rawIndex': 3, 'delivered': .031}]
    result = content_repeat_stats(raw, output, 0, .04)
    assert result['activeOutputPairs'] == 3 and result['sameMarkerAndCenterHashPairs'] == 2
    assert result['differentSourceArrivedSincePreviousDelivery'] == 0
    assert result['laterDifferentSourceObservedBeforeWindowEnd'] == 1
    assert result['laterDifferentSourceWithinOneTargetInterval'] == 1
    assert abs(result['laterDifferentSourceLagMsP50'] - 2.0) < 1e-9
    assert result['noLaterDifferentSourceBeforeWindowEnd'] == 1
    try:
        content_repeat_stats(raw, output + [output[-1]], 0, .04)
    except ValueError:
        pass
    else:
        raise AssertionError('duplicate output index accepted')
    print('REPEATED CONTENT ANALYSIS PASS: active pairs, later arrival, end censoring, duplicate index rejection; synthetic trace')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('timeline', nargs='?', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.timeline:
        print(json.dumps(analyze_document(json.loads(args.timeline.read_text())), indent=2))
    else:
        parser.error('supply a timeline or --self-test')


if __name__ == '__main__':
    main()
