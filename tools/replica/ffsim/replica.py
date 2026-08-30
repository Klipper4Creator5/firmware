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

    def __init__(self, config, image=None, docker=None):
        self.config = config
        self.root = config.root
        self.docker = docker
        self.image = image

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
    def start(cls, config):
        """Resolve docker and the image, or raise Skip explaining what is absent."""
        # There is no want_output parameter any more. The only thing this ever
        # said was that building a replica locally from work/rootfs would cost
        # about a minute per case, and there is no local build left to warn
        # about.
        docker = cls.find_docker()
        if subprocess.run([docker, "info"], capture_output=True).returncode != 0:
            raise Skip("docker daemon not running")

        # The image IS the firmware -- rootfs, /usr/prog and /usr/data, with
        # the stock package already installed, baked by build-printer-image.sh.
        # There is nothing to mount and nothing to build.
        image = config.get("PRINTER_IMAGE")
        if not image:
            raise Skip("no PRINTER_IMAGE -- put one in test.env "
                       "(test.env.example carries the published one), or "
                       "build your own with 'make printer-image'")
        return cls(config, image=image, docker=docker)

    # ------------------------------------------------------------ execution

    def command(self, case, packages=None, want_out=False, env=None):
        """The exact `docker run` argv for this case."""
        packages = packages or {}
        stage = self.stage_dir()
        config = self.config

        argv = [self.docker, "run", "--rm", "-i", "--privileged"]

        # A case that has to hand something back gets an entrypoint of ours,
        # which runs the stock one and then mounts /out inside the chroot.
        # See tools/replica/printer/entrypoint-out.sh for why that cannot
        # be a plain -v onto /printer/out.
        if want_out:
            wrapper = self.root / "tools" / "replica" / "printer" / "entrypoint-out.sh"
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
            # THE ONE WRITABLE MOUNT: everything else is :ro so a case cannot
            # edit the checkout it is testing. Under the stage dir because
            # that is inside the repo, the one path a sibling container
            # resolves to the same place the daemon does -- see stage_dir.
            "-v", "%s/out:/out" % stage,
            "-e", "FF_KEY=%s" % config.ff_key,
            # Both are always empty/off here, and are passed anyway because
            # entrypoint.sh and assemble.sh read them unconditionally. The
            # cases that install a baseline or want a real FAT stick belong
            # to qa/, which builds its own argv -- see qa/lib/replica.py.
            "-e", "BASE_PKG=",
            "-e", "PKGS=%s" % "".join(" %s=/pkgs/%s" % (n, n) for n in packages),
        ]

        # Anything the caller needs the case to see. Sorted so two runs
        # produce the same argv, which is what makes `command` worth diffing.
        for key in sorted(env or {}):
            argv += ["-e", "%s=%s" % (key, env[key])]

        argv += [
            "-e", "PROG_MB=%s" % config.get("PROG_MB"),
            "-e", "DATA_MB=%s" % config.get("DATA_MB"),
            "-e", "SIM_VERBOSE=%s" % os.environ.get("SIM_VERBOSE", "0"),
            "-e", "USB_STICK=0",
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
        and the published one (test.env's PRINTER_IMAGE) predates the split.
        Doing it on this side needs nothing of the image but the mount it has
        always had.

        ONE SOURCE NOW. It used to stage four -- anvil-core's overlay, its
        anvil.conf template, Klipper's launcher and the installer block --
        because case-moonraker.sh and case-upgrade.sh read the last three.
        (anvil.conf has since been removed outright, so that template is not
        a thing to stage again.)
        Those cases are qa/ modules now, so only the overlay is left, and the
        only file any surviving case opens under here is bin/ffscreen.py.
        """
        out = stage / "payload"
        shutil.copytree(str(self.root / "pkgs" / "anvil-core" / "payload"), str(out))
        return out

    def run_case(self, case, packages=None, on_output=None, out_dir=None,
                 env=None):
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

            argv = self.command(case, packages,
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
