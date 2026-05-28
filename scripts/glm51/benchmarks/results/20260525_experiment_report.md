# GLM-5.1 FP8 vLLM/SGLang Benchmark Report

Date: 2026-05-26

Workspace: `/n/home07/juncheng/workspace/slurm_tools`

Model used: `/n/netscratch/juncheng_lab/model/GLM-5.1-FP8-2`

Hardware allocation: 2 nodes, 4 H200 GPUs per node, 8 GPUs total

## Final Artifacts

The cleaned final results are under:

- `logs/glm51/results/20260525_combined_summary.txt`
- `logs/glm51/results/20260525_combined_all_results.csv`
- `logs/glm51/results/20260525_combined_prefill_winners.csv`
- `logs/glm51/results/20260525_combined_decode_winners.csv`
- `logs/glm51/results/20260525_combined_topology_gmeans.csv`
- `logs/glm51/results/plots_20260525_combined/`
- `logs/glm51/results/20260525_api_sglang_matrix/`
- `logs/glm51/results/20260525_api_vllm_matrix/`

Reusable scripts are under:

- `scripts/glm51/benchmarks/run_benchmarks.sh`
- `scripts/glm51/launch_sglang.sh`
- `scripts/glm51/launch_vllm.sh`
- `scripts/glm51/benchmarks/bench_http.py`
- `scripts/glm51/benchmarks/summarize_results.py`
- `scripts/glm51/benchmarks/plot_results.py`
- `scripts/glm51/benchmarks/measure_ib_bw.sh`
- `scripts/glm51/stop.sh`

## High-Level Outcome

For prefill, vLLM was strongest at long context once pipeline parallelism was working. The best long-prefill configuration was `vllm tp1_pp8`, reaching about `19.6k input tokens/s` at 128k context.

For decode, SGLang was strongest overall. The best decode configuration was `sglang tp8_pp1`, reaching about `3501 output tokens/s` at batch size 128.

Recommended practical configurations:

- Long prefill: `vllm tp1_pp8`
- General vLLM prefill: `vllm tp4_pp2`
- SGLang decode: `sglang tp8_pp1`
- vLLM decode: `vllm tp4_pp2`

## Network Measurement

The successful multi-node runs used:

- interface: `ib0`
- IB device: `mlx5_0`
- server node: `holygpu8a12204` (`10.31.181.9`)
- client node: `holygpu8a12604` (`10.31.181.21`)

Measured on 2026-05-26 with `ib_write_bw` and `ib_send_bw` over native InfiniBand, 10-second runs, default 64 KiB payload, RC transport:

- `write_uni`: `373.01 Gb/s`
- `write_bi`: `746.21 Gb/s` aggregate
- `send_uni`: `376.00 Gb/s`
- `send_bi`: `738.22 Gb/s` aggregate

Raw logs and summary are under:

- `logs/glm51/results/bandwidth/20260526_100702/`

These numbers are consistent with a `400 Gb/s` NDR InfiniBand link: single-direction bandwidth is around line rate once protocol overhead is included, and bidirectional bandwidth is roughly double.

## What Did Not Work

### Model Path

The originally requested path used `/models/`, but the model was actually available at:

```bash
/n/netscratch/juncheng_lab/model/GLM-5.1-FP8-2
```

The scripts now default to that working path via `GLM51_MODEL_LOCAL`.

### SGLang Built-In Benchmark Path

SGLang's built-in benchmark path was not reliable because the `/flush_cache` API failed in this setup.

Fix:

- I switched to `scripts/glm51/benchmarks/bench_http.py`, which benchmarks through the OpenAI-compatible HTTP API.
- This made SGLang and vLLM use the same request path and output format.

### SGLang Pipeline Parallel Long Prefill

SGLang `tp4_pp2`, `tp2_pp4`, and `tp1_pp8` failed the 64k and 128k prefill cases after retry.

What still worked:

- SGLang `tp8_pp1` completed all prefill lengths, including 64k and 128k.
- All SGLang configurations completed decode.

Interpretation:

- For SGLang long-context prefill, prefer `tp8_pp1`.
- For SGLang decode, `tp8_pp1` is clearly the best configuration.

### vLLM Wheel Compatibility

The installed vLLM wheel did not work because it imported CUDA 13 libraries, while the cluster environment was CUDA 12.9.

The official `v0.21.0+cu129` wheel also did not install cleanly because its manylinux tag required a newer baseline than these Rocky/RHEL 8 nodes support.

Fix:

- I built vLLM `v0.21.0+cu129` from source in:

```bash
/n/netscratch/juncheng_lab/build/vllm-v0.21.0-src
```

- The vLLM Python environment is:

```bash
/n/netscratch/juncheng_lab/venvs/vllm-0.21.0-cu129/bin/python
```

- Ray was installed into that vLLM environment for distributed serving.

