#!/usr/bin/env python3
import argparse
import csv
import json
import math
import pathlib
from collections import defaultdict


def load_stage(run_roots, stage: str):
    rows = []
    for run_root in run_roots:
        for jsonl in sorted(run_root.glob(f"*/{stage}.jsonl")):
            parent = jsonl.parent.name
            if "_" not in parent:
                continue
            backend, topology = parent.split("_", 1)
            with jsonl.open() as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    row = json.loads(line)
                    row["backend"] = backend
                    row["topology"] = topology
                    row["stage"] = stage
                    row["run_root"] = str(run_root)
                    rows.append(row)
    return rows


def geom_mean(values):
    values = [v for v in values if v and v > 0]
    if not values:
        return None
    return math.exp(sum(math.log(v) for v in values) / len(values))


def write_csv(path: pathlib.Path, fieldnames, rows):
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def summarize_prefill(rows):
    winners = []
    grouped = defaultdict(list)
    by_backend_topology = defaultdict(list)
    for row in rows:
        grouped[(row["backend"], int(row["input_len"]))].append(row)
        by_backend_topology[(row["backend"], row["topology"])].append(
            float(row["input_throughput"])
        )

    for (backend, input_len), items in sorted(grouped.items()):
        best = max(items, key=lambda item: float(item["input_throughput"]))
        winners.append(
            {
                "backend": backend,
                "input_len": input_len,
                "best_topology": best["topology"],
                "input_throughput": round(float(best["input_throughput"]), 2),
                "ttft_s": round(float(best["last_ttft"]), 4),
            }
        )

    averages = []
    for (backend, topology), values in sorted(by_backend_topology.items()):
        gm = geom_mean(values)
        if gm is None:
            continue
        averages.append(
            {
                "backend": backend,
                "topology": topology,
                "metric": "prefill_input_throughput_gmean",
                "value": round(gm, 2),
            }
        )
    return winners, averages


def summarize_decode(rows):
    winners = []
    grouped = defaultdict(list)
    by_backend_topology = defaultdict(list)
    for row in rows:
        grouped[(row["backend"], int(row["batch_size"]))].append(row)
        by_backend_topology[(row["backend"], row["topology"])].append(
            float(row["output_throughput"])
        )

    for (backend, batch_size), items in sorted(grouped.items()):
        best = max(items, key=lambda item: float(item["output_throughput"]))
        winners.append(
            {
                "backend": backend,
                "batch_size": batch_size,
                "best_topology": best["topology"],
                "output_throughput": round(float(best["output_throughput"]), 2),
                "latency_s": round(float(best["latency"]), 4),
            }
        )

    averages = []
    for (backend, topology), values in sorted(by_backend_topology.items()):
        gm = geom_mean(values)
        if gm is None:
            continue
        averages.append(
            {
                "backend": backend,
                "topology": topology,
                "metric": "decode_output_throughput_gmean",
                "value": round(gm, 2),
            }
        )
    return winners, averages


def print_section(title, rows, key_name, metric_name):
    print(title)
    if not rows:
        print("  no results")
        return
    last_backend = None
    for row in rows:
        backend = row["backend"]
        if backend != last_backend:
            print(f"  {backend}")
            last_backend = backend
        print(
            f"    {key_name}={row[key_name]} best={row['best_topology']} {metric_name}={row[metric_name]}"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Summarize GLM-5.1 benchmark JSONL results."
    )
    parser.add_argument("run_roots", nargs="+", type=pathlib.Path)
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=None,
        help="Directory for CSV outputs. Defaults to the first RUN_ROOT.",
    )
    args = parser.parse_args()

    run_roots = [path.resolve() for path in args.run_roots]
    output_root = (args.output_dir or run_roots[0]).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    prefill_rows = load_stage(run_roots, "prefill")
    decode_rows = load_stage(run_roots, "decode")

    prefill_winners, prefill_averages = summarize_prefill(prefill_rows)
    decode_winners, decode_averages = summarize_decode(decode_rows)

    all_rows = prefill_rows + decode_rows
    write_csv(
        output_root / "all_results.csv",
        [
            "run_root",
            "backend",
            "topology",
            "stage",
            "batch_size",
            "input_len",
            "output_len",
            "latency",
            "input_throughput",
            "output_throughput",
            "overall_throughput",
            "last_ttft",
            "last_gen_throughput",
            "acc_length",
        ],
        all_rows,
    )
    write_csv(
        output_root / "prefill_winners.csv",
        ["backend", "input_len", "best_topology", "input_throughput", "ttft_s"],
        prefill_winners,
    )
    write_csv(
        output_root / "decode_winners.csv",
        ["backend", "batch_size", "best_topology", "output_throughput", "latency_s"],
        decode_winners,
    )
    write_csv(
        output_root / "topology_gmeans.csv",
        ["backend", "topology", "metric", "value"],
        prefill_averages + decode_averages,
    )

    print_section("Prefill Winners", prefill_winners, "input_len", "input_throughput")
    print_section("Decode Winners", decode_winners, "batch_size", "output_throughput")

    print("Topology GMeans")
    gmeans = prefill_averages + decode_averages
    if not gmeans:
        print("  no results")
    else:
        for row in gmeans:
            print(
                f"  {row['backend']} {row['topology']} {row['metric']}={row['value']}"
            )


if __name__ == "__main__":
    main()
