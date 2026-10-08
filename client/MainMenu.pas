{*******************************************************}
{                                                       }
{       Main Menu Unit for SOLDAT                       }
{                                                       }
{       Server browser and settings, and the in-game    }
{       screen while the Soldat 1.7 client runs         }
{                                                       }
{*******************************************************}

unit MainMenu;

interface

// Runs the menu until the player picks a server (PendingJoin) or quits
// (QuitRequested).
procedure MainMenuLoop;
// Writes changed player/graphics settings to client.cfg.
procedure SaveSettings;

implementation

uses
  SDL2, SysUtils, Classes, Math, StrUtils,
  Gfx, Vector, Client, ClientGame, GameRendering, GostekGraphics, Sprites,
  Anims, Parts, Game, Net, Weapons, Constants, Cvar, Command, Input,
  GameStrings, ServerList, Sound, Version, Process, PhysFS, BaseUnix,
  LegacyOverlay, LegacyDownload, MapPreview, UpdateCheck, openssl;

const
  // everything is laid out in a 1280x720 design space scaled to the window
  DESIGN_W = 1280;
  DESIGN_H = 720;

  CONFIG_FILE = 'client.cfg';
  FAVORITES_FILE = 'favorites.txt';
  FAVORITE_MAPS_FILE = 'favorite_maps.txt';
  FRIENDS_FILE = 'friends.txt';
  SERVER_PREVIEW_W = 512;
  SERVER_PREVIEW_H = 297;
  C_FRIEND = $5DADE2;

  PLAYER_CVARS: array[0..10] of AnsiString = (
    'cl_player_name', 'cl_player_shirt', 'cl_player_pants', 'cl_player_skin',
    'cl_player_hair', 'cl_player_jet', 'cl_player_hairstyle',
    'cl_player_headstyle', 'cl_player_chainstyle', 'cl_player_secwep',
    'cl_legacy_client'
  );

  GRAPHICS_CVARS: array[0..14] of AnsiString = (
    'r_display', 'r_fullscreen', 'r_screenwidth', 'r_screenheight',
    'r_swapeffect', 'r_fpslimit', 'r_maxfps', 'r_msaa', 'r_resizefilter',
    'r_texturefilter', 'r_mipmapping', 'r_smoothedges', 'r_weathereffects',
    'r_renderbackground', 'r_scaleinterface'
  );

  OPTION_CVARS: array[0..5] of AnsiString = (
    'snd_volume', 'snd_effects_battle', 'snd_effects_explosions', 'cl_sensitivity',
    'cl_mapvote_key', 'cl_update_check'
  );

  LEGACY_VERSION = '1.7.1';

  // widget ids for keyboard focus and dragging
  ID_NONE        = 0;
  ID_SEARCH      = 1;
  ID_ADDRESS     = 2;
  ID_PASSWORD    = 3;
  ID_NAME        = 4;
  ID_SLIDER_R    = 5;
  ID_SLIDER_G    = 6;
  ID_SLIDER_B    = 7;
  ID_LEGACY      = 8;
  ID_MAPSEARCH   = 9;
  ID_MAPSTAB     = 11;
  ID_VOLUME      = 12;
  ID_SENSITIVITY = 13;
  ID_FRIEND      = 14;

  ROW_H = 26;

  // font sizes below are nominal, this maps them to the game's font
  TEXT_SCALE = 0.8;

  PALETTE: array[0..23] of LongWord = (
    $000000, $3B3B3B, $8F8F8F, $FFFFFF, $5C3A21, $8B5A2B, $E6B478, $FFDBAC,
    $7A1010, $C0392B, $E67E22, $F1C40F, $304289, $2E86C1, $5DADE2, $1ABC9C,
    $1E5631, $3F7D20, $8DB33A, $556B2F, $4A235A, $8E44AD, $D35D9B, $00008B
  );

type
  TMenuTab = (tabServers, tabPlayer, tabMaps, tabSettings);
  TSettingsPage = (spGraphics, spAudio, spControls, spGeneral);

  TSortColumn = (scName, scMode, scMap, scPlayers, scPing, scVersion, scCountry);

  TResolution = record
    w, h: Integer;
  end;

  TBindAction = record
    Command, Caption: string;
  end;

const
  // actions shown in the controls tab, the same in both clients
  BIND_ACTIONS: array[0..20] of TBindAction = (
    (Command: '+left'; Caption: 'Move left'),
    (Command: '+right'; Caption: 'Move right'),
    (Command: '+jump'; Caption: 'Jump'),
    (Command: '+crouch'; Caption: 'Crouch'),
    (Command: '+prone'; Caption: 'Prone'),
    (Command: '+jet'; Caption: 'Jets'),
    (Command: '+fire'; Caption: 'Fire'),
    (Command: '+reload'; Caption: 'Reload'),
    (Command: '+changeweapon'; Caption: 'Change weapon'),
    (Command: '+throwgrenade'; Caption: 'Throw grenade'),
    (Command: '+dropweapon'; Caption: 'Drop weapon'),
    (Command: '+chat'; Caption: 'Chat'),
    (Command: '+teamchat'; Caption: 'Team chat'),
    (Command: '+cmd'; Caption: 'Command line'),
    (Command: '+radio'; Caption: 'Radio'),
    (Command: '+weapons'; Caption: 'Weapons menu'),
    (Command: '+fragslist'; Caption: 'Scoreboard'),
    (Command: '+statsmenu'; Caption: 'Statistics'),
    (Command: '+minimap'; Caption: 'Minimap'),
    (Command: '+gamestats'; Caption: 'Game statistics'),
    (Command: 'screenshot'; Caption: 'Screenshot')
  );

var
  // input state for the current frame
  MouseX, MouseY: Single;
  MouseDown, MouseClicked, MouseDoubleClicked: Boolean;
  WheelDelta: Integer;
  TypedText: WideString;
  KeyBackspace, KeyEnter, KeyEscape, KeyUp, KeyDown, KeyPaste: Boolean;
  FocusId, DragId: Integer;

  // layout
  Scale, OffsetX, OffsetY: Single;
  DrawW, DrawH: Integer;

  Tab: TMenuTab = tabServers;
  SettingsPage: TSettingsPage = spGraphics;

  // server browser
  Servers: TServerEntries;
  Visible: array of Integer;
  SelectedServer: Integer = -1; // index into Servers
  ScrollRow: Integer = 0;
  SortColumn: TSortColumn = scPlayers;
  SortDescending: Boolean = True;
  // filters, the string ones are empty for "all"
  FilterMode, FilterCountry, FilterVersion, FilterOS: string;
  FilterPlayers: Integer = 0; // all, not empty, not full, not empty or full
  FilterPrivate, FilterRealistic, FilterSurvival: Integer; // all, yes, no
  ModeOptions, CountryOptions, VersionOptions, OSOptions: array of string;
  SearchText: WideString = '';
  AddressText: WideString = '';
  PasswordText: WideString = '';
  ListRequested: Boolean = False;
  LastPingSort: UInt32 = 0;
  Favorites: TStringList; // "ip:port" of servers starred by the player
  Friends: TStringList; // nicknames
  FriendText: WideString = '';
  FriendsScroll: Integer = 0;
  PlayersScroll: Integer = 0;
  PanelTab: Integer = 0; // players or friends next to the servers
  ServerPreview: TMapPreview;
  ServerPreviewName: string = '';
  LegacyText: WideString = '';
  LegacyProcess: TProcess;
  // server to join once the 1.7 client finished downloading
  PendingLegacyServer: TServerEntry;
  LegacyDownloadPending: Boolean = False;
  // server the running 1.7 client joined
  LegacyServer: TServerEntry;
  // the 1.7 client opened its window (it takes a while to load)
  LegacyWindowShown: Boolean = False;
  LastWindowCheck: UInt32 = 0;

  // map vote overlay for the 1.7 client, opened with cl_mapvote_key in game
  MapVoteActive: Boolean = False;
  MapNames: TStringList;
  MapSearch: WideString = '';
  MapScroll: Integer = 0;

  // maps tab
  FavoriteMaps: TStringList;
  MapsSearch: WideString = '';
  MapsScroll: Integer = 0;
  SelectedMap: string = '';
  MapPreviewData: TMapPreview;
  PreviewName: string = '';

  // MenuStatus is shown as information (not as an error) while it equals this
  InfoStatus: WideString = '';

  // player
  NameText: WideString = '';
  ColorPart: Integer = 0;
  Preview: TSprite;
  PreviewPlayer: TPlayer;
  PreviewTicks: Integer;
  PlayerDirty: Boolean;

  // sound and controls
  OptionsDirty: Boolean;
  BindKeys: array of string; // per BIND_ACTIONS, '' = not bound
  BindsLoaded: Boolean = False;
  CaptureBind: Integer = -1; // action waiting for a key
  CapturedKey: string = '';
  CaptureClear: Boolean = False;

  // graphics (pending values, applied with the Apply button)
  Resolutions: array of TResolution;
  PendingDisplay: Integer;
  PendingFullscreen: Integer;
  PendingResolution: Integer; // index into Resolutions, 0 = desktop
  PendingVsync: Boolean;
  PendingMsaa: Integer;
  GraphicsDirty: Boolean;
  GraphicsMessage: WideString;

  MenuInitialized: Boolean = False;

{******************************************************************************}
{*                                  Helpers                                   *}
{******************************************************************************}

function Choose(Cond: Boolean; const A, B: WideString): WideString; overload;
begin
  if Cond then
    Result := A
  else
    Result := B;
end;

function Choose(Cond: Boolean; A, B: LongWord): LongWord; overload;
begin
  if Cond then
    Result := A
  else
    Result := B;
end;

function Color(c: LongWord; a: Byte = 255): TGfxColor;
begin
  Result := RGBA((c shr 16) and $FF, (c shr 8) and $FF, c and $FF, a);
end;

function Inside(x, y, w, h: Single): Boolean;
begin
  Result := (MouseX >= x) and (MouseX < x + w) and (MouseY >= y) and (MouseY < y + h);
end;

procedure DrawStar(cx, cy, r: Single; c: TGfxColor);
var
  k: Integer;
  a: Single;
  Outer, Inner: array[0..4] of TVector2;
begin
  for k := 0 to 4 do
  begin
    a := -Pi / 2 + k * 2 * Pi / 5;
    Outer[k] := Vector2(cx + r * Cos(a), cy + r * Sin(a));
    a := a + Pi / 5;
    Inner[k] := Vector2(cx + 0.42 * r * Cos(a), cy + 0.42 * r * Sin(a));
  end;

  // one quad per spike: center, previous inner corner, tip, next inner corner
  for k := 0 to 4 do
    GfxDrawQuad(nil,
      GfxVertex(cx, cy, 0, 0, c),
      GfxVertex(Inner[(k + 4) mod 5].x, Inner[(k + 4) mod 5].y, 0, 0, c),
      GfxVertex(Outer[k].x, Outer[k].y, 0, 0, c),
      GfxVertex(Inner[k].x, Inner[k].y, 0, 0, c));
end;

procedure FillRect(x, y, w, h: Single; c: TGfxColor);
begin
  GfxDrawQuad(nil,
    GfxVertex(x, y, 0, 0, c),
    GfxVertex(x + w, y, 0, 0, c),
    GfxVertex(x + w, y + h, 0, 0, c),
    GfxVertex(x, y + h, 0, 0, c));
end;

procedure FillGradient(x, y, w, h: Single; Top, Bottom: TGfxColor);
begin
  GfxDrawQuad(nil,
    GfxVertex(x, y, 0, 0, Top),
    GfxVertex(x + w, y, 0, 0, Top),
    GfxVertex(x + w, y + h, 0, 0, Bottom),
    GfxVertex(x, y + h, 0, 0, Bottom));
end;

procedure StrokeRect(x, y, w, h: Single; c: TGfxColor; t: Single = 1);
begin
  // at least one pixel, otherwise lines vanish in small windows
  t := Max(t, 1 / Scale);
  FillRect(x, y, w, t, c);
  FillRect(x, y + h - t, w, t, c);
  FillRect(x, y + t, t, h - 2 * t, c);
  FillRect(x + w - t, y + t, t, h - 2 * t, c);
end;

procedure SetFont(Size: Single; Big: Boolean = False);
var
  Style: Integer;
begin
  if Big then
    Style := FONT_MENU
  else
    Style := FONT_SMALL;

  SetFontStyle(Style, TEXT_SCALE * Size * Scale / FontStyleSize(Style));
end;

function TextWidth(const s: WideString): Single;
begin
  if s = '' then
    Result := 0
  else
    Result := RectWidth(GfxTextMetrics(s));
end;

// Draws text with its top at y, vertically centered in a box of height h
// when h > 0.
procedure DrawText(const s: WideString; x, y: Single; c: TGfxColor;
  Size: Single = 16; h: Single = 0; Big: Boolean = False);
begin
  if s = '' then
    Exit;
  SetFont(Size, Big);
  GfxTextColor(c);
  if h > 0 then
    y := y + (h - TEXT_SCALE * Size * 1.2) / 2;
  GfxDrawText(s, x, y);
end;

procedure DrawTextCentered(const s: WideString; x, y, w, h: Single;
  c: TGfxColor; Size: Single = 16; Big: Boolean = False);
begin
  if s = '' then
    Exit;
  SetFont(Size, Big);
  GfxTextColor(c);
  GfxDrawText(s, x + (w - TextWidth(s)) / 2, y + (h - TEXT_SCALE * Size * 1.2) / 2);
end;

// Shortens a string so that it fits into the given width (in current font).
function FitText(const s: WideString; MaxWidth: Single; Size: Single = 16): WideString;
var
  n: Integer;
begin
  SetFont(Size);
  Result := s;
  if TextWidth(Result) <= MaxWidth then
    Exit;

  n := Length(s);
  while (n > 0) and (TextWidth(Copy(s, 1, n) + '...') > MaxWidth) do
    Dec(n);
  Result := Copy(s, 1, n) + '...';
end;

{******************************************************************************}
{*                                  Theme                                     *}
{******************************************************************************}

const
  C_BG_TOP     = $20261A;
  C_BG_BOTTOM  = $0E110B;
  C_PANEL      = $1A1F14;
  C_PANEL_LINE = $3A4430;
  C_ROW_ALT    = $232A1B;
  C_HOVER      = $3A4430;
  C_SELECTED   = $4E6B22;
  C_ACCENT     = $8DB33A;
  C_TEXT       = $E8E8DE;
  C_TEXT_DIM   = $9AA08A;
  C_ERROR      = $E0735F;
  C_BUTTON     = $2E3724;

{******************************************************************************}
{*                                  Widgets                                   *}
{******************************************************************************}

function Button(const Caption: WideString; x, y, w, h: Single;
  Primary: Boolean = False; Enabled: Boolean = True): Boolean;
var
  Hover: Boolean;
  Bg: LongWord;
begin
  Hover := Enabled and Inside(x, y, w, h);

  if not Enabled then
    Bg := C_PANEL
  else if Primary then
    Bg := Choose(Hover, $A3C94E, C_ACCENT)
  else
    Bg := Choose(Hover, C_HOVER, C_BUTTON);

  FillRect(x, y, w, h, Color(Bg));
  StrokeRect(x, y, w, h, Color(Choose(Primary and Enabled, $B5D86A, C_PANEL_LINE)));

  if Primary and Enabled then
    DrawTextCentered(Caption, x, y, w, h, Color($11160B), 17, True)
  else
    DrawTextCentered(Caption, x, y, w, h, Color(Choose(Enabled, C_TEXT, C_TEXT_DIM)), 16);

  Result := Hover and MouseClicked;
  if Result then
    PlaySound(SFX_MENUCLICK);
end;

function TabButton(const Caption: WideString; x, y, w, h: Single; Active: Boolean): Boolean;
var
  Hover: Boolean;
begin
  Hover := Inside(x, y, w, h);
  if Active then
    FillRect(x, y + h - 3, w, 3, Color(C_ACCENT));
  DrawTextCentered(Caption, x, y, w, h - 3,
    Color(Choose(Active or Hover, C_TEXT, C_TEXT_DIM)), 20, True);
  Result := Hover and MouseClicked and not Active;
  if Result then
    PlaySound(SFX_MENUCLICK);
end;

function Checkbox(const Caption: WideString; x, y: Single; Value: Boolean): Boolean;
var
  w: Single;
