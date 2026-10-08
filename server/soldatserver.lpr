{*********************************************************}
{                                                         }
{   Soldatserver                                          }
{                                                         }
{   Copyright (c) 2001 Michal Marcinkowski                }
{                                                         }
{*********************************************************}

program soldatserver;

uses
  cthreads, // needs to be first included unit in project
  {$IFDEF AUTOUPDATER}
  AutoUpdater,
  {$ENDIF}
  Main in 'Main.pas';

begin
  {$IFDEF AUTOUPDATER}
  StartAutoUpdater;
  {$ENDIF}
  RunServer;

  DefaultSystemCodePage := CP_UTF8;
end.
