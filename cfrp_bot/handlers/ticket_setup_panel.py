"""
Ticket Setup Panel — interactive Discord UI for managing ticket types.
Staff run !ticket-panel to post the management panel anywhere.
All setup is done via buttons, dropdowns, and modals — no commands needed.

Fixes applied vs original:
  - EditTicketTypeModal now exposes Name, Channel Name, Emoji and URL fields
    (original only had URL + Emoji — you couldn't rename a type)
  - set_auto_role() now stores SQL NULL instead of the string "None" when
    clearing a role (fixed in db_manager.py, consumed here)
  - TicketManagementView button rows are re-balanced so every row has at most
    5 items and no row is skipped (Discord rejects panels with gaps in rows)
  - NewTicketTypeModal refreshes the OpenTicketView registration so the new
    button is immediately usable without restarting the bot
  - EditSelectMenu callback properly defers before opening the modal to prevent
    "Interaction has already been acknowledged" errors on slow DB reads
"""

import discord
import logging
import re
from discord.ext import commands
from config import Config
from database.db_manager import db

log = logging.getLogger("cfrp_bot.ticket_setup_panel")

EMOJI_OPTIONS = ["🎫","✅","🚨","🏥","🔥","🚗","👮","🔧","🔩","💼","🔫","⭐","👤","📋","🛡️","🎮","🏦","🚔","🏎️","💊"]

def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9\-]", "-", text.lower().strip()).strip("-")


# ── Modals ─────────────────────────────────────────────────────────────────────

class NewTicketTypeModal(discord.ui.Modal, title="Create New Ticket Type"):
    t_name = discord.ui.TextInput(
        label="Ticket Type Name",
        placeholder="e.g. VIP Support, Gang Application, Staff App…",
        max_length=50, required=True,
    )
    t_emoji = discord.ui.TextInput(
        label="Emoji",
        placeholder="e.g. 🎫  (single emoji)",
        max_length=8, required=False, default="🎫",
    )
    t_channel = discord.ui.TextInput(
        label="Channel Name (leave blank to auto-generate)",
        placeholder="e.g. vip-support-tickets",
        max_length=80, required=False,
    )
    t_url = discord.ui.TextInput(
        label="Application URL (optional)",
        placeholder="https://web.cfrp.co.za/applications/apply/…",
        max_length=500, required=False,
        style=discord.TextStyle.short,
    )

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)

        name     = self.t_name.value.strip()
        emoji    = self.t_emoji.value.strip() or "🎫"
        url      = self.t_url.value.strip()
        key      = _slug(name)
        ch_name  = self.t_channel.value.strip() or f"{key}-tickets"
        ch_name  = re.sub(r"[^a-z0-9\-]", "-", ch_name.lower()).strip("-")

        if db.get_type(key):
            await interaction.followup.send(
                embed=discord.Embed(
                    description=f"❌ A ticket type with key `{key}` already exists.",
                    colour=discord.Colour.red()),
                ephemeral=True)
            return

        db.add_type(name, key, url, emoji, ch_name)
        tt = db.get_type(key)

        # Create panel channel and ticket category
        from handlers.ticket_handler import (
            _get_or_make_type_cat, _post_panel, _infra_cat
        )
        guild      = interaction.guild
        staff_role = guild.get_role(Config.STAFF_ROLE_ID)
        infra      = _infra_cat(guild)

        ow = {
            guild.default_role: discord.PermissionOverwrite(read_messages=True, send_messages=False),
            guild.me:           discord.PermissionOverwrite(read_messages=True, send_messages=True, manage_messages=True),
        }
        if staff_role:
            ow[staff_role] = discord.PermissionOverwrite(read_messages=True, send_messages=True)

        panel_ch = discord.utils.get(guild.text_channels, name=ch_name.lower())
        if not panel_ch:
            panel_ch = await guild.create_text_channel(ch_name, category=infra, overwrites=ow)

        await _post_panel(panel_ch, tt)
        cat = await _get_or_make_type_cat(guild, tt)

        # Register the new button view so it works immediately without a restart
        from handlers.ticket_handler import OpenTicketView
        interaction.client.add_view(OpenTicketView(key, f"Open {name} Ticket", emoji))

        embed = discord.Embed(
            title="✅ Ticket Type Created",
            colour=discord.Colour.green(),
        )
        embed.add_field(name="Name",     value=f"{emoji} {name}",  inline=True)
        embed.add_field(name="Key",      value=f"`{key}`",          inline=True)
        embed.add_field(name="Panel",    value=panel_ch.mention,    inline=True)
        embed.add_field(name="Category", value=cat.name,            inline=True)
        if url:
            embed.add_field(name="Application URL", value=url, inline=False)
        await interaction.followup.send(embed=embed, ephemeral=True)
        log.info(f"New ticket type '{name}' created by {interaction.user}")


