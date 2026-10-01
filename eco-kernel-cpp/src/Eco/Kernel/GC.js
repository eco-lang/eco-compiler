/*
import Eco.Kernel.Scheduler exposing (succeed, binding)
*/

// Explicit garbage collections for the JS builds (bootstrap stages 2-5);
// plans/frontend-heap-release.md §5.3. Returns the report as a JSON STRING,
// exactly as the C++ kernel (src/eco/GC.cpp) does, so Eco/GC.elm decodes the
// same keys in every build and --optimize's field mangling never touches it.
// Without node --expose-gc no collection runs and collected = 0 (not an error).
// Report values are observations only (HEAP_076): no code may branch on them.

function _GC_run(major) {
    var g = typeof globalThis.gc === 'function' ? globalThis.gc : null;
    var hasProcess = typeof process !== 'undefined' && typeof process.memoryUsage === 'function';
    var mem = function() {
        return hasProcess ? process.memoryUsage() : { rss: 0, heapUsed: 0, heapTotal: 0 };
    };
    var now = function() {
        return hasProcess && process.hrtime && process.hrtime.bigint
            ? process.hrtime.bigint() : BigInt(0);
    };
    var b = mem();
    var t0 = now();
    if (g) {
        try {
            g(major ? { type: 'major', execution: 'sync', flavor: 'last-resort' }
                    : { type: 'minor', execution: 'sync' });
        } catch (_) {
            g(); // older V8: options unsupported -> full GC
        }
    }
    var ns = g ? Number(now() - t0) : 0;
    var a = mem();
    return JSON.stringify({
        kind: major ? 'major' : 'minor', collected: g ? 1 : 0,
        totalNs: ns, gcNs: ns, sweepNs: 0, shrinkNs: 0, discardNs: 0, trimNs: 0,
        rssBefore: b.rss, rssAfterDiscard: a.rss, rssAfter: a.rss,
        oldInUseBefore: b.heapUsed, oldInUseAfter: a.heapUsed,
        oldPendingBefore: 0, oldPendingAfter: 0, oldHighWater: a.heapTotal,
        liveAfterMark: g && major ? a.heapUsed : 0,
        releasedBytes: 0, shrinkReleasedBytes: 0, discardedBytes: 0, nurseryCommitted: 0,
        minorCount: 0, majorCount: 0, majorsRun: g && major ? 1 : 0, trimResult: -1
    });
}

var _GC_minorGC = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(_GC_run(false)));
});

var _GC_majorGC = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(_GC_run(true)));
});
