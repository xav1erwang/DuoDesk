#!/usr/bin/env python3
"""Analyze an owned-fixture timing trace without reading or reconstructing image pixels.

The replay approximates dispatch timers as firing exactly on time; it is not a measurement or
proof of a candidate policy. Compare it with actual output before drawing any conclusions.
"""
import argparse
import json
import math
from pathlib import Path
import tempfile


def replay(raw, fps=120, early=0.0):
    interval = 1.0 / fps
    if not (0 <= early < interval):
        raise ValueError("invalid early tolerance")
    deadline = None
    last = None
    pending = None
    timer = None
    emitted = []

    def emit(index, at):
        if emitted and (at < emitted[-1][1] or index <= emitted[-1][0]):
            raise ValueError("replay would reuse or reorder a source frame")
        emitted.append((index, at))

    for index, row in enumerate(raw):
        pts, arrival = row["pts"], row["arrival"]
        if not (math.isfinite(pts) and math.isfinite(arrival) and arrival >= pts):
            raise ValueError("invalid source clock")
        if last is not None and pts <= last:
            raise ValueError("replay requires strictly ordered source timestamps")
        if timer is not None and timer <= arrival:
            emit(pending, timer)
            deadline += interval
            pending = None
            timer = None
        last = pts
        if deadline is None:
            deadline = pts + interval
            emit(index, arrival)
        elif pts < deadline - early:
            pending = index
            if timer is None:
                timer = max(arrival, deadline)
        else:
            pending = None
            timer = None
            deadline = pts + interval if pts - deadline > 3 * interval else deadline + interval
            emit(index, arrival)
    if timer is not None:
        emit(pending, timer)
    return emitted


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)]


def explain_observed(raw, outputs, fps=120, active_start=None, active_end=None, held_events=None):
    """Reconstruct the pacer's decisions using actual output events, not ideal timer fires.

    Sample callbacks and onFrame delivery share one serial queue. Matching both source index and
    event order tests the reconstruction; apparent timer lateness assumes compatible host clocks.
    """
    interval = 1.0 / fps
    deadline = None
    pending = None
    candidates = []
    due = None
    output_index = 0
    immediate = held = replacements = canceled = 0
    timer_lag = []
    early_timers = 0
    active_immediate = active_held = 0
    local_shifts = {shift: {"same": 0, "older": 0, "beforeDue": 0, "olderPenaltyMs": []}
                    for shift in (0.00025, 0.0005, 0.001, 0.0015)}

    def active(at):
        return (active_start is None or at >= active_start) and (active_end is None or at < active_end)

    def consume_held():
        nonlocal output_index, pending, candidates, due, deadline, held, active_held, early_timers
        output = outputs[output_index]
        if pending is None or output["rawIndex"] != pending or due is None:
            raise ValueError("observed output does not match pending sample")
        lag = output["delivered"] - due
        if active(output["delivered"]):
            active_held += 1
            if held_events is not None:
                held_events.append({"scheduled": candidates[0][1], "due": due, "fired": output["delivered"]})
            if lag < -0.001:
                early_timers += 1
            timer_lag.append(lag * 1000)
            for shift, counts in local_shifts.items():
                shifted = max(candidates[0][1], output["delivered"] - shift)
                available = [index for index, arrival in candidates if arrival <= shifted]
                selected = available[-1]
                if selected == pending:
                    counts["same"] += 1
                else:
                    counts["older"] += 1
                    counts["olderPenaltyMs"].append((raw[pending]["pts"] - raw[selected]["pts"]) * 1000)
                if shifted < due:
                    counts["beforeDue"] += 1
        deadline += interval
        pending = None
        candidates = []
        due = None
        output_index += 1
        held += 1

    for index, row in enumerate(raw):
        pts, arrival = row["pts"], row["arrival"]
        while output_index < len(outputs) and outputs[output_index]["delivered"] < arrival:
            consume_held()
        if deadline is None:
            deadline = pts + interval
            action = "immediate"
        elif pts < deadline:
            if pending is not None:
                replacements += 1
            pending = index
            candidates.append((index, arrival))
            if due is None:
                due = max(arrival, deadline)
            action = "held"
        else:
            if pending is not None:
                canceled += 1
            pending = None
            candidates = []
            due = None
            deadline = pts + interval if pts - deadline > 3 * interval else deadline + interval
            action = "immediate"
        if action == "immediate":
            if output_index >= len(outputs) or outputs[output_index]["rawIndex"] != index:
                raise ValueError("immediate output does not match source callback")
            if outputs[output_index]["delivered"] < arrival:
                raise ValueError("immediate output predates source callback")
            if index + 1 < len(raw) and outputs[output_index]["delivered"] >= raw[index + 1]["arrival"]:
                raise ValueError("immediate output crossed next callback")
            output_index += 1
            immediate += 1
            if active(outputs[output_index - 1]["delivered"]):
                active_immediate += 1
    while output_index < len(outputs):
        consume_held()
    shifts = [{"earlierMs": shift * 1000, "sameCandidate": counts["same"], "olderCandidate": counts["older"],
               "beforeOriginalDue": counts["beforeDue"], "olderCandidatePtsPenaltyP95Ms": percentile(counts["olderPenaltyMs"], 0.95)}
              for shift, counts in local_shifts.items()]
    return {"valid": early_timers == 0, "matchedOutputs": output_index, "immediateOutputs": immediate,
            "heldOutputs": held, "activeImmediateOutputs": active_immediate, "activeHeldOutputs": active_held,
            "heldReplacedByNewerSample": replacements, "heldCanceledByImmediateSample": canceled,
            "apparentTimerLagMsP50": percentile(timer_lag, 0.5), "apparentTimerLagMsP95": percentile(timer_lag, 0.95),
            "apparentTimerLagMsMax": max(timer_lag) if timer_lag else None, "timersEarlierThanAssumedClock": early_timers,
            "localEarlierFireThoughtExperiment": shifts,
            "scope": "uses actual output order; timer lag assumes stream and host clocks are compatible; local shifts assume an earlier fire without modeling downstream rescheduling"}