begin
  SetFont(16);
  w := 26 + TextWidth(Caption);
  FillRect(x, y + 3, 18, 18, Color(C_PANEL));
  StrokeRect(x, y + 3, 18, 18, Color(Choose(Inside(x, y, w, 24), C_ACCENT, C_PANEL_LINE)));
  if Value then
    FillRect(x + 4, y + 7, 10, 10, Color(C_ACCENT));
  DrawText(Caption, x + 26, y, Color(C_TEXT), 16, 24);

  Result := Value;
  if Inside(x, y, w, 24) and MouseClicked then
  begin
    Result := not Value;
    PlaySound(SFX_MENUCLICK);
  end;
end;

// Single line text input. Returns True when Enter was pressed while focused.
function TextField(Id: Integer; var Text: WideString; x, y, w, h: Single;
  MaxLength: Integer; const Placeholder: WideString = ''; Masked: Boolean = False): Boolean;
var
  Shown: WideString;
  Focused: Boolean;
  i: Integer;
begin
  Result := False;

  if MouseClicked then
  begin
    if Inside(x, y, w, h) then
    begin
      if FocusId <> Id then
        SDL_StartTextInput;
      FocusId := Id;
    end
    else if FocusId = Id then
    begin
      FocusId := ID_NONE;
      SDL_StopTextInput;
    end;
  end;

  Focused := FocusId = Id;

  if Focused then
  begin
    if TypedText <> '' then
      Text := Copy(Text + TypedText, 1, MaxLength);
    if KeyPaste then
      Text := Copy(Text + WideString(UTF8String(SDL_GetClipboardText)), 1, MaxLength);
    if KeyBackspace and (Length(Text) > 0) then
      Delete(Text, Length(Text), 1);
    if KeyEnter then
      Result := True;
  end;

  FillRect(x, y, w, h, Color($11140D));
  StrokeRect(x, y, w, h, Color(Choose(Focused, C_ACCENT,
    Choose(Inside(x, y, w, h), $56624A, C_PANEL_LINE))));

  if Masked then
  begin
    Shown := '';
    for i := 1 to Length(Text) do
      Shown := Shown + '*';
  end
  else
    Shown := Text;

  if (Shown = '') and not Focused then
    DrawText(FitText(Placeholder, w - 16), x + 8, y, Color(C_TEXT_DIM, 160), 16, h)
  else
  begin
    SetFont(16);
    // keep the end of long texts visible
    while (Length(Shown) > 0) and (TextWidth(Shown) > w - 20) do
      Delete(Shown, 1, 1);
    DrawText(Shown, x + 8, y, Color(C_TEXT), 16, h);

    if Focused and ((SDL_GetTicks div 500) mod 2 = 0) then
    begin
      SetFont(16);
      FillRect(x + 9 + TextWidth(Shown), y + 6, 2, h - 12, Color(C_ACCENT));
    end;
  end;
end;

// "<  value  >" selector. Returns the new index.
function Selector(const Caption: WideString; const Items: array of WideString;
  Index: Integer; x, y, w: Single): Integer;
const
  H = 30;
  LABEL_W = 210;
var
  bx, bw: Single;
begin
  Result := Index;
  DrawText(Caption, x, y, Color(C_TEXT_DIM), 16, H);

  bx := x + LABEL_W;
  bw := w - LABEL_W;
  FillRect(bx, y, bw, H, Color($11140D));
  StrokeRect(bx, y, bw, H, Color(C_PANEL_LINE));

  if (Index >= Low(Items)) and (Index <= High(Items)) then
    DrawTextCentered(Items[Index], bx + H, y, bw - 2 * H, H, Color(C_TEXT), 16);

  if Button('<', bx, y, H, H) then
    Result := Index - 1;
  if Button('>', bx + bw - H, y, H, H) then
    Result := Index + 1;

  if Result < Low(Items) then
    Result := High(Items)
  else if Result > High(Items) then
    Result := Low(Items);
end;

// Small "caption over value" selector used for the server filters. Returns
// the new index.
function FilterSelector(const Caption: WideString; const Items: array of WideString;
  Index: Integer; x, y, w: Single; Active: Boolean): Integer;
const
  H = 28;
begin
  Result := Index;
  DrawText(Caption, x, y, Color(Choose(Active, C_ACCENT, C_TEXT_DIM)), 13, 18);
  y := y + 18;

  FillRect(x, y, w, H, Color($11140D));
  StrokeRect(x, y, w, H, Color(Choose(Active, C_ACCENT, C_PANEL_LINE)));
  if (Index >= Low(Items)) and (Index <= High(Items)) then
    DrawTextCentered(FitText(Items[Index], w - 2 * H, 14), x + H - 4, y, w - 2 * H + 8, H,
      Color(Choose(Active, C_TEXT, C_TEXT_DIM)), 14);

  if Button('<', x, y, H - 4, H) then
    Result := Index - 1;
  if Button('>', x + w - H + 4, y, H - 4, H) then
    Result := Index + 1;

  // clicking the value goes forward as well
  if MouseClicked and Inside(x + H, y, w - 2 * H, H) then
    Result := Index + 1;

  if Result < Low(Items) then
    Result := High(Items)
  else if Result > High(Items) then
    Result := Low(Items);
end;

function Slider(Id: Integer; const Caption: WideString; Value, MaxValue: Integer;
  x, y, w: Single; Fill: LongWord): Integer;
const
  H = 22;
var
  t: Single;
begin
  Result := Value;

  if MouseClicked and Inside(x, y, w, H) then
    DragId := Id;

  if (DragId = Id) and MouseDown then
  begin
    t := EnsureRange((MouseX - x) / w, 0, 1);
    Result := Round(t * MaxValue);
  end;

  FillRect(x, y + 8, w, 6, Color($11140D));
  FillRect(x, y + 8, w * Value / MaxValue, 6, Color(Fill));
  FillRect(x + w * Value / MaxValue - 4, y + 2, 8, H - 4, Color(C_TEXT));
  DrawText(Caption, x - 28, y, Color(C_TEXT_DIM), 15, H);
  DrawText(WideString(IntToStr(Value)), x + w + 12, y, Color(C_TEXT), 15, H);
end;

{******************************************************************************}
{*                               Server browser                               *}
{******************************************************************************}

// "1.7.1" -> "1.7"
function MajorMinor(const Version: string): string;
var
  p: Integer;
begin
  p := Pos('.', Version);
  if p = 0 then
    Exit(Version);
  p := PosEx('.', Version, p + 1);
  if p = 0 then
    Result := Version
  else
    Result := Copy(Version, 1, p - 1);
end;

// Soldat 1.7 servers use the old network protocol, this client (1.8) uses
// GameNetworkingSockets, so only servers of the same major.minor version work.
function IsCompatible(const s: TServerEntry): Boolean;
begin
  Result := MajorMinor(s.Version) = MajorMinor(SOLDAT_VERSION);
end;

function ServerKey(const s: TServerEntry): string;
begin
  Result := s.IP + ':' + IntToStr(s.Port);
end;

function IsFavorite(const s: TServerEntry): Boolean;
begin
  Result := Favorites.IndexOf(ServerKey(s)) >= 0;
end;

procedure LoadFavorites;
begin
  if Favorites = nil then
  begin
    Favorites := TStringList.Create;
    Favorites.Sorted := True;
    Favorites.Duplicates := dupIgnore;
  end;

  Favorites.Clear;
  try
    if FileExists(UserDirectory + 'configs/' + FAVORITES_FILE) then
      Favorites.LoadFromFile(UserDirectory + 'configs/' + FAVORITES_FILE);
  except
    on E: Exception do
      MenuStatus := WideString('Could not load favorite servers: ' + E.Message);
  end;
end;

procedure ToggleFavorite(const s: TServerEntry);
var
  i: Integer;
begin
  i := Favorites.IndexOf(ServerKey(s));
  if i >= 0 then
    Favorites.Delete(i)
  else
    Favorites.Add(ServerKey(s));

  try
    Favorites.SaveToFile(UserDirectory + 'configs/' + FAVORITES_FILE);
  except
    on E: Exception do
      MenuStatus := WideString('Could not save favorite servers: ' + E.Message);
  end;
end;

procedure LoadFriends;
begin
  if Friends = nil then
  begin
    Friends := TStringList.Create;
    Friends.Sorted := True;
    Friends.Duplicates := dupIgnore;
  end;

  Friends.Clear;
  try
    if FileExists(UserDirectory + 'configs/' + FRIENDS_FILE) then
      Friends.LoadFromFile(UserDirectory + 'configs/' + FRIENDS_FILE);
  except
    on E: Exception do
      MenuStatus := WideString('Could not load friends: ' + E.Message);
  end;
end;

function IsFriend(const Name: string): Boolean;
begin
  Result := Friends.IndexOf(Name) >= 0;
end;

procedure ToggleFriend(const Name: string);
var
  i: Integer;
begin
  if Trim(Name) = '' then
    Exit;
  i := Friends.IndexOf(Name);
  if i >= 0 then
    Friends.Delete(i)
  else
    Friends.Add(Trim(Name));

  try
    Friends.SaveToFile(UserDirectory + 'configs/' + FRIENDS_FILE);
  except
    on E: Exception do
      MenuStatus := WideString('Could not save friends: ' + E.Message);
  end;
end;

function FriendsOnServer(const s: TServerEntry): Integer;
var
  Names: TStringArray;
  i: Integer;
begin
  Result := 0;
  ServerPlayers(ServerKey(s), Names);
  for i := 0 to High(Names) do
    if IsFriend(Names[i]) then
      Inc(Result);
end;

// unknown pings sort after all measured ones
function PingSortValue(const s: TServerEntry): Integer;
begin
  Result := ServerPing(ServerKey(s));
  if Result < 0 then
    Result := MaxInt;
end;

function CompareServers(const a, b: TServerEntry): Integer;
begin
  // favorites always stay on top, whatever the sort order
  Result := Ord(IsFavorite(b)) - Ord(IsFavorite(a));
  if Result <> 0 then
    Exit;

  case SortColumn of
    scName: Result := CompareText(a.Name, b.Name);
    scMode: Result := CompareText(a.GameStyle, b.GameStyle);
    scMap: Result := CompareText(a.CurrentMap, b.CurrentMap);
    scPlayers: Result := CompareValue(a.NumPlayers, b.NumPlayers);
    scPing: Result := CompareValue(PingSortValue(a), PingSortValue(b));
    scVersion: Result := CompareText(a.Version, b.Version);
    scCountry: Result := CompareText(a.Country, b.Country);
  else
    Result := 0;
  end;

  // stable secondary order: most players, then name
  if Result = 0 then
    Result := CompareValue(a.NumPlayers, b.NumPlayers);
  if Result = 0 then
    Result := -CompareText(a.Name, b.Name);

  if SortDescending then
    Result := -Result;
end;

function MatchesYesNo(Filter: Integer; Value: Boolean): Boolean;
begin
  Result := (Filter = 0) or ((Filter = 1) = Value);
end;

function MatchesFilters(const s: TServerEntry): Boolean;
var
  Empty, Full: Boolean;
begin
  Result := False;
  Empty := s.NumPlayers = 0;
  Full := s.NumPlayers >= s.MaxPlayers;

  case FilterPlayers of
    1: if Empty then Exit;
    2: if Full then Exit;
    3: if Empty or Full then Exit;
    4: if FriendsOnServer(s) = 0 then Exit;
  end;

  if (FilterMode <> '') and not SameText(s.GameStyle, FilterMode) then
    Exit;
  if (FilterCountry <> '') and not SameText(s.Country, FilterCountry) then
    Exit;
  if (FilterVersion <> '') and (s.Version <> FilterVersion) then
    Exit;
  if (FilterOS <> '') and not SameText(s.OS, FilterOS) then
    Exit;

  Result := MatchesYesNo(FilterPrivate, s.IsPrivate) and
    MatchesYesNo(FilterRealistic, s.Realistic) and
    MatchesYesNo(FilterSurvival, s.Survival);
end;

// Collects the distinct values of a field for the filter selectors.
procedure UpdateFilterOptions;

  procedure AddUnique(var List: array of string; var Count: Integer; const Value: string);
  var
    k, j: Integer;
  begin
    if Value = '' then
      Exit;
    for k := 0 to Count - 1 do
      if SameText(List[k], Value) then
        Exit;
    // keep sorted
    k := Count;
    while (k > 0) and (CompareText(List[k - 1], Value) > 0) do
      Dec(k);
    for j := Count downto k + 1 do
      List[j] := List[j - 1];
    List[k] := Value;
    Inc(Count);
  end;

var
  i, nm, nc, nv, no: Integer;
begin
  SetLength(ModeOptions, Length(Servers));
  SetLength(CountryOptions, Length(Servers));
  SetLength(VersionOptions, Length(Servers));
  SetLength(OSOptions, Length(Servers));
  nm := 0;
  nc := 0;
  nv := 0;
  no := 0;

  for i := 0 to High(Servers) do
  begin
    AddUnique(ModeOptions, nm, Servers[i].GameStyle);
    AddUnique(CountryOptions, nc, Servers[i].Country);
    AddUnique(VersionOptions, nv, Servers[i].Version);
    AddUnique(OSOptions, no, Servers[i].OS);
  end;

  SetLength(ModeOptions, nm);
  SetLength(CountryOptions, nc);
  SetLength(VersionOptions, nv);
  SetLength(OSOptions, no);
end;

procedure UpdateVisibleServers;
var
  i, j, Tmp, SelectedIndex: Integer;
  Search: string;
begin
  SetLength(Visible, 0);
  Search := LowerCase(Trim(UTF8Encode(SearchText)));

  for i := 0 to High(Servers) do
  begin
    if not MatchesFilters(Servers[i]) then
      Continue;
    if (Search <> '') and
      (Pos(Search, LowerCase(Servers[i].Name)) = 0) and
      (Pos(Search, LowerCase(Servers[i].CurrentMap)) = 0) and
      (Pos(Search, LowerCase(Servers[i].GameStyle)) = 0) then
      Continue;

    SetLength(Visible, Length(Visible) + 1);
    Visible[High(Visible)] := i;
  end;

  // insertion sort, the list is small
  for i := 1 to High(Visible) do
  begin
    Tmp := Visible[i];
    j := i - 1;
    while (j >= 0) and (CompareServers(Servers[Visible[j]], Servers[Tmp]) > 0) do
    begin
      Visible[j + 1] := Visible[j];
      Dec(j);
    end;
    Visible[j + 1] := Tmp;
  end;

  SelectedIndex := -1;
  for i := 0 to High(Visible) do
    if Visible[i] = SelectedServer then
      SelectedIndex := i;
  if SelectedIndex < 0 then
    SelectedServer := -1;
end;

procedure SelectServer(Index: Integer);
begin
  if (Index >= 0) and (Index <> SelectedServer) then
  begin
    RequestServerPlayers(Servers[Index]);
    PlayersScroll := 0;
  end;
  SelectedServer := Index;
  if Index >= 0 then
    AddressText := WideString(Servers[Index].IP + ':' + IntToStr(Servers[Index].Port));
end;


// Starts the Soldat 1.7 client configured in cl_legacy_client, which speaks
// the protocol of the servers this client can't join.
// Reaps the 1.7 client once it quit (TProcess.Running waits for it without
// blocking, so it doesn't stay around as a zombie) and reports a crash.
procedure SetInfoStatus(const Text: WideString);
begin
  MenuStatus := Text;
  InfoStatus := Text;
end;

function LaunchLegacyClient(const Server: TServerEntry): Boolean; forward;
procedure LoadMapNames; forward;
procedure WriteBinds(const Path: string); forward;

// Shows the progress of the 1.7 client download and joins the server it
// was started for once it finished.
procedure CheckLegacyDownload;
var
  LegacyDir: string;
begin
  if not LegacyDownloadPending then
    Exit;

  case LegacyDownloadState of
    ldsRunning:
      SetInfoStatus(WideFormat(_('Downloading the Soldat 1.7.1 client from soldat.pl ' +
        '(only once, about 180 MB): %d%%'), [LegacyDownloadProgress]));
    ldsDone:
      begin
        LegacyDownloadPending := False;
        LegacyDir := UserDirectory + 'legacy/';
        LegacyText := '';
        if DirectoryExists(LegacyDir + 'downloads') then
          PHYSFS_mount(PChar(LegacyDir + 'downloads'), '/', True);
        if MapNames <> nil then
          LoadMapNames;
        if not LaunchLegacyClient(PendingLegacyServer) then
          MenuStatus := _('The Soldat 1.7.1 client was downloaded, but could not be started.');
      end;
    ldsFailed:
      begin
        LegacyDownloadPending := False;
        MenuStatus := WideString('Could not download the Soldat 1.7.1 client: ' + LegacyDownloadError);
      end;
  end;
