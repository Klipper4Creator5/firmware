"""The packages we build, and the installer that reads what upstream writes.

WHAT IS AND IS NOT UNDER TEST HERE. The .ipk archives are built by opkg-build,
which is upstream's tool and upstream's problem -- these tests do not re-derive
the format, they check the things that are OURS and that upstream cannot know
about: that the layout we hand it puts every path under $MODDIR, that the
architecture string is one no public feed can satisfy, that a package is
reproducible, and that pkg/ipk-install can install and remove what comes out.
Plus one structural gate per worry that has already cost time once -- a recipe
growing its own copy of the cross-build, or a package escaping the ABI check.

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
import tempfile

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

OPKG_UTILS = ROOT / "vendor" / "opkg-utils"
OPKG_BUILD = OPKG_UTILS / "opkg-build"
INSTALLER = ROOT / "pkg" / "ipk-install"

# The prefix every package this repo builds installs into, and the one
# pkg/ipk-install hardcodes. Spelled out rather than read out of common.sh
# because a test that derives its expectation from the thing under test cannot
# fail when the thing under test changes.
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

    Written out here rather than shelled out to `ar t` because pkg/ipk-install
    walks the same headers by hand -- the printer's busybox has no ar applet to
    bet on -- and a test that used the real ar would not notice if the two
    disagreed about where a member starts.
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


# ------------------------------------------------------- the installer, on it

def _run_installer(*args, root=None):
    cmd = ["sh", str(INSTALLER)] + [str(a) for a in args]
    if root is not None:
        cmd += ["--root", str(root)]
    return subprocess.run(cmd, capture_output=True, text=True, cwd=str(ROOT))


def test_install_then_remove_is_a_round_trip(tmp_path, ipk):
    """Everything the package brought, and nothing else, goes away again.

    This is the property payload/run-append.sh's install manifest exists to
    give the tarball, and the reason it exists there is written down in that
    file: the installer used to `rm -rf` seven whole directories, which is
    correct only while every file under them is ours.
    """
    root = tmp_path / "root"
    # A file that is not ours, in a directory the package will also use.
    (root / MODDIR.lstrip("/") / "lib").mkdir(parents=True)
    bystander = root / MODDIR.lstrip("/") / "lib" / "not-ours.so"
    bystander.write_text("someone else's")

    done = _run_installer("install", ipk, root=root)
    assert done.returncode == 0, done.stderr
    lib = root / MODDIR.lstrip("/") / "lib"
    assert (lib / "libtest.so.1.2.3").is_file()
    assert os.readlink(lib / "libtest.so") == "libtest.so.1.2.3"

    done = _run_installer("remove", "libtest", root=root)
    assert done.returncode == 0, done.stderr
    assert not (lib / "libtest.so.1.2.3").exists()
    assert not (lib / "libtest.so").exists()
    # The directory survived because something else is in it, and that
    # something else survived too.
    assert bystander.read_text() == "someone else's"


def test_reinstall_leaves_one_stanza(tmp_path, ipk):
    """An upgrade is a remove and an install, not an unpack over the top.

    Two stanzas for one package is not cosmetic: the status file is read
    first-match, so `list` and `remove` start answering about different
    installs of the same name.
    """
    root = tmp_path / "root"
    assert _run_installer("install", ipk, root=root).returncode == 0
    second = _run_installer("install", ipk, root=root)
    assert second.returncode == 0, second.stderr
    status = (root / MODDIR.lstrip("/") / "var/lib/opkg/status").read_text()
    assert status.count("Package: libtest") == 1
    assert _run_installer("list", root=root).stdout.strip() == "libtest - 1.2.3-1"


def test_the_database_is_where_opkg_looks_for_it(tmp_path, ipk):
    """$MODDIR/var/lib/opkg, with opkg's own file names.

    Not a homage: it is what makes pkg/opkg a swap rather than a migration.
    Verified from the other side too -- our cross-built opkg, run under qemu,
    puts its status file at exactly this path, because it was configured
    --prefix=/usr/data/anvil. opkg resolves that directory from its COMPILE
    TIME prefix and not from --offline-root, which is the trap pkg/opkg/build.sh
    exists to document.
    """
    root = tmp_path / "root"
    assert _run_installer("install", ipk, root=root).returncode == 0
    db = root / MODDIR.lstrip("/") / "var" / "lib" / "opkg"
    assert (db / "status").is_file()
    assert (db / "info" / "libtest.control").is_file()
    listed = (db / "info" / "libtest.list").read_text().split()
    assert MODDIR + "/lib/libtest.so.1.2.3" in listed
    # Absolute, every one of them: pkg/ipk-install refuses a relative entry
    # rather than pasting $ROOT onto the front of it and finding out.
    assert all(p.startswith("/") for p in listed)


def test_a_foreign_architecture_is_refused(tmp_path):
    """An OpenWrt mipsel_24kc package must not install on this printer.

    Same ISA, same ABI, musl libc. It would unpack perfectly and produce a
    library nothing can load, and the report would come back as an ImportError
    from Moonraker with no mips in it anywhere.
    """
    foreign = _build(_tree(tmp_path), tmp_path / "packages", arch="mipsel_24kc")
    done = _run_installer("install", foreign, root=tmp_path / "root")
    assert done.returncode != 0
    assert "mipsel_24kc" in done.stderr and "mipsel_xburst2" in done.stderr


def test_the_installer_needs_no_ar(tmp_path, ipk):
    """It walks the ar headers itself, because busybox here may have no ar.

    The printer's busybox is 1.31.1 built small -- no `timeout`, no `nc`, no
    `ionice`, all measured on the replica rather than assumed. Betting the
    installer on an applet nobody has checked for is how a firmware update
    fails at the last step. The test runs it with ar removed from PATH.
    """
    if shutil.which("ar") is None:
        pytest.fail("this machine has no ar, so the test proves nothing -- "
                    "install binutils")
    fake = tmp_path / "nobin"
    fake.mkdir()
    for tool in ("sh", "tar", "gzip", "sed", "awk", "cut", "tr", "sort",
                 "head", "tail", "rm", "mkdir", "cp", "mv", "date", "wc",
                 "cat", "grep", "rmdir", "find", "ln"):
        src = shutil.which(tool)
        if src:
            os.symlink(src, fake / tool)
    done = subprocess.run(
        ["sh", str(INSTALLER), "install", str(ipk),
         "--root", str(tmp_path / "root")],
        capture_output=True, text=True, cwd=str(ROOT),
        env={"PATH": str(fake), "HOME": os.environ.get("HOME", "/tmp")})
    assert done.returncode == 0, done.stderr


# ------------------------------------------------- the recipes and the payload

RECIPES = sorted((ROOT / "pkg").glob("*/build.sh"))


def test_there_are_recipes():
    assert RECIPES, "no recipes under pkg/ -- has the layout moved?"


@pytest.mark.parametrize("recipe", RECIPES,
                         ids=[p.parent.name for p in RECIPES])
def test_a_recipe_does_not_rebuild_the_shared_parts(recipe):
    """No recipe carries its own copy of the cross-build.

    This is the gate for the thing that was already going wrong before pkg/
    existed: bin/patch.sh had the toolchain-unpack, the gcc-wrapper trick and
    the configure/make/install dance written out three times, for s6, CPython
    and libsodium, and the copies had drifted -- one gated its compiler wrapper
    before trusting it and the others did not.

    So a recipe must go through pkg/lib.sh rather than spell those steps again.
    Checked by looking for the shapes that mean "I wrote my own": a gcc wrapper
    heredoc, a bare ./configure --host, an untarred toolchain. A recipe that
    genuinely needs something pkg/lib.sh cannot express should GROW pkg/lib.sh,
    which is the entire point.

    zlib is the one allowed exception and it is allowed by name: its configure
    is a hand-written script that has never accepted --host, so pkg/opkg builds
    it inline with CHOST. If a second exception ever appears, that is the
    signal that pkg/lib.sh needs another verb, not that this test needs another
    name.
    """
    text = recipe.read_text()
    assert ". pkg/lib.sh" in text, (
        "%s does not source pkg/lib.sh, so whatever it does instead is a "
        "second copy of the cross-build" % recipe)

    body = "\n".join(ln for ln in text.splitlines()
                     if not ln.lstrip().startswith("#"))
    # The toolchain is pkg_toolchain's job, exclusively.
    assert not re.search(r"tar .*(mips-toolchain|musl-toolchain)", body), (
        "%s unpacks a toolchain itself; pkg_toolchain does that" % recipe)
    assert "-mnan=2008" not in body, (
        "%s spells its own compiler flags; pkg_toolchain owns the ABI flags"
        % recipe)
    # ./configure is pkg_autotools' job, with zlib named as the exception.
    for line in body.splitlines():
        if "./configure" in line:
            assert "CHOST=" in line, (
                "%s runs ./configure directly:\n  %s\nUse pkg_autotools, or "
                "extend pkg/lib.sh if it cannot express what this needs."
                % (recipe, line.strip()))


def test_the_package_and_the_payload_share_one_build():
    """libsodium is compiled once, whichever vehicle it ships in.

    bin/patch.sh stages $SODIUM_BUILD into the payload and pkg/libsodium
    packages $SODIUM_BUILD, and both get there by running
    pkg/libsodium/build.sh. While that is true the tarball's copy and the
    package's copy cannot be different libraries wearing one version number.
    It stops being true the moment somebody gives either side its own configure
    line, which is a one-line edit and would be invisible in review.
    """
    patch = (ROOT / "bin" / "patch.sh").read_text()

    # Every recipe whose output bin/patch.sh stages into the payload. Listed
    # rather than derived, because the property under test is that a HUMAN
    # decided each of these ships both ways -- a list read off patch.sh would
    # agree with patch.sh by construction and assert nothing.
    staged = ("libsodium", "mainsail", "moonraker", "helixscreen",
              "skalibs", "execline", "s6", "s6-rc", "anvil-core")
    for recipe in staged:
        assert "bash pkg/%s/build.sh" % recipe in patch, (
            "bin/patch.sh does not run pkg/%s/build.sh -- the payload's copy "
            "and the packaged one are built by different code, and nothing "
            "downstream can tell which a printer got" % recipe)
        assert (ROOT / "pkg" / recipe / "build.sh").is_file(), (
            "bin/patch.sh runs pkg/%s/build.sh and there is no such recipe"
            % recipe)

    # And the reverse direction: patch.sh must not have grown its own copy of
    # a build it delegates. A `./configure` anywhere in it would mean some
    # component is compiled in two places again -- which is what this whole
    # layout was written to stop, and what section 5b did for skalibs and s6
    # until it became four recipes.
    body = "\n".join(ln for ln in patch.splitlines()
                      if not ln.lstrip().startswith("#"))
    for gone in ("--enable-static-libc", "MUSL_TOOLCHAIN", "S6_STAMP"):
        assert gone not in body, (
            "bin/patch.sh still mentions %s -- the s6 build moved to pkg/ and "
            "the musl toolchain was deleted with it" % gone)


def test_packages_are_abi_gated_before_they_ship():
    """bin/build-packages.sh runs mips_abi_gate over every recipe's tree.

    bin/patch.sh gates the staged payload, and that does not cover this: a
    package can be built by `make packages` on a machine that never runs
    patch.sh. An .ipk is a shipping vehicle and gets gated like one.
    """
    assert "mips_abi_gate" in (ROOT / "bin" / "build-packages.sh").read_text()
    assert "mips_abi_gate()" in (ROOT / "bin" / "common.sh").read_text()


def test_the_archives_are_built_by_upstream():
    """We drive opkg-build; we do not reimplement it.

    There was a hand-written ar-and-two-tarballs packager here for one
    revision. It worked, and it was still 120 lines of this repo re-deriving a
    format somebody else maintains -- including the parts whose failure mode is
    a package that inspects fine and installs nowhere. If those lines come
    back, this goes red.
    """
    build = (ROOT / "bin" / "build-packages.sh").read_text()
    assert "opkg-build" in build and "opkg-make-index" in build
    assert not (ROOT / "bin" / "mkipk.sh").exists(), (
        "bin/mkipk.sh is back -- opkg-utils is the packager")
    body = "\n".join(ln for ln in build.splitlines()
                     if not ln.lstrip().startswith("#"))
    assert "ar rD" not in body and "debian-binary" not in body, (
        "bin/build-packages.sh is assembling the archive itself again")


# --------------------------------------------------------------------------
# One recipe, one package.
#
# The rule the pkg/ layout exists to enforce. It was not always true:
# pkg/opkg/build.sh used to unpack zlib, libarchive and opkg and ship one
# binary, so two of the three libraries in this repo's dependency graph had no
# version, no package and no way to be reused -- which is why zlib was
# cross-built twice, once here and once in bin/patch.sh section 5c.

def _sh(snippet):
    """Run a snippet with bin/common.sh and pkg/lib.sh sourced, from ROOT."""
    out = subprocess.run(
        ["bash", "-c", ". bin/common.sh; . pkg/lib.sh; %s" % snippet],
        cwd=ROOT, capture_output=True, text=True)
    assert out.returncode == 0, (
        "shell helper failed:\n%s\n%s" % (out.stdout, out.stderr))
    return out.stdout.strip()


def _conf(recipe, var):
    return _sh('pkg_conf %s; printf "%%s" "$%s"' % (recipe, var))


@pytest.mark.parametrize("recipe", RECIPES,
                         ids=[p.parent.name for p in RECIPES])
def test_one_recipe_builds_one_package(recipe):
    """A recipe names one source and seals one tree.

    NOT "one package" -- one BUILD. A recipe may emit a second archive,
    <name>-dev, holding the headers and static library a printer has no use
    for; that is PKG_DEV_FILES and it is a partition of one build, checked by
    test_a_dev_split_partitions_the_build. What this test forbids is a recipe
    building several different upstream projects, which is what pkg/opkg did
    with zlib and libarchive until each became a recipe of its own.

    Counting the source verbs is the cheap structural expression of the rule:
    a recipe that unpacks two tarballs is building somebody else's package
    inside its own, which is exactly the shape this layout replaced. If a
    recipe genuinely needs a second source, that source is a package.

    THE COUNT IS OVER ALL SOURCE VERBS TOGETHER, not over pkg_unpack alone.
    There are two ways for a recipe to say where its inputs come from --
    pkg_unpack for a pinned download, pkg_intree for the files in this
    checkout -- and counting only the first would let a recipe use the second
    to acquire a source the rule was meant to count. One of either, never one
    of each.
    """
    body = "\n".join(ln for ln in recipe.read_text().splitlines()
                     if not ln.lstrip().startswith("#"))
    for verb, want in (("pkg_begin", 1), ("pkg_end", 1)):
        got = len(re.findall(r"^\s*%s\b" % verb, body, re.M))
        assert got == want, (
            "%s calls %s %d time(s), expected %d -- one recipe builds one "
            "package" % (recipe, verb, got, want))
    sources = len(re.findall(r"^\s*(?:pkg_unpack|pkg_intree)\b", body, re.M))
    assert sources == 1, (
        "%s names its source %d time(s), expected exactly 1 -- a recipe "
        "unpacks one pinned archive (pkg_unpack) or builds from this checkout "
        "(pkg_intree), never both and never twice" % (recipe, sources))
    assert "pkg_dep_autotools" not in body, (
        "%s uses pkg_dep_autotools, which built a dependency inside the "
        "recipe that needed it. Make it a package and name it in "
        "PKG_BUILD_DEPENDS." % recipe)


def test_an_arch_all_package_has_no_native_code():
    """Architecture: all is a promise, and it is cheap to check.

    Three packages claim it -- anvil-mainsail, anvil-moonraker and anvil-core
    -- on the grounds that they are JavaScript, Python and shell. The claim
    matters because pkg/ipk-install accepts `all` on any printer without
    consulting the ABI, so an ELF object that slipped into one of them would
    be the one path into $MODDIR that nothing checks. mips_abi_gate passes a
    tree with no ELF in it by returning zero, which is correct and is also
    why it cannot be the thing that catches this.

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
            "pkg/%s declares Architecture: all and its tree contains ELF "
            "objects: %s. An `all` package installs on any printer without an "
            "architecture check." % (recipe, ", ".join(sorted(elves)[:5])))


