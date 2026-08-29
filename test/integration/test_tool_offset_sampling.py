"""Probe sampling in ff_tool_offset._estop.

The contract is klipper-toolchanger's: SAMPLES, SAMPLES_TOLERANCE,
SAMPLES_TOLERANCE_RETRIES, SAMPLES_RESULT, SAMPLE_RETRACT_DIST and
PROBE_SPEED, applied to every probe of a calibration run. What is specific
to this machine is where the DEFAULTS come from: the fork's [e_stop <axis>]
already samples (sub_cycle_cnt touches, spread rejected above error_v,
retried main_cycle_cnt times, back_v retract, averaged), so a command with
none of these passed has to probe exactly as it did before the parameters
existed. That is the property most of these tests pin down -- the parameters
are new, the behaviour without them must not be.

The e_stop object is faked. It is the fork's, not ours, and the only parts
_estop touches are _probe/run_probe, position_offset, back_v, speed and the
four sampling numbers -- a small enough surface to stand in for honestly.
The replica lane cannot cover this: klippy does not run there, and neither
does the levelboard the real probe talks to.
"""
import importlib.util
import os
import types

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load():
    path = os.path.join(ROOT, "pkgs", "klipper", "payload", "klipper", "klippy", "extras",
                        "ff_tool_offset.py")
    spec = importlib.util.spec_from_file_location("ff_tool_offset", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ff_tool_offset = _load()


class CommandError(Exception):
    """Stands in for printer.command_error / gcmd.error."""


class FakeGcmd:
    def __init__(self, **params):
        self.params = params
        self.responses = []

    def _value(self, name, default):
        return self.params[name] if name in self.params else default

    def get(self, name, default=None):
        return str(self._value(name, default))

    def get_int(self, name, default=None, **kw):
        return int(self._value(name, default))

    def get_float(self, name, default=None, **kw):
        value = self._value(name, default)
        return None if value is None else float(value)

    def error(self, msg):
        return CommandError(msg)

    def respond_info(self, msg):
        self.responses.append(msg)


class FakeEstop:
    """The fork's [e_stop <axis>], with printer.base.cfg's numbers."""

    def __init__(self, triggers, sub_cnt=3, err_v=0.02, main_cnt=10,
                 back_v=3.0, speed=5.0):
        self.triggers = list(triggers)
        self.calls = 0
        self.sub_cnt = sub_cnt
        self.err_v = err_v
        self.main_cnt = main_cnt
        self.back_v = back_v
        self.speed = speed
        self.position_offset = 0.0
        self.speeds_seen = []
        self.back_v_seen = []

    def _probe(self, speed):
        self.speeds_seen.append(speed)
        self.back_v_seen.append(self.back_v)
        value = self.triggers[self.calls % len(self.triggers)]
        self.calls += 1
        return value


class FakeEstopNoSingleTouch:
    """An e_stop exposing only run_probe -- its own averaging loop. Not a
    subclass of FakeEstop: the point of it is the ABSENCE of _probe, and an
    inherited one cannot be deleted off an instance."""

    def __init__(self, triggers):
        self.triggers = list(triggers)
        self.calls = 0
        self.sub_cnt = 3
        self.err_v = 0.02
        self.main_cnt = 10
        self.back_v = 3.0
        self.speed = 5.0
        self.position_offset = 0.0

    def run_probe(self, gcmd):
        value = self.triggers[self.calls % len(self.triggers)]
        self.calls += 1
        return value


def make_extra(probe, **config):
    """FFToolOffset with only what _estop reads. __init__ wants a whole
    klippy config object; the sampling path does not."""
    extra = ff_tool_offset.FFToolOffset.__new__(ff_tool_offset.FFToolOffset)
    extra.name = "ff_tool_offset"
    extra.estop = {"Z": probe}
    extra.samples = config.get("samples")
    extra.samples_tolerance = config.get("samples_tolerance")
    extra.samples_retries = config.get("samples_retries")
    extra.samples_result = config.get("samples_result", "average")
    extra.sample_retract_dist = config.get("sample_retract_dist")
    extra.probe_speed = config.get("probe_speed")
    extra.printer = types.SimpleNamespace(command_error=CommandError)
    return extra


# ---------------------------------------------------------------- defaults

def test_an_unparameterised_probe_is_the_forks_own_sampling():
    # sub_cycle_cnt touches, averaged, at the e_stop's speed: what
    # run_probe did before any of this was reachable from a command.
    probe = FakeEstop([1.00, 1.005, 1.01])
    result = make_extra(probe)._estop(FakeGcmd(), "Z", -3.0)
    assert result == pytest.approx(1.005)
    assert probe.calls == 3
    assert probe.speeds_seen == [5.0, 5.0, 5.0]
    assert probe.back_v_seen == [3.0, 3.0, 3.0]


def test_the_target_reaches_the_estop_object():
    probe = FakeEstop([1.0])
    make_extra(probe)._estop(FakeGcmd(), "Z", -3.0)
    assert probe.position_offset == -3.0


def test_a_probe_without_single_touch_is_called_once():
    # run_probe is the fork's whole averaging loop; sampling it sub_cnt
    # times over would be sub_cnt^2 touches.
    probe = FakeEstopNoSingleTouch([1.0])
    assert make_extra(probe)._estop(FakeGcmd(), "Z", -3.0) == 1.0
    assert probe.calls == 1


# ------------------------------------------------------------ combinations

def test_samples_result_median_of_an_odd_count():
    probe = FakeEstop([1.00, 1.10, 1.02, 1.04, 1.03])
    result = make_extra(probe)._estop(
        FakeGcmd(SAMPLES=5, SAMPLES_RESULT="median", SAMPLES_TOLERANCE=1.0),
        "Z", -3.0)
    assert result == pytest.approx(1.03)


def test_samples_result_median_of_an_even_count():
    # Upstream's _calc_median averages the middle two rather than picking.
    probe = FakeEstop([1.00, 1.02, 1.04, 1.10])
    result = make_extra(probe)._estop(
        FakeGcmd(SAMPLES=4, SAMPLES_RESULT="median", SAMPLES_TOLERANCE=1.0),
        "Z", -3.0)
    assert result == pytest.approx(1.03)


def test_an_unknown_samples_result_is_refused():
    with pytest.raises(CommandError):
        make_extra(FakeEstop([1.0]))._estop(
            FakeGcmd(SAMPLES_RESULT="mode"), "Z", -3.0)


def test_config_supplies_the_default_the_estop_would_have():
    probe = FakeEstop([1.0, 1.0])
    make_extra(probe, samples=2)._estop(FakeGcmd(), "Z", -3.0)
    assert probe.calls == 2


# ---------------------------------------------------------------- tolerance

def test_a_wide_round_is_retried_and_the_tight_one_kept():
    probe = FakeEstop([1.0, 1.5, 1.0, 1.0])
    gcmd = FakeGcmd(SAMPLES=2, SAMPLES_TOLERANCE=0.05,
                    SAMPLES_TOLERANCE_RETRIES=3)
    assert make_extra(probe)._estop(gcmd, "Z", -3.0) == pytest.approx(1.0)
    assert probe.calls == 4
    assert any("retrying" in line for line in gcmd.responses)


def test_a_round_is_abandoned_as_soon_as_it_is_known_to_be_bad():
    # The fork judges spread after each touch. Finishing a round already
    # over tolerance just wears the nozzle out against the station.
    probe = FakeEstop([1.0, 1.5, 1.0, 1.0, 1.0, 1.0])
    make_extra(probe)._estop(
        FakeGcmd(SAMPLES=4, SAMPLES_TOLERANCE=0.05,
                 SAMPLES_TOLERANCE_RETRIES=3), "Z", -3.0)
    assert probe.calls == 2 + 4


def test_exhausted_retries_raise_rather_than_return_a_bad_number():
    probe = FakeEstop([1.0, 1.5])
    with pytest.raises(ff_tool_offset.FFToolOffsetError) as excinfo:
        make_extra(probe)._estop(
            FakeGcmd(SAMPLES=2, SAMPLES_TOLERANCE=0.05,
                     SAMPLES_TOLERANCE_RETRIES=1), "Z", -3.0)
    # The samples themselves are in the message: a spread failure is
    # something you diagnose, not just something that stopped.
    assert "1.0000" in str(excinfo.value) and "1.5000" in str(excinfo.value)


def test_a_zero_tolerance_accepts_any_spread():
    probe = FakeEstop([1.0, 9.0])
    result = make_extra(probe)._estop(
        FakeGcmd(SAMPLES=2, SAMPLES_TOLERANCE=0), "Z", -3.0)
    assert result == pytest.approx(5.0)


# -------------------------------------------------------------- retract etc

def test_sample_retract_dist_is_lent_to_the_estop_and_given_back():
    probe = FakeEstop([1.0, 1.0, 1.0])
    make_extra(probe)._estop(FakeGcmd(SAMPLE_RETRACT_DIST=0.5), "Z", -3.0)
    assert probe.back_v_seen == [0.5, 0.5, 0.5]
    assert probe.back_v == 3.0


def test_the_estops_retract_survives_a_failed_probe():
    # Leaving back_v at a calibration value would change how every later
    # probe on that axis behaves, homing included.
    probe = FakeEstop([1.0, 1.5])
    with pytest.raises(ff_tool_offset.FFToolOffsetError):
        make_extra(probe)._estop(
            FakeGcmd(SAMPLES=2, SAMPLES_TOLERANCE=0.05,
                     SAMPLES_TOLERANCE_RETRIES=0, SAMPLE_RETRACT_DIST=0.5),
            "Z", -3.0)
    assert probe.back_v == 3.0


def test_probe_speed_overrides_the_estop_speed():
    probe = FakeEstop([1.0, 1.0, 1.0])
    make_extra(probe)._estop(FakeGcmd(PROBE_SPEED=2.0), "Z", -3.0)
    assert probe.speeds_seen == [2.0, 2.0, 2.0]


def test_the_move_failure_sentinel_is_a_failure():
    # e_stop_move reports a failed move as 9999 instead of raising, and the
    # fork's run_probe loops on it forever.
    with pytest.raises(ff_tool_offset.FFToolOffsetError):
        make_extra(FakeEstop([9999]))._estop(FakeGcmd(), "Z", -3.0)
