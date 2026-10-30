#!/usr/bin/env node
// run-js-e2e.js — the JS-target E2E suites (plans/eco-system-library.md Phase 10, decision D15;
// plans/char-case-mapping-elm-exact.md Step 0). Node only, no dependencies.
//
// Usage:
//   node test/scripts/run-js-e2e.js --build-dir <build> [--repo-root <repo>]
//        [--project <name>[,<name>...]] [--filter <substr>[,<substr>...]] [--jobs <n>]
//        [--timeout <seconds>] [--verbose]
//   node test/scripts/run-js-e2e.js --project <name> --record <TestName>
//
// Projects (default: all, in this order; projectSpecs below):
//   eco-system       test/eco-system, compiled with --local-package eco/system=<repo>/system-kernel-cpp
//   elm-conformance  test/elm-conformance, stock elm/core only: the Elm-vs-eco conformance tests,
//                    which the native harness runs too. Compiled programs get the mode guard
//                    (patchModeGuard), and `-- SKIP-JS:` is a failure there.
// For every <project>/src/*.elm with a top-level `main`:
//   1. The test project (elm.json + src/*.elm) is mirrored into <build>/test/js-e2e/<name>/project
//      (files are only rewritten when their content changed, so the compiler's caches and
//      this runner's up-to-date checks keep working). The checked-in TestServerConfig.elm
//      reads this runner's HTTP test server (js-e2e-http-server.js, the twin of
//      test/TestHttpServer.hpp) from ECO_TEST_HTTP_URL / ECO_TEST_HTTPS_URL.
//   2. Each test is compiled with the Stage-1 compiler (compiler/bin/index.js + guida.js)
//      to <build>/test/js-e2e/<name>/out/<Name>.js, with the project's --local-package flags.
//      A test is recompiled when its .js is older than the test, any helper module,
//      elm.json, the project's shared inputs, this runner, or guida.js. The first compile of
//      a project runs alone (it seeds the package caches), the rest in parallel.
//   3. Each test runs as `node <Name>.run.js` (a two-line launcher installing the
//      XMLHttpRequest shim js-e2e-xhr.js, which elm/http needs on Node, and calling
//      Elm.<Name>.init()) in its own child process, with:
//        stdin          the `-- STDIN:` text through a pipe, else /dev/null
//        ECO_TEST_PORT  a free TCP port (test/TestPort.hpp)
//        ECO_TEST_HTTP_URL, ECO_TEST_HTTPS_URL  the HTTP test server (test/TestServerConfig.hpp;
//                       no HTTPS here: both name the plain HTTP port)
//      and passes iff it exits on its own within the timeout (default 60 s) with the
//      `-- EXIT: <n>` status (default 0) and its stdout+stderr satisfy the CHECK-family
//      directives (test/CheckPatterns.hpp semantics: CHECK, CHECK-NOT, CHECK-DAG,
//      CHECK-LABEL, CHECK-SAME, CHECK-NEXT, {{regex}}; any other CHECK-* is an error).
//   4. `-- SKIP-JS: <reason>` (at the start of a line) skips the test on this target. Use
//      it only for behaviour that genuinely exists only natively, always with a reason.
//      `-- LINUX-ONLY: <reason>` skips it on a host that is not Linux, as the native
//      harnesses do (test/CheckPatterns.hpp). `-- XFAIL-NATIVE:` is ignored here.
//   --record <TestName> runs one test without checking it and prints each non-empty output
//   line as `-- CHECK: <line>`; it fails if the run fails or prints non-ASCII.
// Each test's output is kept in <build>/test/js-e2e/<name>/out/<Name>.log. Each project prints
// "<name>: tests run: N, passed: P, failed: F, skipped: S", then the total line
// "Tests run: ..."; the exit status is 1 if any test failed (or failed to compile), else 0.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const { spawn } = require('child_process');
const { startTestHttpServer } = require('./js-e2e-http-server');

// --- Arguments ------------------------------------------------------------------------

