#!/usr/bin/env python3
"""Validate and package a module directory into an installable ZIP.

Usage:
    python scripts/package_module.py path/to/module_dir [output_dir]
"""
import os
import sys
import zipfile

import yaml

REQUIRED_FIELDS = ["id", "name", "version", "core_compatibility"]


def validate(module_dir):
    manifest_path = os.path.join(module_dir, "manifest.yaml")
    if not os.path.isfile(manifest_path):
        sys.exit("manifest.yaml not found")
    with open(manifest_path) as f:
        manifest = yaml.safe_load(f) or {}
    missing = [f for f in REQUIRED_FIELDS if f not in manifest]
    if missing:
        sys.exit(f"manifest.yaml missing fields: {', '.join(missing)}")
    if not os.path.isfile(os.path.join(module_dir, "routes.py")):
        print("Warning: no routes.py found — module will install but expose no pages.")
    return manifest


def package(module_dir, output_dir):
    manifest = validate(module_dir)
    module_id = manifest["id"]
    version = manifest["version"]
    os.makedirs(output_dir, exist_ok=True)
    out_path = os.path.join(output_dir, f"{module_id}-{version}.zip")

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(module_dir):
            for name in files:
                if name.endswith(".pyc") or "__pycache__" in root:
                    continue
                full_path = os.path.join(root, name)
                arcname = os.path.relpath(full_path, module_dir)
                zf.write(full_path, arcname)

    print(f"Packaged: {out_path}")
    return out_path


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: python scripts/package_module.py path/to/module_dir [output_dir]")
    module_dir = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else "dist"
    package(module_dir, output_dir)
