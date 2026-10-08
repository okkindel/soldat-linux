{*******************************************************}
{                                                       }
{       Server List Unit for SOLDAT                     }
{                                                       }
{       Fetches the public server list, and the players }
{       of a server, from the lobby                     }
{                                                       }
{*******************************************************}

unit ServerList;

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TServerEntry = record
    Name: string;
    IP: string;
    Port: Integer;
    GameStyle: string;
    CurrentMap: string;
    NumPlayers: Integer;
    MaxPlayers: Integer;
    NumBots: Integer;
    Version: string;
    Country: string;
    OS: string;
    Info: string;
    IsPrivate: Boolean;
    Realistic: Boolean;
    Survival: Boolean;
    Advanced: Boolean;
  end;

  TServerEntries = array of TServerEntry;

  TServerListStatus = (slsIdle, slsLoading, slsDone, slsError);

  TServerListThread = class(TThread)
  private
    FURL: string;
    procedure MeasurePings(const Servers: TServerEntries);
  protected
    procedure Execute; override;
  public
    constructor Create(URL: string);
  end;

const
  PING_PENDING = -1;
  PING_FAILED  = -2;

// Starts fetching the server list in background (no-op if already loading).
procedure RefreshServerList;
// Copies the most recently fetched list if a fetch has finished since the last
// call. Returns True when Servers was updated.
function PollServerList(var Servers: TServerEntries): Boolean;
function ServerListStatus: TServerListStatus;
function ServerListError: string;
// Round trip estimate in ms for ip:port, or PING_PENDING / PING_FAILED.
function ServerPing(const Key: string): Integer;
// Asks the lobby for the players of a server (one request at a time, the
// latest one waits for the running one).
procedure RequestServerPlayers(const Server: TServerEntry);
// Names of the players on ip:port (bots included). False until fetched.
function ServerPlayers(const Key: string; out Names: TStringArray): Boolean;
procedure FreeServerList;

implementation

uses
  fphttpclient, {$IF FPC_FULLVERSION >= 30200}opensslsockets,{$ENDIF}
  fpjson, jsonparser, ssockets, Version, Client;

const
  PING_TIMEOUT = 1500;
  PING_WORKERS = 16;

type
  // Servers don't answer ICMP for us (no root), so the ping is the time it
  // takes to open a TCP connection to the game port, which Soldat servers
  // listen on for remote administration.
  TPingWorker = class(TThread)
  private
    FServers: TServerEntries;
  protected
    procedure Execute; override;
  public
    constructor Create(const Servers: TServerEntries);
  end;

  TPlayersThread = class(TThread)
  private
    FServer: TServerEntry;
    FURL: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const Server: TServerEntry; const URL: string);
  end;

var
  Lock: TCriticalSection;
  Thread: TServerListThread;
  Status: TServerListStatus = slsIdle;
  ErrorText: string;
  Fetched: TServerEntries;
  HasNewData: Boolean;
  Pings: TStringList; // "ip:port" -> ms
  NextPing: LongInt;
  // "ip:port" -> '|' followed by the names separated by tabs
  PlayerLists: TStringList;
  PlayersThread: TPlayersThread;
  PendingPlayers: TServerEntry;
  HasPendingPlayers: Boolean;

function ParseServers(const Json: string): TServerEntries;
var
  Root: TJSONData;
  List: TJSONArray;
  Obj: TJSONObject;
  i, n: Integer;