end;

procedure CheckLegacyProcess;
begin
  if (LegacyProcess <> nil) and not LegacyWindowShown and
    (SDL_GetTicks - LastWindowCheck > 250) then
  begin
    LastWindowCheck := SDL_GetTicks;
    LegacyWindowShown := OverlayWindowShown(LegacyProcess.ProcessID);
  end;

  if (LegacyProcess = nil) or LegacyProcess.Running then
    Exit;

  if LegacyProcess.ExitStatus <> 0 then
    MenuStatus := WideFormat(_('The Soldat 1.7 client quit with an error (%d). Try joining again.'),
      [LegacyProcess.ExitCode])
  else if MenuStatus = InfoStatus then
    SetInfoStatus('');
  FreeAndNil(LegacyProcess);

  // the launcher was minimized while the game had the focus
  SDL_RestoreWindow(GameWindow);
  SDL_RaiseWindow(GameWindow);
  OverlayActivate(GetProcessID);
  OverlayStop;
  MapVoteActive := False;
end;

function InGame: Boolean;
begin
  Result := LegacyProcess <> nil;
end;

// Closes the 1.7 client, forcibly when it doesn't quit within a second.
procedure StopLegacyClient;
var
  i: Integer;
begin
  if LegacyProcess = nil then
    Exit;

  if LegacyProcess.Running then
  begin
    FpKill(LegacyProcess.ProcessID, SIGTERM);
    for i := 1 to 50 do
    begin
      if not LegacyProcess.Running then
        Break;
      Sleep(20);
    end;
    if LegacyProcess.Running then
      LegacyProcess.Terminate(0);
  end;

  FreeAndNil(LegacyProcess);
  OverlayStop;
  MapVoteActive := False;
end;

// cl_legacy_client, or the downloaded client in legacy/ of the user directory.
function LegacyClientPath: string;
begin
  Result := Trim(cl_legacy_client.Value);
  if Result <> '' then
    Exit;

  Result := UserDirectory + 'legacy/soldat_x64';
  if not FileExists(Result) then
    Result := '';
end;

// Copies the player and display settings of this menu into the config of
// the 1.7 client, which uses the same cvars. Its other lines (binds etc.)
// are kept.
procedure SyncLegacyConfig(const ClientPath: string);
const
  SHARED_CVARS: array[0..26] of AnsiString = (
    'cl_player_name', 'cl_player_shirt', 'cl_player_pants', 'cl_player_skin',
    'cl_player_hair', 'cl_player_jet', 'cl_player_hairstyle',
    'cl_player_headstyle', 'cl_player_chainstyle', 'cl_player_secwep',
    'r_fullscreen', 'r_screenwidth', 'r_screenheight', 'r_swapeffect',
    'r_fpslimit', 'r_maxfps', 'r_resizefilter', 'r_texturefilter',
    'r_mipmapping', 'r_smoothedges', 'r_weathereffects',
    'r_renderbackground', 'r_scaleinterface', 'snd_volume',
    'snd_effects_battle', 'snd_effects_explosions', 'cl_sensitivity'
  );
var
  Overrides: TStringList;
  ConfigPath: string;
begin
  ConfigPath := ExtractFilePath(ClientPath) + 'configs/client.cfg';
  if not FileExists(ConfigPath) then
    Exit;

  Overrides := TStringList.Create;
  try
    // the 1.7 client takes the head gear graphics id instead of 0/1/2
    case cl_player_headstyle.Value of
      HEADSTYLE_HELMET: Overrides.Values['cl_player_headstyle'] := '34';
      HEADSTYLE_HAT: Overrides.Values['cl_player_headstyle'] := '124';
    else
      Overrides.Values['cl_player_headstyle'] := '0';
    end;
    SaveConfigFile(ConfigPath, SHARED_CVARS, Overrides);
  finally
    Overrides.Free;
  end;
  WriteBinds(ConfigPath);
end;

function LaunchLegacyClient(const Server: TServerEntry): Boolean;
var
  Path: string;
  i: Integer;
begin
  Result := False;
  Path := LegacyClientPath;
  if (Path = '') or not FileExists(Path) then
    Exit;

  if (LegacyProcess <> nil) and LegacyProcess.Running then
  begin
    MenuStatus := _('The Soldat 1.7 client is already running.');
    Result := True;
    Exit;
  end;

  SaveSettings;
  SyncLegacyConfig(Path);

  FreeAndNil(LegacyProcess);
  LegacyProcess := TProcess.Create(nil);
  LegacyProcess.Executable := Path;
  LegacyProcess.CurrentDirectory := ExtractFilePath(Path);
  LegacyProcess.Parameters.Add('-join');
  LegacyProcess.Parameters.Add(Server.IP);
  LegacyProcess.Parameters.Add(IntToStr(Server.Port));
  if PasswordText <> '' then
    LegacyProcess.Parameters.Add(UTF8Encode(PasswordText));

  // keep the game visible (not minimized) while the map vote overlay is up
  for i := 1 to GetEnvironmentVariableCount do
    LegacyProcess.Environment.Add(GetEnvironmentString(i));
  LegacyProcess.Environment.Add('SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0');

  try
    LegacyProcess.Execute;
    LegacyServer := Server;
    LegacyWindowShown := False;
    OverlayStart(LegacyProcess.ProcessID, cl_mapvote_key.Value);
    if cl_mapvote_key.Value <> '' then
      SetInfoStatus(WideFormat(_('Started the Soldat %s client for %s. Press %s in game to change the map.'),
        [WideString(Server.Version), WideString(Server.Name), WideString(cl_mapvote_key.Value)]))
    else
      SetInfoStatus(WideFormat(_('Started the Soldat %s client for %s.'),
        [WideString(Server.Version), WideString(Server.Name)]));
    Result := True;
  except
    on E: Exception do
      MenuStatus := WideString('Could not start ' + Path + ': ' + E.Message);
  end;
end;

procedure JoinAddress;
var
  Address, Port: string;
  p: Integer;
begin
  Address := Trim(UTF8Encode(AddressText));
  if Address = '' then
  begin
    MenuStatus := _('Pick a server from the list or enter an address');
    Exit;
  end;

  if (SelectedServer >= 0) and (Address = ServerKey(Servers[SelectedServer])) and
    not IsCompatible(Servers[SelectedServer]) then
  begin
    if not LaunchLegacyClient(Servers[SelectedServer]) then
    begin
      if Trim(cl_legacy_client.Value) = '' then
      begin
        // no client installed yet: fetch the official one, then join
        PendingLegacyServer := Servers[SelectedServer];
        LegacyDownloadPending := True;
        StartLegacyDownload(UserDirectory + 'legacy');
      end
      else
        MenuStatus := WideFormat(_('This server runs Soldat %s, which can''t be joined with ' +
          'this game version (%s). The Soldat 1.7 client set below was not found.'),
          [WideString(Servers[SelectedServer].Version), WideString(SOLDAT_VERSION)]);
    end;
    Exit;
  end;

  // soldat://ip:port/password links are accepted too
  if AnsiStartsText('soldat://', Address) then
    Delete(Address, 1, Length('soldat://'));

  Port := '23073';
  p := RPos(':', Address);
  if p > 0 then
  begin
    Port := Copy(Address, p + 1, MaxInt);
    Address := Copy(Address, 1, p - 1);
    p := Pos('/', Port);
    if p > 0 then
    begin
      if PasswordText = '' then
        PasswordText := WideString(Copy(Port, p + 1, MaxInt));
      Port := Copy(Port, 1, p - 1);
    end;
  end;

  if StrToIntDef(Port, 0) <= 0 then
  begin
    MenuStatus := WideFormat(_('Invalid server port: %s'), [WideString(Port)]);
    Exit;
  end;

  SaveSettings;

  JoinIP := Address;
  JoinPort := Port;
  JoinPassword := UTF8Encode(PasswordText);
  RequestJoin;
end;

// Renders the preview of the selected server's map when it changed. Must run
// outside of RenderMenu, it uses its own render target.
procedure UpdateServerPreview;
var
  Map: string;
begin
  if Tab <> tabServers then
    Exit;
  Map := '';
  if SelectedServer >= 0 then
    Map := Servers[SelectedServer].CurrentMap;
  if Map = ServerPreviewName then
    Exit;

  FreeMapPreview(ServerPreview);
  ServerPreviewName := Map;
  if Map <> '' then
    ServerPreview := RenderMapPreview(Map, SERVER_PREVIEW_W, SERVER_PREVIEW_H);
end;

// Map preview, players of the selected server and friends, next to the
// servers.
procedure DrawPlayersPanel(PX, PY, PW, PH: Single);
const
  RH = 24;
  PREVIEW_H = 146;
var
  Names: TStringArray;
  Fetched, Hover: Boolean;
  i, j, n, Rows: Integer;
  y, ListY, ListH, tw: Single;
  FriendNames: array of string;
  FriendServer: array of Integer; // index into Servers, -1 = offline
  Name: string;
  Caption: WideString;
  White: TGfxColor;
  u, v: Single;

  // star toggling the friend, returns True when clicked
  function FriendStar(x, y: Single; IsOn: Boolean): Boolean;
  begin
    Result := MouseClicked and Inside(x - 10, y, 22, RH);
    DrawStar(x, y + RH / 2, 7, Color(Choose(IsOn, C_FRIEND,
      Choose(Inside(x - 10, y, 22, RH), C_TEXT, $4A5540))));
  end;

  function PanelTabButton(const Caption: WideString; x, w: Single; Index: Integer): Boolean;
  begin
    Hover := Inside(x, ListY - 32, w, 30);
    if PanelTab = Index then
      FillRect(x, ListY - 5, w, 3, Color(C_ACCENT));
    DrawTextCentered(Caption, x, ListY - 32, w, 28,
      Color(Choose((PanelTab = Index) or Hover, C_TEXT, C_TEXT_DIM)), 15);
    Result := Hover and MouseClicked and (PanelTab <> Index);
    if Result then
      PlaySound(SFX_MENUCLICK);
  end;

begin
  FillRect(PX, PY, PW, PH, Color(C_PANEL, 230));
  StrokeRect(PX, PY, PW, PH, Color(C_PANEL_LINE));

  // current map of the selected server
  FillRect(PX + 1, PY + 1, PW - 2, PREVIEW_H, Color($0B0D08));
  if ServerPreview.Texture <> nil then
  begin
    White := RGBA($FFFFFF);
    u := ServerPreview.Width / ServerPreview.Texture.Width;
    v := ServerPreview.Height / ServerPreview.Texture.Height;
    // render targets are stored bottom up
    GfxDrawQuad(ServerPreview.Texture,
      GfxVertex(PX + 1, PY + 1, 0, v, White),
      GfxVertex(PX + PW - 1, PY + 1, u, v, White),
      GfxVertex(PX + PW - 1, PY + PREVIEW_H, u, 0, White),
      GfxVertex(PX + 1, PY + PREVIEW_H, 0, 0, White));
  end
  else if ServerPreviewName <> '' then
    DrawTextCentered(_('No preview of this map'), PX, PY, PW, PREVIEW_H, Color(C_TEXT_DIM), 14);
  if ServerPreviewName <> '' then
  begin
    SetFont(14);
    tw := TextWidth(WideString(ServerPreviewName));
    FillRect(PX + 1, PY + PREVIEW_H - 22, Min(PW - 2, tw + 16), 22, Color($0B0D08, 200));
    DrawText(FitText(WideString(ServerPreviewName), PW - 18, 14), PX + 8, PY + PREVIEW_H - 22,
      Color(C_TEXT), 14, 22);
  end
  else
    DrawTextCentered(_('Select a server'), PX, PY, PW, PREVIEW_H, Color(C_TEXT_DIM), 14);

  // friends, the ones playing first
  FriendNames := nil;
  FriendServer := nil;
  for i := 0 to High(Servers) do
  begin
    ServerPlayers(ServerKey(Servers[i]), Names);
    for j := 0 to High(Names) do
      if IsFriend(Names[j]) then
      begin
        FriendNames := Concat(FriendNames, [Names[j]]);
        FriendServer := Concat(FriendServer, [i]);
      end;
  end;
  n := Length(FriendNames);
  for i := 0 to Friends.Count - 1 do
  begin
    Name := Friends[i];
    Fetched := False;
    for j := 0 to n - 1 do
      if SameText(FriendNames[j], Name) then
        Fetched := True;
    if not Fetched then
    begin
      FriendNames := Concat(FriendNames, [Name]);
      FriendServer := Concat(FriendServer, [-1]);
    end;
  end;

  // players of the selected server
  Names := nil;
  Fetched := False;
  if SelectedServer >= 0 then
    Fetched := ServerPlayers(ServerKey(Servers[SelectedServer]), Names);

  // tabs
  ListY := PY + PREVIEW_H + 36;
  FillRect(PX + 1, ListY - 34, PW - 2, 32, Color($2A3220));
  if Fetched then
    Caption := WideFormat(_('Players (%d)'), [Length(Names)])
  else
    Caption := _('Players');
  if PanelTabButton(Caption, PX + 1, (PW - 2) / 2, 0) then
    PanelTab := 0;
  if PanelTabButton(WideFormat(_('Friends (%d)'), [Friends.Count]), PX + 1 + (PW - 2) / 2,
    (PW - 2) / 2, 1) then
    PanelTab := 1;

  y := ListY;
  if PanelTab = 0 then
  begin
    ListH := PY + PH - 4 - ListY;
    Rows := Floor(ListH / RH);
    if SelectedServer < 0 then
      DrawText(FitText(_('Select a server to see who plays'), PW - 20, 14), PX + 10, y,
        Color(C_TEXT_DIM), 14, RH)
    else if not Fetched then
      DrawText(_('Loading...'), PX + 10, y, Color(C_TEXT_DIM), 14, RH)
    else if Length(Names) = 0 then
      DrawText(_('Nobody plays here'), PX + 10, y, Color(C_TEXT_DIM), 14, RH)
    else
    begin
      if Inside(PX, y, PW, Rows * RH) then
        PlayersScroll := PlayersScroll - WheelDelta;
      PlayersScroll := EnsureRange(PlayersScroll, 0, Max(0, Length(Names) - Rows));

      for i := PlayersScroll to Min(High(Names), PlayersScroll + Rows - 1) do
      begin
        if FriendStar(PX + 16, y, IsFriend(Names[i])) then
          ToggleFriend(Names[i]);
        DrawText(FitText(WideString(Names[i]), PW - 50, 15), PX + 32, y,
          Color(Choose(IsFriend(Names[i]), C_FRIEND, C_TEXT)), 15, RH);
        y := y + RH;
      end;

      // scrollbar
      if Length(Names) > Rows then
        FillRect(PX + PW - 6, ListY + (Rows * RH - Rows * RH * Rows / Length(Names)) *
          PlayersScroll / (Length(Names) - Rows), 4, Rows * RH * Rows / Length(Names),
          Color(C_PANEL_LINE));
    end;
    Exit;
  end;

  // friends tab
  ListH := PY + PH - 40 - ListY;
  Rows := Floor(ListH / RH);
  if Inside(PX, y, PW, Rows * RH) then
    FriendsScroll := FriendsScroll - WheelDelta;
  FriendsScroll := EnsureRange(FriendsScroll, 0, Max(0, Length(FriendNames) - Rows));

  if Length(FriendNames) = 0 then
    DrawText(FitText(_('Star a player to add a friend'), PW - 20, 14), PX + 10, y,
      Color(C_TEXT_DIM), 14, RH);

  for i := FriendsScroll to Min(High(FriendNames), FriendsScroll + Rows - 1) do
  begin
    Hover := (FriendServer[i] >= 0) and Inside(PX + 28, y, PW - 30, RH);
    if Hover then
      FillRect(PX + 1, y, PW - 2, RH, Color(C_HOVER));

    if FriendStar(PX + 16, y, True) then
    begin
      ToggleFriend(FriendNames[i]);
      Break;
    end;

    if FriendServer[i] >= 0 then
    begin
      DrawText(FitText(WideString(FriendNames[i]), (PW - 40) / 2, 15), PX + 32, y,
        Color(C_FRIEND), 15, RH);
      DrawText(FitText(WideString(Servers[FriendServer[i]].Name), (PW - 40) / 2 - 8, 13),
        PX + 40 + (PW - 40) / 2, y, Color(C_TEXT_DIM), 13, RH);
      if Hover and MouseClicked then
      begin
        PlaySound(SFX_MENUCLICK);
        SelectServer(FriendServer[i]);
      end;
    end
    else
      DrawText(FitText(WideString(FriendNames[i]), PW - 44, 15), PX + 32, y,
        Color(C_TEXT_DIM), 15, RH);
    y := y + RH;
  end;

  if TextField(ID_FRIEND, FriendText, PX + 8, PY + PH - 36, PW - 16, 28, 24,
    _('Add friend by nickname')) and (Trim(FriendText) <> '') then
  begin
    if not IsFriend(UTF8Encode(Trim(FriendText))) then
      ToggleFriend(UTF8Encode(Trim(FriendText)));
    FriendText := '';
  end;