function parseArgs(argv) {
    const opts = {
        buildDir: null,
        repoRoot: path.resolve(__filename, '..', '..', '..'),
        filters: [],
        jobs: 8,   // test/IsolatedTestRunner.hpp MAX_PARALLEL_TESTS
        compileJobs: Math.max(1, os.cpus().length),
        timeoutSec: 60,
        verbose: false,
        projects: [],
        record: null,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const next = () => {
            if (i + 1 >= argv.length) throw new Error('missing value after ' + a);
            return argv[++i];
        };
        const eq = a.indexOf('=');
        const key = eq > 0 && a.startsWith('--') ? a.slice(0, eq) : a;
        const val = eq > 0 && a.startsWith('--') ? () => a.slice(eq + 1) : next;
        switch (key) {
            case '--build-dir': opts.buildDir = path.resolve(val()); break;
            case '--repo-root': opts.repoRoot = path.resolve(val()); break;
            case '--filter': case '-f':
                opts.filters.push(...val().split(',').map((s) => s.trim()).filter(Boolean));
                break;
            case '--jobs': case '-j': opts.jobs = Math.max(1, parseInt(val(), 10) || 1); break;
            case '--timeout': opts.timeoutSec = Math.max(1, parseInt(val(), 10) || 60); break;
            case '--verbose': case '-v': opts.verbose = true; break;
            case '--project':
                opts.projects.push(...val().split(',').map((s) => s.trim()).filter(Boolean));
                break;
            case '--record': opts.record = val(); break;
            case '--help': case '-h':
                console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(1, 47)
                    .map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
                process.exit(0);
                break;
            default:
                throw new Error('unknown argument: ' + a);
        }
    }
    if (!opts.buildDir) opts.buildDir = path.join(opts.repoRoot, 'build');
    return opts;
}

// --- CHECK patterns (test/CheckPatterns.hpp) -----------------------------------------------

const CHECK = '-- CHECK:';
const CHECK_NOT = '-- CHECK-NOT:';
const variant = (word) => '-- CHECK-' + word + ':';

function extractCheckPatterns(content) {
    const same = variant('SAME'), next = variant('NEXT'), dag = variant('DAG'), label = variant('LABEL');
    const patterns = [];
    let lastPositive = -1;
    const grab = (line, pos, len) => line.slice(pos + len).replace(/^[ \t]+/, '').replace(/[ \t\r\n]+$/, '');
    const positive = (p) => { patterns.push({ pattern: p, negated: false, continuations: [] }); lastPositive = patterns.length - 1; };
    for (const line of content.split('\n')) {
        let pos, p;
        if ((pos = line.indexOf(CHECK_NOT)) >= 0) {
            p = grab(line, pos, CHECK_NOT.length);
            if (p) { patterns.push({ pattern: p, negated: true, continuations: [] }); lastPositive = -1; }
        } else if ((pos = line.indexOf(same)) >= 0 || (pos = line.indexOf(next)) >= 0) {
            const kind = line.indexOf(same) >= 0 ? 'same' : 'next';
            p = grab(line, pos, (kind === 'same' ? same : next).length);
            if (!p) continue;
            if (lastPositive >= 0) patterns[lastPositive].continuations.push({ kind, pattern: p });
            else positive(p);
        } else if ((pos = line.indexOf(dag)) >= 0) {
            p = grab(line, pos, dag.length);
            if (p) positive(p);
        } else if ((pos = line.indexOf(label)) >= 0) {
            p = grab(line, pos, label.length);
            if (p) positive(p);
        } else if ((pos = line.indexOf(CHECK)) >= 0) {
            p = grab(line, pos, CHECK.length);
            if (p) positive(p);
        } else if ((pos = line.indexOf('-- CHECK-')) >= 0) {
            const base = pos + '-- CHECK'.length;
            const colon = line.indexOf(':', base);
            const ws = line.slice(base).search(/[ \t]/);
            const wordEnd = ws < 0 ? -1 : base + ws;
            if (colon >= 0 && (wordEnd < 0 || colon < wordEnd)) {
                const word = line.slice(base + 1, colon);
                if (!word.startsWith('MLIR')) {
                    throw new Error('unsupported CHECK variant in test file: ' + line.slice(pos, colon + 1) +
                        ' (supported: CHECK, CHECK-NOT, CHECK-DAG, CHECK-SAME, CHECK-NEXT, CHECK-LABEL)');
                }
            }
        }
    }
    return patterns;
}

function patternRegex(pattern) {
    if (pattern.indexOf('{{') < 0) return null;
    let re = '';
    let pos = 0;
    const lit = (s) => s.replace(/[.^$|?*+()[\]{}\\]/g, '\\$&');
    while (pos < pattern.length) {
        const open = pattern.indexOf('{{', pos);
        if (open < 0) { re += lit(pattern.slice(pos)); break; }
        re += lit(pattern.slice(pos, open));
        const close = pattern.indexOf('}}', open + 2);
        if (close < 0) { re += lit(pattern.slice(open)); break; }
        re += pattern.slice(open + 2, close);
        pos = close + 2;
    }
    try { return new RegExp(re); } catch (e) { return null; }
}

