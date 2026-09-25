{ ... }: {
  networking.hostName = "vm-127";

  # mosquitto MQTT broker: the message bus for Home Assistant, Zigbee2MQTT and ESPHome.
  services.mosquitto = {
    enable = true;
    listeners = [{
      address = "0.0.0.0";
      port = 1883;
      # LAN-only broker (1883 is never port-forwarded).
      settings.allow_anonymous = true;
      omitPasswordAuth = true;
      acl = [ "topic readwrite #" ];
    }];
  };

  networking.firewall.allowedTCPPorts = [ 1883 ];
}
