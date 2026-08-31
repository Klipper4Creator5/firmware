"""The apk packager, and the things about it that only a built package answers.

Companion to test_packages.py, which asks the questions a format change does
not touch -- recipes, build order, the payload. This one asks the questions
the apk migration made possible, and the ones whose failure mode is silence.


WHAT IS AND IS NOT UNDER TEST. `apk mkpkg` is upstream's tool and upstream's
problem; these tests do not re-derive the format. They check what is OURS:
that the ownership recorded in a package is root and not whoever ran the
build, and that the thing calling itself the packager is a working apk.

IT NEEDS work/host/bin/apk, which bin/build-packages.sh builds on demand --
so `make packages` produces it, like every other build input. A missing one
FAILS rather than skips, for the reason qa/conftest.py gives about
shellcheck.
"""
import os
import pathlib
import subprocess

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

APK_BIN = ROOT / "work" / "host" / "bin" / "apk"

# Spelled out rather than read out of common.sh, for the reason test_packages.py
# gives: a test that derives its expectation from the thing under test cannot
# fail when the thing under test changes.
MODDIR = "/usr/data/anvil"
ARCH = "mipsel_xburst2"


@pytest.fixture(scope="session", autouse=True)
def apk_host_present():
    """A failure, not a skip -- see the module docstring and qa/conftest.py."""
    if not APK_BIN.is_file():
        pytest.fail(
            "work/host/bin/apk is missing, so nothing checked the packages we "
            "build. `make packages` builds it from the commit pinned in "
            "versions.env, on the way to building the feed.")


def test_the_host_packager_runs_and_is_the_pinned_version():
    """A packager that cannot report its own version is not a packager.

    Checked before anything leans on it, because the alternative failure lands
    three steps later as a feed nothing can read.
    """
    out = subprocess.run([str(APK_BIN), "--version"],
                         capture_output=True, text=True, check=True).stdout
    assert "apk-tools 3." in out, out

    versions = ROOT / "versions.env"
    pinned = None
    for line in versions.read_text().splitlines():
        if line.startswith("APK_TOOLS_VERSION="):
            pinned = line.split("=", 1)[1].strip().strip('"')
    assert pinned, "versions.env does not pin APK_TOOLS_VERSION"
    assert pinned in out, (
        "work/host/bin/apk reports %r but versions.env pins %s -- the packager "
        "and the printer's apk must be one version, or a package can be "
        "written in a format the machine cannot read" % (out.strip(), pinned))


def _recipes():
    return sorted(list((ROOT / "pkgs").glob("*/pkg.conf"))
                  + list((ROOT / "pkgs" / "3rdparty").glob("*/pkg.conf")))


def _conf(recipe, var):
    """One pkg.conf value, asked of the shell that defines it."""
    out = subprocess.run(
        ["bash", "-c",
         '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; '
         'pkg_conf "%s"; printf "%%s" "$%s"' % (recipe, var)],
        capture_output=True, text=True, cwd=str(ROOT))
    return out.stdout.strip()


@pytest.mark.parametrize("recipe", [p.parent.name for p in _recipes()])
def test_every_version_is_one_apk_can_parse(recipe):
    """apk's version grammar is narrower than opkg's, and silently so.

    `apk_version_validate` (src/version.c) accepts
    number{.number}{letter}{_suffix}{~hash}{-r#} and nothing else. Three
    recipes here shipped versions outside it -- two spelled a commit
    `+git<sha>` where the grammar's hash slot is `~`, and x264 carried a
    snapshot name whose `-2245` would be read as a malformed release. All
    three were valid opkg versions, which is exactly why they survived.

    Asked of pkg_conf rather than by reading the file, because most of these
    versions are shell expansions of a pin in versions.env.
    """
    version = _conf(recipe, "PKG_VERSION")
    release = _conf(recipe, "PKG_RELEASE")
    assert version, "%s sets no PKG_VERSION" % recipe

    full = subprocess.run(
        ["bash", "-c",
         '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; '
         'pkg_fullversion "%s" "%s"' % (version, release)],
        capture_output=True, text=True, cwd=str(ROOT)).stdout.strip()

    ok = subprocess.run(
        ["bash", "-c",
         '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; '
         'pkg_version_ok "%s"' % full],
        cwd=str(ROOT))
    assert ok.returncode == 0, (
        "%s's version %r is not one apk can parse. The grammar is "
        "number{.number}{letter}{_suffix}{~hash}{-r#}: use `~<sha>` for a "
        "commit, never `+git<sha>`, and no bare `-` inside the version."
        % (recipe, full))


