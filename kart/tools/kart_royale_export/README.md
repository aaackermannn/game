# kart-royale model export

The kart + driver models in `assets/models/kart_royale/` come from
[ryancampbell/kart-royale](https://github.com/ryancampbell/kart-royale) (MIT, see
`assets/models/kart_royale/LICENSE-kart-royale.txt`). That project builds every
mesh procedurally in TypeScript, so these scripts run its generator in Node and
write one `.glb` per Loop GP racer (vertex-coloured liveries, no textures).

To regenerate:

1. Download kart-royale next to this folder as `../kr-src/kart-royale-main`
   (or edit the import paths in `export.ts`).
2. `npm i three@0.185.1 simplex-noise@4.0.3 esbuild@0.25.10`
3. `node build.mjs && node export.mjs <output-folder>`

Changes vs the original: rotated to face -Z (Godot forward), wheels as
`WheelFL/FR/RL/RR` pivots, driver split into `Pilot` / `Head`, the decal sheet
dropped (it is a canvas texture), tyre rubber baked dark.
