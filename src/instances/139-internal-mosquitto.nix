{ ... }: {
  networking.hostName = "vm-139";

  # Mosquitto MQTT broker — the message bus for Home Assistant, Zigbee2MQTT and
  # ESPHome. Broker only; Zigbee2MQTT/ESPHome need a USB radio passed through
  # and are added when that hardware exists. LAN-only (1883), no public exposure.
  services.mosquitto = {
    enable = true;
    listeners = [{
      address = "0.0.0.0";
      port = 1883;
      # LAN-only broker (1883 is never port-forwarded). Anonymous for now so the
      # broker is usable immediately; add users with `mosquitto_passwd` (or a
      # sops hashedPasswordFile) and flip allow_anonymous off before exposing it.
      settings.allow_anonymous = true;
      omitPasswordAuth = true;
      acl = [ "topic readwrite #" ];
    }];
  };

  networking.firewall.allowedTCPPorts = [ 1883 ];
}
