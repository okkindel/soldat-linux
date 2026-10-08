{*******************************************************}
{                                                       }
{       Map Preview Unit for SOLDAT                     }
{                                                       }
{       Renders a whole map (background and textured    }
{       polygons, no scenery) into a texture for the    }
{       maps tab of the main menu                       }
{                                                       }
{*******************************************************}

unit MapPreview;

interface

uses
  Gfx;

type
  TMapPreview = record
    Texture: TGfxTexture;   // nil when the map could not be loaded
    Width, Height: Integer; // used part of the texture
    Description: string;
    Polygons: Integer;
    Scenery: Integer;
    Spawns: array[0..5] of Integer; // per team, 0 = general
    Textures: string;
    Weather: Integer;
    Steps: Integer;
  end;

// Loads the map by its name (as in the maps/ directory) and renders it into
// a W x H texture. Free the result with FreeMapPreview.
function RenderMapPreview(const MapName: string; W, H: Integer): TMapPreview;
procedure FreeMapPreview(var Preview: TMapPreview);

implementation

uses
  SysUtils, Math, Client, ClientGame, GameRendering, MapFile, PolyMap, Util,
  PhysFS;

function LoadTexture(const TexName: string): TGfxTexture;
var
  Image: TGfxImage;
  Filename: string;
  w, h: Integer;
begin
  Image := nil;
  Filename := FindImagePath('textures/' + TexName);
  if PHYSFS_exists(PChar(Filename)) then
  begin
    Image := TGfxImage.Create(Filename, RGBA(0, 0, 0, Byte(0)));
    if Image.GetImageData() = nil then
      FreeAndNil(Image);
  end;

  if Image = nil then
  begin
    Filename := FindImagePath('textures/default.bmp');
    if PHYSFS_exists(PChar(Filename)) then
      Image := TGfxImage.Create(Filename, RGBA(0, 0, 0, Byte(0)));
  end;
  if (Image = nil) or (Image.GetImageData() = nil) then
  begin
    FreeAndNil(Image);
    Image := TGfxImage.Create(32, 32);
  end;

  Image.Premultiply();

  // repeating textures need power of two sizes on old hardware
  w := Npot(Image.Width);
  h := Npot(Image.Height);
  if (w <> Image.Width) or (h <> Image.Height) then
    Image.Resize(w, h);

  Result := GfxCreateTexture(w, h, 4, Image.GetImageData());
  GfxTextureWrap(Result, GFX_REPEAT, GFX_REPEAT);
  GfxTextureFilter(Result, GFX_LINEAR, GFX_LINEAR);
  Image.Free;
end;

function MapColorToGfx(const c: TMapColor): TGfxColor;
begin
  Result := RGBA(c[0], c[1], c[2], c[3]);
end;

function RenderMapPreview(const MapName: string; W, H: Integer): TMapPreview;
const
  BACKPOLY = [POLY_TYPE_BACKGROUND, POLY_TYPE_BACKGROUND_TRANSITION];
var
  Info: TMapInfo;
  Map: TMapFile;
  Textures: array of TGfxTexture;
  Bounds: TGfxRect;
  i, j, Level: Integer;
  cx, cy, bw, bh, Aspect: Single;
  Poly: PMapPolygon;
  v: array[1..3] of TGfxVertex;
  Top, Bottom: TGfxColor;