def analyze(document):
    raw, outputs = document["raw"], document["outputs"]
    start, end = document["start"] + 2.0, document["end"]
    if document.get("version") != 1 or end <= start or not raw or not outputs:
        raise ValueError("unsupported or empty timeline")
    if any(a["arrival"] > b["arrival"] or a["pts"] >= b["pts"] for a, b in zip(raw, raw[1:])):
        raise ValueError("unordered source samples")
    if any(a["delivered"] > b["delivered"] for a, b in zip(outputs, outputs[1:])):
        raise ValueError("unordered outputs")
    for output in outputs:
        index = output["rawIndex"]
        if not isinstance(index, int) or not 0 <= index < len(raw) or output["pts"] != raw[index]["pts"]:
            raise ValueError("output does not map to its source PTS")
        if output["delivered"] < raw[index]["arrival"]:
            raise ValueError("output predates source callback")
    active_raw = [(index, row) for index, row in enumerate(raw) if start <= row["arrival"] < end]
    active_output = [(item["rawIndex"], item["delivered"]) for item in outputs if start <= item["delivered"] < end]
    if len(active_raw) < 2 or len(active_output) < 2:
        raise ValueError("too few active samples")
    actual_indices = [index for index, _ in active_output]
    if any(a >= b for a, b in zip(actual_indices, actual_indices[1:])):
        raise ValueError("actual output reused or reordered a source frame")
    raw_gaps = [(b[1]["arrival"] - a[1]["arrival"]) * 1000 for a, b in zip(active_raw, active_raw[1:])]
    output_gaps = [(b[1] - a[1]) * 1000 for a, b in zip(active_output, active_output[1:])]
    source_skipped = sum(max(0, b - a - 1) for a, b in zip(actual_indices, actual_indices[1:]))
    baseline = [(index, at) for index, at in replay(raw) if start <= at < end]
    baseline_indices = [index for index, _ in baseline]
    common = len(set(actual_indices) & set(baseline_indices))
    recall = common / len(actual_indices)
    precision = common / len(baseline_indices) if baseline_indices else 0.0
    replay_valid = recall >= 0.98 and precision >= 0.98
    try:
        observed = explain_observed(raw, outputs, active_start=start, active_end=end)
    except ValueError as error:
        observed = {"valid": False, "reason": str(error)}
    variants = []
    for tolerance in (0.0, 0.00025, 0.0005, 0.001, 0.0015, 0.002):
        selected = [(index, at) for index, at in replay(raw, early=tolerance) if start <= at < end]
        equal_hash = sum(raw[a[0]]["centerSHA256"] == raw[b[0]]["centerSHA256"] for a, b in zip(selected, selected[1:]))
        variants.append({"earlyMilliseconds": tolerance * 1000, "selected": len(selected),
                         "exactGridHashEqualPairs": equal_hash, "notActualReplay": True})
    return {
        "scope": "owned fixture, one recorded trace; ideal timer replay is not actual scheduling or FPS acceptance",
        "seconds": end - start,
        "rawCallbacks": len(active_raw),
        "actualOutputs": len(active_output),
        "actualSkippedSourceBetweenOutputs": source_skipped,
        "rawArrivalGapMsP50": percentile(raw_gaps, 0.5),
        "rawArrivalGapMsP95": percentile(raw_gaps, 0.95),
        "outputGapMsP50": percentile(output_gaps, 0.5),
        "outputGapMsP95": percentile(output_gaps, 0.95),
        "outputGapsOverOneAndHalfTargetIntervals": sum(gap > 12.5 for gap in output_gaps),
        "idealReplayMatchedActualFrames": common,
        "idealReplayRecall": recall,
        "idealReplayPrecision": precision,
        "idealReplayValidForThisTrace": replay_valid,
        "observedDecisionReconstruction": observed,
        "hypotheticalVariants": variants,
        "interpretation": "hash equality is exact grid equality only; differing hashes do not prove meaningful full-frame change",
    }


