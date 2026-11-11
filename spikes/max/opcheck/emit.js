// Runs the OpCheck Elm program (compiled to JS) and writes each family's MLIR and manifest.
//   node emit.js OPCHECK.js OUTDIR
const fs = require('fs');
const path = require('path');
const [, , js, outDir] = process.argv;
const src = fs.readFileSync(js, 'utf8');
const Elm = new Function(src + '; return this.Elm;').call({});
fs.mkdirSync(outDir, { recursive: true });
const manifest = [];
const app = Elm.OpCheck.init();
app.ports.emit.subscribe((family) => {
  if (family.errors) {
    console.error(`${family.graph}: build errors:\n  ` + family.errors.join('\n  '));
    process.exitCode = 1;
    return;
  }
  const file = path.resolve(outDir, family.graph + '.mlir');
  fs.writeFileSync(file, family.mlir);
  fs.writeFileSync(file + 'bc', Buffer.from(family.bytecode));
  delete family.mlir;
  delete family.bytecode;
  family.file = file;
  manifest.push(family);
  fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 1));
});
