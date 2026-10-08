{*******************************************************}
{                                                       }
{       SOLDAT                                          }
{                                                       }
{       Copyright (c) 2001 Michal Marcinkowski          }
{                                                       }
{*******************************************************}

program soldat;

uses
  cthreads,
  cwstring,
  SysUtils,
  {$IFDEF AUTOUPDATER}AutoUpdater,{$ENDIF}
  Client in 'Client.pas';

begin
  {$IFDEF AUTOUPDATER}
  StartAutoUpdater;
  {$ENDIF}

  DefaultSystemCodePage := CP_UTF8;

  StartGame;
  RunClient;
end.
