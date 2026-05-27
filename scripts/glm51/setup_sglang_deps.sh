#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/glm51/setup_sglang_deps.sh [options]

Installs and validates the Python dependencies needed to run SGLang on the
allocated GPU head node. By default, packages are installed into the Python user
site for GLM51_SGLANG_PYTHON.

Options:
  --check-only            Validate the current environment without installing packages.
  --install               Install/upgrade packages, then validate. This is the default.
  --force-reinstall       Pass --force-reinstall to pip for the main SGLang packages.
  --node NODE             Run setup on this Slurm node. Defaults to GLM51_HEAD_NODE.
  --compile-deep-gemm     Also run SGLang DeepGEMM precompile for this model and TP size.
  --job-id JOB_ID         Slurm allocation job id. Defaults to GLM51_JOB_ID/SLURM_JOB_ID/autodetect.
  --help, -h              Show this help.

Useful environment overrides:
  GLM51_SGLANG_PYTHON       Python executable. Default comes from common.sh.
  GLM51_SGLANG_VERSION      SGLang version. Default: 0.5.10.post1.
  GLM51_FLASHINFER_VERSION  flashinfer-python version. Default: 0.6.7.post3.
  GLM51_TORCH_INDEX_URL     Extra PyTorch wheel index. Default: https://download.pytorch.org/whl/cu128.
  GLM51_PIP_EXTRA_ARGS      Extra words appended to pip install commands.

Examples:
  GLM51_JOB_ID=15378036 scripts/glm51/setup_sglang_deps.sh
  GLM51_JOB_ID=15378036 scripts/glm51/setup_sglang_deps.sh --check-only
EOF
}

install="${GLM51_SETUP_INSTALL:-1}"
force_reinstall="${GLM51_SETUP_FORCE_REINSTALL:-0}"
compile_deep_gemm="${GLM51_SETUP_COMPILE_DEEP_GEMM:-0}"
target_node="${GLM51_SETUP_NODE:-}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check-only|--no-install)
      install=0
      ;;
    --install)
      install=1
      ;;
    --force-reinstall)
      force_reinstall=1
      ;;
    --compile-deep-gemm)
      compile_deep_gemm=1
      ;;
    --node)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --node requires a value." >&2
        exit 2
      fi
      target_node="$2"
      shift
      ;;
    --job-id)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --job-id requires a value." >&2
        exit 2
      fi
      export GLM51_JOB_ID="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "glm51: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

export GLM51_FLASHINFER_VERSION="${GLM51_FLASHINFER_VERSION:-0.6.7.post3}"
export GLM51_TORCH_INDEX_URL="${GLM51_TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
export GLM51_SGLANG_PACKAGE="${GLM51_SGLANG_PACKAGE:-sglang==${GLM51_SGLANG_VERSION}}"
export GLM51_FLASHINFER_PACKAGE="${GLM51_FLASHINFER_PACKAGE:-flashinfer-python==${GLM51_FLASHINFER_VERSION}}"

run_on_gpu_node() {
  glm51_load_nodes
  if [[ -z "${target_node}" ]]; then
    target_node="${GLM51_HEAD_NODE}"
  fi

  echo "glm51: running SGLang dependency setup on ${target_node} for job ${GLM51_JOB_ID}"
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${target_node}" \
    /usr/bin/env \
      GLM51_SETUP_ON_NODE=1 \
      GLM51_SETUP_INSTALL="${install}" \
      GLM51_SETUP_FORCE_REINSTALL="${force_reinstall}" \
      GLM51_SETUP_COMPILE_DEEP_GEMM="${compile_deep_gemm}" \
      GLM51_SETUP_NODE="${target_node}" \
      GLM51_JOB_ID="${GLM51_JOB_ID}" \
      GLM51_TP="${GLM51_TP}" \
      GLM51_PP="${GLM51_PP}" \
      GLM51_GPUS_PER_NODE="${GLM51_GPUS_PER_NODE}" \
      GLM51_MODEL_LOCAL="${GLM51_MODEL_LOCAL}" \
      GLM51_MODEL="${GLM51_MODEL:-}" \
      GLM51_SGLANG_PYTHON="${GLM51_SGLANG_PYTHON}" \
      GLM51_SGLANG_VERSION="${GLM51_SGLANG_VERSION}" \
      GLM51_FLASHINFER_VERSION="${GLM51_FLASHINFER_VERSION}" \
      GLM51_TORCH_INDEX_URL="${GLM51_TORCH_INDEX_URL}" \
      GLM51_SGLANG_PACKAGE="${GLM51_SGLANG_PACKAGE}" \
      GLM51_FLASHINFER_PACKAGE="${GLM51_FLASHINFER_PACKAGE}" \
      GLM51_PIP_EXTRA_ARGS="${GLM51_PIP_EXTRA_ARGS:-}" \
      bash "${BASH_SOURCE[0]}"
}

