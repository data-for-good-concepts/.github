// Where scans are kept. Locally: a folder. On Cloud Run: a Cloud Storage bucket (set BUCKET),
// reached through the JSON API with the service account's token from the metadata server.
const fs = require('node:fs/promises');
const path = require('node:path');

class LocalStorage {
  constructor(dir) { this.dir = dir; }
  file(key) {
    const full = path.resolve(this.dir, key);
    if (!full.startsWith(path.resolve(this.dir) + path.sep)) throw new Error('bad path');
    return full;
  }
  async write(key, data) {
    const full = this.file(key);
    await fs.mkdir(path.dirname(full), { recursive: true });
    await fs.writeFile(full, data);
  }
  async read(key) {
    try { return await fs.readFile(this.file(key)); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  }
}

class GcsStorage {
  constructor(bucket) { this.bucket = bucket; this.token = null; this.expires = 0; }
  async auth() {
    if (this.token && Date.now() < this.expires - 60_000) return this.token;
    const r = await fetch('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
      { headers: { 'Metadata-Flavor': 'Google' } });
    if (!r.ok) throw new Error('metadata token ' + r.status);
    const j = await r.json();
    this.token = j.access_token;
    this.expires = Date.now() + j.expires_in * 1000;
    return this.token;
  }
  async write(key, data) {
    const url = `https://storage.googleapis.com/upload/storage/v1/b/${this.bucket}/o?uploadType=media&name=${encodeURIComponent(key)}`;
    const r = await fetch(url, { method: 'POST', body: data, headers: { Authorization: 'Bearer ' + await this.auth(), 'Content-Type': 'application/octet-stream' } });
    if (!r.ok) throw new Error(`GCS write ${key}: ${r.status} ${await r.text()}`);
  }
  async read(key) {
    const url = `https://storage.googleapis.com/storage/v1/b/${this.bucket}/o/${encodeURIComponent(key)}?alt=media`;
    const r = await fetch(url, { headers: { Authorization: 'Bearer ' + await this.auth() } });
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`GCS read ${key}: ${r.status}`);
    return Buffer.from(await r.arrayBuffer());
  }
}

module.exports = function createStorage() {
  if (process.env.BUCKET) return new GcsStorage(process.env.BUCKET);
  return new LocalStorage(process.env.DATA_DIR || path.join(__dirname, '..', 'data'));
};
