# The house's hand-typed energy inputs: gas and water meter readings and the contract tariffs.
#
# One definition for every consumer. 125-internal-homeassistant.nix renders the helpers, the guarded meter
# sensors and their prometheus names from it; ../default.nix hands the same attrset, as json, to energy_model.py,
# which builds the grafana board's and the trmnl panel's queries. A renamed helper or metric is one edit here.
#
# A meter reading goes through three entities (see meter_reading.jinja for the rules):
#   input_number.<key>_meter        what the owner types, untrusted
#   sensor.<key>_meter_reading      the last accepted reading, the only one anything reads
#   sensor.<key>_meter_read_at      when it was accepted, unix seconds
# and input_button.<key>_meter_replaced arms the next entry to start a new meter.
let
  # every metric of home assistant's prometheus integration is <namespace>_<name>
  namespace = "hass";

  meter = key: m: m // rec {
    input = "input_number.${key}_meter";
    replacedButton = "input_button.${key}_meter_replaced";
    # home assistant derives a yaml entity's id from its name, never from unique_id: the name is the id's slug
    readingName = "${key} meter reading";
    reading = "sensor.${key}_meter_reading";
    readAtName = "${key} meter read at";
    readAt = "sensor.${key}_meter_read_at";
    # override_metric names; the default would mangle the unit into the name (m³ -> mu0xb3)
    readingMetricName = "${key}_meter_cubic_meters";
    readingMetric = "${namespace}_${readingMetricName}";
    readAtMetricName = "${key}_meter_read_timestamp_seconds";
    readAtMetric = "${namespace}_${readAtMetricName}";
  };
in {
  inherit namespace;

  # the house's zone: local days, the spot price's "today" and the reading clock follow it
  inherit (builtins.fromJSON (builtins.readFile ../../../generated/site.json)) timeZone;

  # the prometheus integration names an input_number <namespace>_input_number_state_<mangled unit>, so a helper
  # is matched by this prefix plus its entity label
  helperMetricPrefix = "${namespace}_input_number_state";

  meters = builtins.mapAttrs meter {
    gas = {
      label = "Gaszähler";
      icon = "mdi:meter-gas";
      deviceClass = "gas";
      # a house heating in deep winter burns about 25 m³ a day; a decimal shift (x10) of a reading in the
      # thousands would need years between two entries to pass, a cold week does not trip it
      maxRisePerDayCubicMeters = 40;
    };
    water = {
      label = "Wasserzähler";
      icon = "mdi:water";
      deviceClass = "water";
      # four people use about 0.5 m³ a day; a filled pool or a burst pipe is worth a second look anyway, and a
      # decimal shift (x10) of a reading in the hundreds needs years between two entries to pass
      maxRisePerDayCubicMeters = 3;
    };
  };

  # contract prices, kept in home assistant so a tariff change is one edit in the app; max bounds a typo
  tariffs = {
    price_electricity = { label = "Strompreis";          unit = "EUR/kWh";   icon = "mdi:cash";            max = 10;   step = 0.0001; };
    price_feed_in     = { label = "Einspeisevergütung";  unit = "EUR/kWh";   icon = "mdi:cash-plus";       max = 10;   step = 0.0001; };
    price_gas         = { label = "Gaspreis";            unit = "EUR/kWh";   icon = "mdi:cash";            max = 10;   step = 0.0001; };
    # brennwert times zustandszahl, from the gas bill
    gas_kwh_per_m3    = { label = "Gas Umrechnung";      unit = "kWh/m³";    icon = "mdi:swap-horizontal"; max = 20;   step = 0.0001; };
    price_water       = { label = "Wasserpreis";         unit = "EUR/m³";    icon = "mdi:cash";            max = 100;  step = 0.01; };
    fee_electricity   = { label = "Grundpreis Strom";    unit = "EUR/Monat"; icon = "mdi:calendar-month";  max = 1000; step = 0.01; };
    fee_gas           = { label = "Grundpreis Gas";      unit = "EUR/Monat"; icon = "mdi:calendar-month";  max = 1000; step = 0.01; };
    fee_water         = { label = "Grundpreis Wasser";   unit = "EUR/Monat"; icon = "mdi:calendar-month";  max = 1000; step = 0.01; };
  };
}
