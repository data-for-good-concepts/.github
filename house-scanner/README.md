# House Scanner

An iPhone app that scans your home with the LiDAR sensor using Apple's RoomPlan.

- Scan one room, or several rooms in a row. Rooms scanned in one go are joined into a single 3D model of the house.
- 2D floor plan with wall lengths, doors, windows and furniture
- Floor area, ceiling height, and counts of doors, windows and furniture
- View the model in 3D or place it in AR on a table
- **Records the camera while scanning**: an MP4 video plus sharp still photos with the exact camera position, used to put real textures on walls and floors in the web viewer
- Export as **JSON** (for 3D web apps like three.js), **DXF** (CAD floor plan with 3D walls) or **USDZ** (3D model). Send them by AirDrop to your Mac. They're also in the Files app under *On My iPhone → House Scanner*.

## What you need

- An iPhone with LiDAR: 12 Pro, 13 Pro, 14 Pro, 15 Pro, 16 Pro, 17 Pro or newer Pro/Pro Max, running iOS 17 or later
- A Mac with Xcode 16 or newer (free from the Mac App Store)
- A free Apple ID. **No paid developer account is needed.**

## Install it on your iPhone

1. **Get the code on your Mac.** On GitHub, open this branch, click **Code → Download ZIP** and unzip it.
   Or run `git clone` and then `git checkout claude/serene-gates-06t9o6`.
2. Open `house-scanner/HouseScanner.xcodeproj` in Xcode.
3. **Add your Apple ID:** *Xcode → Settings → Accounts → +* → Apple ID.
4. **Choose your team.** In the left sidebar click the blue **HouseScanner** project, then the **HouseScanner** target, then **Signing & Capabilities**. Under **Team**, pick *"Your Name (Personal Team)"*.
   - If Xcode says the bundle identifier is unavailable, change **Bundle Identifier** to anything unique, for example `com.yourname.housescanner`.
5. **Plug in your iPhone** with a cable and tap **Trust** on the phone.
6. **Turn on Developer Mode** on the iPhone: *Settings → Privacy & Security → Developer Mode → On*. The phone restarts.
7. In Xcode's top bar, choose your iPhone as the run destination and press **▶ Run** (⌘R).
8. The first time, the iPhone will refuse to open the app. Go to *Settings → General → VPN & Device Management*, tap your Apple ID and tap **Trust**. Then open House Scanner.

> With a free Apple ID the app stops opening after **7 days**. Plug the phone in and press Run again to renew it. Your scans stay on the phone.

## Scanning tips

- Use good, even lighting. Avoid pointing at mirrors and large windows for a long time.
- Move slowly and sweep the camera from floor to ceiling. Make sure every wall corner has been seen.
- **Several rooms:** after *Done with this room*, walk through the doorway into the next room, then tap *Scan next room*. Do all rooms in one session so they line up.
- Close cupboards and keep doors in a consistent position (fully open or closed).
- **For good textures:** sweep the camera up to the ceiling and down to the floor on every wall, and pause briefly now and then. Photos are only taken while the phone is fairly still.

## Export formats

Every scan folder contains:

| File | Format |
|---|---|
| `house-scene.json` | Every wall, door, window, opening, floor and piece of furniture with position, size, rotation and a full 4×4 matrix. Metres, Y up, right-handed, same as three.js: `new THREE.Matrix4().fromArray(item.matrix)`. Includes overall `bounds` for framing the camera. |
| `floor-plan.dxf` | AutoCAD R12 DXF in metres. Layers `WALLS`, `DOORS`, `WINDOWS`, `OPENINGS`, `FURNITURE`, `FLOOR`, `LABELS` (wall lengths, furniture names) and `WALLS_3D` (walls as 3D faces). |
| `house.usdz`, `room-N.usdz` | Apple 3D models (merged house and each room) |
| `rooms.json` | Apple's raw RoomPlan data |
| `house-scan.zip` | `house-scene.json` + `keyframes.json` + `keyframes/*.jpg`. Open it in the web viewer for textured walls and floors. |
| `video.mp4` | The camera feed recorded during the scan (HEVC) |
| `video-poses.json` | Camera position and lens data for every video frame |
| `keyframes/*.jpg`, `keyframes.json` | Sharp still photos (960 px wide) taken whenever the phone moved 30 cm or turned 15°, with camera position and lens data |

## Files

| File | What it does |
|---|---|
| `ScanController.swift` | Runs RoomPlan and keeps one AR session across rooms |
| `ScanView.swift` | Camera screen with the scan controls |
| `ScanStore.swift` | Saves and loads scans (USDZ models + room data) |
| `ContentView.swift` | List of saved scans |
| `ScanDetailView.swift` | Floor plan, 3D/AR viewer, stats, sharing |
| `FloorPlanView.swift` | Draws the top-down floor plan |
| `RoomStats.swift` | Floor area, ceiling height and object counts |
| `SceneExporter.swift` | Writes `house-scene.json` |
| `DXFExporter.swift` | Writes `floor-plan.dxf` |
| `FrameRecorder.swift` | Records the video and still photos during the scan |

## 3D web viewer

`web-viewer/index.html` turns `house-scan.zip` (or `house-scene.json`) into an interactive three.js model with textured walls and floors (orbit, floor plan and walk-through). See `web-viewer/README.md`.