end;

procedure DrawServersTab;
const
  LIST_X = 40;
  LIST_Y = 200;
  LIST_W = 920;
  LIST_H = 422; // header and 15 whole rows
  FULL_W = 1200; // list and players panel
  HEADER_H = 30;
  FILTER_Y = 142;
  FILTER_W = 144;
  FILTER_STEP = 151;
type
  TColumn = record
    Caption: WideString;
    Sort: TSortColumn;
    x, w: Single;
  end;
var
  Columns: array[0..6] of TColumn;
  Ping: Integer;
  i, Row, Rows, Index, TotalPlayers: Integer;
  x, y: Single;
  s: TServerEntry;
  RowColor: LongWord;
  Status: TServerListStatus;
  Info: WideString;
  OldSearch: WideString;
  FiltersChanged, Favorite: Boolean;
  Items: array of WideString;

  procedure SetColumn(n: Integer; const Caption: WideString; Sort: TSortColumn; cx, cw: Single);
  begin
    Columns[n].Caption := Caption;
    Columns[n].Sort := Sort;
    Columns[n].x := cx;
    Columns[n].w := cw;
  end;

  // selector for a text field filter, '' meaning all
  procedure StringFilter(n: Integer; const Caption: WideString;
    const Options: array of string; var Filter: string);
  var
    k, Current, NewIndex: Integer;
  begin
    SetLength(Items, Length(Options) + 1);
    Items[0] := _('All');
    Current := 0;
    for k := 0 to High(Options) do
    begin
      Items[k + 1] := WideString(Options[k]);
      if SameText(Options[k], Filter) then
        Current := k + 1;
    end;

    NewIndex := FilterSelector(Caption, Items, Current,
      LIST_X + n * FILTER_STEP, FILTER_Y, FILTER_W, Current <> 0);
    if NewIndex <> Current then
    begin
      if NewIndex = 0 then
        Filter := ''
      else
        Filter := Options[NewIndex - 1];
      FiltersChanged := True;
    end;
  end;

  procedure YesNoFilter(n: Integer; const Caption: WideString; var Filter: Integer);
  var
    NewIndex: Integer;
  begin
    SetLength(Items, 3);
    Items[0] := _('All');
    Items[1] := _('Yes');
    Items[2] := _('No');
    NewIndex := FilterSelector(Caption, Items, Filter,
      LIST_X + n * FILTER_STEP, FILTER_Y, FILTER_W, Filter <> 0);
    if NewIndex <> Filter then
    begin
      Filter := NewIndex;
      FiltersChanged := True;
    end;
  end;

begin
  if PollServerList(Servers) then
  begin
    UpdateFilterOptions;
    UpdateVisibleServers;
  end;

  Status := ServerListStatus;

  // toolbar
  OldSearch := SearchText;
  TextField(ID_SEARCH, SearchText, LIST_X, 92, 400, 34, 64, _('Search name, map or mode'));
  FiltersChanged := OldSearch <> SearchText;

  if Button(_('Clear filters'), LIST_X + 412, 92, 150, 34) then
  begin
    SearchText := '';
    FilterMode := '';
    FilterCountry := '';
    FilterVersion := '';
    FilterOS := '';
    FilterPlayers := 0;
    FilterPrivate := 0;
    FilterRealistic := 0;
    FilterSurvival := 0;
    FiltersChanged := True;
  end;

  // filters, same as on the lobby website
  StringFilter(0, _('Game mode'), ModeOptions, FilterMode);

  SetLength(Items, 5);
  Items[0] := _('All');
  Items[1] := _('Not empty');
  Items[2] := _('Not full');
  Items[3] := _('Not empty or full');
  Items[4] := _('With friends');
  i := FilterSelector(_('Players'), Items, FilterPlayers, LIST_X + FILTER_STEP, FILTER_Y,
    FILTER_W, FilterPlayers <> 0);
  if i <> FilterPlayers then
  begin
    FilterPlayers := i;
    FiltersChanged := True;
  end;

  StringFilter(2, _('Country'), CountryOptions, FilterCountry);
  StringFilter(3, _('Version'), VersionOptions, FilterVersion);
  StringFilter(4, _('OS'), OSOptions, FilterOS);
  YesNoFilter(5, _('Password'), FilterPrivate);
  YesNoFilter(6, _('Realistic'), FilterRealistic);
  YesNoFilter(7, _('Survival'), FilterSurvival);

  if FiltersChanged then
  begin
    ScrollRow := 0;
    UpdateVisibleServers;
  end
  else if (SortColumn = scPing) and (SDL_GetTicks - LastPingSort > 1000) then
  begin
    // pings keep arriving after the list was loaded
    LastPingSort := SDL_GetTicks;
    UpdateVisibleServers;
  end;

  if Button(Choose(Status = slsLoading, _('Loading...'), _('Refresh')),
    LIST_X + FULL_W - 140, 92, 140, 34, False, Status <> slsLoading) then
  begin
    RefreshServerList;
    if SelectedServer >= 0 then
      RequestServerPlayers(Servers[SelectedServer]);
  end;

  TotalPlayers := 0;
  Index := 0;
  for i := 0 to High(Servers) do
  begin
    Inc(TotalPlayers, Servers[i].NumPlayers);
    Inc(Index, Ord(IsCompatible(Servers[i])));
  end;
  Info := WideFormat(_('%d servers (%d for v%s), %d players online'),
    [Length(Servers), Index, WideString(MajorMinor(SOLDAT_VERSION)), TotalPlayers]);
  SetFont(15);
  DrawText(Info, LIST_X + FULL_W - 160 - TextWidth(Info), 92, Color(C_TEXT_DIM), 15, 34);

  // table
  SetColumn(0, _('Name'), scName, LIST_X + 40, 270);
  SetColumn(1, _('Mode'), scMode, LIST_X + 315, 65);
  SetColumn(2, _('Map'), scMap, LIST_X + 385, 165);
  SetColumn(3, _('Players'), scPlayers, LIST_X + 555, 105);
  SetColumn(4, _('Ping'), scPing, LIST_X + 665, 60);
  SetColumn(5, _('Version'), scVersion, LIST_X + 730, 85);
  SetColumn(6, _('Country'), scCountry, LIST_X + 820, 90);

  FillRect(LIST_X, LIST_Y, LIST_W, LIST_H, Color(C_PANEL, 230));
  StrokeRect(LIST_X, LIST_Y, LIST_W, LIST_H, Color(C_PANEL_LINE));
  FillRect(LIST_X + 1, LIST_Y + 1, LIST_W - 2, HEADER_H, Color($2A3220));

  for i := Low(Columns) to High(Columns) do
  begin
    Info := Columns[i].Caption;
    if SortColumn = Columns[i].Sort then
      Info := Info + Choose(SortDescending, ' v', ' ^');

    DrawText(Info, Columns[i].x, LIST_Y, Color(Choose(SortColumn = Columns[i].Sort,
      C_ACCENT, Choose(Inside(Columns[i].x, LIST_Y, Columns[i].w, HEADER_H), C_TEXT, C_TEXT_DIM))),
      15, HEADER_H);

    if MouseClicked and Inside(Columns[i].x - 6, LIST_Y, Columns[i].w, HEADER_H) then
    begin
      if SortColumn = Columns[i].Sort then
        SortDescending := not SortDescending
      else
      begin
        SortColumn := Columns[i].Sort;
        SortDescending := Columns[i].Sort = scPlayers;
      end;
      UpdateVisibleServers;
    end;
  end;

  Rows := Floor((LIST_H - HEADER_H - 2) / ROW_H);

  if Inside(LIST_X, LIST_Y, LIST_W, LIST_H) then
    ScrollRow := ScrollRow - WheelDelta * 3;
  ScrollRow := EnsureRange(ScrollRow, 0, Max(0, Length(Visible) - Rows));

  for Row := 0 to Rows - 1 do
  begin
    i := ScrollRow + Row;
    if i > High(Visible) then
      Break;

    Index := Visible[i];
    s := Servers[Index];
    y := LIST_Y + HEADER_H + 1 + Row * ROW_H;
    x := LIST_X + 1;

    if Index = SelectedServer then
      RowColor := C_SELECTED
    else if Inside(x, y, LIST_W - 2, ROW_H) then
      RowColor := C_HOVER
    else if Row mod 2 = 1 then
      RowColor := C_ROW_ALT
    else
      RowColor := C_PANEL;

    if RowColor <> C_PANEL then
      FillRect(x, y, LIST_W - 2, ROW_H, Color(RowColor));

    // favorite star
    Favorite := IsFavorite(s);
    if Inside(x, y, 34, ROW_H) then
      DrawStar(x + 18, y + ROW_H / 2 + 1, 9, Color(Choose(Favorite, $FFE680, C_TEXT)))
    else
      DrawStar(x + 18, y + ROW_H / 2 + 1, 9, Color(Choose(Favorite, $F1C40F, $4A5540)));

    if MouseClicked and Inside(x, y, 34, ROW_H) then
    begin
      ToggleFavorite(s);
      PlaySound(SFX_MENUCLICK);
      UpdateVisibleServers;
      // the rows move, don't let the same click hit another row
      MouseClicked := False;
      MouseDoubleClicked := False;
    end
    else if Inside(x, y, LIST_W - 2, ROW_H) then
    begin
      if MouseClicked then
        SelectServer(Index);
      if MouseDoubleClicked then
      begin
        SelectServer(Index);
        if not s.IsPrivate then
          JoinAddress
        else
        begin
          FocusId := ID_PASSWORD;
          SDL_StartTextInput;
        end;
      end;
    end;

    // friends play here
    if FriendsOnServer(s) > 0 then
      FillRect(Columns[0].x - 10, y + ROW_H / 2 - 3, 6, 6, Color(C_FRIEND));

    Info := WideString(s.Name);
    if s.IsPrivate then
      Info := '[P] ' + Info;
    DrawText(FitText(Info, Columns[0].w - 10, 15), Columns[0].x, y,
      Color(Choose(IsCompatible(s), C_TEXT, C_TEXT_DIM)), 15, ROW_H);
    DrawText(FitText(WideString(s.GameStyle), Columns[1].w - 10, 15), Columns[1].x, y,
      Color(C_TEXT_DIM), 15, ROW_H);
    DrawText(FitText(WideString(s.CurrentMap), Columns[2].w - 10, 15), Columns[2].x, y,
      Color(C_TEXT_DIM), 15, ROW_H);

    Info := WideFormat('%d/%d', [s.NumPlayers, s.MaxPlayers]);
    if s.NumBots > 0 then
      Info := Info + WideFormat(' (+%d)', [s.NumBots]);
    DrawText(Info, Columns[3].x, y,
      Color(Choose(s.NumPlayers > 0, C_ACCENT, C_TEXT_DIM)), 15, ROW_H);

    Ping := ServerPing(ServerKey(s));
    case Ping of
      PING_PENDING: DrawText('...', Columns[4].x, y, Color(C_TEXT_DIM), 15, ROW_H);
      PING_FAILED: DrawText('-', Columns[4].x, y, Color(C_TEXT_DIM), 15, ROW_H);
    else
      if Ping < 80 then
        RowColor := $8DB33A
      else if Ping < 150 then
        RowColor := $E0C040
      else
        RowColor := C_ERROR;
      DrawText(WideString(IntToStr(Ping)), Columns[4].x, y, Color(RowColor), 15, ROW_H);
    end;

    DrawText(FitText(WideString(s.Version), Columns[5].w - 10, 15), Columns[5].x, y,
      Color(Choose(IsCompatible(s), C_ACCENT, C_ERROR)), 15, ROW_H);
    DrawText(WideString(s.Country), Columns[6].x, y, Color(C_TEXT_DIM), 15, ROW_H);
  end;

  // scrollbar
  if Length(Visible) > Rows then
  begin
    y := LIST_Y + HEADER_H + 2;
    x := (LIST_H - HEADER_H - 4) * Rows / Length(Visible);
    FillRect(LIST_X + LIST_W - 6, y + (LIST_H - HEADER_H - 4 - x) *
      ScrollRow / Max(1, Length(Visible) - Rows), 4, x, Color(C_PANEL_LINE));
  end;

  if Length(Visible) = 0 then
  begin
    case Status of
      slsLoading: Info := _('Loading server list...');
      slsError: Info := _('Could not load the server list:') + ' ' + WideString(ServerListError);
    else
      if Length(Servers) = 0 then
        Info := _('No servers found')
      else
        Info := _('No servers match the filters');
    end;
    DrawTextCentered(FitText(Info, LIST_W - 40), LIST_X, LIST_Y + HEADER_H,
      LIST_W, LIST_H - HEADER_H, Color(Choose(Status = slsError, C_ERROR, C_TEXT_DIM)));
  end;

  DrawPlayersPanel(LIST_X + LIST_W + 16, LIST_Y, FULL_W - LIST_W - 16, LIST_H);

  // connect bar
  y := LIST_Y + LIST_H + 16;
  DrawText(_('Address'), LIST_X, y, Color(C_TEXT_DIM), 16, 38);
  if TextField(ID_ADDRESS, AddressText, LIST_X + 84, y, 416, 38, 128, 'ip:port') then
    JoinAddress;

  DrawText(_('Password'), LIST_X + 520, y, Color(C_TEXT_DIM), 16, 38);
  if TextField(ID_PASSWORD, PasswordText, LIST_X + 620, y, 290, 38, 64,
    Choose((SelectedServer >= 0) and Servers[SelectedServer].IsPrivate,
      _('Required'), _('Optional')), True) then
    JoinAddress;

  if Button(_('Connect'), LIST_X + FULL_W - 260, y, 260, 38, True, AddressText <> '') then
    JoinAddress;
end;

{******************************************************************************}
{*                         Map vote for the 1.7 client                        *}
{******************************************************************************}

procedure AddMapsFromDirectory(const Dir: string);
var
  Info: TSearchRec;
begin
  if FindFirst(Dir + '*.pms', faAnyFile, Info) = 0 then
  begin
    repeat
      MapNames.Add(ChangeFileExt(Info.Name, ''));
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
end;

// Maps the game ships with plus the ones downloaded from servers. Which of
// them a server has is unknown, servers answer the command anyway.
procedure LoadMapNames;
var
  Files: TStringArray;
  i: Integer;
  LegacyDir: string;
begin
  if MapNames = nil then
  begin
    MapNames := TStringList.Create;
    MapNames.Sorted := True;
    MapNames.Duplicates := dupIgnore;
    MapNames.CaseSensitive := False;
  end;
  MapNames.Clear;

  Files := PHYSFS_GetEnumeratedFiles('maps');
  for i := 0 to High(Files) do
    if SameText(ExtractFileExt(Files[i]), '.pms') then
      MapNames.Add(ChangeFileExt(ExtractFileName(Files[i]), ''));

  AddMapsFromDirectory(UserDirectory + 'maps/');
  LegacyDir := ExtractFilePath(LegacyClientPath);
  if LegacyDir <> '' then
  begin
    AddMapsFromDirectory(LegacyDir + 'maps/');
    AddMapsFromDirectory(LegacyDir + 'downloads/maps/');
  end;
end;

procedure LoadFavoriteMaps;
begin
  if FavoriteMaps = nil then
  begin
    FavoriteMaps := TStringList.Create;
    FavoriteMaps.Sorted := True;
    FavoriteMaps.Duplicates := dupIgnore;
    FavoriteMaps.CaseSensitive := False;
  end;
  FavoriteMaps.Clear;
  try
    if FileExists(UserDirectory + 'configs/' + FAVORITE_MAPS_FILE) then
      FavoriteMaps.LoadFromFile(UserDirectory + 'configs/' + FAVORITE_MAPS_FILE);
  except
    on E: Exception do
      MenuStatus := WideString('Could not load favorite maps: ' + E.Message);
  end;
