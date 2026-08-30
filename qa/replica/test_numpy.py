"""numpy on the printer's interpreter: does it import, and do the four things klippy asks of it work.

WHY A SMOKE TEST AND NOT JUST AN IMPORT

anvil-python-numpy is the one package in this feed built with meson-python
rather than setuptools, against a cross file this repo writes itself
(pkg_mesoncross), with `-Dallow-noblas=true` and `-Ddisable-optimization=true`.
Each of those is a place where a build can succeed, install cleanly, import
fine, and be wrong underneath:

  * allow-noblas selects numpy's bundled `lapack_lite` instead of a real
    LAPACK. `np.linalg.lstsq` is the call that goes through it, and it is not
    hypothetical -- `_r2_sinusoidal_fit` in extras/stepper_resonance_tester.py
    makes it on every VFA calibration round.
  * a cross build that silently produced host objects would fail at import,
    which test_klippy_extras_import.py already covers -- but one that lost an
    accelerated path while keeping the module would not.

So this asks for numeric answers, not for a module object. The four calls
below are exactly the ones the calibration path makes: rfft and hanning in
`harmonic_extract_using_fft`, polyfit in `parabolic_interpolation`, lstsq in
`_r2_sinusoidal_fit`.

WHY NOT THE ABI

test_abi.py already sweeps every ELF object on the filesystem, so numpy's
extensions are covered there the moment they ship, and duplicating it here
would only make that sweep's failures arrive twice. This is the other half:
the ABI test proves the kernel will load them, this proves they compute.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"

# Ours, not FlashForge's 3.8.2. FlashForge's rootfs HAD a numpy; that one is
# built for 3.8 and is not importable here, which is the whole reason this
# package exists.
PY = MODDIR + "/bin/python3.13"
ENV = MODDIR + "/anvil-env.sh"


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, with the interpreter this asks about."""
    if not printer.file(PY).exists:
        pytest.fail(
            "there is no %s, so there is no interpreter to ask -- "
            "`make build` first." % PY)
    return printer


def _py(box, body, timeout=300):
    return box.sh(". %s\nexec %s - <<'PYEOF'\n%s\nPYEOF\n" % (ENV, PY, body),
                  timeout=timeout)


def test_numpy_imports_at_all(box):
    """The dependency anvil-klipper declares, present on the machine.

    Separate from the maths below so a missing package reads as a missing
    package rather than as four failed calculations.
    """
    res = _py(box, "import numpy; print(numpy.__version__)")
    assert res.ok, (
        "numpy does not import on %s, so klippy cannot start: klippy.py:122 "
        "loads [stepper_resonance_tester] and klippy.py:103 does not catch "
        "ImportError.\nexit=%s\n%s\n%s"
        % (PY, res.code, res.out[-2000:], res.err[-2000:]))
    assert res.out.strip(), "numpy imported but reported no version"


def test_the_four_calls_the_calibration_makes(box):
    """rfft, hanning, polyfit, lstsq -- with answers checked, not just no traceback.

    The values are the ones a correct numpy must produce, computed against
    closed forms rather than against a recorded run of this same code, so a
    subtly wrong build cannot agree with its own output.
    """
    body = r'''
import numpy as np

fails = []

def check(name, got, want, tol=1e-6):
    if abs(got - want) > tol:
        fails.append("%s: got %r, want %r" % (name, got, want))

# rfft on a pure tone: a 16-sample signal at exactly bin 3 must put all its
# energy in that bin and (near) none elsewhere.
n = 16
sig = np.cos(2 * np.pi * 3 * np.arange(n) / n)
spec = np.abs(np.fft.rfft(sig))
check("rfft peak bin", float(np.argmax(spec)), 3.0)
check("rfft peak amplitude", float(spec[3]), n / 2.0, 1e-9)

# hanning: a symmetric window, zero at both ends, 1.0 in the middle for odd N.
w = np.hanning(9)
check("hanning[0]", float(w[0]), 0.0, 1e-12)
check("hanning[-1]", float(w[-1]), 0.0, 1e-12)
check("hanning mid", float(w[4]), 1.0, 1e-12)

# polyfit deg 2 on points taken FROM a known parabola: 2x^2 - 3x + 1.
x = np.array([-2.0, -1.0, 0.0, 1.0, 2.0])
y = 2 * x ** 2 - 3 * x + 1
c = np.polyfit(x, y, 2)
check("polyfit a", float(c[0]), 2.0, 1e-6)
check("polyfit b", float(c[1]), -3.0, 1e-6)
check("polyfit c", float(c[2]), 1.0, 1e-6)

# lstsq: THE lapack_lite CALL. Overdetermined exact-fit system, y = 2a + 3b.
A = np.array([[1.0, 0.0], [0.0, 1.0], [1.0, 1.0]])
rhs = np.array([2.0, 3.0, 5.0])
sol, _res, _rank, _sv = np.linalg.lstsq(A, rhs, rcond=None)
check("lstsq x0", float(sol[0]), 2.0, 1e-6)
check("lstsq x1", float(sol[1]), 3.0, 1e-6)

if fails:
    print("FAILURES")
    for f in fails:
        print("  " + f)
else:
    print("ALL OK")
'''
    res = _py(box, body)
    assert res.ok, (
        "the numpy smoke test did not run to completion on %s.\nexit=%s\n%s\n%s"
        % (PY, res.code, res.out[-3000:], res.err[-3000:]))
    assert "ALL OK" in res.out, (
        "numpy is installed and imports, but computes wrong answers -- so the "
        "cross build produced something that loads and does not work. lstsq "
        "failing on its own points at -Dallow-noblas and the bundled "
        "lapack_lite; the rest points at the cross file.\n%s"
        % res.out[-3000:])
