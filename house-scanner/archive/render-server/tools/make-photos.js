const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const [, , sceneFile, outDir, truthFile] = process.argv;
  const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
  const browser = await chromium.launch({ proxy: proxy ? { server: proxy } : undefined, args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--ignore-certificate-errors'] });
  const page = await browser.newPage({ viewport: { width: 960, height: 720 } });
  page.on('pageerror', e => console.log('PAGEERROR', e.message));
  await page.goto('file://' + path.resolve('make-photos.html'));
  await page.waitForFunction(() => window.ready, null, { timeout: 60000 });
  const data = JSON.parse(fs.readFileSync(sceneFile, 'utf8'));
  const truth = truthFile ? JSON.parse(fs.readFileSync(truthFile, 'utf8')) : null;
  const { frames, images } = await page.evaluate(([d, t]) => window.generate(d, t), [data, truth]);
  fs.mkdirSync(path.join(outDir, 'keyframes'), { recursive: true });
  for (const [file, url] of images) fs.writeFileSync(path.join(outDir, file), Buffer.from(url.split(',')[1], 'base64'));
  fs.writeFileSync(path.join(outDir, 'keyframes.json'), JSON.stringify({ format: 'house-scanner-keyframes', version: 1,
    notes: ['Example photos rendered from the sample house to demonstrate textures.'], frames }));
  console.log('frames', frames.length);
  await browser.close();
})();