install_packages() {
  local python="${GLM51_SGLANG_PYTHON}"
  local pip_extra=()
  if [[ -n "${GLM51_PIP_EXTRA_ARGS:-}" ]]; then
    read -r -a pip_extra <<< "${GLM51_PIP_EXTRA_ARGS}"
  fi

  echo "glm51: python=${python}"
  "${python}" -m pip --version

  echo "glm51: upgrading installer helpers in user site"
  "${python}" -m pip install --user --upgrade \
    pip setuptools wheel packaging ninja cmake \
    "${pip_extra[@]}"

  local install_args=(
    install
    --user
    --upgrade
    --extra-index-url "${GLM51_TORCH_INDEX_URL}"
  )
  if [[ "${force_reinstall}" == "1" ]]; then
    install_args+=(--force-reinstall)
  fi

  echo "glm51: installing ${GLM51_SGLANG_PACKAGE} ${GLM51_FLASHINFER_PACKAGE}"
  "${python}" -m pip "${install_args[@]}" \
    "${GLM51_SGLANG_PACKAGE}" \
    "${GLM51_FLASHINFER_PACKAGE}" \
    "${pip_extra[@]}"
}

validate_environment() {
  local python="${GLM51_SGLANG_PYTHON}"
  echo "glm51: validating SGLang runtime on $(hostname -s)"
  "${python}" -u - <<'PY'
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
import os
import site
import sys

required = [
    "sglang",
    "torch",
    "triton",
    "flashinfer-python",
    "transformers",
    "xgrammar",
    "fastapi",
    "uvloop",
    "pyzmq",
]

print(f"python={sys.executable}")
for package in required:
    try:
        print(f"{package}={version(package)}")
    except PackageNotFoundError:
        raise SystemExit(f"missing required package: {package}")

import torch

print(f"torch_cuda={torch.version.cuda}")
print(f"torch_cuda_available={torch.cuda.is_available()}")
print(f"torch_cuda_device_count={torch.cuda.device_count()}")
if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
    raise SystemExit("CUDA is not visible from this Python on the GPU node.")
print(f"torch_cuda_device0={torch.cuda.get_device_name(0)}")

import flashinfer  # noqa: F401

print("flashinfer_import=ok")

search_roots = [Path(site.getusersitepackages())]
search_roots.extend(Path(p) for p in site.getsitepackages())
parser_paths = [
    root / "sglang" / "srt" / "function_call" / "function_call_parser.py"
    for root in search_roots
]
for parser_path in parser_paths:
    if parser_path.exists():
        text = parser_path.read_text()
        if '"glm47"' not in text:
            raise SystemExit(f"glm47 tool parser not found in {parser_path}")
        print(f"glm47_tool_parser=ok ({parser_path})")
        break
else:
    raise SystemExit("could not find SGLang function_call_parser.py")

print("validation=ok")
PY
}

compile_deep_gemm_if_requested() {
  if [[ "${compile_deep_gemm}" != "1" ]]; then
    return 0
  fi

  glm51_require_model
  echo "glm51: running optional DeepGEMM precompile; this can take a while"
  "${GLM51_SGLANG_PYTHON}" -m sglang.compile_deep_gemm \
    --model "${GLM51_MODEL}" \
    --tp "${GLM51_TP}" \
    --trust-remote-code
}

if [[ "${GLM51_SETUP_ON_NODE:-0}" != "1" ]]; then
  run_on_gpu_node
  exit 0
fi

glm51_prepare_node_local_cache_env
glm51_require_model

if [[ "${install}" == "1" ]]; then
  install_packages
else
  echo "glm51: check-only mode; skipping package installation"
fi

validate_environment
compile_deep_gemm_if_requested