### vLLM Multi-Node Networking

vLLM/Ray initially mixed hostname/FQDN resolution with Ethernet and InfiniBand addresses. That led to c10d/NCCL startup warnings and hangs.

Fix:

- The launcher now uses `ib0` by default:

```bash
GLM51_VLLM_SOCKET_IFNAME=ib0
GLM51_NODE_IP_IFNAME=ib0
```

- It also forces IPv4 distributed setup and exports the relevant NCCL/Gloo/Ray variables.
- vLLM custom all-reduce is disabled by default:

```bash
GLM51_VLLM_DISABLE_CUSTOM_ALL_REDUCE=1
```

### vLLM GLM-5.1 FP8 Pipeline-Parallel Loader Bug

vLLM crashed for pipeline-parallel configurations with:

```text
KeyError: 'layers.0.self_attn.indexer.wk_weights_proj.weight'
```

Root cause:

- GLM-5.1 FP8 uses the DeepSeek-V2/DSA-style FP8 indexer loader path in vLLM.
- Pipeline-parallel ranks see checkpoint tensors for layers they do not own.
- The FP8 indexer fusion path tried to load a fused parameter before checking whether that layer existed on the local pipeline rank.

Fix:

- I patched the local editable vLLM source at:

```bash
/n/netscratch/juncheng_lab/build/vllm-v0.21.0-src/vllm/model_executor/models/deepseek_v2.py
```

- The patch makes `_try_load_fp8_indexer_wk(...)` skip non-local pipeline-parallel parameters when the fused destination parameter is absent.

If vLLM is rebuilt from scratch, this patch must be re-applied unless upstream vLLM has fixed the issue.

### vLLM Startup Timeout

vLLM startup for this 704 GiB FP8 checkpoint is slow. It includes:

- NFS checkpoint loading
- Ray worker startup
- torch compile
- DeepGEMM warmup
- CUDA graph capture
- KV-cache profiling

The original readiness timeout was too short and killed a launch that was still making progress.

Fix:

- `GLM51_VLLM_READY_TIMEOUT` now defaults to `3600` seconds.
- Node-local cache directories are shared per job/node to make reruns faster.

### vLLM `tp8_pp1`

vLLM `tp8_pp1` still did not complete. It stalled before HTTP readiness during multi-node tensor-parallel startup.

Current recommendation:

- Do not include `vllm tp8_pp1` in the default rerun matrix.
- Use `vllm tp4_pp2`, `tp2_pp4`, and `tp1_pp8`.
- If you specifically want to debug vLLM tensor parallel across nodes, run `tp8_pp1` separately so it does not block the full matrix.

## How To Run The Experiment Again

### 1. Get A 2-Node H200 Allocation

Use the same style of allocation as before: 2 nodes, 4 H200 GPUs per node.

If you run inside the Slurm allocation, `SLURM_JOB_ID` should already be available. If you launch from the login node against an existing allocation, set:

```bash
export GLM51_JOB_ID=<your_slurm_job_id>
```

You can verify the job is running:

```bash
squeue -j "${GLM51_JOB_ID}"
```

### 2. Enter The Workspace

```bash
cd /n/home07/juncheng/workspace/slurm_tools
```

### 3. Verify The Model Path

```bash
test -f /n/netscratch/juncheng_lab/model/GLM-5.1-FP8-2/config.json
```

Optional explicit export:

```bash
export GLM51_MODEL_LOCAL=/n/netscratch/juncheng_lab/model/GLM-5.1-FP8-2
```

### 4. Stop Any Old Servers

Run this before starting a new benchmark matrix:

```bash
bash scripts/glm51/stop.sh
```

### 5. Run SGLang Matrix

Recommended SGLang matrix:

```bash
export GLM51_JOB_ID=<your_slurm_job_id>
export SGLANG_RUN_ID="$(date +%Y%m%d_%H%M%S)_api_sglang_matrix"

GLM51_RUN_ID="${SGLANG_RUN_ID}" \
GLM51_BACKENDS=sglang \
GLM51_CONFIGS="8:1 4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

Expected output directory:

```bash
logs/glm51/results/${SGLANG_RUN_ID}
```

Known behavior:

- `sglang tp8_pp1` should complete prefill and decode.
- PP configurations may fail 64k and 128k prefill.
- Decode should complete for all SGLang configurations.

### 6. Run vLLM Matrix

Recommended vLLM matrix, excluding the known-problem `tp8_pp1`:

```bash
export GLM51_JOB_ID=<your_slurm_job_id>
export VLLM_RUN_ID="$(date +%Y%m%d_%H%M%S)_api_vllm_matrix"

GLM51_RUN_ID="${VLLM_RUN_ID}" \
GLM51_BACKENDS=vllm \
GLM51_CONFIGS="4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

Expected output directory:

