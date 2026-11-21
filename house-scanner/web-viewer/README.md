# House Model Viewer

A three.js page that rebuilds a House Scanner scan as an interactive 3D model, with walls and floors textured from the photos taken during the scan.

Open `index.html` in a browser. It starts with an example house. Tap **Open scan** (or drag a file onto the page) to load:

- **`house-scan.zip`** from the app: the model plus the photos, so walls and floors get real textures.
- **`house-scene.json`**: the model only, without textures.

Views:

- **3D**: orbit around a dollhouse view. *Cutaway* slices the walls at 1.25 m so you can see inside.
- **Plan**: top-down view with a 1 m grid.
- **Walk**: eye-height view (1.6 m). Drag to look around, tap the floor to walk there.
- Tap furniture, doors or windows to see their size. Use the room chips to hide or show rooms, and *Textures* to switch the photos on or off.

> The textured example needs the page to be served over http (for example `python3 -m http.server` in this folder). Opened straight from disk, the browser blocks loading the sample photos and the example shows without textures. Your own ZIP works either way.

## How the textures are made

Every wall and floor from RoomPlan is a flat plane. For each texel (80 per metre), the viewer works out its 3D position and projects it into the photos using the camera position and lens data ARKit recorded for each photo. It blends the photos that see that spot best: facing it, close by, not near the photo's edge, and not hidden behind another wall. Furniture stays as plain blocks.

## Files

| File | |
|---|---|
| `index.html` | The viewer |
| `sample-house.json` | Example house, in the app's `house-scene.json` format |
| `sample/` | Example photos and `keyframes.json`, rendered from the example house |
| `tools/make-sample.*` | Script that rendered the example photos (`node tools/make-sample.js scene.json outDir`, run from `tools/`) |
