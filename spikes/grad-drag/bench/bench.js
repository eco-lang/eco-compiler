// Times Bench.elm's solvers:  node bench.js BENCH.js
// Each run is one Elm init (the whole pointer path is solved inside it), timed here.
const fs = require('fs');
const [, , js] = process.argv;
const Elm = new Function(fs.readFileSync(js, 'utf8') + '; return this.Elm;').call({});
const runs = [];
for (const joint of [3, 7, 11]) {
  for (const method of ['builtin', 'gradient']) {
    // warm up the JIT once per configuration, then time
    for (const timed of [false, true]) {
      const moves = timed ? 200 : 20;
      let result = null;
      const t0 = process.hrtime.bigint();
      const app = Elm.Bench.init({ flags: { method, joint, moves } });
      app.ports.report.subscribe((r) => { result = r; });
      const ms = Number(process.hrtime.bigint() - t0) / 1e6;
      if (timed) runs.push({ ms, app, method, joint, moves, get: () => result });
    }
  }
}
for (const method of ['cannon', 'cannonEval', 'train', 'lensEval', 'lens', 'classifyEval', 'classifyTrain', 'cubeEval', 'epidemicEval', 'layoutRelax', 'wavesField', 'wavesEval']) {
  for (const timed of [false, true]) {
    const moves = timed ? 50 : 5;
    let result = null;
    const t0 = process.hrtime.bigint();
    const app = Elm.Bench.init({ flags: { method, joint: 0, moves } });
    app.ports.report.subscribe((r) => { result = r; });
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    if (timed) runs.push({ ms, method, joint: -1, moves, get: () => result });
  }
}
setTimeout(() => {
  console.log('joint  solver     ms/move  mean err px  worst err px  graph runs/move');
  for (const r of runs) {
    const res = r.get();
    if (r.joint < 0) {
      const what = { cannon: 'cannon solve: ms/move', cannonEval: 'cannon graph: ms/run', train: 'fit Train.step: ms/step', lensEval: 'lens graph: ms/run', lens: 'lens solve: ms/move', classifyEval: 'boundary graph: ms/run', classifyTrain: 'classify Train.step: ms/step', cubeEval: 'cube graph: ms/run', epidemicEval: 'epidemic graph: ms/run', layoutRelax: 'layout relax (4 steps): ms/run', wavesField: 'waves field graph: ms/run', wavesEval: 'waves phase graph: ms/run' }[r.method];
      console.log(`${what.padEnd(26)} ${(r.ms / r.moves).toFixed(2).padStart(8)}` + (r.method === 'cannon' ? `   mean err ${res.meanError.toExponential(2)} m, ${(res.graphRuns / r.moves).toFixed(1)} graph runs/move` : r.method === 'lens' ? `   ${(res.graphRuns / r.moves).toFixed(1)} graph runs/move` : ''));
      continue;
    }
    console.log(
      `${String(r.joint + 1).padStart(5)}  ${r.method.padEnd(9)} ${(r.ms / r.moves).toFixed(3).padStart(8)}  ` +
      `${res.meanError.toExponential(2).padStart(11)}  ${res.worstError.toExponential(2).padStart(12)}  ` +
      `${r.method === 'gradient' ? (res.graphRuns / r.moves).toFixed(1).padStart(15) : '              -'}`
    );
  }
}, 0);
