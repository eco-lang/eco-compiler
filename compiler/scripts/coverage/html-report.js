#!/usr/bin/env node
// html-report.js — renders elm-coverage's HTML report for one suite's stored counts
// (cov.py html). Usage: node html-report.js <info.json> <counts.json> <src dir> <out dir>
// The report is written to <out dir>/.coverage/coverage.html (analyze.js writes under the cwd).
'use strict';
const fs = require('fs');
const path = require('path');

const [infoPath, countsPath, srcDir, outDir] = process.argv.slice(2).map((p) => path.resolve(p));
const info = JSON.parse(fs.readFileSync(infoPath, 'utf8'));
const counts = JSON.parse(fs.readFileSync(countsPath, 'utf8'));

const coverageData = {};
const moduleMap = {};
for (const mod of Object.keys(info)) {
    const file = path.join(srcDir, ...mod.split('.')) + '.elm';
    if (!fs.existsSync(file)) continue;
    const c = counts[mod] || {};
    coverageData[mod] = info[mod].map((a, i) => Object.assign({}, a, c[i] ? { count: c[i] } : {}));
    moduleMap[mod] = file;
}

fs.mkdirSync(path.join(outDir, '.coverage'), { recursive: true });
process.chdir(outDir);
const analyze = require(path.join(__dirname, '..', '..', 'elm-coverage', 'lib', 'analyze.js'));
analyze(srcDir, { coverageData, moduleMap }, 'html').then(
    () => console.log(path.join(outDir, '.coverage', 'coverage.html')),
    (e) => { console.error('html-report: ' + (e && e.stack || e)); process.exit(1); });