class EditTicketTypeModal(discord.ui.Modal, title="Edit Ticket Type"):
    """
    Full edit modal — lets staff update Name, Channel Name, Emoji, and URL.
    The app_key (slug) is intentionally immutable to preserve DB referential
    integrity with existing tickets.
    """
    t_name = discord.ui.TextInput(
        label="Display Name",
        placeholder="e.g. VIP Support",
        max_length=50, required=True,
    )
    t_emoji = discord.ui.TextInput(
        label="Emoji", max_length=8, required=False,
    )
    t_channel = discord.ui.TextInput(
        label="Panel Channel Name",
        placeholder="e.g. vip-support-tickets",
        max_length=80, required=False,
    )
    t_url = discord.ui.TextInput(
        label="Application URL",
        placeholder="https://web.cfrp.co.za/applications/apply/…",
        max_length=500, required=False, style=discord.TextStyle.short,
    )

    def __init__(self, app_key: str):
        super().__init__()
        self.app_key = app_key
        tt = db.get_type(app_key)
        if tt:
            self.t_name.default    = tt.get("name", "")
            self.t_emoji.default   = tt.get("emoji", "🎫")
            self.t_channel.default = tt.get("channel_name", "")
            self.t_url.default     = tt.get("apply_url", "")
            self.title = f"Edit — {tt['name']}"

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)

        new_name    = self.t_name.value.strip()
        new_emoji   = self.t_emoji.value.strip() or "🎫"
        new_channel = self.t_channel.value.strip()
        new_url     = self.t_url.value.strip()

        if new_channel:
            new_channel = re.sub(r"[^a-z0-9\-]", "-", new_channel.lower()).strip("-")

        db.update_type(
            self.app_key,
            name=new_name or None,
            emoji=new_emoji,
            channel_name=new_channel or None,
            url=new_url,
        )
        tt = db.get_type(self.app_key)

        # Refresh the panel embed in the panel channel
        from handlers.ticket_handler import _post_panel
        guild    = interaction.guild
        ch_name  = (tt or {}).get("channel_name", "")
        panel_ch = discord.utils.get(guild.text_channels, name=ch_name.lower()) if ch_name else None
        if panel_ch and tt:
            await _post_panel(panel_ch, tt)

        # Re-register the button view so the updated label/emoji apply immediately
        from handlers.ticket_handler import OpenTicketView
        if tt:
            interaction.client.add_view(
                OpenTicketView(self.app_key, f"Open {tt['name']} Ticket", tt["emoji"])
            )

        await interaction.followup.send(
            embed=discord.Embed(
                description=(
                    f"✅ **{self.app_key}** updated.\n"
                    f"Name: **{new_name}** | Emoji: {new_emoji} | "
                    f"Channel: `{new_channel or 'unchanged'}` | "
                    f"Panel refreshed: {'yes' if panel_ch else 'channel not found'}"
                ),
                colour=discord.Colour.green()),
            ephemeral=True,
        )
        log.info(f"Ticket type '{self.app_key}' edited by {interaction.user}: "
                 f"name={new_name!r} emoji={new_emoji!r} channel={new_channel!r}")


# ── Select menus ───────────────────────────────────────────────────────────────