// [begin, end) of the first match of `pattern` in text at or after `from`, or null.
function findPattern(text, from, pattern) {
    if (from > text.length) return null;
    const re = patternRegex(pattern);
    if (!re) {
        const p = text.indexOf(pattern, from);
        return p < 0 ? null : [p, p + pattern.length];
    }
    const m = re.exec(text.slice(from));
    return m ? [from + m.index, from + m.index + m[0].length] : null;
}

function groupMatches(lines, cp) {
    for (let i = 0; i < lines.length; i++) {
        let searchFrom = 0;
        for (;;) {
            const base = findPattern(lines[i], searchFrom, cp.pattern);
            if (!base) break;
            let curLine = i, curPos = base[1], ok = true;
            for (const c of cp.continuations) {
                if (c.kind === 'same') {
                    const m = findPattern(lines[curLine], curPos, c.pattern);
                    if (!m) { ok = false; break; }
                    curPos = m[1];
                } else {
                    curLine++;
                    if (curLine >= lines.length) { ok = false; break; }
                    const m = findPattern(lines[curLine], 0, c.pattern);
                    if (!m) { ok = false; break; }
                    curPos = m[1];
                }
            }
            if (ok) return true;
            searchFrom = base[0] + 1;
        }
    }
    return false;
}

function verifyPatterns(output, patterns) {
    const lines = output.split('\n').map((l) => l.replace(/\r$/, ''));
    if (lines.length && lines[lines.length - 1] === '' && output.endsWith('\n')) lines.pop();
    for (const cp of patterns) {
        if (cp.negated) {
            if (findPattern(output, 0, cp.pattern)) return 'Unexpected pattern (CHECK-NOT): ' + cp.pattern;
        } else if (!cp.continuations.length) {
            if (!findPattern(output, 0, cp.pattern)) return 'Missing pattern: ' + cp.pattern;
        } else if (!groupMatches(lines, cp)) {
            return 'Missing pattern: ' + cp.pattern + ' (with ' + cp.continuations.length +
                ' CHECK-SAME/CHECK-NEXT continuation(s))';
        }
    }
    return '';
}

// --- Process directives ---------------------------------------------------------------------

function directiveLines(content, marker) {
    return content.split('\n').filter((l) => l.startsWith(marker)).map((l) => l.slice(marker.length).replace(/\r$/, ''));
}

function extractExit(content) {
    const lines = directiveLines(content, '-- EXIT:');
    if (!lines.length) return 0;
    const t = lines[0].trim();
    if (!/^[+-]?\d+$/.test(t)) throw new Error("malformed EXIT directive: '" + lines[0] + "'");
    return parseInt(t, 10);
}

function extractStdin(content) {
    const lines = directiveLines(content, '-- STDIN:');
    if (!lines.length) return null;
    let out = '';
    for (const rest of lines) {
        const text = rest.startsWith(' ') ? rest.slice(1) : rest;
        for (let i = 0; i < text.length; i++) {
            if (text[i] === '\\' && i + 1 < text.length) {
                const n = text[i + 1];
                if (n === 'n') { out += '\n'; i++; continue; }
                if (n === 't') { out += '\t'; i++; continue; }
                if (n === '\\') { out += '\\'; i++; continue; }
            }
            out += text[i];
        }
    }
    return out;
}

function extractSkip(content) {
    const lines = directiveLines(content, '-- SKIP-JS:');
    if (lines.length) return lines[0].trim() || '(no reason given)';
    const linux = directiveLines(content, '-- LINUX-ONLY:');
    if (linux.length && process.platform !== 'linux') {
        return 'LINUX-ONLY: ' + (linux[0].trim() || '(no reason given)');
    }
    return null;
}

// --- Files ---------------------------------------------------------------------------------------

function writeIfChanged(file, content) {
    try {
        if (fs.readFileSync(file).equals(Buffer.from(content))) return false;
    } catch (e) { /* missing */ }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
    return true;
}

function mtimeMs(file) {
    try { return fs.statSync(file).mtimeMs; } catch (e) { return -1; }
}