def test_the_feed_holds_every_package_the_recipes_name():
    """The emitter and the prune step must spell a filename the same way.

    They did not. The `all` -> `noarch` mapping went into the emitter alone,
    so the prune -- which builds its expected set from pkg_pkgfile -- went
    looking for `_all.ipk`, did not find it, and deleted seventeen packages
    the same run had just built. `make packages` exited 0.

    Nothing else asks this: the payload-roots test checks names against
    recipes, and the recipes were right. What was wrong was the FILE, and the
    only way to catch that is to look for it.

    Returns rather than skips on a bare checkout, the way test_packages.py's
    payload questions do -- qa/conftest.py records that exception.
    """
    feed = ROOT / "work" / "packages"
    if not feed.is_dir() or not any(feed.iterdir()):
        return

    listed = subprocess.run(
        ["bash", "-c",
         '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; pkg_recipes'],
        capture_output=True, text=True, cwd=str(ROOT)).stdout.split()

    missing = []
    for recipe in listed:
        for variant in ("", "dev"):
            path = subprocess.run(
                ["bash", "-c",
                 '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; '
                 'pkg_pkgfile "%s" "%s"' % (recipe, variant)],
                capture_output=True, text=True, cwd=str(ROOT)).stdout.strip()
            # A recipe need not produce both halves; what it must not do is
            # produce a file under a name nothing else can find. So this only
            # catches a recipe with NEITHER, which is what the bug looked like.
            if variant == "" and not pathlib.Path(path).is_file():
                sibling = list(feed.glob(recipe.split("/")[-1] + "*"))
                if not sibling:
                    continue      # PKG_WHEN gated it out of the build entirely
                missing.append((recipe, pathlib.Path(path).name,
                                sorted(p.name for p in sibling)))

    assert not missing, (
        "the feed holds files these recipes' pkg_pkgfile cannot name:\n  " +
        "\n  ".join("%s: expected %s, found %s" % m for m in missing))


# ------------------------------------------------------- the assembled payload

def _payload():
    """The installed tree, or nothing to say.

    Returns rather than skips on a bare checkout, the way test_packages.py's
    payload questions do -- qa/conftest.py records that exception.
    """
    p = ROOT / "work" / "modpayload-root" / "usr" / "data" / "anvil"
    return p if (p / "lib" / "apk" / "db" / "installed").is_file() else None


def _installed_db(payload):
    return (payload / "lib" / "apk" / "db" / "installed").read_text()


def test_every_payload_file_is_owned_by_a_package():
    """Everything in the payload came from a package, or is on this list.

    Checked against apk's own record of what it installed. That record is
    PLAIN TEXT, not the ADB the package and index use: `F:<dir>` sets the
    current directory and each following `R:<name>` is a file in it. So this
    reads one file where the opkg version globbed var/lib/opkg/info/*.list,
    and is the shorter of the two.

    The interesting output is not the pass but the allowlist: the files that
    are in the payload and in no package. It should shrink and must not grow
    by accident.
    """
    payload = _payload()
    if payload is None:
        return

    # The paths are relative to the INSTALL ROOT, not to $MODDIR -- `F:usr`,
    # `F:usr/data`, `F:usr/data/anvil`, and so on down. That is the whole
    # point of the split this migration rests on: the database lives under
    # $MODDIR but the files it records land at /, so it names them from /.
    owned, cwd = set(), ""
    for line in _installed_db(payload).splitlines():
        if line.startswith("F:"):
            cwd = line[2:]
            owned.add("/" + cwd)
        elif line.startswith("R:"):
            owned.add("/" + (cwd + "/" if cwd else "") + line[2:])
    assert owned, "the apk database lists no files at all"

    allowed = {
        # User state: created once and never overwritten. A package member is
        # overwritten on every upgrade by definition, which is exactly what
        # this must not be.
        MODDIR + "/config/moonraker-custom.conf",
    }

    extra = []
    for dirpath, dirnames, filenames in os.walk(payload):
        for name in list(dirnames) + list(filenames):
            p = pathlib.Path(dirpath, name)
            rel = MODDIR + "/" + str(p.relative_to(payload))
            if rel in owned or rel in allowed:
                continue
            # The database itself: written by apk while installing, so it can
            # never appear in a list it is still being written into.
            if rel.startswith(MODDIR + "/lib/apk") or rel.startswith(MODDIR + "/etc/apk"):
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


