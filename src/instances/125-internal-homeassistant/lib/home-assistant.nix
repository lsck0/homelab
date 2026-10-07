# Home Assistant's side of the energy inputs (inputs.nix), rendered for vm-125 (../main.nix): the
# helpers, one guarded meter sensor pair per meter, the prometheus filter with the metric names, and the Energie
# dashboard. Every value is a json string, which yaml reads as is. ../tests/hass-config.nix checks them with home
# assistant's own config validation.
{ lib }:
let
  energy = import ../../../modules/energy/lib/inputs.nix;
  # the guard's rules; home assistant loads macros from /config/custom_templates
  meterGuardName = "meter_reading.jinja";
  # verdicts of meter_reading.jinja that take the typed value
  accepting = builtins.toJSON [ "accept" "accept_first" "correct" ];
  cubicMeters = "m³";

  meterInput = _: m: {
    name = m.label;
    inherit (m) icon;
    unit_of_measurement = cubicMeters;
    mode = "box";
    # a dial has five or six digits before the comma and liters after it
    min = 0;
    max = 999999;
    step = 0.001;
  };

  tariffInput = _: t: {
    name = t.label;
    inherit (t) icon max step;
    unit_of_measurement = t.unit;
    mode = "box";
    min = 0;
  };

  # what a rejected entry tells the owner, by verdict
  rejectReasons = m: lib.concatStringsSep ", " [
    "'reject_invalid': 'kein Zählerstand'"
    "'reject_low': 'kleiner als ' ~ previous ~ ' ${cubicMeters}, der Stand davor; ein Zähler läuft nicht rückwärts (Komma verrutscht?)'"
    "'reject_high': 'mehr als ${toString m.maxRisePerDayCubicMeters} ${cubicMeters} pro Tag seit dem letzten Stand ' ~ accepted ~ ' ${cubicMeters} (Komma verrutscht?)'"
  ];

  # one trigger-based block per meter: the typed value becomes the reading only if meter_reading.jinja accepts it
  meterTemplate = key: m: {
    triggers = [{ trigger = "state"; entity_id = m.input; not_to = [ "unknown" "unavailable" ]; }];
    variables = {
      reading = "{{ trigger.to_state.state | float(0) }}";
      accepted = "{{ states('${m.reading}') | float(0) }}";
      previous = "{{ state_attr('${m.reading}', 'previous') | float(0) }}";
      read_at_s = "{{ states('${m.readAt}') | float(0) }}";
      now_s = "{{ as_timestamp(now()) }}";
      replaced_s = "{{ as_timestamp(states('${m.replacedButton}'), 0) }}";
      # a restored helper at startup has no from_state: not an entry
      verdict = "{% from '${meterGuardName}' import meter_verdict %}"
        + "{{ 'same' if trigger.from_state is none else meter_verdict(reading, accepted, previous, read_at_s, now_s, "
        + "replaced_s, ${toString m.maxRisePerDayCubicMeters}) | trim }}";
    };
    actions = [{
      "if" = [{ condition = "template"; value_template = "{{ verdict.startswith('reject') }}"; }];
      "then" = [
        {
          action = "persistent_notification.create";
          data = {
            notification_id = "${key}_meter_rejected";
            title = "${m.label}: Stand nicht übernommen";
            message = "{% set reasons = {${rejectReasons m}} %}{{ reading }} ${cubicMeters} ist {{ reasons[verdict] }}. "
              + "Es gilt weiter {{ accepted }} ${cubicMeters}. Ein neuer Zähler: erst \"${m.label} getauscht\" drücken.";
          };
        }
        # the helper shows what counts again; that change is a "same" and does nothing
        {
          "if" = [{ condition = "template"; value_template = "{{ accepted > 0 }}"; }];
          "then" = [{ action = "input_number.set_value"; target.entity_id = m.input; data.value = "{{ accepted }}"; }];
        }
      ];
    }];
    sensor = [
      {
        # the name is the entity id's slug, see inputs.nix
        name = m.readingName;
        unique_id = "${key}_meter_guarded_reading";
        unit_of_measurement = cubicMeters;
        device_class = m.deviceClass;
        state_class = "total_increasing";
        inherit (m) icon;
        # unknown until the first accepted entry: a numeric sensor must never render text
        availability = "{{ verdict in ${accepting} or is_number(this.state) }}";
        state = "{{ reading if verdict in ${accepting} else this.state }}";
        attributes.previous = "{{ 0 if verdict == 'accept_first' else (accepted if verdict == 'accept' "
          + "else this.attributes.previous | default(0)) }}";
      }
      {
        name = m.readAtName;
        unique_id = "${key}_meter_guarded_read_at";
        unit_of_measurement = "s";
        icon = "mdi:clock-check-outline";
        availability = "{{ verdict in ${accepting} or is_number(this.state) }}";
        state = "{{ now_s if verdict in ${accepting} else this.state }}";
      }
    ];
  };

  # json is yaml: a generated section needs no indentation bookkeeping
  inputNumbers = builtins.toJSON (lib.mapAttrs' (key: m: lib.nameValuePair "${key}_meter" (meterInput key m)) energy.meters
    // lib.mapAttrs tariffInput energy.tariffs);
  inputButtons = builtins.toJSON (lib.mapAttrs' (key: m: lib.nameValuePair "${key}_meter_replaced" {
    name = "${m.label} getauscht";
    icon = "mdi:swap-horizontal-circle-outline";
  }) energy.meters);
  templates = builtins.toJSON (lib.mapAttrsToList meterTemplate energy.meters);
  prometheus = builtins.toJSON {
    namespace = energy.namespace;
    filter = {
      include_entities = lib.concatMap (m: [ m.reading m.readAt ]) (lib.attrValues energy.meters);
      include_entity_globs = [ "input_number.*" ];
    };
    # the default name escapes the unit, sensor_gas_mu0xb3
    component_config = lib.foldl' (acc: m: acc // {
      ${m.reading}.override_metric = m.readingMetricName;
      ${m.readAt}.override_metric = m.readAtMetricName;
    }) { } (lib.attrValues energy.meters);
  };

  dashboard = builtins.toJSON {
    title = "Energie";
    views = [{
      title = "Energie";
      path = "energie";
      cards = [
        {
          type = "markdown";
          content = "Strom und Solar (PV, Netzbezug, Batterie) laufen live auf Grafana (grafana.lsck0.dev) und dem "
            + "TRMNL. Hier nur die Werte, die von Hand kommen: Vertragspreise und die Zählerstände. Ein Stand, der "
            + "rückwärts läuft oder unmöglich schnell steigt, wird nicht übernommen; die Meldung sagt warum. Ein "
            + "Tippfehler nach oben wird korrigiert, indem man den richtigen Stand einträgt.";
        }
        {
          type = "entities";
          title = "Preise (aus dem Vertrag)";
          state_color = false;
          entities = map (key: { entity = "input_number.${key}"; }) (lib.attrNames energy.tariffs);
        }
        {
          type = "entities";
          title = "Zählerstände (täglich ablesen und eintragen)";
          entities = lib.concatLists (lib.mapAttrsToList (_: m: [
            { entity = m.input; name = "${m.label}, Eingabe"; }
            { entity = m.reading; name = "${m.label}, übernommen"; }
            { entity = m.replacedButton; }
          ]) energy.meters);
        }
      ];
    }];
  };
in {
  inherit inputNumbers inputButtons templates prometheus dashboard meterGuardName;
  meterGuard = ./${meterGuardName};
}
