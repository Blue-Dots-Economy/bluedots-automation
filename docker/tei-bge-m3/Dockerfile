# TEI (text-embeddings-inference) with BAAI/bge-m3 baked into the image, so the
# pod never downloads the ~2.3 GB model at runtime (fast restarts, no HuggingFace
# dependency / rate-limit in the cluster).
#
# The model revision is PINNED for reproducibility — bump it deliberately. The
# Helm chart must pass `--revision <BGE_M3_REVISION>` to TEI (it loads from the
# baked snapshots/<rev> with HF_HUB_OFFLINE=1; without the matching --revision,
# TEI would try to resolve "main" offline and fail).
ARG BGE_M3_REVISION=5617a9f61b028005a4858fdac845db406aefb181

FROM python:3.11-slim AS dl
ARG BGE_M3_REVISION
RUN pip install --no-cache-dir "huggingface_hub[hf_transfer]"
ENV HF_HUB_ENABLE_HF_TRANSFER=1
# Whole-repo download (config, tokenizer, onnx/ + safetensors) into the HF cache layout.
RUN huggingface-cli download BAAI/bge-m3 --revision "${BGE_M3_REVISION}" --cache-dir /hf \
 && chmod -R a+rX /hf

FROM ghcr.io/huggingface/text-embeddings-inference:cpu-1.7
# Populate TEI's huggingface_hub_cache (/data) and run fully offline.
COPY --from=dl /hf /data
ENV HF_HUB_OFFLINE=1
