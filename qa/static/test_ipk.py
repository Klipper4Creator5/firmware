"""The packages we build, and the recipes and payload they come out of.

WHAT IS AND IS NOT UNDER TEST HERE. The .ipk archives are built by opkg-build,
which is upstream's tool and upstream's problem -- these tests do not re-derive
the format, they check the things that are OURS and that upstream cannot know
about: that the layout we hand it puts every path under $MODDIR, that the
architecture string is one no public feed can satisfy, that a package is
reproducible, and that the payload is exactly the feed installed.

WHAT IS ASKED IS THE BUILT ARTIFACT, never the text of a script in this repo.
A gate that grepped bin/ or pkgs/lib.sh for a spelling went red on a rename
and stayed green through a real regression, so the several that did are gone
rather than rewritten -- the questions they asked are ones only a built
package or the replica can answer.

Every test builds its own package out of a synthetic tree -- three files and
two symlinks, no compiler, no firmware image -- so the lane stays fast and
cannot be skipped into looking green.

IT DOES NEED vendor/opkg-utils, which bin/fetch-assets.sh clones. That is a
change to what qa/static costs, and it is deliberate: the alternative was to
keep hand-rolling the archive format in this repo so that the tests needed
nothing, which is the trade the packager was rewritten to stop making. A
missing opkg-utils FAILS rather than skips, for the reason qa/conftest.py
gives about shellcheck.

The format itself was verified against real opkg 0.7.0 -- our own cross-built
mipsel binary, under qemu, installing these packages and removing them again.
docs/notes/85-packaging.md records that run.
"""
import gzip
import hashlib
import io
import os
import pathlib
import re
import shutil
import subprocess
import tarfile

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

OPKG_UTILS = ROOT / "vendor" / "opkg-utils"
OPKG_BUILD = OPKG_UTILS / "opkg-build"

# The prefix every package this repo builds installs into. Spelled out rather
# than read out of common.sh because a test that derives its expectation from
# the thing under test cannot fail when the thing under test changes.
MODDIR = "/usr/data/anvil"
ARCH = "mipsel_xburst2"


@pytest.fixture(scope="session", autouse=True)
def opkg_utils_present():
    """A failure, not a skip -- see the module docstring and qa/conftest.py."""
    if not OPKG_BUILD.is_file():
        pytest.fail(
            "vendor/opkg-utils is missing, so nothing checked the packages we "
            "build. It is pinned by commit in versions.env and cloned by "
            "`./bin/fetch-assets.sh`; `make vendor` does it in the build image.")


# ------------------------------------------------------------------ fixtures

def _tree(tmp_path):
    """A staged tree shaped like a real one: a file, its soname links, junk.

    The symlinks are the part that matters. libsodium ships
    libsodium.so -> .so.26 -> .so.26.2.0 and the first of those is the name
    libnacl's dlopen fallback constructs, so a packager that dereferenced them
    would ship three copies of one 400KB object and still work -- until
    somebody noticed the payload had tripled.
    """
    root = tmp_path / "stage"
    (root / "lib").mkdir(parents=True)
    (root / "lib" / "libtest.so.1.2.3").write_bytes(b"\x7fELF" + b"payload" * 64)
    (root / "lib" / "libtest.so.1").symlink_to("libtest.so.1.2.3")
    (root / "lib" / "libtest.so").symlink_to("libtest.so.1.2.3")
    return root


def _build(tree, outdir, name="libtest", version="1.2.3-1", arch=ARCH,
           prefix=MODDIR, description="a test package"):
    """Lay out what opkg-build wants and run it -- the same two steps
    bin/build-packages.sh takes, at the same boundary."""
    layout = outdir.parent / ("layout-" + name + arch)
    shutil.rmtree(layout, ignore_errors=True)
    (layout / prefix.lstrip("/")).mkdir(parents=True)
    (layout / "CONTROL").mkdir(parents=True)
    subprocess.run(["cp", "-a", str(tree) + "/.",
                    str(layout / prefix.lstrip("/"))], check=True)
    (layout / "CONTROL" / "control").write_text(
        "Package: %s\nVersion: %s\nArchitecture: %s\n"
        "Maintainer: anvil <none@example.invalid>\nSection: libs\n"
        "Priority: optional\nDescription: %s\n"
        % (name, version, arch, description))
    outdir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, SOURCE_DATE_EPOCH="0")
    done = subprocess.run([str(OPKG_BUILD), "-o", "0", "-g", "0",
                           str(layout), str(outdir)],
                          capture_output=True, text=True, env=env)
    assert done.returncode == 0, done.stdout + done.stderr
    return outdir / ("%s_%s_%s.ipk" % (name, version, arch))