end;

function IsFavoriteMap(const Map: string): Boolean;
begin
  Result := (FavoriteMaps <> nil) and (FavoriteMaps.IndexOf(Map) >= 0);
end;

procedure ToggleFavoriteMap(const Map: string);
var
  i: Integer;
begin
  i := FavoriteMaps.IndexOf(Map);
  if i >= 0 then
    FavoriteMaps.Delete(i)
  else
    FavoriteMaps.Add(Map);
  try
    FavoriteMaps.SaveToFile(UserDirectory + 'configs/' + FAVORITE_MAPS_FILE);
  except
    on E: Exception do
      MenuStatus := WideString('Could not save favorite maps: ' + E.Message);
  end;
end;

// Maps matching the search, favorites first.
function FilterMaps(const SearchText: WideString): TStringArray;
var
  Search: string;
  Pass, i: Integer;
begin
  Result := nil;
  Search := LowerCase(Trim(UTF8Encode(SearchText)));
  for Pass := 0 to 1 do
    for i := 0 to MapNames.Count - 1 do
      if (IsFavoriteMap(MapNames[i]) = (Pass = 0)) and
        ((Search = '') or (Pos(Search, LowerCase(MapNames[i])) > 0)) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := MapNames[i];
      end;
end;

procedure OpenMapVote;
begin
  if MapVoteActive or (LegacyProcess = nil) or not LegacyWindowShown then
    Exit;

  MapVoteActive := True;
  LoadMapNames;
  MapSearch := '';
  MapScroll := 0;
  FocusId := ID_MAPSEARCH;
  SDL_StartTextInput;

  // bring the menu window in front of the game
  SDL_RestoreWindow(GameWindow);
  SDL_RaiseWindow(GameWindow);
  OverlayActivate(GetProcessID);
end;

procedure CloseMapVote(BackToGame: Boolean);
begin
  MapVoteActive := False;
  FocusId := ID_NONE;
  SDL_StopTextInput;
  if BackToGame and (LegacyProcess <> nil) then
    OverlayActivate(LegacyProcess.ProcessID);
end;

procedure SendMapVote(const Map: string);
begin
  CloseMapVote(True);
  // "/" opens the command line of the game
  if OverlayTypeInGame('votemap ' + Map, '/') then
    SetInfoStatus(WideFormat(_('Voted for %s, see the chat of the game.'), [WideString(Map)]))
  else
    MenuStatus := _('Could not type the map vote into the Soldat 1.7 client.');
end;

procedure DrawMapVote;
const
  PX = 200;
  PY = 88;
  PW = 880;
  PH = 590;
  COLS = 3;
  CELL_W = 280;
  CELL_H = 30;
  VISIBLE_ROWS = 12;
var
  Filtered: TStringArray;
  n, Row, Col, Rows: Integer;
  x, y: Single;
begin
  FillRect(PX, PY, PW, PH, Color(C_PANEL, 245));
  StrokeRect(PX, PY, PW, PH, Color(C_ACCENT));

  DrawText(_('Change map'), PX + 24, PY + 12, Color(C_ACCENT), 22, 32, True);
  if cl_mapvote_key.Value <> '' then
    DrawText(WideFormat(_('%s or Esc to go back to the game'), [WideString(cl_mapvote_key.Value)]),
      PX + 300, PY + 12, Color(C_TEXT_DIM), 14, 32)
  else
    DrawText(_('Esc to go back to the game'), PX + 300, PY + 12, Color(C_TEXT_DIM), 14, 32);

  TextField(ID_MAPSEARCH, MapSearch, PX + 24, PY + 56, PW - 48, 34, 64, _('Search map'));

  Filtered := FilterMaps(MapSearch);

  // list in columns, scrolled by rows
  Rows := (Length(Filtered) + COLS - 1) div COLS;
  if Inside(PX, PY + 100, PW, VISIBLE_ROWS * CELL_H) then
    MapScroll := MapScroll - WheelDelta;
  MapScroll := EnsureRange(MapScroll, 0, Max(0, Rows - VISIBLE_ROWS));

  for Row := 0 to VISIBLE_ROWS - 1 do
    for Col := 0 to COLS - 1 do
    begin
      n := (MapScroll + Row) * COLS + Col;
      if n > High(Filtered) then
        Continue;
      x := PX + 24 + Col * CELL_W;
      y := PY + 104 + Row * CELL_H;
      if Inside(x, y, CELL_W - 8, CELL_H - 2) then
      begin
        FillRect(x, y, CELL_W - 8, CELL_H - 2, Color(C_HOVER));
        if MouseClicked then
        begin
          PlaySound(SFX_MENUCLICK);
          SendMapVote(Filtered[n]);
          Exit;
        end;
      end;
      if IsFavoriteMap(Filtered[n]) then
        DrawStar(x + 12, y + CELL_H / 2, 7, Color($F1C40F));
      DrawText(FitText(WideString(Filtered[n]), CELL_W - 36, 15), x + 24, y, Color(C_TEXT), 15, CELL_H - 2);
    end;

  if Length(Filtered) = 0 then
    DrawTextCentered(_('No maps found'), PX, PY + 104, PW, VISIBLE_ROWS * CELL_H, Color(C_TEXT_DIM));

  // Enter picks the only / first match
  if KeyEnter and (FocusId = ID_MAPSEARCH) and (Length(Filtered) > 0) then
  begin
    SendMapVote(Filtered[0]);
    Exit;
  end;

  // footer: hint above, count and button below
  FillRect(PX + 24, PY + PH - 98, PW - 48, 1, Color(C_PANEL_LINE));
  DrawText(FitText(_('Picking a map starts a map vote on the server, like the vote menu of the game.'),
    PW - 48, 13), PX + 24, PY + PH - 90, Color(C_TEXT_DIM), 13, 24);
  DrawText(WideFormat(_('%d maps'), [Length(Filtered)]), PX + 24, PY + PH - 50,
    Color(C_TEXT_DIM), 14, 32);
  if Button(_('Cancel'), PX + PW - 144, PY + PH - 50, 120, 32) then
    CloseMapVote(True);
end;

{******************************************************************************}
{*                                 Maps tab                                   *}
{******************************************************************************}

const
  PREVIEW_W = 1024;
  PREVIEW_H = 585;

// Renders the preview of the selected map when it changed. Must run outside
// of RenderMenu, it uses its own render target.
procedure UpdateMapPreview;
begin
  if (Tab <> tabMaps) or (SelectedMap = PreviewName) then
    Exit;
  FreeMapPreview(MapPreviewData);
  PreviewName := SelectedMap;
  if SelectedMap <> '' then
    MapPreviewData := RenderMapPreview(SelectedMap, PREVIEW_W, PREVIEW_H);
end;

procedure DrawMapsTab;
const
  LX = 40;
  LY = 140;
  LW = 400;
  ROW = 26;
  VISIBLE = 20;
  RX = 470;
  RW = 770;
  RH = 440;
var
  Filtered: TStringArray;
  i, n: Integer;
  x, y, u, v: Single;
  White: TGfxColor;
  Details, Spawns: WideString;
begin
  if MapNames = nil then
    LoadMapNames;

  TextField(ID_MAPSTAB, MapsSearch, LX, 92, LW, 34, 64, _('Search map'));
  Filtered := FilterMaps(MapsSearch);

  if (SelectedMap = '') and (Length(Filtered) > 0) then
    SelectedMap := Filtered[0];

  // list
  FillRect(LX, LY, LW, VISIBLE * ROW + 4, Color(C_PANEL, 230));
  StrokeRect(LX, LY, LW, VISIBLE * ROW + 4, Color(C_PANEL_LINE));

  if Inside(LX, LY, LW, VISIBLE * ROW) then
    MapsScroll := MapsScroll - WheelDelta * 3;
  MapsScroll := EnsureRange(MapsScroll, 0, Max(0, Length(Filtered) - VISIBLE));

  for i := 0 to VISIBLE - 1 do
  begin
    n := MapsScroll + i;
    if n > High(Filtered) then
      Break;
    x := LX + 1;
    y := LY + 2 + i * ROW;

    if SameText(Filtered[n], SelectedMap) then
      FillRect(x, y, LW - 2, ROW, Color(C_SELECTED))
    else if Inside(x, y, LW - 2, ROW) then
      FillRect(x, y, LW - 2, ROW, Color(C_HOVER));

    if IsFavoriteMap(Filtered[n]) then
      DrawStar(x + 18, y + ROW / 2, 9, Color(Choose(Inside(x, y, 34, ROW), $FFE680, $F1C40F)))
    else
      DrawStar(x + 18, y + ROW / 2, 9, Color(Choose(Inside(x, y, 34, ROW), C_TEXT, $4A5540)));

    DrawText(FitText(WideString(Filtered[n]), LW - 60, 15), x + 40, y, Color(C_TEXT), 15, ROW);

    if MouseClicked and Inside(x, y, 34, ROW) then
    begin
      ToggleFavoriteMap(Filtered[n]);
      PlaySound(SFX_MENUCLICK);
      // the list reorders, don't let the click hit another row
      MouseClicked := False;
    end
    else if MouseClicked and Inside(x, y, LW - 2, ROW) then
      SelectedMap := Filtered[n];
  end;

  DrawText(WideFormat(_('%d maps, %d favorite'), [Length(Filtered), FavoriteMaps.Count]),
    LX, LY + VISIBLE * ROW + 10, Color(C_TEXT_DIM), 14, 24);

  // preview
  FillRect(RX, 92, RW, RH, Color($0B0D08));
  StrokeRect(RX, 92, RW, RH, Color(C_PANEL_LINE));
  if MapPreviewData.Texture <> nil then
  begin
    White := RGBA($FFFFFF);
    u := MapPreviewData.Width / MapPreviewData.Texture.Width;
    v := MapPreviewData.Height / MapPreviewData.Texture.Height;
    // render targets are stored bottom up
    GfxDrawQuad(MapPreviewData.Texture,
      GfxVertex(RX + 1, 93, 0, v, White),
      GfxVertex(RX + RW - 1, 93, u, v, White),
      GfxVertex(RX + RW - 1, 92 + RH - 1, u, 0, White),
      GfxVertex(RX + 1, 92 + RH - 1, 0, 0, White));
  end
  else if SelectedMap <> '' then
    DrawTextCentered(_('No preview available for this map'), RX, 92, RW, RH, Color(C_TEXT_DIM));

  // details
  y := 92 + RH + 14;
  DrawText(WideString(SelectedMap), RX, y, Color(C_ACCENT), 24, 34, True);
  if (SelectedMap <> '') and Button(Choose(IsFavoriteMap(SelectedMap), _('Remove favorite'),
    _('Add to favorites')), RX + RW - 200, y, 200, 34) then
    ToggleFavoriteMap(SelectedMap);

  if MapPreviewData.Texture <> nil then
  begin
    y := y + 42;
    if MapPreviewData.Description <> '' then
    begin
      DrawText(FitText(WideString(MapPreviewData.Description), RW, 16), RX, y, Color(C_TEXT), 16, 26);
      y := y + 28;
    end;

    Spawns := '';
    if MapPreviewData.Spawns[1] + MapPreviewData.Spawns[2] > 0 then
      Spawns := WideFormat(_('Alpha %d, Bravo %d'), [MapPreviewData.Spawns[1], MapPreviewData.Spawns[2]]);
    if MapPreviewData.Spawns[0] > 0 then
    begin
      if Spawns <> '' then
        Spawns := Spawns + ', ';
      Spawns := Spawns + WideFormat(_('%d general'), [MapPreviewData.Spawns[0]]);
    end;

    Details := WideFormat(_('Polygons: %d    Scenery: %d    Spawn points: %s'),
      [MapPreviewData.Polygons, MapPreviewData.Scenery, Spawns]);
    DrawText(FitText(Details, RW, 15), RX, y, Color(C_TEXT_DIM), 15, 24);
    DrawText(FitText(_('Textures: ') + WideString(MapPreviewData.Textures), RW, 15),
      RX, y + 24, Color(C_TEXT_DIM), 15, 24);
  end;
end;

{******************************************************************************}
{*                              Player settings                               *}
{******************************************************************************}

function PartCvar(Part: Integer): TColorCvar;
begin
  case Part of
    0: Result := cl_player_shirt;
    1: Result := cl_player_pants;
    2: Result := cl_player_skin;
    3: Result := cl_player_hair;
  else
    Result := cl_player_jet;
  end;
end;

procedure SyncPreviewPlayer;
begin
  PreviewPlayer.Name := cl_player_name.Value;
  PreviewPlayer.ShirtColor := cl_player_shirt.Value or $FF000000;
  PreviewPlayer.PantsColor := cl_player_pants.Value or $FF000000;
  PreviewPlayer.SkinColor := cl_player_skin.Value or $FF000000;
  PreviewPlayer.HairColor := cl_player_hair.Value or $FF000000;
  PreviewPlayer.JetColor := cl_player_jet.Value or $FF000000;
  PreviewPlayer.HairStyle := cl_player_hairstyle.Value;
  PreviewPlayer.Chain := cl_player_chainstyle.Value;
  PreviewPlayer.Team := TEAM_NONE;
  PreviewPlayer.SecWep := cl_player_secwep.Value;

  case cl_player_headstyle.Value of
    HEADSTYLE_HELMET: PreviewPlayer.HeadCap := GFX_GOSTEK_HELM;
    HEADSTYLE_HAT: PreviewPlayer.HeadCap := GFX_GOSTEK_KAP;
  else
    PreviewPlayer.HeadCap := 0;
  end;

  Preview.WearHelmet := Ord(PreviewPlayer.HeadCap <> 0);
  Preview.SecondaryWeapon := Guns[PRIMARY_WEAPONS + EnsureRange(cl_player_secwep.Value, 0, 3) + 1];
end;

procedure InitPreview;
begin
  if PreviewPlayer = nil then
    PreviewPlayer := TPlayer.Create;

  Preview.Player := PreviewPlayer;
  Preview.Active := True;
  Preview.Style := 1;
  Preview.Num := 1;
  Preview.Direction := 1;
  Preview.DeadMeat := False;
  Preview.HalfDead := False;
  Preview.CeaseFireCounter := 0;
  Preview.Alpha := 255;
  Preview.Health := StartHealth;
  Preview.Vest := 0;
  Preview.HasCigar := 0;
  Preview.Fired := 0;
  Preview.Visible := 255;
  Preview.Position := POS_STAND;
  Preview.Control := Default(TControl);
  Preview.Skeleton := GostekSkeleton;
  Preview.LegsAnimation := Stand;
  Preview.BodyAnimation := Stand;
  if Preview.BodyAnimation.CurrFrame < 1 then
    Preview.BodyAnimation.CurrFrame := 1;
  if Preview.LegsAnimation.CurrFrame < 1 then
    Preview.LegsAnimation.CurrFrame := 1;
  Preview.Weapon := Guns[AK74];
  Preview.TertiaryWeapon := Guns[FRAGGRENADE];
  Preview.TertiaryWeapon.AmmoCount := 2;

  SyncPreviewPlayer;
end;

// Poses the preview skeleton like TSprite.Update does for a standing soldier
// aiming slightly forward, without any physics or map involved.
procedure UpdatePreviewPose;
const
  BODY_Y = 8;
var
  i: Integer;
  sk: ^ParticleSystem;
  Legs, Body: ^TFrame;
  Aim, P, RNorm: TVector2;
  Dir: Integer;
