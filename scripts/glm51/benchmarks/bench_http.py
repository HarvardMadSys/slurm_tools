#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import requests
from transformers import AutoTokenizer


def parse_args():
    parser = argparse.ArgumentParser(
        description="Benchmark a single batched request against a running server."
    )
    parser.add_argument("--backend", choices=("sglang", "vllm"), required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--result-filename", required=True)
    parser.add_argument("--run-name", required=True)
    parser.add_argument("--batch-size", type=int, required=True)
    parser.add_argument("--input-len", type=int, required=True)
    parser.add_argument("--output-len", type=int, required=True)
    parser.add_argument("--request-timeout", type=float, default=3600.0)
    parser.add_argument("--warmup-requests", type=int, default=1)
    return parser.parse_args()


def load_tokenizer(model_path: str):
    return AutoTokenizer.from_pretrained(
        model_path,
        trust_remote_code=True,
        use_fast=False,
    )


def build_prompt_ids(tokenizer, input_len: int) -> list[int]:
    base_ids = tokenizer.encode(
        "The quick brown fox jumps over the lazy dog. ",
        add_special_tokens=False,
    )
    special_ids = set(getattr(tokenizer, "all_special_ids", []) or [])
    prompt_piece = [token_id for token_id in base_ids if token_id not in special_ids]

    if not prompt_piece:
        vocab_size = getattr(tokenizer, "vocab_size", 0) or 0
        for token_id in range(vocab_size):
            if token_id not in special_ids:
                prompt_piece = [token_id]
                break

    if not prompt_piece:
        raise RuntimeError("Failed to construct a non-special prompt token sequence.")

    repeats = (input_len + len(prompt_piece) - 1) // len(prompt_piece)
    return (prompt_piece * repeats)[:input_len]


def batch_prompt(prompt_ids: list[int], batch_size: int):
    if batch_size == 1:
        return prompt_ids[:]
    return [prompt_ids[:] for _ in range(batch_size)]


def resolve_vllm_model_id(session: requests.Session, base_url: str, fallback: str) -> str:
    response = session.get(
        f"{base_url}/v1/models",
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    data = payload.get("data") or []
    if not data:
        return fallback
    model_id = data[0].get("id")
    return model_id or fallback


def build_payload(backend: str, prompt_ids, output_len: int, model_id: str | None):
    if backend == "vllm":
        return {
            "model": model_id,
            "prompt": prompt_ids,
            "max_tokens": output_len,
            "temperature": 0.0,
            "ignore_eos": True,
            "stream": False,
            "add_special_tokens": False,
        }

    return {
        "input_ids": prompt_ids,
        "sampling_params": {
            "temperature": 0.0,
            "max_new_tokens": output_len,
            "ignore_eos": True,
        },
        "stream": False,
        "return_logprob": False,
    }


def endpoint_for_backend(backend: str, base_url: str) -> str:
    if backend == "vllm":
        return f"{base_url}/v1/completions"
    return f"{base_url}/generate"


def run_request(
    session: requests.Session,
    backend: str,
    base_url: str,
    payload,
    request_timeout: float,
):
    url = endpoint_for_backend(backend, base_url)
    started = time.perf_counter()
    response = session.post(url, json=payload, timeout=request_timeout)
    latency = time.perf_counter() - started
    response.raise_for_status()
    _ = response.json()
    return latency


def make_result_row(
    run_name: str,
    batch_size: int,
    input_len: int,
    output_len: int,
    latency: float,
):
    input_tokens = batch_size * input_len
    output_tokens = batch_size * output_len
    total_tokens = input_tokens + output_tokens
    input_throughput = input_tokens / latency
    output_throughput = output_tokens / latency
    overall_throughput = total_tokens / latency

    if output_len == 1:
        last_ttft = latency
        last_gen_throughput = -1.0
    else:
        last_ttft = -1.0
        last_gen_throughput = -1.0

    return {
        "run_name": run_name,
        "batch_size": batch_size,
        "input_len": input_len,
        "output_len": output_len,
        "latency": round(latency, 4),
        "input_throughput": round(input_throughput, 2),
        "output_throughput": round(output_throughput, 2),
        "overall_throughput": round(overall_throughput, 2),
        "last_ttft": round(last_ttft, 4),
        "last_gen_throughput": round(last_gen_throughput, 2),
        "acc_length": -1.0,
        "cache_hit_rate": 0.0,
    }


def append_result(path: str, row):
    result_path = Path(path)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    with result_path.open("a") as fh:
        fh.write(json.dumps(row) + "\n")


def main():
    args = parse_args()
    tokenizer = load_tokenizer(args.model_path)
    prompt_ids = build_prompt_ids(tokenizer, args.input_len)
    prompt_batch = batch_prompt(prompt_ids, args.batch_size)

    with requests.Session() as session:
        model_id = args.model_path
        if args.backend == "vllm":
            model_id = resolve_vllm_model_id(session, args.base_url, args.model_path)

        payload = build_payload(
            args.backend,
            prompt_batch,
            args.output_len,
            model_id,
        )

        warmup_latencies = []
        for warmup_idx in range(args.warmup_requests):
            warmup_latencies.append(
                run_request(
                    session,
                    args.backend,
                    args.base_url,
                    payload,
                    args.request_timeout,
                )
            )
            if warmup_idx + 1 < args.warmup_requests:
                time.sleep(1.0)
        time.sleep(1.0)
        latency = run_request(
            session,
            args.backend,
            args.base_url,
            payload,
            args.request_timeout,
        )

    row = make_result_row(
        run_name=args.run_name,
        batch_size=args.batch_size,
        input_len=args.input_len,
        output_len=args.output_len,
        latency=latency,
    )
    row["warmup_requests"] = args.warmup_requests
    row["warmup_latency"] = round(warmup_latencies[-1], 4) if warmup_latencies else -1.0
    append_result(args.result_filename, row)
    print(json.dumps(row))


if __name__ == "__main__":
    main()
