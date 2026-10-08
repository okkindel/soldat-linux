{*******************************************************}
{                                                       }
{       Legacy Download Unit for SOLDAT                 }
{                                                       }
{       Downloads the official native Soldat 1.7 Linux  }
{       client on first use, for packages that don't    }
{       ship it                                         }
{                                                       }
{*******************************************************}

unit LegacyDownload;

interface

type
  TLegacyDownloadState = (ldsIdle, ldsRunning, ldsDone, ldsFailed);

// Downloads and unpacks the client into TargetDir (its soldat_x64 ends up
// at TargetDir + 'soldat_x64'). Runs in the background.
procedure StartLegacyDownload(const TargetDir: string);
function LegacyDownloadState: TLegacyDownloadState;
// 0..100 while downloading
function LegacyDownloadProgress: Integer;
function LegacyDownloadError: string;

implementation

uses
  Classes, SysUtils, SyncObjs, BaseUnix, fphttpclient,
  {$IF FPC_FULLVERSION >= 30200}opensslsockets,{$ENDIF} sha1, Zipper, Version;

const
  // the build linked from https://wiki.soldat.pl/index.php/Soldat_on_macOS_and_Linux
  LEGACY_URL = 'https://update.soldat.pl/updates/soldat_linux.zip';
  LEGACY_SHA1 = '328ea0cbc0e72c8d095082ac0a552f40a75a6b31';
  // directory inside the archive
  ARCHIVE_ROOT = 'soldat_linux/';

type
  TLegacyDownloadThread = class(TThread)
  private
    FTargetDir: string;
    FHttp: TFPHTTPClient;
    procedure DataReceived(Sender: TObject; const ContentLength, CurrentPos: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(const TargetDir: string);
    // stops a running download, e.g. when the game quits
    procedure Cancel;
  end;

var
  Lock: TCriticalSection;
  Thread: TLegacyDownloadThread;
  State: TLegacyDownloadState = ldsIdle;
  Progress: Integer;
  ErrorText: string;

procedure SetState(NewState: TLegacyDownloadState; const Error: string = '');
begin
  Lock.Enter;
  try
    State := NewState;
    ErrorText := Error;
  finally
    Lock.Leave;
  end;
end;

constructor TLegacyDownloadThread.Create(const TargetDir: string);
begin
  FTargetDir := IncludeTrailingPathDelimiter(TargetDir);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TLegacyDownloadThread.Cancel;
begin
  Terminate;
  Lock.Enter;
  try
    if FHttp <> nil then
      FHttp.Terminate;
  finally
    Lock.Leave;
  end;
end;

procedure TLegacyDownloadThread.DataReceived(Sender: TObject; const ContentLength, CurrentPos: Int64);
begin
  if ContentLength > 0 then
  begin
    Lock.Enter;
    Progress := Round(100 * CurrentPos / ContentLength);
    Lock.Leave;
  end;
end;

procedure TLegacyDownloadThread.Execute;
var
  Http: TFPHTTPClient;
  Archive, Unpacked: string;
  UnZipper: TUnZipper;
  Files: TStringList;
  i: Integer;
begin
  Archive := ExcludeTrailingPathDelimiter(FTargetDir) + '.zip.part';
  Unpacked := ExcludeTrailingPathDelimiter(FTargetDir) + '.unpack' + PathDelim;
  Http := TFPHTTPClient.Create(nil);
  Lock.Enter;
  FHttp := Http;
  Lock.Leave;
  UnZipper := TUnZipper.Create;
  Files := TStringList.Create;
  try
    try
      ForceDirectories(ExtractFilePath(Archive));
      Http.AddHeader('User-Agent', 'soldatclient/' + SOLDAT_VERSION);
      Http.AllowRedirect := True;
      Http.ConnectTimeout := 15000;
      Http.IOTimeout := 30000;
      Http.OnDataReceived := DataReceived;
      Http.Get(LEGACY_URL, Archive);
      if Terminated then
        raise Exception.Create('cancelled');

      if SHA1Print(SHA1File(Archive)) <> LEGACY_SHA1 then
        raise Exception.Create('checksum of the downloaded archive does not match');

      // everything except the launcher and the server, which aren't used
      UnZipper.FileName := Archive;
      UnZipper.OutputPath := Unpacked;
      UnZipper.Examine;
      for i := 0 to UnZipper.Entries.Count - 1 do
        if (Pos('AppImage', UnZipper.Entries[i].ArchiveFileName) = 0) and
          (Pos('soldatserver', UnZipper.Entries[i].ArchiveFileName) = 0) then
          Files.Add(UnZipper.Entries[i].ArchiveFileName);
      UnZipper.UnZipFiles(Files);

      if not FileExists(Unpacked + ARCHIVE_ROOT + 'soldat_x64') then
        raise Exception.Create('unexpected archive contents');
      FpChmod(Unpacked + ARCHIVE_ROOT + 'soldat_x64', &755);

      // never overwrite an existing client (and its configs)
      if DirectoryExists(FTargetDir) then
        raise Exception.Create(FTargetDir + ' already exists');
      if not RenameFile(Unpacked + ARCHIVE_ROOT, ExcludeTrailingPathDelimiter(FTargetDir)) then
        raise Exception.Create('could not move the client to ' + FTargetDir);

      SetState(ldsDone);
    except
      on E: Exception do
        SetState(ldsFailed, E.Message);
    end;
  finally
    DeleteFile(Archive);
    RemoveDir(Unpacked);
    Files.Free;
    UnZipper.Free;
    Lock.Enter;
    FHttp := nil;
    Lock.Leave;
    Http.Free;
  end;
end;

procedure StartLegacyDownload(const TargetDir: string);
begin
  if LegacyDownloadState = ldsRunning then
    Exit;
  if Thread <> nil then
  begin
    Thread.WaitFor;
    FreeAndNil(Thread);
  end;

  Lock.Enter;
  Progress := 0;
  Lock.Leave;
  SetState(ldsRunning);
  Thread := TLegacyDownloadThread.Create(TargetDir);
end;

function LegacyDownloadState: TLegacyDownloadState;
begin
  Lock.Enter;
  Result := State;
  Lock.Leave;
end;

function LegacyDownloadProgress: Integer;
begin
  Lock.Enter;
  Result := Progress;
  Lock.Leave;
end;

function LegacyDownloadError: string;
begin
  Lock.Enter;
  Result := ErrorText;
  Lock.Leave;
end;

initialization
  Lock := TCriticalSection.Create;

finalization
  if Thread <> nil then
  begin
    Thread.Cancel;
    Thread.WaitFor;
    Thread.Free;
  end;
  Lock.Free;
end.
