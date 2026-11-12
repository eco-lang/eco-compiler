// Runs the Snapshot Elm program (compiled to JS) and writes each graph's text and bytecode, and each
// block of host bytes, into OUTDIR:  node emit.js SNAPSHOT.js OUTDIR
const fs = require('fs');
const path = require('path');
const [, , js, outDir] = process.argv;
const Elm = new Function(fs.readFileSync(js, 'utf8') + '; return this.Elm;').call({});
fs.mkdirSync(outDir, { recursive: true });
const app = Elm.Snapshot.init();
app.ports.emit.subscribe((item) => {
  const base = path.resolve(outDir, item.name);
  if (item.errors) {
    fs.writeFileSync(base + '.errors', item.errors.join('\n') + '\n');
  } else if (item.bytes) {
    fs.writeFileSync(base + '.bin', Buffer.from(item.bytes));
  } else {
    fs.writeFileSync(base + '.mlir', item.mlir);
    fs.writeFileSync(base + '.mlirbc', Buffer.from(item.bytecode));
  }
});
