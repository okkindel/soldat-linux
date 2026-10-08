<div align="center">
  <img src="https://i.imgur.com/HrYPYjh.png" />
  <h2>opensoldat</h2>
  <a href="https://discord.soldat.pl"><img src="https://img.shields.io/discord/234733999879094272.svg" /></a>
</div>

Opensoldat is a unique 2D (side-view) multiplayer action game. It has been influenced by the best of games such as Liero, Worms, Quake, Counter-Strike, and provides a fast-paced gaming experience with tons of blood and flesh.

This repository contains the source code of the so-called 1.8 version. Compared to the original version, the code has undergone many changes but is not in a finished state. We hope that by open-sourcing Soldat we can empower our community to improve the game at a faster pace.

## okkindel remix: Soldat 1.8 and 1.7.1 on Linux

This fork is a version of opensoldat that you can build on Linux and that runs natively, without Wine. It adds a game menu and lets you play on both Soldat 1.8 and Soldat 1.7.1 servers from one server list.

- **Game menu.** The game starts in a menu instead of requiring `-join`, and returns there after leaving a server:
  - *Servers*: the public server list (the same one as on [soldat.pl/lobby](https://www.soldat.pl/pl/lobby)) with search, filters (mode, players, country, version, OS, password, realistic, survival), sorting, ping, favorites pinned to the top, and direct connect by address.
  - *Player*: nickname, colors, hair, headgear, chain and secondary weapon with a live preview of your soldier.
  - *Graphics*: monitor, window mode, resolution, vsync, frame limit, texture and scaling filters. Changes apply without a restart, and the window can be resized in windowed mode.
- **Settings are saved** to `client.cfg`, keeping your binds.
- **Soldat 1.8 and 1.7.1 servers** both work, see below.

### Installing

Download `soldat_<version>_amd64.deb` from [Releases](https://github.com/okkindel/soldat/releases) and install it:

```sh
sudo apt install ./soldat_*_amd64.deb
```

Then start *Soldat* from the applications menu, or run `soldat`. The package targets Ubuntu 22.04 / Linux Mint 21 and newer. The game is installed to `/opt/soldat`, your settings, logs, screenshots and downloaded maps are kept in `~/.local/share/soldat`.

### How playing on 1.7.1 servers works

Soldat 1.8 (this code) and Soldat 1.7.1 use different network protocols, so this client cannot talk to 1.7.1 servers itself. Nearly all public servers still run 1.7.1. To play there anyway:

1. The server list shows each server's version. 1.8 servers are joined by this client directly. Servers with another version (shown in red) are joined with the **original native Soldat 1.7.1 Linux client**.
2. That client is the official build linked from the [Soldat wiki](https://wiki.soldat.pl/index.php/Soldat_on_macOS_and_Linux). It is not part of this repository: CMake downloads it from `update.soldat.pl` while building (checking its SHA256), and the Debian package ships it in `/opt/soldat/legacy`.
3. When you join a 1.7.1 server, the menu writes your nickname, look, display and sound settings into the 1.7.1 client's own `configs/client.cfg` (it uses the same cvars) and starts it with `-join ip port [password]`. Its binds and other settings stay untouched.
4. Because it is the official client, the servers' anti-cheat works as usual.

5. **Changing the map:** the map vote menu of the 1.7.1 client doesn't work. Press **F10** in game instead: the menu comes up with a searchable list of maps, and picking one types the map command into the game chat for you (chat key T, then Enter). The command defaults to `!map <map>`, which servers with a map script (for example the #Rzal ones) understand; it can be changed in the same panel (saved as `cl_mapvote_command`, `%s` is the map name).

Limitations: the 1.7.1 client can't be told which monitor to use, so it opens where it decides. A custom 1.7.1 client path can be set in the field at the bottom of the *Servers* tab (saved as `cl_legacy_client`).

## Dependencies

- FreePascal 3.0.4
- SDL 2.0.12
- OpenAL
- FreeType 2.6.1
- PhysFS 3.0.2
- [GameNetworkingSockets v1.4.0](https://github.com/ValveSoftware/GameNetworkingSockets/releases/tag/v1.4.0)

## Building opensoldat

This fork is built and tested on Linux. (Upstream opensoldat also compiles on Windows and macOS, see the [original repository](https://github.com/opensoldat/opensoldat).)

### Compilation using CMake

This approach automates some build steps. Opensoldat's assets will be downloaded for you, and you will not have to worry about downloading pre-built libraries. This is the simplest way to build opensoldat for Linux.

CMake 3.14+ is required.

#### Build steps for Linux (Ubuntu)

1. `sudo apt-get install build-essential g++ cmake git fpc libprotobuf-dev protobuf-compiler libssl-dev libsdl2-dev libopenal-dev libphysfs-dev libfreetype6`
2. `mkdir build && cd build`
3. `cmake ..`
4. `make`
5. Run `bin/soldat` (the game starts in the menu)

On Linux x86_64, `cmake` also downloads the native Soldat 1.7.1 client (~185 MB) into `bin/legacy`, used for 1.7.1 servers. Pass `-DADD_LEGACY_CLIENT=0` to skip it.

To build an installable Debian/Ubuntu/Mint package, run `make deb` in the `build` directory. It creates `soldat_<version>_amd64.deb` (needs `dpkg-deb`, and `unzip` plus ImageMagick's `convert` for the menu icon).

#### Available flags

The build can be customized by passing flags to `cmake` command. For example, you can choose whether you want to build the client, the server, or both. You can decide if you want to include opensoldat's assets in the build. There are also options for cross-compilation.

Check the `CMakeLists.txt` files in this repository to see the available options and their default values.

Example: `cmake .. -DCMAKE_BUILD_TYPE=Release -DADD_ASSETS=1 -DBUILD_CLIENT=0` to get a release build of the server with opensoldat's assets

### Compilation using other methods

If you decide to follow the approaches below, you will have to download opensoldat's assets and pre-built libraries for the game to work.
1. Download pre-built libraries. The best way would probably be to download libraries from the latest build of opensoldat (from Github Actions, or Releases). You can download latest from [here](https://nightly.link/Soldat/soldat/workflows/soldat/develop) (includes libraries for 3 platforms - pick the ones you need) 2. Copy libraries to `client/build` and `server/build`
3. Get soldat.smod file from [base repository](https://github.com/opensoldat/base.git). You can either download the file from the [latest release](https://github.com/opensoldat/base/releases/latest) (recommended), or generate the .smod file yourself following the provided instructions
4. Copy `soldat.smod` file to `client/build` and `server/build`
5. Download `play-regular.ttf` file from [base repository](https://github.com/opensoldat/base), either from the [latest release](https://github.com/opensoldat/base/releases/latest) or from `base/client` folder
6. Copy `play-regular.ttf` file to `client/build`

## Running opensoldat

Run `soldat` and pick a server in the menu. To join a server directly without the menu, run `soldat -join ip port` (for example `soldat -join 127.0.0.1 23073`).

To host your own server, run `soldatserver` and connect to it by its address in the menu.