def test_the_payload_is_dependency_closed():
    """Every package in the payload has its declared dependencies beside it.

    THE TEST THAT WAS MISSING. Depends was briefly emitted whitespace-
    separated for both formats, and opkg's pkg_parse.c splits that field on
    ',' and nothing else -- so the whole list became one dependency whose name
    contained spaces, resolved to nothing, and nineteen packages silently
    stopped being installed. `make build` exited 0 and shipped a payload with
    no Tornado in it.

    Nothing else asked this. The roots test checks names against recipes and
    the recipes were right; the ownership test walks the payload and asks
    where each file came from, which cannot notice a file that is absent. The
    only way to catch it is to ask the database for the closure it claims.

    Reads the `D:` records apk writes, so it is a question about what was
    INSTALLED rather than about what the recipes say.
    """
    payload = _payload()
    if payload is None:
        return

    installed, deps, current = set(), {}, None
    for line in _installed_db(payload).splitlines():
        if line.startswith("P:"):
            current = line[2:]
            installed.add(current)
        elif line.startswith("D:") and current:
            deps[current] = line[2:].split()
    assert installed, "the apk database names no packages at all"

    missing = []
    for pkg, wanted in deps.items():
        for dep in wanted:
            # `!name` is a conflict, not a requirement; a versioned or
            # provider dependency is satisfied by something else's provides,
            # which apk resolved when it installed -- so only bare names that
            # name no installed package are interesting here.
            if dep.startswith("!"):
                continue
            name = dep.split("=")[0].split("<")[0].split(">")[0].split("~")[0]
            if name and name.startswith("anvil-") and name not in installed:
                missing.append("%s needs %s" % (pkg, name))

    assert not missing, (
        "%d declared dependency/ies are not installed in the payload:\n  %s\n"
        "The package manager resolved the roots and did not bring these along, "
        "which usually means the dependency FIELD was written in a spelling it "
        "does not parse rather than that a package is missing from the feed."
        % (len(missing), "\n  ".join(sorted(missing)[:20])))


def test_the_payload_database_has_no_clock_in_it():
    """Two builds of one commit must not differ, and here they cannot.

    The opkg version of this test asserted that `Installed-Time` held exactly
    ONE distinct value, because case-build-payload.sh had to sed every record
    to make that true -- opkg takes the field from time() and ignores
    SOURCE_DATE_EPOCH.

    apk needs no such normalisation: it records no install time at all, and
    mkpkg sets no build-time, so the database carries no `t:` line. This
    asserts the absence, which is the stronger claim -- clock-free by
    construction rather than by repair. If a `t:` ever appears, either apk
    changed or something started setting build-time, and the payload stopped
    being reproducible without anyone noticing.
    """
    payload = _payload()
    if payload is None:
        return

    clocked = [l for l in _installed_db(payload).splitlines() if l.startswith("t:")]
    assert not clocked, (
        "the installed database carries %d build-time field(s): %s\n"
        "That is a wall clock in a shipped file, and two builds of one commit "
        "will differ. Either stop setting build-time in bin/build-packages.sh, "
        "or normalise it in case-build-payload.sh the way the opkg path had to."
        % (len(clocked), clocked[:3]))