function newestMtime(dir) {
    let newest = 0;
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return 0; }
    for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) newest = Math.max(newest, newestMtime(p));
        else newest = Math.max(newest, mtimeMs(p));
    }
    return newest;
}

// --- Child processes --------------------------------------------------------------------------

function run(cmd, args, options) {
    return new Promise((resolve) => {
        const child = spawn(cmd, args, Object.assign({ stdio: ['ignore', 'pipe', 'pipe'] }, options));
        const chunks = [];
        child.stdout.on('data', (d) => chunks.push(d));
        child.stderr.on('data', (d) => chunks.push(d));
        child.on('error', (e) => chunks.push(Buffer.from(String(e))));
        child.on('close', (code, signal) => resolve({ code, signal, output: Buffer.concat(chunks).toString('utf8') }));
    });
}

const recentPorts = [];
function pickFreePort() {
    return new Promise((resolve) => {
        const attempt = (n) => {
            const srv = net.createServer();
            srv.once('error', () => resolve(0));
            srv.listen(0, '127.0.0.1', () => {
                const port = srv.address().port;
                srv.close(() => {
                    if (recentPorts.includes(port) && n < 16) { attempt(n + 1); return; }
                    recentPorts.push(port);
                    if (recentPorts.length > 256) recentPorts.shift();
                    resolve(port);
                });
            });
        };
        attempt(0);
    });
}

async function pool(items, jobs, fn) {
    let next = 0;
    const worker = async () => {
        while (next < items.length) {
            const i = next++;
            await fn(items[i], i);
        }
    };
    await Promise.all(Array.from({ length: Math.min(jobs, items.length) }, worker));
}

// The two-line launcher of a test: the XMLHttpRequest shim for elm/http, then the program.
const xhrShim = path.join(__dirname, 'js-e2e-xhr.js');
function launcher(name) {
    return 'require(' + JSON.stringify(xhrShim) + ');\n' +
        "require('./" + name + ".js').Elm." + name + '.init();\n';
}

// --- Projects --------------------------------------------------------------------------------

// The test projects this runner knows. `modeGuard` patches the compiled program so that a
// Char equality whose debug-mode answer differs from --optimize throws (patchModeGuard);
// `allowSkipJs: false` makes a `-- SKIP-JS:` line a failure.
function projectSpecs(repo) {
    const pkgDir = path.join(repo, 'system-kernel-cpp');
    return [
        { name: 'eco-system', dir: path.join(repo, 'test', 'eco-system'),
          localPackages: ['eco/system=' + pkgDir],
          sharedInputs: [path.join(pkgDir, 'src'), path.join(pkgDir, 'elm.json')],
          modeGuard: false, allowSkipJs: true },
        { name: 'elm-conformance', dir: path.join(repo, 'test', 'elm-conformance'),
          localPackages: [], sharedInputs: [],
          modeGuard: true, allowSkipJs: false,
          unicodeTables: path.join(repo, 'runtime', 'src', 'allocator', 'CaseMapTables.hpp') },
    ];
}

// --- Mode guard (plans/char-case-mapping-elm-exact.md Step 0.3) ------------------------------

// The conformance tests are compiled in debug mode (Debug.log is rejected under --optimize),
// where a Char is a `String` object and _Utils_eqHelp's `for (var key in x)` walk makes
// `x == y` a prefix test. Their reference semantics is --optimize (string equality), so any
// Char equality whose two answers differ is made to throw.
const GUARD_MARKER = '/* eco-conformance mode guard */';
const EQ_DEF = 'function _Utils_eqHelp(x, y, depth, stack)';
const GUARD = GUARD_MARKER + '\n' +
    'function _Utils_eqHelp(x, y, depth, stack) {\n' +
    '\tvar r = _Utils_eqHelp_raw(x, y, depth, stack);\n' +
    '\tif (x instanceof String && y instanceof String && r !== (x.valueOf() === y.valueOf()))\n' +
    "\t\tthrow new Error('eco-conformance: Char equality differs between debug and --optimize: '\n" +
    "\t\t\t+ JSON.stringify(x.valueOf()) + ' == ' + JSON.stringify(y.valueOf()));\n" +
    '\treturn r;\n' +
    '}\n';