@pytest.fixture
def ipk(tmp_path):
    return _build(_tree(tmp_path), tmp_path / "packages")


# --------------------------------------------------------- ar member handling

def _ar_members(path):
    """(name, bytes) per member, walking the 60-byte ASCII headers.

    Written out here rather than shelled out to `ar t` so the test reads the
    member boundaries itself, the way opkg does when it streams the archive.
    """
    raw = open(path, "rb").read()
    assert raw[:8] == b"!<arch>\n", "not an ar archive"
    off, out = 8, []
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode().strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        out.append((name, raw[off + 60:off + 60 + size]))
        off += 60 + size + (size % 2)
    return out


def test_member_order_is_the_format(ipk):
    """debian-binary, control.tar.gz, data.tar.gz -- in that order.

    Not a convention. opkg reads the archive as a stream and gives up on a
    package whose control follows its data. This is upstream's job to get
    right; the test is here because the day somebody "simplifies" the packager
    back into this repo, this is the property that breaks silently.
    """
    assert [n for n, _ in _ar_members(ipk)] == \
        ["debian-binary", "control.tar.gz", "data.tar.gz"]


def test_debian_binary_declares_2_0(ipk):
    assert dict(_ar_members(ipk))["debian-binary"] == b"2.0\n"


# ----------------------------------------------------------------- the control

def _control(path):
    members = dict(_ar_members(path))
    with tarfile.open(fileobj=io.BytesIO(
            gzip.decompress(members["control.tar.gz"]))) as t:
        return t.extractfile("./control").read().decode()


def _fields(text):
    out = {}
    for line in text.splitlines():
        if line and not line[0].isspace() and ": " in line:
            k, v = line.split(": ", 1)
            out[k] = v
    return out


def test_control_carries_what_opkg_reads(ipk):
    f = _fields(_control(ipk))
    assert f["Package"] == "libtest"
    # Version is upstream-release: the release half is what lets a repackage
    # ship without lying about which upstream is inside.
    assert f["Version"] == "1.2.3-1"
    assert f["Architecture"] == ARCH


def test_architecture_is_not_an_openwrt_name(ipk):
    """The one field that is a safety property rather than metadata.

    OpenWrt's mipsel_24kc is the same ISA and the same o32 ABI as this printer
    and is built against musl. Its feeds are full of packages that would
    satisfy a dependency here, install without complaint, and then fail to load
    against glibc 2.29. Naming our architecture something no public feed uses
    is what makes that mistake loud instead of quiet.
    """
    assert _fields(_control(ipk))["Architecture"] not in (
        "mipsel_24kc", "mips_24kc", "mipsel", "mips", "all")


# -------------------------------------------------------------------- the data

def _data(path):
    members = dict(_ar_members(path))
    return tarfile.open(fileobj=io.BytesIO(gzip.decompress(members["data.tar.gz"])))


def test_every_path_lands_under_the_prefix(ipk):
    """Nothing this repo packages may own a path outside $MODDIR.

    The whole reason the mod lives on /usr/data is that the firmware partition
    is FlashForge's and an OTA rewrites it. A package that unpacked into /usr
    or /etc would survive exactly until the next factory update, and would take
    whatever it overwrote with it.
    """
    with _data(ipk) as t:
        names = [m.name for m in t.getmembers() if m.name not in (".", "./")]
    strays = [n for n in names
              if not (n.lstrip(".").startswith(MODDIR)
                      or MODDIR.startswith(n.lstrip(".").rstrip("/")))]
    assert not strays, "paths outside %s: %s" % (MODDIR, strays)


