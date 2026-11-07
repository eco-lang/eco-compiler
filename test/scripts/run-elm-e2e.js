#!/usr/bin/env node
// run-elm-e2e.js — the plain-Elm E2E suites compiled by a stock Elm 0.19.x compiler (`elm make`)
// and run on node: a check of the tests themselves against the reference compiler, and of any
// Elm 0.19.x release against the tests. The twin of run-js-e2e.js (which compiles with
// eco's Stage-1 guida.js); the CHECK machinery and directives are the same. Node only, no dependencies.
//
// Usage:
//   node test/scripts/run-elm-e2e.js [--elm <path>] [--build-dir <build>] [--repo-root <repo>]
//        [--project <name>[,<name>...]] [--filter <substr>[,<substr>...]] [--jobs <n>]
//        [--compile-jobs <n>] [--timeout <seconds>] [--verbose]
//   node test/scripts/run-elm-e2e.js --project <name> --record <TestName>
//
// The compiler is --elm, else $ELM, else <build>/toolchain/bin/elm (0.19.1, fetched by CMake),
// else `elm` on PATH. It runs with its own ELM_HOME, <build>/test/elm-e2e/<elm version>/elm-home,
// so the package cache it builds is never shared with eco's compilers.
//
// Projects (default: all, in this order; projectSpecs below) — the E2E projects that use only
// stock elm/* packages (not elm-http, which needs eco/kernel, nor eco-system / eco-kernel):
//   elm, elm-core, elm-bytes, elm-json, elm-parser, elm-regex, elm-time, elm-url, elm-html,
//   elm-compile-errors
//   elm-conformance  as in run-js-e2e.js: compiled programs get the mode guard (patchModeGuard),
//                    and a skip directive is a failure there.
// test/eco-divergence, whose programs behave differently under eco and Elm, is not run here.
// For every <project>/src/*.elm with a top-level `main`:
//   1. The test project (elm.json + src/*.elm) is mirrored into one directory per compile
//      worker, <build>/test/elm-e2e/<elm version>/<name>/project-<k> (elm make is not safe to run
//      concurrently in one project; files are only rewritten when their content changed).
//   2. Each test is compiled with `elm make src/<Name>.elm --output=<Name>.js` (debug mode:
//      the tests use Debug.log) to <build>/test/elm-e2e/<elm version>/<name>/out/. A test is
//      recompiled when its .js is older than the test, any helper module, elm.json, this
//      runner, or the elm binary. The first compile of a project runs alone (it fills ELM_HOME).
//   3. Each test runs as `node <Name>.run.js`: a launcher installing the XMLHttpRequest shim
//      (js-e2e-xhr.js) and a minimal `document` (elm-e2e-dom.js), so that the tests' static
//      `main = Html.text ...` programs can start on node, then calling
//      Elm.<Name>.init({ node, flags }) with the `-- FLAGS:` JSON, if any; a program with ports
//      `echoOut` and `echoIn` gets the JIT harness's echo (each echoOut value is sent to echoIn).
//      Environment, stdin,
//      the HTTP test server, exit status, timeout and CHECK matching are as in run-js-e2e.js.
//   A `-- COMPILE-ERROR: <what>` test (test/CheckPatterns.hpp) is not run: it passes iff
//   `elm make` rejects it and its CHECK lines match the compiler's output. It needs no `main`.
//   4. `-- LINUX-ONLY:` as in run-js-e2e.js. There is no other skip: a test whose behaviour
//      differs between eco and Elm belongs in test/eco-divergence, which this runner does not run.
//      `-- LINUX-ONLY:` as in run-js-e2e.js; `-- XFAIL-NATIVE:` and `-- SKIP-AOT:` are ignored.
//   --record <TestName> runs one test without checking it and prints each non-empty output
//   line as `-- CHECK: <line>`; it fails if the run fails or prints non-ASCII.
// Each test's output is kept in .../out/<Name>.log. Each project prints
// "<name>: tests run: N, passed: P, failed: F, skipped: S", then the total line
// "Tests run: ..."; the exit status is 1 if any test failed (or failed to compile), else 0.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { startTestHttpServer } = require('./js-e2e-http-server');
const { pickFreePort } = require('./test-port');

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
        elm: null,
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
            case '--elm': opts.elm = path.resolve(val()); break;
            case '--compile-jobs': opts.compileJobs = Math.max(1, parseInt(val(), 10) || 1); break;
            case '--help': case '-h':
                console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(1, 44)
                    .map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
                process.exit(0);
                break;
            default:
                throw new Error('unknown argument: ' + a);
        }
    }
    if (!opts.buildDir) opts.buildDir = path.join(opts.repoRoot, 'build');
    if (!opts.elm && process.env.ELM) opts.elm = path.resolve(process.env.ELM);
    if (!opts.elm) {
        const fetched = path.join(opts.buildDir, 'toolchain', 'bin', 'elm');
        opts.elm = fs.existsSync(fetched) ? fetched : 'elm';
    }
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

