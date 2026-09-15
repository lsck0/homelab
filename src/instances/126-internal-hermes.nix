{ ... }: {
  networking.hostName = "vm-126";

  # Local inference endpoint for homelab agents. Serves NousResearch Hermes 3
  # over Ollama's OpenAI-compatible API, so any client that speaks OpenAI can
  # point at http://10.100.0.126:11434/v1 with no key.
  #
  # Models live on the local disk, not the NAS: inference memory-maps the
  # weights file, and doing that over NFS would stream gigabytes per request.
  services.ollama = {
    enable = true;
    host = "0.0.0.0";
    port = 11434;
    openFirewall = true;

    # No GPU is passed through to this VM yet, so inference runs on CPU and is
    # slow — usable for batch work like Paperless tagging, painful for chat.
    # Set this to "cuda" or "rocm" once a card is passed through.
    acceleration = false;

    loadModels = [ "hermes3:8b" ];
    # Drop models declared here but no longer wanted, so the disk does not
    # silently fill with stale weights.
    syncModels = true;

    environmentVariables = {
      # Keep the model resident between requests; a cold load costs minutes on CPU.
      OLLAMA_KEEP_ALIVE = "60m";
      # One request at a time — concurrency on CPU only makes everything slower.
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };
}
