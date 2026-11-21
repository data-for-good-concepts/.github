// Headless Chromium: runs engine.html to process scans and to render live streams.
const { chromium } = require('playwright');

let browserPromise = null;

function launchArgs() {
  if (process.env.USE_GPU === '1') {
    // Hardware rendering on a Cloud Run GPU (NVIDIA L4) through ANGLE + EGL.
    return ['--use-angle=gl-egl', '--use-gl=angle', '--ignore-gpu-blocklist', '--enable-gpu-rasterization', '--no-sandbox'];
  }
  // Software rendering (works everywhere, slower).
  return ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--no-sandbox'];
}

function getBrowser() {
  if (!browserPromise) {
    browserPromise = chromium.launch({ args: launchArgs() }).then((b) => {
      b.on('disconnected', () => { browserPromise = null; });
      return b;
    });
  }
  return browserPromise;
}

// Runs the processing step for one scan. Resolves when the engine page has uploaded its result.
async function processScan({ baseUrl, id, key, onProgress, timeoutMs = 45 * 60_000 }) {
  const browser = await getBrowser();
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  try {
    let settle;
    const finished = new Promise((resolve, reject) => { settle = { resolve, reject }; });
    await page.exposeFunction('reportProgress', (stage, done, total) => onProgress?.(stage, done, total));
    await page.exposeFunction('reportDone', () => settle.resolve());
    await page.exposeFunction('reportError', (message) => settle.reject(new Error(message)));
    page.on('pageerror', (e) => settle.reject(e));
    page.on('console', (m) => { if (m.type() === 'error') console.error('[engine]', m.text()); });
    await page.goto(`${baseUrl}/engine.html?mode=process&scan=${id}&key=${key}`);
    let timer;
    await Promise.race([finished, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('processing timed out')), timeoutMs); })]);
    clearTimeout(timer);
  } finally {
    await context.close().catch(() => {});
  }
}

// One live stream: a page rendering the scan, its screen sent as JPEG frames, input played back into it.
async function openStream({ ws, baseUrl, id, key, width, height, dpr, dark, quality = 65 }) {
  const browser = await getBrowser();
  const scale = Math.min(Math.max(dpr || 1, 1), 2);
  const context = await browser.newContext({
    viewport: { width, height }, deviceScaleFactor: scale, hasTouch: true,
    colorScheme: dark ? 'dark' : 'light',
  });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  let closed = false;
  let size = { width, height };
  const touches = new Map();
  let touchActive = false;

  const close = async () => {
    if (closed) return;
    closed = true;
    await context.close().catch(() => {});
  };
  ws.on('close', close);
  ws.on('error', close);

  const send = (obj) => { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); };

  cdp.on('Page.screencastFrame', ({ data, sessionId }) => {
    // Drop frames when the network can't keep up instead of queueing them.
    if (ws.readyState === 1 && ws.bufferedAmount < 1_500_000) ws.send(Buffer.from(data, 'base64'));
    cdp.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
  });

  async function startScreencast() {
    await cdp.send('Page.stopScreencast').catch(() => {});
    await cdp.send('Page.startScreencast', {
      format: 'jpeg', quality,
      maxWidth: Math.round(size.width * scale), maxHeight: Math.round(size.height * scale), everyNthFrame: 1,
    });
  }

  page.on('pageerror', (e) => send({ t: 'error', message: e.message }));
  await page.exposeFunction('reportReady', () => send({ t: 'ready' }));
  await page.exposeFunction('reportError', (message) => send({ t: 'error', message }));
  await page.goto(`${baseUrl}/engine.html?mode=stream&scan=${id}&key=${key}`);
  await startScreencast();

  ws.on('message', async (raw) => {
    if (closed) return;
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return; }
    try {
      switch (m.t) {
        case 'mouse':
          await cdp.send('Input.dispatchMouseEvent', {
            type: m.type, x: m.x, y: m.y, button: m.button || 'none', buttons: m.buttons || 0,
            clickCount: m.type === 'mouseMoved' ? 0 : 1,
          });
          break;
        case 'wheel':
          await cdp.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: m.x, y: m.y, deltaX: m.dx || 0, deltaY: m.dy || 0 });
          break;
        case 'touch': {
          // The client sends every active finger after each change; CDP works out which ones changed.
          touches.clear();
          for (const p of m.points || []) touches.set(p.id, { x: p.x, y: p.y, id: p.id });
          const points = [...touches.values()];
          let type;
          if (!points.length) { type = 'touchEnd'; touchActive = false; }
          else if (!touchActive) { type = 'touchStart'; touchActive = true; }
          else type = 'touchMove';
          await cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : points });
          break;
        }
        case 'resize':
          size = { width: Math.max(200, Math.min(2000, m.width | 0)), height: Math.max(200, Math.min(2000, m.height | 0)) };
          await page.setViewportSize(size);
          await startScreencast();
          break;
        case 'theme':
          await page.emulateMedia({ colorScheme: m.dark ? 'dark' : 'light' });
          break;
        case 'insets':
          await page.evaluate((i) => {
            const s = document.documentElement.style;
            s.setProperty('--inset-top', i.top + 'px');
            s.setProperty('--inset-bottom', i.bottom + 'px');
            s.setProperty('--inset-left', i.left + 'px');
            s.setProperty('--inset-right', i.right + 'px');
          }, m);
          break;
      }
    } catch (e) {
      if (!closed) console.error('stream input', e.message);
    }
  });
}

module.exports = { getBrowser, processScan, openStream };
