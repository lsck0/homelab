{ config, pkgs, ... }: {
  networking.hostName = "vm-126";

  # NVIDIA RTX 2060 (Turing) passed through from the host (see main.tf hostpci).
  # CUDA packages are unfree.
  nixpkgs.config.allowUnfree = true;
  # videoDrivers loads the kernel module even on a headless box; nouveau must be
  # out of the way for the proprietary driver to bind.
  services.xserver.videoDrivers = [ "nvidia" ];
  boot.blacklistedKernelModules = [ "nouveau" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = false;
    # Turing supports the open kernel modules, but the proprietary build is the
    # safe default for a compute-only card.
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

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

    # RTX 2060 passed through — run inference on CUDA.
    acceleration = "cuda";

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