def _idmap(tmp_path):
    """The synthetic root that makes mkpkg call the build user 'root'.

    The mechanism the packager depends on, built here the same way
    bin/build-packages.sh builds it -- so this test fails if that idea stops
    working, not merely if the script stops calling it.
    """
    etc = tmp_path / "idmap" / "etc"
    etc.mkdir(parents=True)
    (etc / "passwd").write_text("root:x:%d:%d:::\n" % (os.getuid(), os.getgid()))
    (etc / "group").write_text("root:x:%d:\n" % os.getgid())
    return tmp_path / "idmap"


def _stage(tmp_path):
    d = tmp_path / "stage" / MODDIR.lstrip("/") / "share" / "probe"
    d.mkdir(parents=True)
    (d / "f.txt").write_text("owned by root, whoever built it\n")
    return tmp_path / "stage"


def _acl_users(apk_file):
    """Every `user:`/`group:` value the package records, as a set."""
    out = subprocess.run([str(APK_BIN), "adbdump", str(apk_file)],
                         capture_output=True, text=True, check=True).stdout
    names = set()
    for line in out.splitlines():
        line = line.strip()
        for key in ("user:", "group:"):
            if line.startswith(key):
                names.add(line[len(key):].strip())
    return names


def test_a_package_is_owned_by_root_whoever_built_it(tmp_path):
    """The silent one, and the reason `--root` is passed to every mkpkg.

    apk records ownership BY NAME, resolved against <--root>/etc/passwd
    (src/io.c, apk_id_cache_resolve_user). The build lane runs `--user
    $(id -u)` with no passwd entry (Makefile, DOCKER_USER), so left alone
    every file in every package is recorded `nobody` -- measured -- and
    installs on the printer as uid 65534. Nothing errors, at build or at
    install.

    It is not only metadata: mkpkg's empty-directory prune fires only for
    root:root 0755, so the wrong owner changes the SET OF ENTRIES too, and two
    developers with different uids would produce different packages.
    """
    stage = _stage(tmp_path)
    out = tmp_path / "probe-1.0-r1.apk"
    subprocess.run(
        [str(APK_BIN), "--root", str(_idmap(tmp_path)), "mkpkg", "--no-xattrs",
         "-I", "name:probe", "-I", "version:1.0-r1", "-I", "arch:" + ARCH,
         "-I", "description:ownership probe",
         "-F", str(stage), "-o", str(out)],
        check=True, capture_output=True)

    names = _acl_users(out)
    assert names == {"root"}, (
        "a package built as uid %d records ownership %s -- it must record only "
        "'root'. bin/build-packages.sh passes --root at a synthetic passwd "
        "naming the build user root; that is what this checks still works."
        % (os.getuid(), sorted(names)))


def test_without_the_id_map_the_owner_is_not_root(tmp_path):
    """The inverse, so the test above cannot pass for the wrong reason.

    If upstream ever started recording uid 0 regardless, the test above would
    go green while the mechanism it names had stopped mattering. This asserts
    the hazard is real on THIS machine.
    """
    stage = _stage(tmp_path)
    out = tmp_path / "bare-1.0-r1.apk"
    subprocess.run(
        [str(APK_BIN), "mkpkg", "--no-xattrs",
         "-I", "name:bare", "-I", "version:1.0-r1", "-I", "arch:" + ARCH,
         "-I", "description:ownership probe, unmapped",
         "-F", str(stage), "-o", str(out)],
        check=True, capture_output=True)

    if os.getuid() == 0:
        pytest.skip("running as root, where the id map is a no-op by design")
    assert _acl_users(out) != {"root"}, (
        "mkpkg recorded root without the id map, so the --root argument "
        "bin/build-packages.sh passes is no longer buying anything. Check "
        "whether upstream changed the ownership rules before deleting it.")