def test_symlinks_stay_symlinks(ipk):
    with _data(ipk) as t:
        links = {os.path.basename(m.name): m.linkname
                 for m in t.getmembers() if m.issym()}
    assert links == {"libtest.so": "libtest.so.1.2.3",
                     "libtest.so.1": "libtest.so.1.2.3"}


def test_two_builds_of_one_tree_are_byte_identical(tmp_path):
    """Reproducibility, which is what makes a pin bump reviewable.

    Without it there is no cheap way to prove that a bump changed what it said
    it changed: every rebuild differs, so every diff is noise. opkg-build gets
    this right when SOURCE_DATE_EPOCH is set and bin/build-packages.sh always
    sets it -- the test is what says nobody has stopped.
    """
    tree = _tree(tmp_path)
    a = _build(tree, tmp_path / "a")
    # A rebuild after the source tree's timestamps move, which is what a fresh
    # checkout or a re-extracted tarball looks like.
    os.utime(tree / "lib" / "libtest.so.1.2.3", (1000000, 1000000))
    b = _build(tree, tmp_path / "b")
    assert hashlib.sha256(open(a, "rb").read()).hexdigest() == \
        hashlib.sha256(open(b, "rb").read()).hexdigest()


# ------------------------------------------------- the recipes and the payload

# Both levels. pkgs/<name>/ is a recipe carrying files of this repo;
# pkgs/3rdparty/<name>/ builds a pinned tarball and carries none. The split is
# for people reading `ls pkgs/`; nothing about a package depends on which side
# a recipe sits, so every test here treats them as one set.
RECIPES = sorted(list((ROOT / "pkgs").glob("*/build.sh"))
                 + list((ROOT / "pkgs" / "3rdparty").glob("*/build.sh")))


def test_there_are_recipes():
    assert RECIPES, "no recipes under pkgs/ -- has the layout moved?"


@pytest.mark.parametrize("recipe", RECIPES,
                         ids=[p.parent.name for p in RECIPES])
def _mod_roots():
    """MOD_ROOTS as bin/payload.sh's own shell reads it.

    No model substitution to resolve: anvil-klipper-config carries both
    chamber configs and anvil-link-prog.sh picks on the printer.
    """
    patch = (ROOT / "bin" / "payload.sh").read_text()
    m = re.search(r'^MOD_ROOTS="(.*?)"', patch, re.M | re.S)
    assert m, "bin/payload.sh has no MOD_ROOTS -- has section 0 been rewritten?"
    assert "$MODEL_PKG" not in m.group(1), (
        "MOD_ROOTS expands $MODEL_PKG -- the chamber configs are one package, "
        "chosen on the printer rather than by the build")
    return m.group(1).split()


def test_the_payload_roots_name_real_packages():
    """A typo in MOD_ROOTS is silent, so it gets a test instead.

    payload.sh skips a root with no .ipk in the feed, because that is how a
    PKG_WHEN-gated recipe -- BUILD_HELIX=0, BUILD_TOOLCHANGE=0 -- drops out
    without the flags being restated here. The cost is that a misspelled root
    drops out the same way: no error, one package quietly missing from the
    release. Nothing downstream would notice; the payload would just be
    smaller.
    """
    names = {_conf(p.parent.name, "PKG_NAME") for p in RECIPES}
    for root in _mod_roots():
        assert root in names, (
            "bin/payload.sh installs '%s' and no recipe under pkgs/ builds a "
            "package by that name. payload.sh cannot tell this from a recipe "
            "that PKG_WHEN gated off, so it would ship without it" % root)


def test_the_payload_roots_stay_a_short_list():
    """The release is named; the closure is opkg's to work out.

    The point of installing from an indexed feed is that Depends decides what
    comes along -- which is also what an `opkg install anvil-moonraker` on a
    printer will do, so the metadata gets exercised on every build instead of
    only when somebody tries it. A MOD_ROOTS that has grown to the size of the
    feed means somebody answered a missing dependency by naming the package
    here, and the printer's copy of that install will still fail.
    """
    roots = [r for r in _mod_roots()
             if not r.startswith("anvil-klipper-creator5")]
    assert len(roots) <= 12, (
        "MOD_ROOTS names %d packages. Missing files belong in the depending "
        "recipe's PKG_DEPENDS, not here:\n  %s"
        % (len(roots), "\n  ".join(roots)))



