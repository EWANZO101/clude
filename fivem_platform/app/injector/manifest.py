import re


def parse_manifest_scripts(manifest_text: str):
    """Finds client_script(s)/server_script(s)/shared_script(s) declarations
    in an fxmanifest.lua and returns {'client': [...], 'server': [...], 'shared': [...]}
    of the referenced file paths (relative to the resource root).

    Handles both singular ("client_script 'x.lua'") and array/list forms
    ("client_scripts { 'a.lua', 'b.lua' }" or spread across multiple lines).
    """
    result = {"client": [], "server": [], "shared": []}

    for kind, key in (("client", "client"), ("server", "server"), ("shared", "shared")):
        # Singular form: client_script 'path.lua'
        for m in re.finditer(rf"\b{kind}_script\s+['\"]([^'\"]+)['\"]", manifest_text):
            result[key].append(m.group(1))

        # Plural/array form: client_scripts { 'a.lua', 'b.lua', ... }
        for block in re.finditer(rf"\b{kind}_scripts\s*\{{(.*?)\}}", manifest_text, re.S):
            for m in re.finditer(r"['\"]([^'\"]+)['\"]", block.group(1)):
                result[key].append(m.group(1))

    return result
