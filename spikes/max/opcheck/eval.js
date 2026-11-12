// Runs every op-check family with Tensor.Eval, the tensor package's pure-Elm evaluator, on the inputs
// ref.py drew (make check-ops-eval):  node eval.js OPCHECK.js INPUTS.json RESULTS.json
// The results are checked by `ref.py --results`, against the same NumPy references as MAX's.
const fs = require('fs');
const [, , js, inputsFile, outFile] = process.argv;
const Elm = new Function(fs.readFileSync(js, 'utf8') + '; return this.Elm;').call({});
const dumped = JSON.parse(fs.readFileSync(inputsFile, 'utf8'));
const results = [];
const t0 = Date.now();
const app = Elm.OpCheck.init({ flags: { inputs: dumped.inputs } });
app.ports.evalOut.subscribe((r) => {
  results.push(r);
  const status = r.error ? `error: ${r.error}` : `${r.outputs.length} outputs`;
  console.log(`${r.graph.padEnd(12)} ${status} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
});
// Port messages may arrive after init returns: write when Node has nothing left to run.
process.on('exit', () => fs.writeFileSync(outFile, JSON.stringify({ results, refused: dumped.refused })));
