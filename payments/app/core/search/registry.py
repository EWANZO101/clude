"""Global search. Modules register a provider(query) -> list[SearchResult]."""

_providers = {}


class SearchResult:
    def __init__(self, title, url, snippet="", category=""):
        self.title = title
        self.url = url
        self.snippet = snippet
        self.category = category


def register_search_provider(name, fn):
    _providers[name] = fn


def search(query, user):
    if not query or len(query.strip()) < 2:
        return []
    results = []
    for name, fn in _providers.items():
        try:
            results.extend(fn(query, user))
        except Exception:
            continue
    return results
