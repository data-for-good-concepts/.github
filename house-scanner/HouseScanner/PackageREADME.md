# House Scanner package

This folder is a scan of a home made with an iPhone LiDAR sensor. It combines four kinds of data, all in **one shared 3D coordinate system**:

1. **RoomPlan**: Apple's clean, labelled model of the rooms (walls, doors, windows, openings, floors, furniture as boxes).
2. **Photos**: sharp still frames with the exact camera position and lens data for each one.
3. **LiDAR mesh**: ARKit's raw triangle mesh of everything the sensor saw, with a label for each triangle.
4. **Video poses**: the camera position for every frame of the scan video. The video files themselves are exported separately because of their size.

Use it to build a 3D rendering of the home. RoomPlan gives clean architecture with exact measurements. The mesh gives the real shapes of furniture and objects. The photos give colours and textures for both.

## Conventions (all files)

- Units: **metres**. Axes: **right-handed, +Y up** (the same as three.js and glTF). Floor level is around y = 0.
- Every transform is a **4×4 matrix, 16 numbers, column-major**. In three.js: `new THREE.Matrix4().fromArray(m)`.
- All files share the same world space. Several scanning sessions are combined by ARKit relocalisation, so they share it too.

## Files

| File | What it is |
|---|---|
| `manifest.json` | Index of the files, counts, device, number of sessions. Start here. |
| `house-scene.json` | Clean RoomPlan model, documented in its own `notes` field. `rooms[]` each have `walls`, `doors`, `windows`, `openings`, `floors` and `objects`. Every item has `id`, `position` (centre), `rotationY` (radians), `size` [width, height, depth], `matrix` and `confidence`. Doors, windows and openings have `parentId`, the id of the wall they sit in. Floors and non-rectangular walls have `corners` (world space). Objects have `category` (sofa, table, bed, …). Surfaces are flat, so one of their sizes is 0: give walls a thickness (about 0.1 m) when rendering. `bounds` holds the overall extent. |
| `roomplan-raw.json` | Apple's full `CapturedRoom` data for each room (more detail, Apple's own encoding). Usually `house-scene.json` is enough. |
| `keyframes.json` + `keyframes/*.jpg` | Still photos, 960×720. Each frame has `file`, `width`, `height`, `intrinsics` [fx, fy, cx, cy] in pixels of that image, `transform` (camera-to-world) and `time`. |
| `mesh/mesh-N.ply` | LiDAR mesh of session N (binary little-endian PLY). Vertices: `float x, y, z` in world space. Faces: `list uchar uint vertex_indices` (always 3) and `uchar classification`. |
| `video-poses*.json` | Same structure as `keyframes.json`, one entry per video frame (no `file`; `time` is seconds into that session's video). Images are 1920×1440 (the sensor's landscape orientation). |

### Mesh classification values

`0` none (often furniture and objects) · `1` wall · `2` floor · `3` ceiling · `4` table · `5` seat · `6` window · `7` door

## Projecting a 3D point into a photo

The cameras follow ARKit's convention: the camera looks down **−Z**, **+Y** is up and **+X** is right, in the sensor's landscape orientation (the photos are stored in that orientation, not rotated).

```
(X, Y, Z) = inverse(transform) · (Px, Py, Pz, 1)       // world → camera
visible only if Z < 0                                   // in front of the camera
u = fx · X / −Z + cx                                    // pixels from the left
v = fy · −Y / −Z + cy                                   // pixels from the top
```

## A good way to build a rendering

1. **Architecture from RoomPlan.** Extrude each wall rectangle to about 0.1 m thick using its `matrix` and `size`. Cut holes for its doors and windows (`parentId`, in the wall's local x/y). Floors are polygons from `corners`.
2. **Textures on walls and floors.** They are planes, so for each texel compute its world position, project it into the photos that see it, and blend. Weight a photo higher when it faces the surface head-on (cosine of the angle to the surface normal), is close, and the point is far from the image edge. Skip a photo when another wall lies between the camera and the point.
3. **Furniture from the mesh.** Keep mesh faces that are not walls, floors, ceilings, windows or doors (classification 0, 4 or 5) and are not within a few cm of a RoomPlan wall or the floor. Colour each vertex from the photos the same way, using the vertex normal for the facing test. RoomPlan's object boxes say what each cluster is (`category`) and how big it is.
4. **Lighting.** The photos already contain the real lighting, so render photo-coloured surfaces unlit (glTF `KHR_materials_unlit`, three.js `MeshBasicMaterial`) to avoid lighting them twice.

## Good to know

- RoomPlan sizes are accurate to a few centimetres. The mesh has holes where the sensor didn't look and is smoothed at sharp corners.
- Photo exposure changes as the camera moves. Blending several photos per point evens this out.
- Rooms scanned in different sessions can differ in lighting.
