# House Scanner package

This folder is a scan of a home made with an iPhone's LiDAR sensor and camera. It holds **all the raw data** needed to build a photoreal 3D rendering, in **one shared 3D coordinate system**:

1. **RoomPlan**: Apple's clean, labelled model of the rooms (walls, doors, windows, openings, floors, furniture boxes) with accurate measurements.
2. **Photos**: sharp stills at full sensor resolution, each with the exact camera position, lens data and exposure. Photos taken during the LiDAR walk after each room also have a **LiDAR depth map** (RoomPlan doesn't share depth while it scans; `depthFile` in `keyframes.json` says which photos have one).
3. **LiDAR mesh**: ARKit's raw triangle mesh of everything the sensor saw, with a label for each triangle.
4. **Video**: camera poses for every video frame. The video files themselves are only in the "with video" package.

Nothing has been rendered or processed yet. Choose the method that suits the goal (see *Building a photoreal rendering* below).

## Conventions (all files)

- Units: **metres**. Axes: **right-handed, +Y up** (the same as three.js, glTF and nerfstudio). The floor is around y = 0.
- Transforms in this package's own JSON files are **4×4 matrices as 16 numbers, column-major** (three.js: `new THREE.Matrix4().fromArray(m)`). `transforms.json` follows nerfstudio instead: **row-major nested lists**.
- Every file shares the same world space. Several scanning sessions are combined by ARKit relocalisation, so they share it too.
- Cameras follow ARKit's convention, which is the OpenGL/nerfstudio convention: the camera looks down **−Z**, **+Y** is up and **+X** is right. All images are stored in the sensor's **landscape** orientation (not rotated to portrait), so the intrinsics apply as they are.

## Files

| File | What it is |
|---|---|
| `manifest.json` | Index of the files, counts (rooms, photos, photos with depth, mesh size), device, number of sessions. Start here. |
| `transforms.json` | **nerfstudio format**, ready for training. Per-frame `file_path`, `transform_matrix` (camera-to-world), `fl_x`, `fl_y`, `cx`, `cy`, `w`, `h`, and `depth_file_path` when every photo has depth. Uses `camera_model: PINHOLE` and `depth_unit_scale_factor: 0.001`. |
| `keyframes.json` | The same photos with more detail: `file`, `width`, `height`, `intrinsics` [fx, fy, cx, cy], `transform` (camera-to-world, column-major), `time`, `depthFile`, `confidenceFile`, `exposureDuration` (s), `exposureOffset` (EV), `ambientIntensity` and `colorTemperature` (ARKit light estimate, when available). |
| `keyframes/*.jpg` | Photos, 1920×1440, taken when the phone was held still at a new viewpoint, with blurry ones rejected. Roughly one every 30 cm or 15° of turn. |
| `depth/*.png` | LiDAR depth for the photos that have it (see `depthFile`): 16-bit PNG, **millimetres**, 0 = no reading, 256×192. It is the same camera as the photo: scale it up to the photo's size. |
| `confidence/*.png` | ARKit's confidence in each depth pixel: 8-bit PNG, 0 low, 1 medium, 2 high. Use only 2 (or 1 and 2) for geometry. |
| `mesh/mesh-N.ply` | LiDAR mesh of session N (binary little-endian PLY). Vertices: `float x, y, z` in world space. Faces: `list uchar uint vertex_indices` (always 3) and `uchar classification`. |
| `house-scene.json` | Clean RoomPlan model, documented in its own `notes` field. `rooms[]` each have `walls`, `doors`, `windows`, `openings`, `floors` and `objects`, with `id`, `position`, `rotationY`, `size` [w, h, d], `matrix` and `confidence`. Doors and windows have `parentId` (the wall they sit in). Floors have `corners`. Objects have a `category` (sofa, bed, …). Surfaces are flat (one size is 0). |
| `roomplan-raw.json` | Apple's full `CapturedRoom` data for each room (Apple's encoding). |
| `video-poses*.json` | One entry per video frame, same fields as `keyframes.json` (no `file`). `time` is seconds into that session's video. Frames are 1920×1440, landscape. |
| `video*.mp4` | Only in the package with video. HEVC, 1920×1440, with a rotation flag so it plays upright. When extracting frames, **disable auto-rotation** (`ffmpeg -noautorotate …`) so they keep the landscape orientation the poses and intrinsics refer to. |

