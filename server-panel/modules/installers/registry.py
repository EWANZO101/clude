from modules.snailycad.installer import SnailyCadInstaller

_REGISTRY = {}


def register(installer_instance):
    _REGISTRY[installer_instance.key] = installer_instance


def get(key):
    return _REGISTRY.get(key)


def all_installers():
    return list(_REGISTRY.values())


register(SnailyCadInstaller())
