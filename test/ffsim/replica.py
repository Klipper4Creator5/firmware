"""Starting the printer replica and running a case script inside it.

The container is nearly empty Debian -- qemu-user-static, rsync, openssl,
dosfstools. It contributes no userland worth speaking of. The case script is
executed by the printer's OWN busybox, inside a chroot of the real extracted
rootfs.squashfs, with the MIPS binaries running under qemu. That is the whole
value of the thing: `uname -m` genuinely says mips and busybox applets behave
exactly as they do on the machine.

--privileged buys exactly two things: registering a binfmt handler for the
printer's binaries (the stock qemu-mipsel registration does not match them --
its mask requires e_ident[EI_ABIVERSION] to be 0 and every binary the Ingenic
toolchain built for this printer has 3 there), and building a mount layout
with a read-only root and writable prog/data partitions.

This module is the host half. entrypoint.sh, assemble.sh, binfmt.sh and the
case scripts are the container half and stay shell -- they run under the
printer's userland, where the only interpreter that matters is its ash.
"""
import os
import shutil
import subprocess
from pathlib import Path

from . import Fail, Skip


class Replica:
    """A configured docker + image pair, ready to run case scripts."""

    def __init__(self, config, image=None, prebuilt=None, docker=None):
        self.config = config
        self.root = config.root
        self.docker = docker
        self.image = image
        self.prebuilt = prebuilt

    # ---------------------------------------------------------------- setup

    @staticmethod
    def find_docker():
        """The docker CLI, or a Skip saying which half is missing.

        docker.exe is the WSL case: the daemon runs on the Windows side and
        the Linux binary may not be installed at all.
        """
        for name in ("docker", "docker.exe"):
            if shutil.which(name):
                return name
        raise Skip("docker not available")

    @classmethod
    def start(cls, config, want_output=None):
        """Resolve docker and the image, or raise Skip explaining what is absent."""
        docker = cls.find_docker()
        if subprocess.run([docker, "info"], capture_output=True).returncode != 0:
            raise Skip("docker daemon not running")

        image = config.get("PRINTER_IMAGE")
        if image:
            # A prebuilt image carries the firmware already -- rootfs,
            # /usr/prog, /usr/data, baked by build-printer-image.sh. Nothing
            # to mount and nothing to build.
            return cls(config, image=image, prebuilt=True, docker=docker)

        rootfs = config.root / "work" / "rootfs" / "bin"
        if not rootfs.is_dir():
            raise Skip("no printer rootfs -- run 'make rootfs' first (needs "
                       "the stock package), or set PRINTER_IMAGE to a "
                       "prebuilt printer image")

        # Say why this is about to be slow: unpacking the factory image is
        # ~22s and installing the stock baseline ~37s, on EVERY case. The
        # published image has both done and starts in under a second.
        if want_output:
            want_output(
                "printer-sim: PRINTER_IMAGE is not set, so the replica is "
                "being built locally -- about a minute of setup per test "
                "case. Set PRINTER_IMAGE=monstrofil/creator5-printer:latest "
                "in test.env to skip it.")

        image = "creator5-printer-sim"
        build_dir = config.root / "test" / "integration" / "printer"
        # Always rebuild: a cache hit takes about a second, and a stale image
        # silently testing yesterday's harness is not a trade worth making.
        built = subprocess.run(
            [docker, "build", "-q", "-t", image,
             "-f", str(build_dir / "Dockerfile"), str(build_dir)],
            capture_output=True, text=True)
        if built.returncode != 0:
            raise Fail("could not build %s:\n%s" % (image, built.stderr.strip()))
        return cls(config, image=image, prebuilt=False, docker=docker)

    # ------------------------------------------------------------ execution

    def command(self, case, packages=None, base_pkg=None, usb_stick=False,
                stage=None, want_out=False, env=None):
        """The exact `docker run` argv for this case.

        Split out from run() so it can be inspected and diffed against what
        the shell launcher produced, without a docker daemon anywhere near it.
        """
        packages = packages or {}
        stage = stage or self.stage_dir()
        config = self.config

        argv = [self.docker, "run", "--rm", "-i", "--privileged"]
        if not self.prebuilt:
            argv += ["-v", "%s/work/rootfs:/rootfs:ro" % self.root]

        # A case that has to hand something back gets an entrypoint of ours,
        # which runs the stock one and then mounts /out inside the chroot.
        # See test/integration/printer/entrypoint-out.sh for why that cannot
        # be a plain -v onto /printer/out.
        if want_out:
            wrapper = self.root / "test" / "integration" / "printer" / "entrypoint-out.sh"
            argv += [
                "--entrypoint", "/entrypoint-out.sh",
                "-v", "%s:/entrypoint-out.sh:ro" % wrapper,
                "-e", "OUT_UID=%d" % os.getuid(),
                "-e", "OUT_GID=%d" % os.getgid(),
            ]

        argv += [
            "-v", "%s/pkgs:/pkgs:ro" % stage,
            "-v", "%s/case.sh:/case.sh:ro" % stage,
            # ASSEMBLED ON THIS SIDE, and mounted as the one directory
            # every case script already reads. See stage_payload.
            "-v", "%s/payload:/payload:ro" % stage,
            # THE ONE WRITABLE MOUNT, and the only way anything the replica
            # built comes back. Everything else here is :ro on purpose -- a
            # case script must not be able to edit the checkout it is testing
            # -- but the payload build runs the printer's own opkg inside the
            # replica and has to hand the resulting tree back out.
            #
            # Under the stage dir because that is already inside the repo,
            # which is the one path a sibling container resolves to the same
            # place the daemon does. See stage_dir.
            "-v", "%s/out:/out" % stage,
            "-e", "FF_KEY=%s" % config.ff_key,
            "-e", "BASE_PKG=%s" % ("/pkgs/base.tgz" if base_pkg else ""),
            "-e", "PKGS=%s" % "".join(" %s=/pkgs/%s" % (n, n) for n in packages),
        ]

        # A real /usr/prog taken off a printer. Only for a locally built
        # replica: a prebuilt image already has one baked in, and mounting
        # over it would replace the genuine tree with an older copy.
        prog_dump = config.get("PROG_DUMP")
        if not self.prebuilt and prog_dump and os.path.exists(prog_dump):
            dump_abs = os.path.abspath(prog_dump)
            argv += ["-e", "PROG_DUMP=/progdump", "-v", "%s:/progdump:ro" % dump_abs]
        else:
            argv += ["-e", "PROG_DUMP="]

        # Anything the caller needs the case to see. Sorted so two runs of
        # one build produce the same argv, which is what makes `command`
        # worth diffing.
        for key in sorted(env or {}):
            argv += ["-e", "%s=%s" % (key, env[key])]

        argv += [
            "-e", "PROG_MB=%s" % config.get("PROG_MB"),
            "-e", "DATA_MB=%s" % config.get("DATA_MB"),
            "-e", "SIM_VERBOSE=%s" % os.environ.get("SIM_VERBOSE", "0"),
            "-e", "USB_STICK=%s" % ("1" if usb_stick else "0"),
            self.image, "/case.sh",
        ]
        return argv

    def stage_dir(self):
        """Where the inputs are staged.

        Inside the repo, always: the docker daemon resolves bind-mount paths
        on the HOST, and with sibling containers the repo is the one directory
        guaranteed to exist there under the same name -- a path under this
        container's /tmp does not. Per-process, so two suites running at once
        cannot delete each other's staged packages half way through a run.
        """
        return self.root / "work" / (".sim-%d" % os.getpid())

    def stage_payload(self, stage):
        """Assemble what /tmp/payload has always been, from the recipes.

        This was one mount of a top-level payload/ directory until 54a1e72
        moved those files in with the recipes that own them. qa/lib/replica.py
        was updated then and this harness was not, so every case reading
        /tmp/payload ran against an empty tree -- docker does not fail on a
        bind-mount source that does not exist, it creates an empty directory,
        which is why the repo kept growing a root-owned payload/ nobody wrote.

        ASSEMBLED HERE RATHER THAN IN entrypoint.sh, which is where
        qa/lib/replica.py leaves it. That works only when the image is current,
        and the published one (test.env's PRINTER_IMAGE) predates the split:
        its entrypoint.sh knows /payload and nothing else, so the seed and the
        Klipper launcher never arrive and case-moonraker.sh fails on an
        anvil.conf that was never copied. Doing it on this side needs nothing
        of the image but the mount it has always had.

        Four sources, four roles: anvil-core's $MODDIR overlay, its anvil.conf
        template -- the unrendered defaults are exactly what the cases want --
        Klipper's launcher, and the installer block, which is never a file on
        a printer at all (bin/patch.sh splices it into FlashForge's run.sh)
        but which case-upgrade.sh runs directly as the thing under test.

        THE LAUNCHER MOVED. start.sh was pkgs/klipper/prog/start.sh, a file in
        no package; it is anvil-core's payload/prog/start.sh now, so it also
        arrives via the copytree above -- but at prog/start.sh, and the cases
        read it flat. Hence the explicit copy, still. Note the `is_file`
        guard below: a source that moves and is not updated here vanishes
        SILENTLY, which is the same failure this docstring already describes
        once.
        """
        out = stage / "payload"
        shutil.copytree(str(self.root / "pkgs" / "anvil-core" / "payload"), str(out))
        for src, name in (
                (self.root / "pkgs" / "anvil-core" / "seed" / "anvil.conf.in",
                 "anvil.conf"),
                (self.root / "pkgs" / "anvil-core" / "payload" / "prog" / "start.sh",
                 "start.sh"),
                (self.root / "installer" / "run-append.sh",
                 "run-append.sh"),
        ):
            if src.is_file():
                shutil.copy(str(src), str(out / name))
        return out

    def run_case(self, case, packages=None, base_pkg=None, usb_stick=False,
                 on_output=None, out_dir=None, env=None):
        """Run one case script in the replica. Non-zero exit is a Fail.

        out_dir asks for a writable /out inside the chroot and copies what the
        case left there into that directory. Only on success: a failed build
        must not leave behind a payload that looks finished.
        """
        packages = packages or {}
        case = os.path.abspath(case)
        if not os.path.isfile(case):
            raise Fail("no case script at %s" % case)

        stage = self.stage_dir()
        if stage.exists():
            shutil.rmtree(str(stage))
        (stage / "pkgs").mkdir(parents=True)
        (stage / "out").mkdir()
        try:
            self.stage_payload(stage)
            shutil.copy(case, str(stage / "case.sh"))
            for name, path in packages.items():
                if not os.path.isfile(path):
                    raise Fail("no package at %s (for %s)" % (path, name))
                shutil.copy(path, str(stage / "pkgs" / name))
            if base_pkg:
                if not os.path.isfile(base_pkg):
                    raise Fail("no baseline package at %s" % base_pkg)
                shutil.copy(base_pkg, str(stage / "pkgs" / "base.tgz"))

            argv = self.command(case, packages, base_pkg, usb_stick, stage,
                                want_out=out_dir is not None, env=env)
            # errors="replace": a case that cats or heads one of the printer's
            # MIPS binaries emits bytes that are not UTF-8, and the default
            # strict decode raised UnicodeDecodeError out of communicate() --
            # so the harness itself failed, reporting nothing about the case.
            # A case is free to print whatever it likes; that is the case's
            # problem to fix, not a reason to lose the whole run's output.
            completed = subprocess.run(argv, capture_output=True, text=True,
                                       errors="replace")
            output = (completed.stdout or "") + (completed.stderr or "")
            if on_output and output.strip():
                on_output(output)
            if completed.returncode != 0:
                raise Fail("%s exited %d" % (os.path.basename(case),
                                             completed.returncode))
            if out_dir is not None:
                out_dir = Path(out_dir)
                out_dir.mkdir(parents=True, exist_ok=True)
                produced = sorted((stage / "out").iterdir())
                if not produced:
                    raise Fail("%s left nothing in /out"
                               % os.path.basename(case))
                for item in produced:
                    shutil.copy2(str(item), str(out_dir / item.name))
            return output
        finally:
            # The staged packages are ~80MB each.
            shutil.rmtree(str(stage), ignore_errors=True)