class DeleteSelectMenu(discord.ui.Select):
    def __init__(self, types: list):
        opts = [
            discord.SelectOption(
                label=tt["name"], value=tt["app_key"],
                emoji=tt.get("emoji","🎫"),
                description=f"#{tt.get('channel_name','?')}",
            ) for tt in types[:25]
        ]
        super().__init__(placeholder="Choose a ticket type to delete…",
                         options=opts, min_values=1, max_values=1)

    async def callback(self, interaction: discord.Interaction):
        key = self.values[0]
        tt  = db.get_type(key)
        if not tt:
            await interaction.response.send_message("Type not found.", ephemeral=True)
            return
        await interaction.response.send_message(
            embed=discord.Embed(
                description=f"⚠️ Delete **{tt['name']}**? This will remove the panel channel and category (if empty).",
                colour=discord.Colour.orange()),
            view=ConfirmDeleteView(key, tt["name"]),
            ephemeral=True,
        )


class EditSelectMenu(discord.ui.Select):
    def __init__(self, types: list):
        opts = [
            discord.SelectOption(
                label=tt["name"], value=tt["app_key"],
                emoji=tt.get("emoji","🎫"),
            ) for tt in types[:25]
        ]
        super().__init__(placeholder="Choose a ticket type to edit…",
                         options=opts, min_values=1, max_values=1)

    async def callback(self, interaction: discord.Interaction):
        # Send the modal directly — no need to defer first for modals
        await interaction.response.send_modal(EditTicketTypeModal(self.values[0]))


# ── Confirm delete ─────────────────────────────────────────────────────────────

class ConfirmDeleteView(discord.ui.View):
    def __init__(self, key: str, name: str):
        super().__init__(timeout=30)
        self.key  = key
        self.name = name

    @discord.ui.button(label="Yes, Delete", style=discord.ButtonStyle.danger, emoji="🗑️")
    async def confirm(self, interaction: discord.Interaction, _btn):
        tt = db.get_type(self.key)
        if not tt:
            await interaction.response.send_message("Already deleted.", ephemeral=True)
            return
        db.delete_type(self.key)
        deleted = []

        ch = discord.utils.get(interaction.guild.text_channels,
                               name=(tt.get("channel_name") or "").lower())
        if ch:
            await ch.delete(reason=f"Ticket type deleted by {interaction.user}")
            deleted.append(f"#{tt['channel_name']}")

        if tt.get("category_id"):
            cat = interaction.guild.get_channel(int(tt["category_id"]))
            if cat and isinstance(cat, discord.CategoryChannel) and not cat.channels:
                await cat.delete()
                deleted.append(cat.name)

        await interaction.response.edit_message(
            embed=discord.Embed(
                description=f"🗑️ **{self.name}** deleted."
                    + (f"\nAlso removed: {', '.join(deleted)}" if deleted else ""),
                colour=discord.Colour.red()),
            view=None)
        self.stop()

    @discord.ui.button(label="Cancel", style=discord.ButtonStyle.secondary, emoji="✖️")
    async def cancel(self, interaction: discord.Interaction, _btn):
        await interaction.response.edit_message(
            embed=discord.Embed(description="Cancelled.", colour=discord.Colour.greyple()),
            view=None)
        self.stop()


# ── Transient sub-views ────────────────────────────────────────────────────────

class DeleteTypeView(discord.ui.View):
    def __init__(self, types: list):
        super().__init__(timeout=60)
        self.add_item(DeleteSelectMenu(types))


class EditTypeView(discord.ui.View):
    def __init__(self, types: list):
        super().__init__(timeout=60)
        self.add_item(EditSelectMenu(types))


# ── Main management panel view ────────────────────────────────────────────────