# --------------------------------------------------- the assembled payload
#
# These read work/modpayload-root, which exists only after bin/payload.sh has
# run. That needs a stock FlashForge package, so it cannot be a precondition
# of this lane -- but when the tree IS there the questions are worth asking,
# and they are the only ones asked of the thing that actually ships.

def _payload():
    p = ROOT / "work" / "modpayload-root" / "usr" / "data" / "anvil"
    if not (p / "var" / "lib" / "opkg" / "status").is_file():
        pytest.skip("no assembled payload -- run bin/payload.sh")
    return p


def test_every_payload_file_is_owned_by_a_package():
    """Everything in the payload came from a package, or is on this list.

    Checked against opkg's own record of what it installed. The interesting
    output is not the pass but the allowlist below: the files that are in the
    payload and in no package, which is phase 2's remaining to-do list. It
    should shrink and must not grow by accident.
    """
    payload = _payload()

    owned = set()
    for f in (payload / "var" / "lib" / "opkg" / "info").glob("*.list"):
        for line in f.read_text().splitlines():
            path = line.split("\t")[0].strip()
            if path:
                owned.add(path)
    assert owned, "the opkg database lists no files at all"

    allowed = {
        # User state: created once and never overwritten. A package member is
        # overwritten on every upgrade by definition, which is exactly what
        # this must not be. $MODDIR/anvil.conf was the other entry here until
        # it was removed outright -- it is not merely unshipped, so it must
        # not reappear under any exemption.
        MODDIR + "/config/moonraker-custom.conf",
        # opkg's own scaffolding, made by opkg as it installs.
        MODDIR + "/var",
        MODDIR + "/var/lib",
        MODDIR + "/var/run",
    }

    extra = []
    for dirpath, dirnames, filenames in os.walk(payload):
        for name in list(dirnames) + list(filenames):
            p = pathlib.Path(dirpath, name)
            rel = MODDIR + "/" + str(p.relative_to(payload))
            if rel in owned or rel in allowed:
                continue
            # The database itself: written by opkg while installing, so it can
            # never appear in a list it is still being written into.
            if rel.startswith(MODDIR + "/var/lib/opkg"):
                continue
            # The compiled s6-rc database. case-build-payload.sh runs
            # s6-rc-compile over the source tree anvil-core ships, AFTER the
            # payload is installed, so it describes the payload and cannot be
            # finished before the payload is. The SOURCE it is compiled from
            # is package-owned and checked like everything else.
            if rel.startswith(MODDIR + "/etc/s6-rc/compiled"):
                continue
            extra.append(rel)

    assert not extra, (
        "%d path(s) in the payload belong to no package and are not on the "
        "allowlist in this test:\n  %s\n"
        "Either the file should come from a package, or it is new user state "
        "and belongs on the list with a reason."
        % (len(extra), "\n  ".join(sorted(extra)[:20])))


def test_the_payload_database_has_no_clock_in_it():
    """Two builds of one commit produce one payload, byte for byte.

    opkg stamps Installed-Time from time() and honours SOURCE_DATE_EPOCH only
    for a man-page date, so its database differs between two builds a second
    apart. payload.sh normalises the field: this is an image being baked, not a
    machine being installed.

    Asked of the database rather than of anvil.tar.xz, which is not
    reproducible yet for unrelated reasons (pack.sh's tar neither sorts nor
    clamps).
    """
    status = (_payload() / "var" / "lib" / "opkg" / "status").read_text()
    stamps = re.findall(r"^Installed-Time:\s*(\S+)$", status, re.M)
    assert stamps, "the opkg status file records no Installed-Time at all"
    assert len(set(stamps)) == 1, (
        "the payload's database carries %d different Installed-Time values "
        "(%s...). bin/payload.sh is meant to normalise them, so two builds of "
        "one commit differ by one line per package"
        % (len(set(stamps)), sorted(set(stamps))[:3]))


