from modules.installers.base import BaseInstaller, InstallerError
from services import snailycad_service as sc
from services import systemctl_service as svc


class SnailyCadInstaller(BaseInstaller):
    key = "snailycad"
    name = "SnailyCAD"
    description = "Self-hosted SnailyCAD 4 dispatch/CAD system (Node.js + PostgreSQL)."

    def __init__(self):
        self._db_password = None

    def check_requirements(self, ctx):
        import shutil
        if shutil.which("apt-get") is None:
            raise InstallerError("This installer requires a Debian/Ubuntu host (apt-get not found).")
        ctx.log("Host looks Debian/Ubuntu-based, continuing.")

    def install(self, ctx):
        try:
            ctx.set_progress(18, "Step 1/8: system preparation")
            sc.system_prepare(ctx.log)

            ctx.set_progress(30, "Step 2/8: installing Node.js 22, npm, pnpm")
            sc.install_node(ctx.log)

            ctx.set_progress(42, "Step 3/8: installing PostgreSQL 16")
            self._db_password = sc.install_postgres(ctx.log)

            ctx.set_progress(50, "Step 4/8: cloning snaily-cadv4")
            sc.clone_repo(ctx.log)

            ctx.set_progress(58, "Step 5/8: pnpm install")
            sc.pnpm_install(ctx.log)
        except sc.SnailyCadError as exc:
            raise InstallerError(str(exc)) from exc

    def configure(self, ctx):
        try:
            ctx.set_progress(65, "Step 6/8: writing environment file")
            sc.write_env(ctx.log, self._db_password)

            ctx.set_progress(70, "Step 7/8: creating systemd service")
            unit_filename, unit_text = svc.generate_unit_file(
                app_name="snailycad",
                working_dir=sc.CLONE_DIR,
                exec_start="pnpm run start",
                run_user="root",
                description="SnailyCAD Service",
            )
            svc.install_unit_file(unit_filename, unit_text)
            svc.daemon_reload()

            ctx.set_progress(75, "Step 8/8: building (pnpm run build)")
            sc.pnpm_build(ctx.log)
        except (sc.SnailyCadError, svc.ServiceCommandError) as exc:
            raise InstallerError(str(exc)) from exc

    def start_service(self, ctx):
        try:
            svc.control_service("snailycad.service", "enable")
            svc.control_service("snailycad.service", "start")
            ctx.log("snailycad.service enabled and started")
        except svc.ServiceCommandError as exc:
            raise InstallerError(str(exc)) from exc

    def verify(self, ctx):
        ok = sc.verify_installed()
        ctx.log(f"Verification: install directory present = {ok}")
        return ok

    def repair(self, ctx):
        ctx.set_progress(10, "Repair: checking dependencies")
        try:
            sc.pnpm_install(ctx.log)
            ctx.set_progress(60, "Repair: dependencies reinstalled")
            svc.control_service("snailycad.service", "restart")
            ctx.log("snailycad.service restarted")
        except (sc.SnailyCadError, svc.ServiceCommandError) as exc:
            raise InstallerError(str(exc)) from exc
        ctx.set_progress(100, "Repair complete")