### Mesh classification values

`0` none (often furniture and objects) · `1` wall · `2` floor · `3` ceiling · `4` table · `5` seat · `6` window · `7` door

## Projecting a 3D point into a photo

```
(X, Y, Z) = inverse(transform) · (Px, Py, Pz, 1)       // world → camera
visible only if Z < 0                                   // in front of the camera
u = fx · X / −Z + cx                                    // pixels from the left
v = fy · −Y / −Z + cy                                   // pixels from the top
```

Use the depth map to check visibility. The point is occluded in that photo if its distance along −Z is clearly greater than the depth at (u, v), scaled to the depth map's size.

## Building a photoreal rendering

### Recommended: Gaussian splatting (most photo-like)

The package is ready for nerfstudio's `splatfacto` (or gsplat, or other 3DGS trainers). Training needs an NVIDIA GPU: a cloud GPU instance, Colab, or a workstation.

```bash
pip install nerfstudio            # in a CUDA environment
ns-train splatfacto --data . \
  nerfstudio-data --orientation-method none --center-method none --auto-scale-poses False
ns-export gaussian-splat --load-config outputs/*/splatfacto/*/config.yml --output-dir export/
```

- `--orientation-method none --center-method none --auto-scale-poses False` keeps the result in this package's metres and axes. The splats then line up exactly with RoomPlan and the mesh, so measurements, floor plans and labels still apply.
- **Seed points:** sample points from `mesh/*.ply`, coloured by projecting them into the photos, and save them as a PLY with `x y z red green blue`. Add `"ply_file_path": "<that file>"` to `transforms.json` and splatfacto starts from them. It converges faster and gives cleaner walls than random initialisation.
- **Depth:** `depth/` can supervise geometry (for example nerfstudio's `depth-nerfacto`, or a depth loss in gsplat). Weight it by `confidence/`.
- **Exposure:** brightness varies between photos (`exposureDuration`, `exposureOffset`). Per-image appearance or exposure compensation avoids blotchy walls.
- **More views:** for denser coverage, extract frames from the video (package with video) at the times in `video-poses*.json`, with no auto-rotation.
- **Viewing on the web:** export as `.ply` (or compress to `.splat` or `.spz`) and show it with a three.js splat viewer, for example GaussianSplats3D (mkkellogg) or Spark. Overlay RoomPlan for the floor plan, measurements and room labels.

### Alternative: textured mesh (classic 3D model for Blender or games)

Reconstruct or clean a mesh (the LiDAR mesh, or RoomPlan walls and floors plus the furniture part of the mesh), lay it out for texturing (xatlas), and texture it from the photos with the poses given here: OpenMVS `TextureMesh` or mvs-texturing. Use the depth maps for occlusion. Optimise the result for the web with glTF-Transform.

### Simple: textured RoomPlan

RoomPlan walls and floors are planes. For each texel, project into the photos that see it best (head-on, close, away from the image edge, not occluded per the depth map) and blend. This gives clean walls with real colours. Put the mesh furniture, coloured per vertex, on top.

## Good to know

- RoomPlan sizes are accurate to a few centimetres. The mesh and depth are noisier (about 1–2 cm), with holes where the sensor didn't look. Depth is unreliable beyond about 5 m and on glass, mirrors and black surfaces (check `confidence/`).
- Poses come from ARKit's tracking, which is good but not perfect, especially across sessions. Pose refinement during training (for example splatfacto's camera optimiser) can sharpen the result.
- Photos are taken while the phone is held still, but people and pets may appear in some of them.
