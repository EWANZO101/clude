import discord
from discord.ext import commands
from discord import app_commands
import json
import os
from datetime import datetime, timezone
import asyncio

# ───────────────── CONFIG ─────────────────

TOKEN = os.environ.get("DISCORD_TOKEN", "")  # redacted
DATA_FILE = "role_config.json"
REQUEST_CHANNEL_ID = 1501611465323315301

# ───────────────── COLORS ─────────────────

COL_PRIMARY = 0x5865F2
COL_SUCCESS = 0x57F287
COL_DANGER  = 0xED4245
COL_WARNING = 0xFEE75C

# ───────────────── DATA ─────────────────

def load_data():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, "r") as f:
            return json.load(f)
    return {}

def save_data(data):
    with open(DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)

CONFIG = load_data()

def guild_config(guild_id: int):
    gid = str(guild_id)
    if gid not in CONFIG:
        CONFIG[gid] = {}
    return CONFIG[gid]

def clean_approver_id(approver_id):
    """Clean up approver ID if it has 'role:' prefix or other issues"""
    if not approver_id:
        return None
    
    approver_id = str(approver_id)
    
    if approver_id.startswith('role:'):
        approver_id = approver_id[5:]
    
    approver_id = ''.join(c for c in approver_id if c.isdigit())
    
    return approver_id if approver_id else None

# ───────────────── EMBEDS ─────────────────

def status_embed(user, role, status, reason=None):
    embed = discord.Embed(
        title="Role Request",
        colour={
            "pending": COL_WARNING,
            "approved": COL_SUCCESS,
            "denied": COL_DANGER
        }.get(status, COL_PRIMARY),
        timestamp=datetime.now(timezone.utc),
    )

    embed.add_field(name="User", value=user.mention, inline=True)
    embed.add_field(name="Role", value=role.mention, inline=True)
    embed.add_field(name="Status", value=status.upper(), inline=False)

    if reason:
        embed.add_field(name="Reason", value=reason, inline=False)

    return embed


def panel_embed():
    return discord.Embed(
        title="✦ Role Request Panel",
        description="Select a role below to request it.",
        colour=COL_PRIMARY,
        timestamp=datetime.now(timezone.utc),
    )

# ───────────────── BOT SETUP ─────────────────

intents = discord.Intents.default()
intents.members = True
intents.message_content = True

bot = commands.Bot(command_prefix="!", intents=intents)

# ───────────────── HELPER FUNCTIONS ─────────────────

async def notify_approver_role(approver_role_id, guild: discord.Guild, requester: discord.Member, role: discord.Role, thread: discord.Thread):
    """Send a DM to all members who have the approver role."""
    try:
        approver_role_id = clean_approver_id(approver_role_id)
        if not approver_role_id:
            print("No valid approver role ID after cleaning")
            return
            
        approver_role = guild.get_role(int(approver_role_id))
        if not approver_role:
            print(f"Approver role {approver_role_id} not found in guild")
            return
        
        approvers = [m for m in approver_role.members if not m.bot]
        
        if not approvers:
            print(f"No members found with role {approver_role.name}")
            return
        
        print(f"Found {len(approvers)} members with role {approver_role.name}")
        
        embed = discord.Embed(
            title="📬 New Role Request",
            description=f"A new role request needs attention!",
            color=COL_WARNING,
            timestamp=datetime.now(timezone.utc)
        )
        embed.add_field(name="Requester", value=f"{requester.mention} ({requester.name})", inline=True)
        embed.add_field(name="Requested Role", value=role.mention, inline=True)
        embed.add_field(name="Thread", value=thread.mention, inline=False)
        embed.set_footer(text=f"Requester ID: {requester.id}")
        
        success_count = 0
        for approver in approvers:
            try:
                await approver.send(embed=embed)
                print(f"✅ DM sent to {approver.name}")
                success_count += 1
            except discord.Forbidden:
                print(f"⚠️ Cannot DM {approver.name} - DMs disabled")
            except Exception as e:
                print(f"❌ Error sending DM to {approver.name}: {e}")
        
        print(f"Successfully sent DMs to {success_count}/{len(approvers)} approvers")
        
    except ValueError as e:
        print(f"Error converting approver_role_id to int: {approver_role_id} - {e}")
    except Exception as e:
        print(f"Error in notify_approver_role: {e}")

