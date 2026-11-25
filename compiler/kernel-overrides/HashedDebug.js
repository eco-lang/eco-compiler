/*
kind kernel
requires Elm.Kernel.Debug
requires Eco.Kernel.FNV
package elm/core 1.0.5
*/
// eco/system's Hash.Hashed pairs a value with its hash. eco's native Debug.toString prints a Hashed as its
// value alone (RuntimeExports.cpp, Tag_Hashed); this makes elm/core's development-build printer do the
// same. The JS kernel (_Eco_FNV_hashed) gives the object the string `$` 'Hashed_elm_builtin' in both build
// modes; production builds print '<internals>' for every value, so only `_Debug_toAnsiString` needs
// changing. elm/core's printer calls `_Debug_toAnsiString` by name, so a Hashed nested in other values
// comes through here too. Every program that can build a Hashed has eco/system's FNV kernel (Hash.elm
// imports it). `_Debug_toAnsiString(ansi, value)` has this contract in every elm/core 1.0.x release.
var _KernelOverride_stockToAnsiString = _Debug_toAnsiString;
_Debug_toAnsiString = function(ansi, value)
{
	if (typeof value === 'object' && value !== null && value.$ === 'Hashed_elm_builtin')
	{
		return _Debug_toAnsiString(ansi, value.b);
	}
	return _KernelOverride_stockToAnsiString(ansi, value);
};
