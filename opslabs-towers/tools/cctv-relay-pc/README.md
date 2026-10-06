# CCTV relay PC (keeps OPS Hub's cameras live with nobody else on)

A camera's picture can only be drawn by a real copy of GTA V. There is no way to draw it on the
Linux game server (no GTA, no graphics card), so the "bot" is one game client left running on any
Windows PC or a Windows cloud PC with a GPU.

1. A spare Rockstar / FiveM account on that PC (any normal one).
2. Put its identifier in `opslabs-towers/config.lua` → `Config.Cctv.RelayAccounts`, e.g.
   `RelayAccounts = { 'license:abc123…' }` (txAdmin → Players → the account → Identifiers), and restart opslabs-towers.
   That account starts relaying by itself every time it joins — nobody types `/cctvrelay`.
3. Copy `relay-loop.bat` to the PC and put a shortcut to it in `shell:startup`. It starts FiveM, joins the
   city, and rejoins after a crash, a kick or a server restart.
4. In Windows: power plan → never sleep; GTA graphics on low (the pictures are 1280×720 at most).
5. **GTA V Legacy, not Enhanced**, and Settings → Graphics → Screen Type **Windowed Borderless** (don't switch it while
   playing). FiveM can't hand the game picture to scripts on GTA V Enhanced, and a fullscreen ↔ borderless switch breaks it
   until FiveM restarts — the relay then sends nothing and shows a red notice saying so.

Any player who has run `/cctvrelay` once also resumes relaying by itself after a restart or reconnect, until they
switch it off with `/cctvrelay` or BACKSPACE.
