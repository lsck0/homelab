# the lab's local llm, one place for both ends: ollama on vm-134's gpu (instances/134-internal-jellyfin/main.nix serves
# it and admits the clients), paperless-ai on vm-121 asks it (instances/121-internal-paperless/lib/paperless-ai.nix)
{
  vmid = 134;
  port = 11434;
  # 7b: 4b left paperless titles empty; ~4.7 GB, nvenc fits in the rest of the 6 GB card. no thinking model
  model = "qwen2.5:7b-instruct";
  # vmids allowed to call it
  clients = [ 121 ];
}
