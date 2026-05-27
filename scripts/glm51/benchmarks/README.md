# GLM-5.1 Benchmark Scripts

Benchmark-only helpers for the GLM-5.1 FP8 experiments live here. Runtime launch
helpers stay one directory up in `scripts/glm51/`.

## Files

- `run_benchmarks.sh`: launches backend/topology matrices and runs prefill/decode HTTP benchmarks.
- `bench_http.py`: OpenAI-compatible HTTP benchmark client.
- `summarize_results.py`: builds text and CSV summaries from JSONL benchmark output.
- `plot_results.py`: creates result plots from summary CSV files.
- `measure_ib_bw.sh`: measures inter-node InfiniBand bandwidth for the active Slurm allocation.

## Run Benchmarks

Set `GLM51_JOB_ID` to the active 2-node H200 Slurm job, or run from inside that
job allocation.

```bash
GLM51_JOB_ID=<job_id> \
GLM51_BACKENDS=sglang \
GLM51_CONFIGS="8:1 4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

```bash
GLM51_JOB_ID=<job_id> \
GLM51_BACKENDS=vllm \
GLM51_CONFIGS="4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

Useful knobs:

- `GLM51_PREFILL_LENGTHS="1024 2048 4096 8192 16384 32768 65536 131072"`
- `GLM51_DECODE_BATCHES="1 2 4 8 16 32 64 128"`
- `GLM51_RUN_ID=<name>` to choose the output folder under `logs/glm51/results/`.

## Summarize And Plot

```bash
/n/sw/Miniforge3-25.3.1-0/bin/python3 \
  scripts/glm51/benchmarks/summarize_results.py \
  logs/glm51/results/<run_id>
```

```bash
/n/sw/Miniforge3-25.3.1-0/bin/python3 \
  scripts/glm51/benchmarks/plot_results.py \
  logs/glm51/results/<run_id>_all_results.csv \
  logs/glm51/results/plots_<run_id>
```

## Measure Network Bandwidth

```bash
GLM51_JOB_ID=<job_id> bash scripts/glm51/benchmarks/measure_ib_bw.sh
```