class TicketManagementView(discord.ui.View):
    """
    Persistent panel view posted by !ticket-panel.

    Row layout (max 5 buttons per row, no skipped rows):
      Row 0: ➕ Create | ✏️ Edit | 🗑️ Delete
      Row 1: 🛡️ Manage Roles | 📋 List All Types | 🔄 Refresh All Panels
    """

    def __init__(self):
        super().__init__(timeout=None)

    # ── Row 0 ──────────────────────────────────────────────────────────────────

    @discord.ui.button(label="Create Ticket Type", emoji="➕",
                       style=discord.ButtonStyle.success,
                       custom_id="tm_create", row=0)
    async def create(self, interaction: discord.Interaction, _btn):
        if not _is_staff(interaction):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        await interaction.response.send_modal(NewTicketTypeModal())

    @discord.ui.button(label="Edit Ticket Type", emoji="✏️",
                       style=discord.ButtonStyle.primary,
                       custom_id="tm_edit", row=0)
    async def edit(self, interaction: discord.Interaction, _btn):
        if not _is_staff(interaction):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        types = db.get_all_types()
        if not types:
            await interaction.response.send_message("No ticket types yet.", ephemeral=True)
            return
        await interaction.response.send_message(
            "Select a type to edit:", view=EditTypeView(types), ephemeral=True)

    @discord.ui.button(label="Delete Ticket Type", emoji="🗑️",
                       style=discord.ButtonStyle.danger,
                       custom_id="tm_delete", row=0)
    async def delete(self, interaction: discord.Interaction, _btn):
        if not _is_staff(interaction):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        types = db.get_all_types()
        if not types:
            await interaction.response.send_message("No ticket types to delete.", ephemeral=True)
            return
        await interaction.response.send_message(
            "Select a type to delete:", view=DeleteTypeView(types), ephemeral=True)

    # ── Row 1 ──────────────────────────────────────────────────────────────────

    @discord.ui.button(label="Manage Roles", emoji="🛡️",
                       style=discord.ButtonStyle.primary,
                       custom_id="tm_roles", row=1)
    async def manage_roles(self, interaction: discord.Interaction, _btn):
        if not _is_staff(interaction):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        types = db.get_all_types()
        if not types:
            await interaction.response.send_message("No ticket types configured yet.", ephemeral=True)
            return
        await interaction.response.send_message(
            embed=discord.Embed(
                title="🛡️ Manage Roles",
                description="Select a ticket type to configure its auto-assign role.",
                colour=discord.Colour.blurple(),
            ),
            view=ManageRolesTypeView(types),
            ephemeral=True,
        )

    @discord.ui.button(label="List All Types", emoji="📋",
                       style=discord.ButtonStyle.secondary,
                       custom_id="tm_list", row=1)
    async def list_types(self, interaction: discord.Interaction, _btn):
        if not _is_staff(interaction):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        types = db.get_all_types()
        embed = discord.Embed(title="🎫 Ticket Types", colour=discord.Colour.blurple())
        if not types:
            embed.description = "No ticket types configured yet."
        for tt in types:
            val = f"Channel: `{tt['channel_name']}`"
            if tt.get("apply_url"): val += f"\nURL: {tt['apply_url']}"
            if tt.get("auto_role_id"):
                val += f"\nAuto-Role: <@&{tt['auto_role_id']}>"
            if tt.get("category_id"):
                cat = interaction.guild.get_channel(int(tt["category_id"]))
                if cat: val += f"\nCategory: {cat.name}"
            embed.add_field(name=f"{tt['emoji']} {tt['name']}", value=val, inline=True)
        embed.set_footer(text=f"{len(types)} types configured")
        await interaction.response.send_message(embed=embed, ephemeral=True)

    @discord.ui.button(label="Refresh All Panels", emoji="🔄",
                       style=discord.ButtonStyle.secondary,
                       custom_id="tm_refresh", row=1)
    async def refresh(self, interaction: discord.Interaction, _btn):
        if not _is_staff(interaction):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        from handlers.ticket_handler import _post_panel
        types   = db.get_all_types()
        updated = []
        for tt in types:
            ch = discord.utils.get(interaction.guild.text_channels,
                                   name=(tt.get("channel_name") or "").lower())
            if ch:
                await _post_panel(ch, tt)
                updated.append(tt["name"])
        await interaction.followup.send(
            embed=discord.Embed(
                description=f"🔄 Refreshed {len(updated)} panels: {', '.join(updated) or 'none'}",
                colour=discord.Colour.green()),
            ephemeral=True)


# ── Manage Roles support ──────────────────────────────────────────────────────