// `-- ENV:` / `-- UNSETENV:` / `-- RLIMIT-FSIZE:` / `-- STDIN-DELAY-MS:` (test/CheckPatterns.hpp).
function extractEnv(content) {
    return directiveLines(content, '-- ENV:').map((rest) => {
        const t = rest.trim();
        const eq = t.indexOf('=');
        const name = eq < 0 ? t : t.slice(0, eq);
        if (eq < 0 || !name || /[ \t$]/.test(name)) {
            throw new Error("malformed ENV directive (want NAME=VALUE): '" + rest + "'");
        }
        return [name, t.slice(eq + 1)];
    });
}

function extractUnsetenv(content) {
    const out = [];
    for (const rest of directiveLines(content, '-- UNSETENV:')) {
        const names = rest.trim().split(/\s+/).filter(Boolean);
        if (!names.length) throw new Error('empty UNSETENV directive');
        if (names.some((n) => /[=$]/.test(n))) throw new Error("malformed UNSETENV directive: '" + rest + "'");
        out.push(...names);
    }
    return out;
}

function extractCount(content, marker) {
    const lines = directiveLines(content, marker);
    if (!lines.length) return null;
    const t = lines[0].trim();
    if (!/^\d{1,18}$/.test(t)) throw new Error('malformed ' + marker + " directive: '" + lines[0] + "'");
    return Number(t);
}

function expandVars(value, lookup) {
    let out = '';
    for (let i = 0; i < value.length; i++) {
        if (value[i] !== '$') { out += value[i]; continue; }
        if (value[i + 1] === '$') { out += '$'; i++; continue; }
        if (value[i + 1] === '{') {
            const close = value.indexOf('}', i + 2);
            if (close < 0) throw new Error("unterminated ${ in ENV value '" + value + "'");
            const name = value.slice(i + 2, close);
            const v = lookup(name);
            if (v === undefined) throw new Error("ENV value '" + value + "': ${" + name + '} is not known to this harness');
            out += v;
            i = close;
            continue;
        }
        out += '$';
    }
    return out;
}

// The child's environment: `base` with the test's ENV lines (expanded against `base`) set and
// its UNSETENV names removed.
function childEnv(t, base) {
    const env = Object.assign({}, base);
    for (const [name, value] of t.env) {
        if (t.unset.includes(name)) throw new Error('ENV and UNSETENV both name ' + name);
        env[name] = expandVars(value, (n) => base[n]);
    }
    for (const name of t.unset) delete env[name];
    return env;
}

let prlimitPath;
function findPrlimit() {
    if (prlimitPath !== undefined) return prlimitPath;
    prlimitPath = null;
    for (const dir of (process.env.PATH || '').split(path.delimiter).concat(['/usr/bin', '/bin'])) {
        if (!dir) continue;
        const p = path.join(dir, 'prlimit');
        try { fs.accessSync(p, fs.constants.X_OK); prlimitPath = p; break; } catch (e) { /* next */ }
    }
    return prlimitPath;
}

