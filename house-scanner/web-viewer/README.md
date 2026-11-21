# House Model Viewer

A three.js page that rebuilds a House Scanner scan as an interactive 3D model.

Open `index.html` in any browser (desktop or phone). It starts with an example house. Tap **Open scan** (or drag a file onto the page) to load the `house-scene.json` exported from the app.

- **3D**: orbit around a dollhouse view. *Cutaway* slices the walls at 1.25 m so you can see inside.
- **Plan**: top-down view with a 1 m grid.
- **Walk**: eye-height view (1.6 m). Drag to look around, tap the floor to walk there.
- Tap furniture, doors or windows to see their size. Use the room chips to hide or show rooms.

Walls get a thickness of 10 cm, because the scanner gives flat walls. Door and window holes are cut into the walls they belong to.

`sample-house.json` is the example data, in the same format as the app's export.
