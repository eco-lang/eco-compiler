// inject-bytecode-monitor.js
// Instruments eco-boot-2.js to monitor bytecode generation memory and sizes
const fs = require('fs');
const path = process.argv[2] || 'bin/eco-boot-2.js';
let code = fs.readFileSync(path, 'utf8');

// Helper function for memory reporting
const helperCode = `
var _Mon_startTime = Date.now();
function _Mon_mem(label) {
    if (global.gc) global.gc();
    var mem = process.memoryUsage();
    var elapsed = ((Date.now() - _Mon_startTime) / 1000).toFixed(1);
    var rss = (mem.rss / 1048576).toFixed(0);
    var heapUsed = (mem.heapUsed / 1048576).toFixed(0);
    var heapTotal = (mem.heapTotal / 1048576).toFixed(0);
    var ext = (mem.external / 1048576).toFixed(0);
    process.stderr.write('[mon ' + elapsed + 's] ' + label +
        ' rss=' + rss + 'MB heap=' + heapUsed + '/' + heapTotal +
        'MB ext=' + ext + 'MB\\n');
}
function _Mon_listLen(list) {
    var n = 0;
    while (list.b) { n++; list = list.b; }
    return n;
}
function _Mon_countOpsDeep(list) {
    // Count ops including nested ops in regions
    var count = 0;
    while (list.b) {
        count++;
        var op = list.a;
        // Count nested ops in regions (op.gR = regions)
        if (op.gR && op.gR.b) {
            var regions = op.gR;
            while (regions.b) {
                var region = regions.a;
                var blocks = region.a; // blocks list
                while (blocks.b) {
                    var block = blocks.a;
                    count += _Mon_countOpsDeep(block.be); // block body ops
                    blocks = blocks.b;
                }
                regions = regions.b;
            }
        }
        list = list.b;
    }
    return count;
}
`;

// Insert helper before _Bytes_encode
code = code.replace(
    'function _Bytes_encode(encoder)\n{',
    helperCode + 'function _Bytes_encode(encoder)\n{'
);

// Instrument writeMlirBytecode to measure each phase
const oldWriteFn = `var $eco$compiler$Compiler$Generate$MLIR$Backend$writeMlirBytecode = F3(
\tfunction (mode, monoGraph, target) {
\t\tvar mlirModule = A2($eco$compiler$Compiler$Generate$MLIR$Backend$generateMlirModule, mode, monoGraph);
\t\tvar bytecodeBytes = $eco$compiler$Mlir$Bytecode$Encode$encodeModule(mlirModule);`;

const newWriteFn = `var $eco$compiler$Compiler$Generate$MLIR$Backend$writeMlirBytecode = F3(
\tfunction (mode, monoGraph, target) {
\t\t_Mon_mem('before-generateMlirModule');
\t\tvar mlirModule = A2($eco$compiler$Compiler$Generate$MLIR$Backend$generateMlirModule, mode, monoGraph);
\t\t_Mon_mem('after-generateMlirModule');
\t\tvar topOps = _Mon_listLen(mlirModule.be);
\t\tvar deepOps = _Mon_countOpsDeep(mlirModule.be);
\t\tprocess.stderr.write('[mon] mlirModule.body: ' + topOps + ' top-level ops, ' + deepOps + ' total ops (deep)\\n');
\t\t_Mon_mem('before-encodeModule');
\t\tvar bytecodeBytes = $eco$compiler$Mlir$Bytecode$Encode$encodeModule(mlirModule);
\t\t_Mon_mem('after-encodeModule');
\t\tprocess.stderr.write('[mon] bytecodeBytes: ' + bytecodeBytes.byteLength + ' bytes (' + (bytecodeBytes.byteLength / 1048576).toFixed(1) + ' MB)\\n');`;

if (code.includes(oldWriteFn)) {
    code = code.replace(oldWriteFn, newWriteFn);
    console.log('Instrumented writeMlirBytecode');
} else {
    console.error('ERROR: Could not find writeMlirBytecode pattern');
    process.exit(1);
}