begin
  sk := @Preview.Skeleton;
  Dir := Preview.Direction;
  Legs := @Preview.LegsAnimation.Frames[Preview.LegsAnimation.CurrFrame];
  Body := @Preview.BodyAnimation.Frames[Preview.BodyAnimation.CurrFrame];

  for i := 1 to 20 do
  begin
    if not sk.Active[i] then
      Continue;

    sk.OldPos[i] := sk.Pos[i];

    if i in [1..6, 17, 18] then
    begin
      sk.Pos[i].X := Dir * Legs.Pos[i].X;
      sk.Pos[i].Y := Legs.Pos[i].Y;
    end
    else
    begin
      sk.Pos[i].X := Dir * Body.Pos[i].X;
      sk.Pos[i].Y := sk.Pos[6].Y + BODY_Y + Body.Pos[i].Y;
    end;
  end;

  Aim := Vector2(Dir * 120, sk.Pos[12].Y + 10);

  // head
  RNorm := Vec2Subtract(sk.Pos[12], Aim);
  Vec2Normalize(RNorm, RNorm);
  Vec2Scale(RNorm, RNorm, 0.1);
  sk.Pos[12].X := sk.Pos[9].X - Dir * RNorm.Y;
  sk.Pos[12].Y := sk.Pos[9].Y + Dir * RNorm.X;
  Vec2Scale(RNorm, RNorm, 50);
  sk.Pos[23].X := sk.Pos[9].X - Dir * RNorm.Y;
  sk.Pos[23].Y := sk.Pos[9].Y + Dir * RNorm.X;

  // arms
  RNorm := Vec2Subtract(sk.Pos[15], Aim);
  Vec2Normalize(RNorm, RNorm);
  Vec2Scale(RNorm, RNorm, -7);
  sk.Pos[15] := Vec2Add(sk.Pos[16], RNorm);

  RNorm := Vec2Subtract(sk.Pos[19], Aim);
  Vec2Normalize(RNorm, RNorm);
  Vec2Scale(RNorm, RNorm, -8);
  P := sk.Pos[16];
  P.Y := P.Y - 4;
  sk.Pos[19] := Vec2Add(P, RNorm);

  sk.Pos[21] := sk.Pos[9];
  sk.Pos[25] := sk.Pos[5];
end;

procedure DrawPreview(x, y, w, h: Single);
var
  Zoom, cx, cy: Single;
  View: TGfxMat3;
begin
  FillGradient(x, y, w, h, Color($2B3A1E), Color($151A10));
  StrokeRect(x, y, w, h, Color(C_PANEL_LINE));
  // ground line
  FillRect(x + 30, y + h - 70, w - 60, 2, Color(C_PANEL_LINE));

  // animate at the game tick rate
  while PreviewTicks > 0 do
  begin
    Preview.BodyAnimation.DoAnimation;
    Preview.LegsAnimation.DoAnimation;
    Dec(PreviewTicks);
  end;
  UpdatePreviewPose;

  // the skeleton origin is at the feet; map world units into the panel
  Zoom := 8;
  cx := x + w / 2 - 4 * Zoom;
  cy := y + h - 72;

  GfxEnd();
  View := GfxMat3Ortho(
    (OffsetX * -1 / Scale - cx) / Zoom, ((DrawW - OffsetX) / Scale - cx) / Zoom,
    (OffsetY * -1 / Scale - cy) / Zoom, ((DrawH - OffsetY) / Scale - cy) / Zoom);
  GfxTransform(View);
  GfxBegin();
  RenderGostek(Preview);
  GfxEnd();
  GfxTransform(GfxMat3Ortho(-OffsetX / Scale, (DrawW - OffsetX) / Scale,
    -OffsetY / Scale, (DrawH - OffsetY) / Scale));
  GfxBegin();

  DrawTextCentered(WideString(cl_player_name.Value), x, y + 16, w, 30, Color(C_TEXT), 22, True);
end;

procedure SetIntCvar(Cvar: TIntegerCvar; Value: Integer);
begin
  if Cvar.Value <> Value then
  begin
    Cvar.SetValue(Value);
    PlayerDirty := True;
  end;
end;

procedure DrawPlayerTab;
const
  PART_NAMES: array[0..4] of string = ('Shirt', 'Pants', 'Skin', 'Hair', 'Jets');
  HAIR_NAMES: array[0..4] of string = ('None', 'Dreadlocks', 'Punk', 'Mr. T', 'Normal');
  HEAD_NAMES: array[0..2] of string = ('None', 'Helmet', 'Hat');
  CHAIN_NAMES: array[0..2] of string = ('None', 'Silver', 'Golden');
  SECWEP_NAMES: array[0..3] of string = ('USSOCOM', 'Combat Knife', 'Chainsaw', 'M72 LAW');
  PX = 520;
var
  i, r, g, b, NewValue: Integer;
  x, y: Single;
  Items: array of WideString;
  Cvar: TColorCvar;
  c: LongWord;

  procedure SetItems(const Names: array of string);
  var
    k: Integer;
  begin
    SetLength(Items, Length(Names));
    for k := 0 to High(Names) do
      Items[k] := _(Names[k]);
  end;

begin
  DrawPreview(40, 100, 440, 560);

  // name
  DrawText(_('Nickname'), PX, 100, Color(C_TEXT_DIM), 16, 36);
  TextField(ID_NAME, NameText, PX + 210, 100, 510, 36, 24, 'Major');
  if (Trim(NameText) <> '') and (UTF8Encode(NameText) <> cl_player_name.Value) then
  begin
    if cl_player_name.SetValue(UTF8Encode(NameText)) then
    begin
      PreviewPlayer.Name := cl_player_name.Value;
      PlayerDirty := True;
    end;
  end;

  // look
  SetItems(HAIR_NAMES);
  NewValue := Selector(_('Hair style'), Items, cl_player_hairstyle.Value, PX, 156, 720);
  SetIntCvar(cl_player_hairstyle, NewValue);

  SetItems(HEAD_NAMES);
  NewValue := Selector(_('Headgear'), Items, cl_player_headstyle.Value, PX, 196, 720);
  SetIntCvar(cl_player_headstyle, NewValue);

  SetItems(CHAIN_NAMES);
  NewValue := Selector(_('Chain'), Items, cl_player_chainstyle.Value, PX, 236, 720);
  SetIntCvar(cl_player_chainstyle, NewValue);

  SetItems(SECWEP_NAMES);
  NewValue := Selector(_('Secondary weapon'), Items, cl_player_secwep.Value, PX, 276, 720);
  SetIntCvar(cl_player_secwep, NewValue);

  // colors
  y := 336;
  DrawText(_('Colors'), PX, y, Color(C_TEXT), 20, 30, True);
  y := y + 40;

  x := PX;
  for i := 0 to High(PART_NAMES) do
  begin
    c := PartCvar(i).Value and $FFFFFF;
    if ColorPart = i then
      FillRect(x, y, 136, 40, Color(C_SELECTED))
    else if Inside(x, y, 136, 40) then
      FillRect(x, y, 136, 40, Color(C_HOVER));
    FillRect(x + 8, y + 8, 24, 24, Color(c));
    StrokeRect(x + 8, y + 8, 24, 24, Color(C_PANEL_LINE));
    DrawText(_(PART_NAMES[i]), x + 42, y, Color(C_TEXT), 16, 40);
    if Inside(x, y, 136, 40) and MouseClicked then
      ColorPart := i;
    x := x + 146;
  end;

  Cvar := PartCvar(ColorPart);
  c := Cvar.Value and $FFFFFF;

  // palette
  y := y + 56;
  for i := 0 to High(PALETTE) do
  begin
    x := PX + (i mod 12) * 60;
    if i = 12 then
      y := y + 44;
    FillRect(x, y, 50, 36, Color(PALETTE[i]));
    if PALETTE[i] = c then
      StrokeRect(x - 2, y - 2, 54, 40, Color(C_TEXT), 2)
    else if Inside(x, y, 50, 36) then
      StrokeRect(x - 1, y - 1, 52, 38, Color(C_ACCENT), 2);
    if Inside(x, y, 50, 36) and MouseClicked then
    begin
      c := PALETTE[i];
      PlaySound(SFX_MENUCLICK);
    end;
  end;

  // fine tuning
  y := y + 60;
  r := Slider(ID_SLIDER_R, 'R', (c shr 16) and $FF, 255, PX + 28, y, 560, $C0392B);
  g := Slider(ID_SLIDER_G, 'G', (c shr 8) and $FF, 255, PX + 28, y + 32, 560, $3F9D20);
  b := Slider(ID_SLIDER_B, 'B', c and $FF, 255, PX + 28, y + 64, 560, $2E86C1);
  c := LongWord(r shl 16) or LongWord(g shl 8) or LongWord(b);

  FillRect(PX + 660, y, 60, 86, Color(c));
  StrokeRect(PX + 660, y, 60, 86, Color(C_PANEL_LINE));

  if c <> (Cvar.Value and $FFFFFF) then
  begin
    Cvar.SetValue(c);
    PlayerDirty := True;
  end;

  if PlayerDirty then
    SyncPreviewPlayer;
end;

{******************************************************************************}
{*                             Graphics settings                              *}
{******************************************************************************}

// Fills Resolutions with the modes of the pending monitor. Index 0 always
// means "desktop resolution".
procedure LoadResolutions;
var
  i, j, n: Integer;
  Mode: TSDL_DisplayMode;
  Exists: Boolean;
begin
  SetLength(Resolutions, 1);
  Resolutions[0].w := 0;
  Resolutions[0].h := 0;

  n := SDL_GetNumDisplayModes(PendingDisplay);
  for i := 0 to n - 1 do
  begin
    if SDL_GetDisplayMode(PendingDisplay, i, @Mode) <> 0 then
      Continue;
    if (Mode.w < 640) or (Mode.h < 480) then
      Continue;

    Exists := False;
    for j := 1 to High(Resolutions) do
      if (Resolutions[j].w = Mode.w) and (Resolutions[j].h = Mode.h) then
        Exists := True;

    if not Exists then
    begin
      SetLength(Resolutions, Length(Resolutions) + 1);
      Resolutions[High(Resolutions)].w := Mode.w;
      Resolutions[High(Resolutions)].h := Mode.h;
    end;
  end;

  // keep a custom resolution from the config selectable
  if (r_screenwidth.Value > 0) and (r_screenheight.Value > 0) then
  begin
    Exists := False;
    for j := 1 to High(Resolutions) do
      if (Resolutions[j].w = r_screenwidth.Value) and (Resolutions[j].h = r_screenheight.Value) then
        Exists := True;
    if not Exists then
    begin
      SetLength(Resolutions, Length(Resolutions) + 1);
      Resolutions[High(Resolutions)].w := r_screenwidth.Value;
      Resolutions[High(Resolutions)].h := r_screenheight.Value;
    end;
  end;
end;

procedure SelectPendingResolution(w, h: Integer);
var
  i: Integer;
begin
  PendingResolution := 0;
  for i := 1 to High(Resolutions) do
    if (Resolutions[i].w = w) and (Resolutions[i].h = h) then
      PendingResolution := i;
end;

procedure LoadPendingGraphics;
begin
  PendingDisplay := VideoDisplayIndex;
  PendingFullscreen := r_fullscreen.Value;
  PendingVsync := r_swapeffect.Value <> 0;
  PendingMsaa := r_msaa.Value;
  LoadResolutions;
  SelectPendingResolution(r_screenwidth.Value, r_screenheight.Value);
end;

procedure SaveSettings;
var
  Overrides: TStringList;
  Names: array of AnsiString;
  i: Integer;
begin
  if WindowResized then
  begin
    GraphicsDirty := True;
    WindowResized := False;
  end;

  if not (PlayerDirty or GraphicsDirty or OptionsDirty) then
    Exit;

  SetLength(Names, Length(PLAYER_CVARS) + Length(GRAPHICS_CVARS) + Length(OPTION_CVARS));
  for i := 0 to High(PLAYER_CVARS) do
    Names[i] := PLAYER_CVARS[i];
  for i := 0 to High(GRAPHICS_CVARS) do
    Names[Length(PLAYER_CVARS) + i] := GRAPHICS_CVARS[i];
  for i := 0 to High(OPTION_CVARS) do
    Names[Length(PLAYER_CVARS) + Length(GRAPHICS_CVARS) + i] := OPTION_CVARS[i];

  // MSAA can only be set at startup, so it only goes to the file
  Overrides := TStringList.Create;
  try
    Overrides.Values['r_msaa'] := IntToStr(PendingMsaa);
    SaveConfig(CONFIG_FILE, Names, Overrides);
  finally
    Overrides.Free;
  end;

  PlayerDirty := False;
  GraphicsDirty := False;
  OptionsDirty := False;
end;

procedure ApplyGraphics;
var
  w, h: Integer;
begin
  w := Resolutions[PendingResolution].w;
  h := Resolutions[PendingResolution].h;

  r_display.SetValue(PendingDisplay);
  r_fullscreen.SetValue(PendingFullscreen);
  r_screenwidth.SetValue(w);
  r_screenheight.SetValue(h);
  r_swapeffect.SetValue(Ord(PendingVsync));

  ApplyVideoSettings;

  GraphicsDirty := True;
  if PendingMsaa <> r_msaa.Value then
    GraphicsMessage := _('Settings applied. Anti-aliasing changes take effect after restarting the game.')
  else
    GraphicsMessage := _('Settings applied.');
  SaveSettings;
end;

function ResolutionName(Index: Integer): WideString;
var
  Mode: TSDL_DisplayMode;
begin
  if Resolutions[Index].w = 0 then
  begin
    SDL_GetDesktopDisplayMode(PendingDisplay, @Mode);
    Result := WideFormat(_('Desktop (%dx%d)'), [Mode.w, Mode.h]);
  end
  else
    Result := WideFormat('%dx%d', [Resolutions[Index].w, Resolutions[Index].h]);
end;

procedure DrawGraphicsTab;
const
  GX = 240;
  GW = 800;
  ROW = 36;
  FPS_VALUES: array[0..5] of Integer = (0, 60, 120, 144, 240, 360);
  MSAA_VALUES: array[0..3] of Integer = (0, 2, 4, 8);
var
  Items: array of WideString;
  i, Index, OldDisplay, OldW, OldH: Integer;
  y: Single;
  Changed: Boolean;
  Value: Boolean;
  Bounds: TSDL_Rect;
  Name: PAnsiChar;

  procedure Section(const Title: WideString);
  begin
    DrawText(Title, GX, y, Color(C_ACCENT), 20, 30, True);
    FillRect(GX, y + 32, GW, 1, Color(C_PANEL_LINE));
    y := y + 42;
  end;

  // two state selector bound to a boolean cvar
  procedure Toggle(const Caption: WideString; Cvar: TBooleanCvar);
  begin
    SetLength(Items, 2);
    Items[0] := _('Off');
    Items[1] := _('On');
    Value := Selector(Caption, Items, Ord(Cvar.Value), GX, y, GW) = 1;
    if Value <> Cvar.Value then
    begin
      Cvar.SetValue(Value);
      Changed := True;
    end;
    y := y + ROW;
  end;

