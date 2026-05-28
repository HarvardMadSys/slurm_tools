#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export GLM51_TP=8
export GLM51_PP=1
export GLM51_LAUNCH_SCRIPT_DISPLAY="scripts/glm51/launch_tp8_pp1.sh"

# TP8 runs all pipeline stages on every GPU, leaving less free VRAM for transient
# allocations.  The NSA indexer's fast_topk_transform_fused allocates a
# dst_page_table proportional to chunked_prefill_size; with the default 131072
# that peaks at ~526 MiB but only ~300 MiB is free after weights + KV cache.
# Reducing chunked_prefill_size to 32768 brings the peak to ~131 MiB (long
# prompts are simply processed in multiple smaller chunks) so the full
# context_length is preserved for large-context workloads.
export GLM51_CONTEXT_LENGTH="${GLM51_CONTEXT_LENGTH:-131200}"
export GLM51_CHUNKED_PREFILL_SIZE="${GLM51_CHUNKED_PREFILL_SIZE:-32768}"
export GLM51_MEM_FRACTION_STATIC="${GLM51_MEM_FRACTION_STATIC:-0.70}"
export GLM51_SGLANG_CUDA_GRAPH_MAX_BS="${GLM51_SGLANG_CUDA_GRAPH_MAX_BS:-16}"

exec "${script_dir}/launch_tp4_pp2.sh" "$@"
