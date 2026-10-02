"""
SSO provider catalogue. A provider switches on automatically when its
CLIENT_ID + CLIENT_SECRET env vars are present.

Env var names per provider:  <KEY>_CLIENT_ID / <KEY>_CLIENT_SECRET
e.g. GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET

Generic OIDC (any provider) uses:
  OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_METADATA_URL, OIDC_NAME (optional)
"""

# label / brand colour / simple inline SVG path(s) for the button icon
# kind: "oidc" (uses server_metadata_url) or "oauth2" (explicit endpoints)
PROVIDERS = {
    "google": {
        "label": "Google", "color": "#ffffff", "text": "#1f2937",
        "kind": "oidc",
        "server_metadata_url": "https://accounts.google.com/.well-known/openid-configuration",
        "scope": "openid email profile",
        "icon": "M21.35 11.1H12v3.2h5.35c-.25 1.6-1.7 4.7-5.35 4.7A6 6 0 1112 6.3a5.3 5.3 0 013.75 1.45l2.2-2.2A8.9 8.9 0 0012 3.2 8.8 8.8 0 1020.8 12c0-.6-.05-1-.15-1.5z",
    },
    "microsoft": {
        "label": "Microsoft", "color": "#2f2f2f", "text": "#ffffff",
        "kind": "oidc",
        "server_metadata_url": "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration",
        "scope": "openid email profile",
        "icon": "M3 3h8v8H3V3zm10 0h8v8h-8V3zM3 13h8v8H3v-8zm10 0h8v8h-8v-8z",
    },
    "github": {
        "label": "GitHub", "color": "#24292f", "text": "#ffffff",
        "kind": "oauth2",
        "authorize_url": "https://github.com/login/oauth/authorize",
        "access_token_url": "https://github.com/login/oauth/access_token",
        "api_base_url": "https://api.github.com/",
        "userinfo": "https://api.github.com/user",
        "emails_url": "https://api.github.com/user/emails",
        "scope": "read:user user:email",
        "icon": "M12 2a10 10 0 00-3.16 19.49c.5.09.68-.22.68-.48l-.01-1.7c-2.78.6-3.37-1.34-3.37-1.34-.46-1.16-1.11-1.47-1.11-1.47-.9-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.52 2.34 1.08 2.91.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.6 9.6 0 015 0c1.9-1.29 2.74-1.02 2.74-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85l-.01 2.75c0 .27.18.58.69.48A10 10 0 0012 2z",
    },
    "discord": {
        "label": "Discord", "color": "#5865F2", "text": "#ffffff",
        "kind": "oauth2",
        "authorize_url": "https://discord.com/oauth2/authorize",
        "access_token_url": "https://discord.com/api/oauth2/token",
        "api_base_url": "https://discord.com/api/",
        "userinfo": "https://discord.com/api/users/@me",
        "scope": "identify email",
        "icon": "M20.3 4.3A19 19 0 0015.6 3l-.2.5c1.7.4 2.6.9 3.6 1.6a13 13 0 00-11.9 0c1-.7 2-1.2 3.6-1.6L10.4 3a19 19 0 00-4.7 1.3C2.7 8.8 2 13.2 2.2 17.6a19 19 0 005.8 2.9l.5-1c-.6-.2-1.3-.5-2-1l.4-.3a13.6 13.6 0 0011.6 0l.4.3c-.7.5-1.4.8-2 1l.5 1a19 19 0 005.8-2.9c.4-5-.8-9.4-2.9-13.3zM9.3 15c-.9 0-1.7-.8-1.7-1.9s.8-1.9 1.7-1.9 1.7.9 1.7 1.9-.8 1.9-1.7 1.9zm5.4 0c-.9 0-1.7-.8-1.7-1.9s.8-1.9 1.7-1.9 1.7.9 1.7 1.9-.8 1.9-1.7 1.9z",
    },
    "facebook": {
        "label": "Facebook", "color": "#1877F2", "text": "#ffffff",
        "kind": "oauth2",
        "authorize_url": "https://www.facebook.com/v17.0/dialog/oauth",
        "access_token_url": "https://graph.facebook.com/v17.0/oauth/access_token",
        "api_base_url": "https://graph.facebook.com/",
        "userinfo": "https://graph.facebook.com/me?fields=id,name,email",
        "scope": "email public_profile",
        "icon": "M22 12a10 10 0 10-11.6 9.9v-7H7.9V12h2.5V9.8c0-2.5 1.5-3.9 3.8-3.9 1.1 0 2.2.2 2.2.2v2.5h-1.3c-1.2 0-1.6.8-1.6 1.6V12h2.8l-.4 2.9h-2.3v7A10 10 0 0022 12z",
    },
    "gitlab": {
        "label": "GitLab", "color": "#fc6d26", "text": "#1f2937",
        "kind": "oidc",
        "server_metadata_url": "https://gitlab.com/.well-known/openid-configuration",
        "scope": "openid email profile",
        "icon": "M23 13.4l-1.1-3.4-2.2-6.8c-.1-.3-.6-.3-.7 0L16.8 9.9H7.2L5 3.2c-.1-.3-.6-.3-.7 0L2.1 10 .9 13.4c-.1.3 0 .7.3.9L12 22l10.7-7.7c.3-.2.4-.6.3-.9z",
    },
}


def parse_identity(provider, userinfo):
    """Return (sub, email, name) from a provider's userinfo payload."""
    if not userinfo:
        return None, None, None
    if provider == "github":
        sub = str(userinfo.get("id"))
        return sub, userinfo.get("email"), userinfo.get("name") or userinfo.get("login")
    if provider == "discord":
        sub = str(userinfo.get("id"))
        name = userinfo.get("global_name") or userinfo.get("username")
        return sub, userinfo.get("email"), name
    if provider == "facebook":
        return str(userinfo.get("id")), userinfo.get("email"), userinfo.get("name")
    # OIDC-style (google, microsoft, gitlab, generic)
    sub = userinfo.get("sub") or userinfo.get("id")
    name = userinfo.get("name") or userinfo.get("preferred_username")
    return (str(sub) if sub is not None else None), userinfo.get("email"), name
