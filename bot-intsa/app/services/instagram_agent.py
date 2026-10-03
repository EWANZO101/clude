"""
Instagram browser-automation agent.

WARNING - read before flipping PUBLISH_DRY_RUN to false:
- Automating login/actions on Instagram outside its official API is against
  Instagram's Terms of Service and can get an account flagged, challenged, or
  banned, regardless of how carefully this is implemented.
- Storing your password and 2FA secret (even encrypted) means a single leak of
  this app's ENCRYPTION_KEY and database compromises full account access,
  bypassing the entire point of 2FA.
- Instagram's login page changes often and actively fingerprints automated
  browsers, so the selectors below are best-effort and may need updating.

This module defaults to dry-run behaviour. Live automation only happens when
the caller explicitly passes dry_run=False (wired to PUBLISH_DRY_RUN=false in
.env), and you are responsible for what happens to your account after that.
"""

from ..security import current_totp_code, decrypt

try:
    from playwright.sync_api import sync_playwright

    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False


def test_login(account, dry_run: bool = True) -> dict:
    if dry_run:
        return {
            "success": bool(account.encrypted_password),
            "message": "Dry run: credentials saved. Set PUBLISH_DRY_RUN=false to attempt a real login.",
        }

    if not PLAYWRIGHT_AVAILABLE:
        return {
            "success": False,
            "message": "Playwright is not installed. Run: pip install playwright && playwright install chromium",
        }

    if account.platform != "instagram":
        return {"success": False, "message": f"Live automation not implemented for {account.platform} yet."}

    password = decrypt(account.encrypted_password)
    totp_secret = decrypt(account.encrypted_totp_secret) if account.encrypted_totp_secret else None

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page()
            page.goto("https://www.instagram.com/accounts/login/", timeout=30000)
            page.wait_for_selector("input[name='username']", timeout=15000)
            page.fill("input[name='username']", account.username)
            page.fill("input[name='password']", password)
            page.click("button[type='submit']")
            page.wait_for_timeout(4000)

            if page.locator("input[name='verificationCode']").count() > 0:
                if not totp_secret:
                    browser.close()
                    return {
                        "success": False,
                        "message": "Instagram is asking for a 2FA code and no TOTP secret is saved for this account.",
                    }
                code = current_totp_code(totp_secret)
                page.fill("input[name='verificationCode']", code)
                page.click("button[type='submit']")
                page.wait_for_timeout(4000)

            logged_in = "instagram.com/accounts/login" not in page.url
            browser.close()
            if logged_in:
                return {"success": True, "message": "Logged in successfully."}
            return {
                "success": False,
                "message": "Login did not complete - Instagram may have shown a checkpoint/challenge that needs manual review.",
            }
    except Exception as e:
        return {"success": False, "message": f"Automation error: {e}"}


def update_bio(account, bio: str, dry_run: bool = True) -> dict:
    if dry_run or not PLAYWRIGHT_AVAILABLE:
        return {"success": True, "message": "Dry run: bio update queued (not sent to Instagram)."}
    return {
        "success": False,
        "message": "Live bio updates not implemented yet - add selectors for the current Instagram edit-profile page here.",
    }
