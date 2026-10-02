"""
Structural safety net for the Admin Panel / Kiosk App split (see
OWNERSHIP.md). This is what makes cross-contamination between the two
systems fail loudly at test time instead of silently at runtime — the
Admin Panel's base.html "Inventory" dropdown (linking to Kiosk-only
blueprints that were never registered here) and the seven Kiosk blueprint
files that imported model classes deleted from app/models.py years ago are
exactly the two failure modes this guards against.

Run directly:
    python3 -m unittest tests.test_app_boundaries -v
"""
import ast
import os
import re
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

# Names that only ever belonged to the Kiosk App and must never come back
# under app/ (the Admin Panel) — see the removal in this pass.
REMOVED_KIOSK_ONLY_FILES = [
    "app/blueprints/admin.py", "app/blueprints/items.py", "app/blueprints/tools.py",
    "app/blueprints/wire.py", "app/blueprints/projects.py", "app/blueprints/scan.py",
    "app/blueprints/stock_audit.py", "app/permissions.py", "app/barcode_render.py",
]

ADMIN_PANEL_ONLY_MODULE_NAMES = {
    "agent_api", "companies", "instances", "releases", "platform", "rollouts", "dev_files",
    "client_portal", "rbac", "tokens", "emails", "instance_auth", "platform_auth",
    "update_scheduling", "update_validation",
}


def _iter_py_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("__pycache__", ".git")]
        for fname in filenames:
            if fname.endswith(".py"):
                yield os.path.join(dirpath, fname)


def _imported_module_roots(py_file):
    """Top-level module name of every import in a .py file, e.g.
    'from app.blueprints.items import bp' -> 'items' isn't returned (we
    want the leaf module name for the admin-only-name check below, plus
    the full dotted path for the cross-tree check)."""
    with open(py_file, "r", encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=py_file)
    roots = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                roots.append(alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module:
            roots.append(node.module)
    return roots


class TestRemovedKioskFilesStayRemoved(unittest.TestCase):
    def test_kiosk_only_files_do_not_exist_under_app(self):
        for rel in REMOVED_KIOSK_ONLY_FILES:
            self.assertFalse(
                os.path.exists(os.path.join(REPO_ROOT, rel)),
                f"{rel} was removed as a Kiosk-only landmine (imports model classes that don't "
                f"exist in app/models.py) — it must not be re-added to the Admin Panel.",
            )


class TestAdminPanelBoots(unittest.TestCase):
    def test_create_app_registers_only_admin_panel_blueprints(self):
        from app import create_app
        app = create_app()
        expected = {
            "auth", "companies", "dashboard", "instances", "inventory_ops_instances", "agent_api",
            "releases", "platform", "rollouts", "dev_files", "client_portal", "scan_portal", "products",
        }
        self.assertEqual(set(app.blueprints.keys()), expected)

    def test_no_dangling_url_for_in_templates(self):
        """Every url_for('blueprint.endpoint') referenced in an Admin Panel
        template must resolve against the real url_map — this is the
        general form of the dashboard.activity dangling-link bug."""
        from app import create_app
        app = create_app()
        known_endpoints = {rule.endpoint for rule in app.url_map.iter_rules()}

        templates_dir = os.path.join(REPO_ROOT, "app", "templates")
        pattern = re.compile(r"""url_for\(\s*['"]([a-zA-Z_][a-zA-Z0-9_.]*)['"]""")
        problems = []
        for dirpath, _, filenames in os.walk(templates_dir):
            for fname in filenames:
                if not fname.endswith(".html"):
                    continue
                full = os.path.join(dirpath, fname)
                with open(full, "r", encoding="utf-8") as f:
                    content = f.read()
                for endpoint in pattern.findall(content):
                    if endpoint == "static":
                        continue
                    if endpoint not in known_endpoints:
                        problems.append(f"{os.path.relpath(full, REPO_ROOT)}: url_for({endpoint!r})")
        self.assertFalse(problems, "Dangling url_for() targets found:\n" + "\n".join(problems))


class TestNoCrossImports(unittest.TestCase):
    def test_admin_panel_never_imports_kiosk_app(self):
        app_dir = os.path.join(REPO_ROOT, "app")
        offenders = []
        for py_file in _iter_py_files(app_dir):
            for mod in _imported_module_roots(py_file):
                if mod == "kiosk_app" or mod.startswith("kiosk_app."):
                    offenders.append(f"{os.path.relpath(py_file, REPO_ROOT)} imports {mod!r}")
        self.assertFalse(offenders, "app/ must never import kiosk_app/:\n" + "\n".join(offenders))

    def test_kiosk_app_never_imports_admin_panel_only_modules(self):
        kiosk_dir = os.path.join(REPO_ROOT, "kiosk_app")
        offenders = []
        for py_file in _iter_py_files(kiosk_dir):
            for mod in _imported_module_roots(py_file):
                leaf = mod.split(".")[-1]
                if leaf in ADMIN_PANEL_ONLY_MODULE_NAMES:
                    offenders.append(f"{os.path.relpath(py_file, REPO_ROOT)} imports {mod!r}")
        self.assertFalse(offenders, "kiosk_app/ must never import Admin-Panel-only modules:\n" + "\n".join(offenders))


if __name__ == "__main__":
    unittest.main()
