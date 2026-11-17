/*

*/

// FNV.hash for the JavaScript backend: FNV-1a over a value's content, in [0, 2^32). Equal values must hash
// alike, so a Dict is hashed by its entries in key order, not by its tree's shape. The native kernel
// (src/eco-containers/FNVExports.cpp) gives other numbers; nothing compares the two.

var _FNV_prime = 16777619;
var _FNV_offset = 2166136261;

function _FNV_hash(object) {
    return _FNV_hashHelp(_FNV_offset, object, 0) >>> 0;
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
        if (value.$ === 'RBNode_elm_builtin' || value.$ === -1) {
            return _FNV_hashDict(_FNV_mix(h, 5), value, depth);
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
