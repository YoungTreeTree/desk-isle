# Built-in BB8 asset

The user-provided BB8 model was adapted for DeskIsle by baking surface details into
two 512×512 textures and keeping a simplified sphere, dome, lenses and antennae.
The bundled GLB has 7,521 triangles, 4,057 vertices and a 12-second `idle` loop:
side-to-side rolling, eased stops and independent head motion. The PNG is a static
transparent preview from the same software renderer.

Only BB8 is bundled. User-imported GLBs, including other character models, remain
in the local layout library and are not included in the repository.

These are macOS application resources. Models are uploaded into device RAM at
runtime; no character assets are built into the firmware. Source GLBs and prepared
runtime data use the same immutable layout-asset storage as custom imports.

The BB8 character asset is separate from the project's MIT-licensed code. No
separate character-asset redistribution license accompanies the supplied source.
