---
name: gpu-ollama
description: Local LLM on the RTX 2060: models and GPU health.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Ollama, GPU, LLM]
    related_skills: [homelab-ops]
---

# GPU and local models (this VM, vm-114)

- GPU: `ssh 10.100.0.114 nvidia-smi` (VRAM 6 GB).
- Ollama API `http://127.0.0.1:11434`: models `GET /api/tags`, loaded `GET /api/ps`,
  chat `POST /api/chat {"model":"qwen3:8b","messages":[...],"stream":false}`,
  OpenAI-compatible `/v1/chat/completions`.
- Pull a model for a one-off job: `POST /api/pull {"model":"<name>"}`. Declared models are
  synced from Nix (`loadModels` in `113-internal-hermes.nix`), extra ones are removed on redeploy.
- Uses: your fallback model when the cloud API fails; paperless-ai (vm-122) tagging.
- Offload heavy private work (summarising many documents) here instead of the cloud model.
