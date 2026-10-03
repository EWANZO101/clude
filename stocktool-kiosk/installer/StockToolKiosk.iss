#define MyAppName "StockTool Kiosk"
#define MyAppPublisher "OpsLab Systems"
#define MyAppExeName "StockToolKiosk.exe"

#ifndef MyAppVersion
#define MyAppVersion "2.2.0"
#endif

#ifndef NssmPath
#define NssmPath "nssm.exe"
#endif

[Setup]
AppId={{1915E8F3-4602-4CF8-8038-BA346FAD23CA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}

DefaultDirName={autopf}\StockTool Kiosk
DefaultGroupName=StockTool Kiosk

OutputDir=..\dist\installer
OutputBaseFilename=StockToolKiosk-Setup-{#MyAppVersion}

Compression=lzma
SolidCompression=yes

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

PrivilegesRequired=admin

WizardStyle=modern
WizardResizable=no

Uninstallable=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\StockToolKiosk.exe

SetupIconFile=icon.ico

DisableProgramGroupPage=yes

CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"
Description: "Create a desktop shortcut"
GroupDescription: "Additional shortcuts:"
Flags: unchecked

[Files]
Source: "..\dist\StockToolKiosk.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "SetupWizard.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "StartKiosk.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "StopKiosk.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "UninstallCleanup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#NssmPath}"; DestDir: "{app}"; DestName: "nssm.exe"; Flags: ignoreversion
Source: "..\license.txt"; DestDir: "{app}"; Flags: ignoreversion

; Optional Cloudflare executable.
; If it exists beside this .iss file it will be installed.
Source: "cloudflared.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; Optional application assets.
Source: "assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\StockTool Kiosk\StockTool Kiosk"
Filename: "{app}\StockToolKiosk.exe"
WorkingDir: "{app}"

Name: "{autoprograms}\StockTool Kiosk\StockTool Kiosk Setup"
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"
Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\SetupWizard.ps1"""
WorkingDir: "{app}"

Name: "{autoprograms}\StockTool Kiosk\Uninstall StockTool Kiosk"
Filename: "{uninstallexe}"

Name: "{commondesktop}\StockTool Kiosk"
Filename: "{app}\StockToolKiosk.exe"
WorkingDir: "{app}"
Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"
Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\SetupWizard.ps1"" -Silent"
WorkingDir: "{app}"
Description: "Configure and start StockTool Kiosk service"
StatusMsg: "Configuring StockTool Kiosk service..."
Flags: postinstall waituntilterminated

[UninstallDelete]
Type: filesandordirs
Name: "{app}"