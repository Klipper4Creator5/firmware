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
        ctx = config.root / "test" / "integration" / "printer"
        # Always rebuild: a cache hit takes about a second, and a stale image
        # silently testing yesterday's harness is not a trade worth making.
        built = subprocess.run(
            [docker, "build", "-q", "-t", image,
             "-f", str(ctx / "Dockerfile"), str(ctx)],
            capture_output=True, text=True)
        if built.returncode != 0:
            raise Fail("could not build %s:\n%s" % (image, built.stderr.strip()))
        return cls(config, image=image, prebuilt=False, docker=docker)

    # ------------------------------------------------------------ execution

    def command(self, case, packages=None, base_pkg=None, usb_stick=False,
                stage=None):
        """The exact `docker run` argv for this case.

        Split out from run() so it can be inspected and diffed against what
        the shell launcher produced, without a docker daemon anywhere near it.
        """
        packages = packages or {}
        stage = stage or self.stage_dir()
        cfg = self.config

        argv = [self.docker, "run", "--rm", "-i", "--privileged"]
        if not self.prebuilt:
            argv += ["-v", "%s/work/rootfs:/rootfs:ro" % self.root]

        argv += [
            "-v", "%s/pkgs:/pkgs:ro" % stage,
            "-v", "%s/case.sh:/case.sh:ro" % stage,
            "-v", "%s/payload:/payload:ro" % self.root,
            "-e", "FF_KEY=%s" % cfg.ff_key,
            "-e", "BASE_PKG=%s" % ("/pkgs/base.tgz" if base_pkg else ""),
            "-e", "PKGS=%s" % "".join(" %s=/pkgs/%s" % (n, n) for n in packages),
        ]

        # A real /usr/prog taken off a printer. Only for a locally built
        # replica: a prebuilt image already has one baked in, and mounting
        # over it would replace the genuine tree with an older copy.
        dump = cfg.get("PROG_DUMP")
        if not self.prebuilt and dump and os.path.exists(dump):
            dump_abs = os.path.abspath(dump)
            argv += ["-e", "PROG_DUMP=/progdump", "-v", "%s:/progdump:ro" % dump_abs]
        else:
            argv += ["-e", "PROG_DUMP="]

        argv += [
            "-e", "PROG_MB=%s" % cfg.get("PROG_MB"),
            "-e", "DATA_MB=%s" % cfg.get("DATA_MB"),
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

    def run_case(self, case, packages=None, base_pkg=None, usb_stick=False,
                 on_output=None):
        """Run one case script in the replica. Non-zero exit is a Fail."""
        packages = packages or {}
        case = os.path.abspath(case)
        if not os.path.isfile(case):
            raise Fail("no case script at %s" % case)

        stage = self.stage_dir()
        if stage.exists():
            shutil.rmtree(str(stage))
        (stage / "pkgs").mkdir(parents=True)
        try:
            shutil.copy(case, str(stage / "case.sh"))
            for name, path in packages.items():
                if not os.path.isfile(path):
                    raise Fail("no package at %s (for %s)" % (path, name))
                shutil.copy(path, str(stage / "pkgs" / name))
            if base_pkg:
                if not os.path.isfile(base_pkg):
                    raise Fail("no baseline package at %s" % base_pkg)
                shutil.copy(base_pkg, str(stage / "pkgs" / "base.tgz"))

            argv = self.command(case, packages, base_pkg, usb_stick, stage)
            proc = subprocess.run(argv, capture_output=True, text=True)
            body = (proc.stdout or "") + (proc.stderr or "")
            if on_output and body.strip():
                on_output(body)
            if proc.returncode != 0:
                raise Fail("%s exited %d" % (os.path.basename(case),
                                             proc.returncode))
            return body
        finally:
            # The staged packages are ~80MB each.
            shutil.rmtree(str(stage), ignore_errors=True)
