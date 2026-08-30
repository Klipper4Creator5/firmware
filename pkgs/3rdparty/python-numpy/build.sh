#!/usr/bin/env bash
# numpy -- built for the printer's CPython, into its site-packages.
#
# THE ONLY meson-python RECIPE IN THE FEED. Every other python-* package here
# builds with setuptools, where _PYTHON_SYSCONFIGDATA_NAME alone is enough to
# make the build answer for mipsel. Meson has never heard of that variable, so
# this one hands it a cross file instead -- see pkg_mesoncross in pkgs/lib.sh
# for what is in it and why each line is there.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-numpy || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz numpy)"

_np=$(pkg_pysrc numpy)

# numpy's meson.build refuses gcc below 8.4, and ours is 7.2. THE GATE IS
# CONSERVATIVE RATHER THAN LOAD-BEARING, and that was probed before it was
# lowered: numpy 2.1's requirement is a C++17 compiler, and this toolchain
# compiles the features it actually uses -- if constexpr, structured bindings,
# std::optional, std::string_view -- as well as pocketfft_hdronly.h, 3635 lines
# of the heaviest template C++ in the tree and the half np.fft.rfft needs.
# The upstream number comes from the SciPy Toolchain Roadmap, which is a
# statement about what the project supports, not about what the code requires.
#
# The floor is LOWERED, not removed: a genuinely ancient gcc should still be
# refused here rather than three screens into a compile log. If this recipe
# ever fails with a C++ error rather than a version error, that is the gate
# turning out to be real after all, and the fix is a newer cross toolchain --
# not a smaller number.
if ! grep -q "version_compare('>=8.4')" "$_np/meson.build"; then
    pkg_die "python-numpy: the gcc version gate in meson.build is not where
             this recipe patches it -- numpy $(pypkg_version numpy) has moved
             it, and the comment above needs re-checking against the new one"
fi
sed -i "s/version_compare('>=8.4')/version_compare('>=7.2')/" "$_np/meson.build"

# -Dallow-noblas: no BLAS/LAPACK in this feed, so take the bundled lapack_lite.
#   Without this numpy 2.x fails configure rather than falling back.
# -Ddisable-optimization: numpy's SIMD dispatch machinery generates and builds
#   a matrix of per-feature objects. There is no MIPS path in it, so every one
#   of them is a baseline build anyway -- this drops the generation step and,
#   with it, the largest surface for a gcc 7.2 to refuse something.
PKG_PY_PIP_ARGS="--config-settings=setup-args=--cross-file=$(pkg_mesoncross)
                 --config-settings=setup-args=-Dallow-noblas=true
                 --config-settings=setup-args=-Ddisable-optimization=true"

pkg_pywheel numpy

# PRUNE BEFORE SHIP, and only things nothing on a printer can reach.
#   tests/            ~8MB of pytest files; pytest is not on this machine.
#   f2py/             a Fortran wrapper generator, and there is no Fortran here.
#   *.pyi, py.typed   type stubs, read by type checkers and never at runtime.
#   _core/lib/*.a     static libs for BUILDING against numpy's C API, which
#                     nothing on the printer does.
# The .so files are not touched here: pkg_ship runs the cross strip over
# everything it copies.
find "$PKG_PYSP/numpy" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$PKG_PYSP/numpy/f2py"
find "$PKG_PYSP/numpy" -name '*.pyi' -delete 2>/dev/null || true
find "$PKG_PYSP/numpy" -name 'py.typed' -delete 2>/dev/null || true
find "$PKG_PYSP/numpy" -name '*.a' -delete 2>/dev/null || true

pkg_ship "lib/python$PY_MM/site-packages"

# A COUNT, AND A HIGH ONE ON PURPOSE. numpy has a pure-python fallback for
# nothing -- if the cross build quietly produced no extensions there would be
# no import at all, but a partial build that lost _multiarray_umath while
# keeping the small ones would import far enough to look installed. Eight is
# comfortably below what a whole numpy ships and far above any partial one.
pkg_pynative 8
pkg_end