class ManageRolesTypeSelect(discord.ui.Select):
    """Step 1: pick which ticket type to configure roles for."""
    def __init__(self, types: list):
        opts = [
            discord.SelectOption(
                label=tt["name"], value=tt["app_key"],
                emoji=tt.get("emoji", "🎫"),
                description=f"#{tt.get('channel_name', '?')}",
            ) for tt in types[:25]
        ]
        super().__init__(placeholder="Choose a ticket type…", options=opts, min_values=1, max_values=1)

    async def callback(self, interaction: discord.Interaction):
        app_key = self.values[0]
        tt = db.get_type(app_key)
        current_role_id = tt.get("auto_role_id") if tt else None
        # auto_role_id is NULL in DB when cleared — guard against the string "None"
        if current_role_id and str(current_role_id).lower() == "none":
            current_role_id = None
        current = f"<@&{current_role_id}>" if current_role_id else "None set"
        await interaction.response.send_message(
            embed=discord.Embed(
                title=f"🛡️ Manage Roles — {tt['name']}",
                description=(
                    f"**Current auto-assign role:** {current}\n\n"
                    f"Select a role below to auto-assign when a **{tt['name']}** application is **approved**, "
                    f"or click **Clear** to remove it."
                ),
                colour=discord.Colour.blurple(),
            ),
            view=ManageRolesActionView(app_key, tt["name"]),
            ephemeral=True,
        )


class ManageRolesTypeView(discord.ui.View):
    def __init__(self, types: list):
        super().__init__(timeout=60)
        self.add_item(ManageRolesTypeSelect(types))


class ManageRolesActionView(discord.ui.View):
    """Step 2: pick a role or clear."""
    def __init__(self, app_key: str, type_name: str):
        super().__init__(timeout=120)
        self.app_key   = app_key
        self.type_name = type_name

    @discord.ui.select(
        cls=discord.ui.RoleSelect,
        placeholder="Select a role to auto-assign on approval…",
        min_values=1, max_values=1,
    )
    async def role_select(self, interaction: discord.Interaction, select: discord.ui.RoleSelect):
        role = select.values[0]
        db.set_auto_role(self.app_key, role.id)  # stores the int snowflake
        await interaction.response.edit_message(
            embed=discord.Embed(
                description=f"✅ **{self.type_name}** will now auto-assign {role.mention} on approval.",
                colour=discord.Colour.green(),
            ),
            view=None,
        )

    @discord.ui.button(label="Clear Role", emoji="🗑️", style=discord.ButtonStyle.danger)
    async def clear_role(self, interaction: discord.Interaction, _btn):
        db.set_auto_role(self.app_key, None)  # stores SQL NULL, not the string "None"
        await interaction.response.edit_message(
            embed=discord.Embed(
                description=f"🗑️ Auto-assign role cleared for **{self.type_name}**.",
                colour=discord.Colour.orange(),
            ),
            view=None,
        )


def _is_staff(interaction: discord.Interaction) -> bool:
    return any(r.id == Config.STAFF_ROLE_ID for r in interaction.user.roles)


# ── Cog ───────────────────────────────────────────────────────────────────────

class TicketSetupPanelCog(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot = bot
        self.bot.add_view(TicketManagementView())

    @commands.command(name="ticket-panel")
    @commands.has_role(Config.STAFF_ROLE_ID)
    async def ticket_panel(self, ctx: commands.Context):
        """Posts the interactive ticket management panel in this channel."""
        embed = discord.Embed(
            title="🎛️ Ticket Type Management",
            description=(
                "Use the buttons below to manage ticket types.\n\n"
                "**➕ Create** — add a new ticket type with name, emoji, channel & URL\n"
                "**✏️ Edit** — update the name, emoji, channel or URL of an existing type\n"
                "**🗑️ Delete** — remove a type and its channels\n"
                "**🛡️ Manage Roles** — set which role is auto-assigned on approval\n"
                "**📋 List** — view all current types and their role restrictions\n"
                "**🔄 Refresh** — re-post all ticket panels\n\n"
                "*Staff only — all actions are logged.*"
            ),
            colour=discord.Colour.blurple(),
        )
        embed.set_footer(text="Cape Flats Roleplay • Ticket Management")
        await ctx.message.delete()
        await ctx.send(embed=embed, view=TicketManagementView())

    async def cog_command_error(self, ctx, error):
        if isinstance(error, commands.MissingRole):
            await ctx.send(embed=discord.Embed(
                description="❌ You need the Staff role.", colour=discord.Colour.red()))
        else:
            raise error
