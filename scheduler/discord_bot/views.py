"""The Stop button attached to every spam-ping DM.

One view instance per (booking, recipient) pair, with both ids baked
into the button's custom_id (``stop_ping:<booking_id>:<discord_user_id>``)
so it keeps working across bot restarts, and so each recipient's Stop
button only ever stops *their own* ping session — not anyone else's.
on_ready re-registers a fresh view for every still-active session (see
bot.py), and Discord routes the click by matching that custom_id string,
not by object identity.
"""

import logging

import discord

logger = logging.getLogger("discord_bot.views")

# Set by bot.py after create_app() — the view's callback needs an app
# context to touch the database, same as notifier.py.
flask_app = None


class StopPingView(discord.ui.View):
    def __init__(self, booking_id, discord_user_id):
        super().__init__(timeout=None)
        self.booking_id = booking_id
        self.discord_user_id = str(discord_user_id)
        # Decorated children are rebuilt per-instance on __init__, so it's
        # safe to give this instance's button its own custom_id here.
        self.stop_button.custom_id = f"stop_ping:{booking_id}:{self.discord_user_id}"

    @discord.ui.button(label="Stop pings", style=discord.ButtonStyle.danger, emoji="\U0001F6D1")
    async def stop_button(self, interaction: discord.Interaction, button: discord.ui.Button):
        from app import db
        from app.models.booking import BookingPingState

        with flask_app.app_context():
            state = BookingPingState.query.filter_by(
                booking_id=self.booking_id, discord_user_id=self.discord_user_id
            ).first()
            if state is not None:
                state.active = False
                state.last_message_id = None
                db.session.commit()

        button.disabled = True
        button.label = "Stopped"
        embed = interaction.message.embeds[0] if interaction.message.embeds else None
        if embed is not None:
            embed.color = 0x6B7280  # neutral grey — no longer urgent
            embed.set_footer(text=f"Pings stopped \u00b7 {embed.footer.text or 'Scheduler'}")
        try:
            await interaction.response.edit_message(embed=embed, view=self)
        except discord.HTTPException:
            logger.exception(
                "Failed to edit ping message after stop for booking %s / recipient %s",
                self.booking_id, self.discord_user_id,
            )
        self.stop()