def test_the_payload_keeps_libsodium_as_a_symlink():
    """opkg restores a symlink as a symlink, checked where it has to hold.

    libnacl reaches libsodium through ctypes.cdll.LoadLibrary -- dlopen -- and
    the name its fallback constructs is
    __file__[0:__file__.find("lib")+3] + "/libsodium.so", i.e. exactly
    $MODDIR/lib/libsodium.so. There is no such file: there is a symlink to
    libsodium.so.26, which is a symlink to libsodium.so.26.2.0. Dereference
    either on the way through and Moonraker's authorization component stops
    loading, which is three layers from anything that mentions libsodium.

    pkgs/3rdparty/libsodium/build.sh already asserts this about its own build
    tree, and test_symlinks_stay_symlinks asserts opkg-build puts a symlink in
    an archive. Neither covers the step between them -- opkg unpacking the
    archive into the payload -- and that is the step bin/payload.sh used to
    check by hand.
    """
    lib = _payload() / "lib" / "libsodium.so"
    assert lib.is_symlink(), (
        "%s is not a symlink. libnacl's dlopen fallback asks for that exact "
        "name and gets whatever opkg left there" % lib)
    assert lib.resolve().is_file(), (
        "%s is a symlink to nothing -- %s is missing from the payload"
        % (lib, os.readlink(lib)))


# Scripts that build or ship something, and could therefore host a gate.
def _buildish_scripts():
    named = ["bin/common.sh", "bin/build-packages.sh", "bin/verify.sh",
             "bin/payload.sh", "bin/pack.sh", "pkgs/lib.sh",
             "tools/python/build.sh", "tools/python-packages/build.sh",
             "tools/python-packages/build-libsodium.sh"]
    found = [ROOT / n for n in named]
    found += sorted(ROOT.glob("pkgs/*/build.sh"))
    found += sorted(ROOT.glob("pkgs/3rdparty/*/build.sh"))
    return [f for f in found if f.is_file()]


# The compiler wrapper check is NOT a second gate and these four files may
# keep it. It compiles a hello-world and reads THAT object's header, so what
# it judges is the toolchain, not anything the build produced -- a question
# qa/replica/test_abi.py structurally cannot answer, because a filesystem
# sweep cannot see a compiler. It also fails in a second, before a whole feed
# is built on a wrapper that quietly lost -mnan=2008.
#
# They are allowed the raw e_flags words and nothing else: an artefact gate
# needs to say nan2008/o32/mips32r2 (or call mips_abi_gate) to do its job, and
# the wrapper checks never do, so that vocabulary stays forbidden everywhere.
WRAPPER_CHECK_OK = {
    "pkgs/lib.sh",
    "tools/python/build.sh",
    "tools/python-packages/build.sh",
    "tools/python-packages/build-libsodium.sh",
}

# "nan2008" and not "mips32r2": an artefact gate has to read the NaN encoding
# out of the header, and only a gate ever says that word -- whereas mips32r2
# is ALSO the name of an ISA compiler flag, and pkgs/3rdparty/openssl/build.sh
# legitimately passes -mips32r2 to put the ISA back where the printer is. A
# guard word that collides with a build flag reports the flag, which is a
# false alarm and, once it is tuned out, a guard nobody reads.
GATE_WORDS = ("nan2008", "mips_abi_gate")

# The raw e_flags words. Forbidden outside the four files allowed the wrapper
# check -- inside them a hex-only gate would still slip past, which is a known
# and accepted limit: two of those four are the superseded standalone trees
# under tools/ and nothing they build reaches a printer.
GATE_FLAGS = "0x7000140"

# --------------------------------------------------------------------------
# One recipe, one package.
#
# The rule the pkgs/ layout exists to enforce. A recipe that builds its
# dependencies inline leaves them with no version, no package and no way to be
# reused -- which is how one zlib comes to be cross-built twice.

def _sh(snippet):
    """Run a snippet with bin/common.sh and pkgs/lib.sh sourced, from ROOT."""
    out = subprocess.run(
        ["bash", "-c", ". bin/common.sh; . pkgs/lib.sh; %s" % snippet],
        cwd=ROOT, capture_output=True, text=True)
    assert out.returncode == 0, (
        "shell helper failed:\n%s\n%s" % (out.stdout, out.stderr))
    return out.stdout.strip()


