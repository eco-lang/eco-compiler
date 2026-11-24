/*

import Elm.Kernel.List exposing (fromArray, toArray)

*/

// SeqDictTrie.remap for the JavaScript backend: a copy of the SeqDict trie `root` with every entry
// replaced by the entry at its order index in `flat` (a JsArray2, here a JS array, of Maybe entries), as
// the native kernel (src/eco-system/SeqDictTrie/SeqDictTrieExports.cpp) builds it. Nodes and slots keep
// their own constructor tags (`$`, a name or, under --optimize, a number), so the copy needs no names.
// A Branch's second field is the slot array, a Collision's the entry list; a Data slot holds an Entry
// (fields a to d, the index b), a Sub slot a node (fields a and b). `probe` is for the native kernel.

var _SeqDictTrie_remap = F3(function (flat, probe, root) {
    return _SeqDictTrie_node(flat, root);
});

function _SeqDictTrie_entry(flat, entry) {
    return flat[entry.b].a;
}

function _SeqDictTrie_node(flat, node) {
    if (!Array.isArray(node.b)) {
        var entries = __List_toArray(node.b);
        for (var i = 0; i < entries.length; i++) {
            entries[i] = _SeqDictTrie_entry(flat, entries[i]);
        }
        return { $: node.$, a: node.a, b: __List_fromArray(entries) };
    }
    var slots = node.b;
    var out = new Array(slots.length);
    for (var j = 0; j < slots.length; j++) {
        var slot = slots[j];
        out[j] = {
            $: slot.$,
            a: 'c' in slot.a ? _SeqDictTrie_entry(flat, slot.a) : _SeqDictTrie_node(flat, slot.a)
        };
    }
    return { $: node.$, a: node.a, b: out };
}
