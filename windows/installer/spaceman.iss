; Inno Setup script for the Windows installer. CI builds it with
;   iscc /DAppVersion=<version> /DSourceDir=<Release folder> windows\installer\spaceman.iss
; Installs per user (no admin prompt) into %LOCALAPPDATA%\Programs\SpaceMan,
; with a Start menu entry and an uninstaller in Settings > Apps.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6F1D2B7E-5C3A-4E8B-9A41-2B7D0C5E9F13}
AppName=SpaceMan
AppVersion={#AppVersion}
AppPublisher=Ontola
AppPublisherURL=https://github.com/ontola/spaceman
DefaultDirName={autopf}\SpaceMan
DefaultGroupName=SpaceMan
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..
OutputBaseFilename=SpaceMan-Windows-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\SpaceMan.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\SpaceMan"; Filename: "{app}\SpaceMan.exe"
Name: "{autodesktop}\SpaceMan"; Filename: "{app}\SpaceMan.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SpaceMan.exe"; Description: "{cm:LaunchProgram,SpaceMan}"; Flags: nowait postinstall skipifsilent
