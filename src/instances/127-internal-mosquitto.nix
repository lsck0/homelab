{ ... }: {
  networking.hostName = "vm-127";

  # mqtt bus for home assistant, zigbee2mqtt, esphome
  services.mosquitto = {
    enable = true;
    listeners = [{
      address = "0.0.0.0";
      port = 1883;
      # lan only, 1883 never forwarded
      settings.allow_anonymous = true;
      omitPasswordAuth = true;
      acl = [ "topic readwrite #" ];
    }];
  };

  networking.firewall.allowedTCPPorts = [ 1883 ];
}
