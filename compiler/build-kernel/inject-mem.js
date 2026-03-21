const fs = require('fs');
const path = process.argv[2] || 'bin/eco-boot-2.js';
let code = fs.readFileSync(path, 'utf8');

const instrumentationCode = `
var _Mem_startTime = Date.now();
var _Mem_bindCount = 0;
var _Mem_ioCount = 0;
var _Mem_lastLogBinds = 0;
var _Mem_BIND_INTERVAL = 100000;

function _Mem_log(reason) {
    var mem = process.memoryUsage();
    var elapsed = ((Date.now() - _Mem_startTime) / 1000).toFixed(1);
    var rss = (mem.rss / 1048576).toFixed(0);
    var heapUsed = (mem.heapUsed / 1048576).toFixed(0);
    var heapTotal = (mem.heapTotal / 1048576).toFixed(0);
    var ext = (mem.external / 1048576).toFixed(0);
    process.stderr.write('[mem ' + elapsed + 's] ' + reason +
        ' rss=' + rss + 'MB heap=' + heapUsed + '/' + heapTotal +
        'MB ext=' + ext + 'MB binds=' + _Mem_bindCount + ' ios=' + _Mem_ioCount + '\\n');
}

`;

// Insert instrumentation globals just before _Scheduler_step
code = code.replace(
    'function _Scheduler_step(proc)\n{',
    instrumentationCode + 'function _Scheduler_step(proc)\n{'
);

// Instrument bind counting (rootTag 0 = andThen, 1 = onError)
code = code.replace(
    `\t\t\tproc.f = proc.g.b(proc.f.a);\n\t\t\tproc.g = proc.g.i;\n\t\t}\n\t\telse if (rootTag === 2)`,
    `\t\t\tproc.f = proc.g.b(proc.f.a);\n\t\t\tproc.g = proc.g.i;\n` +
    `\t\t\t_Mem_bindCount++;\n` +
    `\t\t\tif (_Mem_bindCount - _Mem_lastLogBinds >= _Mem_BIND_INTERVAL) {\n` +
    `\t\t\t\t_Mem_log('bind');\n` +
    `\t\t\t\t_Mem_lastLogBinds = _Mem_bindCount;\n` +
    `\t\t\t}\n` +
    `\t\t}\n\t\telse if (rootTag === 2)`
);

// Instrument IO callback counting (rootTag 2 = binding/callback)
code = code.replace(
    `\t\telse if (rootTag === 2)\n\t\t{\n\t\t\tproc.f.c = proc.f.b(function(newRoot) {`,
    `\t\telse if (rootTag === 2)\n\t\t{\n\t\t\t_Mem_ioCount++;\n\t\t\t_Mem_log('io');\n` +
    `\t\t\tproc.f.c = proc.f.b(function(newRoot) {`
);

fs.writeFileSync(path, code, 'utf8');
console.log('Instrumentation injected into ' + path);
