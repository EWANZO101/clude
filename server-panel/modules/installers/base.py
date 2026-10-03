class InstallerError(Exception):
    pass


class BaseInstaller:
    """Every installer (SnailyCAD, Nextcloud, Uptime Kuma, custom...) implements this.

    Each lifecycle method receives a JobContext (`ctx`) for progress/log reporting
    and should raise InstallerError with a plain-English message on failure.
    """

    key = "base"
    name = "Base Installer"
    description = ""

    def check_requirements(self, ctx):
        """Verify OS/packages/ports before touching anything. Raise InstallerError to abort."""
        raise NotImplementedError

    def install(self, ctx):
        raise NotImplementedError

    def configure(self, ctx):
        raise NotImplementedError

    def start_service(self, ctx):
        raise NotImplementedError

    def verify(self, ctx):
        """Return True/False (or raise) after checking the app is actually reachable/running."""
        raise NotImplementedError

    def repair(self, ctx):
        """Best-effort self-heal: re-check deps, reinstall if needed, restart service."""
        raise NotImplementedError

    def run_full_install(self, ctx):
        ctx.set_progress(2, f"Starting {self.name} installation")
        self.check_requirements(ctx)
        ctx.set_progress(15, "Requirements OK")

        self.install(ctx)
        ctx.set_progress(60, "Install step complete")

        self.configure(ctx)
        ctx.set_progress(80, "Configuration complete")

        self.start_service(ctx)
        ctx.set_progress(92, "Service started")

        ok = self.verify(ctx)
        if not ok:
            raise InstallerError(f"{self.name} installed but failed verification.")
        ctx.set_progress(100, f"{self.name} installed and verified")