```bash
logs/glm51/results/${VLLM_RUN_ID}
```

Known behavior:

- Startup is slow, especially the first cold run.
- Leave `GLM51_VLLM_READY_TIMEOUT=3600` unless you know the caches are warm.
- The vLLM matrix should complete for `tp4_pp2`, `tp2_pp4`, and `tp1_pp8`.

### 7. Optional: Debug vLLM `tp8_pp1`

Run this separately only if you want to debug multi-node tensor-parallel startup:

```bash
export GLM51_JOB_ID=<your_slurm_job_id>
export VLLM_TP8_RUN_ID="$(date +%Y%m%d_%H%M%S)_api_vllm_tp8_pp1"

GLM51_RUN_ID="${VLLM_TP8_RUN_ID}" \
GLM51_BACKENDS=vllm \
GLM51_CONFIGS="8:1" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

If it stalls, stop it with:

```bash
bash scripts/glm51/stop.sh
```

### 8. Summarize Results

After both matrices complete:

```bash
export COMBINED_DIR="logs/glm51/results/$(date +%Y%m%d_%H%M%S)_combined"

/n/sw/Miniforge3-25.3.1-0/bin/python3 \
  scripts/glm51/benchmarks/summarize_results.py \
  --output-dir "${COMBINED_DIR}" \
  "logs/glm51/results/${SGLANG_RUN_ID}" \
  "logs/glm51/results/${VLLM_RUN_ID}" \
  | tee "${COMBINED_DIR}/summary.txt"
```

This writes:

- `${COMBINED_DIR}/summary.txt`
- `${COMBINED_DIR}/all_results.csv`
- `${COMBINED_DIR}/prefill_winners.csv`
- `${COMBINED_DIR}/decode_winners.csv`
- `${COMBINED_DIR}/topology_gmeans.csv`

### 9. Plot Results

```bash
/n/sw/Miniforge3-25.3.1-0/bin/python3 \
  scripts/glm51/benchmarks/plot_results.py \
  "logs/glm51/results/${SGLANG_RUN_ID}" \
  "logs/glm51/results/${VLLM_RUN_ID}" \
  --output-dir "${COMBINED_DIR}/plots"
```

This writes:

- `${COMBINED_DIR}/plots/prefill_throughput_by_topology.png`
- `${COMBINED_DIR}/plots/decode_throughput_by_topology.png`
- `${COMBINED_DIR}/plots/best_prefill_by_backend.png`
- `${COMBINED_DIR}/plots/best_decode_by_backend.png`

### 10. Resume Behavior

If a run is interrupted, rerun with the same `GLM51_RUN_ID`. The benchmark harness skips JSONL cases that already exist and records known failed cases, so it can resume partial matrices.

Example:

```bash
GLM51_RUN_ID="${VLLM_RUN_ID}" \
GLM51_BACKENDS=vllm \
GLM51_CONFIGS="4:2 2:4 1:8" \
bash scripts/glm51/benchmarks/run_benchmarks.sh
```

### 11. Useful Overrides

Change prefill lengths:

```bash
export GLM51_PREFILL_LENGTHS="1024 2048 4096 8192 16384 32768 65536 131072"
```

Change decode batch sizes:

```bash
export GLM51_DECODE_BATCHES="1 2 4 8 16 32 64 128"
```

Change vLLM readiness timeout:

```bash
export GLM51_VLLM_READY_TIMEOUT=3600
```

Change per-case benchmark timeout:

```bash
export GLM51_BENCH_CASE_TIMEOUT=3600
```

### 12. Measure Inter-Node IB Bandwidth Again

The measurement helper is:

```bash
scripts/glm51/benchmarks/measure_ib_bw.sh
```

Run it like this:

```bash
export GLM51_JOB_ID=<your_slurm_job_id>
bash scripts/glm51/benchmarks/measure_ib_bw.sh
```

Optional overrides:

```bash
export GLM51_BW_IFACE=ib0
export GLM51_BW_DURATION=10
export GLM51_BW_PORT=18515
```

It writes results under:

```bash
logs/glm51/results/bandwidth/<timestamp>/
```

The important file is:

```bash
logs/glm51/results/bandwidth/<timestamp>/summary.tsv
```

## Sanity Checks

Check vLLM import:

```bash
/n/netscratch/juncheng_lab/venvs/vllm-0.21.0-cu129/bin/python - <<'PY'
import torch
import vllm
print("torch", torch.__version__, torch.version.cuda, torch.cuda.is_available())
print("vllm", vllm.__version__, vllm.__file__)
PY
```

Check result files:

```bash
find logs/glm51/results/"${SGLANG_RUN_ID}" logs/glm51/results/"${VLLM_RUN_ID}" \
  -name 'prefill.jsonl' -o -name 'decode.jsonl'
```

Stop all servers:

```bash
bash scripts/glm51/stop.sh
```
