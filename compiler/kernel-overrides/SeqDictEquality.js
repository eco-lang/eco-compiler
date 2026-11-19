/*
kind kernel
requires Elm.Kernel.Utils
requires Eco.Kernel.FNV
package elm/core 1.0.5
*/
// eco/system's SeqDict keeps its entries in a hash trie and in an insertion-order Array, where removing
// an entry leaves a hole, so two SeqDicts with the same entries in the same order can differ field by
// field. eco's native `==` compares two SeqDicts by their entries (seqDictEq in Utils.cpp); this makes
// elm/core's JavaScript `==` do the same. The wrapper turns two SeqDicts into their entry lists and hands
// them to the stock function; everything else goes to it unchanged. `_Utils_eq` and `_Utils_eqHelp` call
// `_Utils_eqHelp` by name, so SeqDicts nested in other values, SeqSets included, go through it too.
// eco/system's FNV kernel, which every program using SeqDict has, recognises a SeqDict in both build
// modes and lists its entries (plans/js-kernel-overrides.md, section 5). `_Utils_eqHelp(x, y, depth,
// stack)` has this contract in every elm/core 1.0.x release.
var _KernelOverride_stockEqHelp = _Utils_eqHelp;
_Utils_eqHelp = function(x, y, depth, stack)
{
	if (typeof x === 'object' && x !== null && y !== null && _Eco_FNV_isSeqDict(x))
	{
		x = _Eco_FNV_seqDictEntries(x);
		y = _Eco_FNV_seqDictEntries(y);
	}
	return _KernelOverride_stockEqHelp(x, y, depth, stack);
};
