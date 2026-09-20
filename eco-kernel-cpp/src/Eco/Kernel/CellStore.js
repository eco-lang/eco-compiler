/*
*/

// CellStore — mutable, index-addressed cell vectors with an undo trail.
//
// The JS twin of eco/CellStore.cpp, used by the JS bootstrap stages. Same
// contract: handles are dense indices, never reused; a disposed handle throws
// on use; every mutator returns the handle.
//
// No GC rooting is needed here — JS keeps the arrays alive by reference.

var _CellStore_stores = [];

var _CellStore_live = function(h) {
    var s = _CellStore_stores[h];
    if (s === undefined || s === null) {
        throw new Error('Eco.CellStore: use after dispose (handle ' + h + ')');
    }
    return s;
};

var _CellStore_new = function(cap) {
    var h = _CellStore_stores.length;
    _CellStore_stores.push({ cells: [], trail: [], marks: [] });
    return h;
};

var _CellStore_size = function(h) {
    return _CellStore_live(h).cells.length;
};

var _CellStore_get = F2(function(ix, h) {
    var s = _CellStore_live(h);
    if (ix < 0 || ix >= s.cells.length) {
        throw new Error('Eco.CellStore: get index out of range (' + ix + ')');
    }
    return s.cells[ix];
});

var _CellStore_set = F3(function(ix, cell, h) {
    var s = _CellStore_live(h);
    if (ix < 0 || ix >= s.cells.length) {
        throw new Error('Eco.CellStore: set index out of range (' + ix + ')');
    }
    if (s.marks.length > 0) {
        s.trail.push([ix, s.cells[ix]]);
    }
    s.cells[ix] = cell;
    return h;
});

var _CellStore_push = F2(function(cell, h) {
    _CellStore_live(h).cells.push(cell);
    return h;
});

var _CellStore_pushMark = function(h) {
    var s = _CellStore_live(h);
    s.marks.push([s.trail.length, s.cells.length]);
    return h;
};

var _CellStore_rollback = function(h) {
    var s = _CellStore_live(h);
    if (s.marks.length === 0) {
        throw new Error('Eco.CellStore: rollback without a mark');
    }
    var mark = s.marks.pop();
    var trailLen = mark[0];
    var cellCount = mark[1];
    while (s.trail.length > trailLen) {
        var entry = s.trail.pop();
        if (entry[0] < cellCount) {
            s.cells[entry[0]] = entry[1];
        }
    }
    s.cells.length = cellCount;
    if (s.marks.length === 0) {
        s.trail.length = 0;
    }
    return h;
};

var _CellStore_commit = function(h) {
    var s = _CellStore_live(h);
    if (s.marks.length === 0) {
        throw new Error('Eco.CellStore: commit without a mark');
    }
    s.marks.pop();
    if (s.marks.length === 0) {
        s.trail.length = 0;
    }
    return h;
};

var _CellStore_disposeThen = F2(function(h, x) {
    if (h >= 0 && h < _CellStore_stores.length) {
        _CellStore_stores[h] = null;
    }
    return x;
});
