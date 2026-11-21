# House Renderer (Cloud Run)

Takes the `house-scan.zip` package from the House Scanner app and turns it into a textured 3D model. It then renders that model live and streams the picture to a thin client (the app's web view, or any browser). The client only displays images and sends touches back, so a phone with no 3D work to do can still show a heavy model smoothly.

```
upload ZIP ──▶ store files ──▶ process once (headless Chromium + three.js) ──▶ model.glb + annotations.json
                                                                                     │
client ◀── JPEG frames (only when the picture changes) ◀── render live ◀────────────┘
client ──▶ touches / mouse / resize ──▶ replayed into the rendering page
```

## What processing does

1. Builds the walls (with door and window holes), floors, windows and doors from RoomPlan (`house-scene.json`).
2. Textures every wall and floor from the photos: each texel is projected into the photos that see it best, and walls between the camera and the point are taken into account.
3. Takes ARKit's LiDAR mesh and keeps only furniture and objects. It removes triangles classified as wall, floor, ceiling, window or door, and those within a few cm of a RoomPlan wall, the floor or the ceiling. The rest is coloured from the photos.
4. Writes `model.glb`, with one node per room plus `scanned-furniture`. Photo surfaces are unlit, and every node carries `extras` with its kind and ids. It also writes `annotations.json`: which room each photo was taken in, which photos textured each surface and how much of it they covered, and mesh filter statistics.

## API

All `/api` routes need `Authorization: Bearer <RENDER_TOKEN>` (or `?token=`) when `RENDER_TOKEN` is set.

| Route | |
|---|---|
| `POST /api/scans` | Body: the ZIP. Returns `{ id, view, status }`. Processing starts in the background. |
| `GET /api/scans/:id` | `{ state: queued \| processing \| ready \| failed, stage, done, total, error }` |
| `GET /api/scans/:id/model.glb` | Processed, textured model |
| `GET /api/scans/:id/annotations.json` | Annotations |
| `GET /api/scans/:id/raw/<path>` | Any file from the uploaded package |
| `GET /view/:id#token=…` | Thin client page (shows progress, then the live stream) |
| `WS /api/scans/:id/stream?w=&h=&dpr=&dark=&token=` | The stream: binary messages are JPEG frames; text messages are `{t:"ready"}` or `{t:"error"}`. Send `{t:"touch",points:[{id,x,y}]}`, `{t:"mouse",type,x,y,button,buttons}`, `{t:"wheel",x,y,dx,dy}`, `{t:"resize",width,height}`, `{t:"theme",dark}` and `{t:"insets",top,right,bottom,left}`. |

## Run locally

```bash
npm install
RENDER_TOKEN=secret node server.js          # http://localhost:8080, files in ./data
curl -H "Authorization: Bearer secret" --data-binary @house-scan.zip http://localhost:8080/api/scans
# open http://localhost:8080/view/<id>#token=secret
```

## Deploy to Cloud Run

You need a Google Cloud project with billing, and the `gcloud` CLI. Replace `PROJECT` and `REGION` (for example `europe-west1`).

```bash
gcloud config set project PROJECT
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com storage.googleapis.com

# Storage for uploaded and processed scans
gcloud storage buckets create gs://PROJECT-house-scans --location=REGION --uniform-bucket-level-access

# Build and deploy (from this folder)
gcloud run deploy house-renderer --source . --region REGION \
  --allow-unauthenticated \
  --set-env-vars BUCKET=PROJECT-house-scans,RENDER_TOKEN=$(openssl rand -hex 16) \
  --cpu 4 --memory 8Gi --no-cpu-throttling \
  --timeout 3600 --concurrency 4 --session-affinity \
  --min-instances 0 --max-instances 2

# Let the service read and write its bucket
SA=$(gcloud run services describe house-renderer --region REGION --format 'value(spec.template.spec.serviceAccountName)')
gcloud storage buckets add-iam-policy-binding gs://PROJECT-house-scans --member serviceAccount:$SA --role roles/storage.objectAdmin
```

Then put the service URL and the token into the app (Settings, gear icon). Read the token back with:
`gcloud run services describe house-renderer --region REGION --format 'value(spec.template.spec.containers[0].env)'`

Why these settings:
- `--allow-unauthenticated` lets the phone reach it. Access is still guarded by `RENDER_TOKEN`.
- `--no-cpu-throttling` keeps processing running after the upload request has returned.
- `--timeout 3600` allows streams of up to an hour.
- `--session-affinity` keeps a viewer on the instance that renders for it.

**Cost:** with `--min-instances 0` you pay only while it is processing or streaming. The first request after a quiet period waits for a cold start (about 10–20 s).

### GPU (optional, faster and smoother)

By default Chromium renders in software, which is fine for one or two viewers. For more, or for big meshes, add an NVIDIA L4 GPU (available in a few regions, and may need quota) and set `USE_GPU=1`:

```bash
gcloud run deploy house-renderer --source . --region europe-west1 --gpu 1 --gpu-type nvidia-l4 --no-gpu-zonal-redundancy \
  --cpu 4 --memory 16Gi --no-cpu-throttling --set-env-vars USE_GPU=1,BUCKET=…,RENDER_TOKEN=…  (other flags as above)
```

The GPU launch flags in `lib/browser.js` haven't been tested on Cloud Run yet. If the stream shows an error, remove `USE_GPU`.

## Limits

- One scan is processed at a time per instance. A scan whose instance stops mid-processing stays "processing": upload it again.
- Furniture colours come from photos without a depth test against the furniture itself. Spots no photo saw from the front (undersides, backs against walls) stay grey.
- Furniture standing in front of a wall can also appear painted onto the wall texture behind it.

## Test data

`tools/` contains the scripts that made the synthetic sample package: `make-sample-mesh.mjs` builds a LiDAR-style mesh, and `make-photos.*` renders example photos.
