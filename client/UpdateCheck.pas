{*******************************************************}
{                                                       }
{       Update Check Unit for SOLDAT                    }
{                                                       }
{       Looks up the latest release of the remix on     }
{       GitHub, once per start                          }
{                                                       }
{*******************************************************}

unit UpdateCheck;

interface

// Starts the check in background.
procedure StartUpdateCheck;
// True when a newer release than REMIX_VERSION was found.
function UpdateAvailable(out Tag, URL: string): Boolean;

implementation

uses
  Classes, SysUtils, SyncObjs, Math, fphttpclient,
  {$IF FPC_FULLVERSION >= 30200}opensslsockets,{$ENDIF} fpjson, jsonparser, Version;

const
  RELEASES_URL = 'https://api.github.com/repos/okkindel/soldat-linux/releases/latest';

type
  TUpdateThread = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Lock: TCriticalSection;
  Thread: TUpdateThread;
  LatestTag, LatestURL: string;

// "r1.2.0", "v1.2" or "1.2.0" -> [1, 2, 0]
function VersionNumbers(const Version: string): TStringArray;
var
  s: string;
begin
  s := Version;
  while (s <> '') and not (s[1] in ['0'..'9']) do
    Delete(s, 1, 1);
  Result := s.Split(['.']);
end;

function IsNewer(const Latest, Current: string): Boolean;
var
  a, b: TStringArray;
  i, x, y: Integer;
begin
  a := VersionNumbers(Latest);
  b := VersionNumbers(Current);
  for i := 0 to Max(High(a), High(b)) do
  begin
    x := 0;
    y := 0;
    if i <= High(a) then
      x := StrToIntDef(a[i], 0);
    if i <= High(b) then
      y := StrToIntDef(b[i], 0);
    if x <> y then
      Exit(x > y);
  end;
  Result := False;
end;

procedure TUpdateThread.Execute;
var
  Http: TFPHTTPClient;
  Root: TJSONData;
begin
  Http := TFPHTTPClient.Create(nil);
  try
    try
      // GitHub requires a user agent
      Http.AddHeader('User-Agent', 'soldat-linux/' + REMIX_VERSION);
      Http.ConnectTimeout := 10000;
      Http.IOTimeout := 10000;
      Root := GetJSON(Http.Get(RELEASES_URL));
      try
        if Root is TJSONObject then
        begin
          Lock.Enter;
          try
            LatestTag := TJSONObject(Root).Get('tag_name', '');
            LatestURL := TJSONObject(Root).Get('html_url', '');
          finally
            Lock.Leave;
          end;
        end;
      finally
        Root.Free;
      end;
    except
      // no network or no release, nothing to show
    end;
  finally
    Http.Free;
  end;
end;

procedure StartUpdateCheck;
begin
  if Thread = nil then
    Thread := TUpdateThread.Create(False);
end;

function UpdateAvailable(out Tag, URL: string): Boolean;
begin
  Lock.Enter;
  try
    Tag := LatestTag;
    URL := LatestURL;
  finally
    Lock.Leave;
  end;
  Result := (Tag <> '') and IsNewer(Tag, REMIX_VERSION);
end;

initialization
  Lock := TCriticalSection.Create;

finalization
  // quitting doesn't wait for a slow network, the process ends anyway
  if (Thread <> nil) and Thread.Finished then
  begin
    Thread.Free;
    Lock.Free;
  end;
end.
