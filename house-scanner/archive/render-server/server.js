// House Renderer: receives House Scanner packages, processes them into a textured 3D model
// (model.glb + annotations.json) and streams a live rendering to thin clients.
const http = require('node:http');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const JSZip = require('jszip');
const { WebSocketServer } = require('ws');
const createStorage = require('./lib/storage');
const { processScan, openStream, getBrowser } = require('./lib/browser');

const PORT = Number(process.env.PORT || 8080);
const TOKEN = process.env.RENDER_TOKEN || '';            // required from clients when set
const KEY = crypto.randomBytes(16).toString('hex');      // for this server's own engine pages only
const MAX_UPLOAD = Number(process.env.MAX_UPLOAD_MB || 800) * 1024 * 1024;
const BASE = `http://127.0.0.1:${PORT}`;
const storage = createStorage();

const PUBLIC = path.join(__dirname, 'public');
const THREE = path.join(__dirname, 'node_modules', 'three');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.json': 'application/json', '.glb': 'model/gltf-binary', '.jpg': 'image/jpeg', '.ply': 'application/octet-stream', '.md': 'text/markdown; charset=utf-8' };

// ---------- helpers ----------
const send = (res, status, body, type = 'application/json') => {
  const data = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' });
  res.end(data);
};

function tokenFrom(req, url) {
  const h = req.headers.authorization || '';
  if (h.startsWith('Bearer ')) return h.slice(7);
  return url.searchParams.get('token') || '';
}
const isInternal = (url) => url.searchParams.get('key') === KEY;
function authorized(req, url) {
  if (isInternal(url)) return true;
  if (!TOKEN) return true;
  const given = Buffer.from(tokenFrom(req, url));
  const want = Buffer.from(TOKEN);
  return given.length === want.length && crypto.timingSafeEqual(given, want);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(Object.assign(new Error('upload too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function serveFile(res, file) {
  fs.readFile(file, (err, data) => {
    if (err) return send(res, 404, { error: 'not found' });
    send(res, 200, data, TYPES[path.extname(file)] || 'application/octet-stream');
  });
}

const validId = (id) => /^[a-z0-9]{12}$/.test(id);
const scanKey = (id, rest) => `scans/${id}/${rest}`;

async function readStatus(id) {
  const b = await storage.read(scanKey(id, 'status.json'));
  return b ? JSON.parse(b) : null;
}
async function writeStatus(id, status) {
  await storage.write(scanKey(id, 'status.json'), JSON.stringify({ ...status, updatedAt: new Date().toISOString() }));
}

// ---------- processing queue (one scan at a time per instance) ----------
let queue = Promise.resolve();
function enqueue(id) {
  queue = queue.then(async () => {
    await writeStatus(id, { state: 'processing', stage: 'Starting', done: 0, total: 0 });
    let last = 0;
    try {
      await processScan({
        baseUrl: BASE, id, key: KEY,
        onProgress: (stage, done, total) => {
          const now = Date.now();
          if (now - last < 1000 && done !== total) return;   // at most one status write per second
          last = now;
          writeStatus(id, { state: 'processing', stage, done, total }).catch(() => {});
        },
      });
      await writeStatus(id, { state: 'ready' });
      console.log(`scan ${id} ready`);
    } catch (e) {
      console.error(`scan ${id} failed`, e);
      await writeStatus(id, { state: 'failed', error: e.message });
    }
  });
}

// ---------- unpacking an upload ----------
async function storeUpload(id, zipBuffer) {
  const zip = await JSZip.loadAsync(zipBuffer);
  const entries = Object.values(zip.files).filter((f) => !f.dir && !f.name.includes('__MACOSX'));
  const scene = entries.find((f) => f.name === 'house-scene.json' || f.name.endsWith('/house-scene.json'));
  if (!scene) throw Object.assign(new Error('house-scene.json not found in the ZIP'), { status: 400 });
  const prefix = scene.name.slice(0, -'house-scene.json'.length);
  let count = 0;
  for (const f of entries) {
    if (!f.name.startsWith(prefix)) continue;
    const rel = f.name.slice(prefix.length);
    if (rel.includes('..') || rel.startsWith('/')) continue;
    await storage.write(scanKey(id, 'raw/' + rel), await f.async('nodebuffer'));
    count++;
  }
  return count;
}

// ---------- HTTP ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const parts = url.pathname.split('/').filter(Boolean);
  try {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Allow-Methods': 'GET, POST' });
      return res.end();
    }
    if (url.pathname === '/healthz') return send(res, 200, { ok: true });

    // Thin client page and engine page.
    if (parts[0] === 'view' && validId(parts[1] || '')) return serveFile(res, path.join(PUBLIC, 'view.html'));
    if (url.pathname === '/engine.html') {
      if (!isInternal(url)) return send(res, 403, { error: 'forbidden' });
      return serveFile(res, path.join(PUBLIC, 'engine.html'));
    }
    if (parts[0] === 'vendor' && parts[1] === 'three') {
      const file = path.resolve(THREE, ...parts.slice(2));
      if (!file.startsWith(THREE + path.sep)) return send(res, 404, { error: 'not found' });
      return serveFile(res, file);
    }

    if (parts[0] !== 'api' || parts[1] !== 'scans') return send(res, 404, { error: 'not found' });
    if (!authorized(req, url)) return send(res, 401, { error: 'missing or wrong token' });

    // POST /api/scans  (body: house-scan.zip)
    if (parts.length === 2 && req.method === 'POST') {
      const body = await readBody(req, MAX_UPLOAD);
      const id = crypto.randomBytes(9).toString('base64url').toLowerCase().replace(/[^a-z0-9]/g, '').padEnd(12, '0').slice(0, 12);
      const files = await storeUpload(id, body);
      await writeStatus(id, { state: 'queued' });
      enqueue(id);
      console.log(`scan ${id} uploaded (${files} files, ${(body.length / 1e6).toFixed(1)} MB)`);
      return send(res, 201, { id, view: `/view/${id}`, status: `/api/scans/${id}` });
    }

    const id = parts[2];
    if (!validId(id || '')) return send(res, 404, { error: 'not found' });

    // GET /api/scans/:id  → processing status
    if (parts.length === 3 && req.method === 'GET') {
      const status = await readStatus(id);
      return status ? send(res, 200, { id, ...status }) : send(res, 404, { error: 'not found' });
    }

    // POST /api/scans/:id/result?part=model|annotations  (engine only)
    if (parts[3] === 'result' && req.method === 'POST') {
      if (!isInternal(url)) return send(res, 403, { error: 'forbidden' });
      const part = url.searchParams.get('part');
      const name = { model: 'model.glb', annotations: 'annotations.json' }[part];
      if (!name) return send(res, 400, { error: 'bad part' });
      await storage.write(scanKey(id, name), await readBody(req, 1024 * 1024 * 1024));
      return send(res, 200, { ok: true });
    }

    // GET /api/scans/:id/raw/<path>, /model.glb, /annotations.json
    if (req.method === 'GET') {
      let key;
      if (parts[3] === 'raw' && parts.length > 4) {
        const rel = parts.slice(4).join('/');
        if (rel.includes('..')) return send(res, 400, { error: 'bad path' });
        key = scanKey(id, 'raw/' + rel);
      } else if (parts[3] === 'model.glb' || parts[3] === 'annotations.json') {
        key = scanKey(id, parts[3]);
      } else {
        return send(res, 404, { error: 'not found' });
      }
      const data = await storage.read(key);
      if (!data) return send(res, 404, { error: 'not found' });
      res.setHeader('Content-Disposition', `inline; filename="${path.basename(key)}"`);
      return send(res, 200, data, TYPES[path.extname(key)] || 'application/octet-stream');
    }

    send(res, 405, { error: 'method not allowed' });
  } catch (e) {
    console.error(e);
    send(res, e.status || 500, { error: e.message });
  }
});

