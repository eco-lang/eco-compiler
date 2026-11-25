/*

import Array exposing (foldl)
import Elm.Kernel.List exposing (fromArray)
import Elm.Kernel.Utils exposing (Tuple2)

*/

// FNV.hash for the JavaScript backend: FNV-1a over a value's content, in [0, 2^32). Equal values must hash
// alike, so a Dict is hashed by its entries in key order and a SeqDict by its entries in insertion order,
// not by their trees' shapes. The native kernel (src/eco-system/FNV/FNVExports.cpp) gives other numbers;
// nothing compares the two.
//
// isSeqDict and seqDictEntryArray are also what compiler/kernel-overrides/SeqDictEquality.js calls (as
// _Eco_FNV_isSeqDict and _Eco_FNV_seqDictEntryArray) to make elm/core's `==` compare SeqDicts by their
// entries, as eco's native `==` does (plans/js-kernel-overrides.md §5). Keep both names.

var _FNV_prime = 16777619;
var _FNV_offset = 2166136261;

function _FNV_hash(object) {
    // A Hashed is its stored hash, as natively: Hash.hash (Hash.hashed x) == Hash.hash x.
    if (_FNV_isHashed(object)) return object.a;
    return _FNV_hashHelp(_FNV_offset, object, 0) >>> 0;
}

// eco/system's Hash.Hashed (HEAP_089 natively): a value with its hash, built only here. Its `$` is a string
// in both build modes (it is not compiled from a constructor), which no compiled value has in an --optimize
// build and no constructor is named in a development build (`_elm_builtin` names are reserved), and which
// elm/core's production `==` does not mistake for a Dict (it tests `x.$ < 0`). `==` compares `$`, then the
// hash `a`, then the value `b`; compiler/kernel-overrides/HashedDebug.js prints it as its value.
function _FNV_hashed(value) {
    return { $: 'Hashed_elm_builtin', a: _FNV_hash(value), b: value };
}

function _FNV_value(hashed) {
    return hashed.b;
}

function _FNV_hashOf(hashed) {
    return hashed.a;
}

function _FNV_isHashed(value) {
    return typeof value === 'object' && value !== null && value.$ === 'Hashed_elm_builtin';
}

function _FNV_mix(h, x) {
    return Math.imul(h ^ x, _FNV_prime);
}

function _FNV_hashHelp(h, value, depth) {
    switch (typeof value) {
    case 'string':
        h = _FNV_mix(h, 4);
        for (var i = 0, len = value.length; i < len; i++) {
            h = _FNV_mix(h, value.charCodeAt(i));
        }
        return h;
    case 'number':
        // Only the integer part counts (1.5 collides with 1, which `==` sorts out), so -0 and 0 agree.
        return _FNV_mix(_FNV_mix(h, value | 0), (value / 4294967296) | 0);
    case 'boolean':
        return _FNV_mix(h, value ? 2 : 3);
    case 'object':
        if (value === null || depth > 16) return h;
        if (value instanceof String) return _FNV_hashHelp(h, value.valueOf(), depth);
        // A Hashed contributes its stored hash; its value is not walked (as natively, marker 18).
        if (value.$ === 'Hashed_elm_builtin') return _FNV_mix(_FNV_mix(h, 18), value.a);
        if (value.$ === 'RBNode_elm_builtin' || value.$ === -1) {
            return _FNV_hashDict(_FNV_mix(h, 5), value, depth);
        }
        if (_FNV_isSeqDict(value)) {
            return _FNV_hashHelp(_FNV_mix(h, 6), _FNV_seqDictEntries(value), depth + 1);
        }
        for (var key in value) {
            h = _FNV_hashHelp(h, value[key], depth + 1);
        }
        return h;
    default:
        return h;
    }
}

// Hashes the entries of the Dict tree `node` in key order. A node's fields are color, key, value, left
// and right, a to e.
function _FNV_hashDict(h, node, depth) {
    while (node.$ === 'RBNode_elm_builtin' || node.$ === -1) {
        h = _FNV_hashDict(h, node.d, depth);
        h = _FNV_hashHelp(h, node.b, depth + 1);
        h = _FNV_hashHelp(h, node.c, depth + 1);
        node = node.e;
    }
    return h;
}

// Whether `value`, an object, is a SeqDict: its one constructor is `SeqDict_elm_builtin` in a development
// build and the reserved tag -3 in an --optimize build (ctorToInt in Compiler/GenerateJs/Expression.elm),
// as Dict's nodes are 'RBNode_elm_builtin' or -1. No other value has either.
function _FNV_isSeqDict(value) {
    return value.$ === 'SeqDict_elm_builtin' || value.$ === -3;
}

// The Entry objects of the SeqDict `seqDict` in insertion order, as a JS array: a walk of the order
// Array's tree (field c: a JS array of SubTree and Leaf nodes, `$` 'SubTree'/0 and 'Leaf'/1, each
// holding a JS array) and its tail (field d), skipping the Nothings (no field a). What
// compiler/kernel-overrides/SeqDictEquality.js compares, as _Eco_FNV_seqDictEntryArray; keep the name.
function _FNV_seqDictEntryArray(seqDict) {
    var out = [];
    var array = seqDict.b.__$array;
    _FNV_collectTree(array.c, out);
    _FNV_collectLeaf(array.d, out);
    return out;
}

function _FNV_collectTree(tree, out) {
    for (var i = 0; i < tree.length; i++) {
        var node = tree[i];
        if (node.$ === 'SubTree' || node.$ === 0) {
            _FNV_collectTree(node.a, out);
        } else {
            _FNV_collectLeaf(node.a, out);
        }
    }
}

function _FNV_collectLeaf(leaf, out) {
    for (var i = 0; i < leaf.length; i++) {
        var slot = leaf[i];
        if (slot.a !== undefined) {
            out.push(slot.a);
        }
    }
}

// The entries of the SeqDict `seqDict` in insertion order, as an Elm List ( k, v ). A SeqDict's fields are
// its trie's root and, second (b), the record whose `array` holds Maybe (Entry hash index key value) in
// insertion order, Nothing where an entry was removed; an Entry's key and value are its fields c and d.
// `__$array` follows --optimize's field renaming.
function _FNV_seqDictEntries(seqDict) {
    var entries = A3(__Array_foldl, F2(function (slot, acc) {
        if (slot.a !== undefined) {
            acc.push(__Utils_Tuple2(slot.a.c, slot.a.d));
        }
        return acc;
    }), [], seqDict.b.__$array);
    return __List_fromArray(entries);
}