begin
  FillRect(GX - 30, 90, GW + 60, 560, Color(C_PANEL, 230));
  StrokeRect(GX - 30, 90, GW + 60, 560, Color(C_PANEL_LINE));

  y := 100;
  Section(_('Display'));

  // monitor
  SetLength(Items, Max(1, SDL_GetNumVideoDisplays()));
  for i := 0 to High(Items) do
  begin
    Name := SDL_GetDisplayName(i);
    Bounds := Default(TSDL_Rect);
    SDL_GetDisplayBounds(i, @Bounds);
    if Name <> nil then
      Items[i] := WideFormat('%d: %s (%dx%d)', [i + 1, WideString(UTF8String(Name)), Bounds.w, Bounds.h])
    else
      Items[i] := WideFormat(_('Monitor %d (%dx%d)'), [i + 1, Bounds.w, Bounds.h]);
  end;
  OldDisplay := PendingDisplay;
  PendingDisplay := Selector(_('Monitor'), Items, Min(PendingDisplay, High(Items)), GX, y, GW);
  if PendingDisplay <> OldDisplay then
  begin
    // keep the chosen resolution if the other monitor supports it
    OldW := Resolutions[PendingResolution].w;
    OldH := Resolutions[PendingResolution].h;
    LoadResolutions;
    SelectPendingResolution(OldW, OldH);
  end;
  y := y + ROW;

  SetLength(Items, 3);
  Items[0] := _('Windowed');
  Items[1] := _('Fullscreen');
  Items[2] := _('Borderless window');
  PendingFullscreen := Selector(_('Display mode'), Items, PendingFullscreen, GX, y, GW);
  y := y + ROW;

  SetLength(Items, Length(Resolutions));
  for i := 0 to High(Resolutions) do
    Items[i] := ResolutionName(i);
  PendingResolution := Selector(_('Resolution'), Items, PendingResolution, GX, y, GW);
  y := y + ROW;

  SetLength(Items, 2);
  Items[0] := _('Off');
  Items[1] := _('On');
  PendingVsync := Selector(_('Vertical sync'), Items, Ord(PendingVsync), GX, y, GW) = 1;
  y := y + ROW;

  SetLength(Items, Length(MSAA_VALUES));
  Items[0] := _('Off');
  Index := 0;
  for i := 1 to High(MSAA_VALUES) do
  begin
    Items[i] := WideFormat('%dx MSAA', [MSAA_VALUES[i]]);
    if MSAA_VALUES[i] = PendingMsaa then
      Index := i;
  end;
  PendingMsaa := MSAA_VALUES[Selector(_('Anti-aliasing *'), Items, Index, GX, y, GW)];
  y := y + ROW + 4;

  if Button(_('Apply'), GX + GW - 200, y, 200, 34, True) then
    ApplyGraphics;
  if GraphicsMessage <> '' then
    DrawText(FitText(GraphicsMessage, GW - 220, 15), GX, y, Color(C_TEXT_DIM), 15, 34)
  else
    DrawText(_('* requires restarting the game'), GX, y, Color(C_TEXT_DIM), 15, 34);
  y := y + 46;

  // the options below don't need the Apply button
  Section(_('Rendering and filters'));
  Changed := False;

  SetLength(Items, Length(FPS_VALUES));
  Items[0] := _('Unlimited');
  Index := 0;
  for i := 1 to High(FPS_VALUES) do
  begin
    Items[i] := WideFormat('%d FPS', [FPS_VALUES[i]]);
    if r_fpslimit.Value and (FPS_VALUES[i] = r_maxfps.Value) then
      Index := i;
  end;
  if r_fpslimit.Value and (Index = 0) then
  begin
    // custom value from the config
    SetLength(Items, Length(Items) + 1);
    Items[High(Items)] := WideFormat('%d FPS', [r_maxfps.Value]);
    Index := High(Items);
  end;
  i := Selector(_('Frame rate limit'), Items, Index, GX, y, GW);
  if i <> Index then
  begin
    if (i = 0) or (i > High(FPS_VALUES)) then
      r_fpslimit.SetValue(i <> 0)
    else
    begin
      r_fpslimit.SetValue(True);
      r_maxfps.SetValue(FPS_VALUES[i]);
    end;
    ResetFrameTiming;
    Changed := True;
  end;
  y := y + ROW;

  // map textures are filtered when the map gets loaded
  SetLength(Items, 2);
  Items[0] := _('Nearest (pixelated)');
  Items[1] := _('Linear (smooth)');
  i := Selector(_('Texture filter'), Items, Ord(r_texturefilter.Value >= 2), GX, y, GW);
  if i <> Ord(r_texturefilter.Value >= 2) then
  begin
    r_texturefilter.SetValue(i + 1);
    Changed := True;
    GraphicsMessage := _('Texture changes are used from the next map.');
  end;
  y := y + ROW;

  Toggle(_('Mipmapping'), r_mipmapping);

  SetLength(Items, 2);
  Items[0] := _('Nearest (pixelated)');
  Items[1] := _('Linear (smooth)');
  i := Selector(_('Upscaling filter'), Items, Ord(r_resizefilter.Value >= 2), GX, y, GW);
  if i <> Ord(r_resizefilter.Value >= 2) then
  begin
    if i = 1 then
      r_resizefilter.SetValue(2)
    else
      r_resizefilter.SetValue(1);
    ResizeGameGraphics;
    Changed := True;
  end;
  y := y + ROW + 6;

  Value := Checkbox(_('Smooth polygon edges'), GX, y, r_smoothedges.Value);
  if Value <> r_smoothedges.Value then
  begin
    r_smoothedges.SetValue(Value);
    Changed := True;
  end;

  Value := Checkbox(_('Weather effects'), GX + 420, y, r_weathereffects.Value);
  if Value <> r_weathereffects.Value then
  begin
    r_weathereffects.SetValue(Value);
    Changed := True;
  end;
  y := y + 32;

  Value := Checkbox(_('Render background scenery'), GX, y, r_renderbackground.Value);
  if Value <> r_renderbackground.Value then
  begin
    r_renderbackground.SetValue(Value);
    Changed := True;
  end;

  Value := Checkbox(_('Scale interface'), GX + 420, y, r_scaleinterface.Value);
  if Value <> r_scaleinterface.Value then
  begin
    r_scaleinterface.SetValue(Value);
    ApplyVideoSettings;
    Changed := True;
  end;

  if Changed then
  begin
    GraphicsDirty := True;
    SaveSettings;
  end;
end;

{******************************************************************************}
{*                              In-game screen                                *}
{******************************************************************************}

// Shown instead of the launcher while the 1.7 client runs.
procedure DrawInGame;
const
  PX = 340;
  PY = 150;
  PW = 600;
  PH = 400;
var
  y: Single;
begin
  FillRect(PX, PY, PW, PH, Color(C_PANEL, 235));
  StrokeRect(PX, PY, PW, PH, Color(C_PANEL_LINE));

  DrawText(Choose(LegacyWindowShown, _('In game'), _('Starting the game...')),
    PX + 24, PY + 16, Color(C_ACCENT), 22, 32, True);
  DrawText(FitText(WideString(LegacyServer.Name), PW - 48, 20), PX + 24, PY + 62,
    Color(C_TEXT), 20, 30);
  DrawText(FitText(WideFormat('%s  |  %s:%d  |  Soldat %s', [WideString(LegacyServer.GameStyle),
    WideString(LegacyServer.IP), LegacyServer.Port, WideString(LegacyServer.Version)]), PW - 48, 15),
    PX + 24, PY + 94, Color(C_TEXT_DIM), 15, 24);

  y := PY + 144;
  if not LegacyWindowShown then
  begin
    DrawText(WideFormat(_('Soldat %s is loading, it joins the server by itself.'),
      [WideString(LegacyServer.Version)]), PX + 24, y, Color(C_TEXT_DIM), 16, 30);
    if Button(_('Cancel'), PX + 24, y + 54, PW - 48, 42) then
    begin
      StopLegacyClient;
      SetInfoStatus('');
    end;
    Exit;
  end;

  if Button(_('Back to game'), PX + 24, y, PW - 48, 42, True) then
    OverlayActivate(LegacyProcess.ProcessID);
  y := y + 54;
  if Button(Choose(cl_mapvote_key.Value <> '', WideFormat(_('Change map (%s)'),
    [WideString(cl_mapvote_key.Value)]), _('Change map')), PX + 24, y, PW - 48, 42) then
    OpenMapVote;
  y := y + 54;
  if Button(_('Leave server'), PX + 24, y, PW - 48, 42) then
  begin
    StopLegacyClient;
    SetInfoStatus(WideFormat(_('Left %s.'), [WideString(LegacyServer.Name)]));
  end;

  DrawText(FitText(_('The server list and settings come back after leaving the server.'), PW - 48, 14),
    PX + 24, PY + PH - 48, Color(C_TEXT_DIM), 14, 28);
end;

{******************************************************************************}
{*                                 Audio tab                                  *}
{******************************************************************************}

procedure DrawAudioTab;
const
  GX = 240;
  GW = 800;
  ROW = 36;
var
  Items: array of WideString;
  y: Single;
  v: Integer;

  procedure Toggle(const Caption: WideString; Cvar: TBooleanCvar);
  var
    Value: Boolean;
  begin
    Value := Selector(Caption, Items, Ord(Cvar.Value), GX, y, GW) = 1;
    if Value <> Cvar.Value then
    begin
      Cvar.SetValue(Value);
      OptionsDirty := True;
    end;
    y := y + ROW;
  end;

begin
  FillRect(GX - 30, 90, GW + 60, 280, Color(C_PANEL, 230));
  StrokeRect(GX - 30, 90, GW + 60, 280, Color(C_PANEL_LINE));

  y := 100;
  DrawText(_('Sound'), GX, y, Color(C_ACCENT), 20, 30, True);
  FillRect(GX, y + 32, GW, 1, Color(C_PANEL_LINE));
  y := y + 42;

  DrawText(_('Volume'), GX, y, Color(C_TEXT_DIM), 16, 30);
  v := Slider(ID_VOLUME, '', snd_volume.Value, 100, GX + 210, y + 4, GW - 260, C_ACCENT);
  if v <> snd_volume.Value then
  begin
    snd_volume.SetValue(v);
    OptionsDirty := True;
  end;
  y := y + ROW + 4;

  SetLength(Items, 2);
  Items[0] := _('Off');
  Items[1] := _('On');
  Toggle(_('Distant battle'), snd_effects_battle);
  Toggle(_('Ear ringing'), snd_effects_explosions);

  DrawText(_('Distant battle: echo of far away shots and explosions.'), GX, y + 8,
    Color(C_TEXT_DIM), 14, 24);
  DrawText(_('Ear ringing: after a grenade explodes close to you.'), GX, y + 32,
    Color(C_TEXT_DIM), 14, 24);
  DrawText(_('Used by both game clients.'), GX, y + 56, Color(C_TEXT_DIM), 14, 24);

  // a dragged slider is saved once released
  if OptionsDirty and not MouseDown then
    SaveSettings;
end;

{******************************************************************************}
{*                               Controls tab                                 *}
{******************************************************************************}

// Next word or "quoted text" of Line from position p.
function NextToken(const Line: string; var p: Integer): string;
begin
  Result := '';
  while (p <= Length(Line)) and (Line[p] = ' ') do
    Inc(p);
  if p > Length(Line) then
    Exit;

  if Line[p] = '"' then
  begin
    Inc(p);
    while (p <= Length(Line)) and (Line[p] <> '"') do
    begin
      Result := Result + Line[p];
      Inc(p);
    end;
    Inc(p);
  end
  else
    while (p <= Length(Line)) and (Line[p] <> ' ') do
    begin
      Result := Result + Line[p];
      Inc(p);
    end;
end;

// Splits a config line like: bind "A" "+left"
function ParseBind(Line: string; out Key, Command: string): Boolean;
var
  p: Integer;
begin
  Line := Trim(Line);
  p := 1;
  Result := LowerCase(NextToken(Line, p)) = 'bind';
  if Result then
  begin
    Key := NextToken(Line, p);
    Command := NextToken(Line, p);
    Result := (Key <> '') and (Command <> '');
  end;
end;