function extractSkip(content) {
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

// The launcher of a test: the XMLHttpRequest shim for elm/http, a minimal DOM for static Html
// programs, then the program, with the `-- FLAGS:` JSON (if any) as its flags.
const xhrShim = path.join(__dirname, 'js-e2e-xhr.js');
const domShim = path.join(__dirname, 'elm-e2e-dom.js');
function launcher(name, flags) {
    return 'require(' + JSON.stringify(xhrShim) + ');\n' +
        'const node = require(' + JSON.stringify(domShim) + ').install();\n' +
        "const app = require('./" + name + ".js').Elm." + name + '.init({ node' +
        (flags === null ? '' : ', flags: ' + flags) + ' });\n' +
        // The generic port echo of the JIT harness (ElmE2ETestBase.hpp installPortEchoBounce): a
        // value sent out through `echoOut` comes back in through `echoIn`.
        'if (app && app.ports && app.ports.echoOut && app.ports.echoIn) {\n' +
        '    app.ports.echoOut.subscribe((v) => app.ports.echoIn.send(v));\n' +
        '}\n';
}

// `-- FLAGS: {...}`: the JSON flags of a `Program Value` test (test/ElmE2ETestBase.hpp).
function extractFlags(content) {
    const lines = directiveLines(content, '-- FLAGS:');
    if (!lines.length) return null;
    const text = lines[0].trim();
    JSON.parse(text);   // throws on a bad directive
    return text;
}

// --- Projects --------------------------------------------------------------------------------

// The test projects this runner knows: those whose elm.json names only stock elm/* packages.
// `modeGuard` patches the compiled program so that a Char equality whose debug-mode answer
// differs from --optimize throws (patchModeGuard); `allowSkip: false` makes a skip a failure.
function projectSpecs(repo) {
    const plain = ['elm', 'elm-core', 'elm-bytes', 'elm-json', 'elm-parser', 'elm-regex', 'elm-time',
        'elm-url', 'elm-html', 'elm-compile-errors',
        // eco's own tests: valid Elm, so stock Elm must run them too (CHECK-MLIR lines are skipped).
        'eco-mlir', 'eco-elm', 'eco-elm-bytes', 'eco-elm-core', 'eco-elm-json', 'eco-elm-regex', 'eco-elm-conformance'];
    return plain.map((name) => ({ name, dir: path.join(repo, 'test', name), modeGuard: false, allowSkip: true }))
        .concat([{ name: 'elm-conformance', dir: path.join(repo, 'test', 'elm-conformance'),
            modeGuard: true, allowSkip: false,
            unicodeTables: path.join(repo, 'runtime', 'src', 'allocator', 'CaseMapTables.hpp') }]);
}

// The compiler's version (`elm --version`), which names the work directory.
function elmVersion(elm) {
    const r = spawnSync(elm, ['--version'], { encoding: 'utf8' });
    if (r.error || r.status !== 0) {
        throw new Error('cannot run ' + elm + ' --version' + (r.error ? ': ' + r.error.message : ''));
    }
    return r.stdout.trim();
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
    const work = path.join(opts.workRoot, spec.name);
    const workers = Math.max(1, opts.compileJobs);
    const projects = Array.from({ length: workers }, (_, k) => path.join(work, 'project-' + k));
    const project = projects[0];
    const outDir = path.join(work, 'out');
    if (!fs.existsSync(path.join(testDir, 'elm.json'))) throw new Error('missing ' + path.join(testDir, 'elm.json'));
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
    const elmJson = fs.readFileSync(path.join(testDir, 'elm.json'));
    const tests = [];
    const sources = fs.readdirSync(srcDir).filter((f) => f.endsWith('.elm')).sort();
    for (const f of sources) {
        const content = fs.readFileSync(path.join(srcDir, f), 'utf8');
        if (/^main\b/m.test(content) || /^-- COMPILE-ERROR:/m.test(content)) {
            tests.push({ name: f.slice(0, -4), content });
        }
    }
    for (const p of projects) {
        writeIfChanged(path.join(p, 'elm.json'), elmJson);
        for (const f of sources) writeIfChanged(path.join(p, 'src', f), fs.readFileSync(path.join(srcDir, f)));
        for (const f of fs.readdirSync(path.join(p, 'src'))) {
            if (f.endsWith('.elm') && !sources.includes(f)) {
                fs.unlinkSync(path.join(p, 'src', f));   // a test that was deleted upstream
            }
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
    console.log('Elm E2E (' + spec.name + '): ' + selected.length + ' of ' + tests.length + ' tests selected' +
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
            t.env = extractEnv(t.content);
            t.unset = extractUnsetenv(t.content);
            t.fsize = extractCount(t.content, '-- RLIMIT-FSIZE:');
            t.stdinDelay = extractCount(t.content, '-- STDIN-DELAY-MS:');
            t.flags = extractFlags(t.content);
            t.compileError = directiveLines(t.content, '-- COMPILE-ERROR:').length > 0;
            if (t.compileError && !t.patterns.length) {
                throw new Error('a COMPILE-ERROR test needs CHECK lines describing the error report');
            }
            if (skip === null && t.fsize !== null && !findPrlimit()) {
                skip = 'RLIMIT-FSIZE needs prlimit (util-linux), not found on this host';
            }
        } catch (e) {
            results.set(t.name, { status: 'fail', message: String(e.message || e) });
            continue;
        }
        if (skip !== null && !spec.allowSkip) {
            results.set(t.name, { status: 'fail', message: skip + ': skips are not allowed here: ' +
                spec.name + ' tests must run everywhere' });
        } else if (skip !== null) results.set(t.name, { status: 'skip', message: skip });
        else toRun.push(t);
    }

    // 2. Compile.
    const shared = Math.max(
        mtimeMs(path.join(project, 'elm.json')),
        opts.elm.includes(path.sep) ? mtimeMs(opts.elm) : -1,
        mtimeMs(__filename),   // the mode guard is part of the compiled output
        ...fs.readdirSync(path.join(project, 'src'))
            .filter((f) => f.endsWith('.elm') && !tests.some((t) => t.name + '.elm' === f))
            .map((f) => mtimeMs(path.join(project, 'src', f))));
    const stale = toRun.filter((t) => {
        if (t.compileError) return true;   // the compile is the test: never cached
        const js = mtimeMs(path.join(outDir, t.name + '.js'));
        return js < 0 || js < Math.max(shared, mtimeMs(path.join(project, 'src', t.name + '.elm')));
    });
    console.log('Compiling: ' + (toRun.length - stale.length) + ' up to date, ' + stale.length + ' to compile');
    const compileOne = async (t, k) => {
        const js = path.join(outDir, t.name + '.js');
        const r = await run(opts.elm, ['make', 'src/' + t.name + '.elm', '--output=' + js], {
            cwd: projects[k],
            env: Object.assign({}, process.env, { ELM_HOME: opts.elmHome }),
        });
        if (t.compileError) {
            const produced = fs.existsSync(js);
            try { fs.unlinkSync(js); } catch (e) { /* none */ }
            let message = r.code === 0 || produced ? 'compiled, but a compile error was expected'
                : verifyPatterns(r.output, t.patterns);
            if (message) message += '\n--- compiler output ---\n' + r.output.slice(0, 4000);
            results.set(t.name, { status: message ? 'fail' : 'pass', message });
            // A failure is printed with the summary, as other compile failures are.
            if (!message && !opts.record) console.log('  PASS ' + spec.name + '/' + t.name + ' (compile error)');
        } else if (r.code !== 0 || !fs.existsSync(js)) {
            try { fs.unlinkSync(js); } catch (e) { /* none */ }
            results.set(t.name, { status: 'fail', message: 'compile failed (exit ' + r.code + '):\n' + r.output.slice(0, 4000) });
        } else if (spec.modeGuard) {
            try { patchModeGuard(js); } catch (e) {
                try { fs.unlinkSync(js); } catch (e2) { /* none */ }
                results.set(t.name, { status: 'fail', message: String(e.message || e) });
            }
        }
    };
    if (stale.length) {
        await compileOne(stale[0], 0);
        let next = 1;
        await Promise.all(projects.map(async (_, k) => {
            while (next < stale.length) await compileOne(stale[next++], k);
        }));
    }
    for (const t of toRun) {
        writeIfChanged(path.join(outDir, t.name + '.run.js'), launcher(t.name, t.flags));
    }

    // 3. Run.
    const runnable = toRun.filter((t) => !results.has(t.name));
    console.log('Running ' + runnable.length + ' tests (max ' + opts.jobs + ' parallel)...');
    const outputs = new Map();
    const runOne = async (t) => {
        const port = await pickFreePort();
        const started = Date.now();
        let env;
        try {
            env = childEnv(t, Object.assign({}, process.env, serverEnv, { ECO_TEST_PORT: String(port) }));
        } catch (e) {
            const message = 'bad test directive: ' + String(e.message || e);
            results.set(t.name, { status: 'fail', message, ms: 0 });
            outputs.set(t.name, { output: '' });
            if (!opts.record) console.log('  FAIL ' + spec.name + '/' + t.name + '\n    ' + message);
            return;
        }
        const r = await new Promise((resolve) => {
            const piped = t.stdin !== null || t.stdinDelay !== null;
            const stdin = piped ? 'pipe' : fs.openSync('/dev/null', 'r');
            const nodeArgv = [process.execPath, t.name + '.run.js'];
            const argv = t.fsize === null ? nodeArgv
                : [findPrlimit(), '--fsize=' + t.fsize + ':' + t.fsize, ...nodeArgv];
            const child = spawn(argv[0], argv.slice(1), {
                cwd: outDir,
                stdio: [stdin, 'pipe', 'pipe'],
                env,
            });
            if (typeof stdin === 'number') fs.closeSync(stdin);
            const chunks = [];
            child.stdout.on('data', (d) => chunks.push(d));
            child.stderr.on('data', (d) => chunks.push(d));
            child.on('error', (e) => chunks.push(Buffer.from(String(e))));
            let stdinTimer = null;
            if (piped) {
                child.stdin.on('error', () => {});
                const feed = () => child.stdin.end(t.stdin === null ? '' : t.stdin);
                if (t.stdinDelay === null) feed();
                else stdinTimer = setTimeout(feed, t.stdinDelay);
            }
            let timedOut = false;
            const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, opts.timeoutSec * 1000);
            child.on('close', (code, signal) => {
                clearTimeout(timer);
                if (stdinTimer) clearTimeout(stdinTimer);
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

    const version = elmVersion(opts.elm);
    opts.workRoot = path.join(opts.buildDir, 'test', 'elm-e2e', version);
    opts.elmHome = path.join(opts.workRoot, 'elm-home');
    console.log('Elm E2E: compiler ' + opts.elm + ' (' + version + '), ELM_HOME ' + opts.elmHome);

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
    console.error('run-elm-e2e: ' + (e && e.stack || e));
    process.exit(2);
});
