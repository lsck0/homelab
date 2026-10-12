# the lab's local llm, one place for both ends: ollama on the gpu of the guest holding the role llm
# (instances/preconfigured/122-internal-jellyfin serves it and grants its clients), paperless-ai on vm-131 asks it
# (instances/preconfigured/131-internal-paperless/lib/paperless-ai.nix)
{
  port = 11434;
  # 7b: 4b left paperless titles empty; ~4.7 GB, nvenc fits in the rest of the 6 GB card. no thinking model
  model = "qwen2.5:7b-instruct";
}