function BindActionIndex(const Command: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(BIND_ACTIONS) do
    if SameText(Command, BIND_ACTIONS[i].Command) then
      Exit(i);
end;

procedure LoadBinds;
var
  Lines: TStringList;
  Key, Command: string;
  i, a: Integer;
begin
  SetLength(BindKeys, Length(BIND_ACTIONS));
  for i := 0 to High(BindKeys) do
    BindKeys[i] := '';

  Lines := TStringList.Create;
  try
    if FileExists(UserDirectory + 'configs/' + CONFIG_FILE) then
      Lines.LoadFromFile(UserDirectory + 'configs/' + CONFIG_FILE);
    for i := 0 to Lines.Count - 1 do
      if ParseBind(Lines[i], Key, Command) then
      begin
        a := BindActionIndex(Command);
        if (a >= 0) and (BindKeys[a] = '') then
          BindKeys[a] := Key;
      end;
  finally
    Lines.Free;
  end;
  BindsLoaded := True;
end;

// Replaces the binds of the actions (and other binds of the same keys) in a
// config file with BindKeys.
procedure WriteBinds(const Path: string);
var
  Lines: TStringList;
  Key, Command: string;
  i, a, InsertAt: Integer;
  Replaced: Boolean;
begin
  if not FileExists(Path) then
    Exit;
  if not BindsLoaded then
    LoadBinds;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    InsertAt := -1;
    for i := Lines.Count - 1 downto 0 do
      if ParseBind(Lines[i], Key, Command) then
      begin
        Replaced := BindActionIndex(Command) >= 0;
        for a := 0 to High(BindKeys) do
          if SameText(Key, BindKeys[a]) then
            Replaced := True;
        if Replaced then
        begin
          Lines.Delete(i);
          InsertAt := i;
        end;
      end;

    if InsertAt < 0 then
      InsertAt := Lines.Count;
    for a := High(BIND_ACTIONS) downto 0 do
      if BindKeys[a] <> '' then
        Lines.Insert(InsertAt, 'bind "' + BindKeys[a] + '" "' + BIND_ACTIONS[a].Command + '"');
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
end;

// Saves the binds and makes the game use them.
procedure ApplyBinds;
var
  Lines: TStringList;
  Key, Command: string;
  i: Integer;
begin
  WriteBinds(UserDirectory + 'configs/' + CONFIG_FILE);

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(UserDirectory + 'configs/' + CONFIG_FILE);
    UnbindAll;
    for i := 0 to Lines.Count - 1 do
      if ParseBind(Lines[i], Key, Command) then
        ParseInput(Trim(Lines[i]));
  finally
    Lines.Free;
  end;
end;

procedure DrawControlsTab;
const
  GX = 260;
  GW = 950;
  ROW = 34;
  COL_W = 440;
  KEY_W = 220;
  MAP_KEY_ROW = Length(BIND_ACTIONS);
var
  Key: string;
  i, a, Half, v: Integer;
  x, y, Top: Single;
  Caption: WideString;
  Capturing: Boolean;
begin
  if not BindsLoaded then
    LoadBinds;

  // a key was pressed for the map vote of the 1.7 client
  if (CaptureBind = MAP_KEY_ROW) and (CapturedKey <> '') then
  begin
    if CaptureClear then
      cl_mapvote_key.SetValue('')
    else if OverlayKeyKnown(CapturedKey) then
    begin
      // the game wouldn't get the key any more
      for a := 0 to High(BindKeys) do
        if SameText(BindKeys[a], CapturedKey) then
          BindKeys[a] := '';
      ApplyBinds;
      cl_mapvote_key.SetValue(CapturedKey);
    end
    else
      MenuStatus := WideFormat(_('%s can''t open the map vote, pick a keyboard key.'),
        [WideString(CapturedKey)]);
    OptionsDirty := True;
    SaveSettings;
    CaptureBind := -1;
    CapturedKey := '';
    CaptureClear := False;
  end;

  // a key was pressed for the action waiting for one
  if (CaptureBind >= 0) and (CapturedKey <> '') then
  begin
    if CaptureClear then
      BindKeys[CaptureBind] := ''
    else
    begin
      for a := 0 to High(BindKeys) do
        if SameText(BindKeys[a], CapturedKey) then
          BindKeys[a] := '';
      BindKeys[CaptureBind] := CapturedKey;
      if SameText(cl_mapvote_key.Value, CapturedKey) then
      begin
        cl_mapvote_key.SetValue('');
        OptionsDirty := True;
        SaveSettings;
      end;
    end;
    CaptureBind := -1;
    CapturedKey := '';
    CaptureClear := False;
    ApplyBinds;
  end;

  FillRect(GX - 30, 90, GW + 60, 560, Color(C_PANEL, 230));
  StrokeRect(GX - 30, 90, GW + 60, 560, Color(C_PANEL_LINE));

  y := 100;
  DrawText(_('Mouse'), GX, y, Color(C_ACCENT), 20, 30, True);
  FillRect(GX, y + 32, GW, 1, Color(C_PANEL_LINE));
  y := y + 42;

  DrawText(_('Sensitivity'), GX, y, Color(C_TEXT_DIM), 16, 30);
  v := Slider(ID_SENSITIVITY, '', Round(cl_sensitivity.Value * 100), 100,
    GX + 240, y + 4, GW - 300, C_ACCENT);
  if v <> Round(cl_sensitivity.Value * 100) then
  begin
    cl_sensitivity.SetValue(v / 100);
    OptionsDirty := True;
  end;
  if OptionsDirty and not MouseDown then
    SaveSettings;
  y := y + 48;

  DrawText(_('Keys'), GX, y, Color(C_ACCENT), 20, 30, True);
  FillRect(GX, y + 32, GW, 1, Color(C_PANEL_LINE));
  Top := y + 42;

  // the actions, then the map vote of the 1.7 client
  Half := (MAP_KEY_ROW + 2) div 2;
  for i := 0 to MAP_KEY_ROW do
  begin
    x := GX + (i div Half) * (COL_W + 40);
    y := Top + (i mod Half) * ROW;
    if i = MAP_KEY_ROW then
    begin
      DrawText(_('Change map'), x, y, Color(C_TEXT_DIM), 16, ROW - 4);
      Key := cl_mapvote_key.Value;
    end
    else
    begin
      DrawText(_(BIND_ACTIONS[i].Caption), x, y, Color(C_TEXT_DIM), 16, ROW - 4);
      Key := BindKeys[i];
    end;

    Capturing := CaptureBind = i;
    if Capturing then
      Caption := _('Press a key...')
    else if Key = '' then
      Caption := '-'
    else
      Caption := WideString(Key);

    x := x + COL_W - KEY_W;
    FillRect(x, y, KEY_W, ROW - 4, Color(Choose(Capturing, C_SELECTED,
      Choose(Inside(x, y, KEY_W, ROW - 4), C_HOVER, $11140D))));
    StrokeRect(x, y, KEY_W, ROW - 4, Color(Choose(Capturing, C_ACCENT, C_PANEL_LINE)));
    DrawTextCentered(FitText(Caption, KEY_W - 12, 15), x, y, KEY_W, ROW - 4,
      Color(C_TEXT), 15);

    if (CaptureBind < 0) and MouseClicked and Inside(x, y, KEY_W, ROW - 4) then
    begin
      PlaySound(SFX_MENUCLICK);
      CaptureBind := i;
      CapturedKey := '';
    end;
  end;

  DrawText(FitText(_('Click an action, then press a key or mouse button. Esc cancels, ' +
    'Delete removes the key. Used by both game clients.'), GW, 14),
    GX, Top + Half * ROW + 6, Color(C_TEXT_DIM), 14, 24);
end;

{******************************************************************************}
{*                                 Main loop                                  *}
{******************************************************************************}

procedure UpdateLayout;
var
  ww, wh: Integer;
begin
  SDL_GL_GetDrawableSize(GameWindow, @DrawW, @DrawH);
  if (DrawW <= 0) or (DrawH <= 0) then
  begin
    SDL_GetWindowSize(GameWindow, @ww, @wh);
    DrawW := ww;
    DrawH := wh;
  end;

  Scale := Min(DrawW / DESIGN_W, DrawH / DESIGN_H);
  OffsetX := (DrawW - DESIGN_W * Scale) / 2;
  OffsetY := (DrawH - DESIGN_H * Scale) / 2;
end;

procedure PollInput;
var
  Event: TSDL_Event;
  ww, wh: Integer;
  px, py: Single;
  Mods: Word;
begin
  MouseClicked := False;
  MouseDoubleClicked := False;
  WheelDelta := 0;
  TypedText := '';
  KeyBackspace := False;
  KeyEnter := False;
  KeyEscape := False;
  KeyUp := False;
  KeyDown := False;
  KeyPaste := False;

  SDL_GetWindowSize(GameWindow, @ww, @wh);
  Event := Default(TSDL_Event);

  while SDL_PollEvent(@Event) = 1 do
  begin
    case Event.type_ of
      SDL_QUITEV:
        RequestQuit;

      SDL_WINDOWEVENT:
        if Event.window.event = SDL_WINDOWEVENT_SIZE_CHANGED then
        begin
          HandleWindowResized(Event.window.data1, Event.window.data2);
          if (Tab = tabSettings) and (SettingsPage = spGraphics) then
            LoadPendingGraphics;
        end;

      SDL_MOUSEMOTION:
      begin
        // window coordinates to drawable pixels to design units
        px := Event.motion.x * DrawW / Max(1, ww);
        py := Event.motion.y * DrawH / Max(1, wh);
        MouseX := (px - OffsetX) / Scale;
        MouseY := (py - OffsetY) / Scale;
      end;

      SDL_MOUSEBUTTONDOWN:
        if CaptureBind >= 0 then
          CapturedKey := 'MOUSE' + IntToStr(Event.button.button)
        else if Event.button.button = SDL_BUTTON_LEFT then
        begin
          px := Event.button.x * DrawW / Max(1, ww);
          py := Event.button.y * DrawH / Max(1, wh);
          MouseX := (px - OffsetX) / Scale;
          MouseY := (py - OffsetY) / Scale;
          MouseDown := True;
          MouseClicked := True;
          MouseDoubleClicked := Event.button.clicks >= 2;
        end;

      SDL_MOUSEBUTTONUP:
        if Event.button.button = SDL_BUTTON_LEFT then
        begin
          MouseDown := False;
          DragId := ID_NONE;
        end;

      SDL_MOUSEWHEEL:
        Inc(WheelDelta, Event.wheel.y);

      SDL_TEXTINPUT:
        TypedText := TypedText +
          WideString(UTF8String(RawByteString(PChar(@Event.text.text[0]))));

      SDL_KEYDOWN:
        if CaptureBind >= 0 then
        begin
          case Event.key.keysym.sym of
            SDLK_ESCAPE: CaptureBind := -1;
            SDLK_DELETE:
            begin
              CaptureClear := True;
              CapturedKey := '-';
            end;
          else
            CapturedKey := string(SDL_GetScancodeName(Event.key.keysym.scancode));
          end;
        end
        else
        begin
          Mods := Event.key.keysym._mod;
          case Event.key.keysym.sym of
            SDLK_BACKSPACE: KeyBackspace := True;
            SDLK_RETURN, SDLK_KP_ENTER: KeyEnter := True;
            SDLK_ESCAPE: KeyEscape := True;
            SDLK_UP: KeyUp := True;
            SDLK_DOWN: KeyDown := True;
            SDLK_v: KeyPaste := (Mods and KMOD_CTRL) <> 0;
          end;
        end;
    end;
  end;
end;

procedure HandleListKeys;
var
  i, Current: Integer;
begin
  if (Tab <> tabServers) or (FocusId <> ID_NONE) or (Length(Visible) = 0) then
    Exit;

  Current := -1;
  for i := 0 to High(Visible) do
    if Visible[i] = SelectedServer then
      Current := i;

  if KeyDown then
    SelectServer(Visible[Min(High(Visible), Current + 1)]);
  if KeyUp then
    SelectServer(Visible[Max(0, Current - 1)]);
  if KeyEnter and (SelectedServer >= 0) then
    JoinAddress;
end;

procedure SwitchSettingsPage(NewPage: TSettingsPage);
begin
  SaveSettings;
  if FocusId <> ID_NONE then
    SDL_StopTextInput;
  FocusId := ID_NONE;
  DragId := ID_NONE;
  GraphicsMessage := '';
  CaptureBind := -1;
  SettingsPage := NewPage;

  // the binds could have been changed from the console in game
  if SettingsPage = spControls then
    LoadBinds;
  if SettingsPage = spGraphics then
    LoadPendingGraphics;
end;

procedure SwitchTab(NewTab: TMenuTab);
begin
  Tab := NewTab;
  SwitchSettingsPage(SettingsPage);
end;

procedure DrawGeneralSettings;
const
  GX = 240;
  GW = 800;
var
  Items: array of WideString;
  Value: Boolean;
begin
  FillRect(GX - 30, 90, GW + 60, 250, Color(C_PANEL, 230));
  StrokeRect(GX - 30, 90, GW + 60, 250, Color(C_PANEL_LINE));

  DrawText(_('Soldat 1.7.1 client'), GX, 100, Color(C_ACCENT), 20, 30, True);
  FillRect(GX, 132, GW, 1, Color(C_PANEL_LINE));
  TextField(ID_LEGACY, LegacyText, GX, 144, GW, 32, 1024,
    Choose(LegacyClientPath <> '', WideString(LegacyClientPath),
      _('Downloaded on first use of a 1.7.1 server')));
  if UTF8Encode(LegacyText) <> cl_legacy_client.Value then
  begin
    cl_legacy_client.SetValue(UTF8Encode(LegacyText));
    PlayerDirty := True;
  end;
  if (LegacyText <> '') and not FileExists(UTF8Encode(LegacyText)) then
    DrawText(_('File not found'), GX, 180, Color(C_ERROR), 14, 24)
  else
    DrawText(_('Path to soldat_x64, empty for the downloaded client.'), GX, 180,
      Color(C_TEXT_DIM), 14, 24);

  DrawText(_('Updates'), GX, 220, Color(C_ACCENT), 20, 30, True);
  FillRect(GX, 252, GW, 1, Color(C_PANEL_LINE));
  SetLength(Items, 2);
  Items[0] := _('Off');
  Items[1] := _('On');
  Value := Selector(_('Check for updates'), Items, Ord(cl_update_check.Value), GX, 264, GW) = 1;
  if Value <> cl_update_check.Value then
  begin
    cl_update_check.SetValue(Value);
    OptionsDirty := True;
    SaveSettings;
  end;
  DrawText(_('Asks GitHub for the latest release when the game starts.'), GX, 300,
    Color(C_TEXT_DIM), 14, 24);
end;

procedure DrawSettingsTab;
const
  NAV_X = 40;
  NAV_W = 150;

  procedure Page(const Caption: WideString; p: TSettingsPage; y: Single);
  var
    Hover: Boolean;
  begin
    Hover := Inside(NAV_X, y, NAV_W, 40);
    if SettingsPage = p then
    begin
      FillRect(NAV_X, y, NAV_W, 40, Color(C_PANEL, 230));
      FillRect(NAV_X, y, 3, 40, Color(C_ACCENT));
    end;
    DrawText(Caption, NAV_X + 16, y, Color(Choose((SettingsPage = p) or Hover, C_TEXT, C_TEXT_DIM)),
      18, 40, True);
    if Hover and MouseClicked and (SettingsPage <> p) then
    begin
      PlaySound(SFX_MENUCLICK);
      SwitchSettingsPage(p);
    end;
  end;

begin
  Page(_('Graphics'), spGraphics, 90);
  Page(_('Audio'), spAudio, 134);
  Page(_('Controls'), spControls, 178);
  Page(_('General'), spGeneral, 222);

  case SettingsPage of
    spGraphics: DrawGraphicsTab;
    spAudio: DrawAudioTab;
    spControls: DrawControlsTab;
    spGeneral: DrawGeneralSettings;
  end;
end;

procedure RenderMenu;
var
  Status, Caption: WideString;
  x, w: Single;
  Tag, URL: string;
  Output: string;
begin
  GfxTarget(nil);
  GfxViewport(0, 0, DrawW, DrawH);
  GfxClear(RGBA(C_BG_BOTTOM));
  GfxTransform(GfxMat3Ortho(-OffsetX / Scale, (DrawW - OffsetX) / Scale,
    -OffsetY / Scale, (DrawH - OffsetY) / Scale));
  GfxTextPixelRatio(Vector2(1 / Scale, 1 / Scale));
  GfxTextShadow(1, 1, RGBA(0, 0, 0, 160));
  GfxTextVerticalAlign(GFX_TOP);
  GfxTextScale(1);

  GfxBegin();

  // background covering the whole window, not only the design area
  FillGradient(-OffsetX / Scale, -OffsetY / Scale, DrawW / Scale, DrawH / Scale,
    Color(C_BG_TOP), Color(C_BG_BOTTOM));

  // header
  FillRect(-OffsetX / Scale, 0, DrawW / Scale, 72, Color($0B0D08, 200));
  FillRect(-OffsetX / Scale, 72, DrawW / Scale, 1, Color(C_PANEL_LINE));
  DrawText('SOLDAT', 40, -8, Color(C_ACCENT), 34, 72, True);
  DrawText(WideString('okkindel remix  r' + REMIX_VERSION), 42, 50, Color(C_TEXT_DIM), 13, 16);

  // newer release on GitHub, opens its page
  if UpdateAvailable(Tag, URL) then
  begin
    Caption := WideFormat(_('%s available'), [WideString(Tag)]);
    // primary buttons use the bold font
    SetFont(17, True);
    w := TextWidth(Caption) + 32;
    if Button(Caption, DESIGN_W - 156 - w, 18, w, 36, True) then
      RunCommand('xdg-open', [URL], Output);
  end;

  // the launcher pages are hidden while the 1.7 client runs
  if not InGame then
  begin
    x := 280;
    if TabButton(_('Servers'), x, 14, 150, 58, Tab = tabServers) then
      SwitchTab(tabServers);
    if TabButton(_('Player'), x + 160, 14, 150, 58, Tab = tabPlayer) then
      SwitchTab(tabPlayer);
    if TabButton(_('Maps'), x + 320, 14, 150, 58, Tab = tabMaps) then
      SwitchTab(tabMaps);
    if TabButton(_('Settings'), x + 480, 14, 150, 58, Tab = tabSettings) then
      SwitchTab(tabSettings);
  end;

  if Button(_('Quit'), DESIGN_W - 140, 18, 100, 36) then
  begin
    SaveSettings;
    RequestQuit;
  end;

  if MapVoteActive then
    DrawMapVote
  else if InGame then
    DrawInGame
  else
    case Tab of
      tabServers: DrawServersTab;
      tabPlayer: DrawPlayerTab;
      tabMaps: DrawMapsTab;
      tabSettings: DrawSettingsTab;
    end;

  // status line
  Status := MenuStatus;
  if Status <> '' then
  begin
    FillRect(-OffsetX / Scale, DESIGN_H - 32, DrawW / Scale, 32, Color($0B0D08, 200));

    // progress bar for the 1.7 client download
    if LegacyDownloadPending and (LegacyDownloadState = ldsRunning) then
    begin
      FillRect(DESIGN_W - 340, DESIGN_H - 22, 300, 12, Color($11140D));
      FillRect(DESIGN_W - 340, DESIGN_H - 22, 3 * LegacyDownloadProgress, 12, Color(C_ACCENT));
      StrokeRect(DESIGN_W - 340, DESIGN_H - 22, 300, 12, Color(C_PANEL_LINE));
      x := DESIGN_W - 400;
    end
    else
      x := DESIGN_W - 80;

    DrawText(FitText(Status, x - 40, 15), 40, DESIGN_H - 32,
      Color(Choose(Status = InfoStatus, C_ACCENT, C_ERROR)), 15, 32);
  end;

  GfxEnd();
  GfxPresent(r_glfinish.Value);
end;

procedure InitMenu;
var
  LegacyDir: string;
begin
  LoadFavorites;
  LoadFavoriteMaps;
  LoadFriends;

  // the HTTP threads would load OpenSSL at the same time otherwise
  InitSSLInterface;
  if cl_update_check.Value then
    StartUpdateCheck;

  // maps (and their textures) the 1.7 client downloaded from servers, with
  // the lowest priority, for the map lists and previews
  LegacyDir := ExtractFilePath(LegacyClientPath);
  if (LegacyDir <> '') and DirectoryExists(LegacyDir + 'downloads') then
    PHYSFS_mount(PChar(LegacyDir + 'downloads'), '/', True);
  LegacyText := WideString(cl_legacy_client.Value);
  NameText := WideString(cl_player_name.Value);
  InitPreview;
  LoadPendingGraphics;
  MenuInitialized := True;
end;

procedure MainMenuLoop;
var
  LastTicks, Now: UInt32;
  TickAccum: Double;
begin
  if not MenuInitialized then
    InitMenu
  else
  begin
    // the player could have changed settings from the console in game
    NameText := WideString(cl_player_name.Value);
    SyncPreviewPlayer;
  end;

  // use the system cursor in the menu
  SDL_SetRelativeMouseMode(SDL_FALSE);
  SDL_ShowCursor(SDL_ENABLE);
  SDL_StopTextInput;
  FocusId := ID_NONE;
  DragId := ID_NONE;
  MouseDown := False;

  if not ListRequested then
  begin
    ListRequested := True;
    RefreshServerList;
  end;

  LastTicks := SDL_GetTicks;
  TickAccum := 0;

  while not (PendingJoin or QuitRequested) do
  begin
    UpdateLayout;
    PollInput;

    // preview animation runs at the game tick rate
    Now := SDL_GetTicks;
    TickAccum := TickAccum + (Now - LastTicks) * DEFAULT_GOALTICKS / 1000;
    LastTicks := Now;
    PreviewTicks := Min(10, Trunc(TickAccum));
    TickAccum := TickAccum - Trunc(TickAccum);

    if KeyEscape and (FocusId <> ID_NONE) then
    begin
      FocusId := ID_NONE;
      SDL_StopTextInput;
    end;

    if OverlayHotkeyPressed then
    begin
      if MapVoteActive then
        CloseMapVote(True)
      else
        OpenMapVote;
    end
    else if MapVoteActive and KeyEscape then
      CloseMapVote(True);

    if not (MapVoteActive or InGame) then
      HandleListKeys;
    CheckLegacyProcess;
    CheckLegacyDownload;
    UpdateMapPreview;
    UpdateServerPreview;
    RenderMenu;

    // there is nothing to simulate here, so don't burn the CPU
    if r_swapeffect.Value = 0 then
      SDL_Delay(8);
  end;

  SaveSettings;
  // quitting the launcher closes the 1.7 client as well
  if QuitRequested then
    StopLegacyClient;
  SDL_StopTextInput;
  SDL_ShowCursor(SDL_DISABLE);
end;

finalization
  FreeAndNil(PreviewPlayer);
  FreeAndNil(Favorites);
  FreeAndNil(Friends);
  FreeAndNil(LegacyProcess);
  FreeAndNil(MapNames);
  FreeAndNil(FavoriteMaps);
end.