function patchModeGuard(jsFile) {
    const src = fs.readFileSync(jsFile, 'utf8');
    if (src.includes(GUARD_MARKER)) return;
    const first = src.indexOf(EQ_DEF);
    if (first < 0 || src.indexOf(EQ_DEF, first + 1) >= 0) {
        throw new Error('stock elm/core Utils.js changed; update patchModeGuard (' + jsFile + ')');
    }
    fs.writeFileSync(jsFile, src.slice(0, first) + GUARD +
        'function _Utils_eqHelp_raw(x, y, depth, stack)' + src.slice(first + EQ_DEF.length));
}

// --- One project ---------------------------------------------------------------------------------

async function runProject(spec, opts, server) {
    const repo = opts.repoRoot;
    const testDir = spec.dir;
    const srcDir = path.join(testDir, 'src');
    const work = path.join(opts.buildDir, 'test', 'js-e2e', spec.name);
    const project = path.join(work, 'project');
    const outDir = path.join(work, 'out');
    const compilerJs = path.join(repo, 'compiler', 'bin', 'index.js');
    const guidaJs = process.env.GUIDA_JS_PATH || path.join(opts.buildDir, 'compiler', 'build-xhr', 'bin', 'guida.js');
    for (const f of [compilerJs, guidaJs, path.join(testDir, 'elm.json')]) {
        if (!fs.existsSync(f)) throw new Error('missing ' + f + ' (build the `guida` target first)');
    }
    fs.mkdirSync(outDir, { recursive: true });
    if (spec.unicodeTables) {
        // The recorded expectations are node's case mapping; eco's tables (UnicodeData.txt
        // simple mappings) must be the same Unicode version (plans/char-simple-case-mapping.md).
        const m = /kUnicodeVersion = "([^"]+)"/.exec(fs.readFileSync(spec.unicodeTables, 'utf8'));
        const tables = m ? m[1] : '(none)';
        if (tables !== process.versions.unicode) {
            throw new Error('node ' + process.version + ' has Unicode ' + process.versions.unicode +
                ', tables are Unicode ' + tables + ': use a node with Unicode ' + tables +
                ' or regenerate the tables (and re-record the conformance tests)');
        }
    }

    // 1. Mirror the project; discover the tests.
    writeIfChanged(path.join(project, 'elm.json'), fs.readFileSync(path.join(testDir, 'elm.json')));
    const tests = [];
    const sources = fs.readdirSync(srcDir).filter((f) => f.endsWith('.elm')).sort();
    for (const f of sources) {
        const content = fs.readFileSync(path.join(srcDir, f), 'utf8');
        writeIfChanged(path.join(project, 'src', f), content);
        if (/^main\b/m.test(content)) tests.push({ name: f.slice(0, -4), content });
    }
    for (const f of fs.readdirSync(path.join(project, 'src'))) {
        if (f.endsWith('.elm') && !sources.includes(f)) {
            fs.unlinkSync(path.join(project, 'src', f));   // a test that was deleted upstream
        }
    }

    const serverEnv = {
        ECO_TEST_HTTP_URL: 'http://127.0.0.1:' + server.port,
        ECO_TEST_HTTPS_URL: 'https://127.0.0.1:' + server.port,
    };

    const selected = opts.record
        ? tests.filter((t) => t.name === opts.record)
        : tests.filter((t) =>
            !opts.filters.length || opts.filters.some((f) => (spec.name + '/' + t.name).includes(f)));
    if (opts.record && !selected.length) throw new Error('--record: no test ' + opts.record + ' in ' + spec.name);
    console.log('JS E2E (' + spec.name + '): ' + selected.length + ' of ' + tests.length + ' tests selected' +
        (opts.filters.length ? ' (filter: ' + opts.filters.join(',') + ')' : '') +
        '; HTTP test server on 127.0.0.1:' + server.port);

    const results = new Map();   // name -> { status: 'pass'|'fail'|'skip', message }
    const toRun = [];
    for (const t of selected) {
        let skip;
        try {
            skip = extractSkip(t.content);
            t.patterns = extractCheckPatterns(t.content);
            t.exit = extractExit(t.content);
            t.stdin = extractStdin(t.content);
        } catch (e) {
            results.set(t.name, { status: 'fail', message: String(e.message || e) });
            continue;
        }
        if (skip !== null && !spec.allowSkipJs) {
            results.set(t.name, { status: 'fail', message: 'SKIP-JS is not allowed here: ' +
                spec.name + ' tests must run on both targets' });
        } else if (skip !== null) results.set(t.name, { status: 'skip', message: skip });
        else toRun.push(t);
    }

    // 2. Compile.
    const shared = Math.max(
        mtimeMs(path.join(project, 'elm.json')),
        ...spec.sharedInputs.map((p) => {
            try { return fs.statSync(p).isDirectory() ? newestMtime(p) : mtimeMs(p); } catch (e) { return -1; }
        }),
        mtimeMs(guidaJs),
        mtimeMs(__filename),   // the mode guard is part of the compiled output
        ...fs.readdirSync(path.join(project, 'src'))
            .filter((f) => f.endsWith('.elm') && !tests.some((t) => t.name + '.elm' === f))
            .map((f) => mtimeMs(path.join(project, 'src', f))));
    const stale = toRun.filter((t) => {
        const js = mtimeMs(path.join(outDir, t.name + '.js'));
        return js < 0 || js < Math.max(shared, mtimeMs(path.join(project, 'src', t.name + '.elm')));
    });
    console.log('Compiling: ' + (toRun.length - stale.length) + ' up to date, ' + stale.length + ' to compile');
    const compileOne = async (t, buildDir) => {
        const js = path.join(outDir, t.name + '.js');
        const args = [compilerJs, 'make', 'src/' + t.name + '.elm', '--output=' + js];
        for (const lp of spec.localPackages) args.push('--local-package', lp);
        if (buildDir) args.push('--builddir=' + buildDir);
        const r = await run(process.execPath, args, {
            cwd: project,
            env: Object.assign({}, process.env, { GUIDA_JS_PATH: guidaJs }),
        });
        if (r.code !== 0 || !fs.existsSync(js)) {
            try { fs.unlinkSync(js); } catch (e) { /* none */ }
            results.set(t.name, { status: 'fail', message: 'compile failed (exit ' + r.code + '):\n' + r.output.slice(0, 4000) });
        } else if (spec.modeGuard) {
            try { patchModeGuard(js); } catch (e) {
                try { fs.unlinkSync(js); } catch (e2) { /* none */ }
                results.set(t.name, { status: 'fail', message: String(e.message || e) });
            }
        }
        writeIfChanged(path.join(outDir, t.name + '.run.js'),
            launcher(t.name));
    };
    if (stale.length) {
        await compileOne(stale[0], null);
        await pool(stale.slice(1), opts.compileJobs, (t) => compileOne(t, t.name));
    }
    for (const t of toRun) {
        writeIfChanged(path.join(outDir, t.name + '.run.js'),
            launcher(t.name));
    }

    // 3. Run.
    const runnable = toRun.filter((t) => !results.has(t.name));
    console.log('Running ' + runnable.length + ' tests (max ' + opts.jobs + ' parallel)...');
    const outputs = new Map();
    const runOne = async (t) => {
        const port = await pickFreePort();
        const started = Date.now();
        const r = await new Promise((resolve) => {
            const stdin = t.stdin === null ? fs.openSync('/dev/null', 'r') : 'pipe';
            const child = spawn(process.execPath, [t.name + '.run.js'], {
                cwd: outDir,
                stdio: [stdin, 'pipe', 'pipe'],
                env: Object.assign({}, process.env, serverEnv, { ECO_TEST_PORT: String(port) }),
            });
            if (typeof stdin === 'number') fs.closeSync(stdin);
            const chunks = [];
            child.stdout.on('data', (d) => chunks.push(d));
            child.stderr.on('data', (d) => chunks.push(d));
            if (t.stdin !== null) {
                child.stdin.on('error', () => {});
                child.stdin.end(t.stdin);
            }
            let timedOut = false;
            const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, opts.timeoutSec * 1000);
            child.on('close', (code, signal) => {
                clearTimeout(timer);
                resolve({ code, signal, timedOut, output: Buffer.concat(chunks).toString('utf8') });
            });
        });
        const ms = Date.now() - started;
        fs.writeFileSync(path.join(outDir, t.name + '.log'), r.output);
        outputs.set(t.name, r);
        let message = '';
        if (r.timedOut) message = 'timed out after ' + opts.timeoutSec + ' s';
        else if (r.signal) message = 'killed by ' + r.signal;
        else if (r.code !== t.exit) message = 'exit code ' + r.code + ', expected ' + t.exit;
        if (!message && !opts.record) message = verifyPatterns(r.output, t.patterns);
        if (message) message += '\n--- output ---\n' + r.output.slice(0, 4000);
        results.set(t.name, { status: message ? 'fail' : 'pass', message, ms });
        if (opts.record) return;
        const res = results.get(t.name);
        console.log((res.status === 'pass' ? '  PASS ' : '  FAIL ') + spec.name + '/' + t.name + ' (' + ms + ' ms)' +
            (res.status === 'fail' ? '\n    ' + message.split('\n').join('\n    ') : ''));
    };
    await pool(runnable, opts.jobs, runOne);

    // --record: print the run's output as CHECK lines (plans/char-case-mapping-elm-exact.md 0.4).
    if (opts.record) {
        const t = selected[0];
        const res = results.get(t.name);
        if (res.status !== 'pass') {
            console.log('  FAIL ' + spec.name + '/' + t.name + '\n    ' + res.message.split('\n').join('\n    '));
            return { passed: 0, failed: 1, skipped: 0, failures: [spec.name + '/' + t.name] };
        }
        // Elm's debug-build banner is JS-only output, not part of the expectation.
        const lines = outputs.get(t.name).output.split('\n').map((l) => l.replace(/\r$/, ''))
            .filter((l) => l.trim() && !l.startsWith('Compiled in DEV mode.'));
        const bad = lines.filter((l) => /[^\x00-\x7f]/.test(l));
        if (bad.length) {
            console.log('  FAIL ' + t.name + ': non-ASCII output; print code points, not text:\n    ' + bad.join('\n    '));
            return { passed: 0, failed: 1, skipped: 0, failures: [spec.name + '/' + t.name] };
        }
        for (const l of lines) console.log('-- CHECK: ' + l);
        return { passed: 1, failed: 0, skipped: 0, failures: [] };
    }

    // 4. Summary.
    let passed = 0, failed = 0, skipped = 0;
    const failures = [];
    for (const t of selected) {
        const r = results.get(t.name);
        if (r.status === 'pass') passed++;
        else if (r.status === 'skip') { skipped++; console.log('  SKIP ' + spec.name + '/' + t.name + ': ' + r.message); }
        else {
            failed++;
            failures.push(spec.name + '/' + t.name);
            if (!runnable.includes(t)) console.log('  FAIL ' + spec.name + '/' + t.name + '\n    ' + r.message.split('\n').join('\n    '));
        }
    }
    console.log(spec.name + ': tests run: ' + (passed + failed) + ', passed: ' + passed + ', failed: ' + failed +
        ', skipped: ' + skipped + '\n');
    return { passed, failed, skipped, failures };
}

