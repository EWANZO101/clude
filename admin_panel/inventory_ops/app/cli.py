import click

from app.extensions import db
from app.models import LocalUser


def register_cli(app):
    @app.cli.command("create-admin")
    @click.argument("username")
    @click.option("--password", required=True)
    def create_admin(username, password):
        """Creates (or promotes/resets) an admin account directly — useful
        if auth was turned on and the account that would manage it got
        locked out, or for scripted first-time setup."""
        user = LocalUser.query.filter_by(username=username).first()
        if user is None:
            user = LocalUser(username=username, role="admin")
            db.session.add(user)
        user.role = "admin"
        user.is_active = True
        user.set_password(password)
        db.session.commit()
        click.echo(f"Admin account '{username}' ready.")

    @app.cli.command("reset-password")
    @click.argument("username")
    @click.option("--password", required=True)
    def reset_password(username, password):
        user = LocalUser.query.filter_by(username=username).first()
        if user is None:
            click.echo(f"No such user '{username}'.")
            raise SystemExit(1)
        user.set_password(password)
        db.session.commit()
        click.echo(f"Password updated for '{username}'.")
