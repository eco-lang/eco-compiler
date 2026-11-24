/*
kind kernel
requires Elm.Kernel.Utils
requires Eco.Kernel.FNV
package elm/core 1.0.5
*/
// eco/system's SeqDict keeps its entries in a hash trie and in an insertion-order Array, where removing
// an entry leaves a hole, so two SeqDicts with the same entries in the same order can differ field by
// field. eco's native `==` compares two SeqDicts by their entries (seqDictEq in Utils.cpp); this makes
// elm/core's JavaScript `==` do the same. The wrapper reads both SeqDicts' entries in insertion order as
// JS arrays and compares the keys and values pairwise, one level deeper; a pair past depth 100 goes to
// the stock function, which defers it to the stack as for any value. Everything else goes to it
// unchanged. `_Utils_eq` and `_Utils_eqHelp` call
// `_Utils_eqHelp` by name, so SeqDicts nested in other values, SeqSets included, go through it too.
// eco/system's FNV kernel, which every program using SeqDict has, recognises a SeqDict in both build
// modes and lists its entries (_Eco_FNV_seqDictEntryArray; plans/js-kernel-overrides.md, section 5). `_Utils_eqHelp(x, y, depth,
// stack)` has this contract in every elm/core 1.0.x release.
var _KernelOverride_stockEqHelp = _Utils_eqHelp;
_Utils_eqHelp = function(x, y, depth, stack)
{
	if (depth <= 100 && typeof x === 'object' && x !== null && y !== null && _Eco_FNV_isSeqDict(x))
	{
		var xs = _Eco_FNV_seqDictEntryArray(x);
		var ys = _Eco_FNV_seqDictEntryArray(y);
		if (xs.length !== ys.length)
		{
			return false;
		}
		for (var i = 0; i < xs.length; i++)
		{
			if (!_Utils_eqHelp(xs[i].c, ys[i].c, depth + 1, stack) || !_Utils_eqHelp(xs[i].d, ys[i].d, depth + 1, stack))
			{
				return false;
			}
		}
		return true;
	}
	return _KernelOverride_stockEqHelp(x, y, depth, stack);
};
