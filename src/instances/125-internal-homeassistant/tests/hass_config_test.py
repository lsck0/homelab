"""Home Assistant's own config validation over the energy inputs it is given (../lib/home-assistant.nix).

Usage: hass_config_test.py <config dir> <meters>

Validates the helpers and the guarded meter sensors (trigger, variables, actions, templates) with the schema home
assistant applies at startup, so a key it does not know fails here and not on vm-125. The template integration
logs an invalid entry and drops it instead of reporting it, so both the log and the surviving entries are checked.
"""
import logging
import sys

from homeassistant.scripts import check_config

DOMAINS = {"input_number", "input_button", "template"}
# per meter: the reading and its read time
SENSORS_PER_METER = 2


class Errors(logging.Handler):
    def __init__(self):
        super().__init__(logging.ERROR)
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


config_dir, meters = sys.argv[1], int(sys.argv[2])
errors = Errors()
logging.getLogger().addHandler(errors)
result = check_config.check(config_dir)

failures = [f"{domain}: {e}" for domain, e in result["except"].items()] + errors.messages
loaded = result["components"] or {}
if not DOMAINS <= set(loaded):
    failures.append(f"not validated: {sorted(DOMAINS - set(loaded))}")
blocks = loaded.get("template", [])
sensors = sum(len(block.get("sensor", [])) for block in blocks)
if len(blocks) != meters or sensors != meters * SENSORS_PER_METER:
    failures.append(f"template: {len(blocks)} blocks, {sensors} sensors survived validation, expected {meters} and "
                    f"{meters * SENSORS_PER_METER}")
for failure in failures:
    print(failure, file=sys.stderr)
if failures:
    sys.exit(1)
print(f"valid: {sorted(DOMAINS)}, {len(blocks)} meter blocks")
