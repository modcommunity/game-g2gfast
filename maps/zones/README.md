# What a map does not say about itself

One file per map, named for its id, merged into the manifest by `tools/bsp_import.py`.

**Coordinates in here are Hammer's**, the ones the tools in `tools/` print — the axis
swap and the yaw conversion happen once, in the importer, where every other
coordinate's does. A file that mixed the two would be a file nobody can check against
the map it describes.

Five of the eight maps beside this directory label their own zones: `zone_start`,
`map_end_zone`, `startzone_s4`, `tm_bonus2_endzone`. Those are read straight out of
the entity lump and need nothing here. This directory is for the other three, and for
the halves the labelled ones are missing — and every entry says **why**, because a
finish line is a judgement about a map somebody played, and the next person to look
at it deserves the evidence rather than a number.

## What a zone may say

A volume, exactly one of:

| | |
| --- | --- |
| `"box": [[x,y,z],[x,y,z]]` | two corners, Hammer coordinates |
| `"named": "targetname"` | the brush volume of the entity(ies) with that name |
| `"teleport_to": "dest"` | the `trigger_teleport` aimed at that destination (`"all": true` to union them) |
| `"around": {"point": …, "extents": [x,y,z]}` | a box grown around a destination name, a list of them, or a literal point |
| `"near": {"class": "trigger_multiple", "point": [x,y,z], "within": 512}` | the nearest brush entity of that class |

Plus `"kind"`, `"track"`, `"number"` (a stage), `"destination"` (a name or a point),
`"destination_yaw"`, and `"note"`.

`"doorways": {"max_horizontal": 512}` opts a map into the rule that a teleport volume
narrower than that is a **door the player walks through** rather than the pit —
`TELEPORT`, which keeps the run, rather than `RESPAWN`, which ends it. It is not on by
default because it is only true of a map whose sections are joined by doors.

Anything a rule cannot resolve is an error and stops the import. That is deliberate:
a finish line that silently resolved to nothing is a map that cannot be finished, and
nothing about playing it would say so.