begin
  Result := nil;
  Root := GetJSON(Json);
  try
    if not (Root is TJSONObject) then
      raise Exception.Create('Unexpected server list format');

    List := TJSONObject(Root).Arrays['Servers'];
    SetLength(Result, List.Count);
    n := 0;

    for i := 0 to List.Count - 1 do
    begin
      if not (List.Items[i] is TJSONObject) then
        Continue;
      Obj := TJSONObject(List.Items[i]);

      Result[n].Name := Trim(Obj.Get('Name', ''));
      Result[n].IP := Obj.Get('IP', '');
      Result[n].Port := Obj.Get('Port', 0);
      Result[n].GameStyle := Obj.Get('GameStyle', '');
      Result[n].CurrentMap := Obj.Get('CurrentMap', '');
      Result[n].NumPlayers := Obj.Get('NumPlayers', 0);
      Result[n].MaxPlayers := Obj.Get('MaxPlayers', 0);
      Result[n].NumBots := Obj.Get('NumBots', 0);
      Result[n].Version := Obj.Get('Version', '');
      Result[n].Country := Obj.Get('Country', '');
      Result[n].OS := Obj.Get('OS', '');
      Result[n].Info := Obj.Get('Info', '');
      Result[n].IsPrivate := Obj.Get('Private', False);
      Result[n].Realistic := Obj.Get('Realistic', False);
      Result[n].Survival := Obj.Get('Survival', False);
      Result[n].Advanced := Obj.Get('Advanced', False);

      if (Result[n].IP <> '') and (Result[n].Port > 0) then
        Inc(n);
    end;

    SetLength(Result, n);
  finally
    Root.Free;
  end;
end;

procedure SetPing(const Key: string; Value: Integer);
begin
  Lock.Enter;
  try
    Pings.Values[Key] := IntToStr(Value);
  finally
    Lock.Leave;
  end;
end;

function ServerPing(const Key: string): Integer;
begin
  Lock.Enter;
  try
    Result := StrToIntDef(Pings.Values[Key], PING_PENDING);
  finally
    Lock.Leave;
  end;
end;

function ServerPlayers(const Key: string; out Names: TStringArray): Boolean;
var
  Value: string;