// --- Main ----------------------------------------------------------------------------------------

async function main() {
    const opts = parseArgs(process.argv.slice(2));
    const specs = projectSpecs(opts.repoRoot);
    const unknown = opts.projects.filter((n) => !specs.some((s) => s.name === n));
    if (unknown.length) throw new Error('unknown project(s): ' + unknown.join(', ') +
        ' (known: ' + specs.map((s) => s.name).join(', ') + ')');
    if (opts.record && opts.projects.length !== 1) throw new Error('--record needs exactly one --project');
    const chosen = specs.filter((s) => !opts.projects.length || opts.projects.includes(s.name));

    // The single-project layout's work directories, from before the runner took several.
    const work = path.join(opts.buildDir, 'test', 'js-e2e');
    for (const old of ['project', 'out']) {
        fs.rmSync(path.join(work, old), { recursive: true, force: true });
    }

    // The HTTP test server, on an ephemeral port, shared by every project; the tests read its
    // URL from the environment (TestServerConfig.elm), so nothing is regenerated per run.
    const server = await startTestHttpServer(0);
    let passed = 0, failed = 0, skipped = 0;
    const failures = [];
    try {
        for (const spec of chosen) {
            const r = await runProject(spec, opts, server);
            passed += r.passed; failed += r.failed; skipped += r.skipped;
            failures.push(...r.failures);
        }
    } finally {
        await server.close();
    }
    if (opts.record) return failed ? 1 : 0;
    console.log('Tests run: ' + (passed + failed) + ', passed: ' + passed + ', failed: ' + failed +
        ', skipped: ' + skipped);
    if (failures.length) console.log('Failed: ' + failures.join(' '));
    return failed ? 1 : 0;
}

main().then((code) => process.exit(code), (e) => {
    console.error('run-js-e2e: ' + (e && e.stack || e));
    process.exit(2);
});