async def role_autocomplete(interaction: discord.Interaction, current: str) -> list[app_commands.Choice[str]]:
    """Autocomplete for roles"""
    roles = [r for r in interaction.guild.roles if not r.is_default() and not r.managed and r.name != "@everyone"]
    
    if current:
        roles = [r for r in roles if current.lower() in r.name.lower()]
    
    return [
        app_commands.Choice(name=r.name, value=str(r.id))
        for r in roles[:25]
    ]

# ───────────────── ROLE SELECT ─────────────────

class RoleSelect(discord.ui.RoleSelect):
    def __init__(self):
        super().__init__(
            placeholder="Search and select a role...",
            min_values=1,
            max_values=1
        )

    async def callback(self, interaction: discord.Interaction):
        # Defer immediately to prevent timeout
        await interaction.response.defer(ephemeral=True)
        
        role: discord.Role = self.values[0]
        guild = interaction.guild
        requester = interaction.user

        if not isinstance(interaction.channel, discord.TextChannel):
            return await interaction.followup.send(
                "Use this in a server channel.",
                ephemeral=True
            )

        gc = guild_config(guild.id)
        approver_role_id = gc.get(str(role.id))
        
        print(f"DEBUG - Requested Role: {role.name} (ID: {role.id})")
        print(f"DEBUG - Approver Role ID from config: {approver_role_id}")
        
        approver_role_id = clean_approver_id(approver_role_id)
        if approver_role_id:
            print(f"DEBUG - Cleaned Approver Role ID: {approver_role_id}")

        try:
            thread = await interaction.channel.create_thread(
                name=f"request-{requester.name}-{role.name}"[:90],
                type=discord.ChannelType.private_thread,
                invitable=False
            )
        except Exception as e:
            print(f"Error creating thread: {e}")
            return await interaction.followup.send(
                "❌ Failed to create request thread. Please try again.",
                ephemeral=True
            )

        try:
            await thread.add_user(requester)
        except Exception as e:
            print(f"Error adding user to thread: {e}")

        view = RequestActions(requester, role, thread, approver_role_id)

        msg = await thread.send(
            embed=status_embed(requester, role, "pending"),
            view=view
        )

        view.message = msg

        # Send DMs in the background without blocking
        if approver_role_id:
            asyncio.create_task(notify_approver_role(approver_role_id, guild, requester, role, thread))
        else:
            print(f"⚠️ No approver role configured for role {role.name}")

        await interaction.followup.send(
            f"✅ Request created in {thread.mention}",
            ephemeral=True
        )

# ───────────────── PANEL VIEW ─────────────────

class PanelView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)
        self.add_item(RoleSelect())

# ───────────────── SETUP PANEL VIEW ─────────────────

class SetupBossRoleSelect(discord.ui.RoleSelect):
    """First dropdown: pick the 'boss' (approver) role."""
    def __init__(self):
        super().__init__(
            placeholder="1️⃣  Select the boss role (who can approve)...",
            min_values=1,
            max_values=1,
            custom_id="setup_boss_role",
            row=0
        )

    async def callback(self, interaction: discord.Interaction):
        # Store selection on the parent view, no response needed yet
        self.view.boss_role = self.values[0]
        await interaction.response.defer()


class SetupControlledRoleSelect(discord.ui.RoleSelect):
    """Second dropdown: pick the role users can request."""
    def __init__(self):
        super().__init__(
            placeholder="2️⃣  Select the role to be controlled (requestable)...",
            min_values=1,
            max_values=1,
            custom_id="setup_controlled_role",
            row=1
        )

    async def callback(self, interaction: discord.Interaction):
        self.view.controlled_role = self.values[0]
        await interaction.response.defer()


