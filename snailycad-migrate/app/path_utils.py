"""
Shared helper for cleaning up user-pasted file paths before they're
stored or used. Handles the common case of pasting a path copied via
Windows Explorer's "Copy as path", which wraps the result in double
quotes (e.g. "D:\\SnailyCAD"), plus stray whitespace.
"""


def clean_path(value):
    if value is None:
        return value
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1].strip()
    return value
