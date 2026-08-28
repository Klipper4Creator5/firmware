"""The .ipk builder and the installer that reads what it writes.

WHY THESE ARE STATIC TESTS AND NOT REPLICA ONES. Every test here builds its own
package out of a synthetic tree -- three files and two symlinks, no compiler,
no toolchain, no firmware image -- so the lane keeps the property qa/conftest.py
insists on: it needs nothing but the checkout, and it can therefore never be
quietly skipped into looking green. The real libsodium package needs a 200MB
cross-toolchain and thirty seconds of gcc; that belongs to `make packages`,
which is a build target, not a gate.

What is left to prove here is everything that is actually about PACKAGING:
that the archive has the shape opkg reads, that two builds of the same tree
produce the same bytes, that installing and removing a package is a round trip,
and that a package built for somebody else's mips cannot be installed by
accident. The format itself was verified against real opkg 0.6.3 -- install,
list, files, remove -- and docs/notes/85-packaging.md records that run.
"""
import gzip
import hashlib
import io
import os
import shutil
import subprocess
import tarfile

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

MKIPK = ROOT / "bin" / "mkipk.sh"
INSTALLER = ROOT / "pkg" / "ipk-install"

# The prefix every package this repo builds installs into, and the one
# pkg/ipk-install hardcodes. Spelled out rather than read out of common.sh
# because a test that derives its expectation from the thing under test cannot
# fail when the thing under test changes.
MODDIR = "/usr/data/anvil"
ARCH = "mipsel_xburst2"


# ------------------------------------------------------------------ fixtures

def _tree(tmp_path):
    """A staged tree shaped like a real one: a file, its soname link, junk.

    The symlinks are the part that matters. libsodium ships
    libsodium.so -> .so.26 -> .so.26.2.0 and the first of those is the name
    libnacl's dlopen fallback constructs, so a packager that dereferenced them
    would ship three copies of the same 400KB object and still work -- until
    somebody noticed the payload had tripled. Every test that walks the archive
    is really asking about these two entries.
    """
    root = tmp_path / "stage"
    (root / "lib").mkdir(parents=True)
    (root / "lib" / "libtest.so.1.2.3").write_bytes(b"\x7fELF" + b"payload" * 64)
    (root / "lib" / "libtest.so.1").symlink_to("libtest.so.1.2.3")
    (root / "lib" / "libtest.so").symlink_to("libtest.so.1.2.3")
    # The build stamp pkg/libsodium/build.sh leaves behind. It is a build
    # artefact and PKG_EXCLUDE exists to keep it out of the package.
    (root / ".version").write_text("1.2.3\n")
    return root


def _build(root, outdir, name="libtest", version="1.2.3", release="1",
           arch=ARCH, prefix=MODDIR, excludes=(".version",), extra=()):
    cmd = [str(MKIPK),
           "--name", name, "--version", version, "--release", release,
           "--arch", arch, "--prefix", prefix,
           "--root", str(root), "--outdir", str(outdir),
           "--description", "a test package"]
    for e in excludes:
        cmd += ["--exclude", e]
    cmd += list(extra)
    done = subprocess.run(cmd, capture_output=True, text=True, cwd=str(ROOT))
    assert done.returncode == 0, done.stderr.strip()
    return done.stdout.strip()


@pytest.fixture
def ipk(tmp_path):
    out = tmp_path / "packages"
    return _build(_tree(tmp_path), out)


# --------------------------------------------------------- ar member handling

def _ar_members(path):
    """(name, bytes) per member, walking the 60-byte ASCII headers.

    Written out here rather than shelled out to `ar t` because pkg/ipk-install
    walks the same headers by hand -- the printer's busybox has no ar applet to
    bet on -- and a test that used the real ar would not notice if the two
    disagreed about where a member starts.
    """
    raw = path.read_bytes() if hasattr(path, "read_bytes") else open(path, "rb").read()
    assert raw[:8] == b"!<arch>\n", "not an ar archive"
    off, out = 8, []
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode().strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        data = raw[off + 60:off + 60 + size]
        out.append((name, data))
        off += 60 + size + (size % 2)
    return out


def test_member_order_is_the_format(ipk):
    """debian-binary, control.tar.gz, data.tar.gz -- in that order.

    Not a convention. opkg reads the archive as a stream and gives up on a
    package whose control follows its data, so a builder that emitted them in
    alphabetical order would produce files that every structural test passes
    and no package manager installs.
    """
    assert [n for n, _ in _ar_members(ipk)] == \
        ["debian-binary", "control.tar.gz", "data.tar.gz"]


def test_debian_binary_declares_2_0(ipk):
    members = dict(_ar_members(ipk))
    assert members["debian-binary"] == b"2.0\n"


# ----------------------------------------------------------------- the control

def _control(path):
    members = dict(_ar_members(path))
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(members["control.tar.gz"]))) as t:
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
    # Version is upstream-release, and the release half is what lets a
    # repackage ship without lying about which upstream is inside.
    assert f["Version"] == "1.2.3-1"
    assert f["Architecture"] == ARCH
    assert int(f["Installed-Size"]) > 0


def test_description_is_the_last_field(ipk):
    """Because it is the only one that may continue onto further lines.

    A continuation line in a control file is one starting with whitespace, so a
    field written AFTER a multi-line Description would have to be unindented --
    and an unindented line in the feed index is where the next package's stanza
    begins. Putting Description last removes the question rather than
    documenting it.
    """
    keys = [ln.split(":", 1)[0] for ln in _control(ipk).splitlines()
            if ln and not ln[0].isspace()]
    assert keys[-1] == "Description"


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


def test_excluded_paths_do_not_ship(ipk):
    with _data(ipk) as t:
        assert not [m.name for m in t.getmembers()
                    if os.path.basename(m.name) == ".version"]


