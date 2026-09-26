// UI driver for the PlantBasedPizza React frontend (http://localhost:3000).
// Flow: register -> login -> add Margherita from the menu -> open cart -> Submit Order
//       -> /orders list. Screenshots land in .claude/skills/run-plantbasedpizza/shots/.
// Uses playwright-core with the locally installed Chrome (channel "chrome"), so no browser download.
// Usage: node ui.mjs            (headless)
//        HEADED=1 node ui.mjs   (watch it)
import { chromium } from 'playwright-core';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const FE = process.env.FE_URL ?? 'http://localhost:3000';
const SHOTS = join(dirname(fileURLToPath(import.meta.url)), 'shots');
mkdirSync(SHOTS, { recursive: true });

const email = `ui${Date.now()}@test.com`;
const pw = 'Ui!Pass12345';
const browser = await chromium.launch({ channel: process.env.PW_CHANNEL ?? 'chrome', headless: !process.env.HEADED });
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', e => console.log('[pageerror]', e.message));
const shot = async (name, fullPage = false) => { const p = join(SHOTS, `${name}.png`); await page.screenshot({ path: p, fullPage }); console.log('screenshot', p); };

try {
  await page.goto(`${FE}/register`);
  await page.getByPlaceholder('Email Address').fill(email);
  await page.getByPlaceholder('Password').fill(pw);
  await page.getByRole('button', { name: 'Register' }).click();
  await page.waitForURL('**/login');                         // register navigates to /login on success
  console.log('registered', email);

  await page.getByPlaceholder('Email Address').fill(email);
  await page.getByPlaceholder('Password').fill(pw);
  await page.locator('button[type=submit]').click();
  await page.waitForURL(u => new URL(u).pathname === '/');
  await page.getByText('Margherita', { exact: true }).waitFor(); // menu comes from GET /recipes via the gateway
  console.log('logged in; menu loaded');
  await shot('01-menu', true);

  // Each menu card has a green "+" IconButton; pick the one inside the Margherita card.
  const card = page.locator('.MuiCard-root', { has: page.getByText('Margherita', { exact: true }) });
  await card.locator('button').click();
  await page.getByText('marg added to order!').waitFor();
  console.log('added marg');

  await page.locator('button:has([data-testid=ShoppingCartIcon])').click();
  await page.getByRole('button', { name: 'Submit Order' }).click();
  await page.getByText('Order submitted!').waitFor();
  console.log('order submitted');
  await shot('02-submitted');

  await page.goto(`${FE}/orders`);
  await page.waitForLoadState('networkidle');
  await shot('03-orders');
  console.log('UI OK');
} catch (e) {
  console.log('UI FAIL:', e.message.split('\n')[0]);
  await shot('error');
  process.exitCode = 1;
} finally {
  await browser.close();
}
