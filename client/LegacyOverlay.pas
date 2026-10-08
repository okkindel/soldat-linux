{*******************************************************}
{                                                       }
{       Legacy Overlay Unit for SOLDAT                  }
{                                                       }
{       While the Soldat 1.7 client runs, a hotkey      }
{       brings up the menu to pick a map and types the  }
{       chosen chat command into the game. The map      }
{       vote menu of that client doesn't work.          }
{                                                       }
{*******************************************************}

unit LegacyOverlay;

interface

// Starts listening for the hotkey (F10) while the client with this process
// id is running.
procedure OverlayStart(GamePid: Integer);
procedure OverlayStop;
// True once for every hotkey press since the last call.
function OverlayHotkeyPressed: Boolean;
// Brings the window of the given process to the front.
procedure OverlayActivate(Pid: Integer);
// Activates the game window and types Text into its chat (opened with
// ChatKey), then presses Enter. Returns False when it was not possible.
function OverlayTypeInGame(const Text: string; ChatKey: Char = 't'): Boolean;

implementation

uses
  SysUtils, ctypes, dynlibs, x, xlib, xatom, keysym;

type
  TXTestFakeKeyEvent = function(Dpy: PDisplay; Keycode: cuint; IsPress: TBool;
    Delay: culong): cint; cdecl;

var
  Dpy: PDisplay = nil;
  HotkeyCode: TKeyCode;
  TargetPid: Integer;
  XTestLib: TLibHandle = NilHandle;
  XTestFakeKeyEvent: TXTestFakeKeyEvent = nil;

const
  // the hotkey must work with Caps Lock and Num Lock on as well
  LOCK_MASKS: array[0..3] of cuint = (0, LockMask, Mod2Mask, LockMask or Mod2Mask);

// The game can quit (and its window vanish) any time, which must not take
// the menu down with Xlib's default error handler.
function IgnoreXError(Display: PDisplay; Event: PXErrorEvent): cint; cdecl;
begin
  Result := 0;
end;

function LoadXTest: Boolean;
begin
  if XTestLib = NilHandle then
  begin
    XTestLib := LoadLibrary('libXtst.so.6');
    if XTestLib <> NilHandle then
      XTestFakeKeyEvent := TXTestFakeKeyEvent(GetProcedureAddress(XTestLib, 'XTestFakeKeyEvent'));
  end;
  Result := Assigned(XTestFakeKeyEvent);
end;

procedure OverlayStart(GamePid: Integer);
var
  i: Integer;
begin
  OverlayStop;
  TargetPid := GamePid;

  Dpy := XOpenDisplay(nil);
  if Dpy = nil then
    Exit;

  XSetErrorHandler(@IgnoreXError);
  HotkeyCode := XKeysymToKeycode(Dpy, XK_F10);
  for i := Low(LOCK_MASKS) to High(LOCK_MASKS) do
    XGrabKey(Dpy, HotkeyCode, LOCK_MASKS[i], DefaultRootWindow(Dpy), 0,
      GrabModeAsync, GrabModeAsync);
  XFlush(Dpy);
end;

procedure OverlayStop;
var
  i: Integer;
begin
  if Dpy = nil then
    Exit;

  for i := Low(LOCK_MASKS) to High(LOCK_MASKS) do
    XUngrabKey(Dpy, HotkeyCode, LOCK_MASKS[i], DefaultRootWindow(Dpy));
  XCloseDisplay(Dpy);
  Dpy := nil;
end;

function OverlayHotkeyPressed: Boolean;
var
  Event: TXEvent;
begin
  Result := False;
  if Dpy = nil then
    Exit;

  while XPending(Dpy) > 0 do
  begin
    XNextEvent(Dpy, @Event);
    if (Event._type = KeyPress) and (Event.xkey.keycode = HotkeyCode) then
      Result := True;
  end;
end;

function WindowPid(Win: TWindow; PidAtom: TAtom): Integer;
var
  ActualType: TAtom;
  Format: cint;
  Count, After: culong;
  Data: pcuchar;
begin
  Result := -1;
  Data := nil;
  if XGetWindowProperty(Dpy, Win, PidAtom, 0, 1, False, XA_CARDINAL, @ActualType,
    @Format, @Count, @After, @Data) <> Success then
    Exit;
  if (Data <> nil) and (Count = 1) then
    Result := PCULong(Data)^;
  if Data <> nil then
    XFree(Data);
end;

// Top level window of a process, from the window manager's client list.
function FindWindow(Pid: Integer): TWindow;
var
  ListAtom, PidAtom, ActualType: TAtom;
  Format: cint;
  Count, After: culong;
  Data: pcuchar;
  Windows: PWindow;
  i: Integer;
begin
  Result := 0;
  ListAtom := XInternAtom(Dpy, '_NET_CLIENT_LIST', True);
  PidAtom := XInternAtom(Dpy, '_NET_WM_PID', True);
  if (ListAtom = None) or (PidAtom = None) then
    Exit;

  Data := nil;
  if XGetWindowProperty(Dpy, DefaultRootWindow(Dpy), ListAtom, 0, 4096, False,
    XA_WINDOW, @ActualType, @Format, @Count, @After, @Data) <> Success then
    Exit;

  if Data <> nil then
  begin
    Windows := PWindow(Data);
    for i := 0 to Integer(Count) - 1 do
      if WindowPid(Windows[i], PidAtom) = Pid then
      begin
        Result := Windows[i];
        Break;
      end;
    XFree(Data);
  end;
end;

function ActivateWindow(Win: TWindow): Boolean;
var
  Event: TXEvent;
begin
  Result := Win <> 0;
  if not Result then
    Exit;

  FillChar(Event, SizeOf(Event), 0);
  Event.xclient._type := ClientMessage;
  Event.xclient.window := Win;
  Event.xclient.message_type := XInternAtom(Dpy, '_NET_ACTIVE_WINDOW', False);
  Event.xclient.format := 32;
  Event.xclient.data.l[0] := 2; // request from a pager, honored by most WMs
  Event.xclient.data.l[1] := CurrentTime;
  XSendEvent(Dpy, DefaultRootWindow(Dpy), False,
    SubstructureRedirectMask or SubstructureNotifyMask, @Event);
  XRaiseWindow(Dpy, Win);
  XSync(Dpy, False);
end;

procedure OverlayActivate(Pid: Integer);
begin
  if Dpy <> nil then
    ActivateWindow(FindWindow(Pid));
end;

procedure PressKey(Code: TKeyCode; Shift: Boolean);
var
  ShiftCode: TKeyCode;
begin
  ShiftCode := XKeysymToKeycode(Dpy, XK_Shift_L);
  // X booleans are integers: 1 = press, 0 = release
  if Shift then
    XTestFakeKeyEvent(Dpy, ShiftCode, 1, 0);
  XTestFakeKeyEvent(Dpy, Code, 1, 0);
  XTestFakeKeyEvent(Dpy, Code, 0, 0);
  if Shift then
    XTestFakeKeyEvent(Dpy, ShiftCode, 0, 0);
  XFlush(Dpy);
  // the game reads input once per frame
  Sleep(25);
end;

// Latin-1 characters have keysyms equal to their code.
function TypeChar(c: Char): Boolean;
var
  Sym: TKeySym;
  Code: TKeyCode;
begin
  Sym := Ord(c);
  Code := XKeysymToKeycode(Dpy, Sym);
  Result := Code <> 0;
  if Result then
    PressKey(Code, XKeycodeToKeysym(Dpy, Code, 0) <> Sym);
end;

function OverlayTypeInGame(const Text: string; ChatKey: Char): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (Dpy = nil) or not LoadXTest then
    Exit;

  if not ActivateWindow(FindWindow(TargetPid)) then
    Exit;
  // let the window manager hand over the focus
  Sleep(400);

  TypeChar(ChatKey);
  Sleep(150);
  for i := 1 to Length(Text) do
    TypeChar(Text[i]);
  PressKey(XKeysymToKeycode(Dpy, XK_Return), False);
  Result := True;
end;

finalization
  OverlayStop;
end.
