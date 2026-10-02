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

UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\StockToolKiosk.exe

SetupIconFile=icon.ico

DisableProgramGroupPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]

Source: "..\dist\StockToolKiosk.exe"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

Source: "SetupWizard.ps1"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

Source: "{#NssmPath}"; \
    DestDir: "{app}"; \
    DestName: "nssm.exe"; \
    Flags: ignoreversion

Source: "..\license.txt"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

[Dirs]
Name: "{app}"

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

[Tasks]
Name: "desktopicon"
Description: "Create a desktop shortcut"
GroupDescription: "Additional shortcuts:"
Flags: unchecked

[Run]

Filename: "{app}\StockToolKiosk.exe"
Description: "Launch StockTool Kiosk"
Flags: nowait postinstall skipifsilent

[UninstallDelete]

Type: filesandordirs
Name: "{app}"

[Code]

function PrepareToInstall(
  var NeedsRestart: Boolean
): String;
begin
  Result := '';

  if FileExists(ExpandConstant('{app}\StockToolKiosk.exe')) then
  begin
    Exec(
      ExpandConstant('{sys}\taskkill.exe'),
      '/F /IM StockToolKiosk.exe',
      '',
      SW_HIDE,
      ewWaitUntilTerminated,
      NeedsRestart
    );
  end;
end;