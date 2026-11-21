// Builds a synthetic ARKit-style LiDAR mesh for the sample house, for testing:
//   node make-sample-mesh.mjs house-scene.json out/mesh-1.ply out/truth.json
// mesh-1.ply is in the app's format (world space, per-face classification).
// truth.json holds the same triangles with their "real" colours, used to render the example photos.
import fs from 'node:fs';
import * as THREE from 'three';

const [, , sceneFile, plyOut, truthOut] = process.argv;
const scene = JSON.parse(fs.readFileSync(sceneFile, 'utf8'));
const positions = [], colors = [], faces = [], cls = [];
let seed = 7;
const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const jitter = (a) => (rand() - 0.5) * a;

// Adds a subdivided box (local size, local offset) transformed by matrix m.
function box(m, size, offset, color, klass, step = 0.06, noise = 0.004) {
  const [sx, sy, sz] = size;
  const faceDefs = [
    [[1, 0, 0], [0, 0, -1], [0, 1, 0]], [[-1, 0, 0], [0, 0, 1], [0, 1, 0]],
    [[0, 1, 0], [1, 0, 0], [0, 0, -1]], [[0, -1, 0], [1, 0, 0], [0, 0, 1]],
    [[0, 0, 1], [1, 0, 0], [0, 1, 0]], [[0, 0, -1], [-1, 0, 0], [0, 1, 0]],
  ];
  const half = new THREE.Vector3(sx / 2, sy / 2, sz / 2);
  for (const [n, u, v] of faceDefs) {
    const N = new THREE.Vector3(...n), U = new THREE.Vector3(...u), V = new THREE.Vector3(...v);
    const du = Math.abs(U.dot(new THREE.Vector3(sx, sy, sz))), dv = Math.abs(V.dot(new THREE.Vector3(sx, sy, sz)));
    const nu = Math.max(1, Math.round(du / step)), nvv = Math.max(1, Math.round(dv / step));
    const base = positions.length / 3;
    const c0 = new THREE.Vector3().copy(N).multiply(half);
    for (let j = 0; j <= nvv; j++) for (let i = 0; i <= nu; i++) {
      const p = c0.clone().addScaledVector(U, (i / nu - 0.5) * du).addScaledVector(V, (j / nvv - 0.5) * dv)
        .add(new THREE.Vector3(...offset)).addScaledVector(N, jitter(noise));
      p.applyMatrix4(m);
      positions.push(p.x, p.y, p.z);
      const shade = 0.92 + jitter(0.1);
      colors.push(color[0] * shade, color[1] * shade, color[2] * shade);
    }
    for (let j = 0; j < nvv; j++) for (let i = 0; i < nu; i++) {
      const a = base + j * (nu + 1) + i, b = a + 1, c = a + nu + 1, d = c + 1;
      faces.push([a, b, d], [a, d, c]);
      cls.push(klass, klass);
    }
  }
}
// Rough sphere (foliage, lamp shade) or cylinder-ish shapes via scaled boxes.
function blob(center, radius, color, klass) {
  const g = new THREE.IcosahedronGeometry(radius, 3);
  const base = positions.length / 3;
  const p = g.attributes.position;
  const unique = new Map();
  const idx = [];
  for (let i = 0; i < p.count; i++) {
    const key = `${p.getX(i).toFixed(4)},${p.getY(i).toFixed(4)},${p.getZ(i).toFixed(4)}`;
    if (!unique.has(key)) {
      unique.set(key, unique.size);
      const r = 1 + jitter(0.35);
      positions.push(center[0] + p.getX(i) * r, center[1] + p.getY(i) * r * 0.9, center[2] + p.getZ(i) * r);
      const s = 0.75 + rand() * 0.5;
      colors.push(color[0] * s, color[1] * s, color[2] * s);
    }
    idx.push(base + unique.get(key));
  }
  for (let i = 0; i < idx.length; i += 3) { faces.push([idx[i], idx[i + 1], idx[i + 2]]); cls.push(klass); }
}

const C = {
  sofa: [0.33, 0.43, 0.56], cushion: [0.45, 0.55, 0.66], wood: [0.55, 0.38, 0.22], dark: [0.15, 0.15, 0.16], white: [0.92, 0.92, 0.9],
  steel: [0.78, 0.8, 0.82], bed: [0.93, 0.91, 0.86], duvet: [0.62, 0.7, 0.8], pillow: [0.97, 0.96, 0.93], leaf: [0.25, 0.5, 0.2], pot: [0.7, 0.42, 0.3],
  fabric: [0.6, 0.65, 0.48], shade: [0.95, 0.9, 0.78],
};
const NONE = 0, TABLE = 4, SEAT = 5, WALL = 1, FLOOR = 2;

