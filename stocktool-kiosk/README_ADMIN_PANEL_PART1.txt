ADMIN PANEL -- PART 1 (AI fully removed, new Admin Panel foundation)
=====================================================================

APPLY:

1) Overwrite every file in this zip over your current files at the
   same relative path (one copy of each -- these are the final,
   already-merged versions):
     app/__init__.py, app/settings.py, server_supervisor.py,
     relay_client.py, requirements.txt, build.spec, build.ps1,
     app/routes_admin.py
   plus these NEW files:
     app/admin_models.py, app/admin_auth.py, app/admin_app.py,
     app/routes_admin_panel.py, app/templates/admin_panel.html

2) Delete these (AI-only, fully removed):
   app/ai_models.py, app/ai_engine.py, app/ai_tools.py,
   app/ai_knowledge.py, app/ai_explain.py, app/routes_ai.py,
   app/ai_app.py, app/templates/admin_ai.html,
   AI_ASSISTANT_PLAN.txt, installer/get-llama-server.ps1,
   vendor/llama/ (whole folder, if it exists)

ACCESS: http://127.0.0.1:8423/ui/admin -- log in with any existing
kiosk badge code/username. Default roles (super_admin/admin/supervisor/
stock_user) and default sidebar pages are seeded automatically on first
startup after this is applied. To actually use super_admin, change an
existing user's role to it (existing --create-user CLI or the new
Admin Panel Users screen once you're in as any current admin).

BUILT IN PART 1: roles & permission grants (full CRUD), users (role
assignment), sidebar/page metadata (Sidebar Builder -- add/rename/
reorder/enable/disable/delete, role-based visibility), custom field
SCHEMA (definitions only -- not yet rendered into Item/Tool/Project
forms), kiosk pairing tokens (issue/list/revoke/redeem, 12h expiry),
audit log (write + read), and a working Tailwind login+dashboard shell
wired to all of the above.

NOT YET BUILT (spec sections not covered by Part 1):
  - Page Builder's visual component canvas (section 16-17) -- AdminPage
    exists as a page/route/order/visibility record; dragging components
    onto a page is a separate, later part
  - Custom field VALUES on actual Item/Tool/Project/Wire records, and
    rendering custom fields into their forms (section 20)
  - Import/Export (21-23), Database Management (24), Backups (25)
  - Field-level permissions (33)
  - Developer Settings screen content (34) -- the page exists (super_admin
    only) but has no content yet
  - Kiosk Management multi-kiosk fleet view (29) -- this build is
    single-kiosk-per-install (Admin Panel folded into this same exe),
    so there's no fleet to list; dashboard reflects this one install