class SetupPanelView(discord.ui.View):
    """Ephemeral view sent by /setup_panel — two dropdowns + a Confirm button."""
    def __init__(self):
        super().__init__(timeout=120)
        self.boss_role: discord.Role | None = None
        self.controlled_role: discord.Role | None = None
        self.add_item(SetupBossRoleSelect())
        self.add_item(SetupControlledRoleSelect())

    @discord.ui.button(
        label="✅ Confirm Setup",
        style=discord.ButtonStyle.success,
        row=2
    )
    async def confirm(self, interaction: discord.Interaction, button: discord.ui.Button):
        if not self.boss_role or not self.controlled_role:
            return await interaction.response.send_message(
                "❌ Please select **both** roles before confirming.",
                ephemeral=True
            )

        if self.boss_role.id == self.controlled_role.id:
            return await interaction.response.send_message(
                "❌ The boss role and the controlled role cannot be the same.",
                ephemeral=True
            )

        gc = guild_config(interaction.guild.id)
        gc[str(self.controlled_role.id)] = str(self.boss_role.id)
        save_data(CONFIG)

        print(f"✅ Setup via panel: Request role '{self.controlled_role.name}' -> Approver role '{self.boss_role.name}'")

        embed = discord.Embed(
            title="✅ Configuration Saved!",
            description=f"Users can now request **{self.controlled_role.mention}**",
            color=COL_SUCCESS
        )
        embed.add_field(
            name="Approvers",
            value=f"Anyone with {self.boss_role.mention} role",
            inline=False
        )

        # Disable the view so the dropdowns can't be reused
        for item in self.children:
            item.disabled = True

        await interaction.response.edit_message(embed=embed, view=self)
        await post_panel(interaction.guild)

    @discord.ui.button(
        label="🗑️ Cancel",
        style=discord.ButtonStyle.secondary,
        row=2
    )
    async def cancel(self, interaction: discord.Interaction, button: discord.ui.Button):
        for item in self.children:
            item.disabled = True
        cancel_embed = discord.Embed(
            title="❌ Setup Cancelled",
            color=COL_DANGER
        )
        await interaction.response.edit_message(embed=cancel_embed, view=self)


# ───────────────── REQUEST ACTIONS ─────────────────

