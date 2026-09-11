# The prototype texture set

Six PNGs, one per [G2GTextures] `Role`. Dropping them here is the whole installation: `G2GTextures._texture_for` looks each role up by the name in `ROLE_FILES` and falls back to the generated grid when a file is absent, so nothing here is a dependency and removing a file is a supported state rather than a break.

These are **Kenney's Prototype Textures 1.0** (`kenney.nl`), released under **CC0 1.0** — public domain, no attribution required, which is strictly more permissive than the MIT this repository ships under. `LICENSE.txt` is Kenney's own, copied unchanged. Only the six files actually referenced are vendored; the kit itself is 6 colours × 13 patterns and the rest is not needed here.

| File | Role | Kenney source | Why |
| --- | --- | --- | --- |
| `ramp.png` | `RAMP` | `PNG/Orange/texture_05.png` | The one surface a player *rides*, so it is the one colour nothing else in the map wears — and its diagonals run with the slope, which is the cue a surfer reads a ramp's direction from at 3000 u/s |
| `platform.png` | `PLATFORM` | `PNG/Light/texture_02.png` | Anything standable. Bright, because a player looking for where to land is looking for a floor |
| `floor.png` | `FLOOR` | `PNG/Dark/texture_02.png` | Walls and ceilings. Dark, so the ride reads in front of them instead of competing with them |
| `start.png` | `START` | `PNG/Green/texture_02.png` | Inside the start zone |
| `end.png` | `END` | `PNG/Red/texture_02.png` | Inside the finish zone |
| `bonus.png` | `BONUS` | `PNG/Purple/texture_02.png` | A bonus route, visibly not the main one |

**The set carries its own colour, so the role tint stops applying.** The generated grid is greyscale and is multiplied by `ROLE_COLOURS`; these are not, and multiplying Kenney's orange by the RAMP blue is a double tint that produces mud. `G2GTextures.material_for` therefore paints an installed set white. That is why the roles are distinguished by *file* here rather than by tint.

**One square is 64 units, on every surface in the game.** Kenney's tile is 8 squares across where the generated one is 4, so `INSTALLED_SQUARES_PER_TILE` is what keeps the two the same size in the world — swapping the set must not change how fast the ground appears to move, because that appearance is how a player judges their speed.

Both the hand-built maps and the imported `.bsp` maps draw from this directory. The imported ones get their role from the **geometry** rather than from a material name — see `tools/bsp_import.py`.

**`texture_02` and not `texture_13`, which is the same grid.** Kenney's file numbering is not the same pattern in every colour folder, and several of the `texture_13`s have `WALL / 1 x 1 meter / 1024 x 1024` painted into the corner of the image. Tiled across a map that is a label repeating every nine metres, and the number on it is wrong here anyway — a tile is eight 64-unit squares, which is 9.75 m, not one. Checked per file rather than per number, because the number does not mean the same thing twice.
