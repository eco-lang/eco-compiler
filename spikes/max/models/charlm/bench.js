// Times building a GPT-sized training step in Elm (compiled to JS): node bench.js GPTBENCH.js FLAGS-JSON
const fs = require('fs');
const [, , js, flags] = process.argv;
const Elm = new Function(fs.readFileSync(js, 'utf8') + '; return this.Elm;').call({});
const t0 = process.hrtime.bigint();
const app = Elm.GptBench.init({ flags: JSON.parse(flags) });
app.ports.report.subscribe((r) => {
  const s = Number(process.hrtime.bigint() - t0) / 1e9;
  const mb = process.memoryUsage().heapUsed / 1e6;
  console.log(JSON.stringify({ ...JSON.parse(flags), ...r, buildSeconds: +s.toFixed(1), heapMB: Math.round(mb) }));
});
