"""The meter guard macro (../lib/meter_reading.jinja) through jinja2, as home assistant renders it.

Usage: meter_guard_test.py <meter_reading.jinja>

Table cases for every verdict, the owner's real typos, and the law that a corrected typo never counts as consumption
(hypothesis, derandomized).
"""
import os
import sys
import unittest

import jinja2
from hypothesis import given, settings
from hypothesis import strategies as st

METER_GUARD = sys.argv.pop(1)
DAY = 86400
PROPERTY = settings(max_examples=200, deadline=None, derandomize=True)


GUARD = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.dirname(METER_GUARD)), undefined=jinja2.StrictUndefined)
GUARD_CALL = GUARD.from_string(
    "{% from '" + os.path.basename(METER_GUARD) + "' import meter_verdict %}"
    "{{ meter_verdict(reading, accepted, previous, read_at_s, now_s, replaced_s, max_rise) | trim }}")
ACCEPTING = ("accept", "accept_first", "correct")


def verdict(reading, accepted, previous, read_at_s, now_s, replaced_s=0.0, max_rise=40.0):
    return GUARD_CALL.render(reading=float(reading), accepted=float(accepted), previous=float(previous),
                             read_at_s=float(read_at_s), now_s=float(now_s), replaced_s=float(replaced_s),
                             max_rise=float(max_rise))


class Meter:
    """What home assistant keeps per meter (vm-125's lib/home-assistant.nix), driven through the real macro."""

    def __init__(self, max_rise):
        self.max_rise = max_rise
        self.accepted = self.previous = self.read_at_s = self.replaced_s = 0.0
        self.history = []

    def enter(self, reading, now_s):
        v = verdict(reading, self.accepted, self.previous, self.read_at_s, now_s, self.replaced_s, self.max_rise)
        if v in ("accept", "accept_first"):
            self.previous = 0.0 if v == "accept_first" else self.accepted
        if v in ACCEPTING:
            self.accepted, self.read_at_s = float(reading), float(now_s)
            self.history.append(self.accepted)
        return v

    def rise(self):
        """energy_model.meter_rise over everything accepted: the last value minus the minimum."""
        return self.history[-1] - min(self.history)


class MeterGuard(unittest.TestCase):
    def test_verdicts(self):
        day = float(DAY)
        cases = [
            ("unset helper", 0, 0, 0, 0, day, 0, "reject_invalid"),
            ("negative", -3, 100, 90, 0, day, 0, "reject_invalid"),
            ("first reading", 3256.821, 0, 0, 0, day, 0, "accept_first"),
            ("a day's use", 3261.321, 3256.821, 0, 0, day, 0, "accept"),
            ("same value", 3261.321, 3261.321, 3256.821, 0, day, 0, "same"),
            ("decimal shift down", 327.8, 3269.8, 3261.321, 0, day, 0, "reject_low"),
            ("decimal shift up", 32698, 3269.8, 3261.321, 0, day, 0, "reject_high"),
            ("correction of the last entry", 3265.0, 3269.8, 3261.321, 0, day, 0, "correct"),
            ("below the one before", 3260.0, 3269.8, 3261.321, 0, day, 0, "reject_low"),
            ("below the only reading", 326.98, 3269.8, 0, 0, day, 0, "reject_low"),
            ("a cold week between readings", 3269.8 + 7 * 39, 3269.8, 3261.321, 0, 7 * day, 0, "accept"),
            ("the same rise in one day", 3269.8 + 7 * 39, 3269.8, 3261.321, 0, day, 0, "reject_high"),
            ("within the hour counts as a day", 3269.8 + 39, 3269.8, 3261.321, 0, 600, 0, "accept"),
            ("new meter after the button", 12.5, 3269.8, 3261.321, 0, day, 100, "accept_first"),
            ("button pressed before the last reading", 12.5, 3269.8, 3261.321, 100, day, 50, "reject_low"),
        ]
        for name, reading, accepted, previous, read_at_s, now_s, replaced_s, expected in cases:
            with self.subTest(name):
                self.assertEqual(verdict(reading, accepted, previous, read_at_s, now_s, replaced_s), expected)

    def test_the_owners_typos_count_nothing(self):
        # the live history that made the old max-min count 3269.8 m³ of gas and 275 m³ of water in a week
        for readings, typo_at, fixed, max_rise in (([3256.821, 3261.321, 3269.8, 327.8], 3, 3278.0, 40.0),
                                                   ([273, 274, 275, 27.6], 3, 276.0, 3.0)):
            meter = Meter(max_rise)
            for i, reading in enumerate(readings):
                v = meter.enter(reading, (i + 1) * DAY)
                self.assertEqual(v.startswith("reject"), i == typo_at, (reading, v))
            self.assertEqual(meter.enter(fixed, (len(readings) + 1) * DAY), "accept")
            self.assertAlmostEqual(meter.rise(), fixed - readings[0])

    @PROPERTY
    @given(st.floats(min_value=100, max_value=9000), st.lists(st.tuples(
        st.integers(min_value=1, max_value=3),                      # days since the last reading
        st.floats(min_value=0, max_value=0.9),                      # share of the allowed rise used
        st.sampled_from(["none", "times10", "div10", "high"])),    # the typo typed first, then the right value
        min_size=1, max_size=40))
    def test_a_corrected_typo_never_counts(self, start, entries):
        max_rise = 40.0
        meter = Meter(max_rise)
        start = round(start, 3)
        now_s, true_value = 0, start
        meter.enter(true_value, now_s)
        for days, share, typo in entries:
            now_s += days * DAY
            true_value = round(true_value + share * max_rise * days, 3)
            wrong = {"none": None, "times10": true_value * 10, "div10": true_value / 10,
                     "high": true_value + (max_rise * days - (true_value - meter.accepted)) / 2 + 0.001}[typo]
            if wrong is not None and wrong != true_value:
                meter.enter(wrong, now_s)
            meter.enter(true_value, now_s + 60)
            self.assertAlmostEqual(meter.accepted, true_value, places=6)
        self.assertAlmostEqual(meter.rise(), true_value - start, places=6)


if __name__ == "__main__":
    unittest.main()