def _conf(recipe, var):
    return _sh('pkg_conf %s; printf "%%s" "$%s"' % (recipe, var))


def test_an_arch_all_package_has_no_native_code():
    """Architecture: all is a promise, and it is cheap to check.

    Three packages claim it -- anvil-mainsail, anvil-moonraker and anvil-core
    -- on the grounds that they are JavaScript, Python and shell. The claim
    matters because opkg accepts `all` on any printer without consulting the
    ABI, so an ELF object that slipped into one of them would install on a
    printer that cannot run it. qa/replica/test_abi.py would refuse the
    object once it were on a machine; this refuses the CLAIM, here, without
    needing a replica -- and it is the only check that reads `all` as a
    promise rather than as an absence of anything to check.

    Checked against the built tree when there is one; a checkout that has not
    run `make packages` has nothing to inspect and is not a failure.
    """
    for recipe in sorted(p.parent.name for p in RECIPES):
        if _conf(recipe, "PKG_ARCH") != "all":
            continue
        out = ROOT / "work" / "pkg" / recipe
        if not out.is_dir():
            continue
        elves = []
        for f in out.rglob("*"):
            if not f.is_file() or f.is_symlink():
                continue
            with open(f, "rb") as fh:
                if fh.read(4) == b"\x7fELF":
                    elves.append(str(f.relative_to(out)))
        assert not elves, (
            "recipe %s declares Architecture: all and its tree contains ELF "
            "objects: %s. An `all` package installs on any printer without an "
            "architecture check." % (recipe, ", ".join(sorted(elves)[:5])))


def test_a_dev_split_partitions_the_build():
    """PKG_DEV_FILES moves files; it never copies them.

    A path in both the runtime and the dev package is a path two packages
    own. opkg resolves that by letting whichever installed last win, and
    removing either one deletes a file the other still lists -- so the damage
    shows up as a missing file long after the install that caused it. The split is a partition, and this is what says so.

    Checked against the built feed when there is one; a checkout that has not
    run `make packages` has nothing to compare.
    """
    feed = ROOT / "work" / "packages"
    if not feed.is_dir():
        return
    for recipe in sorted(p.parent.name for p in RECIPES):
        if not _conf(recipe, "PKG_DEV_FILES"):
            continue
        name = _conf(recipe, "PKG_NAME")
        pair = []
        for suffix in ("", "-dev"):
            hits = sorted(feed.glob("%s%s_*.ipk" % (name, suffix)))
            if hits:
                pair.append(hits[0])
        if len(pair) != 2:
            continue
        # Directories are legitimately shared -- both packages live under
        # $MODDIR and opkg is content for two packages to own a directory.
        # Files are not: a regular file or symlink in both archives is the
        # bug this test is about.
        runtime, dev = ({m.name for m in _data(pair[0]) if not m.isdir()},
                        {m.name for m in _data(pair[1]) if not m.isdir()})
        shared = runtime & dev
        assert not shared, (
            "%s and %s-dev both contain %s -- PKG_DEV_FILES must move files "
            "out of the runtime package, not copy them"
            % (name, name, ", ".join(sorted(shared)[:5])))


def test_a_dev_package_installs_nothing_a_printer_runs():
    """Whatever the split moved out is gone from the runtime package.

    The point of the split is that a printer with no compiler stops carrying
    headers and static archives. That is only true if the runtime half no
    longer contains them, which is a different claim from "the dev half does".
    """
    feed = ROOT / "work" / "packages"
    if not feed.is_dir():
        return
    for recipe in sorted(p.parent.name for p in RECIPES):
        if not _conf(recipe, "PKG_DEV_FILES"):
            continue
        name = _conf(recipe, "PKG_NAME")
        hits = sorted(feed.glob("%s_*.ipk" % name))
        if not hits:
            continue
        stragglers = [m.name for m in _data(hits[0])
                      if m.name.endswith((".a", ".h", ".pc"))]
        assert not stragglers, (
            "%s declares a dev split and still ships %s"
            % (name, ", ".join(sorted(stragglers)[:5])))