class RequestActions(discord.ui.View):
    def __init__(self, user, role, thread, approver_role_id):
        super().__init__(timeout=None)
        self.user = user
        self.role = role
        self.thread = thread
        self.approver_role_id = clean_approver_id(approver_role_id)
        self.message = None

    def allowed(self, interaction: discord.Interaction):
        if not self.approver_role_id:
            return interaction.user.guild_permissions.administrator
            
        try:
            approver_role = interaction.guild.get_role(int(self.approver_role_id))
            if not approver_role:
                return interaction.user.guild_permissions.administrator
            
            return (
                interaction.user.guild_permissions.administrator
                or approver_role in interaction.user.roles
            )
        except ValueError:
            return interaction.user.guild_permissions.administrator

    @discord.ui.button(label="Approve", style=discord.ButtonStyle.success)
    async def approve(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer(ephemeral=True)

        if not self.allowed(interaction):
            return await interaction.followup.send("❌ You don't have permission to approve this request.", ephemeral=True)

        try:
            await self.user.add_roles(self.role)
        except discord.Forbidden:
            return await interaction.followup.send(
                "❌ Missing permission to assign this role.",
                ephemeral=True
            )

        await self.message.edit(
            embed=status_embed(self.user, self.role, "approved"),
            view=self
        )

        await self.thread.send(f"✅ Approved by {interaction.user.mention}")
        
        try:
            approve_embed = discord.Embed(
                title="✅ Role Request Approved",
                description=f"Your request for {self.role.mention} has been approved!",
                color=COL_SUCCESS,
                timestamp=datetime.now(timezone.utc)
            )
            approve_embed.add_field(name="Role", value=self.role.name, inline=True)
            approve_embed.add_field(name="Server", value=interaction.guild.name, inline=True)
            approve_embed.add_field(name="Approved by", value=interaction.user.mention, inline=True)
            await self.user.send(embed=approve_embed)
        except discord.Forbidden:
            pass

    @discord.ui.button(label="Deny", style=discord.ButtonStyle.danger)
    async def deny(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer(ephemeral=True)

        if not self.allowed(interaction):
            return await interaction.followup.send("❌ You don't have permission to deny this request.", ephemeral=True)

        await self.message.edit(
            embed=status_embed(self.user, self.role, "denied"),
            view=self
        )

        await self.thread.send(f"❌ Denied by {interaction.user.mention}")
        
        try:
            deny_embed = discord.Embed(
                title="❌ Role Request Denied",
                description=f"Your request for {self.role.mention} has been denied.",
                color=COL_DANGER,
                timestamp=datetime.now(timezone.utc)
            )
            deny_embed.add_field(name="Role", value=self.role.name, inline=True)
            deny_embed.add_field(name="Server", value=interaction.guild.name, inline=True)
            deny_embed.add_field(name="Denied by", value=interaction.user.mention, inline=True)
            await self.user.send(embed=deny_embed)
        except discord.Forbidden:
            pass

# ───────────────── PANEL POST ─────────────────

async def post_panel(guild):
    channel = guild.get_channel(REQUEST_CHANNEL_ID)
    if not channel:
        print("Panel channel not found")
        return

    async for msg in channel.history(limit=50):
        if msg.author == bot.user and msg.embeds:
            await msg.edit(embed=panel_embed(), view=PanelView())
            return

    await channel.send(embed=panel_embed(), view=PanelView())

# ───────────────── SETUP COMMAND WITH AUTOCOMPLETE ─────────────────

@bot.tree.command(name="setup")
@app_commands.describe(
    requested_role="The role users can request",
    approver_role="The role that can approve requests"
)
@app_commands.autocomplete(
    requested_role=role_autocomplete,
    approver_role=role_autocomplete
)
@app_commands.checks.has_permissions(administrator=True)
async def setup(
    interaction: discord.Interaction, 
    requested_role: str, 
    approver_role: str
):
    """Setup role request configuration with searchable autocomplete"""
    
    guild = interaction.guild
    
    try:
        req_role_id = int(requested_role)
        app_role_id = int(approver_role)
    except ValueError:
        return await interaction.response.send_message("❌ Invalid role selection.", ephemeral=True)
    
    req_role = guild.get_role(req_role_id)
    app_role = guild.get_role(app_role_id)
    
    if not req_role or not app_role:
        return await interaction.response.send_message("❌ One or both roles not found.", ephemeral=True)
    
    gc = guild_config(guild.id)
    gc[str(req_role_id)] = str(app_role_id)
    save_data(CONFIG)
    
    print(f"✅ Saved: Request role '{req_role.name}' -> Approver role '{app_role.name}'")
    
    embed = discord.Embed(
        title="✅ Configuration Saved!",
        description=f"Users can now request **{req_role.mention}**",
        color=COL_SUCCESS
    )
    embed.add_field(name="Approvers", value=f"Anyone with {app_role.mention} role", inline=False)
    
    await interaction.response.send_message(embed=embed, ephemeral=True)
    
    await post_panel(guild)

# ───────────────── SETUP PANEL COMMAND ─────────────────

@bot.tree.command(name="setup_panel")
@app_commands.checks.has_permissions(administrator=True)
async def setup_panel_cmd(interaction: discord.Interaction):
    """Interactively configure a new role via dropdowns"""
    embed = discord.Embed(
        title="⚙️ Role Request Setup",
        description=(
            "Use the dropdowns below to configure a new requestable role.\n\n"
            "**Step 1 — Boss Role:** Pick who can approve requests for this role.\n"
            "**Step 2 — Controlled Role:** Pick the role users will be able to request.\n\n"
            "Then hit **Confirm Setup** to save."
        ),
        color=COL_PRIMARY
    )
    await interaction.response.send_message(embed=embed, view=SetupPanelView(), ephemeral=True)


# ───────────────── OTHER COMMANDS ─────────────────

@bot.tree.command(name="refresh_panel")
@app_commands.checks.has_permissions(administrator=True)
async def refresh(interaction: discord.Interaction):
    """Refresh the role request panel"""
    await post_panel(interaction.guild)
    await interaction.response.send_message("✅ Panel refreshed!", ephemeral=True)

@bot.tree.command(name="request")
async def request_cmd(interaction: discord.Interaction):
    """Get a link to the role request panel"""
    channel = interaction.guild.get_channel(REQUEST_CHANNEL_ID)
    if channel:
        await interaction.response.send_message(
            f"📋 Please go to {channel.mention} to request a role!",
            ephemeral=True
        )
    else:
        await interaction.response.send_message(
            "❌ Request channel not found. Please contact an administrator.",
            ephemeral=True
        )

@bot.tree.command(name="list_configs")
@app_commands.checks.has_permissions(administrator=True)
async def list_configs(interaction: discord.Interaction):
    """List all configured role requests"""
    gc = guild_config(interaction.guild.id)
    
    if not gc:
        return await interaction.response.send_message("No configurations found.", ephemeral=True)
    
    embed = discord.Embed(
        title="📋 Role Request Configurations",
        color=COL_PRIMARY
    )
    
    for req_role_id, app_role_id in gc.items():
        req_role = interaction.guild.get_role(int(req_role_id))
        app_role = interaction.guild.get_role(int(app_role_id))
        
        req_name = req_role.name if req_role else f"Unknown ({req_role_id})"
        app_name = app_role.name if app_role else f"Unknown ({app_role_id})"
        
        embed.add_field(
            name=req_name,
            value=f"Approvers: {app_name}",
            inline=False
        )
    
    await interaction.response.send_message(embed=embed, ephemeral=True)

@bot.tree.command(name="remove_config")
@app_commands.describe(role="The role to remove from configuration")
@app_commands.autocomplete(role=role_autocomplete)
@app_commands.checks.has_permissions(administrator=True)
async def remove_config(interaction: discord.Interaction, role: str):
    """Remove a role request configuration"""
    gc = guild_config(interaction.guild.id)
    
    if role in gc:
        del gc[role]
        save_data(CONFIG)
        
        role_obj = interaction.guild.get_role(int(role))
        role_name = role_obj.name if role_obj else role
        
        await interaction.response.send_message(f"✅ Removed configuration for **{role_name}**", ephemeral=True)
        await post_panel(interaction.guild)
    else:
        await interaction.response.send_message(f"❌ No configuration found for that role.", ephemeral=True)

@bot.tree.command(name="fix_config")
@app_commands.checks.has_permissions(administrator=True)
async def fix_config(interaction: discord.Interaction):
    """Fix corrupted config data"""
    gc = guild_config(interaction.guild.id)
    fixed = {}
    
    for role_id, approver_role_id in gc.items():
        cleaned = clean_approver_id(approver_role_id)
        if cleaned:
            fixed[role_id] = cleaned
            print(f"Fixed: {role_id} -> {approver_role_id} becomes {cleaned}")
    
    CONFIG[str(interaction.guild.id)] = fixed
    save_data(CONFIG)
    
    await interaction.response.send_message(
        f"✅ Fixed {len(fixed)} role configurations!",
        ephemeral=True
    )

# ───────────────── START ─────────────────

@bot.event
async def on_ready():
    await bot.tree.sync()
    print(f"✅ Logged in as {bot.user}")
    print(f"📊 Connected to {len(bot.guilds)} guild(s)")

    for g in bot.guilds:
        print(f"   - {g.name} (ID: {g.id})")
        await post_panel(g)

bot.run(TOKEN)