def test_a_dev_split_partitions_the_build():
    """PKG_DEV_FILES moves files; it never copies them.

    A path in both the runtime and the dev package is a path two packages
    own. opkg resolves that by letting whichever installed last win, and
    `ipk-install remove` on either one deletes a file the other still lists --
    so the damage shows up as a missing file long after the install that
    caused it. The split is a partition, and this is what says so.

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

    Alphabetical order -- what iterating pkg/*/ gives you, and what this used
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


def test_a_build_dependency_is_not_a_runtime_dependency():
    """PKG_BUILD_DEPENDS must never reach the control file.

    zlib and libarchive are linked INTO opkg. A package that also declared them
    as Depends would refuse to install unless two development packages were on
    the printer, for libraries already inside the file being installed.
    """
    build = (ROOT / "bin" / "build-packages.sh").read_text()
    body = "\n".join(ln for ln in build.splitlines()
                     if not ln.lstrip().startswith("#"))

    # The property, not a spelling. Depends is written once, from a value the
    # caller passes -- PKG_DEPENDS for a runtime package, the runtime package's
    # own name for its -dev half. What matters is that PKG_BUILD_DEPENDS is not
    # among the things that can reach it.
    assert "Depends: %s" in body, (
        "bin/build-packages.sh no longer writes a Depends field at all")
    assert '"$PKG_DEPENDS"' in body, (
        "bin/build-packages.sh no longer passes PKG_DEPENDS into the control "
        "file -- a package's declared runtime dependencies have stopped "
        "reaching opkg")
    assert "PKG_BUILD_DEPENDS" not in body, (
        "bin/build-packages.sh reads PKG_BUILD_DEPENDS while writing the "
        "package; build dependencies are pkg_deps' business, not opkg's")


def test_a_dev_package_ships_what_its_dependents_need():
    """A library that exists to be built against ships headers, .a and .pc.

    This is what makes building against the PACKAGE rather than against the
    build tree worth the extra step: a package that forgot a header fails the
    next recipe's configure. Asserted on the ship list so it is checked without
    a toolchain, on a bare checkout, in CI.
    """
    zlib = (ROOT / "pkg" / "zlib" / "build.sh").read_text()
    for want in ("include/zlib.h", "lib/libz.a", "lib/pkgconfig/zlib.pc"):
        assert want in zlib, "pkg/zlib does not ship %s" % want
    arch = (ROOT / "pkg" / "libarchive" / "build.sh").read_text()
    for want in ("include/archive.h", "lib/libarchive.a",
                 "lib/pkgconfig/libarchive.pc"):
        assert want in arch, "pkg/libarchive does not ship %s" % want

    # skalibs is the interesting one, and the reason this test is not just
    # "headers and an archive". lib/skalibs is a directory of CROSS-COMPILE
    # ANSWERS ABOUT THE LIBC -- does this target have /dev/urandom, does
    # posix_spawn return early -- that skalibs would normally settle by
    # compiling and running a probe, which a cross-build cannot do. execline,
    # s6 and s6-rc all read it through --with-sysdeps and refuse to configure
    # without it, naming a missing FILE rather than a missing flag. It is not a
    # header, not an archive and not a .pc, so a rule written around those
    # three would have let it be dropped.
    ska = (ROOT / "pkg" / "skalibs" / "build.sh").read_text()
    for want in ("include/skalibs", "lib/libskarnet.a", "lib/skalibs"):
        assert want in ska, "pkg/skalibs does not ship %s" % want


def test_dependencies_are_unpacked_by_upstream():
    """opkg-unbuild fills the sysroot -- we do not open .ipk files by hand.

    Same argument as opkg-build for making them: the format is somebody else's
    and the pinned checkout already carries the tool for reading it. It is also
    what makes opkg an ordinary recipe rather than a bootstrap stage, since
    nothing needs a working opkg in order to build packages.
    """
    lib = (ROOT / "pkg" / "lib.sh").read_text()
    assert "OPKG_UNBUILD_BIN" in lib, (
        "pkg/lib.sh no longer uses opkg-unbuild to fill a build sysroot")
    assert (OPKG_UTILS / "opkg-unbuild").is_file(), (
        "vendor/opkg-utils has no opkg-unbuild -- check the pinned commit")
    body = "\n".join(ln for ln in lib.splitlines()
                     if not ln.lstrip().startswith("#"))
    assert "ar x" not in body and "debian-binary" not in body, (
        "pkg/lib.sh is taking .ipk files apart itself again")


def test_the_abi_gate_reads_every_member_of_an_archive():
    """A static archive is many ELF headers, and all of them are checked.

    readelf -h on a .a prints one header per MEMBER -- 122 for this repo's
    libarchive.a. The gate used to read a single `Flags:` line, so it handed a
    multi-line string to a comparison expecting one word and every archive
    failed with an unreadable error. Nothing caught it because no package had
    ever shipped a .a until pkg/zlib did.

    Built here rather than mocked: a two-member x86 archive must be REFUSED
    (wrong ABI) and the refusal must say it looked at both members, which is
    the part that proves per-member iteration.
    """
    for tool in ("gcc", "ar"):
        assert shutil.which(tool), (
            "%s is missing, so this gate cannot run -- it must not be skipped"
            % tool)
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        objs = []
        for i in (1, 2):
            src = td / ("m%d.c" % i)
            src.write_text("int m%d(void){return %d;}\n" % (i, i))
            obj = td / ("m%d.o" % i)
            subprocess.run(["gcc", "-c", str(src), "-o", str(obj)], check=True)
            objs.append(str(obj))
        lib = td / "lib" / "libhost.a"
        lib.parent.mkdir()
        subprocess.run(["ar", "rcs", str(lib)] + objs, check=True)

        out = subprocess.run(
            ["bash", "-c",
             ". bin/common.sh; mips_abi_gate '%s'" % lib.parent],
            cwd=ROOT, capture_output=True, text=True)
        assert out.returncode != 0, (
            "mips_abi_gate accepted an x86-64 archive:\n%s" % out.stdout)
        assert "of 2 ELF header(s)" in out.stderr, (
            "mips_abi_gate did not report per-member counts, so it is not "
            "looking inside the archive:\n%s" % out.stderr)


def test_no_cache_stamp_is_spelled_in_two_places():
    """A stamp compared by one file and written by another must be defined once.

    This is not hypothetical tidiness. bin/fetch-assets.sh compared
    work/.s6/.version against "$SKALIBS_VERSION $S6_VERSION" while bin/patch.sh
    wrote three fields into it, so the test could never be false: a 71MB
    toolchain was re-fetched on every single run, and the comment above the
    condition described a fast path that had never once been taken. One
    definition is what makes that class of bug impossible rather than unlikely.
    """
    # The rule, not the variable. S6_STAMP itself is gone -- s6 is a recipe and
    # pkg_stamp computes its key -- so naming it here would test nothing. What
    # survives is the property it existed to guarantee, and the property has to
    # be stated over every stamp rather than over the one that broke.
    for var in ("S6_STAMP", "PY_STAMP"):
        spelled = sorted(p.name for p in (ROOT / "bin").glob("*.sh")
                         if '%s="' % var in p.read_text())
        assert spelled in ([], ["common.sh"]), (
            "%s is assigned in %s; a cache stamp is defined in bin/common.sh "
            "alone, or not at all once its build became a recipe"
            % (var, ", ".join(spelled)))

    # And the fields themselves, because moving the definition is only half of
    # it: a file that re-derives the same string under another name has
    # reintroduced the bug with the evidence removed. These are the two stamps
    # this repo has actually got wrong -- s6's three fields, and CPython's
    # eight, which were spelled in THREE places and happened to agree.
    for name in ("patch.sh", "fetch-assets.sh"):
        text = (ROOT / "bin" / name).read_text()
        assert '"$SKALIBS_VERSION $S6_VERSION' not in text, (
            "bin/%s spells the s6 stamp out by hand" % name)
        assert '"$PY_VERSION $OPENSSL_VERSION' not in text, (
            "bin/%s spells the CPython stamp out instead of using $PY_STAMP "
            "from bin/common.sh" % name)

    # The fetcher must ask the recipes rather than compare a string it wrote
    # itself. This is what makes the whole class impossible for anything under
    # pkg/: one implementation computes the key and one reads it.
    fetch = (ROOT / "bin" / "fetch-assets.sh").read_text()
    assert "pkg_needs" in fetch, (
        "bin/fetch-assets.sh no longer asks pkg_needs -- it is back to "
        "deciding whether a recipe is stale by a rule of its own")