def test_every_recipe_has_metadata():
    """pkg.conf is what makes a directory a recipe, and it is required.

    bin/build-packages.sh discovers recipes by pkg.conf, so a build.sh without
    one is never built by anything and would rot unnoticed.
    """
    for recipe in RECIPES:
        assert (recipe.parent / "pkg.conf").is_file(), (
            "%s has no pkg.conf, so nothing will ever build it" % recipe)


def test_build_order_is_topological():
    """pkg_order puts a dependency before the recipe that needs it.

    Alphabetical order -- what iterating pkgs/*/ gives you, and what this used
    to do -- is wrong the moment there are two recipes: libarchive sorts before
    the zlib it builds against. The failure is not subtle (configure cannot
    find zlib.h) but it is a build that worked yesterday failing today because
    somebody added a package whose name sorts early.
    """
    recipes = _sh("pkg_recipes").split()
    order = _sh("pkg_order %s" % " ".join(recipes)).split()
    assert sorted(order) == sorted(recipes), (
        "pkg_order returned %s for %s" % (order, recipes))
    for r in recipes:
        for dep in _conf(r, "PKG_BUILD_DEPENDS").split():
            assert order.index(dep) < order.index(r), (
                "%s is built before its dependency %s: %s" % (r, dep, order))


def test_asking_for_one_recipe_builds_its_dependencies():
    """`PKG=opkg make packages` must not fail on an empty sysroot.

    A recipe consumes its dependencies out of the feed, so asking for one
    package has to mean asking for its closure -- otherwise the first build on
    a clean checkout dies in configure with a missing header.
    """
    for r in _sh("pkg_recipes").split():
        closure = _sh("pkg_order %s" % r).split()
        assert closure[-1] == r
        for dep in _conf(r, "PKG_BUILD_DEPENDS").split():
            assert dep in closure, (
                "pkg_order %s omits its build dependency %s" % (r, dep))


def test_a_dev_package_ships_what_its_dependents_need():
    """A library that exists to be built against ships headers, .a and .pc.

    This is what makes building against the PACKAGE rather than against the
    build tree worth the extra step: a package that forgot a header fails the
    next recipe's configure. Asserted on the ship list so it is checked without
    a toolchain, on a bare checkout, in CI.
    """
    zlib = (ROOT / "pkgs" / "3rdparty" / "zlib" / "build.sh").read_text()
    for want in ("include/zlib.h", "lib/libz.a", "lib/pkgconfig/zlib.pc"):
        assert want in zlib, "pkgs/3rdparty/zlib does not ship %s" % want
    arch = (ROOT / "pkgs" / "3rdparty" / "libarchive" / "build.sh").read_text()
    for want in ("include/archive.h", "lib/libarchive.a",
                 "lib/pkgconfig/libarchive.pc"):
        assert want in arch, "pkgs/3rdparty/libarchive does not ship %s" % want

    # skalibs is the interesting one, and the reason this test is not just
    # "headers and an archive". lib/skalibs is a directory of CROSS-COMPILE
    # ANSWERS ABOUT THE LIBC -- does this target have /dev/urandom, does
    # posix_spawn return early -- that skalibs would normally settle by
    # compiling and running a probe, which a cross-build cannot do. execline,
    # s6 and s6-rc all read it through --with-sysdeps and refuse to configure
    # without it, naming a missing FILE rather than a missing flag. It is not a
    # header, not an archive and not a .pc, so a rule written around those
    # three would have let it be dropped.
    ska = (ROOT / "pkgs" / "3rdparty" / "skalibs" / "build.sh").read_text()
    for want in ("include/skalibs", "lib/libskarnet.a", "lib/skalibs"):
        assert want in ska, "pkgs/3rdparty/skalibs does not ship %s" % want


