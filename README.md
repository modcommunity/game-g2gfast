This is a **timer server** built on TMC's **Dot** collection, rather than a piece of it. It is the bunny-hop and surf half of the family put together into something a community could actually host.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This project is built out of them, so it doubles as a worked example of what they look like in a real game rather than in a demo.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## A Timer Server in the Competitive-Shooter Shape
**A bunny-hop and surf timer for Godot 4, in the shape of the movement servers
the genre grew up on.**

The genre's movement in its own units, `sv_autobunnyhopping` and the rest of the cvars,
a timer with zones an admin draws from the console, styles, records, first and third
person, and every player drawn as an avatar — theirs from the platform, or a stock one.

## Playing it

```bash
godot --path .
```

| | |
| --- | --- |
| **WASD** / **Space** / **Shift** | Move, jump (hold it, if the server allows), duck |
| **F5** | First / third person |
| **Tab** | Cycle style — normal, sideways, half-sideways, backwards, low gravity, prebhop |
| **R** | Back to the start |
| **C** / **V** | Save a practice checkpoint / go back to it |
| **M** | Next map |

## Running a server

```bash
godot --headless --path . res://examples/dedicated.tscn
```

`server.cfg`, in the units you already know:

```
sv_tickrate 100
sv_autobunnyhopping 1
sv_airaccelerate 1000        // 150 for surf
sv_gravity 800
sv_allow_thirdperson 1
sv_replay_bot 1            # run the server record as a visible ghost
```

`--g2g-auto-bhop=0`, `G2G_AIR_ACCELERATE=150` and a JSON file all work too: the config
is layered like every `DotConfig`.

Then, from the console, zone a map whose author never used this engine:

```
g2g_zone start
g2g_zone_mark          // stand on one corner
g2g_zone_mark          // and the other
g2g_zone stage main 1
...
g2g_zone_save
```

## What it uses

dot-fps-controller · dot-timer · dot-map · dot-leaderboard · dot-server ·
dot-user-avatar · dot-ui · dot-core. Symlink them for development:

```bash
for pair in dot_core:dot-core dot_fps_controller:dot-fps-controller dot_timer:dot-timer \
            dot_map:dot-map dot_leaderboard:dot-leaderboard dot_ui:dot-ui \
            dot_server:dot-server dot_user_avatar:dot-user-avatar; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done
```

## Validating

```bash
godot --headless --path . --import
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_run.tscn   # 90 checks
godot --headless --path . res://examples/headless_net.tscn   # 76 checks, server + client in one process
godot --headless --path . res://examples/dedicated.tscn      # 52 checks
```

[`CLAUDE.md`](CLAUDE.md) has the four decisions and the reasoning.

## Licence

MIT. See [LICENSE](LICENSE).