for (const room of scene.rooms) {
  for (const o of room.objects) {
    const m = new THREE.Matrix4().fromArray(o.matrix);
    const [w, h, d] = o.size;
    const y0 = -h / 2;
    switch (o.category) {
      case 'sofa':
        box(m, [w, h * 0.45, d], [0, y0 + h * 0.225, 0], C.sofa, SEAT);
        box(m, [w - 0.3, h * 0.12, d * 0.7], [0, y0 + h * 0.51, 0.05], C.cushion, SEAT);
        box(m, [w, h * 0.55, d * 0.25], [0, y0 + h * 0.72, -d * 0.375], C.sofa, SEAT);
        box(m, [0.15, h * 0.65, d], [-w / 2 + 0.075, y0 + h * 0.325, 0], C.sofa, SEAT);
        box(m, [0.15, h * 0.65, d], [w / 2 - 0.075, y0 + h * 0.325, 0], C.sofa, SEAT);
        break;
      case 'table':
        box(m, [w, 0.04, d], [0, h / 2 - 0.02, 0], C.wood, TABLE);
        for (const sx of [-1, 1]) for (const sz of [-1, 1]) box(m, [0.05, h - 0.04, 0.05], [sx * (w / 2 - 0.06), y0 + (h - 0.04) / 2, sz * (d / 2 - 0.06)], C.wood, TABLE, 0.05);
        break;
      case 'chair':
        box(m, [w, 0.05, d], [0, y0 + 0.45, 0], C.fabric, SEAT);
        box(m, [w, h - 0.5, 0.05], [0, y0 + 0.475 + (h - 0.5) / 2, -d / 2 + 0.025], C.fabric, SEAT);
        for (const sx of [-1, 1]) for (const sz of [-1, 1]) box(m, [0.04, 0.43, 0.04], [sx * (w / 2 - 0.04), y0 + 0.215, sz * (d / 2 - 0.04)], C.dark, SEAT, 0.05);
        break;
      case 'bed':
        box(m, [w, h * 0.55, d], [0, y0 + h * 0.275, 0], C.wood, SEAT);
        box(m, [w - 0.05, h * 0.35, d - 0.1], [0, y0 + h * 0.72, 0.03], C.bed, SEAT);
        box(m, [w - 0.02, 0.06, d * 0.62], [0, y0 + h * 0.92, d * 0.17], C.duvet, SEAT);
        box(m, [w, 0.9, 0.08], [0, y0 + 0.45, -d / 2 + 0.04], C.wood, SEAT);
        box(m, [0.6, 0.12, 0.35], [-0.38, y0 + h * 0.95, -d / 2 + 0.3], C.pillow, SEAT);
        box(m, [0.6, 0.12, 0.35], [0.38, y0 + h * 0.95, -d / 2 + 0.3], C.pillow, SEAT);
        break;
      case 'television':
        box(m, [w, h * 0.55, 0.06], [0, h / 2 - h * 0.275, 0], C.dark, NONE);
        box(m, [w * 0.9, h * 0.42, d], [0, y0 + h * 0.21, 0], C.wood, NONE);
        break;
      default: {
        const color = { refrigerator: C.steel, stove: C.dark, dishwasher: C.steel, sink: C.white, washerDryer: C.white, toilet: C.white, bathtub: C.white, storage: C.wood }[o.category] || C.steel;
        box(m, [w, h, d], [0, 0, 0], color, NONE, 0.08);
      }
    }
  }
}
// Things RoomPlan doesn't know about: a plant and a floor lamp in the living room.
const I = new THREE.Matrix4();
box(new THREE.Matrix4().makeTranslation(4.65, 0.2, 3.7), [0.35, 0.4, 0.35], [0, 0, 0], C.pot, NONE, 0.05);
blob([4.65, 0.95, 3.7], 0.42, C.leaf, NONE);
box(new THREE.Matrix4().makeTranslation(0.45, 0.8, 3.75), [0.04, 1.6, 0.04], [0, 0, 0], C.dark, NONE, 0.05);
blob([0.45, 1.65, 3.75], 0.22, C.shade, NONE);
// Wall and floor fragments that the renderer must remove (as ARKit includes them in the mesh).
box(new THREE.Matrix4().makeTranslation(2.6, 1.25, 0.01), [5.0, 2.4, 0.01], [0, 0, 0], C.white, WALL, 0.25);
box(new THREE.Matrix4().makeTranslation(2.6, 0.005, 2.1), [5.0, 0.01, 4.0], [0, 0, 0], C.wood, FLOOR, 0.25);
box(new THREE.Matrix4().makeTranslation(7.0, 0.01, 2.1), [3.4, 0.01, 4.0], [0, 0, 0], C.white, NONE, 0.3);  // unclassified floor scrap

// Write PLY.
const nv = positions.length / 3, nf = faces.length;
const header = `ply\nformat binary_little_endian 1.0\ncomment House Scanner ARKit LiDAR mesh (synthetic sample)\nelement vertex ${nv}\nproperty float x\nproperty float y\nproperty float z\nelement face ${nf}\nproperty list uchar uint vertex_indices\nproperty uchar classification\nend_header\n`;
const body = Buffer.alloc(nv * 12 + nf * 14);
let o = 0;
for (let i = 0; i < nv * 3; i++, o += 4) body.writeFloatLE(positions[i], o);
for (let f = 0; f < nf; f++) {
  body.writeUInt8(3, o); o += 1;
  for (const v of faces[f]) { body.writeUInt32LE(v, o); o += 4; }
  body.writeUInt8(cls[f], o); o += 1;
}
fs.writeFileSync(plyOut, Buffer.concat([Buffer.from(header, 'ascii'), body]));
fs.writeFileSync(truthOut, JSON.stringify({ positions: positions.map((v) => +v.toFixed(4)), colors: colors.map((v) => +v.toFixed(3)), index: faces.flat() }));
console.log(`mesh: ${nv} vertices, ${nf} faces`);
