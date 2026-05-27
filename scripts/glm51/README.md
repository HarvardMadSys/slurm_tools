# GLM-5.1 FP8 On 2x4xH200

These scripts launch GLM-5.1-FP8 with SGLang or vLLM on a two-node Slurm
allocation with four H200 GPUs per node. The default target is `tp4_pp2`, and
the benchmark-only tooling lives in `scripts/glm51/benchmarks/`.

## Layout

- `common.sh`: shared defaults and helper functions for Slurm nodes, model paths, ports, logs, and backend arguments.
- `setup_sglang_deps.sh`: installs and validates SGLang dependencies on a GPU node.
- `deploy_tp8pp1.sh`: one-command SGLang `tp8_pp1` deploy with `--stop-first --tunnel` defaults.
- `launch_tp4_pp2.sh`: easy entrypoint for launching either backend with tensor parallel 4 and pipeline parallel 2.
- `launch_tp8_pp1.sh`: easy entrypoint for launching either backend with tensor parallel 8 and pipeline parallel 1.
- `launch_sglang.sh`: launches SGLang across all nodes in the allocation.
- `launch_vllm.sh`: starts a Ray cluster, then launches `vllm serve`.
- `run_sglang_node.sh`: per-node SGLang worker entrypoint used by `launch_sglang.sh`.
- `stop.sh`: stops SGLang, vLLM, Ray, and leftover compile helpers on the allocation.
- `benchmarks/`: HTTP benchmark client, matrix runner, summarizer, plotter, and IB bandwidth checker.

## Defaults

- Model path: `/n/netscratch/juncheng_lab/model/GLM-5.1-FP8-2`
- Logs: `logs/glm51/`
- Results: `logs/glm51/results/`
- HTTP port: `30000`
- Distributed init port: `29500`
- Ray port: `6379`
- Network interface: `ib0`
- Default context length: `202752`
- SGLang tool-call parser: `glm47`
- Reverse tunnel default: `internal.freeinference.org:8002`

Override the model path if you keep the model elsewhere:

```bash
export GLM51_MODEL_LOCAL=/path/to/GLM-5.1-FP8-2
```

## Launch A Server

Use an active two-node H200 allocation. You can pass the job id explicitly, run
inside the allocation, or let `common.sh` try to autodetect a running two-node
H200 job.

Set up or validate SGLang dependencies on the GPU head node:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/setup_sglang_deps.sh
```

Validate without installing:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/setup_sglang_deps.sh --check-only
```

Launch SGLang and export it through the reverse SSH tunnel:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/launch_tp4_pp2.sh sglang --stop-first --tunnel
```

Launch the `tp8_pp1` SGLang topology and export it through the reverse SSH tunnel:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/launch_tp8_pp1.sh sglang --stop-first --tunnel
```

Equivalent one-command deploy wrapper:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/deploy_tp8pp1.sh
```

The tunneled OpenAI-compatible endpoint is:

```text
http://internal.freeinference.org:8002/v1
```

Launch SGLang in the background and create the tunnel when ready:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/launch_tp4_pp2.sh sglang --background --stop-first --tunnel
```

Launch vLLM in the foreground:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/launch_tp4_pp2.sh vllm --stop-first
```

Stop the running service:

```bash
GLM51_JOB_ID=<job_id> scripts/glm51/stop.sh
```

Check readiness from the head node:

```bash
srun --overlap --jobid=<job_id> -N1 -n1 bash -lc \
  'curl -fsS http://127.0.0.1:30000/v1/models'
```

Check readiness through the tunnel:

```bash
curl -fsS http://internal.freeinference.org:8002/v1/models
```

## Run Benchmarks

Benchmark scripts are in `scripts/glm51/benchmarks/`. See
`scripts/glm51/benchmarks/README.md` for the full benchmark workflow.

Run the SGLang matrix:

```bash
GLM51_JOB_ID=<job_id> \
GLM51_BACKENDS=sglang \
GLM51_CONFIGS="8:1 4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

Run the vLLM matrix:

```bash
GLM51_JOB_ID=<job_id> \
GLM51_BACKENDS=vllm \
GLM51_CONFIGS="4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

Measure inter-node InfiniBand bandwidth:

```bash
GLM51_JOB_ID=<job_id> bash scripts/glm51/benchmarks/measure_ib_bw.sh
```

## Results

The cleaned experiment outputs are under `logs/glm51/results/`.

- `20260525_combined_summary.txt`: combined text summary.
- `20260525_combined_all_results.csv`: combined row-level benchmark data.
- `20260525_combined_prefill_winners.csv`: best prefill cases.
- `20260525_combined_decode_winners.csv`: best decode cases.
- `20260525_combined_topology_gmeans.csv`: topology geometric means.
- `plots_20260525_combined/`: generated plots.
- `20260525_experiment_report.md`: notes on failures, fixes, and rerun instructions.

## Practical Notes

- SGLang was easier to set up and was the most reliable backend in these runs.
- vLLM required a patched vLLM source tree for GLM-5.1 FP8 pipeline-parallel loading.
- The known-good multi-node network path is `ib0`; previous bandwidth checks measured roughly 373-376 Gb/s unidirectional and 738-746 Gb/s bidirectional aggregate.
- vLLM `tp8_pp1` was not kept in the default vLLM benchmark command because it previously failed or stalled.
- SGLang can run in the background with `--background`; vLLM is usually easier to debug in the foreground first.

## Useful Environment Variables

- `GLM51_JOB_ID`: Slurm allocation id.
- `GLM51_TP` and `GLM51_PP`: tensor and pipeline parallelism; `tp * pp` must equal total GPUs.
- `GLM51_SERVE_PORT`: HTTP API port.
- `GLM51_DIST_PORT`: distributed initialization port.
- `GLM51_RAY_PORT`: Ray port for vLLM.
- `GLM51_MODEL_LOCAL`: local model path override.
- `GLM51_TOOL_CALL_PARSER`: SGLang OpenAI tool-call parser; defaults to `glm47` for GLM-5-family models.
- `GLM51_TUNNEL_HOST`: reverse SSH tunnel host; defaults to `internal.freeinference.org`.
- `GLM51_TUNNEL_PORT`: reverse SSH tunnel port; defaults to `8002`.
- `GLM51_TUNNEL_BIND`: remote bind address; defaults to `0.0.0.0`.
- `GLM51_LOG_DIR`: launcher log directory.
- `GLM51_RESULTS_DIR`: benchmark result directory.

## Validation

Quick syntax check:

```bash
bash -n scripts/glm51/*.sh scripts/glm51/benchmarks/*.sh
```

Python compile check:

```bash
/n/sw/Miniforge3-25.3.1-0/bin/python3 -m py_compile scripts/glm51/benchmarks/*.py
```