// Also instrument generateMlirModule to track sub-phases
const oldGenFn = `var $eco$compiler$Compiler$Generate$MLIR$Backend$generateMlirModule = F2(
\tfunction (mode, monoGraph0) {
\t\tvar _v0 = monoGraph0;
\t\tvar nodes = _v0.hf;`;

const newGenFn = `var $eco$compiler$Compiler$Generate$MLIR$Backend$generateMlirModule = F2(
\tfunction (mode, monoGraph0) {
\t\t_Mon_mem('genModule-start');
\t\tvar _v0 = monoGraph0;
\t\tvar nodes = _v0.hf;
\t\tprocess.stderr.write('[mon] MonoGraph nodes: present\\n');`;

if (code.includes(oldGenFn)) {
    code = code.replace(oldGenFn, newGenFn);
    console.log('Instrumented generateMlirModule start');
} else {
    console.error('WARNING: Could not find generateMlirModule pattern');
}

// Instrument after Array.foldl produces revOpChunks
const oldFoldResult = `\t\tvar revOpChunks = _v1.a;
\t\tvar ctxAfterNodes = _v1.b;
\t\tvar ops = $elm$core$List$concat(
\t\t\t$elm$core$List$reverse(revOpChunks));`;

const newFoldResult = `\t\tvar revOpChunks = _v1.a;
\t\tvar ctxAfterNodes = _v1.b;
\t\t_Mon_mem('after-foldl-nodes');
\t\tprocess.stderr.write('[mon] revOpChunks: ' + _Mon_listLen(revOpChunks) + ' chunks\\n');
\t\tvar ops = $elm$core$List$concat(
\t\t\t$elm$core$List$reverse(revOpChunks));
\t\t_Mon_mem('after-list-concat');
\t\tprocess.stderr.write('[mon] ops (flattened): ' + _Mon_listLen(ops) + ' ops\\n');`;

if (code.includes(oldFoldResult)) {
    code = code.replace(oldFoldResult, newFoldResult);
    console.log('Instrumented foldl/concat');
} else {
    console.error('WARNING: Could not find foldl result pattern');
}

// Instrument after lambdas
const oldLambdas = `\t\tvar lambdaOps = _v5.a;
\t\tvar finalCtx = _v5.b;
\t\tvar typeTableOp = $eco$compiler$Compiler$Generate$MLIR$TypeTable$generateTypeTable(finalCtx);`;

const newLambdas = `\t\tvar lambdaOps = _v5.a;
\t\tvar finalCtx = _v5.b;
\t\tprocess.stderr.write('[mon] lambdaOps: ' + _Mon_listLen(lambdaOps) + ' ops\\n');
\t\t_Mon_mem('after-processLambdas');
\t\tvar typeTableOp = $eco$compiler$Compiler$Generate$MLIR$TypeTable$generateTypeTable(finalCtx);`;

if (code.includes(oldLambdas)) {
    code = code.replace(oldLambdas, newLambdas);
    console.log('Instrumented lambdas');
} else {
    console.error('WARNING: Could not find lambdas pattern');
}

// Instrument the encodeModule function to track collection vs encoding
// Find the encodeModule function
const oldEncodeMod = 'var $eco$compiler$Mlir$Bytecode$Encode$encodeModule = function (mod) {';
const newEncodeMod = 'var $eco$compiler$Mlir$Bytecode$Encode$encodeModule = function (mod) {\n\t_Mon_mem("encodeModule-entry");';

if (code.includes(oldEncodeMod)) {
    code = code.replace(oldEncodeMod, newEncodeMod);
    console.log('Instrumented encodeModule entry');
} else {
    console.error('WARNING: Could not find encodeModule pattern');
}

fs.writeFileSync(path, code, 'utf8');
console.log('All instrumentation injected into ' + path);
