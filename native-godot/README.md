# Dustline Native: Courtyard

A separate, **native desktop** tactical FPS experiment using **Godot 4.7.2**.
An experimental **Sol + Astra run**, inspired by Counter-Strike's Dust2 route
structure. This is an original single-map interpretation, **not the exact Valve
map**, not an asset extraction, and not affiliated with Valve.

The existing Rust/Bevy browser game stays unchanged in the parent folder and on
GitHub Pages. This project does not require a browser, Unreal, Epic account,
proprietary engine plugins, or commercial asset packs.

![Native A site, captured in Godot on Windows](docs/a-site.png)
![Roofed upper tunnels, captured in Godot on Windows](docs/tunnels.png)

Actual native-renderer screenshots, with staged camera positions for map review.
These are not concept art or a claimed continuous gameplay recording.

## Play locally

On the configured Windows machine, double-click **Play Windows.cmd** in this
folder. It uses the standalone build if available, otherwise the portable Godot
installation. Or import `project.godot` in Godot 4.7.2 and press **F6/F5** to run.

The default renderer is **Forward+ / Vulkan**. If the GPU or driver has trouble,
use **Play Windows - Compatibility.cmd** for the lighter OpenGL renderer.

For Linux/WSL development, from the repository root:

```sh
bash native-godot/tools/setup.sh         # pinned, verified portable engine
bash native-godot/Play\ Linux.sh
```

Use native Windows on a Windows/WSL host for graphics; WSL software rendering
is not representative of desktop performance. A packaged build needs no editor.

## Controls and feedback

Press **Enter / Deploy**. The seven-second buy phase freezes everyone, then
**ROUND LIVE** unlocks movement and firing. You play CT with four bot teammates
against five attackers. Defend A/B, or hold E near a planted device for five
seconds to defuse. First to five rounds wins.

| Action | Input |
| --- | --- |
| Move / look | WASD / mouse |
| Fire / aim or scope | Left / right mouse button |
| Reload | R |
| Jump / walk / crouch | Space / Shift / Ctrl |
| Armory / select purchase | B / 1–4 during buy phase |
| Defuse | Hold E near device |
| Scoreboard / pause | Tab / Escape |
| Fullscreen / diagnostics | F11 / F3 |
| Save a screenshot directly | F8 |

**Escape → Copy feedback details** puts build, renderer, FPS, position, weapon,
health and shot statistics on the clipboard. Paste it with what felt wrong.
**F8** saves a screenshot without needing an external screenshot shortcut;
**Escape → Open screenshots folder** finds the files. Nothing uploads
automatically. Sound is generated noise/tones; there is no recorded soundtrack.

## First native prototype

- One larger original desert layout: long, mid, short/catwalk, roofed upper/lower
  tunnels, two sites, raised A platform, ramps and separated spawns.
- Procedural plaster/masonry shaders, sunlight/shadows, skyline, facade details,
  crates, palms, original operator and four first-person weapon models.
- Acceleration and braking, jumping, walking, crouching, recoil, reloads, economy.
  Weapon type, firing cadence, movement and stance all affect precision.
- Radius-aware pathfinding and checked corner/strafe clearance. Bots follow
  routes, scan ahead, react to visible targets, remember/hear contacts, burst,
  reload, plant and defuse. Physics rays block sight and shots at walls.
- Native 0.2 adds one bomb carrier, visible dropped-device recovery, timed and
  interruptible plants, separate defuse/cover roles, and sight-based squad
  backup calls. Bots settle for firing bursts and hold fire behind teammates.

This is a playable foundation, not CS2-level art or a finished competitive game.
It is single-player with bots, not online multiplayer. The native gameplay is
new; it does not claim full feature parity with the browser version. No grenades,
networking, exact Dust2 dimensions, Valve art, or recorded weapon sounds.

## Verification

```sh
bash native-godot/tools/check.sh
```

To produce standalone Windows and Linux packages (close running local builds
before rebuilding):

```sh
bash native-godot/tools/setup.sh --templates  # first time: 1.28 GB official archive
bash native-godot/tools/build.sh
```

Outputs are `builds/windows/DustlineNative.exe` (keep its `.pck` beside it) and
`builds/linux/DustlineNative.x86_64`. The archive is not shipped with the game.
Export templates and the native engine have already been installed on the
configured local machine. No Unreal/Epic software was installed.

The native suites include **107 core checks, 47 tactical checks and four complete
seeded 5v5 rounds** with a bot replacing the human for equal-team observation.
The tactical tests cover carrier death/recovery, plant interruption, human defuse
ownership, teammate shot obstruction, burst movement and expiring radio contacts.
The seeded checks measure sustained lack of navigation progress independently
of the bots' own replan timer. These samples are not a general difficulty rating.
Windows Forward+ / Vulkan has also been playtested on an RTX 2060. Linux
packages have been smoke-tested headlessly, not visually on a Linux desktop.

Runs Godot's actual importer, then a fast fixed-timestep headless integration
suite: all key map routes, body clearance, buy freeze, real input movement,
collision, weapon spread/recoil/reload, economy, blocked shots/sight, objective
ownership, generated PCM sound and a live bot round. Both error logs and the
test sentinel are checked because Godot can return exit 0 after a script error.
This is correctness testing, **not a GPU performance benchmark**.

`tests/visual.gd` runs a native renderer smoke test and saves labelled staged
views under `builds/captures`. It exercises movement, shooting and reloading;
the later staged viewpoints are visual tests, not a continuous gameplay clip.

## Open-source provenance

All project code, map geometry, shaders, sounds and original models are MIT
licensed; see [LICENSE](LICENSE). The six GLBs are copies of this repository's
own Blender-authored models, generated by `../scripts/make-operators.py` and
`../scripts/make-weapons.py`. No third-party graphics or audio files are used in
this native project. These copies keep it independent of the browser asset tree.

[Godot is MIT licensed](https://godotengine.org/license/), with open-source
third-party components and bundled font notices in [licenses](licenses).
Official binaries and export templates are pinned to 4.7.2 and verified against
the [official SHA-512 release manifest](https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/SHA512-SUMS.txt).
Engine/tool binaries, caches and game builds are ignored by Git. The build does
not change system services, file associations, firewall or registry settings.