// ---------- WebSocket: /api/scans/:id/stream ----------
const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
server.on('upgrade', async (req, socket, head) => {
  const url = new URL(req.url, 'http://x');
  const m = url.pathname.match(/^\/api\/scans\/([a-z0-9]{12})\/stream$/);
  if (!m || !authorized(req, url)) { socket.destroy(); return; }
  const id = m[1];
  wss.handleUpgrade(req, socket, head, async (ws) => {
    try {
      const status = await readStatus(id);
      if (status?.state !== 'ready') {
        ws.send(JSON.stringify({ t: 'error', message: 'This scan is not ready yet.' }));
        return ws.close();
      }
      const n = (k, d) => Number(url.searchParams.get(k)) || d;
      await openStream({
        ws, baseUrl: BASE, id, key: KEY,
        width: Math.min(2000, n('w', 390)), height: Math.min(2000, n('h', 844)),
        dpr: n('dpr', 1.5), dark: url.searchParams.get('dark') === '1', quality: Math.min(90, n('q', 65)),
      });
    } catch (e) {
      console.error('stream', e);
      try { ws.send(JSON.stringify({ t: 'error', message: e.message })); ws.close(); } catch {}
    }
  });
});

server.listen(PORT, () => {
  console.log(`House Renderer on :${PORT} (${process.env.BUCKET ? 'bucket ' + process.env.BUCKET : 'local storage'}${TOKEN ? ', token required' : ''})`);
  getBrowser().catch((e) => console.error('browser launch failed', e));
});
