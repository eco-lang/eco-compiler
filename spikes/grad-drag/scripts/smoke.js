// Smoke test in headless Chromium over the DevTools protocol (make smoke CHROME=...): real pointer drags
// on every panel of build/grad-drag.html; reports where each grabbed handle ended up and page errors.
const { spawn } = require('child_process');
const [, , chrome, page, shotPrefix] = process.argv;
const proc = spawn(chrome, ['--no-sandbox', '--disable-gpu', '--hide-scrollbars', '--remote-debugging-port=9333', '--window-size=1040,5600', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0;
const pending = new Map();
function send(method, params = {}) {
  return new Promise((resolve) => { const i = ++id; pending.set(i, resolve); ws.send(JSON.stringify({ id: i, method, params })); });
}
async function evaluate(expr) {
  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
  return r.result.result.value;
}
async function mouse(type, x, y) {
  await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1, pointerType: 'mouse' });
}
// centre of the n-th circle (in document order) of the k-th svg with this fill
const centre = (svg, fill, n) => evaluate(`(() => {
  const cs = [...document.querySelectorAll('svg')[${svg}].querySelectorAll('circle')].filter(c => c.getAttribute('fill') === '${fill}');
  const n = ${n}; const c = n < 0 ? cs[cs.length + n] : cs[n]; const r = c.getBoundingClientRect();
  return [r.left + r.width / 2, r.top + r.height / 2];
})()`);
async function drag(from, to, steps, beforeRelease) {
  await mouse('mousePressed', from[0], from[1]);
  const t0 = Date.now();
  for (let k = 1; k <= steps; k++) {
    const t = k / steps;
    await mouse('mouseMoved', from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t);
  }
  const ms = (Date.now() - t0) / steps;
  await sleep(60);
  if (beforeRelease) await beforeRelease();
  await mouse('mouseReleased', to[0], to[1]);
  await sleep(400);
  return ms;
}
// press at the first point, move through the rest, measure (still pressed), release
async function dragPath(points, measure, afterRelease) {
  await mouse('mousePressed', points[0][0], points[0][1]);
  const t0 = Date.now();
  for (const p of points.slice(1)) await mouse('mouseMoved', p[0], p[1]);
  const ms = (Date.now() - t0) / (points.length - 1);
  await sleep(60);
  const during = afterRelease ? null : await measure();
  await mouse('mouseReleased', points[points.length - 1][0], points[points.length - 1][1]);
  await sleep(500);
  return { ms, result: afterRelease ? await measure() : during };
}
// from `from`, out to a circle about `centre` of this radius, then twice round it
function twiceRound(from, centre, radius) {
  const a0 = Math.atan2(from[1] - centre[1], from[0] - centre[0]);
  const onCircle = (a) => [centre[0] + radius * Math.cos(a), centre[1] + radius * Math.sin(a)];
  const pts = [from];
  for (let k = 1; k <= 10; k++) { const t = k / 10; const c = onCircle(a0); pts.push([from[0] + (c[0] - from[0]) * t, from[1] + (c[1] - from[1]) * t]); }
  for (let k = 1; k <= 240; k++) pts.push(onCircle(a0 + (4 * Math.PI * k) / 240));
  return pts;
}
(async () => {
  let wsUrl;
  for (let i = 0; i < 50 && !wsUrl; i++) {
    await sleep(200);
    try {
      const list = await (await fetch('http://127.0.0.1:9333/json')).json();
      wsUrl = list.find((t) => t.type === 'page').webSocketDebuggerUrl;
    } catch (e) {}
  }
  ws = new WebSocket(wsUrl);
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } };
  await new Promise((r) => (ws.onopen = r));
  await send('Page.enable'); await send('Runtime.enable');
  const errors = [];
  ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails.text); });
  await send('Page.navigate', { url: page });
  await sleep(1500);
  const report = {};
  // each panel's svg, by its panel's id
  const S = await evaluate(`(() => { const all = [...document.querySelectorAll('svg')]; const o = {}; for (const id of ['builtin', 'gradient', 'cube', 'bezier', 'cannon', 'lens', 'waves', 'epidemic', 'fit', 'classify', 'layout']) o[id] = all.indexOf(document.querySelector('#' + id + ' svg')); return o; })()`);
  // the centre of the circle with this fill nearest a point (evg draws a dragged element last, so order is no guide)
  const nearest = (svg, fill, p) => evaluate(`(() => { const cs = [...document.querySelectorAll('svg')[${svg}].querySelectorAll('circle')].filter(c => c.getAttribute('fill') === '${fill}').map(c => { const r = c.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }); return cs.reduce((b, c) => Math.hypot(c[0] - ${p[0]}, c[1] - ${p[1]}) < Math.hypot(b[0] - ${p[0]}, b[1] - ${p[1]}) ? c : b, cs[0]); })()`);
  const svgText = (svg) => evaluate(`[...document.querySelectorAll('svg')[${svg}].querySelectorAll('text')].map(t => t.textContent).join(' | ')`);
  const svgOrigin = (svg) => evaluate(`(() => { const r = document.querySelectorAll('svg')[${svg}].getBoundingClientRect(); return [r.left, r.top]; })()`);
  for (const [name, svg, fill] of [['builtin', S.builtin, '#1c7ed6'], ['gradient', S.gradient, '#e8590c']]) {
    const tip = await centre(svg, fill, -1);
    const target = [tip[0] + 70, tip[1] + 60];
    const ms = await drag(tip, target, 40);
    const after = await centre(svg, fill, -1);
    report[name + ' tip'] = { msPerMove: +ms.toFixed(2), miss: +Math.hypot(after[0] - target[0], after[1] - target[1]).toFixed(2) };
    const mid = await centre(svg, fill, 5);
    const t2 = [mid[0] - 50, mid[1] + 20];
    const ms2 = await drag(mid, t2, 30);
    const after2 = await centre(svg, fill, 5);
    report[name + ' joint 6'] = { msPerMove: +ms2.toFixed(2), miss: +Math.hypot(after2[0] - t2[0], after2[1] - t2[1]).toFixed(2) };
  }
  const ball = await centre(S.cannon, '#e8590c', -1);
  const bt = [ball[0] + 90, ball[1] + 30];
  const msBall = await drag(ball, bt, 30);
  const ballAfter = await centre(S.cannon, '#e8590c', -1);
  report.cannon = { msPerMove: +msBall.toFixed(2), miss: +Math.hypot(ballAfter[0] - bt[0], ballAfter[1] - bt[1]).toFixed(2), label: await evaluate(`document.querySelectorAll('svg')[${S.cannon}].querySelector('text').textContent`) };
  // fit: training has paused by itself (loss below 0.001); a drag of the curve starts it again, and it
  // pauses again once the curve is back on the points
  const fitStatus = () => evaluate(`document.querySelectorAll('svg')[${S.fit}].parentElement.querySelector('span').textContent`);
  const curvePoint = () => evaluate(`(() => { const svg = document.querySelectorAll('svg')[${S.fit}]; const pl = svg.querySelectorAll('polyline')[0]; const pts = pl.getAttribute('points').trim().split(/\\s+/).map(p => p.split(',').map(Number)); const b = svg.getBoundingClientRect(); const p = pts[70]; return [b.left + p[0], b.top + p[1]]; })()`);
  const clickButton = (label) => evaluate(`(() => { const b = [...document.querySelectorAll('button')].find(b => b.textContent === ${JSON.stringify(label)}); if (b) b.click(); return !!b; })()`);
  report.fitStatus = await fitStatus();
  const p0 = await curvePoint();
  await drag(p0, [p0[0], p0[1] - 70], 30);
  await sleep(150);
  report.fitResumed = await fitStatus();
  await sleep(3000);
  report.fitRefitted = await fitStatus();
  // then pause by hand ("Keep training", then "Pause training"), grab the curve at the screen x of point 5, drag it up
  await clickButton('Keep training');
  await sleep(100);
  await clickButton('Pause training');
  await sleep(200);
  report.fitPaused = await fitStatus();
  const curveStart = await evaluate(`(() => { const svg = document.querySelectorAll('svg')[${S.fit}]; const pl = svg.querySelectorAll('polyline')[0]; const pts = pl.getAttribute('points').trim().split(/\\s+/).map(p => p.split(',').map(Number)); const b = svg.getBoundingClientRect(); const p = pts[70]; return [b.left + p[0], b.top + p[1]]; })()`);
  const ct = [curveStart[0], curveStart[1] - 70];
  const msCurve = await drag(curveStart, ct, 30);
  const curveAt = await evaluate(`(() => { const svg = document.querySelectorAll('svg')[${S.fit}]; const pl = svg.querySelectorAll('polyline')[0]; const pts = pl.getAttribute('points').trim().split(/\\s+/).map(p => p.split(',').map(Number)); const b = svg.getBoundingClientRect(); const p = pts[70]; return [b.left + p[0], b.top + p[1]]; })()`);
  report.fitCurve = { msPerMove: +msCurve.toFixed(2), miss: +Math.abs(curveAt[1] - ct[1]).toFixed(2) };

  // lens: drag the focus; the marker is the best focus of the new lens, so it lands near the pointer
  const lensText = () => evaluate(`document.querySelectorAll('svg')[${S.lens}].querySelector('text').textContent`);
  const focus0 = await centre(S.lens, '#e8590c', 0);
  const ft = [focus0[0] + 50, focus0[1] - 35];
  const msLens = await drag(focus0, ft, 30);
  const focus1 = await centre(S.lens, '#e8590c', 0);
  report.lens = { msPerMove: +msLens.toFixed(2), miss: +Math.hypot(focus1[0] - ft[0], focus1[1] - ft[1]).toFixed(2), label: await lensText() };

  // classifier: drag a red point; then, paused, drag the boundary and measure how near it passes
  const panelButtons = (svg) => `[...document.querySelectorAll('svg')[${svg}].parentElement.parentElement.querySelectorAll('button')]`;
  report.classifyStatus = await evaluate(`${panelButtons(S.classify)}[0].parentElement.textContent`);
  const red = await centre(S.classify, '#e03131', 3);
  const rt = [red[0] + 30, red[1] + 25];
  const msPoint = await drag(red, rt, 30);
  // evg draws the dragged element last, so find the red point nearest the target
  const reds = await evaluate(`[...document.querySelectorAll('svg')[${S.classify}].querySelectorAll('circle')].filter(c => c.getAttribute('fill') === '#e03131').map(c => { const r = c.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })`);
  report.classifyPoint = { msPerMove: +msPoint.toFixed(2), miss: +Math.min(...reds.map((p) => Math.hypot(p[0] - rt[0], p[1] - rt[1]))).toFixed(2) };
  await sleep(2500);
  await evaluate(`(() => { const b = ${panelButtons(S.classify)}; const k = b.find(x => x.textContent === 'Keep training'); if (k) k.click(); })()`);
  await sleep(100);
  await evaluate(`(() => { const b = ${panelButtons(S.classify)}; const k = b.find(x => x.textContent === 'Pause training'); if (k) k.click(); })()`);
  await sleep(200);
  const boundaryPoints = `(() => { const svg = document.querySelectorAll('svg')[${S.classify}]; const b = svg.getBoundingClientRect(); const d = svg.querySelectorAll('path')[0].getAttribute('d'); const nums = d.match(/-?[0-9.]+(e-?[0-9]+)?/g).map(Number); const pts = []; for (let i = 0; i + 1 < nums.length; i += 2) pts.push([b.left + nums[i], b.top + nums[i + 1]]); return pts; })()`;
  const bps = await evaluate(boundaryPoints);
  const centreOf5 = await evaluate(`(() => { const r = document.querySelectorAll('svg')[${S.classify}].getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
  const mid = bps.reduce((best, p) => (Math.hypot(p[0] - centreOf5[0], p[1] - centreOf5[1]) < Math.hypot(best[0] - centreOf5[0], best[1] - centreOf5[1]) ? p : best), bps[0]);
  const bt2 = [mid[0], mid[1] - 30];
  const msBoundary = await drag(mid, bt2, 30);
  const bps2 = await evaluate(boundaryPoints);
  report.classifyBoundary = { msPerMove: +msBoundary.toFixed(2), miss: +Math.min(...bps2.map((p) => Math.hypot(p[0] - bt2[0], p[1] - bt2[1]))).toFixed(2), status: await evaluate(`${panelButtons(S.classify)}[0].parentElement.textContent`) };

  // cube: drag a corner; it should stay under the pointer
  const corner = await centre(S.cube, '#e8590c', 0);
  const cubeTarget = [corner[0] + 30, corner[1] - 20];
  const msCube = await drag(corner, cubeTarget, 30);
  const cornerAfter = await nearest(S.cube, '#e8590c', cubeTarget);
  report.cube = { msPerMove: +msCube.toFixed(2), miss: +Math.hypot(cornerAfter[0] - cubeTarget[0], cornerAfter[1] - cubeTarget[1]).toFixed(2) };

  // waves: drag a band off the axis up by 30 px; then drag the upper source up by 15 px (spacing +30)
  const w0 = await svgOrigin(S.waves);
  report.wavesBefore = await svgText(S.waves);
  const msBand = await drag([w0[0] + 300, w0[1] + 95], [w0[0] + 300, w0[1] + 65], 30);
  // the grabbed band's phase difference (wavelengths), from the labels' spacing and wavelength
  const phaseAt = (label, x, y) => { const [sp, wl] = label.match(/[0-9.]+/g).map(Number); const d = (sy) => Math.hypot(x - 36, y - sy); return (d(150 + sp / 2) - d(150 - sp / 2)) / wl; };
  const wavesAfter = await svgText(S.waves);
  report.wavesBand = { msPerMove: +msBand.toFixed(2), label: wavesAfter, phaseAtGrab: +phaseAt(report.wavesBefore, 300, 95).toFixed(3), phaseAtRelease: +phaseAt(wavesAfter, 300, 65).toFixed(3) };
  const upper = await centre(S.waves, '#e8590c', 0);
  const msSource = await drag(upper, [upper[0], upper[1] - 15], 15);
  report.wavesSource = { msPerMove: +msSource.toFixed(2), label: await svgText(S.waves) };

  // epidemic: drag the peak later and lower
  const peak0 = await centre(S.epidemic, '#e8590c', 0);
  const peakTarget = [peak0[0] + 40, peak0[1] + 60];
  const msPeak = await drag(peak0, peakTarget, 30);
  const peak1 = await centre(S.epidemic, '#e8590c', 0);
  report.epidemic = { msPerMove: +msPeak.toFixed(2), miss: +Math.hypot(peak1[0] - peakTarget[0], peak1[1] - peakTarget[1]).toFixed(2), label: await svgText(S.epidemic) };

  // layout: it has settled by now; drag an outer node away, check it is under the pointer, let it settle
  report.layoutBefore = await svgText(S.layout);
  const node = await centre(S.layout, '#e8590c', 0);
  const nodeTarget = [node[0] + 80, node[1] + 40];
  let nodeAfter;
  const msNode = await drag(node, nodeTarget, 30, async () => { nodeAfter = await nearest(S.layout, '#e8590c', nodeTarget); });
  report.layoutDrag = { msPerMove: +msNode.toFixed(2), miss: +Math.hypot(nodeAfter[0] - nodeTarget[0], nodeAfter[1] - nodeTarget[1]).toFixed(2), label: await svgText(S.layout) };
  await sleep(3000);
  report.layoutSettled = await svgText(S.layout);

  // Bézier: drag the curve across itself, turn the tangent, bend at the selected point, drag the
  // lowest point; each measured after release
  {
    const curvePts = () => evaluate(`(() => { const svg = document.querySelectorAll('svg')[${S.bezier}]; const pl = [...svg.querySelectorAll('polyline')].find(p => p.getAttribute('stroke-width') === '3'); const b = svg.getBoundingClientRect(); return pl.getAttribute('points').trim().split(/\\s+/).map(p => p.split(',').map(Number)).map(([x, y]) => [b.left + x, b.top + y]); })()`);
    const toCurve = (pts, t) => Math.min(...pts.map((p) => Math.hypot(p[0] - t[0], p[1] - t[1])));
    let cp = await curvePts();
    const grab = cp[70];
    const target = [grab[0] + 20, grab[1] - 35];
    const msCurve = await drag(grab, target, 25);
    cp = await curvePts();
    report.bezierCurve = { msPerMove: +msCurve.toFixed(2), curveToTarget: +toCurve(cp, target).toFixed(2) };

    const sel = await centre(S.bezier, '#1c7ed6', 0);
    const tip = await centre(S.bezier, '#e8590c', 0);
    const a = Math.atan2(tip[1] - sel[1], tip[0] - sel[0]) + (40 * Math.PI) / 180;
    const tTarget = [sel[0] + 50 * Math.cos(a), sel[1] + 50 * Math.sin(a)];
    const msTangent = await drag(tip, tTarget, 20);
    const sel2 = await centre(S.bezier, '#1c7ed6', 0);
    const tip2 = await centre(S.bezier, '#e8590c', 0);
    const angleOff = Math.abs(((Math.atan2(tip2[1] - sel2[1], tip2[0] - sel2[0]) - a + 3 * Math.PI) % (2 * Math.PI)) - Math.PI);
    report.bezierTangent = { msPerMove: +msTangent.toFixed(2), angleOffDegrees: +((angleOff * 180) / Math.PI).toFixed(2), pointMoved: +Math.hypot(sel2[0] - sel[0], sel2[1] - sel[1]).toFixed(2) };

    // the comb handle is comb·κ from the point along the normal: drag it 1.6 times as far out
    const c0 = await centre(S.bezier, '#2f9e44', 0);
    const h0 = Math.hypot(c0[0] - sel2[0], c0[1] - sel2[1]);
    const cTarget = [sel2[0] + (c0[0] - sel2[0]) * 1.6, sel2[1] + (c0[1] - sel2[1]) * 1.6];
    const msBend = await drag(c0, cTarget, 20);
    const sel3 = await centre(S.bezier, '#1c7ed6', 0);
    const c1 = await centre(S.bezier, '#2f9e44', 0);
    report.bezierBend = { msPerMove: +msBend.toFixed(2), combBefore: +h0.toFixed(1), combWanted: +(1.6 * h0).toFixed(1), combAfter: +Math.hypot(c1[0] - sel3[0], c1[1] - sel3[1]).toFixed(1), pointMoved: +Math.hypot(sel3[0] - sel2[0], sel3[1] - sel2[1]).toFixed(2), label: await svgText(S.bezier) };

    const low = await evaluate(`(() => { const r = [...document.querySelectorAll('svg')[${S.bezier}].querySelectorAll('rect')].find(r => r.getAttribute('fill') === '#7048e8').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
    const lTarget = [low[0] + 15, low[1] + 10];
    const msLow = await drag(low, lTarget, 20);
    const low2 = await evaluate(`(() => { const r = [...document.querySelectorAll('svg')[${S.bezier}].querySelectorAll('rect')].find(r => r.getAttribute('fill') === '#7048e8').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
    report.bezierLowest = { msPerMove: +msLow.toFixed(2), miss: +Math.hypot(low2[0] - lTarget[0], low2[1] - lTarget[1]).toFixed(2) };
  }

  // pinning: pin the tip, then drag joint 6 on both tentacles; the tip should not move
  {
    await clickButton('Pin the tip');
    await sleep(200);
    for (const [name, svg, fill] of [['builtin', S.builtin, '#1c7ed6'], ['gradient', S.gradient, '#e8590c']]) {
      const tipBefore = await centre(svg, fill, -1);
      const joint = await centre(svg, fill, 5);
      const target = [joint[0] - 12, joint[1] + 6];
      const ms = await drag(joint, target, 20);
      const tipAfter = await nearest(svg, fill, tipBefore);
      const jointAfter = await nearest(svg, fill, target);
      report['pinned ' + name] = { msPerMove: +ms.toFixed(2), tipMoved: +Math.hypot(tipAfter[0] - tipBefore[0], tipAfter[1] - tipBefore[1]).toFixed(2), jointMiss: +Math.hypot(jointAfter[0] - target[0], jointAfter[1] - target[1]).toFixed(2) };
    }
    await clickButton('Unpin the tip');
    await sleep(200);
  }

  // floating: pull the gradient tentacle's tip far past its reach; during the drag the handle is under
  // the pointer and a ghost marks where it will land; after release it lands within reach
  {
    const g0 = await svgOrigin(S.gradient);
    const tip = await centre(S.gradient, '#e8590c', -1);
    const far = [g0[0] + 310, g0[1] + 20];
    const reachOf = (p) => Math.hypot(p[0] - (g0[0] + 160), p[1] - (g0[1] + 262));
    let during;
    await drag(tip, far, 20, async () => { during = await nearest(S.gradient, '#e8590c', far); });
    const after = await nearest(S.gradient, '#e8590c', far);
    report.floating = { handleToPointerDuring: +Math.hypot(during[0] - far[0], during[1] - far[1]).toFixed(2), pointerDistanceFromBase: +reachOf(far).toFixed(1), landedDistanceFromBase: +reachOf(after).toFixed(1), reach: 12 * 19 };
  }

  // lens catalogue: grab the focus, read the stock foci's rings from the overlay, move onto ring B,
  // release: the lens is the stock plano-convex lens
  {
    const f0 = await centre(S.lens, '#e8590c', 0);
    await mouse('mousePressed', f0[0], f0[1]);
    await mouse('mouseMoved', f0[0] + 2, f0[1]);
    await sleep(100);
    const rings = await evaluate(`[...document.querySelectorAll('svg')[${S.lens}].querySelectorAll('circle')].filter(c => c.getAttribute('stroke') === '#1c7ed6').map(c => { const r = c.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })`);
    const b = rings[1];
    for (let k = 1; k <= 20; k++) await mouse('mouseMoved', f0[0] + (b[0] - f0[0]) * k / 20, f0[1] + (b[1] - f0[1]) * k / 20);
    await sleep(100);
    await mouse('mouseReleased', b[0], b[1]);
    await sleep(500);
    report.lensCatalogue = { rings: rings.length, label: await evaluate(`document.querySelectorAll('svg')[${S.lens}].querySelector('text').textContent`) };
  }

  // spinning: the gradient tentacle's tip twice round its base, a cube corner twice round the cube's
  // centre; angles that wrap have no bounds, so both keep up (measured after release: during the drag
  // a floating handle is under the pointer whatever the solver does)
  {
    const g0 = await svgOrigin(S.gradient);
    const tip = await centre(S.gradient, '#e8590c', -1);
    const path = twiceRound(tip, [g0[0] + 160, g0[1] + 262], 150);
    const end = path[path.length - 1];
    const r = await dragPath(path, () => nearest(S.gradient, '#e8590c', end), true);
    report.spinTentacle = { msPerMove: +r.ms.toFixed(2), miss: +Math.hypot(r.result[0] - end[0], r.result[1] - end[1]).toFixed(2) };
    const c0 = await svgOrigin(S.cube);
    const cnr = await centre(S.cube, '#e8590c', 0);
    const mid = [c0[0] + 240, c0[1] + 150];
    const cpath = twiceRound(cnr, mid, Math.hypot(cnr[0] - mid[0], cnr[1] - mid[1]));
    const cend = cpath[cpath.length - 1];
    const rc = await dragPath(cpath, () => nearest(S.cube, '#e8590c', cend), true);
    report.spinCube = { msPerMove: +rc.ms.toFixed(2), miss: +Math.hypot(rc.result[0] - cend[0], rc.result[1] - cend[1]).toFixed(2) };
  }

  // cube snapping: drag visible corners onto where a face-on square's corners would be, a few rounds;
  // a release within 25° of face-on snaps, leaving exactly one face showing
  {
    const c0 = await svgOrigin(S.cube);
    const square = [[180, 90], [300, 90], [300, 210], [180, 210]].map((p) => [c0[0] + p[0], c0[1] + p[1]]);
    const handles = () => evaluate(`[...document.querySelectorAll('svg')[${S.cube}].querySelectorAll('circle')].filter(c => c.getAttribute('opacity') !== '0').map(c => { const r = c.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })`);
    const faces = () => evaluate(`[...document.querySelectorAll('svg')[${S.cube}].querySelectorAll('polygon')].map(p => p.getAttribute('fill-opacity'))`);
    let rounds = 0;
    for (; rounds < 6; rounds++) {
      for (const t of square) {
        const hs = await handles();
        const h = hs.reduce((b, c) => (Math.hypot(c[0] - t[0], c[1] - t[1]) < Math.hypot(b[0] - t[0], b[1] - t[1]) ? c : b), hs[0]);
        await drag(h, t, 15);
      }
      await sleep(500);
      if ((await faces()).filter((o) => o === '1').length === 1) break;
    }
    report.cubeSnap = { rounds: rounds + 1, faceOpacities: await faces() };
  }

  for (const [name, svg] of [['bezier', S.bezier], ['cube', S.cube], ['lens', S.lens], ['waves', S.waves], ['epidemic', S.epidemic], ['fit', S.fit], ['classify', S.classify], ['layout', S.layout]]) {
    const r = await evaluate(`(() => { const r = document.querySelectorAll('svg')[${svg}].getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()`);
    const part = await send('Page.captureScreenshot', { format: 'png', clip: { x: r[0], y: r[1], width: r[2], height: r[3], scale: 1 } });
    require('fs').writeFileSync(shotPrefix + '-' + name + '.png', Buffer.from(part.result.data, 'base64'));
  }
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  require('fs').writeFileSync(shotPrefix + '.png', Buffer.from(shot.result.data, 'base64'));
  report.errors = errors;
  console.log(JSON.stringify(report, null, 1));
  ws.close(); proc.kill();
})().catch((e) => { console.error(e); proc.kill(); process.exit(1); });