begin
  Result := Default(TMapPreview);
  Map := Default(TMapFile);

  if not GetMapInfo(MapName, UserDirectory, Info) then
    Exit;
  if not LoadMapFile(Info, Map) then
    Exit;

  Result.Description := Map.MapName;
  Result.Polygons := Length(Map.Polygons);
  Result.Scenery := Length(Map.Props);
  Result.Weather := Map.Weather;
  Result.Steps := Map.Steps;
  for i := 0 to High(Map.Spawnpoints) do
    if Map.Spawnpoints[i].Active and (Map.Spawnpoints[i].Team >= 0) and
      (Map.Spawnpoints[i].Team <= High(Result.Spawns)) then
      Inc(Result.Spawns[Map.Spawnpoints[i].Team]);
  for i := 0 to High(Map.Textures) do
  begin
    if i > 0 then
      Result.Textures := Result.Textures + ', ';
    Result.Textures := Result.Textures + Map.Textures[i];
  end;

  if Length(Map.Polygons) = 0 then
    Exit;

  // map bounds, widened to the aspect ratio of the preview
  Bounds.Left := Map.Polygons[0].Vertices[1].x;
  Bounds.Right := Bounds.Left;
  Bounds.Top := Map.Polygons[0].Vertices[1].y;
  Bounds.Bottom := Bounds.Top;
  for i := 0 to High(Map.Polygons) do
    for j := 1 to 3 do
    begin
      Bounds.Left := Min(Bounds.Left, Map.Polygons[i].Vertices[j].x);
      Bounds.Right := Max(Bounds.Right, Map.Polygons[i].Vertices[j].x);
      Bounds.Top := Min(Bounds.Top, Map.Polygons[i].Vertices[j].y);
      Bounds.Bottom := Max(Bounds.Bottom, Map.Polygons[i].Vertices[j].y);
    end;

  bw := Max(1, Bounds.Right - Bounds.Left) * 1.04;
  bh := Max(1, Bounds.Bottom - Bounds.Top) * 1.04;
  cx := (Bounds.Left + Bounds.Right) / 2;
  cy := (Bounds.Top + Bounds.Bottom) / 2;
  Aspect := W / H;
  if bw / bh > Aspect then
    bh := bw / Aspect
  else
    bw := bh * Aspect;

  SetLength(Textures, Length(Map.Textures));
  for i := 0 to High(Textures) do
    Textures[i] := LoadTexture(Map.Textures[i]);

  Result.Width := W;
  Result.Height := H;
  Result.Texture := GfxCreateRenderTarget(Npot(W), Npot(H));
  GfxTextureFilter(Result.Texture, GFX_LINEAR, GFX_LINEAR);

  GfxTarget(Result.Texture);
  GfxViewport(0, 0, W, H);
  GfxClear(0, 0, 0, 255);

  // sky gradient
  Top := MapColorToGfx(Map.BgColorTop);
  Bottom := MapColorToGfx(Map.BgColorBtm);
  Top.a := 255;
  Bottom.a := 255;
  GfxTransform(GfxMat3Ortho(0, 1, 0, 1));
  GfxBegin();
  GfxDrawQuad(nil,
    GfxVertex(0, 0, 0, 0, Top), GfxVertex(1, 0, 0, 0, Top),
    GfxVertex(1, 1, 0, 0, Bottom), GfxVertex(0, 1, 0, 0, Bottom));
  GfxEnd();

  // background polygons first, then the rest, as in the game
  GfxTransform(GfxMat3Ortho(cx - bw / 2, cx + bw / 2, cy - bh / 2, cy + bh / 2));
  GfxBegin();
  for Level := 0 to 1 do
    for i := 0 to High(Map.Polygons) do
    begin
      Poly := @Map.Polygons[i];
      if Level <> Ord(not (Poly.PolyType in BACKPOLY)) then
        Continue;

      for j := 1 to 3 do
        v[j] := GfxVertex(Poly.Vertices[j].x, Poly.Vertices[j].y,
          Poly.Vertices[j].u, Poly.Vertices[j].v, MapColorToGfx(Poly.Vertices[j].Color));

      if Poly.TextureIndex <= High(Textures) then
        GfxDrawQuad(Textures[Poly.TextureIndex], v[1], v[2], v[3], v[3])
      else
        GfxDrawQuad(nil, v[1], v[2], v[3], v[3]);
    end;
  GfxEnd();

  GfxTarget(nil);
  for i := 0 to High(Textures) do
    GfxDeleteTexture(Textures[i]);
end;

procedure FreeMapPreview(var Preview: TMapPreview);
begin
  if Preview.Texture <> nil then
    GfxDeleteTexture(Preview.Texture);
  Preview := Default(TMapPreview);
end;

end.
