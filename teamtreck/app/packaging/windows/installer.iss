; Inno Setup script for the TeamTreck Agent (Windows).
; NOT RUN/COMPILED IN THIS SANDBOX - Inno Setup (iscc.exe) is a Windows-only
; tool, not available here. This has been written against Inno Setup 6
; syntax but its first real compile still needs to happen on a Windows
; machine with Inno Setup installed (https://jrsoftware.org/isinfo.php).
;
; Build with:  iscc packaging\windows\installer.iss
; (run AFTER packaging\windows\build_windows.bat has produced dist\teamtreck-agent.exe)
;
; What this does:
;   - Installs teamtreck-agent.exe to Program Files
;   - Adds a Start Menu shortcut and an optional Desktop shortcut
;   - Adds a Startup-folder shortcut so the agent runs on login (checkbox,
;     off by default - see the [Tasks] section)
;   - Runs `teamtreck-agent setup` in a console window right after install
;     so the user enters their server URL + token immediately
;   - Opens the browser-extension folder in Explorer at the end, with a
;     message pointing at the Chrome/Edge "Load unpacked" flow, since this
;     extension isn't published to a web store (see TODO.txt)

#define MyAppName "TeamTreck Agent"
#define MyAppVersion "0.18.0"
#define MyAppPublisher "TeamTreck"
#define MyAppExeName "teamtreck-agent.exe"

[Setup]
AppId={{8F2B2C2E-7B3A-4E7E-9C1B-TEAMTRECK0001}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\TeamTreck Agent
DefaultGroupName=TeamTreck Agent
DisableProgramGroupPage=yes
OutputDir=..\..\dist\installer
OutputBaseFilename=teamtreck-agent-setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
; No code-signing certificate is configured here - see TODO.txt.
; Unsigned installers trigger a Windows SmartScreen warning on first run.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"
Name: "startup"; Description: "Start TeamTreck Agent automatically when I log in"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "..\..\dist\teamtreck-agent.exe"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; Flags: ignoreversion
Source: "..\..\browser-extension\*"; DestDir: "{app}\browser-extension"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\TeamTreck Agent"; Filename: "{app}\{#MyAppExeName}"; Parameters: "run"
Name: "{group}\Uninstall TeamTreck Agent"; Filename: "{uninstallexe}"
Name: "{autodesktop}\TeamTreck Agent"; Filename: "{app}\{#MyAppExeName}"; Parameters: "run"; Tasks: desktopicon
Name: "{userstartup}\TeamTreck Agent"; Filename: "{app}\{#MyAppExeName}"; Parameters: "run"; Tasks: startup

[Run]
; First-run setup: opens a console so the user can paste server URL + token.
Filename: "{cmd}"; Parameters: "/K ""{app}\{#MyAppExeName}"" setup"; Description: "Run first-time setup now"; Flags: postinstall runascurrentuser
; Point the user at the browser extension, since it isn't on the Chrome Web Store.
Filename: "{win}\explorer.exe"; Parameters: """{app}\browser-extension"""; Description: "Open the browser extension folder (load it via chrome://extensions -> Load unpacked)"; Flags: postinstall shellexec unchecked
