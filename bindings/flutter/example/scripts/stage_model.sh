#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <oga-model-directory> [staging-directory]" >&2
  exit 2
fi

source_dir="$1"
staging_dir="${2:-assets/models/qwen3_cpu_int4}"
required_files=(
  chat_template.jinja
  genai_config.json
  model.onnx
  model.onnx.data
  tokenizer.json
  tokenizer_config.json
)

if [[ ! -d "${source_dir}" ]]; then
  echo "Model directory does not exist: ${source_dir}" >&2
  exit 1
fi

source_dir="$(cd "${source_dir}" && pwd -P)"
for name in "${required_files[@]}"; do
  if [[ ! -f "${source_dir}/${name}" ]]; then
    echo "Missing required model file: ${source_dir}/${name}" >&2
    exit 1
  fi
done

mkdir -p "${staging_dir}"
staging_dir="$(cd "${staging_dir}" && pwd -P)"
if [[ "${source_dir}" == "${staging_dir}" ]]; then
  echo "Source and staging directories must be different." >&2
  exit 1
fi

for name in "${required_files[@]}"; do
  rm -f "${staging_dir:?}/${name}"
  ln -s "${source_dir}/${name}" "${staging_dir}/${name}"
done

echo "Staged ${#required_files[@]} model files in ${staging_dir}"