def test_an_empty_package_is_refused(tmp_path):
    """A recipe whose build produced nothing must not yield a valid package.

    It is the failure that explains itself least: the package installs, opkg
    reports success, and the library it was supposed to carry is simply absent
    at the point something dlopens it.
    """
    empty = tmp_path / "empty"
    empty.mkdir()
    done = subprocess.run(
        [str(MKIPK), "--name", "x", "--version", "1", "--arch", ARCH,
         "--prefix", MODDIR, "--root", str(empty), "--outdir", str(tmp_path),
         "--description", "d"],
        capture_output=True, text=True, cwd=str(ROOT))
    assert done.returncode != 0
    assert "empty package refused" in done.stderr


def test_a_relative_prefix_is_refused(tmp_path):
    done = subprocess.run(
        [str(MKIPK), "--name", "x", "--version", "1", "--arch", ARCH,
         "--prefix", "usr/data/anvil", "--root", str(_tree(tmp_path)),
         "--outdir", str(tmp_path), "--description", "d"],
        capture_output=True, text=True, cwd=str(ROOT))
    assert done.returncode != 0
    assert "must be absolute" in done.stderr


# ------------------------------------------------------------ reproducibility

def test_two_builds_of_one_tree_are_byte_identical(tmp_path):
    """The property the whole builder is arranged around.

    Without it there is no cheap way to prove that a pin bump changed what it
    said it changed: every rebuild differs, so every diff is noise. tar sorting
    its entries, gzip -n, and ar's deterministic mode are each load-bearing for
    this test and for nothing else -- which is why the test exists, because the
    comment saying so would rot the first time someone added a flag.
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
    cmd = ["sh", str(INSTALLER)] + list(args)
    if root is not None:
        cmd += ["--root", str(root)]
    return subprocess.run(cmd, capture_output=True, text=True, cwd=str(ROOT))


def test_install_then_remove_is_a_round_trip(tmp_path, ipk):
    """Everything the package brought, and nothing else, goes away again.

    This is the property payload/run-append.sh's install manifest exists to
    give the tarball, and the reason it exists there is written down in that
    file: the installer used to `rm -rf` seven whole directories, which is
    correct only while every file under them is ours. A package knows exactly
    what it owns, so it can be exact -- and this test is what says it is.
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

    listed = _run_installer("list", root=root)
    assert listed.stdout.strip() == "libtest - 1.2.3-1"


def test_the_database_is_where_opkg_looks_for_it(tmp_path, ipk):
    """$MODDIR/var/lib/opkg, with opkg's own file names.

    Phase 2 of docs/notes/85-packaging.md cross-builds the real opkg and points
    it at this directory; that is a swap only for as long as the layout is
    genuinely opkg's. It also has a trap in it worth keeping a test near: opkg
    bakes its lib directory in at COMPILE time, so the phase-2 build has to be
    configured --prefix=/usr/data/anvil or it will look somewhere else entirely
    and conclude that nothing is installed.
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
    out = tmp_path / "packages"
    foreign = _build(_tree(tmp_path), out, arch="mipsel_24kc")
    done = _run_installer("install", foreign, root=tmp_path / "root")
    assert done.returncode != 0
    assert "mipsel_24kc" in done.stderr and "mipsel_xburst2" in done.stderr


# ------------------------------------------------- the recipe and the payload

def test_the_package_and_the_payload_share_one_build():
    """The property the whole PoC rests on: libsodium is compiled once.

    bin/patch.sh stages $SODIUM_BUILD into the payload and pkg/libsodium
    packages $SODIUM_BUILD, and both get there by running
    pkg/libsodium/build.sh. While that is true the tarball's copy and the
    package's copy cannot be different libraries wearing one version number.
    It stops being true the moment somebody gives either side its own configure
    line, which is a one-line edit and would be invisible in review -- so it is
    asserted rather than trusted.
    """
    patch = (ROOT / "bin" / "patch.sh").read_text()
    conf = (ROOT / "pkg" / "libsodium" / "pkg.conf").read_text()
    assert "bash pkg/libsodium/build.sh" in patch, (
        "bin/patch.sh no longer runs the recipe -- the payload's libsodium and "
        "the packaged one are now built by different code")
    assert 'PKG_ROOT="$SODIUM_BUILD"' in conf
    assert '"$SODIUM_BUILD/lib/"libsodium.so*' in patch


def test_packages_are_abi_gated_before_they_ship():
    """bin/build-packages.sh runs mips_abi_gate over every recipe's tree.

    bin/patch.sh gates the staged payload, and that does not cover this: a
    package can be built by `make packages` on a machine that never runs
    patch.sh. An .ipk is a shipping vehicle and gets gated like one.
    """
    assert "mips_abi_gate" in (ROOT / "bin" / "build-packages.sh").read_text()
    assert "mips_abi_gate()" in (ROOT / "bin" / "common.sh").read_text()


def test_the_installer_needs_no_ar(tmp_path, ipk):
    """It walks the ar headers itself, because busybox here may have no ar.

    The printer's busybox is 1.31.1 built small -- no `timeout`, no `nc`, no
    `ionice`, all measured on the replica rather than assumed. Betting the
    installer on an applet nobody has checked for is how a firmware update
    fails at the last step. The test runs the installer with ar removed from
    PATH; if it ever grows an `ar` call this goes red.
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
        ["sh", str(INSTALLER), "install", ipk, "--root", str(tmp_path / "root")],
        capture_output=True, text=True, cwd=str(ROOT),
        env={"PATH": str(fake), "HOME": os.environ.get("HOME", "/tmp")})
    assert done.returncode == 0, done.stderr
