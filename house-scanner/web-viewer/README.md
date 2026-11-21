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

## Model and Splats

When the ZIP contains the LiDAR mesh (`mesh/*.ply`, from the LiDAR walk), two more things happen:

- **Better textures and real furniture (Model).** The mesh's depth is rendered from every photo's camera on the GPU, so each photo only colours what it really sees: furniture no longer gets painted onto the wall behind it. Furniture is shown with its real scanned shape (the mesh inside each RoomPlan box), coloured from the photos. The RoomPlan boxes stay underneath for tapping and sizes.
- **Splats.** A *Splats* button appears: the whole LiDAR mesh as up to 600,000 flat Gaussian splats, each coloured from the photos that see it, rendered with [Spark](https://sparkjs.dev). It shows everything the sensor saw (shelves, plants, lamps), not only RoomPlan's walls and boxes. It is an instant preview made in the browser, not trained Gaussian splatting, so it is softer than a trained result. Cutaway, Walk and tapping work in both looks.

Photos are matched to each other before blending (a brightness and colour gain per photo, worked out from spots several photos see), the best photo per spot is strongly preferred so slightly misaligned photos don't blur, and spots no photo saw are filled smoothly from the colours around them.

**Several levels:** rooms on different floors are grouped into levels. Each room is cut away 1.25 m above its own floor, Walk keeps you 1.6 m above the floor you're on, and *Lower / Upper* (or *Level n*) shows one level at a time.

To test a scan without picking the file, serve this folder (`python3 -m http.server`) and open `/?zip=path/to/house-scan.zip`.

## How the textures are made

Every wall and floor from RoomPlan is a flat plane. For each texel (80 per metre), the viewer works out its 3D position and projects it into the photos using the camera position and lens data ARKit recorded for each photo. It blends the photos that see that spot best: facing it, close by, not near the photo's edge, and not hidden behind another wall. Furniture stays as plain blocks.

## Files

| File | |
|---|---|
| `index.html` | The viewer |
| `sample-house.json` | Example house, in the app's `house-scene.json` format |
| `sample/` | Example photos and `keyframes.json`, rendered from the example house |
| `tools/make-sample.*` | Script that rendered the example photos (`node tools/make-sample.js scene.json outDir`, run from `tools/`) |
