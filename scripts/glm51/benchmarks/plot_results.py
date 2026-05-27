#!/usr/bin/env python3
import argparse
import json
import pathlib
import re
from collections import defaultdict

import matplotlib.pyplot as plt


BACKEND_STYLES = {
    "sglang": {"color": "#2563eb", "marker": "o"},
    "vllm": {"color": "#dc2626", "marker": "s"},
}

TOPOLOGY_STYLES = {
    "tp8_pp1": "-",
    "tp4_pp2": "--",
    "tp2_pp4": "-.",
    "tp1_pp8": ":",
}


def topology_sort_key(topology):
    match = re.fullmatch(r"tp(\d+)_pp(\d+)", topology)
    if not match:
        return (999, 999, topology)
    tp, pp = map(int, match.groups())
    return (-tp, pp, topology)


def load_stage(run_roots, stage):
    rows = []
    for run_root in run_roots:
        for jsonl in sorted(run_root.glob(f"*/{stage}.jsonl")):
            if jsonl.stat().st_size == 0:
                continue
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


def collect_series(rows, x_key, y_key):
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["backend"], row["topology"])].append(
            (int(row[x_key]), float(row[y_key]))
        )
    return {
        key: sorted(values, key=lambda item: item[0])
        for key, values in grouped.items()
        if values
    }


def set_power2_ticks(ax, values):
    values = sorted(set(values))
    ax.set_xticks(values)
    ax.set_xticklabels([str(value) for value in values], rotation=30, ha="right")


def plot_by_topology(rows, x_key, y_key, title, xlabel, ylabel, output_path):
    series = collect_series(rows, x_key, y_key)
    if not series:
        return False

    fig, ax = plt.subplots(figsize=(11, 6.2))
    all_x = []
    for (backend, topology), values in sorted(
        series.items(), key=lambda item: (item[0][0], topology_sort_key(item[0][1]))
    ):
        xs = [x for x, _ in values]
        ys = [y for _, y in values]
        all_x.extend(xs)
        backend_style = BACKEND_STYLES.get(backend, {})
        linestyle = TOPOLOGY_STYLES.get(topology, "-")
        ax.plot(
            xs,
            ys,
            label=f"{backend} {topology}",
            color=backend_style.get("color"),
            marker=backend_style.get("marker", "o"),
            linestyle=linestyle,
            linewidth=2.2,
            markersize=6,
        )

    ax.set_xscale("log", base=2)
    set_power2_ticks(ax, all_x)
    ax.set_title(title, fontsize=15, fontweight="bold")
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.grid(True, which="major", alpha=0.28)
    ax.legend(ncol=2, fontsize=9)
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)
    return True


def best_by_backend(rows, x_key, y_key):
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["backend"], int(row[x_key]))].append(row)

    best = defaultdict(list)
    for (backend, x_value), items in grouped.items():
        row = max(items, key=lambda item: float(item[y_key]))
        best[backend].append((x_value, float(row[y_key]), row["topology"]))
    return {
        backend: sorted(values, key=lambda item: item[0])
        for backend, values in best.items()
    }


def plot_best_by_backend(rows, x_key, y_key, title, xlabel, ylabel, output_path):
    series = best_by_backend(rows, x_key, y_key)
    if not series:
        return False

    fig, ax = plt.subplots(figsize=(10.5, 5.8))
    all_x = []
    for backend, values in sorted(series.items()):
        xs = [x for x, _, _ in values]
        ys = [y for _, y, _ in values]
        labels = [topology for _, _, topology in values]
        all_x.extend(xs)
        backend_style = BACKEND_STYLES.get(backend, {})
        ax.plot(
            xs,
            ys,
            label=backend,
            color=backend_style.get("color"),
            marker=backend_style.get("marker", "o"),
            linewidth=2.5,
            markersize=7,
        )
        for x, y, label in zip(xs, ys, labels):
            ax.annotate(
                label,
                (x, y),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=8,
                color=backend_style.get("color", "#111827"),
            )

    ax.set_xscale("log", base=2)
    set_power2_ticks(ax, all_x)
    ax.set_title(title, fontsize=15, fontweight="bold")
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.grid(True, which="major", alpha=0.28)
    ax.legend(fontsize=10)
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Plot GLM-5.1 benchmark JSONL results."
    )
    parser.add_argument("run_roots", nargs="+", type=pathlib.Path)
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=None,
        help="Directory for PNG plots. Defaults to RUN_ROOT/plots for the first root.",
    )
    args = parser.parse_args()

    run_roots = [path.resolve() for path in args.run_roots]
    output_dir = args.output_dir or (run_roots[0] / "plots")
    output_dir.mkdir(parents=True, exist_ok=True)

    prefill_rows = load_stage(run_roots, "prefill")
    decode_rows = load_stage(run_roots, "decode")

    outputs = []
    plot_specs = [
        (
            plot_by_topology,
            prefill_rows,
            "input_len",
            "input_throughput",
            "Prefill Throughput By Topology",
            "Prefill length (tokens)",
            "Input throughput (tokens/s)",
            output_dir / "prefill_throughput_by_topology.png",
        ),
        (
            plot_by_topology,
            decode_rows,
            "batch_size",
            "output_throughput",
            "Decode Throughput By Topology",
            "Batch size",
            "Output throughput (tokens/s)",
            output_dir / "decode_throughput_by_topology.png",
        ),
        (
            plot_best_by_backend,
            prefill_rows,
            "input_len",
            "input_throughput",
            "Best Prefill Throughput By Backend",
            "Prefill length (tokens)",
            "Input throughput (tokens/s)",
            output_dir / "best_prefill_by_backend.png",
        ),
        (
            plot_best_by_backend,
            decode_rows,
            "batch_size",
            "output_throughput",
            "Best Decode Throughput By Backend",
            "Batch size",
            "Output throughput (tokens/s)",
            output_dir / "best_decode_by_backend.png",
        ),
    ]

    for plotter, rows, x_key, y_key, title, xlabel, ylabel, path in plot_specs:
        if plotter(rows, x_key, y_key, title, xlabel, ylabel, path):
            outputs.append(path)

    for path in outputs:
        print(path)


if __name__ == "__main__":
    main()
