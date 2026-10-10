; Інсталятор Потягуся для Windows (Inno Setup 6.3+).
; Збирається з installer/windows/build.ps1 або воркфлоу .github/workflows/windows-installer.yml.
; Ставиться в профіль користувача (%LOCALAPPDATA%\Programs\Potyagus), без прав адміністратора.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\dist\windows\publish"
#endif
#ifndef AppExe
  #define AppExe "Potyagus.exe"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist\windows"
#endif

[Setup]
AppId={{6BA3AE6C-7A5C-451D-B571-7653B81CC1C8}
AppName=Потягусь
AppVersion={#AppVersion}
AppVerName=Потягусь {#AppVersion}
AppPublisher=Alina Uvarova
AppPublisherURL=https://potyagus.alinauvarova.com
AppSupportURL=https://github.com/uvallie/Potyagus
DefaultDirName={autopf}\Potyagus
DefaultGroupName=Потягусь
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Potyagus-{#AppVersion}-Setup
SetupIconFile=..\..\windows\potyagus.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=Потягусь
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
uk.AutoStart=Запускати Потягуся при вході в Windows
en.AutoStart=Start Potyagus when I sign in to Windows
uk.WebView2Failed=Не вдалося встановити Microsoft Edge WebView2, без нього гусь не покажеться. Постав його вручну: https://developer.microsoft.com/microsoft-edge/webview2/
en.WebView2Failed=Could not install Microsoft Edge WebView2, which Potyagus needs. Install it manually: https://developer.microsoft.com/microsoft-edge/webview2/

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Потягусь"; Filename: "{app}\{#AppExe}"

[Registry]
; Те саме значення, яке перемикає «Вимкнути автозапуск» у меню трею.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Potyagus"; ValueData: """{app}\{#AppExe}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Потягусь}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "StopPotyagus"

[UninstallDelete]
; Профіль WebView2 шелла. Історія й налаштування в %APPDATA%\Potyagus лишаються.
Type: filesandordirs; Name: "{localappdata}\Potyagus\WebView2"

[Code]
const
  WebView2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  WebView2Url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

var
  DownloadPage: TDownloadWizardPage;

function HasVersion(RootKey: Integer; SubKey: String): Boolean;
var
  V: String;
begin
  Result := RegQueryStringValue(RootKey, SubKey, 'pv', V) and (V <> '') and (V <> '0.0.0.0');
end;

function WebView2Installed: Boolean;
begin
  Result := HasVersion(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' + WebView2Guid);
  if not Result then
    Result := HasVersion(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WebView2Guid);
  if not Result then
    Result := HasVersion(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\' + WebView2Guid);
end;

procedure InstallWebView2;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

// WebView2 є у Windows 11 і в оновленій Windows 10. Якщо його нема, тихо ставимо bootstrapper від Microsoft.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID <> wpReady) or WebView2Installed then
    exit;
  DownloadPage.Clear;
  DownloadPage.Add(WebView2Url, 'MicrosoftEdgeWebview2Setup.exe', '');
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
      InstallWebView2;
    except
      Log('WebView2: ' + GetExceptionMessage);
    end;
  finally
    DownloadPage.Hide;
  end;
  if not WebView2Installed then
    SuppressibleMsgBox(CustomMessage('WebView2Failed'), mbError, MB_OK, IDOK);
end;

// Гусь живе в треї без вікна, і Restart Manager не вміє його закрити, тож при оновленні зупиняємо його самі.
// У тихому режимі (/VERYSILENT) сторінок майстра немає, тож WebView2 докачуємо тут, без прогрес-бару.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode = 0 then
    Sleep(500);
  if not WizardSilent or WebView2Installed then
    exit;
  try
    DownloadTemporaryFile(WebView2Url, 'MicrosoftEdgeWebview2Setup.exe', '', nil);
    InstallWebView2;
  except
    Log('WebView2: ' + GetExceptionMessage);
  end;
end;
