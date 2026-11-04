// Renders design/app-icon.html into the three app icon PNGs.
// Needs Node with Playwright, and Python with Pillow to drop the alpha
// channel (App Store icons can't have one).
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const path = require('path');

const out = path.join(__dirname, '..', 'AuraSearch', 'Resources', 'Assets.xcassets', 'AppIcon.appiconset');
const icons = { halo: 'AppIcon.png', eclipse2: 'AppIcon-Dark.png', tinted: 'AppIcon-Tinted.png' };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(__dirname, 'app-icon.html'));
  for (const [id, file] of Object.entries(icons)) {
    const target = path.join(out, file);
    await page.locator('#' + id).screenshot({ path: target });
    const mode = id === 'tinted' ? 'L' : 'RGB';
    execFileSync('python3', ['-c',
      `from PIL import Image; import sys; Image.open(sys.argv[1]).convert('${mode}').convert('RGB').save(sys.argv[1], optimize=True)`,
      target]);
    console.log('wrote', file);
  }
  await browser.close();
})();