def self_test():
    for fps, duration in ((170, 3), (60, 3), (120, 3)):
        raw = [{"pts": i / fps, "arrival": i / fps + 0.001} for i in range(fps * duration)]
        result = replay(raw)
        indices = [index for index, _ in result]
        assert indices == sorted(set(indices)), "duplicate or reordered frame"
        recorded = [{"rawIndex": index, "delivered": at} for index, at in result]
        observed = explain_observed(raw, recorded)
        assert observed["valid"] and observed["matchedOutputs"] == len(result), "observed reconstruction failed"
        assert len(result) <= 120 * duration + 1
        if fps == 60:
            assert len(result) == len(raw), "60-Hz input was repeated or discarded"
        if fps == 170:
            assert len(result) >= 120 * duration - 1, "faster regular source did not fill target cadence"
    try:
        replay([{"pts": 1.0, "arrival": 1.1}, {"pts": 0.5, "arrival": 1.2}])
    except ValueError:
        pass
    else:
        raise AssertionError("unordered source was accepted")
    # Export is numeric timing only and must never overwrite an existing evidence file.
    raw = [{"pts": i / 170, "arrival": i / 170 + 0.001, "centerSHA256": "a" * 64}
           for i in range(170 * 4)]
    outputs = [{"rawIndex": index, "pts": raw[index]["pts"], "delivered": at} for index, at in replay(raw)]
    document = {"version": 1, "start": 0.0, "end": 3.0, "raw": raw, "outputs": outputs}
    with tempfile.TemporaryDirectory() as directory:
        destination = Path(directory) / "schedule.json"
        export_timer_schedule(document, destination)
        exported = destination.read_bytes()
        assert json.loads(exported)["events"], "empty exported schedule"
        try:
            export_timer_schedule(document, destination)
        except FileExistsError:
            pass
        else:
            raise AssertionError("evidence file overwritten")
        assert destination.read_bytes() == exported, "existing evidence changed"
        invalid = dict(document, version=2)
        try:
            export_timer_schedule(invalid, Path(directory) / "invalid.json")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid timeline accepted for timer export")
    print("SAMPLING REPLAY SELF-CHECK PASS: regular 60/120/170-Hz sources, observed-event reconstruction, no duplicate source, invalid order, timer export and no-overwrite; simulation only")


def export_timer_schedule(document, destination):
    # Apply the same version, source ordering, PTS matching, clock and output checks as analysis.
    # The exported schedule must not silently legitimize a malformed trace.
    validated = analyze(document)
    if not validated["observedDecisionReconstruction"].get("valid"):
        raise ValueError("invalid observed timer sequence")
    start, end = document["start"] + 2.0, document["end"]
    events = []
    observed = explain_observed(document["raw"], document["outputs"], active_start=start, active_end=end,
                                held_events=events)
    if not observed["valid"] or not events or any(e["due"] < e["scheduled"] or e["fired"] < e["scheduled"] for e in events):
        raise ValueError("invalid observed timer sequence")
    if any(a["fired"] > b["scheduled"] for a, b in zip(events, events[1:])):
        raise ValueError("overlapping observed timers")
    result = {"version": 1, "scope": "relative numeric timing from one owned-window trace, no image data",
              "duration": end - start,
              "rawOffsets": [row["arrival"] - start for row in document["raw"] if start <= row["arrival"] < end],
              "events": [{"offset": event["scheduled"] - start, "wait": event["due"] - event["scheduled"]}
                         for event in events]}
    with destination.open("x") as handle:
        json.dump(result, handle, separators=(",", ":"), allow_nan=False)
        handle.write("\n")
    print("TIMER SCHEDULE EXPORTED: held events=", len(events), "raw callbacks=", len(result["rawOffsets"]),
          "; estimated due times, no image data")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("timeline", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--export-timers", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.timeline:
        document = json.loads(args.timeline.read_text())
        if args.export_timers:
            export_timer_schedule(document, args.export_timers)
        else:
            print(json.dumps(analyze(document), indent=2))
    else:
        parser.error("supply a timeline or --self-test")


if __name__ == "__main__":
    main()
