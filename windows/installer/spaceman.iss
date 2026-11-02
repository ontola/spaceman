; Inno Setup script for the Windows installer. CI builds it with
;   iscc /DAppVersion=0.1.0 windows\installer\spaceman.iss
; after `flutter build windows --release`.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Keep AppId fixed: Windows uses it to recognise upgrades and the uninstaller.
AppId={{2B6E8E87-06E4-4A7A-9915-1DE77E8A7F76}
AppName=SpaceMan
AppVersion={#AppVersion}
AppVerName=SpaceMan {#AppVersion}
AppPublisher=Ontola
AppPublisherURL=https://github.com/ontola/spaceman
AppSupportURL=https://github.com/ontola/spaceman/issues
DefaultDirName={autopf}\SpaceMan
DefaultGroupName=SpaceMan
DisableProgramGroupPage=yes
; Installs for the current user without an admin prompt; the dialog lets
; people choose an install for all users instead.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\SpaceMan.exe
OutputDir=..\..\build\installer
OutputBaseFilename=SpaceMan-Windows-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\SpaceMan"; Filename: "{app}\SpaceMan.exe"
Name: "{autodesktop}\SpaceMan"; Filename: "{app}\SpaceMan.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SpaceMan.exe"; Description: "{cm:LaunchProgram,SpaceMan}"; Flags: nowait postinstall skipifsilent
