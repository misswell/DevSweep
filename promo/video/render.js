#!/usr/bin/env node
/* Deterministic frame renderer for promo/video/engine.html
 * Usage:
 *   node render.js --sample 1.5,3,7,12,20,26,31   # render single stills to shots/
 *   node render.js                                 # render full timeline to frames/
 *   node render.js --fps 60 --start 0 --end 34
 */
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const ROOT = __dirname;
const ENGINE = "file://" + path.join(ROOT, "engine.html");

function arg(name, def) {
  const i = process.argv.indexOf("--" + name);
  return i > -1 ? process.argv[i + 1] : def;
}
const FPS = parseInt(arg("fps", "60"), 10);
const START = parseFloat(arg("start", "0"));
const END = parseFloat(arg("end", "34"));
const DUR = END - START;
const SAMPLE = arg("sample", null);
const OUT = SAMPLE ? path.join(ROOT, "shots") : path.join(ROOT, "frames");
fs.mkdirSync(OUT, { recursive: true });

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  const profile = path.join(ROOT, ".chrome-profile");
  fs.rmSync(profile, { recursive: true, force: true });
  const chrome = spawn(CHROME, [
    "--headless=new",
    "--remote-debugging-port=0",
    "--user-data-dir=" + profile,
    "--no-first-run", "--no-default-browser-check", "--disable-extensions",
    "--disable-background-networking", "--disable-sync", "--mute-audio",
    "--hide-scrollbars", "--force-device-scale-factor=1",
    "--window-size=1920,1080",
    "about:blank"
  ], { stdio: ["ignore", "pipe", "pipe"] });

  const wsUrl = await new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("chrome devtools timeout")), 20000);
    chrome.stderr.on("data", d => {
      buf += d.toString();
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) { clearTimeout(timer); resolve(m[1]); }
    });
    chrome.on("exit", c => reject(new Error("chrome exited " + c)));
  });
  // browser-level endpoint -> find page target
  const browserWS = wsUrl;
  const ws = new WebSocket(browserWS);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

  let msgId = 0;
  const pending = new Map();
  const eventWaiters = [];
  ws.onmessage = ev => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    } else if (msg.method) {
      for (let i = eventWaiters.length - 1; i >= 0; i--) {
        const w = eventWaiters[i];
        if (w.method === msg.method) { eventWaiters.splice(i, 1); w.resolve(msg.params); }
      }
    }
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++msgId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const waitEvent = method => new Promise(resolve => eventWaiters.push({ method, resolve }));

  // attach to the initial page target (retry until it shows up)
  let pageTarget = null;
  for (let i = 0; i < 50 && !pageTarget; i++) {
    const { targetInfos = [] } = await send("Target.getTargets");
    pageTarget = targetInfos.find(t => t.type === "page" && t.url.startsWith("about:"));
    if (!pageTarget) await sleep(100);
  }
  if (!pageTarget) throw new Error("no page target found");
  const attached = await send("Target.attachToTarget", { targetId: pageTarget.targetId, flatten: true });
  const sid = attached.sessionId;

  await send("Page.enable", {}, sid);
  await send("Runtime.enable", {}, sid);
  await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false }, sid);
  const loaded = waitEvent("Page.loadEventFired");
  await send("Page.navigate", { url: ENGINE }, sid);
  await loaded;
  await sleep(300);
  // wait for fonts + icon image decode
  await send("Runtime.evaluate", { expression: `(async () => { await document.fonts.ready; const imgs=[...document.images]; await Promise.all(imgs.map(i=>i.decode().catch(()=>{}))); await new Promise(r=>requestAnimationFrame(r)); })()`, awaitPromise: true }, sid);

  const times = [];
  if (SAMPLE) {
    for (const s of SAMPLE.split(",")) times.push(parseFloat(s));
  } else {
    const n = Math.round(DUR * FPS);
    for (let i = 0; i < n; i++) times.push(START + i / FPS);
  }
  console.log(`rendering ${times.length} frames @${FPS}fps -> ${OUT}`);
  const t0 = Date.now();
  for (let i = 0; i < times.length; i++) {
    const t = times[i];
    await send("Runtime.evaluate", { expression: `window.__seek(${t.toFixed(6)})` }, sid);
    const shot = await send("Page.captureScreenshot", { format: "png", optimizeForSpeed: true }, sid);
    const name = SAMPLE ? `shot_t${t.toFixed(2).replace(".", "_")}.png` : `f${String(Math.round(t * FPS)).padStart(5, "0")}.png`;
    fs.writeFileSync(path.join(OUT, name), Buffer.from(shot.data, "base64"));
    if (!SAMPLE && i % 120 === 0) {
      const el = (Date.now() - t0) / 1000;
      console.log(`  ${i}/${times.length}  (${el.toFixed(0)}s elapsed, ~${((times.length - i) * el / (i + 1)).toFixed(0)}s left)`);
    }
  }
  console.log(`done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  ws.close();
  chrome.kill("SIGKILL");
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