def _recipes_built(key=None):
    """The recipes a build would actually make, asked with a given key.

    Not the pkg.conf glob: pkg_recipes drops anything whose PKG_WHEN is false,
    such as pkgs/3rdparty/busybox on any build with no stock firmware to take
    a busybox out of. That set is what the stability check below is about.
    """
    env = dict(os.environ)
    env.pop("APK_SIGN_KEY", None)
    if key:
        env["APK_SIGN_KEY"] = key
    out = subprocess.run(
        ["bash", "-c",
         '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; pkg_recipes'],
        capture_output=True, text=True, cwd=str(ROOT), env=env)
    return sorted(out.stdout.split())


@pytest.mark.parametrize("recipe", [p.parent.name for p in _recipes()])
@pytest.mark.parametrize("key", ["", "/nonexistent/anvil.rsa"])
def test_a_recipe_reads_with_no_signing_key(recipe, key):
    """A bare checkout has no signing key, and that is the CI case.

    bin/build-packages.sh runs under `set -euo pipefail` and sources every
    pkg.conf inside it, so a substitution that FAILS in a recipe kills the
    whole run -- before a single package is emitted, and with nothing on
    stderr if the recipe redirected it. That is what
    `sha256sum "${APK_SIGN_KEY:-/dev/null}.pub" | cut` did in anvil-core: the
    missing file made sha256sum non-zero, pipefail made the pipeline
    non-zero, and `make packages` exited 1 having said only that it had
    sealed a cache entry. Every signed build passed, which is why it reached
    CI to be found.

    Both spellings of "no key" are covered: unset, and set to a path that is
    not there. The flags are the point -- _conf above runs without them and
    would have gone green throughout.

    EVERY recipe, not just the ones a build would make. A recipe PKG_WHEN
    switches off is still SOURCED to find that out, and pkg_recipes does it in
    a subshell that discards the result -- so one that cannot be read is
    dropped silently rather than reported. busybox did exactly that, printing
    "BUSYBOX_BIN: unbound variable" into every CI log directly above the first
    real failure.
    """
    env = dict(os.environ)
    env.pop("APK_SIGN_KEY", None)
    if key:
        env["APK_SIGN_KEY"] = key

    out = subprocess.run(
        ["bash", "-c",
         'set -euo pipefail; . ./bin/common.sh >/dev/null 2>&1; '
         '. ./pkgs/lib.sh; pkg_conf "%s"' % recipe],
        capture_output=True, text=True, cwd=str(ROOT), env=env)
    assert out.returncode == 0, (
        "%s cannot be read with APK_SIGN_KEY=%r -- `make packages` on a "
        "checkout with no key dies here, and the failure is silent.\n%s"
        % (recipe, key, out.stderr))


def test_the_signing_key_does_not_change_which_recipes_exist():
    """A recipe that cannot be read DISAPPEARS instead of failing.

    pkg_recipes evaluates PKG_WHEN in a subshell and drops the recipe when it
    returns non-zero (pkgs/lib.sh) -- which it also does when sourcing the
    pkg.conf failed. So a recipe broken only in the unsigned case would not
    make CI red; it would quietly leave the feed, and the printer would get a
    payload missing a package nobody noticed was gone.

    The feed is signed on a release and unsigned in CI, so the two have to
    describe the same set of packages.
    """
    unsigned = _recipes_built()
    signed = _recipes_built("/nonexistent/anvil.rsa")
    assert unsigned == signed, (
        "the recipe list changes with APK_SIGN_KEY: %r appear only unsigned, "
        "%r only signed"
        % (sorted(set(unsigned) - set(signed)),
           sorted(set(signed) - set(unsigned))))


