"""Customer-portal session auth. Deliberately NOT built on Flask-Login /
current_user - VM customers are not models.user.User rows, and mixing
them into the same current_user pipeline that templates/base.html and
every admin route checks would risk a VM "customer" session being
treated as an authenticated admin somewhere (base.html's whole sidebar
gate is current_user.is_authenticated). Keeping this as a completely
separate plain-session mechanism means a customer session can never
accidentally satisfy an admin permission check, and vice versa.
"""
from functools import wraps

from flask import session, redirect, url_for, flash, g

from database import db
from models.vm import VM

SESSION_KEY = "vm_session_id"


def current_vm():
    """Returns the logged-in VM for this request, or None. A locked VM is
    always treated as logged-out, even if the session key is still set -
    that's what makes "admin locks a VM" take effect immediately instead
    of only on the next login attempt."""
    if hasattr(g, "_current_vm"):
        return g._current_vm
    vm_id = session.get(SESSION_KEY)
    vm = db.session.get(VM, vm_id) if vm_id else None
    if vm and vm.locked:
        vm = None
    g._current_vm = vm
    return vm


def vm_login_required(view_func):
    @wraps(view_func)
    def wrapped(*args, **kwargs):
        vm = current_vm()
        if vm is None:
            had_session = session.get(SESSION_KEY) is not None
            session.pop(SESSION_KEY, None)
            if had_session:
                flash("This VM has been locked by an administrator.", "error")
            else:
                flash("Please log in to manage your VM.", "info")
            return redirect(url_for("customer.login"))
        return view_func(*args, **kwargs)

    return wrapped