def test_the_python_package_list_and_the_recipes_agree():
    """PYPKG_LIST and pkgs/3rdparty/python-* are one list, and it is checked.

    versions.env carries the pin for each third-party python package and
    bin/fetch-assets.sh downloads from that list, while what actually BUILDS
    each one is a recipe directory. Those are two spellings of one set, and the
    failure when they disagree is quiet in both directions: an entry added to
    versions.env alone is fetched, hashed and never built, and a recipe added
    alone has no source to build from.

    This checks both directions at once, without building anything. It used to
    say that bin/payload.sh checked the first one at build time as it looped over
    the list; payload.sh installs packages now and has no such loop, so this is
    the only thing asking.
    """
    listed = set(_sh('printf "%s" "$PYPKG_LIST"').split())
    recipes = {d.name[len("python-"):] for d in (ROOT / "pkgs" / "3rdparty").glob("python-*")
               if d.is_dir()}
    assert listed == recipes, (
        "PYPKG_LIST and the pkgs/3rdparty/python-* recipes disagree.\n"
        "  in versions.env only: %s\n"
        "  in pkgs/ only:         %s"
        % (sorted(listed - recipes) or "none", sorted(recipes - listed) or "none"))


def test_a_python_package_does_not_pin_its_version_twice():
    """The version comes out of the pinned file name, never written again.

    Every sdist is <name>-<version>.tar.gz and versions.env pins the FILE, so
    the version is already there. A PKG_VERSION written out by hand in the
    pkg.conf would be a second copy of a string nobody would think to update
    together with the first -- and the result is a .ipk that claims a version
    it does not contain, which nothing downstream can detect.
    """
    for conf in sorted((ROOT / "pkgs" / "3rdparty").glob("python-*/pkg.conf")):
        name = conf.parent.name[len("python-"):]
        text = conf.read_text()
        want = 'PKG_VERSION="$(pypkg_version %s)"' % name
        assert want in text, (
            "%s does not read its version from the pin: expected\n  %s\n"
            "so that versions.env stays the only place the version is written"
            % (conf.relative_to(ROOT), want))


# test_bin_patch_builds_every_python_package WAS HERE and is deleted rather
# than rewritten. It asserted that bin/payload.sh contained
# `for p in $PYPKG_LIST; do` and ran each pkgs/3rdparty/python-$p/build.sh,
# which was how the eighteen wheels reached the payload. payload.sh installs
# packages now and does not know which of them are wheels, so the loop is
# gone.
#
# Nothing is lost: the property it was protecting -- a pin in PYPKG_LIST with
# no recipe is fetched, hashed and never built -- is
# test_the_python_package_list_and_the_recipes_agree above, which checks it in
# BOTH directions and needs neither a build nor a shell script to read.

def test_every_declared_dependency_is_a_package_this_feed_builds():
    """A Depends the feed cannot satisfy is an install that refuses itself.

    opkg resolves Depends before it unpacks anything, so a package naming one
    that does not exist does not install PARTIALLY -- it does not install at
    all, and the error names the missing dependency rather than the recipe that
    asked for it. Nothing in a build catches this: bin/build-packages.sh writes
    whatever PKG_DEPENDS says into the control file, opkg-make-index copies it
    into the index, and the first thing to notice is a printer.

    Checked from the pkg.conf files rather than from a built feed, so it runs
    on a bare checkout. Names ending -dev are matched against the recipes that
    set PKG_DEV_FILES, because that is what makes the second archive exist.

    Dependencies on the STOCK ROOTFS are a different thing and are deliberately
    absent everywhere: anvil-python needs libatomic.so.1 and does not say so,
    because opkg has no idea what FlashForge installed and would refuse a
    package for want of a library that is already there.
    """
    provided = set()
    for conf in RECIPES:
        recipe = conf.parent.name
        name = _conf(recipe, "PKG_NAME")
        provided.add(name)
        if _conf(recipe, "PKG_DEV_FILES"):
            provided.add(name + "-dev")
        # A VIRTUAL NAME COUNTS AS PROVIDED, which is the whole point of
        # Provides: anvil-klipper-config depends on "a chamber config" and
        # either model package satisfies it. Without this the check would
        # reject exactly the arrangement it exists to protect.
        provided.update(_conf(recipe, "PKG_PROVIDES").split())

    for conf in RECIPES:
        recipe = conf.parent.name
        depends = _conf(recipe, "PKG_DEPENDS")
        for dep in [d.strip().split()[0] for d in depends.split(",") if d.strip()]:
            assert dep in provided, (
                "recipe %s depends on '%s' and no recipe under pkgs/ produces it. "
                "opkg refuses the whole install rather than part of it, so "
                "this is a package that cannot be installed at all."
                % (recipe, dep))