def test_the_build_container_can_see_a_key_outside_the_checkout(tmp_path):
    """The documented place for the key is OUTSIDE this repo, and the build
    runs in a container that mounts only the repo.

    config.env is read inside the container, so make never learns the path
    unless the Makefile reads it too -- and without that the mount is absent
    and `apk mkpkg --sign-key` fails on a file the developer can see in their
    own shell. Missed by everything until now because the key used while the
    migration was written happened to sit under work/, which is inside the one
    directory that was already mounted.

    Asked of `make -n`, which needs no docker: the question is only what the
    command line would be.
    """
    key = tmp_path / "keys" / "anvil.rsa"
    key.parent.mkdir()
    key.write_text("not a key, only a path that exists")

    cfg = tmp_path / "config.env"
    cfg.write_text('MOD_NAME=anvil\nAPK_SIGN_KEY="%s"\n' % key)

    env = dict(os.environ)
    env.pop("APK_SIGN_KEY", None)
    env["CONFIG_ENV"] = str(cfg)
    out = subprocess.run(["make", "-n", "packages"],
                         capture_output=True, text=True, cwd=str(ROOT), env=env)
    mount = '-v "%s":"%s":ro' % (key.parent, key.parent)
    assert mount in out.stdout, (
        "`make packages` would run docker without mounting %s, so the signing "
        "key named by config.env is not visible to apk inside the container.\n"
        "%s" % (key.parent, out.stdout[-2000:]))


def test_no_key_mounts_nothing():
    """The inverse: an unsigned build must not mount a stray directory.

    `$(dir )` of an empty path is `./`, so a careless spelling of the rule
    above would bind-mount something read-only into every unsigned build and
    the failure would surface as an unrelated permission error.
    """
    env = dict(os.environ)
    env.pop("APK_SIGN_KEY", None)
    env["CONFIG_ENV"] = str(ROOT / "config.env.example")
    out = subprocess.run(["make", "-n", "packages"],
                         capture_output=True, text=True, cwd=str(ROOT), env=env)
    assert '":ro' not in out.stdout, (
        "an unsigned build mounts something read-only that it should not:\n%s"
        % out.stdout[-2000:])


def _workflow_mod_vers():
    """Every MOD_VER a workflow writes into config.env, with its source."""
    found = []
    for wf in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        for n, line in enumerate(wf.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("MOD_VER="):
                found.append((wf.name, n, stripped.split("=", 1)[1].strip()))
    return found


def test_every_workflow_version_is_one_apk_can_parse():
    """anvil-core's version is MOD_VER, and CI sets it.

    test_every_version_is_one_apk_can_parse asks the RECIPES, and anvil-core
    answers with whatever config.env happens to say on the machine running the
    test -- a date, locally, which is always valid. It cannot see that ci.yml
    writes `MOD_VER=ci`, which apk rejects: a version has to start with a
    digit. So `make packages` was green on every developer machine and red on
    every CI run, and mkpkg's message named neither the package nor the field's
    value.

    A value that is empty or a shell expansion is skipped: bin/common.sh
    stamps today's UTC date for the first, and the second is release.yml
    deriving the version from the tag, which has its own gate in the tag
    format.
    """
    bad = []
    for wf, line, raw in _workflow_mod_vers():
        value = raw.strip('"').strip("'")
        if not value or "$" in value:
            continue
        full = subprocess.run(
            ["bash", "-c",
             '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; '
             'pkg_fullversion "%s" 1' % value],
            capture_output=True, text=True, cwd=str(ROOT)).stdout.strip()
        ok = subprocess.run(
            ["bash", "-c",
             '. ./bin/common.sh >/dev/null 2>&1; . ./pkgs/lib.sh; '
             'pkg_version_ok "%s"' % full],
            cwd=str(ROOT), capture_output=True)
        if ok.returncode != 0:
            bad.append("%s:%s sets MOD_VER=%s -> %s" % (wf, line, raw, full))

    assert not bad, (
        "a workflow pins a MOD_VER apk cannot parse, so `make packages` fails "
        "there and nowhere else. A version must start with a digit:\n  %s"
        % "\n  ".join(bad))


def test_a_workflow_actually_pins_a_version():
    """The test above passes trivially if nothing sets MOD_VER at all.

    CI pins it so two runs of one tree produce the same bytes; if that line is
    ever dropped, the date default makes the reproducibility gate depend on
    what day it is, and the check above would go quiet rather than red.
    """
    pinned = [f for f in _workflow_mod_vers()
              if f[2] and "$" not in f[2]]
    assert pinned, (
        "no workflow pins MOD_VER any more, so the version check above is "
        "asserting nothing and CI builds are dated rather than reproducible")