begin
  // start the request that waited for the previous one
  if HasPendingPlayers and (PlayersThread <> nil) and PlayersThread.Finished then
    RequestServerPlayers(PendingPlayers);

  Lock.Enter;
  try
    Value := PlayerLists.Values[Key];
  finally
    Lock.Leave;
  end;

  Result := Value <> '';
  Names := nil;
  if Length(Value) > 1 then
    Names := Copy(Value, 2, MaxInt).Split([#9]);
end;

procedure SetPlayers(const Key: string; const Names: string);
begin
  Lock.Enter;
  try
    PlayerLists.Values[Key] := '|' + Names;
  finally
    Lock.Leave;
  end;
end;

constructor TPlayersThread.Create(const Server: TServerEntry; const URL: string);
begin
  FServer := Server;
  FURL := URL;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPlayersThread.Execute;
var
  Http: TFPHTTPClient;
  Root: TJSONData;
  List: TJSONArray;
  Names: string;
  j: Integer;
begin
  Http := TFPHTTPClient.Create(nil);
  try
    Http.AddHeader('User-Agent', 'soldatclient/' + SOLDAT_VERSION);
    Http.ConnectTimeout := 5000;
    Http.IOTimeout := 5000;
    try
      Root := GetJSON(Http.SimpleGet(Format('%s/v0/server/%s/%d/players',
        [FURL, FServer.IP, FServer.Port])));
      try
        Names := '';
        if (Root is TJSONObject) and (TJSONObject(Root).Find('Players') is TJSONArray) then
        begin
          List := TJSONObject(Root).Arrays['Players'];
          for j := 0 to List.Count - 1 do
          begin
            if j > 0 then
              Names := Names + #9;
            Names := Names + StringReplace(List.Items[j].AsString, #9, ' ', [rfReplaceAll]);
          end;
        end;
        SetPlayers(FServer.IP + ':' + IntToStr(FServer.Port), Names);
      finally
        Root.Free;
      end;
    except
      // keeps the names from the last request
    end;
  finally
    Http.Free;
  end;
end;

function LobbyURL: string;
begin
  Result := cl_lobbyurl.Value;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

procedure RequestServerPlayers(const Server: TServerEntry);
begin
  // empty servers need no request (bots aren't counted)
  if Server.NumPlayers = 0 then
  begin
    SetPlayers(Server.IP + ':' + IntToStr(Server.Port), '');
    Exit;
  end;

  if (PlayersThread <> nil) and not PlayersThread.Finished then
  begin
    PendingPlayers := Server;
    HasPendingPlayers := True;
    Exit;
  end;

  FreeAndNil(PlayersThread);
  HasPendingPlayers := False;
  PlayersThread := TPlayersThread.Create(Server, LobbyURL);
end;

constructor TPingWorker.Create(const Servers: TServerEntries);
begin
  FServers := Servers;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPingWorker.Execute;
var
  i: Integer;
  Start: QWord;
  Socket: TInetSocket;
  Key: string;
begin
  while not Terminated do
  begin
    // workers share one queue
    i := InterLockedIncrement(NextPing);
    if i > High(FServers) then
      Break;

    Key := FServers[i].IP + ':' + IntToStr(FServers[i].Port);
    Start := GetTickCount64;
    try
      Socket := TInetSocket.Create(FServers[i].IP, FServers[i].Port, PING_TIMEOUT);
      SetPing(Key, GetTickCount64 - Start);
      Socket.Free;
    except
      SetPing(Key, PING_FAILED);
    end;
  end;
end;

procedure TServerListThread.MeasurePings(const Servers: TServerEntries);
var
  Workers: array of TPingWorker;
  i: Integer;
begin
  NextPing := -1;
  SetLength(Workers, PING_WORKERS);
  for i := 0 to High(Workers) do
    Workers[i] := TPingWorker.Create(Servers);
  for i := 0 to High(Workers) do
  begin
    Workers[i].WaitFor;
    Workers[i].Free;
  end;
end;

constructor TServerListThread.Create(URL: string);
begin
  FURL := URL;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TServerListThread.Execute;
var
  Http: TFPHTTPClient;
  Response: string;
  Servers: TServerEntries;
begin
  Http := TFPHTTPClient.Create(nil);
  try
    try
      Http.AddHeader('User-Agent', 'soldatclient/' + SOLDAT_VERSION);
      Http.AllowRedirect := True;
      Http.ConnectTimeout := 10000;
      Http.IOTimeout := 10000;
      Response := Http.SimpleGet(FURL);
      Servers := ParseServers(Response);

      Lock.Enter;
      try
        Fetched := Servers;
        HasNewData := True;
        Status := slsDone;
      finally
        Lock.Leave;
      end;

      // the list is already shown, pings fill in as they arrive
      MeasurePings(Servers);
    except
      on E: Exception do
      begin
        Lock.Enter;
        try
          ErrorText := E.Message;
          Status := slsError;
        finally
          Lock.Leave;
        end;
      end;
    end;
  finally
    Http.Free;
  end;
end;

procedure RefreshServerList;
var
  URL: string;
begin
  // still loading the list or measuring pings
  if (ServerListStatus = slsLoading) or ((Thread <> nil) and not Thread.Finished) then
    Exit;

  if Thread <> nil then
  begin
    Thread.WaitFor;
    FreeAndNil(Thread);
  end;

  URL := LobbyURL;

  Lock.Enter;
  try
    Status := slsLoading;
    ErrorText := '';
  finally
    Lock.Leave;
  end;

  Thread := TServerListThread.Create(URL + '/v0/servers');
end;

function PollServerList(var Servers: TServerEntries): Boolean;
begin
  Lock.Enter;
  try
    Result := HasNewData;
    if HasNewData then
    begin
      Servers := Copy(Fetched);
      HasNewData := False;
    end;
  finally
    Lock.Leave;
  end;
end;

function ServerListStatus: TServerListStatus;
begin
  Lock.Enter;
  try
    Result := Status;
  finally
    Lock.Leave;
  end;
end;

function ServerListError: string;
begin
  Lock.Enter;
  try
    Result := ErrorText;
  finally
    Lock.Leave;
  end;
end;

procedure FreeServerList;
begin
  if Thread <> nil then
  begin
    Thread.WaitFor;
    FreeAndNil(Thread);
  end;
  if PlayersThread <> nil then
  begin
    PlayersThread.WaitFor;
    FreeAndNil(PlayersThread);
  end;
end;

initialization
  Lock := TCriticalSection.Create;
  Pings := TStringList.Create;
  PlayerLists := TStringList.Create;

finalization
  FreeServerList;
  Pings.Free;
  PlayerLists.Free;
  Lock.Free;
end.
