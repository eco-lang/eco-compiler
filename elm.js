(function(scope){
'use strict';

function F(arity, fun, wrapper) {
  wrapper.a = arity;
  wrapper.f = fun;
  return wrapper;
}

function F2(fun) {
  return F(2, fun, function(a) { return function(b) { return fun(a,b); }; })
}
function F3(fun) {
  return F(3, fun, function(a) {
    return function(b) { return function(c) { return fun(a, b, c); }; };
  });
}
function F4(fun) {
  return F(4, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return fun(a, b, c, d); }; }; };
  });
}
function F5(fun) {
  return F(5, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return fun(a, b, c, d, e); }; }; }; };
  });
}
function F6(fun) {
  return F(6, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return fun(a, b, c, d, e, f); }; }; }; }; };
  });
}
function F7(fun) {
  return F(7, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return function(g) { return fun(a, b, c, d, e, f, g); }; }; }; }; }; };
  });
}
function F8(fun) {
  return F(8, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return function(g) { return function(h) {
    return fun(a, b, c, d, e, f, g, h); }; }; }; }; }; }; };
  });
}
function F9(fun) {
  return F(9, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return function(g) { return function(h) { return function(i) {
    return fun(a, b, c, d, e, f, g, h, i); }; }; }; }; }; }; }; };
  });
}

function A2(fun, a, b) {
  return fun.a === 2 ? fun.f(a, b) : fun(a)(b);
}
function A3(fun, a, b, c) {
  return fun.a === 3 ? fun.f(a, b, c) : fun(a)(b)(c);
}
function A4(fun, a, b, c, d) {
  return fun.a === 4 ? fun.f(a, b, c, d) : fun(a)(b)(c)(d);
}
function A5(fun, a, b, c, d, e) {
  return fun.a === 5 ? fun.f(a, b, c, d, e) : fun(a)(b)(c)(d)(e);
}
function A6(fun, a, b, c, d, e, f) {
  return fun.a === 6 ? fun.f(a, b, c, d, e, f) : fun(a)(b)(c)(d)(e)(f);
}
function A7(fun, a, b, c, d, e, f, g) {
  return fun.a === 7 ? fun.f(a, b, c, d, e, f, g) : fun(a)(b)(c)(d)(e)(f)(g);
}
function A8(fun, a, b, c, d, e, f, g, h) {
  return fun.a === 8 ? fun.f(a, b, c, d, e, f, g, h) : fun(a)(b)(c)(d)(e)(f)(g)(h);
}
function A9(fun, a, b, c, d, e, f, g, h, i) {
  return fun.a === 9 ? fun.f(a, b, c, d, e, f, g, h, i) : fun(a)(b)(c)(d)(e)(f)(g)(h)(i);
}

console.warn('Compiled in DEV mode. Follow the advice at https://elm-lang.org/0.19.1/optimize for better performance and smaller assets.');


var _JsArray_empty = [];

function _JsArray_singleton(value)
{
    return [value];
}

function _JsArray_length(array)
{
    return array.length;
}

var _JsArray_initialize = F3(function(size, offset, func)
{
    var result = new Array(size);

    for (var i = 0; i < size; i++)
    {
        result[i] = func(offset + i);
    }

    return result;
});

var _JsArray_initializeFromList = F2(function (max, ls)
{
    var result = new Array(max);

    for (var i = 0; i < max && ls.b; i++)
    {
        result[i] = ls.a;
        ls = ls.b;
    }

    result.length = i;
    return _Utils_Tuple2(result, ls);
});

var _JsArray_unsafeGet = F2(function(index, array)
{
    return array[index];
});

var _JsArray_unsafeSet = F3(function(index, value, array)
{
    var length = array.length;
    var result = new Array(length);

    for (var i = 0; i < length; i++)
    {
        result[i] = array[i];
    }

    result[index] = value;
    return result;
});

var _JsArray_push = F2(function(value, array)
{
    var length = array.length;
    var result = new Array(length + 1);

    for (var i = 0; i < length; i++)
    {
        result[i] = array[i];
    }

    result[length] = value;
    return result;
});

var _JsArray_foldl = F3(function(func, acc, array)
{
    var length = array.length;

    for (var i = 0; i < length; i++)
    {
        acc = A2(func, array[i], acc);
    }

    return acc;
});

var _JsArray_foldr = F3(function(func, acc, array)
{
    for (var i = array.length - 1; i >= 0; i--)
    {
        acc = A2(func, array[i], acc);
    }

    return acc;
});

var _JsArray_map = F2(function(func, array)
{
    var length = array.length;
    var result = new Array(length);

    for (var i = 0; i < length; i++)
    {
        result[i] = func(array[i]);
    }

    return result;
});

var _JsArray_indexedMap = F3(function(func, offset, array)
{
    var length = array.length;
    var result = new Array(length);

    for (var i = 0; i < length; i++)
    {
        result[i] = A2(func, offset + i, array[i]);
    }

    return result;
});

var _JsArray_slice = F3(function(from, to, array)
{
    return array.slice(from, to);
});

var _JsArray_appendN = F3(function(n, dest, source)
{
    var destLen = dest.length;
    var itemsToCopy = n - destLen;

    if (itemsToCopy > source.length)
    {
        itemsToCopy = source.length;
    }

    var size = destLen + itemsToCopy;
    var result = new Array(size);

    for (var i = 0; i < destLen; i++)
    {
        result[i] = dest[i];
    }

    for (var i = 0; i < itemsToCopy; i++)
    {
        result[i + destLen] = source[i];
    }

    return result;
});



// LOG

var _Debug_log_UNUSED = F2(function(tag, value)
{
	return value;
});

var _Debug_log = F2(function(tag, value)
{
	console.log(tag + ': ' + _Debug_toString(value));
	return value;
});


// TODOS

function _Debug_todo(moduleName, region)
{
	return function(message) {
		_Debug_crash(8, moduleName, region, message);
	};
}

function _Debug_todoCase(moduleName, region, value)
{
	return function(message) {
		_Debug_crash(9, moduleName, region, value, message);
	};
}


// TO STRING

function _Debug_toString_UNUSED(value)
{
	return '<internals>';
}

function _Debug_toString(value)
{
	return _Debug_toAnsiString(false, value);
}

function _Debug_toAnsiString(ansi, value)
{
	if (typeof value === 'function')
	{
		return _Debug_internalColor(ansi, '<function>');
	}

	if (typeof value === 'boolean')
	{
		return _Debug_ctorColor(ansi, value ? 'True' : 'False');
	}

	if (typeof value === 'number')
	{
		return _Debug_numberColor(ansi, value + '');
	}

	if (value instanceof String)
	{
		return _Debug_charColor(ansi, "'" + _Debug_addSlashes(value, true) + "'");
	}

	if (typeof value === 'string')
	{
		return _Debug_stringColor(ansi, '"' + _Debug_addSlashes(value, false) + '"');
	}

	if (typeof value === 'object' && '$' in value)
	{
		var tag = value.$;

		if (typeof tag === 'number')
		{
			return _Debug_internalColor(ansi, '<internals>');
		}

		if (tag[0] === '#')
		{
			var output = [];
			for (var k in value)
			{
				if (k === '$') continue;
				output.push(_Debug_toAnsiString(ansi, value[k]));
			}
			return '(' + output.join(',') + ')';
		}

		if (tag === 'Set_elm_builtin')
		{
			return _Debug_ctorColor(ansi, 'Set')
				+ _Debug_fadeColor(ansi, '.fromList') + ' '
				+ _Debug_toAnsiString(ansi, $elm$core$Set$toList(value));
		}

		if (tag === 'RBNode_elm_builtin' || tag === 'RBEmpty_elm_builtin')
		{
			return _Debug_ctorColor(ansi, 'Dict')
				+ _Debug_fadeColor(ansi, '.fromList') + ' '
				+ _Debug_toAnsiString(ansi, $elm$core$Dict$toList(value));
		}

		if (tag === 'Array_elm_builtin')
		{
			return _Debug_ctorColor(ansi, 'Array')
				+ _Debug_fadeColor(ansi, '.fromList') + ' '
				+ _Debug_toAnsiString(ansi, $elm$core$Array$toList(value));
		}

		if (tag === '::' || tag === '[]')
		{
			var output = '[';

			value.b && (output += _Debug_toAnsiString(ansi, value.a), value = value.b)

			for (; value.b; value = value.b) // WHILE_CONS
			{
				output += ',' + _Debug_toAnsiString(ansi, value.a);
			}
			return output + ']';
		}

		var output = '';
		for (var i in value)
		{
			if (i === '$') continue;
			var str = _Debug_toAnsiString(ansi, value[i]);
			var c0 = str[0];
			var parenless = c0 === '{' || c0 === '(' || c0 === '[' || c0 === '<' || c0 === '"' || str.indexOf(' ') < 0;
			output += ' ' + (parenless ? str : '(' + str + ')');
		}
		return _Debug_ctorColor(ansi, tag) + output;
	}

	if (typeof DataView === 'function' && value instanceof DataView)
	{
		return _Debug_stringColor(ansi, '<' + value.byteLength + ' bytes>');
	}

	if (typeof File !== 'undefined' && value instanceof File)
	{
		return _Debug_internalColor(ansi, '<' + value.name + '>');
	}

	if (typeof value === 'object')
	{
		var output = [];
		for (var key in value)
		{
			var field = key[0] === '_' ? key.slice(1) : key;
			output.push(_Debug_fadeColor(ansi, field) + ' = ' + _Debug_toAnsiString(ansi, value[key]));
		}
		if (output.length === 0)
		{
			return '{}';
		}
		return '{ ' + output.join(', ') + ' }';
	}

	return _Debug_internalColor(ansi, '<internals>');
}

function _Debug_addSlashes(str, isChar)
{
	var s = str
		.replace(/\\/g, '\\\\')
		.replace(/\n/g, '\\n')
		.replace(/\t/g, '\\t')
		.replace(/\r/g, '\\r')
		.replace(/\v/g, '\\v')
		.replace(/\0/g, '\\0');

	if (isChar)
	{
		return s.replace(/\'/g, '\\\'');
	}
	else
	{
		return s.replace(/\"/g, '\\"');
	}
}

function _Debug_ctorColor(ansi, string)
{
	return ansi ? '\x1b[96m' + string + '\x1b[0m' : string;
}

function _Debug_numberColor(ansi, string)
{
	return ansi ? '\x1b[95m' + string + '\x1b[0m' : string;
}

function _Debug_stringColor(ansi, string)
{
	return ansi ? '\x1b[93m' + string + '\x1b[0m' : string;
}

function _Debug_charColor(ansi, string)
{
	return ansi ? '\x1b[92m' + string + '\x1b[0m' : string;
}

function _Debug_fadeColor(ansi, string)
{
	return ansi ? '\x1b[37m' + string + '\x1b[0m' : string;
}

function _Debug_internalColor(ansi, string)
{
	return ansi ? '\x1b[36m' + string + '\x1b[0m' : string;
}

function _Debug_toHexDigit(n)
{
	return String.fromCharCode(n < 10 ? 48 + n : 55 + n);
}


// CRASH


function _Debug_crash_UNUSED(identifier)
{
	throw new Error('https://github.com/elm/core/blob/1.0.0/hints/' + identifier + '.md');
}


function _Debug_crash(identifier, fact1, fact2, fact3, fact4)
{
	switch(identifier)
	{
		case 0:
			throw new Error('What node should I take over? In JavaScript I need something like:\n\n    Elm.Main.init({\n        node: document.getElementById("elm-node")\n    })\n\nYou need to do this with any Browser.sandbox or Browser.element program.');

		case 1:
			throw new Error('Browser.application programs cannot handle URLs like this:\n\n    ' + document.location.href + '\n\nWhat is the root? The root of your file system? Try looking at this program with `elm reactor` or some other server.');

		case 2:
			var jsonErrorString = fact1;
			throw new Error('Problem with the flags given to your Elm program on initialization.\n\n' + jsonErrorString);

		case 3:
			var portName = fact1;
			throw new Error('There can only be one port named `' + portName + '`, but your program has multiple.');

		case 4:
			var portName = fact1;
			var problem = fact2;
			throw new Error('Trying to send an unexpected type of value through port `' + portName + '`:\n' + problem);

		case 5:
			throw new Error('Trying to use `(==)` on functions.\nThere is no way to know if functions are "the same" in the Elm sense.\nRead more about this at https://package.elm-lang.org/packages/elm/core/latest/Basics#== which describes why it is this way and what the better version will look like.');

		case 6:
			var moduleName = fact1;
			throw new Error('Your page is loading multiple Elm scripts with a module named ' + moduleName + '. Maybe a duplicate script is getting loaded accidentally? If not, rename one of them so I know which is which!');

		case 8:
			var moduleName = fact1;
			var region = fact2;
			var message = fact3;
			throw new Error('TODO in module `' + moduleName + '` ' + _Debug_regionToString(region) + '\n\n' + message);

		case 9:
			var moduleName = fact1;
			var region = fact2;
			var value = fact3;
			var message = fact4;
			throw new Error(
				'TODO in module `' + moduleName + '` from the `case` expression '
				+ _Debug_regionToString(region) + '\n\nIt received the following value:\n\n    '
				+ _Debug_toString(value).replace('\n', '\n    ')
				+ '\n\nBut the branch that handles it says:\n\n    ' + message.replace('\n', '\n    ')
			);

		case 10:
			throw new Error('Bug in https://github.com/elm/virtual-dom/issues');

		case 11:
			throw new Error('Cannot perform mod 0. Division by zero error.');
	}
}

function _Debug_regionToString(region)
{
	if (region.start.line === region.end.line)
	{
		return 'on line ' + region.start.line;
	}
	return 'on lines ' + region.start.line + ' through ' + region.end.line;
}



// EQUALITY

function _Utils_eq(x, y)
{
	for (
		var pair, stack = [], isEqual = _Utils_eqHelp(x, y, 0, stack);
		isEqual && (pair = stack.pop());
		isEqual = _Utils_eqHelp(pair.a, pair.b, 0, stack)
		)
	{}

	return isEqual;
}

function _Utils_eqHelp(x, y, depth, stack)
{
	if (x === y)
	{
		return true;
	}

	if (typeof x !== 'object' || x === null || y === null)
	{
		typeof x === 'function' && _Debug_crash(5);
		return false;
	}

	if (depth > 100)
	{
		stack.push(_Utils_Tuple2(x,y));
		return true;
	}

	/**/
	if (x.$ === 'Set_elm_builtin')
	{
		x = $elm$core$Set$toList(x);
		y = $elm$core$Set$toList(y);
	}
	if (x.$ === 'RBNode_elm_builtin' || x.$ === 'RBEmpty_elm_builtin')
	{
		x = $elm$core$Dict$toList(x);
		y = $elm$core$Dict$toList(y);
	}
	//*/

	/**_UNUSED/
	if (x.$ < 0)
	{
		x = $elm$core$Dict$toList(x);
		y = $elm$core$Dict$toList(y);
	}
	//*/

	for (var key in x)
	{
		if (!_Utils_eqHelp(x[key], y[key], depth + 1, stack))
		{
			return false;
		}
	}
	return true;
}

var _Utils_equal = F2(_Utils_eq);
var _Utils_notEqual = F2(function(a, b) { return !_Utils_eq(a,b); });



// COMPARISONS

// Code in Generate/JavaScript.hs, Basics.js, and List.js depends on
// the particular integer values assigned to LT, EQ, and GT.

function _Utils_cmp(x, y, ord)
{
	if (typeof x !== 'object')
	{
		return x === y ? /*EQ*/ 0 : x < y ? /*LT*/ -1 : /*GT*/ 1;
	}

	/**/
	if (x instanceof String)
	{
		var a = x.valueOf();
		var b = y.valueOf();
		return a === b ? 0 : a < b ? -1 : 1;
	}
	//*/

	/**_UNUSED/
	if (typeof x.$ === 'undefined')
	//*/
	/**/
	if (x.$[0] === '#')
	//*/
	{
		return (ord = _Utils_cmp(x.a, y.a))
			? ord
			: (ord = _Utils_cmp(x.b, y.b))
				? ord
				: _Utils_cmp(x.c, y.c);
	}

	// traverse conses until end of a list or a mismatch
	for (; x.b && y.b && !(ord = _Utils_cmp(x.a, y.a)); x = x.b, y = y.b) {} // WHILE_CONSES
	return ord || (x.b ? /*GT*/ 1 : y.b ? /*LT*/ -1 : /*EQ*/ 0);
}

var _Utils_lt = F2(function(a, b) { return _Utils_cmp(a, b) < 0; });
var _Utils_le = F2(function(a, b) { return _Utils_cmp(a, b) < 1; });
var _Utils_gt = F2(function(a, b) { return _Utils_cmp(a, b) > 0; });
var _Utils_ge = F2(function(a, b) { return _Utils_cmp(a, b) >= 0; });

var _Utils_compare = F2(function(x, y)
{
	var n = _Utils_cmp(x, y);
	return n < 0 ? $elm$core$Basics$LT : n ? $elm$core$Basics$GT : $elm$core$Basics$EQ;
});


// COMMON VALUES

var _Utils_Tuple0_UNUSED = 0;
var _Utils_Tuple0 = { $: '#0' };

function _Utils_Tuple2_UNUSED(a, b) { return { a: a, b: b }; }
function _Utils_Tuple2(a, b) { return { $: '#2', a: a, b: b }; }

function _Utils_Tuple3_UNUSED(a, b, c) { return { a: a, b: b, c: c }; }
function _Utils_Tuple3(a, b, c) { return { $: '#3', a: a, b: b, c: c }; }

function _Utils_chr_UNUSED(c) { return c; }
function _Utils_chr(c) { return new String(c); }


// RECORDS

function _Utils_update(oldRecord, updatedFields)
{
	var newRecord = {};

	for (var key in oldRecord)
	{
		newRecord[key] = oldRecord[key];
	}

	for (var key in updatedFields)
	{
		newRecord[key] = updatedFields[key];
	}

	return newRecord;
}


// APPEND

var _Utils_append = F2(_Utils_ap);

function _Utils_ap(xs, ys)
{
	// append Strings
	if (typeof xs === 'string')
	{
		return xs + ys;
	}

	// append Lists
	if (!xs.b)
	{
		return ys;
	}
	var root = _List_Cons(xs.a, ys);
	xs = xs.b
	for (var curr = root; xs.b; xs = xs.b) // WHILE_CONS
	{
		curr = curr.b = _List_Cons(xs.a, ys);
	}
	return root;
}



var _List_Nil_UNUSED = { $: 0 };
var _List_Nil = { $: '[]' };

function _List_Cons_UNUSED(hd, tl) { return { $: 1, a: hd, b: tl }; }
function _List_Cons(hd, tl) { return { $: '::', a: hd, b: tl }; }


var _List_cons = F2(_List_Cons);

function _List_fromArray(arr)
{
	var out = _List_Nil;
	for (var i = arr.length; i--; )
	{
		out = _List_Cons(arr[i], out);
	}
	return out;
}

function _List_toArray(xs)
{
	for (var out = []; xs.b; xs = xs.b) // WHILE_CONS
	{
		out.push(xs.a);
	}
	return out;
}

var _List_map2 = F3(function(f, xs, ys)
{
	for (var arr = []; xs.b && ys.b; xs = xs.b, ys = ys.b) // WHILE_CONSES
	{
		arr.push(A2(f, xs.a, ys.a));
	}
	return _List_fromArray(arr);
});

var _List_map3 = F4(function(f, xs, ys, zs)
{
	for (var arr = []; xs.b && ys.b && zs.b; xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
	{
		arr.push(A3(f, xs.a, ys.a, zs.a));
	}
	return _List_fromArray(arr);
});

var _List_map4 = F5(function(f, ws, xs, ys, zs)
{
	for (var arr = []; ws.b && xs.b && ys.b && zs.b; ws = ws.b, xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
	{
		arr.push(A4(f, ws.a, xs.a, ys.a, zs.a));
	}
	return _List_fromArray(arr);
});

var _List_map5 = F6(function(f, vs, ws, xs, ys, zs)
{
	for (var arr = []; vs.b && ws.b && xs.b && ys.b && zs.b; vs = vs.b, ws = ws.b, xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
	{
		arr.push(A5(f, vs.a, ws.a, xs.a, ys.a, zs.a));
	}
	return _List_fromArray(arr);
});

var _List_sortBy = F2(function(f, xs)
{
	return _List_fromArray(_List_toArray(xs).sort(function(a, b) {
		return _Utils_cmp(f(a), f(b));
	}));
});

var _List_sortWith = F2(function(f, xs)
{
	return _List_fromArray(_List_toArray(xs).sort(function(a, b) {
		var ord = A2(f, a, b);
		return ord === $elm$core$Basics$EQ ? 0 : ord === $elm$core$Basics$LT ? -1 : 1;
	}));
});



// MATH

var _Basics_add = F2(function(a, b) { return a + b; });
var _Basics_sub = F2(function(a, b) { return a - b; });
var _Basics_mul = F2(function(a, b) { return a * b; });
var _Basics_fdiv = F2(function(a, b) { return a / b; });
var _Basics_idiv = F2(function(a, b) { return (a / b) | 0; });
var _Basics_pow = F2(Math.pow);

var _Basics_remainderBy = F2(function(b, a) { return a % b; });

// https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/divmodnote-letter.pdf
var _Basics_modBy = F2(function(modulus, x)
{
	var answer = x % modulus;
	return modulus === 0
		? _Debug_crash(11)
		:
	((answer > 0 && modulus < 0) || (answer < 0 && modulus > 0))
		? answer + modulus
		: answer;
});


// TRIGONOMETRY

var _Basics_pi = Math.PI;
var _Basics_e = Math.E;
var _Basics_cos = Math.cos;
var _Basics_sin = Math.sin;
var _Basics_tan = Math.tan;
var _Basics_acos = Math.acos;
var _Basics_asin = Math.asin;
var _Basics_atan = Math.atan;
var _Basics_atan2 = F2(Math.atan2);


// MORE MATH

function _Basics_toFloat(x) { return x; }
function _Basics_truncate(n) { return n | 0; }
function _Basics_isInfinite(n) { return n === Infinity || n === -Infinity; }

var _Basics_ceiling = Math.ceil;
var _Basics_floor = Math.floor;
var _Basics_round = Math.round;
var _Basics_sqrt = Math.sqrt;
var _Basics_log = Math.log;
var _Basics_isNaN = isNaN;


// BOOLEANS

function _Basics_not(bool) { return !bool; }
var _Basics_and = F2(function(a, b) { return a && b; });
var _Basics_or  = F2(function(a, b) { return a || b; });
var _Basics_xor = F2(function(a, b) { return a !== b; });



var _String_cons = F2(function(chr, str)
{
	return chr + str;
});

function _String_uncons(string)
{
	var word = string.charCodeAt(0);
	return !isNaN(word)
		? $elm$core$Maybe$Just(
			0xD800 <= word && word <= 0xDBFF
				? _Utils_Tuple2(_Utils_chr(string[0] + string[1]), string.slice(2))
				: _Utils_Tuple2(_Utils_chr(string[0]), string.slice(1))
		)
		: $elm$core$Maybe$Nothing;
}

var _String_append = F2(function(a, b)
{
	return a + b;
});

function _String_length(str)
{
	return str.length;
}

var _String_map = F2(function(func, string)
{
	var len = string.length;
	var array = new Array(len);
	var i = 0;
	while (i < len)
	{
		var word = string.charCodeAt(i);
		if (0xD800 <= word && word <= 0xDBFF)
		{
			array[i] = func(_Utils_chr(string[i] + string[i+1]));
			i += 2;
			continue;
		}
		array[i] = func(_Utils_chr(string[i]));
		i++;
	}
	return array.join('');
});

var _String_filter = F2(function(isGood, str)
{
	var arr = [];
	var len = str.length;
	var i = 0;
	while (i < len)
	{
		var char = str[i];
		var word = str.charCodeAt(i);
		i++;
		if (0xD800 <= word && word <= 0xDBFF)
		{
			char += str[i];
			i++;
		}

		if (isGood(_Utils_chr(char)))
		{
			arr.push(char);
		}
	}
	return arr.join('');
});

function _String_reverse(str)
{
	var len = str.length;
	var arr = new Array(len);
	var i = 0;
	while (i < len)
	{
		var word = str.charCodeAt(i);
		if (0xD800 <= word && word <= 0xDBFF)
		{
			arr[len - i] = str[i + 1];
			i++;
			arr[len - i] = str[i - 1];
			i++;
		}
		else
		{
			arr[len - i] = str[i];
			i++;
		}
	}
	return arr.join('');
}

var _String_foldl = F3(function(func, state, string)
{
	var len = string.length;
	var i = 0;
	while (i < len)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		i++;
		if (0xD800 <= word && word <= 0xDBFF)
		{
			char += string[i];
			i++;
		}
		state = A2(func, _Utils_chr(char), state);
	}
	return state;
});

var _String_foldr = F3(function(func, state, string)
{
	var i = string.length;
	while (i--)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		if (0xDC00 <= word && word <= 0xDFFF)
		{
			i--;
			char = string[i] + char;
		}
		state = A2(func, _Utils_chr(char), state);
	}
	return state;
});

var _String_split = F2(function(sep, str)
{
	return str.split(sep);
});

var _String_join = F2(function(sep, strs)
{
	return strs.join(sep);
});

var _String_slice = F3(function(start, end, str) {
	return str.slice(start, end);
});

function _String_trim(str)
{
	return str.trim();
}

function _String_trimLeft(str)
{
	return str.replace(/^\s+/, '');
}

function _String_trimRight(str)
{
	return str.replace(/\s+$/, '');
}

function _String_words(str)
{
	return _List_fromArray(str.trim().split(/\s+/g));
}

function _String_lines(str)
{
	return _List_fromArray(str.split(/\r\n|\r|\n/g));
}

function _String_toUpper(str)
{
	return str.toUpperCase();
}

function _String_toLower(str)
{
	return str.toLowerCase();
}

var _String_any = F2(function(isGood, string)
{
	var i = string.length;
	while (i--)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		if (0xDC00 <= word && word <= 0xDFFF)
		{
			i--;
			char = string[i] + char;
		}
		if (isGood(_Utils_chr(char)))
		{
			return true;
		}
	}
	return false;
});

var _String_all = F2(function(isGood, string)
{
	var i = string.length;
	while (i--)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		if (0xDC00 <= word && word <= 0xDFFF)
		{
			i--;
			char = string[i] + char;
		}
		if (!isGood(_Utils_chr(char)))
		{
			return false;
		}
	}
	return true;
});

var _String_contains = F2(function(sub, str)
{
	return str.indexOf(sub) > -1;
});

var _String_startsWith = F2(function(sub, str)
{
	return str.indexOf(sub) === 0;
});

var _String_endsWith = F2(function(sub, str)
{
	return str.length >= sub.length &&
		str.lastIndexOf(sub) === str.length - sub.length;
});

var _String_indexes = F2(function(sub, str)
{
	var subLen = sub.length;

	if (subLen < 1)
	{
		return _List_Nil;
	}

	var i = 0;
	var is = [];

	while ((i = str.indexOf(sub, i)) > -1)
	{
		is.push(i);
		i = i + subLen;
	}

	return _List_fromArray(is);
});


// TO STRING

function _String_fromNumber(number)
{
	return number + '';
}


// INT CONVERSIONS

function _String_toInt(str)
{
	var total = 0;
	var code0 = str.charCodeAt(0);
	var start = code0 == 0x2B /* + */ || code0 == 0x2D /* - */ ? 1 : 0;

	for (var i = start; i < str.length; ++i)
	{
		var code = str.charCodeAt(i);
		if (code < 0x30 || 0x39 < code)
		{
			return $elm$core$Maybe$Nothing;
		}
		total = 10 * total + code - 0x30;
	}

	return i == start
		? $elm$core$Maybe$Nothing
		: $elm$core$Maybe$Just(code0 == 0x2D ? -total : total);
}


// FLOAT CONVERSIONS

function _String_toFloat(s)
{
	// check if it is a hex, octal, or binary number
	if (s.length === 0 || /[\sxbo]/.test(s))
	{
		return $elm$core$Maybe$Nothing;
	}
	var n = +s;
	// faster isNaN check
	return n === n ? $elm$core$Maybe$Just(n) : $elm$core$Maybe$Nothing;
}

function _String_fromList(chars)
{
	return _List_toArray(chars).join('');
}




function _Char_toCode(char)
{
	var code = char.charCodeAt(0);
	if (0xD800 <= code && code <= 0xDBFF)
	{
		return (code - 0xD800) * 0x400 + char.charCodeAt(1) - 0xDC00 + 0x10000
	}
	return code;
}

function _Char_fromCode(code)
{
	return _Utils_chr(
		(code < 0 || 0x10FFFF < code)
			? '\uFFFD'
			:
		(code <= 0xFFFF)
			? String.fromCharCode(code)
			:
		(code -= 0x10000,
			String.fromCharCode(Math.floor(code / 0x400) + 0xD800, code % 0x400 + 0xDC00)
		)
	);
}

function _Char_toUpper(char)
{
	return _Utils_chr(char.toUpperCase());
}

function _Char_toLower(char)
{
	return _Utils_chr(char.toLowerCase());
}

function _Char_toLocaleUpper(char)
{
	return _Utils_chr(char.toLocaleUpperCase());
}

function _Char_toLocaleLower(char)
{
	return _Utils_chr(char.toLocaleLowerCase());
}



/**/
function _Json_errorToString(error)
{
	return $elm$json$Json$Decode$errorToString(error);
}
//*/


// CORE DECODERS

function _Json_succeed(msg)
{
	return {
		$: 0,
		a: msg
	};
}

function _Json_fail(msg)
{
	return {
		$: 1,
		a: msg
	};
}

function _Json_decodePrim(decoder)
{
	return { $: 2, b: decoder };
}

var _Json_decodeInt = _Json_decodePrim(function(value) {
	return (typeof value !== 'number')
		? _Json_expecting('an INT', value)
		:
	(-2147483647 < value && value < 2147483647 && (value | 0) === value)
		? $elm$core$Result$Ok(value)
		:
	(isFinite(value) && !(value % 1))
		? $elm$core$Result$Ok(value)
		: _Json_expecting('an INT', value);
});

var _Json_decodeBool = _Json_decodePrim(function(value) {
	return (typeof value === 'boolean')
		? $elm$core$Result$Ok(value)
		: _Json_expecting('a BOOL', value);
});

var _Json_decodeFloat = _Json_decodePrim(function(value) {
	return (typeof value === 'number')
		? $elm$core$Result$Ok(value)
		: _Json_expecting('a FLOAT', value);
});

var _Json_decodeValue = _Json_decodePrim(function(value) {
	return $elm$core$Result$Ok(_Json_wrap(value));
});

var _Json_decodeString = _Json_decodePrim(function(value) {
	return (typeof value === 'string')
		? $elm$core$Result$Ok(value)
		: (value instanceof String)
			? $elm$core$Result$Ok(value + '')
			: _Json_expecting('a STRING', value);
});

function _Json_decodeList(decoder) { return { $: 3, b: decoder }; }
function _Json_decodeArray(decoder) { return { $: 4, b: decoder }; }

function _Json_decodeNull(value) { return { $: 5, c: value }; }

var _Json_decodeField = F2(function(field, decoder)
{
	return {
		$: 6,
		d: field,
		b: decoder
	};
});

var _Json_decodeIndex = F2(function(index, decoder)
{
	return {
		$: 7,
		e: index,
		b: decoder
	};
});

function _Json_decodeKeyValuePairs(decoder)
{
	return {
		$: 8,
		b: decoder
	};
}

function _Json_mapMany(f, decoders)
{
	return {
		$: 9,
		f: f,
		g: decoders
	};
}

var _Json_andThen = F2(function(callback, decoder)
{
	return {
		$: 10,
		b: decoder,
		h: callback
	};
});

function _Json_oneOf(decoders)
{
	return {
		$: 11,
		g: decoders
	};
}


// DECODING OBJECTS

var _Json_map1 = F2(function(f, d1)
{
	return _Json_mapMany(f, [d1]);
});

var _Json_map2 = F3(function(f, d1, d2)
{
	return _Json_mapMany(f, [d1, d2]);
});

var _Json_map3 = F4(function(f, d1, d2, d3)
{
	return _Json_mapMany(f, [d1, d2, d3]);
});

var _Json_map4 = F5(function(f, d1, d2, d3, d4)
{
	return _Json_mapMany(f, [d1, d2, d3, d4]);
});

var _Json_map5 = F6(function(f, d1, d2, d3, d4, d5)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5]);
});

var _Json_map6 = F7(function(f, d1, d2, d3, d4, d5, d6)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5, d6]);
});

var _Json_map7 = F8(function(f, d1, d2, d3, d4, d5, d6, d7)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5, d6, d7]);
});

var _Json_map8 = F9(function(f, d1, d2, d3, d4, d5, d6, d7, d8)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5, d6, d7, d8]);
});


// DECODE

var _Json_runOnString = F2(function(decoder, string)
{
	try
	{
		var value = JSON.parse(string);
		return _Json_runHelp(decoder, value);
	}
	catch (e)
	{
		return $elm$core$Result$Err(A2($elm$json$Json$Decode$Failure, 'This is not valid JSON! ' + e.message, _Json_wrap(string)));
	}
});

var _Json_run = F2(function(decoder, value)
{
	return _Json_runHelp(decoder, _Json_unwrap(value));
});

function _Json_runHelp(decoder, value)
{
	switch (decoder.$)
	{
		case 2:
			return decoder.b(value);

		case 5:
			return (value === null)
				? $elm$core$Result$Ok(decoder.c)
				: _Json_expecting('null', value);

		case 3:
			if (!_Json_isArray(value))
			{
				return _Json_expecting('a LIST', value);
			}
			return _Json_runArrayDecoder(decoder.b, value, _List_fromArray);

		case 4:
			if (!_Json_isArray(value))
			{
				return _Json_expecting('an ARRAY', value);
			}
			return _Json_runArrayDecoder(decoder.b, value, _Json_toElmArray);

		case 6:
			var field = decoder.d;
			if (typeof value !== 'object' || value === null || !(field in value))
			{
				return _Json_expecting('an OBJECT with a field named `' + field + '`', value);
			}
			var result = _Json_runHelp(decoder.b, value[field]);
			return ($elm$core$Result$isOk(result)) ? result : $elm$core$Result$Err(A2($elm$json$Json$Decode$Field, field, result.a));

		case 7:
			var index = decoder.e;
			if (!_Json_isArray(value))
			{
				return _Json_expecting('an ARRAY', value);
			}
			if (index >= value.length)
			{
				return _Json_expecting('a LONGER array. Need index ' + index + ' but only see ' + value.length + ' entries', value);
			}
			var result = _Json_runHelp(decoder.b, value[index]);
			return ($elm$core$Result$isOk(result)) ? result : $elm$core$Result$Err(A2($elm$json$Json$Decode$Index, index, result.a));

		case 8:
			if (typeof value !== 'object' || value === null || _Json_isArray(value))
			{
				return _Json_expecting('an OBJECT', value);
			}

			var keyValuePairs = _List_Nil;
			// TODO test perf of Object.keys and switch when support is good enough
			for (var key in value)
			{
				if (value.hasOwnProperty(key))
				{
					var result = _Json_runHelp(decoder.b, value[key]);
					if (!$elm$core$Result$isOk(result))
					{
						return $elm$core$Result$Err(A2($elm$json$Json$Decode$Field, key, result.a));
					}
					keyValuePairs = _List_Cons(_Utils_Tuple2(key, result.a), keyValuePairs);
				}
			}
			return $elm$core$Result$Ok($elm$core$List$reverse(keyValuePairs));

		case 9:
			var answer = decoder.f;
			var decoders = decoder.g;
			for (var i = 0; i < decoders.length; i++)
			{
				var result = _Json_runHelp(decoders[i], value);
				if (!$elm$core$Result$isOk(result))
				{
					return result;
				}
				answer = answer(result.a);
			}
			return $elm$core$Result$Ok(answer);

		case 10:
			var result = _Json_runHelp(decoder.b, value);
			return (!$elm$core$Result$isOk(result))
				? result
				: _Json_runHelp(decoder.h(result.a), value);

		case 11:
			var errors = _List_Nil;
			for (var temp = decoder.g; temp.b; temp = temp.b) // WHILE_CONS
			{
				var result = _Json_runHelp(temp.a, value);
				if ($elm$core$Result$isOk(result))
				{
					return result;
				}
				errors = _List_Cons(result.a, errors);
			}
			return $elm$core$Result$Err($elm$json$Json$Decode$OneOf($elm$core$List$reverse(errors)));

		case 1:
			return $elm$core$Result$Err(A2($elm$json$Json$Decode$Failure, decoder.a, _Json_wrap(value)));

		case 0:
			return $elm$core$Result$Ok(decoder.a);
	}
}

function _Json_runArrayDecoder(decoder, value, toElmValue)
{
	var len = value.length;
	var array = new Array(len);
	for (var i = 0; i < len; i++)
	{
		var result = _Json_runHelp(decoder, value[i]);
		if (!$elm$core$Result$isOk(result))
		{
			return $elm$core$Result$Err(A2($elm$json$Json$Decode$Index, i, result.a));
		}
		array[i] = result.a;
	}
	return $elm$core$Result$Ok(toElmValue(array));
}

function _Json_isArray(value)
{
	return Array.isArray(value) || (typeof FileList !== 'undefined' && value instanceof FileList);
}

function _Json_toElmArray(array)
{
	return A2($elm$core$Array$initialize, array.length, function(i) { return array[i]; });
}

function _Json_expecting(type, value)
{
	return $elm$core$Result$Err(A2($elm$json$Json$Decode$Failure, 'Expecting ' + type, _Json_wrap(value)));
}


// EQUALITY

function _Json_equality(x, y)
{
	if (x === y)
	{
		return true;
	}

	if (x.$ !== y.$)
	{
		return false;
	}

	switch (x.$)
	{
		case 0:
		case 1:
			return x.a === y.a;

		case 2:
			return x.b === y.b;

		case 5:
			return x.c === y.c;

		case 3:
		case 4:
		case 8:
			return _Json_equality(x.b, y.b);

		case 6:
			return x.d === y.d && _Json_equality(x.b, y.b);

		case 7:
			return x.e === y.e && _Json_equality(x.b, y.b);

		case 9:
			return x.f === y.f && _Json_listEquality(x.g, y.g);

		case 10:
			return x.h === y.h && _Json_equality(x.b, y.b);

		case 11:
			return _Json_listEquality(x.g, y.g);
	}
}

function _Json_listEquality(aDecoders, bDecoders)
{
	var len = aDecoders.length;
	if (len !== bDecoders.length)
	{
		return false;
	}
	for (var i = 0; i < len; i++)
	{
		if (!_Json_equality(aDecoders[i], bDecoders[i]))
		{
			return false;
		}
	}
	return true;
}


// ENCODE

var _Json_encode = F2(function(indentLevel, value)
{
	return JSON.stringify(_Json_unwrap(value), null, indentLevel) + '';
});

function _Json_wrap(value) { return { $: 0, a: value }; }
function _Json_unwrap(value) { return value.a; }

function _Json_wrap_UNUSED(value) { return value; }
function _Json_unwrap_UNUSED(value) { return value; }

function _Json_emptyArray() { return []; }
function _Json_emptyObject() { return {}; }

var _Json_addField = F3(function(key, value, object)
{
	object[key] = _Json_unwrap(value);
	return object;
});

function _Json_addEntry(func)
{
	return F2(function(entry, array)
	{
		array.push(_Json_unwrap(func(entry)));
		return array;
	});
}

var _Json_encodeNull = _Json_wrap(null);



// TASKS

function _Scheduler_succeed(value)
{
	return {
		$: 0,
		a: value
	};
}

function _Scheduler_fail(error)
{
	return {
		$: 1,
		a: error
	};
}

function _Scheduler_binding(callback)
{
	return {
		$: 2,
		b: callback,
		c: null
	};
}

var _Scheduler_andThen = F2(function(callback, task)
{
	return {
		$: 3,
		b: callback,
		d: task
	};
});

var _Scheduler_onError = F2(function(callback, task)
{
	return {
		$: 4,
		b: callback,
		d: task
	};
});

function _Scheduler_receive(callback)
{
	return {
		$: 5,
		b: callback
	};
}


// PROCESSES

var _Scheduler_guid = 0;

function _Scheduler_rawSpawn(task)
{
	var proc = {
		$: 0,
		e: _Scheduler_guid++,
		f: task,
		g: null,
		h: []
	};

	_Scheduler_enqueue(proc);

	return proc;
}

function _Scheduler_spawn(task)
{
	return _Scheduler_binding(function(callback) {
		callback(_Scheduler_succeed(_Scheduler_rawSpawn(task)));
	});
}

function _Scheduler_rawSend(proc, msg)
{
	proc.h.push(msg);
	_Scheduler_enqueue(proc);
}

var _Scheduler_send = F2(function(proc, msg)
{
	return _Scheduler_binding(function(callback) {
		_Scheduler_rawSend(proc, msg);
		callback(_Scheduler_succeed(_Utils_Tuple0));
	});
});

function _Scheduler_kill(proc)
{
	return _Scheduler_binding(function(callback) {
		var task = proc.f;
		if (task.$ === 2 && task.c)
		{
			task.c();
		}

		proc.f = null;

		callback(_Scheduler_succeed(_Utils_Tuple0));
	});
}


/* STEP PROCESSES

type alias Process =
  { $ : tag
  , id : unique_id
  , root : Task
  , stack : null | { $: SUCCEED | FAIL, a: callback, b: stack }
  , mailbox : [msg]
  }

*/


var _Scheduler_working = false;
var _Scheduler_queue = [];


function _Scheduler_enqueue(proc)
{
	_Scheduler_queue.push(proc);
	if (_Scheduler_working)
	{
		return;
	}
	_Scheduler_working = true;
	while (proc = _Scheduler_queue.shift())
	{
		_Scheduler_step(proc);
	}
	_Scheduler_working = false;
}


function _Scheduler_step(proc)
{
	while (proc.f)
	{
		var rootTag = proc.f.$;
		if (rootTag === 0 || rootTag === 1)
		{
			while (proc.g && proc.g.$ !== rootTag)
			{
				proc.g = proc.g.i;
			}
			if (!proc.g)
			{
				return;
			}
			proc.f = proc.g.b(proc.f.a);
			proc.g = proc.g.i;
		}
		else if (rootTag === 2)
		{
			proc.f.c = proc.f.b(function(newRoot) {
				proc.f = newRoot;
				_Scheduler_enqueue(proc);
			});
			return;
		}
		else if (rootTag === 5)
		{
			if (proc.h.length === 0)
			{
				return;
			}
			proc.f = proc.f.b(proc.h.shift());
		}
		else // if (rootTag === 3 || rootTag === 4)
		{
			proc.g = {
				$: rootTag === 3 ? 0 : 1,
				b: proc.f.b,
				i: proc.g
			};
			proc.f = proc.f.d;
		}
	}
}



function _Process_sleep(time)
{
	return _Scheduler_binding(function(callback) {
		var id = setTimeout(function() {
			callback(_Scheduler_succeed(_Utils_Tuple0));
		}, time);

		return function() { clearTimeout(id); };
	});
}




// PROGRAMS


var _Platform_worker = F4(function(impl, flagDecoder, debugMetadata, args)
{
	return _Platform_initialize(
		flagDecoder,
		args,
		impl.init,
		impl.update,
		impl.subscriptions,
		function() { return function() {} }
	);
});



// INITIALIZE A PROGRAM


function _Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder)
{
	var result = A2(_Json_run, flagDecoder, _Json_wrap(args ? args['flags'] : undefined));
	$elm$core$Result$isOk(result) || _Debug_crash(2 /**/, _Json_errorToString(result.a) /**/);
	var managers = {};
	var initPair = init(result.a);
	var model = initPair.a;
	var stepper = stepperBuilder(sendToApp, model);
	var ports = _Platform_setupEffects(managers, sendToApp);

	function sendToApp(msg, viewMetadata)
	{
		var pair = A2(update, msg, model);
		stepper(model = pair.a, viewMetadata);
		_Platform_enqueueEffects(managers, pair.b, subscriptions(model));
	}

	_Platform_enqueueEffects(managers, initPair.b, subscriptions(model));

	return ports ? { ports: ports } : {};
}



// TRACK PRELOADS
//
// This is used by code in elm/browser and elm/http
// to register any HTTP requests that are triggered by init.
//


var _Platform_preload;


function _Platform_registerPreload(url)
{
	_Platform_preload.add(url);
}



// EFFECT MANAGERS


var _Platform_effectManagers = {};


function _Platform_setupEffects(managers, sendToApp)
{
	var ports;

	// setup all necessary effect managers
	for (var key in _Platform_effectManagers)
	{
		var manager = _Platform_effectManagers[key];

		if (manager.a)
		{
			ports = ports || {};
			ports[key] = manager.a(key, sendToApp);
		}

		managers[key] = _Platform_instantiateManager(manager, sendToApp);
	}

	return ports;
}


function _Platform_createManager(init, onEffects, onSelfMsg, cmdMap, subMap)
{
	return {
		b: init,
		c: onEffects,
		d: onSelfMsg,
		e: cmdMap,
		f: subMap
	};
}


function _Platform_instantiateManager(info, sendToApp)
{
	var router = {
		g: sendToApp,
		h: undefined
	};

	var onEffects = info.c;
	var onSelfMsg = info.d;
	var cmdMap = info.e;
	var subMap = info.f;

	function loop(state)
	{
		return A2(_Scheduler_andThen, loop, _Scheduler_receive(function(msg)
		{
			var value = msg.a;

			if (msg.$ === 0)
			{
				return A3(onSelfMsg, router, value, state);
			}

			return cmdMap && subMap
				? A4(onEffects, router, value.i, value.j, state)
				: A3(onEffects, router, cmdMap ? value.i : value.j, state);
		}));
	}

	return router.h = _Scheduler_rawSpawn(A2(_Scheduler_andThen, loop, info.b));
}



// ROUTING


var _Platform_sendToApp = F2(function(router, msg)
{
	return _Scheduler_binding(function(callback)
	{
		router.g(msg);
		callback(_Scheduler_succeed(_Utils_Tuple0));
	});
});


var _Platform_sendToSelf = F2(function(router, msg)
{
	return A2(_Scheduler_send, router.h, {
		$: 0,
		a: msg
	});
});



// BAGS


function _Platform_leaf(home)
{
	return function(value)
	{
		return {
			$: 1,
			k: home,
			l: value
		};
	};
}


function _Platform_batch(list)
{
	return {
		$: 2,
		m: list
	};
}


var _Platform_map = F2(function(tagger, bag)
{
	return {
		$: 3,
		n: tagger,
		o: bag
	}
});



// PIPE BAGS INTO EFFECT MANAGERS
//
// Effects must be queued!
//
// Say your init contains a synchronous command, like Time.now or Time.here
//
//   - This will produce a batch of effects (FX_1)
//   - The synchronous task triggers the subsequent `update` call
//   - This will produce a batch of effects (FX_2)
//
// If we just start dispatching FX_2, subscriptions from FX_2 can be processed
// before subscriptions from FX_1. No good! Earlier versions of this code had
// this problem, leading to these reports:
//
//   https://github.com/elm/core/issues/980
//   https://github.com/elm/core/pull/981
//   https://github.com/elm/compiler/issues/1776
//
// The queue is necessary to avoid ordering issues for synchronous commands.


// Why use true/false here? Why not just check the length of the queue?
// The goal is to detect "are we currently dispatching effects?" If we
// are, we need to bail and let the ongoing while loop handle things.
//
// Now say the queue has 1 element. When we dequeue the final element,
// the queue will be empty, but we are still actively dispatching effects.
// So you could get queue jumping in a really tricky category of cases.
//
var _Platform_effectsQueue = [];
var _Platform_effectsActive = false;


function _Platform_enqueueEffects(managers, cmdBag, subBag)
{
	_Platform_effectsQueue.push({ p: managers, q: cmdBag, r: subBag });

	if (_Platform_effectsActive) return;

	_Platform_effectsActive = true;
	for (var fx; fx = _Platform_effectsQueue.shift(); )
	{
		_Platform_dispatchEffects(fx.p, fx.q, fx.r);
	}
	_Platform_effectsActive = false;
}


function _Platform_dispatchEffects(managers, cmdBag, subBag)
{
	var effectsDict = {};
	_Platform_gatherEffects(true, cmdBag, effectsDict, null);
	_Platform_gatherEffects(false, subBag, effectsDict, null);

	for (var home in managers)
	{
		_Scheduler_rawSend(managers[home], {
			$: 'fx',
			a: effectsDict[home] || { i: _List_Nil, j: _List_Nil }
		});
	}
}


function _Platform_gatherEffects(isCmd, bag, effectsDict, taggers)
{
	switch (bag.$)
	{
		case 1:
			var home = bag.k;
			var effect = _Platform_toEffect(isCmd, home, taggers, bag.l);
			effectsDict[home] = _Platform_insert(isCmd, effect, effectsDict[home]);
			return;

		case 2:
			for (var list = bag.m; list.b; list = list.b) // WHILE_CONS
			{
				_Platform_gatherEffects(isCmd, list.a, effectsDict, taggers);
			}
			return;

		case 3:
			_Platform_gatherEffects(isCmd, bag.o, effectsDict, {
				s: bag.n,
				t: taggers
			});
			return;
	}
}


function _Platform_toEffect(isCmd, home, taggers, value)
{
	function applyTaggers(x)
	{
		for (var temp = taggers; temp; temp = temp.t)
		{
			x = temp.s(x);
		}
		return x;
	}

	var map = isCmd
		? _Platform_effectManagers[home].e
		: _Platform_effectManagers[home].f;

	return A2(map, applyTaggers, value)
}


function _Platform_insert(isCmd, newEffect, effects)
{
	effects = effects || { i: _List_Nil, j: _List_Nil };

	isCmd
		? (effects.i = _List_Cons(newEffect, effects.i))
		: (effects.j = _List_Cons(newEffect, effects.j));

	return effects;
}



// PORTS


function _Platform_checkPortName(name)
{
	if (_Platform_effectManagers[name])
	{
		_Debug_crash(3, name)
	}
}



// OUTGOING PORTS


function _Platform_outgoingPort(name, converter)
{
	_Platform_checkPortName(name);
	_Platform_effectManagers[name] = {
		e: _Platform_outgoingPortMap,
		u: converter,
		a: _Platform_setupOutgoingPort
	};
	return _Platform_leaf(name);
}


var _Platform_outgoingPortMap = F2(function(tagger, value) { return value; });


function _Platform_setupOutgoingPort(name)
{
	var subs = [];
	var converter = _Platform_effectManagers[name].u;

	// CREATE MANAGER

	var init = _Process_sleep(0);

	_Platform_effectManagers[name].b = init;
	_Platform_effectManagers[name].c = F3(function(router, cmdList, state)
	{
		for ( ; cmdList.b; cmdList = cmdList.b) // WHILE_CONS
		{
			// grab a separate reference to subs in case unsubscribe is called
			var currentSubs = subs;
			var value = _Json_unwrap(converter(cmdList.a));
			for (var i = 0; i < currentSubs.length; i++)
			{
				currentSubs[i](value);
			}
		}
		return init;
	});

	// PUBLIC API

	function subscribe(callback)
	{
		subs.push(callback);
	}

	function unsubscribe(callback)
	{
		// copy subs into a new array in case unsubscribe is called within a
		// subscribed callback
		subs = subs.slice();
		var index = subs.indexOf(callback);
		if (index >= 0)
		{
			subs.splice(index, 1);
		}
	}

	return {
		subscribe: subscribe,
		unsubscribe: unsubscribe
	};
}



// INCOMING PORTS


function _Platform_incomingPort(name, converter)
{
	_Platform_checkPortName(name);
	_Platform_effectManagers[name] = {
		f: _Platform_incomingPortMap,
		u: converter,
		a: _Platform_setupIncomingPort
	};
	return _Platform_leaf(name);
}


var _Platform_incomingPortMap = F2(function(tagger, finalTagger)
{
	return function(value)
	{
		return tagger(finalTagger(value));
	};
});


function _Platform_setupIncomingPort(name, sendToApp)
{
	var subs = _List_Nil;
	var converter = _Platform_effectManagers[name].u;

	// CREATE MANAGER

	var init = _Scheduler_succeed(null);

	_Platform_effectManagers[name].b = init;
	_Platform_effectManagers[name].c = F3(function(router, subList, state)
	{
		subs = subList;
		return init;
	});

	// PUBLIC API

	function send(incomingValue)
	{
		var result = A2(_Json_run, converter, _Json_wrap(incomingValue));

		$elm$core$Result$isOk(result) || _Debug_crash(4, name, result.a);

		var value = result.a;
		for (var temp = subs; temp.b; temp = temp.b) // WHILE_CONS
		{
			sendToApp(temp.a(value));
		}
	}

	return { send: send };
}



// EXPORT ELM MODULES
//
// Have DEBUG and PROD versions so that we can (1) give nicer errors in
// debug mode and (2) not pay for the bits needed for that in prod mode.
//


function _Platform_export_UNUSED(exports)
{
	scope['Elm']
		? _Platform_mergeExportsProd(scope['Elm'], exports)
		: scope['Elm'] = exports;
}


function _Platform_mergeExportsProd(obj, exports)
{
	for (var name in exports)
	{
		(name in obj)
			? (name == 'init')
				? _Debug_crash(6)
				: _Platform_mergeExportsProd(obj[name], exports[name])
			: (obj[name] = exports[name]);
	}
}


function _Platform_export(exports)
{
	scope['Elm']
		? _Platform_mergeExportsDebug('Elm', scope['Elm'], exports)
		: scope['Elm'] = exports;
}


function _Platform_mergeExportsDebug(moduleName, obj, exports)
{
	for (var name in exports)
	{
		(name in obj)
			? (name == 'init')
				? _Debug_crash(6, moduleName)
				: _Platform_mergeExportsDebug(moduleName + '.' + name, obj[name], exports[name])
			: (obj[name] = exports[name]);
	}
}



var _Bitwise_and = F2(function(a, b)
{
	return a & b;
});

var _Bitwise_or = F2(function(a, b)
{
	return a | b;
});

var _Bitwise_xor = F2(function(a, b)
{
	return a ^ b;
});

function _Bitwise_complement(a)
{
	return ~a;
};

var _Bitwise_shiftLeftBy = F2(function(offset, a)
{
	return a << offset;
});

var _Bitwise_shiftRightBy = F2(function(offset, a)
{
	return a >> offset;
});

var _Bitwise_shiftRightZfBy = F2(function(offset, a)
{
	return a >>> offset;
});



function _Time_now(millisToPosix)
{
	return _Scheduler_binding(function(callback)
	{
		callback(_Scheduler_succeed(millisToPosix(Date.now())));
	});
}

var _Time_setInterval = F2(function(interval, task)
{
	return _Scheduler_binding(function(callback)
	{
		var id = setInterval(function() { _Scheduler_rawSpawn(task); }, interval);
		return function() { clearInterval(id); };
	});
});

function _Time_here()
{
	return _Scheduler_binding(function(callback)
	{
		callback(_Scheduler_succeed(
			A2($elm$time$Time$customZone, -(new Date().getTimezoneOffset()), _List_Nil)
		));
	});
}


function _Time_getZoneName()
{
	return _Scheduler_binding(function(callback)
	{
		try
		{
			var name = $elm$time$Time$Name(Intl.DateTimeFormat().resolvedOptions().timeZone);
		}
		catch (e)
		{
			var name = $elm$time$Time$Offset(new Date().getTimezoneOffset());
		}
		callback(_Scheduler_succeed(name));
	});
}


function _Url_percentEncode(string)
{
	return encodeURIComponent(string);
}

function _Url_percentDecode(string)
{
	try
	{
		return $elm$core$Maybe$Just(decodeURIComponent(string));
	}
	catch (e)
	{
		return $elm$core$Maybe$Nothing;
	}
}

// CREATE

var _Regex_never = /.^/;

var _Regex_fromStringWith = F2(function(options, string)
{
	var flags = 'g';
	if (options.multiline) { flags += 'm'; }
	if (options.caseInsensitive) { flags += 'i'; }

	try
	{
		return $elm$core$Maybe$Just(new RegExp(string, flags));
	}
	catch(error)
	{
		return $elm$core$Maybe$Nothing;
	}
});


// USE

var _Regex_contains = F2(function(re, string)
{
	return string.match(re) !== null;
});


var _Regex_findAtMost = F3(function(n, re, str)
{
	var out = [];
	var number = 0;
	var string = str;
	var lastIndex = re.lastIndex;
	var prevLastIndex = -1;
	var result;
	while (number++ < n && (result = re.exec(string)))
	{
		if (prevLastIndex == re.lastIndex) break;
		var i = result.length - 1;
		var subs = new Array(i);
		while (i > 0)
		{
			var submatch = result[i];
			subs[--i] = submatch
				? $elm$core$Maybe$Just(submatch)
				: $elm$core$Maybe$Nothing;
		}
		out.push(A4($elm$regex$Regex$Match, result[0], result.index, number, _List_fromArray(subs)));
		prevLastIndex = re.lastIndex;
	}
	re.lastIndex = lastIndex;
	return _List_fromArray(out);
});


var _Regex_replaceAtMost = F4(function(n, re, replacer, string)
{
	var count = 0;
	function jsReplacer(match)
	{
		if (count++ >= n)
		{
			return match;
		}
		var i = arguments.length - 3;
		var submatches = new Array(i);
		while (i > 0)
		{
			var submatch = arguments[i];
			submatches[--i] = submatch
				? $elm$core$Maybe$Just(submatch)
				: $elm$core$Maybe$Nothing;
		}
		return replacer(A4($elm$regex$Regex$Match, match, arguments[arguments.length - 2], count, _List_fromArray(submatches)));
	}
	return string.replace(re, jsReplacer);
});

var _Regex_splitAtMost = F3(function(n, re, str)
{
	var string = str;
	var out = [];
	var start = re.lastIndex;
	var restoreLastIndex = re.lastIndex;
	while (n--)
	{
		var result = re.exec(string);
		if (!result) break;
		out.push(string.slice(start, result.index));
		start = re.lastIndex;
	}
	out.push(string.slice(start));
	re.lastIndex = restoreLastIndex;
	return _List_fromArray(out);
});

var _Regex_infinity = Infinity;



// SEND REQUEST

var _Http_toTask = F3(function(router, toTask, request)
{
	return _Scheduler_binding(function(callback)
	{
		function done(response) {
			callback(toTask(request.expect.a(response)));
		}

		var xhr = new XMLHttpRequest();
		xhr.addEventListener('error', function() { done($elm$http$Http$NetworkError_); });
		xhr.addEventListener('timeout', function() { done($elm$http$Http$Timeout_); });
		xhr.addEventListener('load', function() { done(_Http_toResponse(request.expect.b, xhr)); });
		$elm$core$Maybe$isJust(request.tracker) && _Http_track(router, xhr, request.tracker.a);

		try {
			xhr.open(request.method, request.url, true);
		} catch (e) {
			return done($elm$http$Http$BadUrl_(request.url));
		}

		_Http_configureRequest(xhr, request);

		request.body.a && xhr.setRequestHeader('Content-Type', request.body.a);
		xhr.send(request.body.b);

		return function() { xhr.c = true; xhr.abort(); };
	});
});


// CONFIGURE

function _Http_configureRequest(xhr, request)
{
	for (var headers = request.headers; headers.b; headers = headers.b) // WHILE_CONS
	{
		xhr.setRequestHeader(headers.a.a, headers.a.b);
	}
	xhr.timeout = request.timeout.a || 0;
	xhr.responseType = request.expect.d;
	xhr.withCredentials = request.allowCookiesFromOtherDomains;
}


// RESPONSES

function _Http_toResponse(toBody, xhr)
{
	return A2(
		200 <= xhr.status && xhr.status < 300 ? $elm$http$Http$GoodStatus_ : $elm$http$Http$BadStatus_,
		_Http_toMetadata(xhr),
		toBody(xhr.response)
	);
}


// METADATA

function _Http_toMetadata(xhr)
{
	return {
		url: xhr.responseURL,
		statusCode: xhr.status,
		statusText: xhr.statusText,
		headers: _Http_parseHeaders(xhr.getAllResponseHeaders())
	};
}


// HEADERS

function _Http_parseHeaders(rawHeaders)
{
	if (!rawHeaders)
	{
		return $elm$core$Dict$empty;
	}

	var headers = $elm$core$Dict$empty;
	var headerPairs = rawHeaders.split('\r\n');
	for (var i = headerPairs.length; i--; )
	{
		var headerPair = headerPairs[i];
		var index = headerPair.indexOf(': ');
		if (index > 0)
		{
			var key = headerPair.substring(0, index);
			var value = headerPair.substring(index + 2);

			headers = A3($elm$core$Dict$update, key, function(oldValue) {
				return $elm$core$Maybe$Just($elm$core$Maybe$isJust(oldValue)
					? value + ', ' + oldValue.a
					: value
				);
			}, headers);
		}
	}
	return headers;
}


// EXPECT

var _Http_expect = F3(function(type, toBody, toValue)
{
	return {
		$: 0,
		d: type,
		b: toBody,
		a: toValue
	};
});

var _Http_mapExpect = F2(function(func, expect)
{
	return {
		$: 0,
		d: expect.d,
		b: expect.b,
		a: function(x) { return func(expect.a(x)); }
	};
});

function _Http_toDataView(arrayBuffer)
{
	return new DataView(arrayBuffer);
}


// BODY and PARTS

var _Http_emptyBody = { $: 0 };
var _Http_pair = F2(function(a, b) { return { $: 0, a: a, b: b }; });

function _Http_toFormData(parts)
{
	for (var formData = new FormData(); parts.b; parts = parts.b) // WHILE_CONS
	{
		var part = parts.a;
		formData.append(part.a, part.b);
	}
	return formData;
}

var _Http_bytesToBlob = F2(function(mime, bytes)
{
	return new Blob([bytes], { type: mime });
});


// PROGRESS

function _Http_track(router, xhr, tracker)
{
	// TODO check out lengthComputable on loadstart event

	xhr.upload.addEventListener('progress', function(event) {
		if (xhr.c) { return; }
		_Scheduler_rawSpawn(A2($elm$core$Platform$sendToSelf, router, _Utils_Tuple2(tracker, $elm$http$Http$Sending({
			sent: event.loaded,
			size: event.total
		}))));
	});
	xhr.addEventListener('progress', function(event) {
		if (xhr.c) { return; }
		_Scheduler_rawSpawn(A2($elm$core$Platform$sendToSelf, router, _Utils_Tuple2(tracker, $elm$http$Http$Receiving({
			received: event.loaded,
			size: event.lengthComputable ? $elm$core$Maybe$Just(event.total) : $elm$core$Maybe$Nothing
		}))));
	});
}var $elm$core$List$cons = _List_cons;
var $elm$core$Elm$JsArray$foldr = _JsArray_foldr;
var $elm$core$Array$foldr = F3(
	function (func, baseCase, _v0) {
		var tree = _v0.c;
		var tail = _v0.d;
		var helper = F2(
			function (node, acc) {
				if (node.$ === 'SubTree') {
					var subTree = node.a;
					return A3($elm$core$Elm$JsArray$foldr, helper, acc, subTree);
				} else {
					var values = node.a;
					return A3($elm$core$Elm$JsArray$foldr, func, acc, values);
				}
			});
		return A3(
			$elm$core$Elm$JsArray$foldr,
			helper,
			A3($elm$core$Elm$JsArray$foldr, func, baseCase, tail),
			tree);
	});
var $elm$core$Array$toList = function (array) {
	return A3($elm$core$Array$foldr, $elm$core$List$cons, _List_Nil, array);
};
var $elm$core$Dict$foldr = F3(
	function (func, acc, t) {
		foldr:
		while (true) {
			if (t.$ === 'RBEmpty_elm_builtin') {
				return acc;
			} else {
				var key = t.b;
				var value = t.c;
				var left = t.d;
				var right = t.e;
				var $temp$func = func,
					$temp$acc = A3(
					func,
					key,
					value,
					A3($elm$core$Dict$foldr, func, acc, right)),
					$temp$t = left;
				func = $temp$func;
				acc = $temp$acc;
				t = $temp$t;
				continue foldr;
			}
		}
	});
var $elm$core$Dict$toList = function (dict) {
	return A3(
		$elm$core$Dict$foldr,
		F3(
			function (key, value, list) {
				return A2(
					$elm$core$List$cons,
					_Utils_Tuple2(key, value),
					list);
			}),
		_List_Nil,
		dict);
};
var $elm$core$Dict$keys = function (dict) {
	return A3(
		$elm$core$Dict$foldr,
		F3(
			function (key, value, keyList) {
				return A2($elm$core$List$cons, key, keyList);
			}),
		_List_Nil,
		dict);
};
var $elm$core$Set$toList = function (_v0) {
	var dict = _v0.a;
	return $elm$core$Dict$keys(dict);
};
var $elm$core$Basics$EQ = {$: 'EQ'};
var $elm$core$Basics$GT = {$: 'GT'};
var $elm$core$Basics$LT = {$: 'LT'};
var $elm$core$Result$Err = function (a) {
	return {$: 'Err', a: a};
};
var $elm$json$Json$Decode$Failure = F2(
	function (a, b) {
		return {$: 'Failure', a: a, b: b};
	});
var $elm$json$Json$Decode$Field = F2(
	function (a, b) {
		return {$: 'Field', a: a, b: b};
	});
var $elm$json$Json$Decode$Index = F2(
	function (a, b) {
		return {$: 'Index', a: a, b: b};
	});
var $elm$core$Result$Ok = function (a) {
	return {$: 'Ok', a: a};
};
var $elm$json$Json$Decode$OneOf = function (a) {
	return {$: 'OneOf', a: a};
};
var $elm$core$Basics$False = {$: 'False'};
var $elm$core$Basics$add = _Basics_add;
var $elm$core$Maybe$Just = function (a) {
	return {$: 'Just', a: a};
};
var $elm$core$Maybe$Nothing = {$: 'Nothing'};
var $elm$core$String$all = _String_all;
var $elm$core$Basics$and = _Basics_and;
var $elm$core$Basics$append = _Utils_append;
var $elm$json$Json$Encode$encode = _Json_encode;
var $elm$core$String$fromInt = _String_fromNumber;
var $elm$core$String$join = F2(
	function (sep, chunks) {
		return A2(
			_String_join,
			sep,
			_List_toArray(chunks));
	});
var $elm$core$String$split = F2(
	function (sep, string) {
		return _List_fromArray(
			A2(_String_split, sep, string));
	});
var $elm$json$Json$Decode$indent = function (str) {
	return A2(
		$elm$core$String$join,
		'\n    ',
		A2($elm$core$String$split, '\n', str));
};
var $elm$core$List$foldl = F3(
	function (func, acc, list) {
		foldl:
		while (true) {
			if (!list.b) {
				return acc;
			} else {
				var x = list.a;
				var xs = list.b;
				var $temp$func = func,
					$temp$acc = A2(func, x, acc),
					$temp$list = xs;
				func = $temp$func;
				acc = $temp$acc;
				list = $temp$list;
				continue foldl;
			}
		}
	});
var $elm$core$List$length = function (xs) {
	return A3(
		$elm$core$List$foldl,
		F2(
			function (_v0, i) {
				return i + 1;
			}),
		0,
		xs);
};
var $elm$core$List$map2 = _List_map2;
var $elm$core$Basics$le = _Utils_le;
var $elm$core$Basics$sub = _Basics_sub;
var $elm$core$List$rangeHelp = F3(
	function (lo, hi, list) {
		rangeHelp:
		while (true) {
			if (_Utils_cmp(lo, hi) < 1) {
				var $temp$lo = lo,
					$temp$hi = hi - 1,
					$temp$list = A2($elm$core$List$cons, hi, list);
				lo = $temp$lo;
				hi = $temp$hi;
				list = $temp$list;
				continue rangeHelp;
			} else {
				return list;
			}
		}
	});
var $elm$core$List$range = F2(
	function (lo, hi) {
		return A3($elm$core$List$rangeHelp, lo, hi, _List_Nil);
	});
var $elm$core$List$indexedMap = F2(
	function (f, xs) {
		return A3(
			$elm$core$List$map2,
			f,
			A2(
				$elm$core$List$range,
				0,
				$elm$core$List$length(xs) - 1),
			xs);
	});
var $elm$core$Char$toCode = _Char_toCode;
var $elm$core$Char$isLower = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return (97 <= code) && (code <= 122);
};
var $elm$core$Char$isUpper = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return (code <= 90) && (65 <= code);
};
var $elm$core$Basics$or = _Basics_or;
var $elm$core$Char$isAlpha = function (_char) {
	return $elm$core$Char$isLower(_char) || $elm$core$Char$isUpper(_char);
};
var $elm$core$Char$isDigit = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return (code <= 57) && (48 <= code);
};
var $elm$core$Char$isAlphaNum = function (_char) {
	return $elm$core$Char$isLower(_char) || ($elm$core$Char$isUpper(_char) || $elm$core$Char$isDigit(_char));
};
var $elm$core$List$reverse = function (list) {
	return A3($elm$core$List$foldl, $elm$core$List$cons, _List_Nil, list);
};
var $elm$core$String$uncons = _String_uncons;
var $elm$json$Json$Decode$errorOneOf = F2(
	function (i, error) {
		return '\n\n(' + ($elm$core$String$fromInt(i + 1) + (') ' + $elm$json$Json$Decode$indent(
			$elm$json$Json$Decode$errorToString(error))));
	});
var $elm$json$Json$Decode$errorToString = function (error) {
	return A2($elm$json$Json$Decode$errorToStringHelp, error, _List_Nil);
};
var $elm$json$Json$Decode$errorToStringHelp = F2(
	function (error, context) {
		errorToStringHelp:
		while (true) {
			switch (error.$) {
				case 'Field':
					var f = error.a;
					var err = error.b;
					var isSimple = function () {
						var _v1 = $elm$core$String$uncons(f);
						if (_v1.$ === 'Nothing') {
							return false;
						} else {
							var _v2 = _v1.a;
							var _char = _v2.a;
							var rest = _v2.b;
							return $elm$core$Char$isAlpha(_char) && A2($elm$core$String$all, $elm$core$Char$isAlphaNum, rest);
						}
					}();
					var fieldName = isSimple ? ('.' + f) : ('[\'' + (f + '\']'));
					var $temp$error = err,
						$temp$context = A2($elm$core$List$cons, fieldName, context);
					error = $temp$error;
					context = $temp$context;
					continue errorToStringHelp;
				case 'Index':
					var i = error.a;
					var err = error.b;
					var indexName = '[' + ($elm$core$String$fromInt(i) + ']');
					var $temp$error = err,
						$temp$context = A2($elm$core$List$cons, indexName, context);
					error = $temp$error;
					context = $temp$context;
					continue errorToStringHelp;
				case 'OneOf':
					var errors = error.a;
					if (!errors.b) {
						return 'Ran into a Json.Decode.oneOf with no possibilities' + function () {
							if (!context.b) {
								return '!';
							} else {
								return ' at json' + A2(
									$elm$core$String$join,
									'',
									$elm$core$List$reverse(context));
							}
						}();
					} else {
						if (!errors.b.b) {
							var err = errors.a;
							var $temp$error = err,
								$temp$context = context;
							error = $temp$error;
							context = $temp$context;
							continue errorToStringHelp;
						} else {
							var starter = function () {
								if (!context.b) {
									return 'Json.Decode.oneOf';
								} else {
									return 'The Json.Decode.oneOf at json' + A2(
										$elm$core$String$join,
										'',
										$elm$core$List$reverse(context));
								}
							}();
							var introduction = starter + (' failed in the following ' + ($elm$core$String$fromInt(
								$elm$core$List$length(errors)) + ' ways:'));
							return A2(
								$elm$core$String$join,
								'\n\n',
								A2(
									$elm$core$List$cons,
									introduction,
									A2($elm$core$List$indexedMap, $elm$json$Json$Decode$errorOneOf, errors)));
						}
					}
				default:
					var msg = error.a;
					var json = error.b;
					var introduction = function () {
						if (!context.b) {
							return 'Problem with the given value:\n\n';
						} else {
							return 'Problem with the value at json' + (A2(
								$elm$core$String$join,
								'',
								$elm$core$List$reverse(context)) + ':\n\n    ');
						}
					}();
					return introduction + ($elm$json$Json$Decode$indent(
						A2($elm$json$Json$Encode$encode, 4, json)) + ('\n\n' + msg));
			}
		}
	});
var $elm$core$Array$branchFactor = 32;
var $elm$core$Array$Array_elm_builtin = F4(
	function (a, b, c, d) {
		return {$: 'Array_elm_builtin', a: a, b: b, c: c, d: d};
	});
var $elm$core$Elm$JsArray$empty = _JsArray_empty;
var $elm$core$Basics$ceiling = _Basics_ceiling;
var $elm$core$Basics$fdiv = _Basics_fdiv;
var $elm$core$Basics$logBase = F2(
	function (base, number) {
		return _Basics_log(number) / _Basics_log(base);
	});
var $elm$core$Basics$toFloat = _Basics_toFloat;
var $elm$core$Array$shiftStep = $elm$core$Basics$ceiling(
	A2($elm$core$Basics$logBase, 2, $elm$core$Array$branchFactor));
var $elm$core$Array$empty = A4($elm$core$Array$Array_elm_builtin, 0, $elm$core$Array$shiftStep, $elm$core$Elm$JsArray$empty, $elm$core$Elm$JsArray$empty);
var $elm$core$Elm$JsArray$initialize = _JsArray_initialize;
var $elm$core$Array$Leaf = function (a) {
	return {$: 'Leaf', a: a};
};
var $elm$core$Basics$apL = F2(
	function (f, x) {
		return f(x);
	});
var $elm$core$Basics$apR = F2(
	function (x, f) {
		return f(x);
	});
var $elm$core$Basics$eq = _Utils_equal;
var $elm$core$Basics$floor = _Basics_floor;
var $elm$core$Elm$JsArray$length = _JsArray_length;
var $elm$core$Basics$gt = _Utils_gt;
var $elm$core$Basics$max = F2(
	function (x, y) {
		return (_Utils_cmp(x, y) > 0) ? x : y;
	});
var $elm$core$Basics$mul = _Basics_mul;
var $elm$core$Array$SubTree = function (a) {
	return {$: 'SubTree', a: a};
};
var $elm$core$Elm$JsArray$initializeFromList = _JsArray_initializeFromList;
var $elm$core$Array$compressNodes = F2(
	function (nodes, acc) {
		compressNodes:
		while (true) {
			var _v0 = A2($elm$core$Elm$JsArray$initializeFromList, $elm$core$Array$branchFactor, nodes);
			var node = _v0.a;
			var remainingNodes = _v0.b;
			var newAcc = A2(
				$elm$core$List$cons,
				$elm$core$Array$SubTree(node),
				acc);
			if (!remainingNodes.b) {
				return $elm$core$List$reverse(newAcc);
			} else {
				var $temp$nodes = remainingNodes,
					$temp$acc = newAcc;
				nodes = $temp$nodes;
				acc = $temp$acc;
				continue compressNodes;
			}
		}
	});
var $elm$core$Tuple$first = function (_v0) {
	var x = _v0.a;
	return x;
};
var $elm$core$Array$treeFromBuilder = F2(
	function (nodeList, nodeListSize) {
		treeFromBuilder:
		while (true) {
			var newNodeSize = $elm$core$Basics$ceiling(nodeListSize / $elm$core$Array$branchFactor);
			if (newNodeSize === 1) {
				return A2($elm$core$Elm$JsArray$initializeFromList, $elm$core$Array$branchFactor, nodeList).a;
			} else {
				var $temp$nodeList = A2($elm$core$Array$compressNodes, nodeList, _List_Nil),
					$temp$nodeListSize = newNodeSize;
				nodeList = $temp$nodeList;
				nodeListSize = $temp$nodeListSize;
				continue treeFromBuilder;
			}
		}
	});
var $elm$core$Array$builderToArray = F2(
	function (reverseNodeList, builder) {
		if (!builder.nodeListSize) {
			return A4(
				$elm$core$Array$Array_elm_builtin,
				$elm$core$Elm$JsArray$length(builder.tail),
				$elm$core$Array$shiftStep,
				$elm$core$Elm$JsArray$empty,
				builder.tail);
		} else {
			var treeLen = builder.nodeListSize * $elm$core$Array$branchFactor;
			var depth = $elm$core$Basics$floor(
				A2($elm$core$Basics$logBase, $elm$core$Array$branchFactor, treeLen - 1));
			var correctNodeList = reverseNodeList ? $elm$core$List$reverse(builder.nodeList) : builder.nodeList;
			var tree = A2($elm$core$Array$treeFromBuilder, correctNodeList, builder.nodeListSize);
			return A4(
				$elm$core$Array$Array_elm_builtin,
				$elm$core$Elm$JsArray$length(builder.tail) + treeLen,
				A2($elm$core$Basics$max, 5, depth * $elm$core$Array$shiftStep),
				tree,
				builder.tail);
		}
	});
var $elm$core$Basics$idiv = _Basics_idiv;
var $elm$core$Basics$lt = _Utils_lt;
var $elm$core$Array$initializeHelp = F5(
	function (fn, fromIndex, len, nodeList, tail) {
		initializeHelp:
		while (true) {
			if (fromIndex < 0) {
				return A2(
					$elm$core$Array$builderToArray,
					false,
					{nodeList: nodeList, nodeListSize: (len / $elm$core$Array$branchFactor) | 0, tail: tail});
			} else {
				var leaf = $elm$core$Array$Leaf(
					A3($elm$core$Elm$JsArray$initialize, $elm$core$Array$branchFactor, fromIndex, fn));
				var $temp$fn = fn,
					$temp$fromIndex = fromIndex - $elm$core$Array$branchFactor,
					$temp$len = len,
					$temp$nodeList = A2($elm$core$List$cons, leaf, nodeList),
					$temp$tail = tail;
				fn = $temp$fn;
				fromIndex = $temp$fromIndex;
				len = $temp$len;
				nodeList = $temp$nodeList;
				tail = $temp$tail;
				continue initializeHelp;
			}
		}
	});
var $elm$core$Basics$remainderBy = _Basics_remainderBy;
var $elm$core$Array$initialize = F2(
	function (len, fn) {
		if (len <= 0) {
			return $elm$core$Array$empty;
		} else {
			var tailLen = len % $elm$core$Array$branchFactor;
			var tail = A3($elm$core$Elm$JsArray$initialize, tailLen, len - tailLen, fn);
			var initialFromIndex = (len - tailLen) - $elm$core$Array$branchFactor;
			return A5($elm$core$Array$initializeHelp, fn, initialFromIndex, len, _List_Nil, tail);
		}
	});
var $elm$core$Basics$True = {$: 'True'};
var $elm$core$Result$isOk = function (result) {
	if (result.$ === 'Ok') {
		return true;
	} else {
		return false;
	}
};
var $elm$json$Json$Decode$andThen = _Json_andThen;
var $elm$json$Json$Decode$field = _Json_decodeField;
var $elm$core$Basics$identity = function (x) {
	return x;
};
var $author$project$API$EventLogMsg = function (a) {
	return {$: 'EventLogMsg', a: a};
};
var $elm$core$Platform$Cmd$batch = _Platform_batch;
var $the_sett$elm_aws_core$AWS$Credentials$fromAccessKeys = F2(
	function (keyId, secretKey) {
		return {accessKeyId: keyId, secretAccessKey: secretKey, sessionToken: $elm$core$Maybe$Nothing};
	});
var $author$project$EventLog$Model$ModelStart = function (a) {
	return {$: 'ModelStart', a: a};
};
var $the_sett$elm_update_helper$Update2$andMap = F2(
	function (fn, _v0) {
		var model = _v0.a;
		var cmd = _v0.b;
		var _v1 = fn(model);
		var nextModel = _v1.a;
		var nextCmd = _v1.b;
		return _Utils_Tuple2(
			nextModel,
			$elm$core$Platform$Cmd$batch(
				_List_fromArray(
					[cmd, nextCmd])));
	});
var $elm$core$Platform$Cmd$map = _Platform_map;
var $elm$core$Tuple$mapSecond = F2(
	function (func, _v0) {
		var x = _v0.a;
		var y = _v0.b;
		return _Utils_Tuple2(
			x,
			func(y));
	});
var $elm$core$Platform$Cmd$none = $elm$core$Platform$Cmd$batch(_List_Nil);
var $the_sett$elm_update_helper$Update2$pure = function (model) {
	return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
};
var $author$project$EventLog$Msg$RandomSeed = function (a) {
	return {$: 'RandomSeed', a: a};
};
var $elm$random$Random$Generate = function (a) {
	return {$: 'Generate', a: a};
};
var $elm$core$Task$andThen = _Scheduler_andThen;
var $elm$random$Random$Seed = F2(
	function (a, b) {
		return {$: 'Seed', a: a, b: b};
	});
var $elm$core$Bitwise$shiftRightZfBy = _Bitwise_shiftRightZfBy;
var $elm$random$Random$next = function (_v0) {
	var state0 = _v0.a;
	var incr = _v0.b;
	return A2($elm$random$Random$Seed, ((state0 * 1664525) + incr) >>> 0, incr);
};
var $elm$random$Random$initialSeed = function (x) {
	var _v0 = $elm$random$Random$next(
		A2($elm$random$Random$Seed, 0, 1013904223));
	var state1 = _v0.a;
	var incr = _v0.b;
	var state2 = (state1 + x) >>> 0;
	return $elm$random$Random$next(
		A2($elm$random$Random$Seed, state2, incr));
};
var $elm$time$Time$Name = function (a) {
	return {$: 'Name', a: a};
};
var $elm$time$Time$Offset = function (a) {
	return {$: 'Offset', a: a};
};
var $elm$time$Time$Zone = F2(
	function (a, b) {
		return {$: 'Zone', a: a, b: b};
	});
var $elm$time$Time$customZone = $elm$time$Time$Zone;
var $elm$time$Time$Posix = function (a) {
	return {$: 'Posix', a: a};
};
var $elm$time$Time$millisToPosix = $elm$time$Time$Posix;
var $elm$time$Time$now = _Time_now($elm$time$Time$millisToPosix);
var $elm$time$Time$posixToMillis = function (_v0) {
	var millis = _v0.a;
	return millis;
};
var $elm$core$Task$succeed = _Scheduler_succeed;
var $elm$random$Random$init = A2(
	$elm$core$Task$andThen,
	function (time) {
		return $elm$core$Task$succeed(
			$elm$random$Random$initialSeed(
				$elm$time$Time$posixToMillis(time)));
	},
	$elm$time$Time$now);
var $elm$core$Platform$sendToApp = _Platform_sendToApp;
var $elm$random$Random$step = F2(
	function (_v0, seed) {
		var generator = _v0.a;
		return generator(seed);
	});
var $elm$random$Random$onEffects = F3(
	function (router, commands, seed) {
		if (!commands.b) {
			return $elm$core$Task$succeed(seed);
		} else {
			var generator = commands.a.a;
			var rest = commands.b;
			var _v1 = A2($elm$random$Random$step, generator, seed);
			var value = _v1.a;
			var newSeed = _v1.b;
			return A2(
				$elm$core$Task$andThen,
				function (_v2) {
					return A3($elm$random$Random$onEffects, router, rest, newSeed);
				},
				A2($elm$core$Platform$sendToApp, router, value));
		}
	});
var $elm$random$Random$onSelfMsg = F3(
	function (_v0, _v1, seed) {
		return $elm$core$Task$succeed(seed);
	});
var $elm$random$Random$Generator = function (a) {
	return {$: 'Generator', a: a};
};
var $elm$random$Random$map = F2(
	function (func, _v0) {
		var genA = _v0.a;
		return $elm$random$Random$Generator(
			function (seed0) {
				var _v1 = genA(seed0);
				var a = _v1.a;
				var seed1 = _v1.b;
				return _Utils_Tuple2(
					func(a),
					seed1);
			});
	});
var $elm$random$Random$cmdMap = F2(
	function (func, _v0) {
		var generator = _v0.a;
		return $elm$random$Random$Generate(
			A2($elm$random$Random$map, func, generator));
	});
_Platform_effectManagers['Random'] = _Platform_createManager($elm$random$Random$init, $elm$random$Random$onEffects, $elm$random$Random$onSelfMsg, $elm$random$Random$cmdMap);
var $elm$random$Random$command = _Platform_leaf('Random');
var $elm$random$Random$generate = F2(
	function (tagger, generator) {
		return $elm$random$Random$command(
			$elm$random$Random$Generate(
				A2($elm$random$Random$map, tagger, generator)));
	});
var $elm$core$Bitwise$and = _Bitwise_and;
var $elm$core$Basics$negate = function (n) {
	return -n;
};
var $elm$core$Bitwise$xor = _Bitwise_xor;
var $elm$random$Random$peel = function (_v0) {
	var state = _v0.a;
	var word = (state ^ (state >>> ((state >>> 28) + 4))) * 277803737;
	return ((word >>> 22) ^ word) >>> 0;
};
var $elm$random$Random$int = F2(
	function (a, b) {
		return $elm$random$Random$Generator(
			function (seed0) {
				var _v0 = (_Utils_cmp(a, b) < 0) ? _Utils_Tuple2(a, b) : _Utils_Tuple2(b, a);
				var lo = _v0.a;
				var hi = _v0.b;
				var range = (hi - lo) + 1;
				if (!((range - 1) & range)) {
					return _Utils_Tuple2(
						(((range - 1) & $elm$random$Random$peel(seed0)) >>> 0) + lo,
						$elm$random$Random$next(seed0));
				} else {
					var threshhold = (((-range) >>> 0) % range) >>> 0;
					var accountForBias = function (seed) {
						accountForBias:
						while (true) {
							var x = $elm$random$Random$peel(seed);
							var seedN = $elm$random$Random$next(seed);
							if (_Utils_cmp(x, threshhold) < 0) {
								var $temp$seed = seedN;
								seed = $temp$seed;
								continue accountForBias;
							} else {
								return _Utils_Tuple2((x % range) + lo, seedN);
							}
						}
					};
					return accountForBias(seed0);
				}
			});
	});
var $elm$random$Random$map3 = F4(
	function (func, _v0, _v1, _v2) {
		var genA = _v0.a;
		var genB = _v1.a;
		var genC = _v2.a;
		return $elm$random$Random$Generator(
			function (seed0) {
				var _v3 = genA(seed0);
				var a = _v3.a;
				var seed1 = _v3.b;
				var _v4 = genB(seed1);
				var b = _v4.a;
				var seed2 = _v4.b;
				var _v5 = genC(seed2);
				var c = _v5.a;
				var seed3 = _v5.b;
				return _Utils_Tuple2(
					A3(func, a, b, c),
					seed3);
			});
	});
var $elm$core$Bitwise$or = _Bitwise_or;
var $elm$random$Random$independentSeed = $elm$random$Random$Generator(
	function (seed0) {
		var makeIndependentSeed = F3(
			function (state, b, c) {
				return $elm$random$Random$next(
					A2($elm$random$Random$Seed, state, (1 | (b ^ c)) >>> 0));
			});
		var gen = A2($elm$random$Random$int, 0, 4294967295);
		return A2(
			$elm$random$Random$step,
			A4($elm$random$Random$map3, makeIndependentSeed, gen, gen, gen),
			seed0);
	});
var $author$project$EventLog$Component$randomize = function (model) {
	return _Utils_Tuple2(
		model,
		A2($elm$random$Random$generate, $author$project$EventLog$Msg$RandomSeed, $elm$random$Random$independentSeed));
};
var $author$project$EventLog$Component$switchState = F2(
	function (cons, state) {
		return _Utils_Tuple2(
			cons(state),
			$elm$core$Platform$Cmd$none);
	});
var $author$project$EventLog$Component$init = function (toMsg) {
	return A2(
		$elm$core$Tuple$mapSecond,
		$elm$core$Platform$Cmd$map(toMsg),
		A2(
			$the_sett$elm_update_helper$Update2$andMap,
			$author$project$EventLog$Component$switchState($author$project$EventLog$Model$ModelStart),
			A2(
				$the_sett$elm_update_helper$Update2$andMap,
				$author$project$EventLog$Component$randomize,
				$the_sett$elm_update_helper$Update2$pure(
					{}))));
};
var $the_sett$elm_aws_core$AWS$Credentials$withSessionToken = F2(
	function (token, creds) {
		return _Utils_update(
			creds,
			{
				sessionToken: $elm$core$Maybe$Just(token)
			});
	});
var $author$project$API$init = function (flags) {
	var credentials = A2(
		$the_sett$elm_aws_core$AWS$Credentials$withSessionToken,
		flags.awsSessionToken,
		A2($the_sett$elm_aws_core$AWS$Credentials$fromAccessKeys, flags.awsAccessKeyId, flags.awsSecretAccessKey));
	var _v0 = $author$project$EventLog$Component$init($author$project$API$EventLogMsg);
	var eventLogMdl = _v0.a;
	var eventLogCmds = _v0.b;
	return _Utils_Tuple2(
		{awsAccessKeyId: flags.awsAccessKeyId, awsRegion: flags.awsRegion, awsSecretAccessKey: flags.awsSecretAccessKey, awsSessionToken: flags.awsSessionToken, channelApiUrl: flags.channelApiUrl, channelTable: flags.channelTable, defaultCredentials: credentials, eventLog: eventLogMdl, eventLogTable: flags.eventLogTable, momentoApiKey: flags.momentoSecret.apiKey, snapshotQueueUrl: flags.snapshotQueueUrl, snapshotTable: flags.snapshotTable},
		$elm$core$Platform$Cmd$batch(
			_List_fromArray(
				[eventLogCmds])));
};
var $elm$json$Json$Decode$string = _Json_decodeString;
var $elm$core$Platform$Sub$batch = _Platform_batch;
var $author$project$API$eventLogProtocol = {onUpdate: $elm$core$Basics$identity, toMsg: $author$project$API$EventLogMsg};
var $author$project$EventLog$Msg$HttpRequest = F2(
	function (a, b) {
		return {$: 'HttpRequest', a: a, b: b};
	});
var $author$project$EventLog$Msg$MomentoError = function (a) {
	return {$: 'MomentoError', a: a};
};
var $author$project$EventLog$Msg$SqsEvent = F2(
	function (a, b) {
		return {$: 'SqsEvent', a: a, b: b};
	});
var $author$project$HttpServer$HttpSessionKey = function (a) {
	return {$: 'HttpSessionKey', a: a};
};
var $author$project$HttpServer$InvalidRequestFormat = function (a) {
	return {$: 'InvalidRequestFormat', a: a};
};
var $author$project$HttpServer$NoMatchingRoute = function (a) {
	return {$: 'NoMatchingRoute', a: a};
};
var $elm$core$Maybe$andThen = F2(
	function (callback, maybeValue) {
		if (maybeValue.$ === 'Just') {
			var value = maybeValue.a;
			return callback(value);
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $elm$core$Result$andThen = F2(
	function (callback, result) {
		if (result.$ === 'Ok') {
			var value = result.a;
			return callback(value);
		} else {
			var msg = result.a;
			return $elm$core$Result$Err(msg);
		}
	});
var $elm$json$Json$Decode$decodeValue = _Json_run;
var $author$project$Http$Request$HeadersOnly = function (headers) {
	return {headers: headers};
};
var $author$project$Http$Request$Request = function (a) {
	return {$: 'Request', a: a};
};
var $elm$core$Basics$composeL = F3(
	function (g, f, x) {
		return g(
			f(x));
	});
var $elm$json$Json$Decode$keyValuePairs = _Json_decodeKeyValuePairs;
var $elm$json$Json$Decode$map = _Json_map1;
var $elm$json$Json$Decode$null = _Json_decodeNull;
var $elm$json$Json$Decode$oneOf = _Json_oneOf;
var $elm$json$Json$Decode$nullable = function (decoder) {
	return $elm$json$Json$Decode$oneOf(
		_List_fromArray(
			[
				$elm$json$Json$Decode$null($elm$core$Maybe$Nothing),
				A2($elm$json$Json$Decode$map, $elm$core$Maybe$Just, decoder)
			]));
};
var $elm$json$Json$Decode$succeed = _Json_succeed;
var $author$project$Http$KeyValueList$decoder = A2(
	$elm$json$Json$Decode$andThen,
	function (maybeParams) {
		if (maybeParams.$ === 'Just') {
			var params = maybeParams.a;
			return $elm$json$Json$Decode$succeed(params);
		} else {
			return $elm$json$Json$Decode$succeed(_List_Nil);
		}
	},
	$elm$json$Json$Decode$nullable(
		$elm$json$Json$Decode$keyValuePairs($elm$json$Json$Decode$string)));
var $elm$core$Dict$RBEmpty_elm_builtin = {$: 'RBEmpty_elm_builtin'};
var $elm$core$Dict$empty = $elm$core$Dict$RBEmpty_elm_builtin;
var $elm$core$Dict$Black = {$: 'Black'};
var $elm$core$Dict$RBNode_elm_builtin = F5(
	function (a, b, c, d, e) {
		return {$: 'RBNode_elm_builtin', a: a, b: b, c: c, d: d, e: e};
	});
var $elm$core$Dict$Red = {$: 'Red'};
var $elm$core$Dict$balance = F5(
	function (color, key, value, left, right) {
		if ((right.$ === 'RBNode_elm_builtin') && (right.a.$ === 'Red')) {
			var _v1 = right.a;
			var rK = right.b;
			var rV = right.c;
			var rLeft = right.d;
			var rRight = right.e;
			if ((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Red')) {
				var _v3 = left.a;
				var lK = left.b;
				var lV = left.c;
				var lLeft = left.d;
				var lRight = left.e;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Red,
					key,
					value,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					color,
					rK,
					rV,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, key, value, left, rLeft),
					rRight);
			}
		} else {
			if ((((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Red')) && (left.d.$ === 'RBNode_elm_builtin')) && (left.d.a.$ === 'Red')) {
				var _v5 = left.a;
				var lK = left.b;
				var lV = left.c;
				var _v6 = left.d;
				var _v7 = _v6.a;
				var llK = _v6.b;
				var llV = _v6.c;
				var llLeft = _v6.d;
				var llRight = _v6.e;
				var lRight = left.e;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Red,
					lK,
					lV,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, llK, llV, llLeft, llRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, key, value, lRight, right));
			} else {
				return A5($elm$core$Dict$RBNode_elm_builtin, color, key, value, left, right);
			}
		}
	});
var $elm$core$Basics$compare = _Utils_compare;
var $elm$core$Dict$insertHelp = F3(
	function (key, value, dict) {
		if (dict.$ === 'RBEmpty_elm_builtin') {
			return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, key, value, $elm$core$Dict$RBEmpty_elm_builtin, $elm$core$Dict$RBEmpty_elm_builtin);
		} else {
			var nColor = dict.a;
			var nKey = dict.b;
			var nValue = dict.c;
			var nLeft = dict.d;
			var nRight = dict.e;
			var _v1 = A2($elm$core$Basics$compare, key, nKey);
			switch (_v1.$) {
				case 'LT':
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						A3($elm$core$Dict$insertHelp, key, value, nLeft),
						nRight);
				case 'EQ':
					return A5($elm$core$Dict$RBNode_elm_builtin, nColor, nKey, value, nLeft, nRight);
				default:
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						nLeft,
						A3($elm$core$Dict$insertHelp, key, value, nRight));
			}
		}
	});
var $elm$core$Dict$insert = F3(
	function (key, value, dict) {
		var _v0 = A3($elm$core$Dict$insertHelp, key, value, dict);
		if ((_v0.$ === 'RBNode_elm_builtin') && (_v0.a.$ === 'Red')) {
			var _v1 = _v0.a;
			var k = _v0.b;
			var v = _v0.c;
			var l = _v0.d;
			var r = _v0.e;
			return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, k, v, l, r);
		} else {
			var x = _v0;
			return x;
		}
	});
var $elm$core$Dict$fromList = function (assocs) {
	return A3(
		$elm$core$List$foldl,
		F2(
			function (_v0, dict) {
				var key = _v0.a;
				var value = _v0.b;
				return A3($elm$core$Dict$insert, key, value, dict);
			}),
		$elm$core$Dict$empty,
		assocs);
};
var $author$project$Http$Body$Empty = {$: 'Empty'};
var $author$project$Http$Body$Error = function (a) {
	return {$: 'Error', a: a};
};
var $author$project$Http$Body$Json = function (a) {
	return {$: 'Json', a: a};
};
var $author$project$Http$Body$Text = function (a) {
	return {$: 'Text', a: a};
};
var $elm$json$Json$Decode$decodeString = _Json_runOnString;
var $elm$json$Json$Decode$maybe = function (decoder) {
	return $elm$json$Json$Decode$oneOf(
		_List_fromArray(
			[
				A2($elm$json$Json$Decode$map, $elm$core$Maybe$Just, decoder),
				$elm$json$Json$Decode$succeed($elm$core$Maybe$Nothing)
			]));
};
var $elm$core$String$startsWith = _String_startsWith;
var $elm$json$Json$Decode$value = _Json_decodeValue;
var $elm$core$Maybe$withDefault = F2(
	function (_default, maybe) {
		if (maybe.$ === 'Just') {
			var value = maybe.a;
			return value;
		} else {
			return _default;
		}
	});
var $author$project$Http$Body$decoder = function (maybeType) {
	return A2(
		$elm$json$Json$Decode$andThen,
		function (maybeString) {
			if (maybeString.$ === 'Just') {
				var w = maybeString.a;
				if (A2(
					$elm$core$String$startsWith,
					'application/json',
					A2($elm$core$Maybe$withDefault, '', maybeType))) {
					var _v1 = A2($elm$json$Json$Decode$decodeString, $elm$json$Json$Decode$value, w);
					if (_v1.$ === 'Ok') {
						var val = _v1.a;
						return $elm$json$Json$Decode$succeed(
							$author$project$Http$Body$Json(val));
					} else {
						var err = _v1.a;
						return $elm$json$Json$Decode$succeed(
							$author$project$Http$Body$Error(
								$elm$json$Json$Decode$errorToString(err)));
					}
				} else {
					return $elm$json$Json$Decode$succeed(
						$author$project$Http$Body$Text(w));
				}
			} else {
				return $elm$json$Json$Decode$succeed($author$project$Http$Body$Empty);
			}
		},
		$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string));
};
var $author$project$Http$IpAddress$Ip4 = F4(
	function (a, b, c, d) {
		return {$: 'Ip4', a: a, b: b, c: c, d: d};
	});
var $elm$json$Json$Decode$fail = _Json_fail;
var $elm$core$List$foldrHelper = F4(
	function (fn, acc, ctr, ls) {
		if (!ls.b) {
			return acc;
		} else {
			var a = ls.a;
			var r1 = ls.b;
			if (!r1.b) {
				return A2(fn, a, acc);
			} else {
				var b = r1.a;
				var r2 = r1.b;
				if (!r2.b) {
					return A2(
						fn,
						a,
						A2(fn, b, acc));
				} else {
					var c = r2.a;
					var r3 = r2.b;
					if (!r3.b) {
						return A2(
							fn,
							a,
							A2(
								fn,
								b,
								A2(fn, c, acc)));
					} else {
						var d = r3.a;
						var r4 = r3.b;
						var res = (ctr > 500) ? A3(
							$elm$core$List$foldl,
							fn,
							acc,
							$elm$core$List$reverse(r4)) : A4($elm$core$List$foldrHelper, fn, acc, ctr + 1, r4);
						return A2(
							fn,
							a,
							A2(
								fn,
								b,
								A2(
									fn,
									c,
									A2(fn, d, res))));
					}
				}
			}
		}
	});
var $elm$core$List$foldr = F3(
	function (fn, acc, ls) {
		return A4($elm$core$List$foldrHelper, fn, acc, 0, ls);
	});
var $elm$core$List$map = F2(
	function (f, xs) {
		return A3(
			$elm$core$List$foldr,
			F2(
				function (x, acc) {
					return A2(
						$elm$core$List$cons,
						f(x),
						acc);
				}),
			_List_Nil,
			xs);
	});
var $elm$core$Basics$ge = _Utils_ge;
var $elm$core$String$toInt = _String_toInt;
var $author$project$Http$IpAddress$toNonNegativeInt = function (val) {
	return A2(
		$elm$core$Maybe$andThen,
		function (i) {
			return (i >= 0) ? $elm$core$Maybe$Just(i) : $elm$core$Maybe$Nothing;
		},
		$elm$core$String$toInt(val));
};
var $author$project$Http$IpAddress$decoder = A2(
	$elm$json$Json$Decode$andThen,
	function (w) {
		var list = A2(
			$elm$core$List$map,
			$author$project$Http$IpAddress$toNonNegativeInt,
			A2($elm$core$String$split, '.', w));
		if ((((((((list.b && (list.a.$ === 'Just')) && list.b.b) && (list.b.a.$ === 'Just')) && list.b.b.b) && (list.b.b.a.$ === 'Just')) && list.b.b.b.b) && (list.b.b.b.a.$ === 'Just')) && (!list.b.b.b.b.b)) {
			var a = list.a.a;
			var _v1 = list.b;
			var b = _v1.a.a;
			var _v2 = _v1.b;
			var c = _v2.a.a;
			var _v3 = _v2.b;
			var d = _v3.a.a;
			return $elm$json$Json$Decode$succeed(
				A4($author$project$Http$IpAddress$Ip4, a, b, c, d));
		} else {
			return $elm$json$Json$Decode$fail('Unsupported IP address: ' + w);
		}
	},
	$elm$json$Json$Decode$string);
var $elm$core$Dict$get = F2(
	function (targetKey, dict) {
		get:
		while (true) {
			if (dict.$ === 'RBEmpty_elm_builtin') {
				return $elm$core$Maybe$Nothing;
			} else {
				var key = dict.b;
				var value = dict.c;
				var left = dict.d;
				var right = dict.e;
				var _v1 = A2($elm$core$Basics$compare, targetKey, key);
				switch (_v1.$) {
					case 'LT':
						var $temp$targetKey = targetKey,
							$temp$dict = left;
						targetKey = $temp$targetKey;
						dict = $temp$dict;
						continue get;
					case 'EQ':
						return $elm$core$Maybe$Just(value);
					default:
						var $temp$targetKey = targetKey,
							$temp$dict = right;
						targetKey = $temp$targetKey;
						dict = $temp$dict;
						continue get;
				}
			}
		}
	});
var $elm$core$Basics$composeR = F3(
	function (f, g, x) {
		return g(
			f(x));
	});
var $elm$json$Json$Decode$map2 = _Json_map2;
var $NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$custom = $elm$json$Json$Decode$map2($elm$core$Basics$apR);
var $NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$hardcoded = A2($elm$core$Basics$composeR, $elm$json$Json$Decode$succeed, $NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$custom);
var $elm$json$Json$Decode$int = _Json_decodeInt;
var $author$project$Http$Request$CONNECT = {$: 'CONNECT'};
var $author$project$Http$Request$DELETE = {$: 'DELETE'};
var $author$project$Http$Request$GET = {$: 'GET'};
var $author$project$Http$Request$HEAD = {$: 'HEAD'};
var $author$project$Http$Request$OPTIONS = {$: 'OPTIONS'};
var $author$project$Http$Request$PATCH = {$: 'PATCH'};
var $author$project$Http$Request$POST = {$: 'POST'};
var $author$project$Http$Request$PUT = {$: 'PUT'};
var $author$project$Http$Request$TRACE = {$: 'TRACE'};
var $elm$core$String$toLower = _String_toLower;
var $author$project$Http$Request$methodDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (w) {
		var _v0 = $elm$core$String$toLower(w);
		switch (_v0) {
			case 'connect':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$CONNECT);
			case 'delete':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$DELETE);
			case 'get':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$GET);
			case 'head':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$HEAD);
			case 'options':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$OPTIONS);
			case 'patch':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$PATCH);
			case 'post':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$POST);
			case 'put':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$PUT);
			case 'trace':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$TRACE);
			default:
				return $elm$json$Json$Decode$fail('Unsupported method: ' + w);
		}
	},
	$elm$json$Json$Decode$string);
var $NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required = F3(
	function (key, valDecoder, decoder) {
		return A2(
			$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$custom,
			A2($elm$json$Json$Decode$field, key, valDecoder),
			decoder);
	});
var $author$project$Http$Request$Http = {$: 'Http'};
var $author$project$Http$Request$Https = {$: 'Https'};
var $author$project$Http$Request$schemeDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (w) {
		var _v0 = $elm$core$String$toLower(w);
		switch (_v0) {
			case 'http':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$Http);
			case 'https':
				return $elm$json$Json$Decode$succeed($author$project$Http$Request$Https);
			default:
				return $elm$json$Json$Decode$fail('Unsupported scheme: ' + w);
		}
	},
	$elm$json$Json$Decode$string);
var $author$project$Http$Request$schemeToString = function (scheme) {
	if (scheme.$ === 'Http') {
		return 'http:';
	} else {
		return 'https:';
	}
};
var $author$project$Http$Request$modelDecoder = function (_v0) {
	var headers = _v0.headers;
	return A3(
		$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
		'queryString',
		$elm$json$Json$Decode$string,
		A3(
			$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
			'queryParams',
			A2($elm$json$Json$Decode$map, $elm$core$Dict$fromList, $author$project$Http$KeyValueList$decoder),
			A3(
				$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
				'stage',
				$elm$json$Json$Decode$string,
				A3(
					$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
					'scheme',
					$author$project$Http$Request$schemeDecoder,
					A3(
						$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
						'remoteIp',
						$author$project$Http$IpAddress$decoder,
						A3(
							$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
							'port',
							$elm$json$Json$Decode$int,
							A3(
								$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
								'path',
								$elm$json$Json$Decode$string,
								A3(
									$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
									'method',
									$author$project$Http$Request$methodDecoder,
									A3(
										$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
										'host',
										$elm$json$Json$Decode$string,
										A2(
											$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$hardcoded,
											headers,
											A3(
												$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
												'body',
												$author$project$Http$Body$decoder(
													A2($elm$core$Dict$get, 'content-type', headers)),
												$elm$json$Json$Decode$succeed(
													function (bodyVal) {
														return function (headersVal) {
															return function (hostVal) {
																return function (methodVal) {
																	return function (pathVal) {
																		return function (portVal) {
																			return function (remoteIpVal) {
																				return function (schemeVal) {
																					return function (stageVal) {
																						return function (queryParamsVal) {
																							return function (queryStringVal) {
																								return {
																									body: bodyVal,
																									headers: headersVal,
																									host: hostVal,
																									method: methodVal,
																									path: pathVal,
																									port_: portVal,
																									queryParams: queryParamsVal,
																									queryString: queryStringVal,
																									remoteIp: remoteIpVal,
																									scheme: schemeVal,
																									stage: stageVal,
																									url: $author$project$Http$Request$schemeToString(schemeVal) + ('//' + (hostVal + (':' + ($elm$core$String$fromInt(portVal) + (pathVal + queryStringVal)))))
																								};
																							};
																						};
																					};
																				};
																			};
																		};
																	};
																};
															};
														};
													}))))))))))));
};
var $author$project$Http$Request$decoder = A2(
	$elm$json$Json$Decode$andThen,
	A2(
		$elm$core$Basics$composeL,
		$elm$json$Json$Decode$map($author$project$Http$Request$Request),
		$author$project$Http$Request$modelDecoder),
	A3(
		$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
		'headers',
		A2($elm$json$Json$Decode$map, $elm$core$Dict$fromList, $author$project$Http$KeyValueList$decoder),
		$elm$json$Json$Decode$succeed($author$project$Http$Request$HeadersOnly)));
var $elm$url$Url$Http = {$: 'Http'};
var $elm$url$Url$Https = {$: 'Https'};
var $elm$url$Url$Url = F6(
	function (protocol, host, port_, path, query, fragment) {
		return {fragment: fragment, host: host, path: path, port_: port_, protocol: protocol, query: query};
	});
var $elm$core$String$contains = _String_contains;
var $elm$core$String$length = _String_length;
var $elm$core$String$slice = _String_slice;
var $elm$core$String$dropLeft = F2(
	function (n, string) {
		return (n < 1) ? string : A3(
			$elm$core$String$slice,
			n,
			$elm$core$String$length(string),
			string);
	});
var $elm$core$String$indexes = _String_indexes;
var $elm$core$String$isEmpty = function (string) {
	return string === '';
};
var $elm$core$String$left = F2(
	function (n, string) {
		return (n < 1) ? '' : A3($elm$core$String$slice, 0, n, string);
	});
var $elm$url$Url$chompBeforePath = F5(
	function (protocol, path, params, frag, str) {
		if ($elm$core$String$isEmpty(str) || A2($elm$core$String$contains, '@', str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, ':', str);
			if (!_v0.b) {
				return $elm$core$Maybe$Just(
					A6($elm$url$Url$Url, protocol, str, $elm$core$Maybe$Nothing, path, params, frag));
			} else {
				if (!_v0.b.b) {
					var i = _v0.a;
					var _v1 = $elm$core$String$toInt(
						A2($elm$core$String$dropLeft, i + 1, str));
					if (_v1.$ === 'Nothing') {
						return $elm$core$Maybe$Nothing;
					} else {
						var port_ = _v1;
						return $elm$core$Maybe$Just(
							A6(
								$elm$url$Url$Url,
								protocol,
								A2($elm$core$String$left, i, str),
								port_,
								path,
								params,
								frag));
					}
				} else {
					return $elm$core$Maybe$Nothing;
				}
			}
		}
	});
var $elm$url$Url$chompBeforeQuery = F4(
	function (protocol, params, frag, str) {
		if ($elm$core$String$isEmpty(str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, '/', str);
			if (!_v0.b) {
				return A5($elm$url$Url$chompBeforePath, protocol, '/', params, frag, str);
			} else {
				var i = _v0.a;
				return A5(
					$elm$url$Url$chompBeforePath,
					protocol,
					A2($elm$core$String$dropLeft, i, str),
					params,
					frag,
					A2($elm$core$String$left, i, str));
			}
		}
	});
var $elm$url$Url$chompBeforeFragment = F3(
	function (protocol, frag, str) {
		if ($elm$core$String$isEmpty(str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, '?', str);
			if (!_v0.b) {
				return A4($elm$url$Url$chompBeforeQuery, protocol, $elm$core$Maybe$Nothing, frag, str);
			} else {
				var i = _v0.a;
				return A4(
					$elm$url$Url$chompBeforeQuery,
					protocol,
					$elm$core$Maybe$Just(
						A2($elm$core$String$dropLeft, i + 1, str)),
					frag,
					A2($elm$core$String$left, i, str));
			}
		}
	});
var $elm$url$Url$chompAfterProtocol = F2(
	function (protocol, str) {
		if ($elm$core$String$isEmpty(str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, '#', str);
			if (!_v0.b) {
				return A3($elm$url$Url$chompBeforeFragment, protocol, $elm$core$Maybe$Nothing, str);
			} else {
				var i = _v0.a;
				return A3(
					$elm$url$Url$chompBeforeFragment,
					protocol,
					$elm$core$Maybe$Just(
						A2($elm$core$String$dropLeft, i + 1, str)),
					A2($elm$core$String$left, i, str));
			}
		}
	});
var $elm$url$Url$fromString = function (str) {
	return A2($elm$core$String$startsWith, 'http://', str) ? A2(
		$elm$url$Url$chompAfterProtocol,
		$elm$url$Url$Http,
		A2($elm$core$String$dropLeft, 7, str)) : (A2($elm$core$String$startsWith, 'https://', str) ? A2(
		$elm$url$Url$chompAfterProtocol,
		$elm$url$Url$Https,
		A2($elm$core$String$dropLeft, 8, str)) : $elm$core$Maybe$Nothing);
};
var $elm$core$Result$mapError = F2(
	function (f, result) {
		if (result.$ === 'Ok') {
			var v = result.a;
			return $elm$core$Result$Ok(v);
		} else {
			var e = result.a;
			return $elm$core$Result$Err(
				f(e));
		}
	});
var $author$project$Http$Request$url = function (_v0) {
	var request = _v0.a;
	return request.url;
};
var $author$project$HttpServer$decodeRequestAndRoute = F2(
	function (rawRequest, parseRoute) {
		return A2(
			$elm$core$Result$andThen,
			function (req) {
				return function (maybeRoute) {
					if (maybeRoute.$ === 'Nothing') {
						return $elm$core$Result$Err(
							$author$project$HttpServer$NoMatchingRoute(
								$author$project$Http$Request$url(req)));
					} else {
						var route = maybeRoute.a;
						return $elm$core$Result$Ok(
							_Utils_Tuple2(req, route));
					}
				}(
					A2(
						$elm$core$Maybe$andThen,
						parseRoute,
						$elm$url$Url$fromString(
							$author$project$Http$Request$url(req))));
			},
			A2(
				$elm$core$Result$mapError,
				$author$project$HttpServer$InvalidRequestFormat,
				A2($elm$json$Json$Decode$decodeValue, $author$project$Http$Request$decoder, rawRequest)));
	});
var $elm$core$Platform$Sub$map = _Platform_map;
var $elm$core$Result$map = F2(
	function (func, ra) {
		if (ra.$ === 'Ok') {
			var a = ra.a;
			return $elm$core$Result$Ok(
				func(a));
		} else {
			var e = ra.a;
			return $elm$core$Result$Err(e);
		}
	});
var $author$project$HttpServer$requestSub = F2(
	function (protocol, requestFn) {
		var fn = function (_v1) {
			var session = _v1.session;
			var req = _v1.req;
			return A2(
				requestFn,
				$author$project$HttpServer$HttpSessionKey(session),
				A2(
					$elm$core$Result$map,
					function (_v0) {
						var request = _v0.a;
						var route = _v0.b;
						return {request: request, route: route};
					},
					A2($author$project$HttpServer$decodeRequestAndRoute, req, protocol.parseRoute)));
		};
		return A2(
			$elm$core$Platform$Sub$map,
			$elm$core$Basics$identity,
			protocol.ports.request(fn));
	});
var $elm$json$Json$Encode$bool = _Json_wrap;
var $author$project$Http$Body$contentType = function (body) {
	switch (body.$) {
		case 'Json':
			return 'application/json';
		case 'Binary':
			var binType = body.a;
			return binType;
		default:
			return 'text/text';
	}
};
var $author$project$Http$Charset$toString = function (charset) {
	return 'utf-8';
};
var $author$project$Http$Response$contentType = function (_v0) {
	var body = _v0.body;
	var charset = _v0.charset;
	return $author$project$Http$Body$contentType(body) + ('; charset=' + $author$project$Http$Charset$toString(charset));
};
var $elm$json$Json$Encode$null = _Json_encodeNull;
var $elm$json$Json$Encode$string = _Json_wrap;
var $author$project$Http$Body$encode = function (body) {
	switch (body.$) {
		case 'Empty':
			return $elm$json$Json$Encode$null;
		case 'Error':
			var err = body.a;
			return $elm$json$Json$Encode$string(err);
		case 'Text':
			var w = body.a;
			return $elm$json$Json$Encode$string(w);
		case 'Json':
			var j = body.a;
			return j;
		default:
			var v = body.b;
			return $elm$json$Json$Encode$string(v);
	}
};
var $elm$json$Json$Encode$object = function (pairs) {
	return _Json_wrap(
		A3(
			$elm$core$List$foldl,
			F2(
				function (_v0, obj) {
					var k = _v0.a;
					var v = _v0.b;
					return A3(_Json_addField, k, v, obj);
				}),
			_Json_emptyObject(_Utils_Tuple0),
			pairs));
};
var $author$project$Http$KeyValueList$encode = function (params) {
	return $elm$json$Json$Encode$object(
		A2(
			$elm$core$List$map,
			function (_v0) {
				var a = _v0.a;
				var b = _v0.b;
				return _Utils_Tuple2(
					a,
					$elm$json$Json$Encode$string(b));
			},
			$elm$core$List$reverse(params)));
};
var $elm$json$Json$Encode$int = _Json_wrap;
var $author$project$Http$Body$isBase64Encoded = function (body) {
	if (body.$ === 'Binary') {
		return true;
	} else {
		return false;
	}
};
var $author$project$Http$Response$encode = function (_v0) {
	var res = _v0.a;
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'body',
				$author$project$Http$Body$encode(res.body)),
				_Utils_Tuple2(
				'headers',
				$author$project$Http$KeyValueList$encode(
					_Utils_ap(
						res.headers,
						_List_fromArray(
							[
								_Utils_Tuple2(
								'content-type',
								$author$project$Http$Response$contentType(res))
							])))),
				_Utils_Tuple2(
				'statusCode',
				$elm$json$Json$Encode$int(res.status)),
				_Utils_Tuple2(
				'isBase64Encoded',
				$elm$json$Json$Encode$bool(
					$author$project$Http$Body$isBase64Encoded(res.body)))
			]));
};
var $author$project$HttpServer$responseCmd = F3(
	function (protocol, _v0, response) {
		var session = _v0.a;
		return protocol.ports.response(
			{
				res: $author$project$Http$Response$encode(response),
				session: session
			});
	});
var $author$project$HttpServer$httpServerApi = function (protocol) {
	return {
		request: $author$project$HttpServer$requestSub(protocol),
		response: $author$project$HttpServer$responseCmd(protocol)
	};
};
var $author$project$Ports$requestPort = _Platform_incomingPort(
	'requestPort',
	A2(
		$elm$json$Json$Decode$andThen,
		function (session) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (req) {
					return $elm$json$Json$Decode$succeed(
						{req: req, session: session});
				},
				A2($elm$json$Json$Decode$field, 'req', $elm$json$Json$Decode$value));
		},
		A2($elm$json$Json$Decode$field, 'session', $elm$json$Json$Decode$value)));
var $author$project$Ports$responsePort = _Platform_outgoingPort(
	'responsePort',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'res',
					$elm$core$Basics$identity($.res)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session))
				]));
	});
var $author$project$EventLog$Route$Channel = function (a) {
	return {$: 'Channel', a: a};
};
var $author$project$EventLog$Route$ChannelJoin = function (a) {
	return {$: 'ChannelJoin', a: a};
};
var $author$project$EventLog$Route$ChannelRoot = {$: 'ChannelRoot'};
var $elm$url$Url$Parser$Parser = function (a) {
	return {$: 'Parser', a: a};
};
var $elm$url$Url$Parser$State = F5(
	function (visited, unvisited, params, frag, value) {
		return {frag: frag, params: params, unvisited: unvisited, value: value, visited: visited};
	});
var $elm$url$Url$Parser$mapState = F2(
	function (func, _v0) {
		var visited = _v0.visited;
		var unvisited = _v0.unvisited;
		var params = _v0.params;
		var frag = _v0.frag;
		var value = _v0.value;
		return A5(
			$elm$url$Url$Parser$State,
			visited,
			unvisited,
			params,
			frag,
			func(value));
	});
var $elm$url$Url$Parser$map = F2(
	function (subValue, _v0) {
		var parseArg = _v0.a;
		return $elm$url$Url$Parser$Parser(
			function (_v1) {
				var visited = _v1.visited;
				var unvisited = _v1.unvisited;
				var params = _v1.params;
				var frag = _v1.frag;
				var value = _v1.value;
				return A2(
					$elm$core$List$map,
					$elm$url$Url$Parser$mapState(value),
					parseArg(
						A5($elm$url$Url$Parser$State, visited, unvisited, params, frag, subValue)));
			});
	});
var $elm$core$List$append = F2(
	function (xs, ys) {
		if (!ys.b) {
			return xs;
		} else {
			return A3($elm$core$List$foldr, $elm$core$List$cons, ys, xs);
		}
	});
var $elm$core$List$concat = function (lists) {
	return A3($elm$core$List$foldr, $elm$core$List$append, _List_Nil, lists);
};
var $elm$core$List$concatMap = F2(
	function (f, list) {
		return $elm$core$List$concat(
			A2($elm$core$List$map, f, list));
	});
var $elm$url$Url$Parser$oneOf = function (parsers) {
	return $elm$url$Url$Parser$Parser(
		function (state) {
			return A2(
				$elm$core$List$concatMap,
				function (_v0) {
					var parser = _v0.a;
					return parser(state);
				},
				parsers);
		});
};
var $elm$url$Url$Parser$getFirstMatch = function (states) {
	getFirstMatch:
	while (true) {
		if (!states.b) {
			return $elm$core$Maybe$Nothing;
		} else {
			var state = states.a;
			var rest = states.b;
			var _v1 = state.unvisited;
			if (!_v1.b) {
				return $elm$core$Maybe$Just(state.value);
			} else {
				if ((_v1.a === '') && (!_v1.b.b)) {
					return $elm$core$Maybe$Just(state.value);
				} else {
					var $temp$states = rest;
					states = $temp$states;
					continue getFirstMatch;
				}
			}
		}
	}
};
var $elm$url$Url$Parser$removeFinalEmpty = function (segments) {
	if (!segments.b) {
		return _List_Nil;
	} else {
		if ((segments.a === '') && (!segments.b.b)) {
			return _List_Nil;
		} else {
			var segment = segments.a;
			var rest = segments.b;
			return A2(
				$elm$core$List$cons,
				segment,
				$elm$url$Url$Parser$removeFinalEmpty(rest));
		}
	}
};
var $elm$url$Url$Parser$preparePath = function (path) {
	var _v0 = A2($elm$core$String$split, '/', path);
	if (_v0.b && (_v0.a === '')) {
		var segments = _v0.b;
		return $elm$url$Url$Parser$removeFinalEmpty(segments);
	} else {
		var segments = _v0;
		return $elm$url$Url$Parser$removeFinalEmpty(segments);
	}
};
var $elm$url$Url$Parser$addToParametersHelp = F2(
	function (value, maybeList) {
		if (maybeList.$ === 'Nothing') {
			return $elm$core$Maybe$Just(
				_List_fromArray(
					[value]));
		} else {
			var list = maybeList.a;
			return $elm$core$Maybe$Just(
				A2($elm$core$List$cons, value, list));
		}
	});
var $elm$url$Url$percentDecode = _Url_percentDecode;
var $elm$core$Dict$getMin = function (dict) {
	getMin:
	while (true) {
		if ((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) {
			var left = dict.d;
			var $temp$dict = left;
			dict = $temp$dict;
			continue getMin;
		} else {
			return dict;
		}
	}
};
var $elm$core$Dict$moveRedLeft = function (dict) {
	if (((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) && (dict.e.$ === 'RBNode_elm_builtin')) {
		if ((dict.e.d.$ === 'RBNode_elm_builtin') && (dict.e.d.a.$ === 'Red')) {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v1 = dict.d;
			var lClr = _v1.a;
			var lK = _v1.b;
			var lV = _v1.c;
			var lLeft = _v1.d;
			var lRight = _v1.e;
			var _v2 = dict.e;
			var rClr = _v2.a;
			var rK = _v2.b;
			var rV = _v2.c;
			var rLeft = _v2.d;
			var _v3 = rLeft.a;
			var rlK = rLeft.b;
			var rlV = rLeft.c;
			var rlL = rLeft.d;
			var rlR = rLeft.e;
			var rRight = _v2.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				$elm$core$Dict$Red,
				rlK,
				rlV,
				A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					rlL),
				A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, rK, rV, rlR, rRight));
		} else {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v4 = dict.d;
			var lClr = _v4.a;
			var lK = _v4.b;
			var lV = _v4.c;
			var lLeft = _v4.d;
			var lRight = _v4.e;
			var _v5 = dict.e;
			var rClr = _v5.a;
			var rK = _v5.b;
			var rV = _v5.c;
			var rLeft = _v5.d;
			var rRight = _v5.e;
			if (clr.$ === 'Black') {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			}
		}
	} else {
		return dict;
	}
};
var $elm$core$Dict$moveRedRight = function (dict) {
	if (((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) && (dict.e.$ === 'RBNode_elm_builtin')) {
		if ((dict.d.d.$ === 'RBNode_elm_builtin') && (dict.d.d.a.$ === 'Red')) {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v1 = dict.d;
			var lClr = _v1.a;
			var lK = _v1.b;
			var lV = _v1.c;
			var _v2 = _v1.d;
			var _v3 = _v2.a;
			var llK = _v2.b;
			var llV = _v2.c;
			var llLeft = _v2.d;
			var llRight = _v2.e;
			var lRight = _v1.e;
			var _v4 = dict.e;
			var rClr = _v4.a;
			var rK = _v4.b;
			var rV = _v4.c;
			var rLeft = _v4.d;
			var rRight = _v4.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				$elm$core$Dict$Red,
				lK,
				lV,
				A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, llK, llV, llLeft, llRight),
				A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					lRight,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight)));
		} else {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v5 = dict.d;
			var lClr = _v5.a;
			var lK = _v5.b;
			var lV = _v5.c;
			var lLeft = _v5.d;
			var lRight = _v5.e;
			var _v6 = dict.e;
			var rClr = _v6.a;
			var rK = _v6.b;
			var rV = _v6.c;
			var rLeft = _v6.d;
			var rRight = _v6.e;
			if (clr.$ === 'Black') {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			}
		}
	} else {
		return dict;
	}
};
var $elm$core$Dict$removeHelpPrepEQGT = F7(
	function (targetKey, dict, color, key, value, left, right) {
		if ((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Red')) {
			var _v1 = left.a;
			var lK = left.b;
			var lV = left.c;
			var lLeft = left.d;
			var lRight = left.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				color,
				lK,
				lV,
				lLeft,
				A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, key, value, lRight, right));
		} else {
			_v2$2:
			while (true) {
				if ((right.$ === 'RBNode_elm_builtin') && (right.a.$ === 'Black')) {
					if (right.d.$ === 'RBNode_elm_builtin') {
						if (right.d.a.$ === 'Black') {
							var _v3 = right.a;
							var _v4 = right.d;
							var _v5 = _v4.a;
							return $elm$core$Dict$moveRedRight(dict);
						} else {
							break _v2$2;
						}
					} else {
						var _v6 = right.a;
						var _v7 = right.d;
						return $elm$core$Dict$moveRedRight(dict);
					}
				} else {
					break _v2$2;
				}
			}
			return dict;
		}
	});
var $elm$core$Dict$removeMin = function (dict) {
	if ((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) {
		var color = dict.a;
		var key = dict.b;
		var value = dict.c;
		var left = dict.d;
		var lColor = left.a;
		var lLeft = left.d;
		var right = dict.e;
		if (lColor.$ === 'Black') {
			if ((lLeft.$ === 'RBNode_elm_builtin') && (lLeft.a.$ === 'Red')) {
				var _v3 = lLeft.a;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					color,
					key,
					value,
					$elm$core$Dict$removeMin(left),
					right);
			} else {
				var _v4 = $elm$core$Dict$moveRedLeft(dict);
				if (_v4.$ === 'RBNode_elm_builtin') {
					var nColor = _v4.a;
					var nKey = _v4.b;
					var nValue = _v4.c;
					var nLeft = _v4.d;
					var nRight = _v4.e;
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						$elm$core$Dict$removeMin(nLeft),
						nRight);
				} else {
					return $elm$core$Dict$RBEmpty_elm_builtin;
				}
			}
		} else {
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				color,
				key,
				value,
				$elm$core$Dict$removeMin(left),
				right);
		}
	} else {
		return $elm$core$Dict$RBEmpty_elm_builtin;
	}
};
var $elm$core$Dict$removeHelp = F2(
	function (targetKey, dict) {
		if (dict.$ === 'RBEmpty_elm_builtin') {
			return $elm$core$Dict$RBEmpty_elm_builtin;
		} else {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			if (_Utils_cmp(targetKey, key) < 0) {
				if ((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Black')) {
					var _v4 = left.a;
					var lLeft = left.d;
					if ((lLeft.$ === 'RBNode_elm_builtin') && (lLeft.a.$ === 'Red')) {
						var _v6 = lLeft.a;
						return A5(
							$elm$core$Dict$RBNode_elm_builtin,
							color,
							key,
							value,
							A2($elm$core$Dict$removeHelp, targetKey, left),
							right);
					} else {
						var _v7 = $elm$core$Dict$moveRedLeft(dict);
						if (_v7.$ === 'RBNode_elm_builtin') {
							var nColor = _v7.a;
							var nKey = _v7.b;
							var nValue = _v7.c;
							var nLeft = _v7.d;
							var nRight = _v7.e;
							return A5(
								$elm$core$Dict$balance,
								nColor,
								nKey,
								nValue,
								A2($elm$core$Dict$removeHelp, targetKey, nLeft),
								nRight);
						} else {
							return $elm$core$Dict$RBEmpty_elm_builtin;
						}
					}
				} else {
					return A5(
						$elm$core$Dict$RBNode_elm_builtin,
						color,
						key,
						value,
						A2($elm$core$Dict$removeHelp, targetKey, left),
						right);
				}
			} else {
				return A2(
					$elm$core$Dict$removeHelpEQGT,
					targetKey,
					A7($elm$core$Dict$removeHelpPrepEQGT, targetKey, dict, color, key, value, left, right));
			}
		}
	});
var $elm$core$Dict$removeHelpEQGT = F2(
	function (targetKey, dict) {
		if (dict.$ === 'RBNode_elm_builtin') {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			if (_Utils_eq(targetKey, key)) {
				var _v1 = $elm$core$Dict$getMin(right);
				if (_v1.$ === 'RBNode_elm_builtin') {
					var minKey = _v1.b;
					var minValue = _v1.c;
					return A5(
						$elm$core$Dict$balance,
						color,
						minKey,
						minValue,
						left,
						$elm$core$Dict$removeMin(right));
				} else {
					return $elm$core$Dict$RBEmpty_elm_builtin;
				}
			} else {
				return A5(
					$elm$core$Dict$balance,
					color,
					key,
					value,
					left,
					A2($elm$core$Dict$removeHelp, targetKey, right));
			}
		} else {
			return $elm$core$Dict$RBEmpty_elm_builtin;
		}
	});
var $elm$core$Dict$remove = F2(
	function (key, dict) {
		var _v0 = A2($elm$core$Dict$removeHelp, key, dict);
		if ((_v0.$ === 'RBNode_elm_builtin') && (_v0.a.$ === 'Red')) {
			var _v1 = _v0.a;
			var k = _v0.b;
			var v = _v0.c;
			var l = _v0.d;
			var r = _v0.e;
			return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, k, v, l, r);
		} else {
			var x = _v0;
			return x;
		}
	});
var $elm$core$Dict$update = F3(
	function (targetKey, alter, dictionary) {
		var _v0 = alter(
			A2($elm$core$Dict$get, targetKey, dictionary));
		if (_v0.$ === 'Just') {
			var value = _v0.a;
			return A3($elm$core$Dict$insert, targetKey, value, dictionary);
		} else {
			return A2($elm$core$Dict$remove, targetKey, dictionary);
		}
	});
var $elm$url$Url$Parser$addParam = F2(
	function (segment, dict) {
		var _v0 = A2($elm$core$String$split, '=', segment);
		if ((_v0.b && _v0.b.b) && (!_v0.b.b.b)) {
			var rawKey = _v0.a;
			var _v1 = _v0.b;
			var rawValue = _v1.a;
			var _v2 = $elm$url$Url$percentDecode(rawKey);
			if (_v2.$ === 'Nothing') {
				return dict;
			} else {
				var key = _v2.a;
				var _v3 = $elm$url$Url$percentDecode(rawValue);
				if (_v3.$ === 'Nothing') {
					return dict;
				} else {
					var value = _v3.a;
					return A3(
						$elm$core$Dict$update,
						key,
						$elm$url$Url$Parser$addToParametersHelp(value),
						dict);
				}
			}
		} else {
			return dict;
		}
	});
var $elm$url$Url$Parser$prepareQuery = function (maybeQuery) {
	if (maybeQuery.$ === 'Nothing') {
		return $elm$core$Dict$empty;
	} else {
		var qry = maybeQuery.a;
		return A3(
			$elm$core$List$foldr,
			$elm$url$Url$Parser$addParam,
			$elm$core$Dict$empty,
			A2($elm$core$String$split, '&', qry));
	}
};
var $elm$url$Url$Parser$parse = F2(
	function (_v0, url) {
		var parser = _v0.a;
		return $elm$url$Url$Parser$getFirstMatch(
			parser(
				A5(
					$elm$url$Url$Parser$State,
					_List_Nil,
					$elm$url$Url$Parser$preparePath(url.path),
					$elm$url$Url$Parser$prepareQuery(url.query),
					url.fragment,
					$elm$core$Basics$identity)));
	});
var $elm$url$Url$Parser$s = function (str) {
	return $elm$url$Url$Parser$Parser(
		function (_v0) {
			var visited = _v0.visited;
			var unvisited = _v0.unvisited;
			var params = _v0.params;
			var frag = _v0.frag;
			var value = _v0.value;
			if (!unvisited.b) {
				return _List_Nil;
			} else {
				var next = unvisited.a;
				var rest = unvisited.b;
				return _Utils_eq(next, str) ? _List_fromArray(
					[
						A5(
						$elm$url$Url$Parser$State,
						A2($elm$core$List$cons, next, visited),
						rest,
						params,
						frag,
						value)
					]) : _List_Nil;
			}
		});
};
var $elm$url$Url$Parser$slash = F2(
	function (_v0, _v1) {
		var parseBefore = _v0.a;
		var parseAfter = _v1.a;
		return $elm$url$Url$Parser$Parser(
			function (state) {
				return A2(
					$elm$core$List$concatMap,
					parseAfter,
					parseBefore(state));
			});
	});
var $elm$url$Url$Parser$custom = F2(
	function (tipe, stringToSomething) {
		return $elm$url$Url$Parser$Parser(
			function (_v0) {
				var visited = _v0.visited;
				var unvisited = _v0.unvisited;
				var params = _v0.params;
				var frag = _v0.frag;
				var value = _v0.value;
				if (!unvisited.b) {
					return _List_Nil;
				} else {
					var next = unvisited.a;
					var rest = unvisited.b;
					var _v2 = stringToSomething(next);
					if (_v2.$ === 'Just') {
						var nextValue = _v2.a;
						return _List_fromArray(
							[
								A5(
								$elm$url$Url$Parser$State,
								A2($elm$core$List$cons, next, visited),
								rest,
								params,
								frag,
								value(nextValue))
							]);
					} else {
						return _List_Nil;
					}
				}
			});
	});
var $elm$url$Url$Parser$string = A2($elm$url$Url$Parser$custom, 'STRING', $elm$core$Maybe$Just);
var $author$project$EventLog$Route$routeParser = $elm$url$Url$Parser$parse(
	$elm$url$Url$Parser$oneOf(
		_List_fromArray(
			[
				A2(
				$elm$url$Url$Parser$map,
				$author$project$EventLog$Route$ChannelRoot,
				$elm$url$Url$Parser$s('channel')),
				A2(
				$elm$url$Url$Parser$map,
				$author$project$EventLog$Route$Channel,
				A2(
					$elm$url$Url$Parser$slash,
					$elm$url$Url$Parser$s('channel'),
					$elm$url$Url$Parser$string)),
				A2(
				$elm$url$Url$Parser$map,
				$author$project$EventLog$Route$ChannelJoin,
				A2(
					$elm$url$Url$Parser$slash,
					$elm$url$Url$Parser$s('channel'),
					A2(
						$elm$url$Url$Parser$slash,
						$elm$url$Url$Parser$string,
						$elm$url$Url$Parser$s('join'))))
			])));
var $author$project$EventLog$Apis$httpServerApi = $author$project$HttpServer$httpServerApi(
	{
		parseRoute: $author$project$EventLog$Route$routeParser,
		ports: {request: $author$project$Ports$requestPort, response: $author$project$Ports$responsePort}
	});
var $author$project$EventLog$Msg$ProcedureMsg = function (a) {
	return {$: 'ProcedureMsg', a: a};
};
var $author$project$Ports$mmAsyncError = _Platform_incomingPort(
	'mmAsyncError',
	A2(
		$elm$json$Json$Decode$andThen,
		function (id) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (error) {
					return $elm$json$Json$Decode$succeed(
						{error: error, id: id});
				},
				A2($elm$json$Json$Decode$field, 'error', $elm$json$Json$Decode$value));
		},
		A2($elm$json$Json$Decode$field, 'id', $elm$json$Json$Decode$string)));
var $author$project$Ports$mmClose = _Platform_outgoingPort(
	'mmClose',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session))
				]));
	});
var $author$project$Ports$mmCreateWebhook = _Platform_outgoingPort(
	'mmCreateWebhook',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'name',
					$elm$json$Json$Encode$string($.name)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session)),
					_Utils_Tuple2(
					'topic',
					$elm$json$Json$Encode$string($.topic)),
					_Utils_Tuple2(
					'url',
					$elm$json$Json$Encode$string($.url))
				]));
	});
var $author$project$Ports$mmOnMessage = _Platform_incomingPort(
	'mmOnMessage',
	A2(
		$elm$json$Json$Decode$andThen,
		function (session) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (payload) {
					return A2(
						$elm$json$Json$Decode$andThen,
						function (id) {
							return $elm$json$Json$Decode$succeed(
								{id: id, payload: payload, session: session});
						},
						A2($elm$json$Json$Decode$field, 'id', $elm$json$Json$Decode$string));
				},
				A2($elm$json$Json$Decode$field, 'payload', $elm$json$Json$Decode$value));
		},
		A2($elm$json$Json$Decode$field, 'session', $elm$json$Json$Decode$value)));
var $author$project$Ports$mmOpen = _Platform_outgoingPort(
	'mmOpen',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'apiKey',
					$elm$json$Json$Encode$string($.apiKey)),
					_Utils_Tuple2(
					'cache',
					$elm$json$Json$Encode$string($.cache)),
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id))
				]));
	});
var $author$project$Ports$mmPopList = _Platform_outgoingPort(
	'mmPopList',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'list',
					$elm$json$Json$Encode$string($.list)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session))
				]));
	});
var $author$project$Ports$mmPublish = _Platform_outgoingPort(
	'mmPublish',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'payload',
					$elm$core$Basics$identity($.payload)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session)),
					_Utils_Tuple2(
					'topic',
					$elm$json$Json$Encode$string($.topic))
				]));
	});
var $author$project$Ports$mmPushList = _Platform_outgoingPort(
	'mmPushList',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'list',
					$elm$json$Json$Encode$string($.list)),
					_Utils_Tuple2(
					'payload',
					$elm$core$Basics$identity($.payload)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session))
				]));
	});
var $author$project$Ports$mmResponse = _Platform_incomingPort(
	'mmResponse',
	A2(
		$elm$json$Json$Decode$andThen,
		function (type_) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (response) {
					return A2(
						$elm$json$Json$Decode$andThen,
						function (id) {
							return $elm$json$Json$Decode$succeed(
								{id: id, response: response, type_: type_});
						},
						A2($elm$json$Json$Decode$field, 'id', $elm$json$Json$Decode$string));
				},
				A2($elm$json$Json$Decode$field, 'response', $elm$json$Json$Decode$value));
		},
		A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string)));
var $author$project$Ports$mmSubscribe = _Platform_outgoingPort(
	'mmSubscribe',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'session',
					$elm$core$Basics$identity($.session)),
					_Utils_Tuple2(
					'topic',
					$elm$json$Json$Encode$string($.topic))
				]));
	});
var $author$project$Momento$MomentoError = function (a) {
	return {$: 'MomentoError', a: a};
};
var $author$project$Momento$asyncError = F2(
	function (ports, dt) {
		return ports.asyncError(
			function (_v0) {
				var error = _v0.error;
				return dt(
					$author$project$Momento$MomentoError(
						{details: error, message: 'MomentoPorts Async Error'}));
			});
	});
var $elm$core$Debug$log = _Debug_log;
var $author$project$Momento$onMessage = F2(
	function (ports, dt) {
		return ports.onMessage(
			function (_v0) {
				var session = _v0.session;
				var payload = _v0.payload;
				var _v1 = A2($elm$core$Debug$log, 'Momento.onMessage', 'called');
				return dt(payload);
			});
	});
var $brian_watkins$elm_procedure$Procedure$Internal$Continue = {$: 'Continue'};
var $brian_watkins$elm_procedure$Procedure$Internal$Execute = F2(
	function (a, b) {
		return {$: 'Execute', a: a, b: b};
	});
var $brian_watkins$elm_procedure$Procedure$Internal$Procedure = function (a) {
	return {$: 'Procedure', a: a};
};
var $brian_watkins$elm_procedure$Procedure$Internal$Subscribe = F3(
	function (a, b, c) {
		return {$: 'Subscribe', a: a, b: b, c: c};
	});
var $brian_watkins$elm_procedure$Procedure$Internal$Unsubscribe = F3(
	function (a, b, c) {
		return {$: 'Unsubscribe', a: a, b: b, c: c};
	});
var $brian_watkins$elm_procedure$Procedure$Channel$channelKey = function (channelId) {
	return 'Channel-' + $elm$core$String$fromInt(channelId);
};
var $elm$core$Task$Perform = function (a) {
	return {$: 'Perform', a: a};
};
var $elm$core$Task$init = $elm$core$Task$succeed(_Utils_Tuple0);
var $elm$core$Task$map = F2(
	function (func, taskA) {
		return A2(
			$elm$core$Task$andThen,
			function (a) {
				return $elm$core$Task$succeed(
					func(a));
			},
			taskA);
	});
var $elm$core$Task$map2 = F3(
	function (func, taskA, taskB) {
		return A2(
			$elm$core$Task$andThen,
			function (a) {
				return A2(
					$elm$core$Task$andThen,
					function (b) {
						return $elm$core$Task$succeed(
							A2(func, a, b));
					},
					taskB);
			},
			taskA);
	});
var $elm$core$Task$sequence = function (tasks) {
	return A3(
		$elm$core$List$foldr,
		$elm$core$Task$map2($elm$core$List$cons),
		$elm$core$Task$succeed(_List_Nil),
		tasks);
};
var $elm$core$Task$spawnCmd = F2(
	function (router, _v0) {
		var task = _v0.a;
		return _Scheduler_spawn(
			A2(
				$elm$core$Task$andThen,
				$elm$core$Platform$sendToApp(router),
				task));
	});
var $elm$core$Task$onEffects = F3(
	function (router, commands, state) {
		return A2(
			$elm$core$Task$map,
			function (_v0) {
				return _Utils_Tuple0;
			},
			$elm$core$Task$sequence(
				A2(
					$elm$core$List$map,
					$elm$core$Task$spawnCmd(router),
					commands)));
	});
var $elm$core$Task$onSelfMsg = F3(
	function (_v0, _v1, _v2) {
		return $elm$core$Task$succeed(_Utils_Tuple0);
	});
var $elm$core$Task$cmdMap = F2(
	function (tagger, _v0) {
		var task = _v0.a;
		return $elm$core$Task$Perform(
			A2($elm$core$Task$map, tagger, task));
	});
_Platform_effectManagers['Task'] = _Platform_createManager($elm$core$Task$init, $elm$core$Task$onEffects, $elm$core$Task$onSelfMsg, $elm$core$Task$cmdMap);
var $elm$core$Task$command = _Platform_leaf('Task');
var $elm$core$Task$perform = F2(
	function (toMessage, task) {
		return $elm$core$Task$command(
			$elm$core$Task$Perform(
				A2($elm$core$Task$map, toMessage, task)));
	});
var $brian_watkins$elm_procedure$Procedure$Channel$acceptUntil = F2(
	function (shouldUnsubscribe, _v0) {
		var channel = _v0.a;
		return $brian_watkins$elm_procedure$Procedure$Internal$Procedure(
			F3(
				function (procId, msgTagger, resultTagger) {
					var requestCommandMsg = function (channelId) {
						return A3(
							$elm$core$Basics$composeL,
							msgTagger,
							$brian_watkins$elm_procedure$Procedure$Internal$Execute(procId),
							channel.request(
								$brian_watkins$elm_procedure$Procedure$Channel$channelKey(channelId)));
					};
					var generateMsg = F2(
						function (channelId, aData) {
							return shouldUnsubscribe(aData) ? A3(
								$elm$core$Basics$composeL,
								msgTagger,
								A2($brian_watkins$elm_procedure$Procedure$Internal$Unsubscribe, procId, channelId),
								resultTagger(
									$elm$core$Result$Ok(aData))) : resultTagger(
								$elm$core$Result$Ok(aData));
						});
					var subGenerator = function (channelId) {
						return channel.subscription(
							function (aData) {
								return A2(
									channel.shouldAccept,
									$brian_watkins$elm_procedure$Procedure$Channel$channelKey(channelId),
									aData) ? A2(generateMsg, channelId, aData) : msgTagger($brian_watkins$elm_procedure$Procedure$Internal$Continue);
							});
					};
					return A2(
						$elm$core$Task$perform,
						A2(
							$elm$core$Basics$composeL,
							msgTagger,
							A2($brian_watkins$elm_procedure$Procedure$Internal$Subscribe, procId, requestCommandMsg)),
						$elm$core$Task$succeed(subGenerator));
				}));
	});
var $elm$core$Basics$always = F2(
	function (a, _v0) {
		return a;
	});
var $brian_watkins$elm_procedure$Procedure$Channel$acceptOne = $brian_watkins$elm_procedure$Procedure$Channel$acceptUntil(
	$elm$core$Basics$always(true));
var $brian_watkins$elm_procedure$Procedure$Channel$Channel = function (a) {
	return {$: 'Channel', a: a};
};
var $brian_watkins$elm_procedure$Procedure$Channel$defaultPredicate = F2(
	function (_v0, _v1) {
		return true;
	});
var $brian_watkins$elm_procedure$Procedure$Channel$connect = F2(
	function (generator, _v0) {
		var requestGenerator = _v0.a;
		return $brian_watkins$elm_procedure$Procedure$Channel$Channel(
			{request: requestGenerator, shouldAccept: $brian_watkins$elm_procedure$Procedure$Channel$defaultPredicate, subscription: generator});
	});
var $author$project$Momento$MomentoSessionKey = function (a) {
	return {$: 'MomentoSessionKey', a: a};
};
var $author$project$Momento$decodeResponseWithSessionKey = function (res) {
	var _v0 = res.type_;
	switch (_v0) {
		case 'Ok':
			return $elm$core$Result$Ok(
				$author$project$Momento$MomentoSessionKey(res.response));
		case 'Error':
			return $elm$core$Result$Err(
				$author$project$Momento$MomentoError(
					{details: res.response, message: 'MomentoError'}));
		default:
			return $elm$core$Result$Err(
				$author$project$Momento$MomentoError(
					{details: $elm$json$Json$Encode$null, message: 'Momento Unknown response type: ' + res.type_}));
	}
};
var $brian_watkins$elm_procedure$Procedure$Channel$filter = F2(
	function (predicate, _v0) {
		var channel = _v0.a;
		return $brian_watkins$elm_procedure$Procedure$Channel$Channel(
			_Utils_update(
				channel,
				{shouldAccept: predicate}));
	});
var $brian_watkins$elm_procedure$Procedure$Channel$ChannelRequest = function (a) {
	return {$: 'ChannelRequest', a: a};
};
var $brian_watkins$elm_procedure$Procedure$Channel$open = $brian_watkins$elm_procedure$Procedure$Channel$ChannelRequest;
var $elm$core$Basics$never = function (_v0) {
	never:
	while (true) {
		var nvr = _v0.a;
		var $temp$_v0 = nvr;
		_v0 = $temp$_v0;
		continue never;
	}
};
var $brian_watkins$elm_procedure$Procedure$Internal$Initiate = function (a) {
	return {$: 'Initiate', a: a};
};
var $brian_watkins$elm_procedure$Procedure$try = F3(
	function (msgTagger, tagger, _v0) {
		var procedure = _v0.a;
		return A2(
			$elm$core$Task$perform,
			A2($elm$core$Basics$composeL, msgTagger, $brian_watkins$elm_procedure$Procedure$Internal$Initiate),
			$elm$core$Task$succeed(
				function (procId) {
					return A3(procedure, procId, msgTagger, tagger);
				}));
	});
var $brian_watkins$elm_procedure$Procedure$run = F2(
	function (msgTagger, tagger) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$try,
			msgTagger,
			function (result) {
				if (result.$ === 'Ok') {
					var data = result.a;
					return tagger(data);
				} else {
					var e = result.a;
					return $elm$core$Basics$never(e);
				}
			});
	});
var $author$project$Momento$open = F4(
	function (pt, ports, openParams, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (res) {
				return dt(
					$author$project$Momento$decodeResponseWithSessionKey(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.open(
									{apiKey: openParams.apiKey, cache: openParams.cache, id: key});
							})))));
	});
var $author$project$Momento$decodeItemResponse = function (res) {
	var _v0 = res.type_;
	switch (_v0) {
		case 'Item':
			return $elm$core$Result$Ok(
				$elm$core$Maybe$Just(
					{payload: res.response}));
		case 'ItemNotFound':
			return $elm$core$Result$Ok($elm$core$Maybe$Nothing);
		case 'Error':
			return $elm$core$Result$Err(
				$author$project$Momento$MomentoError(
					{details: res.response, message: 'MomentoError'}));
		default:
			return $elm$core$Result$Err(
				$author$project$Momento$MomentoError(
					{details: $elm$json$Json$Encode$null, message: 'Momento Unknown response type: ' + res.type_}));
	}
};
var $author$project$Momento$popList = F5(
	function (pt, ports, _v0, _v1, dt) {
		var sessionKey = _v0.a;
		var list = _v1.list;
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (res) {
				return dt(
					$author$project$Momento$decodeItemResponse(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v2) {
							var id = _v2.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.popList(
									{id: key, list: list, session: sessionKey});
							})))));
	});
var $author$project$Momento$decodeResponse = function (res) {
	var _v0 = res.type_;
	switch (_v0) {
		case 'Ok':
			return $elm$core$Result$Ok(_Utils_Tuple0);
		case 'Error':
			return $elm$core$Result$Err(
				$author$project$Momento$MomentoError(
					{details: res.response, message: 'MomentoError'}));
		default:
			return $elm$core$Result$Err(
				$author$project$Momento$MomentoError(
					{details: $elm$json$Json$Encode$null, message: 'Momento Unknown response type: ' + res.type_}));
	}
};
var $author$project$Momento$publish = F5(
	function (pt, ports, _v0, _v1, dt) {
		var sessionKey = _v0.a;
		var topic = _v1.topic;
		var payload = _v1.payload;
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (res) {
				return dt(
					$author$project$Momento$decodeResponse(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v2) {
							var id = _v2.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.publish(
									{id: key, payload: payload, session: sessionKey, topic: topic});
							})))));
	});
var $author$project$Momento$pushList = F5(
	function (pt, ports, _v0, _v1, dt) {
		var sessionKey = _v0.a;
		var list = _v1.list;
		var payload = _v1.payload;
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (res) {
				return dt(
					$author$project$Momento$decodeResponse(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v2) {
							var id = _v2.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.pushList(
									{id: key, list: list, payload: payload, session: sessionKey});
							})))));
	});
var $author$project$Momento$subscribe = F5(
	function (pt, ports, _v0, subscribeParams, dt) {
		var sessionKey = _v0.a;
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (res) {
				return dt(
					$author$project$Momento$decodeResponse(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v1) {
							var id = _v1.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.subscribe(
									{id: key, session: sessionKey, topic: subscribeParams.topic});
							})))));
	});
var $author$project$Momento$webhook = F5(
	function (pt, ports, _v0, _v1, dt) {
		var sessionKey = _v0.a;
		var name = _v1.name;
		var topic = _v1.topic;
		var url = _v1.url;
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (res) {
				return dt(
					$author$project$Momento$decodeResponse(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v2) {
							var id = _v2.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.createWebhook(
									{id: key, name: name, session: sessionKey, topic: topic, url: url});
							})))));
	});
var $author$project$Momento$momentoApi = F2(
	function (pt, ports) {
		return {
			asyncError: $author$project$Momento$asyncError(ports),
			onMessage: $author$project$Momento$onMessage(ports),
			open: A2($author$project$Momento$open, pt, ports),
			popList: A2($author$project$Momento$popList, pt, ports),
			publish: A2($author$project$Momento$publish, pt, ports),
			pushList: A2($author$project$Momento$pushList, pt, ports),
			subscribe: A2($author$project$Momento$subscribe, pt, ports),
			webhook: A2($author$project$Momento$webhook, pt, ports)
		};
	});
var $author$project$EventLog$Apis$momentoApi = A2(
	$author$project$Momento$momentoApi,
	$author$project$EventLog$Msg$ProcedureMsg,
	{asyncError: $author$project$Ports$mmAsyncError, close: $author$project$Ports$mmClose, createWebhook: $author$project$Ports$mmCreateWebhook, onMessage: $author$project$Ports$mmOnMessage, open: $author$project$Ports$mmOpen, popList: $author$project$Ports$mmPopList, publish: $author$project$Ports$mmPublish, pushList: $author$project$Ports$mmPushList, response: $author$project$Ports$mmResponse, subscribe: $author$project$Ports$mmSubscribe});
var $elm$core$Platform$Sub$none = $elm$core$Platform$Sub$batch(_List_Nil);
var $author$project$SqsLambda$InvalidRequestFormat = function (a) {
	return {$: 'InvalidRequestFormat', a: a};
};
var $author$project$SqsLambda$SqsMessage = F2(
	function (messageId, body) {
		return {body: body, messageId: messageId};
	});
var $elm_community$json_extra$Json$Decode$Extra$andMap = $elm$json$Json$Decode$map2($elm$core$Basics$apR);
var $elm$json$Json$Decode$list = _Json_decodeList;
var $author$project$SqsLambda$decodeRequestAndRoute = function (rawRequest) {
	var eventDecoder = A2(
		$elm_community$json_extra$Json$Decode$Extra$andMap,
		A2($elm$json$Json$Decode$field, 'body', $elm$json$Json$Decode$string),
		A2(
			$elm_community$json_extra$Json$Decode$Extra$andMap,
			A2($elm$json$Json$Decode$field, 'messageId', $elm$json$Json$Decode$string),
			$elm$json$Json$Decode$succeed($author$project$SqsLambda$SqsMessage)));
	var decoder = A2(
		$elm$json$Json$Decode$field,
		'Records',
		$elm$json$Json$Decode$list(eventDecoder));
	return A2(
		$elm$core$Result$mapError,
		$author$project$SqsLambda$InvalidRequestFormat,
		A2($elm$json$Json$Decode$decodeValue, decoder, rawRequest));
};
var $author$project$HttpServer$sessionKeyFromCallback = $author$project$HttpServer$HttpSessionKey;
var $author$project$SqsLambda$requestSub = F2(
	function (ports, requestFn) {
		var fn = function (_v0) {
			var session = _v0.session;
			var req = _v0.req;
			return A2(
				requestFn,
				$author$project$HttpServer$sessionKeyFromCallback(session),
				$author$project$SqsLambda$decodeRequestAndRoute(req));
		};
		return A2(
			$elm$core$Platform$Sub$map,
			$elm$core$Basics$identity,
			ports.sqsLambdaSubscribe(fn));
	});
var $author$project$SqsLambda$sqsEventApi = function (ports) {
	return {
		event: $author$project$SqsLambda$requestSub(ports)
	};
};
var $author$project$Ports$sqsLambdaSubscribe = _Platform_incomingPort(
	'sqsLambdaSubscribe',
	A2(
		$elm$json$Json$Decode$andThen,
		function (session) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (req) {
					return $elm$json$Json$Decode$succeed(
						{req: req, session: session});
				},
				A2($elm$json$Json$Decode$field, 'req', $elm$json$Json$Decode$value));
		},
		A2($elm$json$Json$Decode$field, 'session', $elm$json$Json$Decode$value)));
var $author$project$EventLog$Apis$sqsLambdaApi = $author$project$SqsLambda$sqsEventApi(
	{sqsLambdaSubscribe: $author$project$Ports$sqsLambdaSubscribe});
var $elm$core$Dict$values = function (dict) {
	return A3(
		$elm$core$Dict$foldr,
		F3(
			function (key, value, valueList) {
				return A2($elm$core$List$cons, value, valueList);
			}),
		_List_Nil,
		dict);
};
var $brian_watkins$elm_procedure$Procedure$Program$subscriptions = function (_v0) {
	var registry = _v0.a;
	return $elm$core$Platform$Sub$batch(
		$elm$core$Dict$values(registry.channels));
};
var $author$project$EventLog$Component$subscriptions = F2(
	function (protocol, component) {
		var model = component.eventLog;
		if (model.$ === 'ModelReady') {
			var state = model.a;
			return A2(
				$elm$core$Platform$Sub$map,
				protocol.toMsg,
				$elm$core$Platform$Sub$batch(
					_List_fromArray(
						[
							$brian_watkins$elm_procedure$Procedure$Program$subscriptions(state.procedure),
							$author$project$EventLog$Apis$httpServerApi.request($author$project$EventLog$Msg$HttpRequest),
							$author$project$EventLog$Apis$momentoApi.asyncError($author$project$EventLog$Msg$MomentoError),
							$author$project$EventLog$Apis$sqsLambdaApi.event($author$project$EventLog$Msg$SqsEvent)
						])));
		} else {
			return $elm$core$Platform$Sub$none;
		}
	});
var $author$project$API$subscriptions = function (model) {
	return $elm$core$Platform$Sub$batch(
		_List_fromArray(
			[
				A2($author$project$EventLog$Component$subscriptions, $author$project$API$eventLogProtocol, model)
			]));
};
var $author$project$EventLog$Model$ModelReady = function (a) {
	return {$: 'ModelReady', a: a};
};
var $author$project$ErrorFormat$encodeErrorFormat = function (error) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'message',
				$elm$json$Json$Encode$string(error.message)),
				_Utils_Tuple2('details', error.details)
			]));
};
var $author$project$Http$Response$Model = F4(
	function (body, charset, headers, status) {
		return {body: body, charset: charset, headers: headers, status: status};
	});
var $author$project$Http$Response$Response = function (a) {
	return {$: 'Response', a: a};
};
var $author$project$Http$Body$empty = $author$project$Http$Body$Empty;
var $author$project$Http$Charset$Utf8 = {$: 'Utf8'};
var $author$project$Http$Charset$utf8 = $author$project$Http$Charset$Utf8;
var $author$project$Http$Response$init = $author$project$Http$Response$Response(
	A4(
		$author$project$Http$Response$Model,
		$author$project$Http$Body$empty,
		$author$project$Http$Charset$utf8,
		_List_fromArray(
			[
				_Utils_Tuple2('cache-control', 'max-age=0, private, must-revalidate')
			]),
		200));
var $author$project$Http$Response$setBody = F2(
	function (body, _v0) {
		var res = _v0.a;
		return $author$project$Http$Response$Response(
			_Utils_update(
				res,
				{body: body}));
	});
var $author$project$Http$Response$setStatus = F2(
	function (value, _v0) {
		var res = _v0.a;
		return $author$project$Http$Response$Response(
			_Utils_update(
				res,
				{status: value}));
	});
var $author$project$Http$Body$text = $author$project$Http$Body$Text;
var $author$project$Http$Response$err500 = function (err) {
	return A2(
		$author$project$Http$Response$setStatus,
		500,
		A2(
			$author$project$Http$Response$setBody,
			$author$project$Http$Body$text(err),
			$author$project$Http$Response$init));
};
var $author$project$Http$Body$json = $author$project$Http$Body$Json;
var $author$project$Http$Response$err500json = function (err) {
	return A2(
		$author$project$Http$Response$setStatus,
		500,
		A2(
			$author$project$Http$Response$setBody,
			$author$project$Http$Body$json(err),
			$author$project$Http$Response$init));
};
var $author$project$SqsLambda$errorToDetails = function (error) {
	var decodeError = error.a;
	return {
		details: $elm$json$Json$Encode$null,
		message: 'Problem decoding the request: ' + $elm$json$Json$Decode$errorToString(decodeError)
	};
};
var $author$project$HttpServer$errorToString = function (error) {
	if (error.$ === 'NoMatchingRoute') {
		var url = error.a;
		return 'No matching route for: ' + url;
	} else {
		var decodeError = error.a;
		return 'Problem decoding the request: ' + $elm$json$Json$Decode$errorToString(decodeError);
	}
};
var $brian_watkins$elm_procedure$Procedure$Program$Model = function (a) {
	return {$: 'Model', a: a};
};
var $brian_watkins$elm_procedure$Procedure$Program$init = $brian_watkins$elm_procedure$Procedure$Program$Model(
	{channels: $elm$core$Dict$empty, nextId: 0});
var $elm$core$Tuple$mapFirst = F2(
	function (func, _v0) {
		var x = _v0.a;
		var y = _v0.b;
		return _Utils_Tuple2(
			func(x),
			y);
	});
var $elm_community$result_extra$Result$Extra$merge = function (r) {
	if (r.$ === 'Ok') {
		var rr = r.a;
		return rr;
	} else {
		var rr = r.a;
		return rr;
	}
};
var $author$project$EventLog$Msg$HttpResponse = F2(
	function (a, b) {
		return {$: 'HttpResponse', a: a, b: b};
	});
var $elm$core$Task$fail = _Scheduler_fail;
var $elm$core$Task$onError = _Scheduler_onError;
var $elm$core$Task$attempt = F2(
	function (resultToMessage, task) {
		return $elm$core$Task$command(
			$elm$core$Task$Perform(
				A2(
					$elm$core$Task$onError,
					A2(
						$elm$core$Basics$composeL,
						A2($elm$core$Basics$composeL, $elm$core$Task$succeed, resultToMessage),
						$elm$core$Result$Err),
					A2(
						$elm$core$Task$andThen,
						A2(
							$elm$core$Basics$composeL,
							A2($elm$core$Basics$composeL, $elm$core$Task$succeed, resultToMessage),
							$elm$core$Result$Ok),
						task))));
	});
var $brian_watkins$elm_procedure$Procedure$fromTask = function (task) {
	return $brian_watkins$elm_procedure$Procedure$Internal$Procedure(
		F3(
			function (_v0, _v1, resultTagger) {
				return A2($elm$core$Task$attempt, resultTagger, task);
			}));
};
var $brian_watkins$elm_procedure$Procedure$break = A2($elm$core$Basics$composeL, $brian_watkins$elm_procedure$Procedure$fromTask, $elm$core$Task$fail);
var $brian_watkins$elm_procedure$Procedure$next = F2(
	function (_v0, resultMapper) {
		var procedure = _v0.a;
		return $brian_watkins$elm_procedure$Procedure$Internal$Procedure(
			F3(
				function (procId, msgTagger, tagger) {
					return A3(
						procedure,
						procId,
						msgTagger,
						function (aResult) {
							var _v1 = resultMapper(aResult);
							var nextProcedure = _v1.a;
							return A3(
								$elm$core$Basics$composeL,
								msgTagger,
								$brian_watkins$elm_procedure$Procedure$Internal$Execute(procId),
								A3(nextProcedure, procId, msgTagger, tagger));
						});
				}));
	});
var $brian_watkins$elm_procedure$Procedure$andThen = F2(
	function (generator, procedure) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$next,
			procedure,
			function (aResult) {
				if (aResult.$ === 'Ok') {
					var aData = aResult.a;
					return generator(aData);
				} else {
					var eData = aResult.a;
					return $brian_watkins$elm_procedure$Procedure$break(eData);
				}
			});
	});
var $brian_watkins$elm_procedure$Procedure$provide = A2($elm$core$Basics$composeL, $brian_watkins$elm_procedure$Procedure$fromTask, $elm$core$Task$succeed);
var $author$project$EventLog$SnapshotChannel$LaterFound = function (a) {
	return {$: 'LaterFound', a: a};
};
var $author$project$EventLog$SnapshotChannel$New = {$: 'New'};
var $author$project$EventLog$SnapshotChannel$OutOfDate = function (a) {
	return {$: 'OutOfDate', a: a};
};
var $author$project$EventLog$LatestSnapshot$getLatestSnapshotFromCache = F3(
	function (component, channelName, state) {
		var _v0 = A2($elm$core$Debug$log, 'LatestSnapshot.getLatestSnapshotFromCache', 'called');
		return $brian_watkins$elm_procedure$Procedure$provide(
			{
				cache: state.cache,
				maybeLatest: A2($elm$core$Dict$get, channelName, state.cache)
			});
	});
var $author$project$AWS$Dynamo$errorToDetails = function (error) {
	switch (error.$) {
		case 'Error':
			var message = error.a.message;
			var details = error.a.details;
			return {details: details, message: message};
		case 'ConditionCheckFailed':
			var message = error.a.message;
			var details = error.a.details;
			return {details: details, message: message};
		default:
			var err = error.a;
			return {
				details: $elm$json$Json$Encode$null,
				message: $elm$json$Json$Decode$errorToString(err)
			};
	}
};
var $brian_watkins$elm_procedure$Procedure$fetchResult = function (generator) {
	return $brian_watkins$elm_procedure$Procedure$Internal$Procedure(
		F3(
			function (_v0, _v1, tagger) {
				return generator(tagger);
			}));
};
var $brian_watkins$elm_procedure$Procedure$map = function (mapper) {
	return $brian_watkins$elm_procedure$Procedure$andThen(
		A2($elm$core$Basics$composeL, $brian_watkins$elm_procedure$Procedure$provide, mapper));
};
var $brian_watkins$elm_procedure$Procedure$mapError = F2(
	function (mapper, procedure) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$next,
			procedure,
			function (aResult) {
				if (aResult.$ === 'Ok') {
					var aData = aResult.a;
					return $brian_watkins$elm_procedure$Procedure$provide(aData);
				} else {
					var eData = aResult.a;
					return $brian_watkins$elm_procedure$Procedure$break(
						mapper(eData));
				}
			});
	});
var $author$project$Ports$dynamoBatchGet = _Platform_outgoingPort(
	'dynamoBatchGet',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoBatchWrite = _Platform_outgoingPort(
	'dynamoBatchWrite',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoDelete = _Platform_outgoingPort(
	'dynamoDelete',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoGet = _Platform_outgoingPort(
	'dynamoGet',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoPut = _Platform_outgoingPort(
	'dynamoPut',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoQuery = _Platform_outgoingPort(
	'dynamoQuery',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoResponse = _Platform_incomingPort(
	'dynamoResponse',
	A2(
		$elm$json$Json$Decode$andThen,
		function (res) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (id) {
					return $elm$json$Json$Decode$succeed(
						{id: id, res: res});
				},
				A2($elm$json$Json$Decode$field, 'id', $elm$json$Json$Decode$string));
		},
		A2($elm$json$Json$Decode$field, 'res', $elm$json$Json$Decode$value)));
var $author$project$Ports$dynamoScan = _Platform_outgoingPort(
	'dynamoScan',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoUpdate = _Platform_outgoingPort(
	'dynamoUpdate',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$Ports$dynamoWriteTx = _Platform_outgoingPort(
	'dynamoWriteTx',
	function ($) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'id',
					$elm$json$Json$Encode$string($.id)),
					_Utils_Tuple2(
					'req',
					$elm$core$Basics$identity($.req))
				]));
	});
var $author$project$EventLog$Apis$dynamoPorts = {batchGet: $author$project$Ports$dynamoBatchGet, batchWrite: $author$project$Ports$dynamoBatchWrite, _delete: $author$project$Ports$dynamoDelete, get: $author$project$Ports$dynamoGet, put: $author$project$Ports$dynamoPut, query: $author$project$Ports$dynamoQuery, response: $author$project$Ports$dynamoResponse, scan: $author$project$Ports$dynamoScan, update: $author$project$Ports$dynamoUpdate, writeTx: $author$project$Ports$dynamoWriteTx};
var $miniBill$elm_codec$Codec$decoder = function (_v0) {
	var m = _v0.a;
	return m.decoder;
};
var $elm$json$Json$Encode$list = F2(
	function (func, entries) {
		return _Json_wrap(
			A3(
				$elm$core$List$foldl,
				_Json_addEntry(func),
				_Json_emptyArray(_Utils_Tuple0),
				entries));
	});
var $author$project$AWS$Dynamo$batchGetEncoder = F2(
	function (encoder, getOp) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'RequestItems',
					$elm$json$Json$Encode$object(
						_List_fromArray(
							[
								_Utils_Tuple2(
								getOp.tableName,
								$elm$json$Json$Encode$object(
									_List_fromArray(
										[
											_Utils_Tuple2(
											'Keys',
											A2($elm$json$Json$Encode$list, encoder, getOp.keys))
										])))
							])))
				]));
	});
var $author$project$AWS$Dynamo$DecodeError = function (a) {
	return {$: 'DecodeError', a: a};
};
var $elm$json$Json$Decode$at = F2(
	function (fields, decoder) {
		return A3($elm$core$List$foldr, $elm$json$Json$Decode$field, decoder, fields);
	});
var $author$project$AWS$Dynamo$ConditionCheckFailed = function (a) {
	return {$: 'ConditionCheckFailed', a: a};
};
var $author$project$AWS$Dynamo$Error = function (a) {
	return {$: 'Error', a: a};
};
var $author$project$AWS$Dynamo$errorDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (details) {
		return A2(
			$elm$json$Json$Decode$andThen,
			function (type_) {
				if (type_ === 'ConditionCheckFailed') {
					return $elm$json$Json$Decode$succeed(
						$elm$core$Result$Err(
							$author$project$AWS$Dynamo$ConditionCheckFailed(details)));
				} else {
					return $elm$json$Json$Decode$succeed(
						$elm$core$Result$Err(
							$author$project$AWS$Dynamo$Error(details)));
				}
			},
			A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
	},
	A2(
		$elm_community$json_extra$Json$Decode$Extra$andMap,
		A2($elm$json$Json$Decode$field, 'details', $elm$json$Json$Decode$value),
		A2(
			$elm_community$json_extra$Json$Decode$Extra$andMap,
			A2($elm$json$Json$Decode$field, 'message', $elm$json$Json$Decode$string),
			$elm$json$Json$Decode$succeed(
				F2(
					function (message, details) {
						return {details: details, message: message};
					})))));
var $author$project$AWS$Dynamo$batchGetResponseDecoder = F3(
	function (valDecoder, tableName, val) {
		var decoder = A2(
			$elm$json$Json$Decode$andThen,
			function (type_) {
				if (type_ === 'Item') {
					return A2(
						$elm$json$Json$Decode$map,
						$elm$core$Result$Ok,
						A2(
							$elm$json$Json$Decode$at,
							_List_fromArray(
								['item', 'Responses', tableName]),
							$elm$json$Json$Decode$list(valDecoder)));
				} else {
					return $author$project$AWS$Dynamo$errorDecoder;
				}
			},
			A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
		return $elm_community$result_extra$Result$Extra$merge(
			A2(
				$elm$core$Result$mapError,
				A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
				A2($elm$json$Json$Decode$decodeValue, decoder, val)));
	});
var $author$project$AWS$Dynamo$batchGet = F6(
	function (pt, ports, encoder, decoder, batchGetProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v1) {
				var res = _v1.res;
				return dt(
					A3($author$project$AWS$Dynamo$batchGetResponseDecoder, decoder, batchGetProps.tableName, res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.batchWrite(
									{
										id: key,
										req: A2(
											$author$project$AWS$Dynamo$batchGetEncoder,
											encoder,
											{keys: batchGetProps.keys, tableName: batchGetProps.tableName})
									});
							})))));
	});
var $author$project$AWS$Dynamo$batchPutEncoder = F2(
	function (encoder, putOp) {
		var encodeItem = function (item) {
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'PutRequest',
						$elm$json$Json$Encode$object(
							_List_fromArray(
								[
									_Utils_Tuple2(
									'Item',
									encoder(item))
								])))
					]));
		};
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'RequestItems',
					$elm$json$Json$Encode$object(
						_List_fromArray(
							[
								_Utils_Tuple2(
								putOp.tableName,
								A2($elm$json$Json$Encode$list, encodeItem, putOp.items))
							])))
				]));
	});
var $author$project$AWS$Dynamo$batchPutResponseDecoder = function (val) {
	var decoder = A2(
		$elm$json$Json$Decode$andThen,
		function (type_) {
			if (type_ === 'Ok') {
				return $elm$json$Json$Decode$succeed(
					$elm$core$Result$Ok(_Utils_Tuple0));
			} else {
				return $author$project$AWS$Dynamo$errorDecoder;
			}
		},
		A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
	return $elm_community$result_extra$Result$Extra$merge(
		A2(
			$elm$core$Result$mapError,
			A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
			A2($elm$json$Json$Decode$decodeValue, decoder, val)));
};
var $elm$core$List$drop = F2(
	function (n, list) {
		drop:
		while (true) {
			if (n <= 0) {
				return list;
			} else {
				if (!list.b) {
					return list;
				} else {
					var x = list.a;
					var xs = list.b;
					var $temp$n = n - 1,
						$temp$list = xs;
					n = $temp$n;
					list = $temp$list;
					continue drop;
				}
			}
		}
	});
var $elm$core$List$takeReverse = F3(
	function (n, list, kept) {
		takeReverse:
		while (true) {
			if (n <= 0) {
				return kept;
			} else {
				if (!list.b) {
					return kept;
				} else {
					var x = list.a;
					var xs = list.b;
					var $temp$n = n - 1,
						$temp$list = xs,
						$temp$kept = A2($elm$core$List$cons, x, kept);
					n = $temp$n;
					list = $temp$list;
					kept = $temp$kept;
					continue takeReverse;
				}
			}
		}
	});
var $elm$core$List$takeTailRec = F2(
	function (n, list) {
		return $elm$core$List$reverse(
			A3($elm$core$List$takeReverse, n, list, _List_Nil));
	});
var $elm$core$List$takeFast = F3(
	function (ctr, n, list) {
		if (n <= 0) {
			return _List_Nil;
		} else {
			var _v0 = _Utils_Tuple2(n, list);
			_v0$1:
			while (true) {
				_v0$5:
				while (true) {
					if (!_v0.b.b) {
						return list;
					} else {
						if (_v0.b.b.b) {
							switch (_v0.a) {
								case 1:
									break _v0$1;
								case 2:
									var _v2 = _v0.b;
									var x = _v2.a;
									var _v3 = _v2.b;
									var y = _v3.a;
									return _List_fromArray(
										[x, y]);
								case 3:
									if (_v0.b.b.b.b) {
										var _v4 = _v0.b;
										var x = _v4.a;
										var _v5 = _v4.b;
										var y = _v5.a;
										var _v6 = _v5.b;
										var z = _v6.a;
										return _List_fromArray(
											[x, y, z]);
									} else {
										break _v0$5;
									}
								default:
									if (_v0.b.b.b.b && _v0.b.b.b.b.b) {
										var _v7 = _v0.b;
										var x = _v7.a;
										var _v8 = _v7.b;
										var y = _v8.a;
										var _v9 = _v8.b;
										var z = _v9.a;
										var _v10 = _v9.b;
										var w = _v10.a;
										var tl = _v10.b;
										return (ctr > 1000) ? A2(
											$elm$core$List$cons,
											x,
											A2(
												$elm$core$List$cons,
												y,
												A2(
													$elm$core$List$cons,
													z,
													A2(
														$elm$core$List$cons,
														w,
														A2($elm$core$List$takeTailRec, n - 4, tl))))) : A2(
											$elm$core$List$cons,
											x,
											A2(
												$elm$core$List$cons,
												y,
												A2(
													$elm$core$List$cons,
													z,
													A2(
														$elm$core$List$cons,
														w,
														A3($elm$core$List$takeFast, ctr + 1, n - 4, tl)))));
									} else {
										break _v0$5;
									}
							}
						} else {
							if (_v0.a === 1) {
								break _v0$1;
							} else {
								break _v0$5;
							}
						}
					}
				}
				return list;
			}
			var _v1 = _v0.b;
			var x = _v1.a;
			return _List_fromArray(
				[x]);
		}
	});
var $elm$core$List$take = F2(
	function (n, list) {
		return A3($elm$core$List$takeFast, 0, n, list);
	});
var $author$project$AWS$Dynamo$batchPutInner = F4(
	function (ports, encoder, table, vals) {
		var remainder = A2($elm$core$List$drop, 25, vals);
		var firstBatch = A2($elm$core$List$take, 25, vals);
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (_v1) {
				var id = _v1.id;
				var res = _v1.res;
				var _v2 = $author$project$AWS$Dynamo$batchPutResponseDecoder(res);
				if (_v2.$ === 'Ok') {
					if (!remainder.b) {
						return $brian_watkins$elm_procedure$Procedure$provide(
							_Utils_Tuple2(
								id,
								$elm$core$Result$Ok(_Utils_Tuple0)));
					} else {
						var moreItems = remainder;
						return A4($author$project$AWS$Dynamo$batchPutInner, ports, encoder, table, moreItems);
					}
				} else {
					var err = _v2.a;
					return $brian_watkins$elm_procedure$Procedure$provide(
						_Utils_Tuple2(
							id,
							$elm$core$Result$Err(err)));
				}
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.batchWrite(
									{
										id: key,
										req: A2(
											$author$project$AWS$Dynamo$batchPutEncoder,
											encoder,
											{items: firstBatch, tableName: table})
									});
							})))));
	});
var $author$project$AWS$Dynamo$batchPut = F5(
	function (pt, ports, encoder, batchPutProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v0) {
				var res = _v0.b;
				return dt(res);
			},
			A4($author$project$AWS$Dynamo$batchPutInner, ports, encoder, batchPutProps.tableName, batchPutProps.items));
	});
var $author$project$AWS$Dynamo$deleteEncoder = F2(
	function (encoder, deleteOp) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'TableName',
					$elm$json$Json$Encode$string(deleteOp.tableName)),
					_Utils_Tuple2(
					'Key',
					encoder(deleteOp.key))
				]));
	});
var $author$project$AWS$Dynamo$deleteResponseDecoder = function (val) {
	var decoder = A2(
		$elm$json$Json$Decode$andThen,
		function (type_) {
			if (type_ === 'Ok') {
				return $elm$json$Json$Decode$succeed(
					$elm$core$Result$Ok(_Utils_Tuple0));
			} else {
				return $author$project$AWS$Dynamo$errorDecoder;
			}
		},
		A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
	return $elm_community$result_extra$Result$Extra$merge(
		A2(
			$elm$core$Result$mapError,
			A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
			A2($elm$json$Json$Decode$decodeValue, decoder, val)));
};
var $author$project$AWS$Dynamo$delete = F5(
	function (pt, ports, encoder, deleteProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v1) {
				var res = _v1.res;
				return dt(
					$author$project$AWS$Dynamo$deleteResponseDecoder(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports._delete(
									{
										id: key,
										req: A2($author$project$AWS$Dynamo$deleteEncoder, encoder, deleteProps)
									});
							})))));
	});
var $author$project$AWS$Dynamo$getEncoder = F2(
	function (encoder, getOp) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'TableName',
					$elm$json$Json$Encode$string(getOp.tableName)),
					_Utils_Tuple2(
					'Key',
					encoder(getOp.key))
				]));
	});
var $author$project$AWS$Dynamo$getResponseDecoder = F2(
	function (valDecoder, val) {
		var decoder = A2(
			$elm$json$Json$Decode$andThen,
			function (type_) {
				switch (type_) {
					case 'Item':
						return A2(
							$elm$json$Json$Decode$map,
							A2($elm$core$Basics$composeR, $elm$core$Maybe$Just, $elm$core$Result$Ok),
							A2(
								$elm$json$Json$Decode$at,
								_List_fromArray(
									['item', 'Item']),
								valDecoder));
					case 'ItemNotFound':
						return $elm$json$Json$Decode$succeed(
							$elm$core$Result$Ok($elm$core$Maybe$Nothing));
					default:
						return $author$project$AWS$Dynamo$errorDecoder;
				}
			},
			A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
		return $elm_community$result_extra$Result$Extra$merge(
			A2(
				$elm$core$Result$mapError,
				A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
				A2($elm$json$Json$Decode$decodeValue, decoder, val)));
	});
var $author$project$AWS$Dynamo$get = F6(
	function (pt, ports, encoder, decoder, getProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v1) {
				var res = _v1.res;
				return dt(
					A2($author$project$AWS$Dynamo$getResponseDecoder, decoder, res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.get(
									{
										id: key,
										req: A2($author$project$AWS$Dynamo$getEncoder, encoder, getProps)
									});
							})))));
	});
var $author$project$AWS$Dynamo$putEncoder = F2(
	function (encoder, putOp) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'TableName',
					$elm$json$Json$Encode$string(putOp.tableName)),
					_Utils_Tuple2(
					'Item',
					encoder(putOp.item))
				]));
	});
var $author$project$AWS$Dynamo$putResponseDecoder = function (val) {
	var decoder = A2(
		$elm$json$Json$Decode$andThen,
		function (type_) {
			if (type_ === 'Ok') {
				return $elm$json$Json$Decode$succeed(
					$elm$core$Result$Ok(_Utils_Tuple0));
			} else {
				return $author$project$AWS$Dynamo$errorDecoder;
			}
		},
		A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
	return $elm_community$result_extra$Result$Extra$merge(
		A2(
			$elm$core$Result$mapError,
			A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
			A2($elm$json$Json$Decode$decodeValue, decoder, val)));
};
var $author$project$AWS$Dynamo$put = F5(
	function (pt, ports, encoder, putProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v1) {
				var res = _v1.res;
				return dt(
					$author$project$AWS$Dynamo$putResponseDecoder(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.put(
									{
										id: key,
										req: A2($author$project$AWS$Dynamo$putEncoder, encoder, putProps)
									});
							})))));
	});
var $author$project$AWS$Dynamo$nextPage = F2(
	function (lastEvalKey, q) {
		return _Utils_update(
			q,
			{
				exclusiveStartKey: $elm$core$Maybe$Just(lastEvalKey)
			});
	});
var $author$project$AWS$Dynamo$Equals = F2(
	function (a, b) {
		return {$: 'Equals', a: a, b: b};
	});
var $author$project$AWS$Dynamo$encodeAttr = function (attr) {
	if (attr.$ === 'StringAttr') {
		var val = attr.a;
		return $elm$json$Json$Encode$string(val);
	} else {
		var val = attr.a;
		return $elm$json$Json$Encode$int(val);
	}
};
var $elm$core$List$unzip = function (pairs) {
	var step = F2(
		function (_v0, _v1) {
			var x = _v0.a;
			var y = _v0.b;
			var xs = _v1.a;
			var ys = _v1.b;
			return _Utils_Tuple2(
				A2($elm$core$List$cons, x, xs),
				A2($elm$core$List$cons, y, ys));
		});
	return A3(
		$elm$core$List$foldr,
		step,
		_Utils_Tuple2(_List_Nil, _List_Nil),
		pairs);
};
var $author$project$AWS$Dynamo$keyConditionAsStringAndAttrs = function (keyConditions) {
	var encodeKeyConditions = F2(
		function (index, keyCondition) {
			var attrName = ':attr' + $elm$core$String$fromInt(index);
			switch (keyCondition.$) {
				case 'Equals':
					var field = keyCondition.a;
					var attr = keyCondition.b;
					return _Utils_Tuple2(
						field + (' = ' + attrName),
						_List_fromArray(
							[
								_Utils_Tuple2(
								attrName,
								$author$project$AWS$Dynamo$encodeAttr(attr))
							]));
				case 'LessThan':
					var field = keyCondition.a;
					var attr = keyCondition.b;
					return _Utils_Tuple2(
						field + (' < ' + attrName),
						_List_fromArray(
							[
								_Utils_Tuple2(
								attrName,
								$author$project$AWS$Dynamo$encodeAttr(attr))
							]));
				case 'LessThenOrEqual':
					var field = keyCondition.a;
					var attr = keyCondition.b;
					return _Utils_Tuple2(
						field + (' <= ' + attrName),
						_List_fromArray(
							[
								_Utils_Tuple2(
								attrName,
								$author$project$AWS$Dynamo$encodeAttr(attr))
							]));
				case 'GreaterThan':
					var field = keyCondition.a;
					var attr = keyCondition.b;
					return _Utils_Tuple2(
						field + (' > ' + attrName),
						_List_fromArray(
							[
								_Utils_Tuple2(
								attrName,
								$author$project$AWS$Dynamo$encodeAttr(attr))
							]));
				case 'GreaterThanOrEqual':
					var field = keyCondition.a;
					var attr = keyCondition.b;
					return _Utils_Tuple2(
						field + (' >= ' + attrName),
						_List_fromArray(
							[
								_Utils_Tuple2(
								attrName,
								$author$project$AWS$Dynamo$encodeAttr(attr))
							]));
				default:
					var field = keyCondition.a;
					var lowAttr = keyCondition.b;
					var highAttr = keyCondition.c;
					var lowAttrName = ':lowattr' + $elm$core$String$fromInt(index);
					var highAttrName = ':highattr' + $elm$core$String$fromInt(index);
					return _Utils_Tuple2(
						field + (' BETWEEN ' + (lowAttrName + (' AND ' + highAttrName))),
						_List_fromArray(
							[
								_Utils_Tuple2(
								lowAttrName,
								$author$project$AWS$Dynamo$encodeAttr(lowAttr)),
								_Utils_Tuple2(
								highAttrName,
								$author$project$AWS$Dynamo$encodeAttr(highAttr))
							]));
			}
		});
	return A2(
		$elm$core$Tuple$mapSecond,
		$elm$core$List$concat,
		A2(
			$elm$core$Tuple$mapFirst,
			$elm$core$String$join(' AND '),
			$elm$core$List$unzip(
				A2($elm$core$List$indexedMap, encodeKeyConditions, keyConditions))));
};
var $elm$core$Maybe$map = F2(
	function (f, maybe) {
		if (maybe.$ === 'Just') {
			var value = maybe.a;
			return $elm$core$Maybe$Just(
				f(value));
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $elm_community$maybe_extra$Maybe$Extra$cons = F2(
	function (item, list) {
		if (item.$ === 'Just') {
			var v = item.a;
			return A2($elm$core$List$cons, v, list);
		} else {
			return list;
		}
	});
var $elm_community$maybe_extra$Maybe$Extra$values = A2($elm$core$List$foldr, $elm_community$maybe_extra$Maybe$Extra$cons, _List_Nil);
var $author$project$AWS$Dynamo$queryEncoder = F3(
	function (table, maybeIndex, q) {
		var _v0 = $author$project$AWS$Dynamo$keyConditionAsStringAndAttrs(
			$elm_community$maybe_extra$Maybe$Extra$values(
				_List_fromArray(
					[
						$elm$core$Maybe$Just(
						A2($author$project$AWS$Dynamo$Equals, q.partitionKeyName, q.partitionKeyValue)),
						q.rangeKeyCondition
					])));
		var keyExpressionsString = _v0.a;
		var attrVals = _v0.b;
		var encodedAttrVals = $elm$json$Json$Encode$object(attrVals);
		return $elm$json$Json$Encode$object(
			A2(
				$elm$core$Debug$log,
				'queryEncoder',
				$elm_community$maybe_extra$Maybe$Extra$values(
					_List_fromArray(
						[
							$elm$core$Maybe$Just(
							_Utils_Tuple2(
								'TableName',
								$elm$json$Json$Encode$string(table))),
							A2(
							$elm$core$Maybe$map,
							function (index) {
								return _Utils_Tuple2(
									'IndexName',
									$elm$json$Json$Encode$string(index));
							},
							maybeIndex),
							$elm$core$Maybe$Just(
							_Utils_Tuple2(
								'KeyConditionExpression',
								$elm$json$Json$Encode$string(keyExpressionsString))),
							$elm$core$Maybe$Just(
							_Utils_Tuple2('ExpressionAttributeValues', encodedAttrVals)),
							function () {
							var _v1 = q.order;
							if (_v1.$ === 'Forward') {
								return $elm$core$Maybe$Just(
									_Utils_Tuple2(
										'ScanIndexForward',
										$elm$json$Json$Encode$bool(true)));
							} else {
								return $elm$core$Maybe$Just(
									_Utils_Tuple2(
										'ScanIndexForward',
										$elm$json$Json$Encode$bool(false)));
							}
						}(),
							A2(
							$elm$core$Maybe$map,
							function (limit) {
								return _Utils_Tuple2(
									'Limit',
									$elm$json$Json$Encode$int(limit));
							},
							q.limit),
							A2(
							$elm$core$Maybe$map,
							function (exclusiveStartKey) {
								return _Utils_Tuple2('ExclusiveStartKey', exclusiveStartKey);
							},
							q.exclusiveStartKey)
						]))));
	});
var $elm$core$Tuple$pair = F2(
	function (a, b) {
		return _Utils_Tuple2(a, b);
	});
var $author$project$AWS$Dynamo$queryResponseDecoder = F2(
	function (valDecoder, val) {
		var decoder = A2(
			$elm$json$Json$Decode$andThen,
			function (type_) {
				if (type_ === 'Items') {
					return A3(
						$elm$json$Json$Decode$map2,
						F2(
							function (lastKey, vals) {
								return $elm$core$Result$Ok(
									A2($elm$core$Tuple$pair, lastKey, vals));
							}),
						$elm$json$Json$Decode$maybe(
							A2($elm$json$Json$Decode$field, 'lastEvaluatedKey', $elm$json$Json$Decode$value)),
						A2(
							$elm$json$Json$Decode$field,
							'items',
							$elm$json$Json$Decode$list(valDecoder)));
				} else {
					return $author$project$AWS$Dynamo$errorDecoder;
				}
			},
			A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
		return $elm_community$result_extra$Result$Extra$merge(
			A2(
				$elm$core$Result$mapError,
				A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
				A2($elm$json$Json$Decode$decodeValue, decoder, val)));
	});
var $author$project$AWS$Dynamo$queryInner = F6(
	function (ports, decoder, table, maybeIndex, q, accum) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (_v1) {
				var id = _v1.id;
				var res = _v1.res;
				var _v2 = A2($author$project$AWS$Dynamo$queryResponseDecoder, decoder, res);
				if (_v2.$ === 'Ok') {
					if (_v2.a.a.$ === 'Nothing') {
						var _v3 = _v2.a;
						var _v4 = _v3.a;
						var items = _v3.b;
						return $brian_watkins$elm_procedure$Procedure$provide(
							_Utils_Tuple2(
								id,
								$elm$core$Result$Ok(items)));
					} else {
						var _v5 = _v2.a;
						var lastEvaluatedKey = _v5.a.a;
						var items = _v5.b;
						return A6(
							$author$project$AWS$Dynamo$queryInner,
							ports,
							decoder,
							table,
							maybeIndex,
							A2($author$project$AWS$Dynamo$nextPage, lastEvaluatedKey, q),
							_Utils_ap(accum, items));
					}
				} else {
					var err = _v2.a;
					return $brian_watkins$elm_procedure$Procedure$provide(
						_Utils_Tuple2(
							id,
							$elm$core$Result$Err(err)));
				}
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.query(
									{
										id: key,
										req: A3($author$project$AWS$Dynamo$queryEncoder, table, maybeIndex, q)
									});
							})))));
	});
var $author$project$AWS$Dynamo$query = F5(
	function (pt, ports, decoder, qry, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v0) {
				var res = _v0.b;
				return dt(res);
			},
			A6($author$project$AWS$Dynamo$queryInner, ports, decoder, qry.tableName, $elm$core$Maybe$Nothing, qry.match, _List_Nil));
	});
var $author$project$AWS$Dynamo$queryIndex = F5(
	function (pt, ports, decoder, qry, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v0) {
				var res = _v0.b;
				return dt(res);
			},
			A6(
				$author$project$AWS$Dynamo$queryInner,
				ports,
				decoder,
				qry.tableName,
				$elm$core$Maybe$Just(qry.indexName),
				qry.match,
				_List_Nil));
	});
var $author$project$AWS$Dynamo$scanEncoder = function (scanProps) {
	return $elm$json$Json$Encode$object(
		$elm_community$maybe_extra$Maybe$Extra$values(
			_List_fromArray(
				[
					$elm$core$Maybe$Just(
					_Utils_Tuple2(
						'TableName',
						$elm$json$Json$Encode$string(scanProps.tableName))),
					A2(
					$elm$core$Maybe$map,
					function (exclusiveStartKey) {
						return _Utils_Tuple2('ExclusiveStartKey', exclusiveStartKey);
					},
					scanProps.exclusiveStartKey)
				])));
};
var $author$project$AWS$Dynamo$scanInner = F4(
	function (ports, decoder, scanProps, accum) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (_v1) {
				var id = _v1.id;
				var res = _v1.res;
				var _v2 = A2($author$project$AWS$Dynamo$queryResponseDecoder, decoder, res);
				if (_v2.$ === 'Ok') {
					if (_v2.a.a.$ === 'Nothing') {
						var _v3 = _v2.a;
						var _v4 = _v3.a;
						var items = _v3.b;
						return $brian_watkins$elm_procedure$Procedure$provide(
							_Utils_Tuple2(
								id,
								$elm$core$Result$Ok(items)));
					} else {
						var _v5 = _v2.a;
						var lastEvaluatedKey = _v5.a.a;
						var items = _v5.b;
						return A4(
							$author$project$AWS$Dynamo$scanInner,
							ports,
							decoder,
							A2($author$project$AWS$Dynamo$nextPage, lastEvaluatedKey, scanProps),
							_Utils_ap(accum, items));
					}
				} else {
					var err = _v2.a;
					return $brian_watkins$elm_procedure$Procedure$provide(
						_Utils_Tuple2(
							id,
							$elm$core$Result$Err(err)));
				}
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.scan(
									{
										id: key,
										req: $author$project$AWS$Dynamo$scanEncoder(scanProps)
									});
							})))));
	});
var $author$project$AWS$Dynamo$scan = F5(
	function (pt, ports, decoder, scanProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v0) {
				var res = _v0.b;
				return dt(res);
			},
			A4($author$project$AWS$Dynamo$scanInner, ports, decoder, scanProps, _List_Nil));
	});
var $elm$core$Dict$foldl = F3(
	function (func, acc, dict) {
		foldl:
		while (true) {
			if (dict.$ === 'RBEmpty_elm_builtin') {
				return acc;
			} else {
				var key = dict.b;
				var value = dict.c;
				var left = dict.d;
				var right = dict.e;
				var $temp$func = func,
					$temp$acc = A3(
					func,
					key,
					value,
					A3($elm$core$Dict$foldl, func, acc, left)),
					$temp$dict = right;
				func = $temp$func;
				acc = $temp$acc;
				dict = $temp$dict;
				continue foldl;
			}
		}
	});
var $elm$json$Json$Encode$dict = F3(
	function (toKey, toValue, dictionary) {
		return _Json_wrap(
			A3(
				$elm$core$Dict$foldl,
				F3(
					function (key, value, obj) {
						return A3(
							_Json_addField,
							toKey(key),
							toValue(value),
							obj);
					}),
				_Json_emptyObject(_Utils_Tuple0),
				dictionary));
	});
var $author$project$AWS$Dynamo$encodeReturnConsumedCapacity = function (arg) {
	if (arg.$ === 'CapacityIndexes') {
		return $elm$json$Json$Encode$string('INDEXES');
	} else {
		return $elm$json$Json$Encode$string('TOTAL');
	}
};
var $author$project$AWS$Dynamo$encodeReturnItemCollectionMetrics = function (arg) {
	return $elm$json$Json$Encode$string('SIZE');
};
var $author$project$AWS$Dynamo$encodeReturnValues = function (arg) {
	switch (arg.$) {
		case 'ReturnValuesAllOld':
			return $elm$json$Json$Encode$string('ALL_OLD');
		case 'ReturnValuesUpdatedOld':
			return $elm$json$Json$Encode$string('UPDATED_OLD');
		case 'ReturnValuesAllNew':
			return $elm$json$Json$Encode$string('ALL_NEW');
		default:
			return $elm$json$Json$Encode$string('UPDATED_NEW');
	}
};
var $author$project$AWS$Dynamo$encodeReturnValuesOnConditionCheckFailure = function (arg) {
	return $elm$json$Json$Encode$string('ALL_OLD');
};
var $elm$core$List$maybeCons = F3(
	function (f, mx, xs) {
		var _v0 = f(mx);
		if (_v0.$ === 'Just') {
			var x = _v0.a;
			return A2($elm$core$List$cons, x, xs);
		} else {
			return xs;
		}
	});
var $elm$core$List$filterMap = F2(
	function (f, xs) {
		return A3(
			$elm$core$List$foldr,
			$elm$core$List$maybeCons(f),
			_List_Nil,
			xs);
	});
var $elm$core$Dict$isEmpty = function (dict) {
	if (dict.$ === 'RBEmpty_elm_builtin') {
		return true;
	} else {
		return false;
	}
};
var $author$project$AWS$Dynamo$updateEncoder = F2(
	function (encoder, putOp) {
		return $elm$json$Json$Encode$object(
			A2(
				$elm$core$List$filterMap,
				$elm$core$Basics$identity,
				_List_fromArray(
					[
						$elm$core$Maybe$Just(
						_Utils_Tuple2(
							'TableName',
							$elm$json$Json$Encode$string(putOp.tableName))),
						$elm$core$Maybe$Just(
						_Utils_Tuple2(
							'Key',
							encoder(putOp.key))),
						$elm$core$Maybe$Just(
						_Utils_Tuple2(
							'UpdateExpression',
							$elm$json$Json$Encode$string(putOp.updateExpression))),
						A2(
						$elm$core$Maybe$map,
						function (ce) {
							return _Utils_Tuple2(
								'ConditionExpression',
								$elm$json$Json$Encode$string(ce));
						},
						putOp.conditionExpression),
						function () {
						var _v0 = $elm$core$Dict$isEmpty(putOp.expressionAttributeNames);
						if (!_v0) {
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(
									'ExpressionAttributeNames',
									A3($elm$json$Json$Encode$dict, $elm$core$Basics$identity, $elm$json$Json$Encode$string, putOp.expressionAttributeNames)));
						} else {
							return $elm$core$Maybe$Nothing;
						}
					}(),
						function () {
						var _v1 = $elm$core$Dict$isEmpty(putOp.expressionAttributeValues);
						if (!_v1) {
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(
									'ExpressionAttributeValues',
									A3($elm$json$Json$Encode$dict, $elm$core$Basics$identity, $author$project$AWS$Dynamo$encodeAttr, putOp.expressionAttributeValues)));
						} else {
							return $elm$core$Maybe$Nothing;
						}
					}(),
						A2(
						$elm$core$Maybe$map,
						function (rcc) {
							return _Utils_Tuple2(
								'ReturnConsumedCapacity',
								$author$project$AWS$Dynamo$encodeReturnConsumedCapacity(rcc));
						},
						putOp.returnConsumedCapacity),
						A2(
						$elm$core$Maybe$map,
						function (rcm) {
							return _Utils_Tuple2(
								'ReturnItemCollectionMetrics',
								$author$project$AWS$Dynamo$encodeReturnItemCollectionMetrics(rcm));
						},
						putOp.returnItemCollectionMetrics),
						A2(
						$elm$core$Maybe$map,
						function (rv) {
							return _Utils_Tuple2(
								'ReturnValues',
								$author$project$AWS$Dynamo$encodeReturnValues(rv));
						},
						putOp.returnValues),
						A2(
						$elm$core$Maybe$map,
						function (rvcf) {
							return _Utils_Tuple2(
								'ReturnValuesOnConditionCheckFailure',
								$author$project$AWS$Dynamo$encodeReturnValuesOnConditionCheckFailure(rvcf));
						},
						putOp.returnValuesOnConditionCheckFailure)
					])));
	});
var $author$project$AWS$Dynamo$updateResponseDecoder = F2(
	function (valDecoder, val) {
		var decoder = A2(
			$elm$json$Json$Decode$andThen,
			function (type_) {
				switch (type_) {
					case 'Ok':
						return $elm$json$Json$Decode$succeed(
							$elm$core$Result$Ok($elm$core$Maybe$Nothing));
					case 'Item':
						return A2(
							$elm$json$Json$Decode$map,
							A2($elm$core$Basics$composeR, $elm$core$Maybe$Just, $elm$core$Result$Ok),
							A2(
								$elm$json$Json$Decode$at,
								_List_fromArray(
									['item', 'Item']),
								valDecoder));
					default:
						return $author$project$AWS$Dynamo$errorDecoder;
				}
			},
			A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
		return $elm_community$result_extra$Result$Extra$merge(
			A2(
				$elm$core$Result$mapError,
				A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
				A2($elm$json$Json$Decode$decodeValue, decoder, val)));
	});
var $author$project$AWS$Dynamo$update = F6(
	function (pt, ports, encoder, decoder, updateProps, dt) {
		var _v0 = A2(
			$elm$core$Debug$log,
			'Dynamo.update',
			A2(
				$elm$json$Json$Encode$encode,
				2,
				A2($author$project$AWS$Dynamo$updateEncoder, encoder, updateProps)));
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v2) {
				var res = _v2.res;
				return dt(
					A2($author$project$AWS$Dynamo$updateResponseDecoder, decoder, res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v1) {
							var id = _v1.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.update(
									{
										id: key,
										req: A2($author$project$AWS$Dynamo$updateEncoder, encoder, updateProps)
									});
							})))));
	});
var $author$project$AWS$Dynamo$writeTxEncoder = function (writeTxOp) {
	var encoder = function (writeCommand) {
		switch (writeCommand.$) {
			case 'PutCommand':
				var v = writeCommand.a;
				return $elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2('Put', v)
						]));
			case 'UpdateCommand':
				var v = writeCommand.a;
				return $elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2('Update', v)
						]));
			default:
				var v = writeCommand.a;
				return $elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2('Delete', v)
						]));
		}
	};
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'TableName',
				$elm$json$Json$Encode$string(writeTxOp.tableName)),
				_Utils_Tuple2(
				'TransactItems',
				A2($elm$json$Json$Encode$list, encoder, writeTxOp.commands))
			]));
};
var $author$project$AWS$Dynamo$writeTxResponseDecoder = function (val) {
	var decoder = A2(
		$elm$json$Json$Decode$andThen,
		function (type_) {
			if (type_ === 'Ok') {
				return $elm$json$Json$Decode$succeed(
					$elm$core$Result$Ok(_Utils_Tuple0));
			} else {
				return $author$project$AWS$Dynamo$errorDecoder;
			}
		},
		A2($elm$json$Json$Decode$field, 'type_', $elm$json$Json$Decode$string));
	return $elm_community$result_extra$Result$Extra$merge(
		A2(
			$elm$core$Result$mapError,
			A2($elm$core$Basics$composeR, $author$project$AWS$Dynamo$DecodeError, $elm$core$Result$Err),
			A2($elm$json$Json$Decode$decodeValue, decoder, val)));
};
var $author$project$AWS$Dynamo$writeTx = F4(
	function (pt, ports, writeTxProps, dt) {
		return A3(
			$brian_watkins$elm_procedure$Procedure$run,
			pt,
			function (_v1) {
				var res = _v1.res;
				return dt(
					$author$project$AWS$Dynamo$writeTxResponseDecoder(res));
			},
			$brian_watkins$elm_procedure$Procedure$Channel$acceptOne(
				A2(
					$brian_watkins$elm_procedure$Procedure$Channel$filter,
					F2(
						function (key, _v0) {
							var id = _v0.id;
							return _Utils_eq(id, key);
						}),
					A2(
						$brian_watkins$elm_procedure$Procedure$Channel$connect,
						ports.response,
						$brian_watkins$elm_procedure$Procedure$Channel$open(
							function (key) {
								return ports.writeTx(
									{
										id: key,
										req: $author$project$AWS$Dynamo$writeTxEncoder(writeTxProps)
									});
							})))));
	});
var $author$project$AWS$Dynamo$dynamoTypedApi = F5(
	function (keyEncoder, valEncoder, decoder, pt, ports) {
		return {
			batchGet: A4($author$project$AWS$Dynamo$batchGet, pt, ports, keyEncoder, decoder),
			batchPut: A3($author$project$AWS$Dynamo$batchPut, pt, ports, valEncoder),
			_delete: A3($author$project$AWS$Dynamo$delete, pt, ports, keyEncoder),
			get: A4($author$project$AWS$Dynamo$get, pt, ports, keyEncoder, decoder),
			put: A3($author$project$AWS$Dynamo$put, pt, ports, valEncoder),
			query: A3($author$project$AWS$Dynamo$query, pt, ports, decoder),
			queryIndex: A3($author$project$AWS$Dynamo$queryIndex, pt, ports, decoder),
			scan: A3($author$project$AWS$Dynamo$scan, pt, ports, decoder),
			update: A4($author$project$AWS$Dynamo$update, pt, ports, keyEncoder, decoder),
			writeTx: A2($author$project$AWS$Dynamo$writeTx, pt, ports)
		};
	});
var $author$project$DB$SnapshotTable$encodeKey = function (key) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'id',
				$elm$json$Json$Encode$string(key.id)),
				_Utils_Tuple2(
				'seq',
				$elm$json$Json$Encode$int(key.seq))
			]));
};
var $miniBill$elm_codec$Codec$encoder = function (_v0) {
	var m = _v0.a;
	return m.encoder;
};
var $author$project$AWS$Dynamo$Reverse = {$: 'Reverse'};
var $author$project$AWS$Dynamo$orderResults = F2(
	function (ord, q) {
		return _Utils_update(
			q,
			{order: ord});
	});
var $author$project$AWS$Dynamo$Forward = {$: 'Forward'};
var $author$project$AWS$Dynamo$StringAttr = function (a) {
	return {$: 'StringAttr', a: a};
};
var $author$project$AWS$Dynamo$partitionKeyEquals = F2(
	function (key, val) {
		return {
			exclusiveStartKey: $elm$core$Maybe$Nothing,
			limit: $elm$core$Maybe$Nothing,
			order: $author$project$AWS$Dynamo$Forward,
			partitionKeyName: key,
			partitionKeyValue: $author$project$AWS$Dynamo$StringAttr(val),
			rangeKeyCondition: $elm$core$Maybe$Nothing
		};
	});
var $author$project$DB$SnapshotTable$findLatestSnapshotQuery = F2(
	function (tableName, channel) {
		var matchLatestSnapshot = A2(
			$author$project$AWS$Dynamo$orderResults,
			$author$project$AWS$Dynamo$Reverse,
			A2($author$project$AWS$Dynamo$partitionKeyEquals, 'id', channel));
		return A2(
			$elm$core$Debug$log,
			'findLatestSnapshotQuery',
			{match: matchLatestSnapshot, tableName: tableName});
	});
var $author$project$DB$SnapshotTable$Record = F4(
	function (id, seq, updatedAt, snapshot) {
		return {id: id, seq: seq, snapshot: snapshot, updatedAt: updatedAt};
	});
var $miniBill$elm_codec$Codec$Codec = function (a) {
	return {$: 'Codec', a: a};
};
var $miniBill$elm_codec$Codec$buildObject = function (_v0) {
	var om = _v0.a;
	return $miniBill$elm_codec$Codec$Codec(
		{
			decoder: om.decoder,
			encoder: function (v) {
				return $elm$json$Json$Encode$object(
					om.encoder(v));
			}
		});
};
var $miniBill$elm_codec$Codec$ObjectCodec = function (a) {
	return {$: 'ObjectCodec', a: a};
};
var $miniBill$elm_codec$Codec$field = F4(
	function (name, getter, codec, _v0) {
		var ocodec = _v0.a;
		return $miniBill$elm_codec$Codec$ObjectCodec(
			{
				decoder: A3(
					$elm$json$Json$Decode$map2,
					F2(
						function (f, x) {
							return f(x);
						}),
					ocodec.decoder,
					A2(
						$elm$json$Json$Decode$field,
						name,
						$miniBill$elm_codec$Codec$decoder(codec))),
				encoder: function (v) {
					return A2(
						$elm$core$List$cons,
						_Utils_Tuple2(
							name,
							A2(
								$miniBill$elm_codec$Codec$encoder,
								codec,
								getter(v))),
						ocodec.encoder(v));
				}
			});
	});
var $miniBill$elm_codec$Codec$build = F2(
	function (encoder_, decoder_) {
		return $miniBill$elm_codec$Codec$Codec(
			{decoder: decoder_, encoder: encoder_});
	});
var $miniBill$elm_codec$Codec$int = A2($miniBill$elm_codec$Codec$build, $elm$json$Json$Encode$int, $elm$json$Json$Decode$int);
var $miniBill$elm_codec$Codec$object = function (ctor) {
	return $miniBill$elm_codec$Codec$ObjectCodec(
		{
			decoder: $elm$json$Json$Decode$succeed(ctor),
			encoder: function (_v0) {
				return _List_Nil;
			}
		});
};
var $author$project$DB$SnapshotTable$posixCodec = A2(
	$miniBill$elm_codec$Codec$build,
	function (timestamp) {
		return $elm$json$Json$Encode$int(
			$elm$time$Time$posixToMillis(timestamp));
	},
	A2($elm$json$Json$Decode$map, $elm$time$Time$millisToPosix, $elm$json$Json$Decode$int));
var $miniBill$elm_codec$Codec$string = A2($miniBill$elm_codec$Codec$build, $elm$json$Json$Encode$string, $elm$json$Json$Decode$string);
var $miniBill$elm_codec$Codec$value = $miniBill$elm_codec$Codec$Codec(
	{decoder: $elm$json$Json$Decode$value, encoder: $elm$core$Basics$identity});
var $author$project$DB$SnapshotTable$recordCodec = $miniBill$elm_codec$Codec$buildObject(
	A4(
		$miniBill$elm_codec$Codec$field,
		'snapshot',
		function ($) {
			return $.snapshot;
		},
		$miniBill$elm_codec$Codec$value,
		A4(
			$miniBill$elm_codec$Codec$field,
			'updatedAt',
			function ($) {
				return $.updatedAt;
			},
			$author$project$DB$SnapshotTable$posixCodec,
			A4(
				$miniBill$elm_codec$Codec$field,
				'seq',
				function ($) {
					return $.seq;
				},
				$miniBill$elm_codec$Codec$int,
				A4(
					$miniBill$elm_codec$Codec$field,
					'id',
					function ($) {
						return $.id;
					},
					$miniBill$elm_codec$Codec$string,
					$miniBill$elm_codec$Codec$object($author$project$DB$SnapshotTable$Record))))));
var $author$project$DB$SnapshotTable$operations = F3(
	function (proc, ports, tableName) {
		var typedApi = A5(
			$author$project$AWS$Dynamo$dynamoTypedApi,
			$author$project$DB$SnapshotTable$encodeKey,
			$miniBill$elm_codec$Codec$encoder($author$project$DB$SnapshotTable$recordCodec),
			$miniBill$elm_codec$Codec$decoder($author$project$DB$SnapshotTable$recordCodec),
			proc,
			ports);
		return {
			findLatestSnapshot: function (channel) {
				return typedApi.query(
					A2($author$project$DB$SnapshotTable$findLatestSnapshotQuery, tableName, channel));
			},
			put: typedApi.put
		};
	});
var $author$project$EventLog$Apis$snapshotTableApi = function (tableName) {
	return A3($author$project$DB$SnapshotTable$operations, $author$project$EventLog$Msg$ProcedureMsg, $author$project$EventLog$Apis$dynamoPorts, tableName);
};
var $author$project$EventLog$LatestSnapshot$getLatestSnapshotFromTable = F3(
	function (component, channelName, state) {
		var _v0 = A2($elm$core$Debug$log, 'LatestSnapshot.getLatestSnapshotFromTable', 'called');
		return A2(
			$brian_watkins$elm_procedure$Procedure$map,
			function (queryResult) {
				var _v1 = A2($elm$core$Debug$log, 'queryResult', queryResult);
				if (!_v1.b) {
					return {cache: state.cache, maybeLatest: $elm$core$Maybe$Nothing};
				} else {
					var r = _v1.a;
					return {
						cache: state.cache,
						maybeLatest: $elm$core$Maybe$Just(
							{model: r.snapshot, seq: r.seq})
					};
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				$author$project$AWS$Dynamo$errorToDetails,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					$author$project$EventLog$Apis$snapshotTableApi(component.snapshotTable).findLatestSnapshot(channelName))));
	});
var $author$project$EventLog$SnapshotChannel$checkAgainstCurrentSnapshot = F3(
	function (component, event, state) {
		var _v0 = A2($elm$core$Debug$log, 'SnapshotChannel.checkAgainstCurrentSnapshot', 'called');
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (_v3) {
				var cache = _v3.cache;
				var maybeLatest = _v3.maybeLatest;
				if (maybeLatest.$ === 'Just') {
					var latest = maybeLatest.a;
					return (_Utils_cmp(latest.seq, event.seq) > -1) ? $brian_watkins$elm_procedure$Procedure$provide(
						$author$project$EventLog$SnapshotChannel$LaterFound(
							A3($elm$core$Dict$insert, event.channel, latest, cache))) : $brian_watkins$elm_procedure$Procedure$provide(
						$author$project$EventLog$SnapshotChannel$OutOfDate(latest));
				} else {
					return $brian_watkins$elm_procedure$Procedure$provide($author$project$EventLog$SnapshotChannel$New);
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$andThen,
				function (_v1) {
					var cache = _v1.cache;
					var maybeLatest = _v1.maybeLatest;
					if (maybeLatest.$ === 'Just') {
						var latest = maybeLatest.a;
						return (_Utils_cmp(latest.seq, event.seq) > -1) ? $brian_watkins$elm_procedure$Procedure$provide(
							{
								cache: cache,
								maybeLatest: $elm$core$Maybe$Just(latest)
							}) : A3(
							$author$project$EventLog$LatestSnapshot$getLatestSnapshotFromTable,
							component,
							event.channel,
							{cache: state.cache});
					} else {
						return A3(
							$author$project$EventLog$LatestSnapshot$getLatestSnapshotFromTable,
							component,
							event.channel,
							{cache: state.cache});
					}
				},
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$LatestSnapshot$getLatestSnapshotFromCache, component, event.channel),
					$brian_watkins$elm_procedure$Procedure$provide(state))));
	});
var $author$project$DB$EventLogTable$encodeKey = function (key) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'id',
				$elm$json$Json$Encode$string(key.id)),
				_Utils_Tuple2(
				'seq',
				$elm$json$Json$Encode$int(key.seq))
			]));
};
var $author$project$DB$EventLogTable$Record = F4(
	function (id, seq, updatedAt, event) {
		return {event: event, id: id, seq: seq, updatedAt: updatedAt};
	});
var $author$project$DB$EventLogTable$posixCodec = A2(
	$miniBill$elm_codec$Codec$build,
	function (timestamp) {
		return $elm$json$Json$Encode$int(
			$elm$time$Time$posixToMillis(timestamp));
	},
	A2($elm$json$Json$Decode$map, $elm$time$Time$millisToPosix, $elm$json$Json$Decode$int));
var $author$project$DB$EventLogTable$recordCodec = $miniBill$elm_codec$Codec$buildObject(
	A4(
		$miniBill$elm_codec$Codec$field,
		'event',
		function ($) {
			return $.event;
		},
		$miniBill$elm_codec$Codec$value,
		A4(
			$miniBill$elm_codec$Codec$field,
			'updatedAt',
			function ($) {
				return $.updatedAt;
			},
			$author$project$DB$EventLogTable$posixCodec,
			A4(
				$miniBill$elm_codec$Codec$field,
				'seq',
				function ($) {
					return $.seq;
				},
				$miniBill$elm_codec$Codec$int,
				A4(
					$miniBill$elm_codec$Codec$field,
					'id',
					function ($) {
						return $.id;
					},
					$miniBill$elm_codec$Codec$string,
					$miniBill$elm_codec$Codec$object($author$project$DB$EventLogTable$Record))))));
var $author$project$DB$EventLogTable$operations = A3(
	$author$project$AWS$Dynamo$dynamoTypedApi,
	$author$project$DB$EventLogTable$encodeKey,
	$miniBill$elm_codec$Codec$encoder($author$project$DB$EventLogTable$recordCodec),
	$miniBill$elm_codec$Codec$decoder($author$project$DB$EventLogTable$recordCodec));
var $author$project$EventLog$Apis$eventLogTableApi = A2($author$project$DB$EventLogTable$operations, $author$project$EventLog$Msg$ProcedureMsg, $author$project$EventLog$Apis$dynamoPorts);
var $author$project$AWS$Dynamo$NumberAttr = function (a) {
	return {$: 'NumberAttr', a: a};
};
var $author$project$AWS$Dynamo$int = function (val) {
	return $author$project$AWS$Dynamo$NumberAttr(val);
};
var $author$project$AWS$Dynamo$GreaterThan = F2(
	function (a, b) {
		return {$: 'GreaterThan', a: a, b: b};
	});
var $author$project$AWS$Dynamo$rangeKeyGreaterThan = F3(
	function (keyName, attr, q) {
		return _Utils_update(
			q,
			{
				rangeKeyCondition: $elm$core$Maybe$Just(
					A2($author$project$AWS$Dynamo$GreaterThan, keyName, attr))
			});
	});
var $author$project$EventLog$SnapshotChannel$readLaterEvents = F3(
	function (component, event, state) {
		var seq = A2(
			$elm$core$Maybe$withDefault,
			0,
			A2(
				$elm$core$Maybe$map,
				function ($) {
					return $.seq;
				},
				state.baseSnapshot));
		var matchLaterEvents = A2(
			$author$project$AWS$Dynamo$orderResults,
			$author$project$AWS$Dynamo$Forward,
			A3(
				$author$project$AWS$Dynamo$rangeKeyGreaterThan,
				'seq',
				$author$project$AWS$Dynamo$int(seq),
				A2($author$project$AWS$Dynamo$partitionKeyEquals, 'id', event.channel)));
		var query = {match: matchLaterEvents, tableName: component.eventLogTable};
		var _v0 = A2($elm$core$Debug$log, 'SnapshotChannel.readLaterEvents', 'called');
		return A2(
			$brian_watkins$elm_procedure$Procedure$map,
			function (laterEvents) {
				return {baseSnapshot: state.baseSnapshot, cache: state.cache, laterEvents: laterEvents};
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				$author$project$AWS$Dynamo$errorToDetails,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					$author$project$EventLog$Apis$eventLogTableApi.query(query))));
	});
var $author$project$Realtime$RTPersisted = F2(
	function (a, b) {
		return {$: 'RTPersisted', a: a, b: b};
	});
var $author$project$EventLog$SnapshotChannel$initialSnapshot = function (rtmessage) {
	switch (rtmessage.$) {
		case 'RTPersisted':
			var seq = rtmessage.a;
			var val = rtmessage.b;
			return $elm$core$Maybe$Just(
				{
					model: $elm$json$Json$Encode$string(
						'hello-' + $elm$core$String$fromInt(seq)),
					seq: seq
				});
		case 'RTTransient':
			return $elm$core$Maybe$Nothing;
		default:
			var seq = rtmessage.a;
			var val = rtmessage.b;
			return $elm$core$Maybe$Just(
				{model: val, seq: seq});
	}
};
var $author$project$EventLog$SnapshotChannel$stepSnapshot = F2(
	function (rtmessage, current) {
		switch (rtmessage.$) {
			case 'RTPersisted':
				var seq = rtmessage.a;
				var val = rtmessage.b;
				return {
					model: $elm$json$Json$Encode$string(
						'hello-' + $elm$core$String$fromInt(seq)),
					seq: seq
				};
			case 'RTTransient':
				return current;
			default:
				var seq = rtmessage.a;
				var val = rtmessage.b;
				return {model: val, seq: seq};
		}
	});
var $author$project$EventLog$SnapshotChannel$saveNextSnapshot = F3(
	function (component, event, state) {
		var rtMessage = function (record) {
			return A2($author$project$Realtime$RTPersisted, record.seq, record.event);
		};
		var maybeNextSnapshot = A3(
			$elm$core$List$foldl,
			F2(
				function (rtm, acc) {
					if (acc.$ === 'Nothing') {
						return $author$project$EventLog$SnapshotChannel$initialSnapshot(rtm);
					} else {
						var prev = acc.a;
						return $elm$core$Maybe$Just(
							A2($author$project$EventLog$SnapshotChannel$stepSnapshot, rtm, prev));
					}
				}),
			state.baseSnapshot,
			A2($elm$core$List$map, rtMessage, state.laterEvents));
		var _v0 = A2($elm$core$Debug$log, 'SnapshotChannel.saveNextSnapshot', 'called');
		if (maybeNextSnapshot.$ === 'Just') {
			var nextSnapshot = maybeNextSnapshot.a;
			return A2(
				$brian_watkins$elm_procedure$Procedure$andThen,
				function (timestamp) {
					return A2(
						$brian_watkins$elm_procedure$Procedure$map,
						function (_v2) {
							return {
								cache: A3($elm$core$Dict$insert, event.channel, nextSnapshot, state.cache)
							};
						},
						A2(
							$brian_watkins$elm_procedure$Procedure$mapError,
							$author$project$AWS$Dynamo$errorToDetails,
							$brian_watkins$elm_procedure$Procedure$fetchResult(
								$author$project$EventLog$Apis$snapshotTableApi(component.snapshotTable).put(
									{
										item: {id: event.channel, seq: nextSnapshot.seq, snapshot: nextSnapshot.model, updatedAt: timestamp},
										tableName: component.snapshotTable
									}))));
				},
				$brian_watkins$elm_procedure$Procedure$fromTask($elm$time$Time$now));
		} else {
			return $brian_watkins$elm_procedure$Procedure$provide(
				{cache: state.cache});
		}
	});
var $author$project$EventLog$SnapshotChannel$snapshotChannel = F3(
	function (component, event, state) {
		var _v0 = A2($elm$core$Debug$log, 'SnapshotChannel.snapshotChannel', 'called');
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (condition) {
				switch (condition.$) {
					case 'LaterFound':
						var cache = condition.a;
						return $brian_watkins$elm_procedure$Procedure$provide(
							{cache: cache});
					case 'OutOfDate':
						var snapshot = condition.a;
						return A2(
							$brian_watkins$elm_procedure$Procedure$andThen,
							A2($author$project$EventLog$SnapshotChannel$saveNextSnapshot, component, event),
							A2(
								$brian_watkins$elm_procedure$Procedure$andThen,
								A2($author$project$EventLog$SnapshotChannel$readLaterEvents, component, event),
								$brian_watkins$elm_procedure$Procedure$provide(
									{
										baseSnapshot: $elm$core$Maybe$Just(snapshot),
										cache: state.cache
									})));
					default:
						return A2(
							$brian_watkins$elm_procedure$Procedure$andThen,
							A2($author$project$EventLog$SnapshotChannel$saveNextSnapshot, component, event),
							A2(
								$brian_watkins$elm_procedure$Procedure$andThen,
								A2($author$project$EventLog$SnapshotChannel$readLaterEvents, component, event),
								$brian_watkins$elm_procedure$Procedure$provide(
									{baseSnapshot: $elm$core$Maybe$Nothing, cache: state.cache})));
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$andThen,
				A2($author$project$EventLog$SnapshotChannel$checkAgainstCurrentSnapshot, component, event),
				$brian_watkins$elm_procedure$Procedure$provide(state)));
	});
var $author$project$EventLog$SnapshotChannel$drainSnapshotRequests = F3(
	function (component, snapshotSeqByChannel, state) {
		var _v0 = A2($elm$core$Debug$log, 'SnapshotChannel.drainSnapshotRequests', 'called');
		if (!snapshotSeqByChannel.b) {
			return $brian_watkins$elm_procedure$Procedure$provide(state);
		} else {
			var snapshotRequestEvent = snapshotSeqByChannel.a;
			var events = snapshotSeqByChannel.b;
			return A2(
				$brian_watkins$elm_procedure$Procedure$andThen,
				A2($author$project$EventLog$SnapshotChannel$drainSnapshotRequests, component, events),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$SnapshotChannel$snapshotChannel, component, snapshotRequestEvent),
					$brian_watkins$elm_procedure$Procedure$provide(state)));
		}
	});
var $author$project$Http$Response$ok200json = function (msg) {
	return A2(
		$author$project$Http$Response$setBody,
		$author$project$Http$Body$json(msg),
		$author$project$Http$Response$init);
};
var $author$project$EventLog$SnapshotChannel$setModel = F2(
	function (m, x) {
		return _Utils_update(
			m,
			{eventLog: x});
	});
var $author$project$Realtime$SnapshotRequestEvent = F3(
	function (rt, channel, seq) {
		return {channel: channel, rt: rt, seq: seq};
	});
var $author$project$Realtime$snapshotRequestEventDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (ctor) {
		if (ctor === 'S') {
			return A2(
				$elm_community$json_extra$Json$Decode$Extra$andMap,
				A2($elm$json$Json$Decode$field, 'seq', $elm$json$Json$Decode$int),
				A2(
					$elm_community$json_extra$Json$Decode$Extra$andMap,
					A2($elm$json$Json$Decode$field, 'channel', $elm$json$Json$Decode$string),
					A2(
						$elm_community$json_extra$Json$Decode$Extra$andMap,
						$elm$json$Json$Decode$succeed('S'),
						$elm$json$Json$Decode$succeed($author$project$Realtime$SnapshotRequestEvent))));
		} else {
			return $elm$json$Json$Decode$fail('Unrecognized constructor');
		}
	},
	A2($elm$json$Json$Decode$field, 'rt', $elm$json$Json$Decode$string));
var $author$project$EventLog$SnapshotChannel$switchState = F2(
	function (cons, state) {
		return _Utils_Tuple2(
			cons(state),
			$elm$core$Platform$Cmd$none);
	});
var $elm$core$Result$withDefault = F2(
	function (def, result) {
		if (result.$ === 'Ok') {
			var a = result.a;
			return a;
		} else {
			return def;
		}
	});
var $author$project$EventLog$SnapshotChannel$procedure = F4(
	function (session, state, sqsEvent, component) {
		var updateHighest = F2(
			function (_new, maybeExisting) {
				if (maybeExisting.$ === 'Just') {
					var existing = maybeExisting.a;
					return (_Utils_cmp(_new.seq, existing.seq) > 0) ? $elm$core$Maybe$Just(_new) : $elm$core$Maybe$Just(existing);
				} else {
					return $elm$core$Maybe$Just(_new);
				}
			});
		var snapshotSeqByChannel = A2(
			$elm$core$Debug$log,
			'snapshotSeqByChannel',
			$elm$core$Dict$values(
				A3(
					$elm$core$List$foldl,
					F2(
						function (sqsMessage, acc) {
							return A2(
								$elm$core$Result$withDefault,
								acc,
								A2(
									$elm$core$Result$map,
									function (snapshotRequestEvent) {
										return A3(
											$elm$core$Dict$update,
											snapshotRequestEvent.channel,
											updateHighest(snapshotRequestEvent),
											acc);
									},
									A2($elm$json$Json$Decode$decodeString, $author$project$Realtime$snapshotRequestEventDecoder, sqsMessage.body)));
						}),
					$elm$core$Dict$empty,
					sqsEvent)));
		var innerProc = A2(
			$brian_watkins$elm_procedure$Procedure$map,
			$elm$core$Basics$always(
				$author$project$Http$Response$ok200json($elm$json$Json$Encode$null)),
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				A2(
					$elm$core$Basics$composeR,
					$elm$core$Debug$log('error'),
					A2($elm$core$Basics$composeR, $author$project$ErrorFormat$encodeErrorFormat, $author$project$Http$Response$err500json)),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$SnapshotChannel$drainSnapshotRequests, component, snapshotSeqByChannel),
					$brian_watkins$elm_procedure$Procedure$provide(
						{cache: state.cache}))));
		var _v0 = A2($elm$core$Debug$log, 'SnapshotChannel.procedure', 'called');
		return A2(
			$elm$core$Tuple$mapFirst,
			$author$project$EventLog$SnapshotChannel$setModel(component),
			A2(
				$the_sett$elm_update_helper$Update2$andMap,
				$author$project$EventLog$SnapshotChannel$switchState($author$project$EventLog$Model$ModelReady),
				_Utils_Tuple2(
					state,
					A3(
						$brian_watkins$elm_procedure$Procedure$try,
						$author$project$EventLog$Msg$ProcedureMsg,
						$author$project$EventLog$Msg$HttpResponse(session),
						innerProc))));
	});
var $elm$core$Basics$abs = function (n) {
	return (n < 0) ? (-n) : n;
};
var $elm$random$Random$andThen = F2(
	function (callback, _v0) {
		var genA = _v0.a;
		return $elm$random$Random$Generator(
			function (seed) {
				var _v1 = genA(seed);
				var result = _v1.a;
				var newSeed = _v1.b;
				var _v2 = callback(result);
				var genB = _v2.a;
				return genB(newSeed);
			});
	});
var $elm$random$Random$float = F2(
	function (a, b) {
		return $elm$random$Random$Generator(
			function (seed0) {
				var seed1 = $elm$random$Random$next(seed0);
				var range = $elm$core$Basics$abs(b - a);
				var n1 = $elm$random$Random$peel(seed1);
				var n0 = $elm$random$Random$peel(seed0);
				var lo = (134217727 & n1) * 1.0;
				var hi = (67108863 & n0) * 1.0;
				var val = ((hi * 134217728.0) + lo) / 9007199254740992.0;
				var scaled = (val * range) + a;
				return _Utils_Tuple2(
					scaled,
					$elm$random$Random$next(seed1));
			});
	});
var $elm$core$Tuple$second = function (_v0) {
	var y = _v0.b;
	return y;
};
var $elm$core$List$sum = function (numbers) {
	return A3($elm$core$List$foldl, $elm$core$Basics$add, 0, numbers);
};
var $elm_community$random_extra$Random$Extra$frequency = F2(
	function (head, pairs) {
		var total = $elm$core$List$sum(
			A2(
				$elm$core$List$map,
				A2($elm$core$Basics$composeL, $elm$core$Basics$abs, $elm$core$Tuple$first),
				A2($elm$core$List$cons, head, pairs)));
		var pick = F2(
			function (someChoices, n) {
				pick:
				while (true) {
					if (someChoices.b) {
						var _v1 = someChoices.a;
						var k = _v1.a;
						var g = _v1.b;
						var rest = someChoices.b;
						if (_Utils_cmp(n, k) < 1) {
							return g;
						} else {
							var $temp$someChoices = rest,
								$temp$n = n - k;
							someChoices = $temp$someChoices;
							n = $temp$n;
							continue pick;
						}
					} else {
						return head.b;
					}
				}
			});
		return A2(
			$elm$random$Random$andThen,
			pick(
				A2($elm$core$List$cons, head, pairs)),
			A2($elm$random$Random$float, 0, total));
	});
var $elm_community$random_extra$Random$Extra$choices = F2(
	function (hd, gens) {
		return A2(
			$elm_community$random_extra$Random$Extra$frequency,
			_Utils_Tuple2(1, hd),
			A2(
				$elm$core$List$map,
				function (g) {
					return _Utils_Tuple2(1, g);
				},
				gens));
	});
var $elm$core$Char$fromCode = _Char_fromCode;
var $elm_community$random_extra$Random$Char$char = F2(
	function (start, end) {
		return A2(
			$elm$random$Random$map,
			$elm$core$Char$fromCode,
			A2($elm$random$Random$int, start, end));
	});
var $elm_community$random_extra$Random$Char$lowerCaseLatin = A2($elm_community$random_extra$Random$Char$char, 97, 122);
var $elm_community$random_extra$Random$Char$upperCaseLatin = A2($elm_community$random_extra$Random$Char$char, 65, 90);
var $elm_community$random_extra$Random$Char$latin = A2(
	$elm_community$random_extra$Random$Extra$choices,
	$elm_community$random_extra$Random$Char$lowerCaseLatin,
	_List_fromArray(
		[$elm_community$random_extra$Random$Char$upperCaseLatin]));
var $elm_community$random_extra$Random$Char$english = $elm_community$random_extra$Random$Char$latin;
var $elm$core$String$fromList = _String_fromList;
var $elm$random$Random$listHelp = F4(
	function (revList, n, gen, seed) {
		listHelp:
		while (true) {
			if (n < 1) {
				return _Utils_Tuple2(revList, seed);
			} else {
				var _v0 = gen(seed);
				var value = _v0.a;
				var newSeed = _v0.b;
				var $temp$revList = A2($elm$core$List$cons, value, revList),
					$temp$n = n - 1,
					$temp$gen = gen,
					$temp$seed = newSeed;
				revList = $temp$revList;
				n = $temp$n;
				gen = $temp$gen;
				seed = $temp$seed;
				continue listHelp;
			}
		}
	});
var $elm$random$Random$list = F2(
	function (n, _v0) {
		var gen = _v0.a;
		return $elm$random$Random$Generator(
			function (seed) {
				return A4($elm$random$Random$listHelp, _List_Nil, n, gen, seed);
			});
	});
var $elm_community$random_extra$Random$String$string = F2(
	function (stringLength, charGenerator) {
		return A2(
			$elm$random$Random$map,
			$elm$core$String$fromList,
			A2($elm$random$Random$list, stringLength, charGenerator));
	});
var $author$project$Names$nameGenerator = A2($elm_community$random_extra$Random$String$string, 10, $elm_community$random_extra$Random$Char$english);
var $author$project$Names$cacheName = function (channel) {
	return 'elm-realtime' + '-cache';
};
var $author$project$Momento$errorToDetails = function (_v0) {
	var err = _v0.a;
	return err;
};
var $author$project$EventLog$OpenMomentoCache$openMomentoCache = F2(
	function (component, channelName) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$mapError,
			$author$project$Momento$errorToDetails,
			$brian_watkins$elm_procedure$Procedure$fetchResult(
				$author$project$EventLog$Apis$momentoApi.open(
					{
						apiKey: component.momentoApiKey,
						cache: $author$project$Names$cacheName(channelName)
					})));
	});
var $author$project$DB$ChannelTable$encodeKey = function (key) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'id',
				$elm$json$Json$Encode$string(key.id))
			]));
};
var $author$project$DB$ChannelTable$Record = F6(
	function (id, updatedAt, modelTopic, saveTopic, saveList, webhook) {
		return {id: id, modelTopic: modelTopic, saveList: saveList, saveTopic: saveTopic, updatedAt: updatedAt, webhook: webhook};
	});
var $author$project$DB$ChannelTable$posixCodec = A2(
	$miniBill$elm_codec$Codec$build,
	function (timestamp) {
		return $elm$json$Json$Encode$int(
			$elm$time$Time$posixToMillis(timestamp));
	},
	A2($elm$json$Json$Decode$map, $elm$time$Time$millisToPosix, $elm$json$Json$Decode$int));
var $author$project$DB$ChannelTable$recordCodec = $miniBill$elm_codec$Codec$buildObject(
	A4(
		$miniBill$elm_codec$Codec$field,
		'webhook',
		function ($) {
			return $.webhook;
		},
		$miniBill$elm_codec$Codec$string,
		A4(
			$miniBill$elm_codec$Codec$field,
			'saveList',
			function ($) {
				return $.saveList;
			},
			$miniBill$elm_codec$Codec$string,
			A4(
				$miniBill$elm_codec$Codec$field,
				'saveTopic',
				function ($) {
					return $.saveTopic;
				},
				$miniBill$elm_codec$Codec$string,
				A4(
					$miniBill$elm_codec$Codec$field,
					'modelTopic',
					function ($) {
						return $.modelTopic;
					},
					$miniBill$elm_codec$Codec$string,
					A4(
						$miniBill$elm_codec$Codec$field,
						'updatedAt',
						function ($) {
							return $.updatedAt;
						},
						$author$project$DB$ChannelTable$posixCodec,
						A4(
							$miniBill$elm_codec$Codec$field,
							'id',
							function ($) {
								return $.id;
							},
							$miniBill$elm_codec$Codec$string,
							$miniBill$elm_codec$Codec$object($author$project$DB$ChannelTable$Record))))))));
var $author$project$DB$ChannelTable$operations = A3(
	$author$project$AWS$Dynamo$dynamoTypedApi,
	$author$project$DB$ChannelTable$encodeKey,
	$miniBill$elm_codec$Codec$encoder($author$project$DB$ChannelTable$recordCodec),
	$miniBill$elm_codec$Codec$decoder($author$project$DB$ChannelTable$recordCodec));
var $author$project$EventLog$Apis$channelTableApi = A2($author$project$DB$ChannelTable$operations, $author$project$EventLog$Msg$ProcedureMsg, $author$project$EventLog$Apis$dynamoPorts);
var $author$project$Names$modelTopicName = function (channel) {
	return channel + '-modeltopic';
};
var $author$project$Names$notifyTopicName = function (channel) {
	return channel + '-savetopic';
};
var $author$project$Names$saveListName = function (channel) {
	return channel + '-savelist';
};
var $author$project$Names$webhookName = function (channel) {
	return channel + '-webhook';
};
var $author$project$EventLog$CreateChannel$recordChannel = F3(
	function (component, channelName, sessionKey) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (timestamp) {
				var channelRecord = {
					id: channelName,
					modelTopic: $author$project$Names$modelTopicName(channelName),
					saveList: $author$project$Names$saveListName(channelName),
					saveTopic: $author$project$Names$notifyTopicName(channelName),
					updatedAt: timestamp,
					webhook: $author$project$Names$webhookName(channelName)
				};
				return A2(
					$brian_watkins$elm_procedure$Procedure$mapError,
					$author$project$AWS$Dynamo$errorToDetails,
					A2(
						$brian_watkins$elm_procedure$Procedure$map,
						$elm$core$Basics$always(channelRecord),
						$brian_watkins$elm_procedure$Procedure$fetchResult(
							$author$project$EventLog$Apis$channelTableApi.put(
								{item: channelRecord, tableName: component.channelTable}))));
			},
			$brian_watkins$elm_procedure$Procedure$fromTask($elm$time$Time$now));
	});
var $author$project$DB$EventLogTable$MetadataRecord = F4(
	function (id, seq, updatedAt, lastId) {
		return {id: id, lastId: lastId, seq: seq, updatedAt: updatedAt};
	});
var $author$project$DB$EventLogTable$metadataRecordCodec = $miniBill$elm_codec$Codec$buildObject(
	A4(
		$miniBill$elm_codec$Codec$field,
		'lastId',
		function ($) {
			return $.lastId;
		},
		$miniBill$elm_codec$Codec$int,
		A4(
			$miniBill$elm_codec$Codec$field,
			'updatedAt',
			function ($) {
				return $.updatedAt;
			},
			$author$project$DB$EventLogTable$posixCodec,
			A4(
				$miniBill$elm_codec$Codec$field,
				'seq',
				function ($) {
					return $.seq;
				},
				$miniBill$elm_codec$Codec$int,
				A4(
					$miniBill$elm_codec$Codec$field,
					'id',
					function ($) {
						return $.id;
					},
					$miniBill$elm_codec$Codec$string,
					$miniBill$elm_codec$Codec$object($author$project$DB$EventLogTable$MetadataRecord))))));
var $author$project$DB$EventLogTable$metadataOperations = A3(
	$author$project$AWS$Dynamo$dynamoTypedApi,
	$author$project$DB$EventLogTable$encodeKey,
	$miniBill$elm_codec$Codec$encoder($author$project$DB$EventLogTable$metadataRecordCodec),
	$miniBill$elm_codec$Codec$decoder($author$project$DB$EventLogTable$metadataRecordCodec));
var $author$project$EventLog$Apis$eventLogTableMetadataApi = A2($author$project$DB$EventLogTable$metadataOperations, $author$project$EventLog$Msg$ProcedureMsg, $author$project$EventLog$Apis$dynamoPorts);
var $author$project$Names$metadataKeyName = function (channel) {
	return channel + '-metadata';
};
var $author$project$EventLog$CreateChannel$recordEventsLogMetaData = F3(
	function (component, channelName, sessionKey) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (timestamp) {
				var metadataRecord = {
					id: $author$project$Names$metadataKeyName(channelName),
					lastId: 0,
					seq: 0,
					updatedAt: timestamp
				};
				return A2(
					$brian_watkins$elm_procedure$Procedure$mapError,
					$author$project$AWS$Dynamo$errorToDetails,
					A2(
						$brian_watkins$elm_procedure$Procedure$map,
						$elm$core$Basics$always(sessionKey),
						$brian_watkins$elm_procedure$Procedure$fetchResult(
							$author$project$EventLog$Apis$eventLogTableMetadataApi.put(
								{item: metadataRecord, tableName: component.eventLogTable}))));
			},
			$brian_watkins$elm_procedure$Procedure$fromTask($elm$time$Time$now));
	});
var $author$project$EventLog$CreateChannel$setModel = F2(
	function (m, x) {
		return _Utils_update(
			m,
			{eventLog: x});
	});
var $author$project$EventLog$CreateChannel$setupChannelWebhook = F3(
	function (component, channelName, sessionKey) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$map,
			$elm$core$Basics$always(sessionKey),
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				$author$project$Momento$errorToDetails,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					A2(
						$author$project$EventLog$Apis$momentoApi.webhook,
						sessionKey,
						{
							name: $author$project$Names$webhookName(channelName),
							topic: $author$project$Names$notifyTopicName(channelName),
							url: component.channelApiUrl + ('/v1/channel/' + channelName)
						}))));
	});
var $author$project$EventLog$CreateChannel$switchState = F2(
	function (cons, state) {
		return _Utils_Tuple2(
			cons(state),
			$elm$core$Platform$Cmd$none);
	});
var $author$project$EventLog$CreateChannel$createChannel = F3(
	function (session, state, component) {
		var _v0 = A2($elm$random$Random$step, $author$project$Names$nameGenerator, state.seed);
		var channelName = _v0.a;
		var nextSeed = _v0.b;
		var procedure = A2(
			$brian_watkins$elm_procedure$Procedure$map,
			A2(
				$elm$core$Basics$composeR,
				$miniBill$elm_codec$Codec$encoder($author$project$DB$ChannelTable$recordCodec),
				$author$project$Http$Response$ok200json),
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				A2($elm$core$Basics$composeR, $author$project$ErrorFormat$encodeErrorFormat, $author$project$Http$Response$err500json),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$CreateChannel$recordChannel, component, channelName),
					A2(
						$brian_watkins$elm_procedure$Procedure$andThen,
						A2($author$project$EventLog$CreateChannel$recordEventsLogMetaData, component, channelName),
						A2(
							$brian_watkins$elm_procedure$Procedure$andThen,
							A2($author$project$EventLog$CreateChannel$setupChannelWebhook, component, channelName),
							A2(
								$brian_watkins$elm_procedure$Procedure$andThen,
								$author$project$EventLog$OpenMomentoCache$openMomentoCache(component),
								$brian_watkins$elm_procedure$Procedure$provide(channelName)))))));
		return A2(
			$elm$core$Tuple$mapFirst,
			$author$project$EventLog$CreateChannel$setModel(component),
			A2(
				$the_sett$elm_update_helper$Update2$andMap,
				$author$project$EventLog$CreateChannel$switchState($author$project$EventLog$Model$ModelReady),
				_Utils_Tuple2(
					{cache: state.cache, procedure: state.procedure, seed: nextSeed},
					A3(
						$brian_watkins$elm_procedure$Procedure$try,
						$author$project$EventLog$Msg$ProcedureMsg,
						$author$project$EventLog$Msg$HttpResponse(session),
						procedure))));
	});
var $elm$core$List$head = function (list) {
	if (list.b) {
		var x = list.a;
		var xs = list.b;
		return $elm$core$Maybe$Just(x);
	} else {
		return $elm$core$Maybe$Nothing;
	}
};
var $author$project$EventLog$GetAvailableChannel$findAvailableChannel = F2(
	function (component, _v0) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$mapError,
			$author$project$AWS$Dynamo$errorToDetails,
			A2(
				$brian_watkins$elm_procedure$Procedure$map,
				$elm$core$List$head,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					$author$project$EventLog$Apis$channelTableApi.scan(
						{exclusiveStartKey: $elm$core$Maybe$Nothing, tableName: component.channelTable}))));
	});
var $author$project$Http$Response$notFound400json = function (err) {
	return A2(
		$author$project$Http$Response$setStatus,
		400,
		A2(
			$author$project$Http$Response$setBody,
			$author$project$Http$Body$json(err),
			$author$project$Http$Response$init));
};
var $author$project$EventLog$GetAvailableChannel$setModel = F2(
	function (m, x) {
		return _Utils_update(
			m,
			{eventLog: x});
	});
var $author$project$EventLog$GetAvailableChannel$switchState = F2(
	function (cons, state) {
		return _Utils_Tuple2(
			cons(state),
			$elm$core$Platform$Cmd$none);
	});
var $author$project$EventLog$GetAvailableChannel$getAvailableChannel = F3(
	function (session, state, component) {
		var procedure = A2(
			$brian_watkins$elm_procedure$Procedure$map,
			function (maybeChannel) {
				if (maybeChannel.$ === 'Just') {
					var channel = maybeChannel.a;
					return $author$project$Http$Response$ok200json(
						A2($miniBill$elm_codec$Codec$encoder, $author$project$DB$ChannelTable$recordCodec, channel));
				} else {
					return $author$project$Http$Response$notFound400json($elm$json$Json$Encode$null);
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				A2($elm$core$Basics$composeR, $author$project$ErrorFormat$encodeErrorFormat, $author$project$Http$Response$err500json),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					$author$project$EventLog$GetAvailableChannel$findAvailableChannel(component),
					$brian_watkins$elm_procedure$Procedure$provide(_Utils_Tuple0))));
		return A2(
			$elm$core$Tuple$mapFirst,
			$author$project$EventLog$GetAvailableChannel$setModel(component),
			A2(
				$the_sett$elm_update_helper$Update2$andMap,
				$author$project$EventLog$GetAvailableChannel$switchState($author$project$EventLog$Model$ModelReady),
				_Utils_Tuple2(
					state,
					A3(
						$brian_watkins$elm_procedure$Procedure$try,
						$author$project$EventLog$Msg$ProcedureMsg,
						$author$project$EventLog$Msg$HttpResponse(session),
						procedure))));
	});
var $author$project$Http$Request$method = function (_v0) {
	var request = _v0.a;
	return request.method;
};
var $author$project$Realtime$encodePersistedEvent = F2(
	function (seq, payload) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'rt',
					$elm$json$Json$Encode$string('P')),
					_Utils_Tuple2(
					'seq',
					$elm$json$Json$Encode$int(seq)),
					_Utils_Tuple2('payload', payload)
				]));
	});
var $author$project$Realtime$encodeSnapshotEvent = F2(
	function (seq, payload) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'rt',
					$elm$json$Json$Encode$string('R')),
					_Utils_Tuple2(
					'seq',
					$elm$json$Json$Encode$int(seq)),
					_Utils_Tuple2('payload', payload)
				]));
	});
var $author$project$EventLog$JoinChannel$fetchSavedEventsSince = F3(
	function (component, channelName, state) {
		var startSeq = function () {
			var _v2 = state.maybeLatest;
			if (_v2.$ === 'Just') {
				var latest = _v2.a;
				return latest.seq;
			} else {
				return 1;
			}
		}();
		var match = A2(
			$author$project$AWS$Dynamo$orderResults,
			$author$project$AWS$Dynamo$Forward,
			A3(
				$author$project$AWS$Dynamo$rangeKeyGreaterThan,
				'seq',
				$author$project$AWS$Dynamo$int(startSeq),
				A2($author$project$AWS$Dynamo$partitionKeyEquals, 'id', channelName)));
		var query = {match: match, tableName: component.eventLogTable};
		var _v0 = A2($elm$core$Debug$log, 'JoinChannel.fetchSavedEventsSince', 'called');
		var _v1 = A2($elm$core$Debug$log, 'state', state);
		return A2(
			$brian_watkins$elm_procedure$Procedure$map,
			function (events) {
				return {cache: state.cache, laterEvents: events, maybeLatest: state.maybeLatest};
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				$author$project$AWS$Dynamo$errorToDetails,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					$author$project$EventLog$Apis$eventLogTableApi.query(query))));
	});
var $author$project$EventLog$JoinChannel$setModel = F2(
	function (m, x) {
		return _Utils_update(
			m,
			{eventLog: x});
	});
var $author$project$EventLog$JoinChannel$switchState = F2(
	function (cons, state) {
		return _Utils_Tuple2(
			cons(state),
			$elm$core$Platform$Cmd$none);
	});
var $author$project$EventLog$JoinChannel$procedure = F5(
	function (session, state, apiRequest, channelName, component) {
		var encodeEvent = function (record) {
			return A2($author$project$Realtime$encodePersistedEvent, record.seq, record.event);
		};
		var response = F2(
			function (snapshot, events) {
				return A2(
					$elm$json$Json$Encode$list,
					$elm$core$Basics$identity,
					A2(
						$elm$core$List$filterMap,
						$elm$core$Basics$identity,
						A2(
							$elm$core$List$cons,
							A2(
								$elm$core$Maybe$map,
								function (s) {
									return A2($author$project$Realtime$encodeSnapshotEvent, s.seq, s.model);
								},
								snapshot),
							A2(
								$elm$core$List$map,
								function (event) {
									return $elm$core$Maybe$Just(
										encodeEvent(event));
								},
								events))));
			});
		var innerProcedure = A2(
			$brian_watkins$elm_procedure$Procedure$map,
			function (_v1) {
				var maybeLatest = _v1.maybeLatest;
				var laterEvents = _v1.laterEvents;
				return $author$project$Http$Response$ok200json(
					A2(response, maybeLatest, laterEvents));
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				A2(
					$elm$core$Basics$composeR,
					$elm$core$Debug$log('error'),
					A2($elm$core$Basics$composeR, $author$project$ErrorFormat$encodeErrorFormat, $author$project$Http$Response$err500json)),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$JoinChannel$fetchSavedEventsSince, component, channelName),
					A2(
						$brian_watkins$elm_procedure$Procedure$andThen,
						A2($author$project$EventLog$LatestSnapshot$getLatestSnapshotFromTable, component, channelName),
						$brian_watkins$elm_procedure$Procedure$provide(
							{cache: state.cache})))));
		var _v0 = A2($elm$core$Debug$log, 'JoinChannel.procedure', 'called');
		return A2(
			$elm$core$Tuple$mapFirst,
			$author$project$EventLog$JoinChannel$setModel(component),
			A2(
				$the_sett$elm_update_helper$Update2$andMap,
				$author$project$EventLog$JoinChannel$switchState($author$project$EventLog$Model$ModelReady),
				_Utils_Tuple2(
					state,
					A3(
						$brian_watkins$elm_procedure$Procedure$try,
						$author$project$EventLog$Msg$ProcedureMsg,
						$author$project$EventLog$Msg$HttpResponse(session),
						innerProcedure))));
	});
var $author$project$EventLog$SaveChannel$DrainedNothing = function (a) {
	return {$: 'DrainedNothing', a: a};
};
var $author$project$EventLog$SaveChannel$DrainedToSeq = function (a) {
	return {$: 'DrainedToSeq', a: a};
};
var $author$project$EventLog$SaveChannel$publishEvent = F3(
	function (component, channelName, state) {
		var payload = A2($author$project$Realtime$encodePersistedEvent, state.lastSeqNo, state.unsavedEvent.payload);
		return A2(
			$brian_watkins$elm_procedure$Procedure$mapError,
			$author$project$Momento$errorToDetails,
			A2(
				$brian_watkins$elm_procedure$Procedure$map,
				$elm$core$Basics$always(state),
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					A2(
						$author$project$EventLog$Apis$momentoApi.publish,
						state.sessionKey,
						{
							payload: payload,
							topic: $author$project$Names$modelTopicName(channelName)
						}))));
	});
var $author$project$EventLog$SaveChannel$getEventsLogMetaData = F3(
	function (component, channelName, state) {
		var key = {
			id: $author$project$Names$metadataKeyName(channelName),
			seq: 0
		};
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (maybeMetaData) {
				if (maybeMetaData.$ === 'Just') {
					var metadata = maybeMetaData.a;
					return $brian_watkins$elm_procedure$Procedure$provide(
						{lastSeqNo: metadata.lastId, sessionKey: state.sessionKey, unsavedEvent: state.unsavedEvent});
				} else {
					return $brian_watkins$elm_procedure$Procedure$break(
						{details: $elm$json$Json$Encode$null, message: 'No EventLog metadata record found for channel: ' + channelName});
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				$author$project$AWS$Dynamo$errorToDetails,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					$author$project$EventLog$Apis$eventLogTableMetadataApi.get(
						{key: key, tableName: component.eventLogTable}))));
	});
var $brian_watkins$elm_procedure$Procedure$catch = F2(
	function (generator, procedure) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$next,
			procedure,
			function (aResult) {
				if (aResult.$ === 'Ok') {
					var aData = aResult.a;
					return $brian_watkins$elm_procedure$Procedure$provide(aData);
				} else {
					var eData = aResult.a;
					return generator(eData);
				}
			});
	});
var $author$project$DB$EventLogTable$encodeRecord = $miniBill$elm_codec$Codec$encoder($author$project$DB$EventLogTable$recordCodec);
var $author$project$AWS$Dynamo$PutCommand = function (a) {
	return {$: 'PutCommand', a: a};
};
var $author$project$AWS$Dynamo$putCommand = F2(
	function (encoder, putProps) {
		return $author$project$AWS$Dynamo$PutCommand(
			A2($author$project$AWS$Dynamo$putEncoder, encoder, putProps));
	});
var $author$project$AWS$Dynamo$UpdateCommand = function (a) {
	return {$: 'UpdateCommand', a: a};
};
var $author$project$AWS$Dynamo$updateCommand = F2(
	function (encoder, updateProps) {
		return $author$project$AWS$Dynamo$UpdateCommand(
			A2($author$project$AWS$Dynamo$updateEncoder, encoder, updateProps));
	});
var $author$project$EventLog$SaveChannel$recordEventsAndMetadata = F3(
	function (component, channelName, state) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (timestamp) {
				var seqUpdate = A2(
					$author$project$AWS$Dynamo$updateCommand,
					$author$project$DB$EventLogTable$encodeKey,
					{
						conditionExpression: $elm$core$Maybe$Just('lastId = :current_id'),
						expressionAttributeNames: $elm$core$Dict$empty,
						expressionAttributeValues: $elm$core$Dict$fromList(
							_List_fromArray(
								[
									_Utils_Tuple2(
									':incr',
									$author$project$AWS$Dynamo$int(1)),
									_Utils_Tuple2(
									':current_id',
									$author$project$AWS$Dynamo$int(state.lastSeqNo))
								])),
						key: {
							id: $author$project$Names$metadataKeyName(channelName),
							seq: 0
						},
						returnConsumedCapacity: $elm$core$Maybe$Nothing,
						returnItemCollectionMetrics: $elm$core$Maybe$Nothing,
						returnValues: $elm$core$Maybe$Nothing,
						returnValuesOnConditionCheckFailure: $elm$core$Maybe$Nothing,
						tableName: component.eventLogTable,
						updateExpression: 'SET lastId = lastId + :incr'
					});
				var assignedSeqNo = state.lastSeqNo + 1;
				var eventRecord = {event: state.unsavedEvent.payload, id: channelName, seq: assignedSeqNo, updatedAt: timestamp};
				var eventPut = A2(
					$author$project$AWS$Dynamo$putCommand,
					$author$project$DB$EventLogTable$encodeRecord,
					{item: eventRecord, tableName: component.eventLogTable});
				return A2(
					$brian_watkins$elm_procedure$Procedure$catch,
					function (error) {
						if (error.$ === 'ConditionCheckFailed') {
							return $brian_watkins$elm_procedure$Procedure$provide(
								{lastSeqNo: assignedSeqNo, sessionKey: state.sessionKey, txSuccess: false, unsavedEvent: state.unsavedEvent});
						} else {
							return $brian_watkins$elm_procedure$Procedure$break(
								$author$project$AWS$Dynamo$errorToDetails(error));
						}
					},
					A2(
						$brian_watkins$elm_procedure$Procedure$map,
						$elm$core$Basics$always(
							{lastSeqNo: assignedSeqNo, sessionKey: state.sessionKey, txSuccess: true, unsavedEvent: state.unsavedEvent}),
						$brian_watkins$elm_procedure$Procedure$fetchResult(
							$author$project$EventLog$Apis$eventLogTableMetadataApi.writeTx(
								{
									commands: _List_fromArray(
										[seqUpdate, eventPut]),
									tableName: component.eventLogTable
								}))));
			},
			$brian_watkins$elm_procedure$Procedure$fromTask($elm$time$Time$now));
	});
var $author$project$EventLog$SaveChannel$recordEventWithUniqueSeqNo = F3(
	function (component, channelName, state) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (stateAfterTxAttempt) {
				return stateAfterTxAttempt.txSuccess ? $brian_watkins$elm_procedure$Procedure$provide(stateAfterTxAttempt) : A3(
					$author$project$EventLog$SaveChannel$recordEventWithUniqueSeqNo,
					component,
					channelName,
					{sessionKey: stateAfterTxAttempt.sessionKey, unsavedEvent: stateAfterTxAttempt.unsavedEvent});
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$andThen,
				A2($author$project$EventLog$SaveChannel$recordEventsAndMetadata, component, channelName),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$SaveChannel$getEventsLogMetaData, component, channelName),
					$brian_watkins$elm_procedure$Procedure$provide(state))));
	});
var $author$project$Realtime$UnsavedEvent = F2(
	function (rt, payload) {
		return {payload: payload, rt: rt};
	});
var $author$project$Realtime$unsavedEventDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (ctor) {
		if (ctor === 'U') {
			return A2(
				$elm_community$json_extra$Json$Decode$Extra$andMap,
				A2($elm$json$Json$Decode$field, 'payload', $elm$json$Json$Decode$value),
				A2(
					$elm_community$json_extra$Json$Decode$Extra$andMap,
					$elm$json$Json$Decode$succeed('U'),
					$elm$json$Json$Decode$succeed($author$project$Realtime$UnsavedEvent)));
		} else {
			return $elm$json$Json$Decode$fail('Unrecognized constructor');
		}
	},
	A2($elm$json$Json$Decode$field, 'rt', $elm$json$Json$Decode$string));
var $author$project$EventLog$SaveChannel$tryReadEvent = F3(
	function (component, channelName, sessionKey) {
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (maybeCacheItem) {
				if (maybeCacheItem.$ === 'Just') {
					var cacheItem = maybeCacheItem.a;
					var _v1 = A2($elm$json$Json$Decode$decodeValue, $author$project$Realtime$unsavedEventDecoder, cacheItem.payload);
					if (_v1.$ === 'Ok') {
						var unsavedEvent = _v1.a;
						return $brian_watkins$elm_procedure$Procedure$provide(
							{
								sessionKey: sessionKey,
								unsavedEvent: $elm$core$Maybe$Just(unsavedEvent)
							});
					} else {
						var err = _v1.a;
						return $brian_watkins$elm_procedure$Procedure$break(
							{
								details: $elm$json$Json$Encode$null,
								message: $elm$json$Json$Decode$errorToString(err)
							});
					}
				} else {
					return $brian_watkins$elm_procedure$Procedure$provide(
						{sessionKey: sessionKey, unsavedEvent: $elm$core$Maybe$Nothing});
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				$author$project$Momento$errorToDetails,
				$brian_watkins$elm_procedure$Procedure$fetchResult(
					A2(
						$author$project$EventLog$Apis$momentoApi.popList,
						sessionKey,
						{
							list: $author$project$Names$saveListName(channelName)
						}))));
	});
var $author$project$EventLog$SaveChannel$drainSaveListInner = F3(
	function (component, channelName, state) {
		var msk = function () {
			if (state.$ === 'DrainedNothing') {
				var sessionKey = state.a;
				return sessionKey;
			} else {
				var sessionKey = state.a.sessionKey;
				return sessionKey;
			}
		}();
		return A2(
			$brian_watkins$elm_procedure$Procedure$andThen,
			function (innerState) {
				var _v0 = innerState.unsavedEvent;
				if (_v0.$ === 'Nothing') {
					return $brian_watkins$elm_procedure$Procedure$provide(state);
				} else {
					var event = _v0.a;
					return A2(
						$brian_watkins$elm_procedure$Procedure$andThen,
						A2($author$project$EventLog$SaveChannel$drainSaveListInner, component, channelName),
						A2(
							$brian_watkins$elm_procedure$Procedure$map,
							function (_v1) {
								var sessionKey = _v1.sessionKey;
								var lastSeqNo = _v1.lastSeqNo;
								return $author$project$EventLog$SaveChannel$DrainedToSeq(
									{lastSeqNo: lastSeqNo, sessionKey: sessionKey});
							},
							A2(
								$brian_watkins$elm_procedure$Procedure$andThen,
								A2($author$project$EventLog$SaveChannel$publishEvent, component, channelName),
								A2(
									$brian_watkins$elm_procedure$Procedure$andThen,
									A2($author$project$EventLog$SaveChannel$recordEventWithUniqueSeqNo, component, channelName),
									$brian_watkins$elm_procedure$Procedure$provide(
										{sessionKey: msk, unsavedEvent: event})))));
				}
			},
			A2(
				$brian_watkins$elm_procedure$Procedure$andThen,
				A2($author$project$EventLog$SaveChannel$tryReadEvent, component, channelName),
				$brian_watkins$elm_procedure$Procedure$provide(msk)));
	});
var $author$project$EventLog$SaveChannel$drainSaveList = F3(
	function (component, channelName, sessionKey) {
		return A3(
			$author$project$EventLog$SaveChannel$drainSaveListInner,
			component,
			channelName,
			$author$project$EventLog$SaveChannel$DrainedNothing(sessionKey));
	});
var $elm$core$Debug$toString = _Debug_toString;
var $author$project$EventLog$SaveChannel$awsErrorToDetails = function (err) {
	if (err.$ === 'HttpError') {
		var hterr = err.a;
		return {
			details: $elm$json$Json$Encode$null,
			message: 'Http.Error: ' + $elm$core$Debug$toString(hterr)
		};
	} else {
		var awserr = err.a;
		return {
			details: $elm$json$Json$Encode$null,
			message: 'AWSError: ' + (awserr.type_ + (' ' + A2($elm$core$Maybe$withDefault, '', awserr.message)))
		};
	}
};
var $author$project$Realtime$encodeSnapshotRequestEvent = F2(
	function (channel, seq) {
		return $elm$json$Json$Encode$object(
			_List_fromArray(
				[
					_Utils_Tuple2(
					'rt',
					$elm$json$Json$Encode$string('S')),
					_Utils_Tuple2(
					'channel',
					$elm$json$Json$Encode$string(channel)),
					_Utils_Tuple2(
					'seq',
					$elm$json$Json$Encode$int(seq))
				]));
	});
var $elm$core$Basics$modBy = _Basics_modBy;
var $elm$http$Http$BadBody = function (a) {
	return {$: 'BadBody', a: a};
};
var $the_sett$elm_aws_core$AWS$Internal$Error$HttpError = function (a) {
	return {$: 'HttpError', a: a};
};
var $the_sett$elm_aws_core$AWS$Http$addHeaders = F2(
	function (headers, req) {
		return _Utils_update(
			req,
			{
				headers: A2($elm$core$List$append, req.headers, headers)
			});
	});
var $the_sett$elm_aws_core$AWS$Http$AWSError = function (a) {
	return {$: 'AWSError', a: a};
};
var $the_sett$elm_aws_core$AWS$Http$HttpError = function (a) {
	return {$: 'HttpError', a: a};
};
var $the_sett$elm_aws_core$AWS$Http$internalErrToErr = function (error) {
	if (error.$ === 'HttpError') {
		var err = error.a;
		return $the_sett$elm_aws_core$AWS$Http$HttpError(err);
	} else {
		var err = error.a;
		return $the_sett$elm_aws_core$AWS$Http$AWSError(err);
	}
};
var $elm$core$Task$mapError = F2(
	function (convert, task) {
		return A2(
			$elm$core$Task$onError,
			A2($elm$core$Basics$composeL, $elm$core$Task$fail, convert),
			task);
	});
var $the_sett$elm_aws_core$AWS$Internal$Error$AWSError = function (a) {
	return {$: 'AWSError', a: a};
};
var $elm$http$Http$BadUrl = function (a) {
	return {$: 'BadUrl', a: a};
};
var $elm$http$Http$NetworkError = {$: 'NetworkError'};
var $elm$http$Http$Timeout = {$: 'Timeout'};
var $the_sett$elm_aws_core$AWS$Internal$V4$algorithm = 'AWS4-HMAC-SHA256';
var $the_sett$elm_aws_core$AWS$Internal$Canonical$joinHeader = function (_v0) {
	var key = _v0.a;
	var val = _v0.b;
	return key + (':' + val);
};
var $the_sett$elm_aws_core$AWS$Internal$Canonical$mergeSameHeaders = F2(
	function (_v0, acc) {
		var key1 = _v0.a;
		var val1 = _v0.b;
		if (acc.b) {
			var _v2 = acc.a;
			var key0 = _v2.a;
			var val0 = _v2.b;
			var rest = acc.b;
			return _Utils_eq(key0, key1) ? A2(
				$elm$core$List$cons,
				_Utils_Tuple2(key0, val0 + (',' + val1)),
				rest) : A2(
				$elm$core$List$cons,
				_Utils_Tuple2(key1, val1),
				A2(
					$elm$core$List$cons,
					_Utils_Tuple2(key0, val0),
					rest));
		} else {
			return A2(
				$elm$core$List$cons,
				_Utils_Tuple2(key1, val1),
				acc);
		}
	});
var $elm$regex$Regex$Match = F4(
	function (match, index, number, submatches) {
		return {index: index, match: match, number: number, submatches: submatches};
	});
var $elm$regex$Regex$fromStringWith = _Regex_fromStringWith;
var $elm$regex$Regex$fromString = function (string) {
	return A2(
		$elm$regex$Regex$fromStringWith,
		{caseInsensitive: false, multiline: false},
		string);
};
var $elm$regex$Regex$never = _Regex_never;
var $elm$regex$Regex$replace = _Regex_replaceAtMost(_Regex_infinity);
var $the_sett$elm_aws_core$AWS$Internal$Canonical$normalizeHeader = function (_v0) {
	var key = _v0.a;
	var val = _v0.b;
	return _Utils_Tuple2(
		$elm$core$String$toLower(key),
		A3(
			$elm$regex$Regex$replace,
			A2(
				$elm$core$Maybe$withDefault,
				$elm$regex$Regex$never,
				$elm$regex$Regex$fromString('\\s{2,}')),
			function (_v3) {
				return ' ';
			},
			A3(
				$elm$regex$Regex$replace,
				A2(
					$elm$core$Maybe$withDefault,
					$elm$regex$Regex$never,
					$elm$regex$Regex$fromString('(^\\s*|\\s*$)')),
				function (_v2) {
					return '';
				},
				A3(
					$elm$regex$Regex$replace,
					A2(
						$elm$core$Maybe$withDefault,
						$elm$regex$Regex$never,
						$elm$regex$Regex$fromString('\\s*?\n\\s*')),
					function (_v1) {
						return ',';
					},
					val))));
};
var $elm$core$List$sortBy = _List_sortBy;
var $elm$core$List$sort = function (xs) {
	return A2($elm$core$List$sortBy, $elm$core$Basics$identity, xs);
};
var $the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalHeaders = function (headers) {
	return A2(
		$elm$core$String$join,
		'\n',
		$elm$core$List$sort(
			A2(
				$elm$core$List$map,
				$the_sett$elm_aws_core$AWS$Internal$Canonical$joinHeader,
				A3(
					$elm$core$List$foldl,
					$the_sett$elm_aws_core$AWS$Internal$Canonical$mergeSameHeaders,
					_List_Nil,
					A2($elm$core$List$map, $the_sett$elm_aws_core$AWS$Internal$Canonical$normalizeHeader, headers)))));
};
var $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256 = {$: 'SHA256'};
var $ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars = F8(
	function (a, b, c, d, e, f, g, h) {
		return {a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h};
	});
var $ktonon$elm_word$Word$D = F2(
	function (a, b) {
		return {$: 'D', a: a, b: b};
	});
var $ktonon$elm_word$Word$Mismatch = {$: 'Mismatch'};
var $ktonon$elm_word$Word$W = function (a) {
	return {$: 'W', a: a};
};
var $ktonon$elm_word$Word$low31mask = 2147483647;
var $ktonon$elm_word$Word$carry32 = F2(
	function (x, y) {
		var _v0 = (x >>> 31) + (y >>> 31);
		switch (_v0) {
			case 0:
				return 0;
			case 2:
				return 1;
			default:
				return (1 === ((($ktonon$elm_word$Word$low31mask & x) + ($ktonon$elm_word$Word$low31mask & y)) >>> 31)) ? 1 : 0;
		}
	});
var $elm$core$Basics$pow = _Basics_pow;
var $ktonon$elm_word$Word$mod32 = function (val) {
	return A2(
		$elm$core$Basics$modBy,
		A2($elm$core$Basics$pow, 2, 32),
		val);
};
var $ktonon$elm_word$Word$add = F2(
	function (wx, wy) {
		var _v0 = _Utils_Tuple2(wx, wy);
		_v0$2:
		while (true) {
			switch (_v0.a.$) {
				case 'W':
					if (_v0.b.$ === 'W') {
						var x = _v0.a.a;
						var y = _v0.b.a;
						return $ktonon$elm_word$Word$W(
							$ktonon$elm_word$Word$mod32(x + y));
					} else {
						break _v0$2;
					}
				case 'D':
					if (_v0.b.$ === 'D') {
						var _v1 = _v0.a;
						var xh = _v1.a;
						var xl = _v1.b;
						var _v2 = _v0.b;
						var yh = _v2.a;
						var yl = _v2.b;
						var zl = xl + yl;
						var zh = (xh + yh) + A2($ktonon$elm_word$Word$carry32, xl, yl);
						return A2(
							$ktonon$elm_word$Word$D,
							$ktonon$elm_word$Word$mod32(zh),
							$ktonon$elm_word$Word$mod32(zl));
					} else {
						break _v0$2;
					}
				default:
					break _v0$2;
			}
		}
		return $ktonon$elm_word$Word$Mismatch;
	});
var $ktonon$elm_crypto$Crypto$SHA$Types$addWorkingVars = F2(
	function (x, y) {
		return A8(
			$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
			A2($ktonon$elm_word$Word$add, x.a, y.a),
			A2($ktonon$elm_word$Word$add, x.b, y.b),
			A2($ktonon$elm_word$Word$add, x.c, y.c),
			A2($ktonon$elm_word$Word$add, x.d, y.d),
			A2($ktonon$elm_word$Word$add, x.e, y.e),
			A2($ktonon$elm_word$Word$add, x.f, y.f),
			A2($ktonon$elm_word$Word$add, x.g, y.g),
			A2($ktonon$elm_word$Word$add, x.h, y.h));
	});
var $ktonon$elm_word$Word$and = F2(
	function (wx, wy) {
		var _v0 = _Utils_Tuple2(wx, wy);
		_v0$2:
		while (true) {
			switch (_v0.a.$) {
				case 'W':
					if (_v0.b.$ === 'W') {
						var x = _v0.a.a;
						var y = _v0.b.a;
						return $ktonon$elm_word$Word$W(x & y);
					} else {
						break _v0$2;
					}
				case 'D':
					if (_v0.b.$ === 'D') {
						var _v1 = _v0.a;
						var xh = _v1.a;
						var xl = _v1.b;
						var _v2 = _v0.b;
						var yh = _v2.a;
						var yl = _v2.b;
						return A2($ktonon$elm_word$Word$D, xh & yh, xl & yl);
					} else {
						break _v0$2;
					}
				default:
					break _v0$2;
			}
		}
		return $ktonon$elm_word$Word$Mismatch;
	});
var $elm$core$Bitwise$complement = _Bitwise_complement;
var $ktonon$elm_word$Word$complement = function (word) {
	switch (word.$) {
		case 'W':
			var x = word.a;
			return $ktonon$elm_word$Word$W(~x);
		case 'D':
			var xh = word.a;
			var xl = word.b;
			return A2($ktonon$elm_word$Word$D, ~xh, ~xl);
		default:
			return $ktonon$elm_word$Word$Mismatch;
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512 = {$: 'SHA512'};
var $ktonon$elm_word$Word$Helpers$lowMask = function (n) {
	switch (n) {
		case 0:
			return 0;
		case 1:
			return 1;
		case 2:
			return 3;
		case 3:
			return 7;
		case 4:
			return 15;
		case 5:
			return 31;
		case 6:
			return 63;
		case 7:
			return 127;
		case 8:
			return 255;
		case 9:
			return 511;
		case 10:
			return 1023;
		case 11:
			return 2047;
		case 12:
			return 4095;
		case 13:
			return 8191;
		case 14:
			return 16383;
		case 15:
			return 32767;
		case 16:
			return 65535;
		case 17:
			return 131071;
		case 18:
			return 262143;
		case 19:
			return 524287;
		case 20:
			return 1048575;
		case 21:
			return 2097151;
		case 22:
			return 4194303;
		case 23:
			return 8388607;
		case 24:
			return 16777215;
		case 25:
			return 33554431;
		case 26:
			return 67108863;
		case 27:
			return 134217727;
		case 28:
			return 268435455;
		case 29:
			return 536870911;
		case 30:
			return 1073741823;
		case 31:
			return 2147483647;
		default:
			return 4294967295;
	}
};
var $ktonon$elm_word$Word$Helpers$safeShiftRightZfBy = F2(
	function (n, val) {
		return (n >= 32) ? 0 : (val >>> n);
	});
var $elm$core$Bitwise$shiftLeftBy = _Bitwise_shiftLeftBy;
var $ktonon$elm_word$Word$dShiftRightZfBy = F2(
	function (n, _v0) {
		var xh = _v0.a;
		var xl = _v0.b;
		return (n > 32) ? _Utils_Tuple2(
			0,
			A2($ktonon$elm_word$Word$Helpers$safeShiftRightZfBy, n - 32, xh)) : _Utils_Tuple2(
			A2($ktonon$elm_word$Word$Helpers$safeShiftRightZfBy, n, xh),
			A2($ktonon$elm_word$Word$Helpers$safeShiftRightZfBy, n, xl) + (($ktonon$elm_word$Word$Helpers$lowMask(n) & xh) << (32 - n)));
	});
var $ktonon$elm_word$Word$Helpers$rotatedLowBits = F2(
	function (n, val) {
		return $elm$core$Basics$add(
			($ktonon$elm_word$Word$Helpers$lowMask(n) & val) << (32 - n));
	});
var $ktonon$elm_word$Word$rotateRightBy = F2(
	function (unboundN, word) {
		switch (word.$) {
			case 'W':
				var x = word.a;
				var n = A2($elm$core$Basics$modBy, 32, unboundN);
				return $ktonon$elm_word$Word$W(
					A3(
						$ktonon$elm_word$Word$Helpers$rotatedLowBits,
						n,
						x,
						A2($ktonon$elm_word$Word$Helpers$safeShiftRightZfBy, n, x)));
			case 'D':
				var xh = word.a;
				var xl = word.b;
				var n = A2($elm$core$Basics$modBy, 64, unboundN);
				if (n > 32) {
					var n_ = n - 32;
					var _v1 = A2(
						$ktonon$elm_word$Word$dShiftRightZfBy,
						n_,
						_Utils_Tuple2(xl, xh));
					var zh = _v1.a;
					var zl = _v1.b;
					return A2(
						$ktonon$elm_word$Word$D,
						A3($ktonon$elm_word$Word$Helpers$rotatedLowBits, n_, xh, zh),
						zl);
				} else {
					var _v2 = A2(
						$ktonon$elm_word$Word$dShiftRightZfBy,
						n,
						_Utils_Tuple2(xh, xl));
					var zh = _v2.a;
					var zl = _v2.b;
					return A2(
						$ktonon$elm_word$Word$D,
						A3($ktonon$elm_word$Word$Helpers$rotatedLowBits, n, xl, zh),
						zl);
				}
			default:
				return $ktonon$elm_word$Word$Mismatch;
		}
	});
var $ktonon$elm_word$Word$xor = F2(
	function (wx, wy) {
		var _v0 = _Utils_Tuple2(wx, wy);
		_v0$2:
		while (true) {
			switch (_v0.a.$) {
				case 'W':
					if (_v0.b.$ === 'W') {
						var x = _v0.a.a;
						var y = _v0.b.a;
						return $ktonon$elm_word$Word$W(x ^ y);
					} else {
						break _v0$2;
					}
				case 'D':
					if (_v0.b.$ === 'D') {
						var _v1 = _v0.a;
						var xh = _v1.a;
						var xl = _v1.b;
						var _v2 = _v0.b;
						var yh = _v2.a;
						var yl = _v2.b;
						return A2($ktonon$elm_word$Word$D, xh ^ yh, xl ^ yl);
					} else {
						break _v0$2;
					}
				default:
					break _v0$2;
			}
		}
		return $ktonon$elm_word$Word$Mismatch;
	});
var $ktonon$elm_crypto$Crypto$SHA$Process$sum0 = F2(
	function (alg, word) {
		sum0:
		while (true) {
			switch (alg.$) {
				case 'SHA224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum0;
				case 'SHA384':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum0;
				case 'SHA256':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$rotateRightBy, 22, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 13, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 2, word)));
				case 'SHA512':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$rotateRightBy, 39, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 34, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 28, word)));
				case 'SHA512_224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum0;
				default:
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum0;
			}
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$Process$sum1 = F2(
	function (alg, word) {
		sum1:
		while (true) {
			switch (alg.$) {
				case 'SHA224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum1;
				case 'SHA384':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum1;
				case 'SHA256':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$rotateRightBy, 25, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 11, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 6, word)));
				case 'SHA512':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$rotateRightBy, 41, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 18, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 14, word)));
				case 'SHA512_224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum1;
				default:
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sum1;
			}
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$Process$compress = F3(
	function (alg, _v0, _v1) {
		var k = _v0.a;
		var w = _v0.b;
		var a = _v1.a;
		var b = _v1.b;
		var c = _v1.c;
		var d = _v1.d;
		var e = _v1.e;
		var f = _v1.f;
		var g = _v1.g;
		var h = _v1.h;
		var s1 = A2($ktonon$elm_crypto$Crypto$SHA$Process$sum1, alg, e);
		var s0 = A2($ktonon$elm_crypto$Crypto$SHA$Process$sum0, alg, a);
		var maj = A2(
			$ktonon$elm_word$Word$xor,
			A2($ktonon$elm_word$Word$and, b, c),
			A2(
				$ktonon$elm_word$Word$xor,
				A2($ktonon$elm_word$Word$and, a, c),
				A2($ktonon$elm_word$Word$and, a, b)));
		var temp2 = A2($ktonon$elm_word$Word$add, s0, maj);
		var ch = A2(
			$ktonon$elm_word$Word$xor,
			A2(
				$ktonon$elm_word$Word$and,
				g,
				$ktonon$elm_word$Word$complement(e)),
			A2($ktonon$elm_word$Word$and, e, f));
		var temp1 = A2(
			$ktonon$elm_word$Word$add,
			w,
			A2(
				$ktonon$elm_word$Word$add,
				k,
				A2(
					$ktonon$elm_word$Word$add,
					ch,
					A2($ktonon$elm_word$Word$add, s1, h))));
		return A8(
			$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
			A2($ktonon$elm_word$Word$add, temp1, temp2),
			a,
			b,
			c,
			A2($ktonon$elm_word$Word$add, d, temp1),
			e,
			f,
			g);
	});
var $ktonon$elm_crypto$Crypto$SHA$Constants$roundConstants = function (alg) {
	roundConstants:
	while (true) {
		switch (alg.$) {
			case 'SHA224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256;
				alg = $temp$alg;
				continue roundConstants;
			case 'SHA256':
				return _List_fromArray(
					[
						$ktonon$elm_word$Word$W(1116352408),
						$ktonon$elm_word$Word$W(1899447441),
						$ktonon$elm_word$Word$W(3049323471),
						$ktonon$elm_word$Word$W(3921009573),
						$ktonon$elm_word$Word$W(961987163),
						$ktonon$elm_word$Word$W(1508970993),
						$ktonon$elm_word$Word$W(2453635748),
						$ktonon$elm_word$Word$W(2870763221),
						$ktonon$elm_word$Word$W(3624381080),
						$ktonon$elm_word$Word$W(310598401),
						$ktonon$elm_word$Word$W(607225278),
						$ktonon$elm_word$Word$W(1426881987),
						$ktonon$elm_word$Word$W(1925078388),
						$ktonon$elm_word$Word$W(2162078206),
						$ktonon$elm_word$Word$W(2614888103),
						$ktonon$elm_word$Word$W(3248222580),
						$ktonon$elm_word$Word$W(3835390401),
						$ktonon$elm_word$Word$W(4022224774),
						$ktonon$elm_word$Word$W(264347078),
						$ktonon$elm_word$Word$W(604807628),
						$ktonon$elm_word$Word$W(770255983),
						$ktonon$elm_word$Word$W(1249150122),
						$ktonon$elm_word$Word$W(1555081692),
						$ktonon$elm_word$Word$W(1996064986),
						$ktonon$elm_word$Word$W(2554220882),
						$ktonon$elm_word$Word$W(2821834349),
						$ktonon$elm_word$Word$W(2952996808),
						$ktonon$elm_word$Word$W(3210313671),
						$ktonon$elm_word$Word$W(3336571891),
						$ktonon$elm_word$Word$W(3584528711),
						$ktonon$elm_word$Word$W(113926993),
						$ktonon$elm_word$Word$W(338241895),
						$ktonon$elm_word$Word$W(666307205),
						$ktonon$elm_word$Word$W(773529912),
						$ktonon$elm_word$Word$W(1294757372),
						$ktonon$elm_word$Word$W(1396182291),
						$ktonon$elm_word$Word$W(1695183700),
						$ktonon$elm_word$Word$W(1986661051),
						$ktonon$elm_word$Word$W(2177026350),
						$ktonon$elm_word$Word$W(2456956037),
						$ktonon$elm_word$Word$W(2730485921),
						$ktonon$elm_word$Word$W(2820302411),
						$ktonon$elm_word$Word$W(3259730800),
						$ktonon$elm_word$Word$W(3345764771),
						$ktonon$elm_word$Word$W(3516065817),
						$ktonon$elm_word$Word$W(3600352804),
						$ktonon$elm_word$Word$W(4094571909),
						$ktonon$elm_word$Word$W(275423344),
						$ktonon$elm_word$Word$W(430227734),
						$ktonon$elm_word$Word$W(506948616),
						$ktonon$elm_word$Word$W(659060556),
						$ktonon$elm_word$Word$W(883997877),
						$ktonon$elm_word$Word$W(958139571),
						$ktonon$elm_word$Word$W(1322822218),
						$ktonon$elm_word$Word$W(1537002063),
						$ktonon$elm_word$Word$W(1747873779),
						$ktonon$elm_word$Word$W(1955562222),
						$ktonon$elm_word$Word$W(2024104815),
						$ktonon$elm_word$Word$W(2227730452),
						$ktonon$elm_word$Word$W(2361852424),
						$ktonon$elm_word$Word$W(2428436474),
						$ktonon$elm_word$Word$W(2756734187),
						$ktonon$elm_word$Word$W(3204031479),
						$ktonon$elm_word$Word$W(3329325298)
					]);
			case 'SHA384':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue roundConstants;
			case 'SHA512':
				return _List_fromArray(
					[
						A2($ktonon$elm_word$Word$D, 1116352408, 3609767458),
						A2($ktonon$elm_word$Word$D, 1899447441, 602891725),
						A2($ktonon$elm_word$Word$D, 3049323471, 3964484399),
						A2($ktonon$elm_word$Word$D, 3921009573, 2173295548),
						A2($ktonon$elm_word$Word$D, 961987163, 4081628472),
						A2($ktonon$elm_word$Word$D, 1508970993, 3053834265),
						A2($ktonon$elm_word$Word$D, 2453635748, 2937671579),
						A2($ktonon$elm_word$Word$D, 2870763221, 3664609560),
						A2($ktonon$elm_word$Word$D, 3624381080, 2734883394),
						A2($ktonon$elm_word$Word$D, 310598401, 1164996542),
						A2($ktonon$elm_word$Word$D, 607225278, 1323610764),
						A2($ktonon$elm_word$Word$D, 1426881987, 3590304994),
						A2($ktonon$elm_word$Word$D, 1925078388, 4068182383),
						A2($ktonon$elm_word$Word$D, 2162078206, 991336113),
						A2($ktonon$elm_word$Word$D, 2614888103, 633803317),
						A2($ktonon$elm_word$Word$D, 3248222580, 3479774868),
						A2($ktonon$elm_word$Word$D, 3835390401, 2666613458),
						A2($ktonon$elm_word$Word$D, 4022224774, 944711139),
						A2($ktonon$elm_word$Word$D, 264347078, 2341262773),
						A2($ktonon$elm_word$Word$D, 604807628, 2007800933),
						A2($ktonon$elm_word$Word$D, 770255983, 1495990901),
						A2($ktonon$elm_word$Word$D, 1249150122, 1856431235),
						A2($ktonon$elm_word$Word$D, 1555081692, 3175218132),
						A2($ktonon$elm_word$Word$D, 1996064986, 2198950837),
						A2($ktonon$elm_word$Word$D, 2554220882, 3999719339),
						A2($ktonon$elm_word$Word$D, 2821834349, 766784016),
						A2($ktonon$elm_word$Word$D, 2952996808, 2566594879),
						A2($ktonon$elm_word$Word$D, 3210313671, 3203337956),
						A2($ktonon$elm_word$Word$D, 3336571891, 1034457026),
						A2($ktonon$elm_word$Word$D, 3584528711, 2466948901),
						A2($ktonon$elm_word$Word$D, 113926993, 3758326383),
						A2($ktonon$elm_word$Word$D, 338241895, 168717936),
						A2($ktonon$elm_word$Word$D, 666307205, 1188179964),
						A2($ktonon$elm_word$Word$D, 773529912, 1546045734),
						A2($ktonon$elm_word$Word$D, 1294757372, 1522805485),
						A2($ktonon$elm_word$Word$D, 1396182291, 2643833823),
						A2($ktonon$elm_word$Word$D, 1695183700, 2343527390),
						A2($ktonon$elm_word$Word$D, 1986661051, 1014477480),
						A2($ktonon$elm_word$Word$D, 2177026350, 1206759142),
						A2($ktonon$elm_word$Word$D, 2456956037, 344077627),
						A2($ktonon$elm_word$Word$D, 2730485921, 1290863460),
						A2($ktonon$elm_word$Word$D, 2820302411, 3158454273),
						A2($ktonon$elm_word$Word$D, 3259730800, 3505952657),
						A2($ktonon$elm_word$Word$D, 3345764771, 106217008),
						A2($ktonon$elm_word$Word$D, 3516065817, 3606008344),
						A2($ktonon$elm_word$Word$D, 3600352804, 1432725776),
						A2($ktonon$elm_word$Word$D, 4094571909, 1467031594),
						A2($ktonon$elm_word$Word$D, 275423344, 851169720),
						A2($ktonon$elm_word$Word$D, 430227734, 3100823752),
						A2($ktonon$elm_word$Word$D, 506948616, 1363258195),
						A2($ktonon$elm_word$Word$D, 659060556, 3750685593),
						A2($ktonon$elm_word$Word$D, 883997877, 3785050280),
						A2($ktonon$elm_word$Word$D, 958139571, 3318307427),
						A2($ktonon$elm_word$Word$D, 1322822218, 3812723403),
						A2($ktonon$elm_word$Word$D, 1537002063, 2003034995),
						A2($ktonon$elm_word$Word$D, 1747873779, 3602036899),
						A2($ktonon$elm_word$Word$D, 1955562222, 1575990012),
						A2($ktonon$elm_word$Word$D, 2024104815, 1125592928),
						A2($ktonon$elm_word$Word$D, 2227730452, 2716904306),
						A2($ktonon$elm_word$Word$D, 2361852424, 442776044),
						A2($ktonon$elm_word$Word$D, 2428436474, 593698344),
						A2($ktonon$elm_word$Word$D, 2756734187, 3733110249),
						A2($ktonon$elm_word$Word$D, 3204031479, 2999351573),
						A2($ktonon$elm_word$Word$D, 3329325298, 3815920427),
						A2($ktonon$elm_word$Word$D, 3391569614, 3928383900),
						A2($ktonon$elm_word$Word$D, 3515267271, 566280711),
						A2($ktonon$elm_word$Word$D, 3940187606, 3454069534),
						A2($ktonon$elm_word$Word$D, 4118630271, 4000239992),
						A2($ktonon$elm_word$Word$D, 116418474, 1914138554),
						A2($ktonon$elm_word$Word$D, 174292421, 2731055270),
						A2($ktonon$elm_word$Word$D, 289380356, 3203993006),
						A2($ktonon$elm_word$Word$D, 460393269, 320620315),
						A2($ktonon$elm_word$Word$D, 685471733, 587496836),
						A2($ktonon$elm_word$Word$D, 852142971, 1086792851),
						A2($ktonon$elm_word$Word$D, 1017036298, 365543100),
						A2($ktonon$elm_word$Word$D, 1126000580, 2618297676),
						A2($ktonon$elm_word$Word$D, 1288033470, 3409855158),
						A2($ktonon$elm_word$Word$D, 1501505948, 4234509866),
						A2($ktonon$elm_word$Word$D, 1607167915, 987167468),
						A2($ktonon$elm_word$Word$D, 1816402316, 1246189591)
					]);
			case 'SHA512_224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue roundConstants;
			default:
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue roundConstants;
		}
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Process$compressLoop = F3(
	function (alg, workingVars, messageSchedule) {
		return A3(
			$elm$core$List$foldl,
			$ktonon$elm_crypto$Crypto$SHA$Process$compress(alg),
			workingVars,
			A3(
				$elm$core$List$map2,
				F2(
					function (a, b) {
						return _Utils_Tuple2(a, b);
					}),
				$ktonon$elm_crypto$Crypto$SHA$Constants$roundConstants(alg),
				$elm$core$Array$toList(messageSchedule)));
	});
var $elm$core$Array$fromListHelp = F3(
	function (list, nodeList, nodeListSize) {
		fromListHelp:
		while (true) {
			var _v0 = A2($elm$core$Elm$JsArray$initializeFromList, $elm$core$Array$branchFactor, list);
			var jsArray = _v0.a;
			var remainingItems = _v0.b;
			if (_Utils_cmp(
				$elm$core$Elm$JsArray$length(jsArray),
				$elm$core$Array$branchFactor) < 0) {
				return A2(
					$elm$core$Array$builderToArray,
					true,
					{nodeList: nodeList, nodeListSize: nodeListSize, tail: jsArray});
			} else {
				var $temp$list = remainingItems,
					$temp$nodeList = A2(
					$elm$core$List$cons,
					$elm$core$Array$Leaf(jsArray),
					nodeList),
					$temp$nodeListSize = nodeListSize + 1;
				list = $temp$list;
				nodeList = $temp$nodeList;
				nodeListSize = $temp$nodeListSize;
				continue fromListHelp;
			}
		}
	});
var $elm$core$Array$fromList = function (list) {
	if (!list.b) {
		return $elm$core$Array$empty;
	} else {
		return A3($elm$core$Array$fromListHelp, list, _List_Nil, 0);
	}
};
var $elm$core$Elm$JsArray$appendN = _JsArray_appendN;
var $elm$core$Elm$JsArray$slice = _JsArray_slice;
var $elm$core$Array$appendHelpBuilder = F2(
	function (tail, builder) {
		var tailLen = $elm$core$Elm$JsArray$length(tail);
		var notAppended = ($elm$core$Array$branchFactor - $elm$core$Elm$JsArray$length(builder.tail)) - tailLen;
		var appended = A3($elm$core$Elm$JsArray$appendN, $elm$core$Array$branchFactor, builder.tail, tail);
		return (notAppended < 0) ? {
			nodeList: A2(
				$elm$core$List$cons,
				$elm$core$Array$Leaf(appended),
				builder.nodeList),
			nodeListSize: builder.nodeListSize + 1,
			tail: A3($elm$core$Elm$JsArray$slice, notAppended, tailLen, tail)
		} : ((!notAppended) ? {
			nodeList: A2(
				$elm$core$List$cons,
				$elm$core$Array$Leaf(appended),
				builder.nodeList),
			nodeListSize: builder.nodeListSize + 1,
			tail: $elm$core$Elm$JsArray$empty
		} : {nodeList: builder.nodeList, nodeListSize: builder.nodeListSize, tail: appended});
	});
var $elm$core$Array$bitMask = 4294967295 >>> (32 - $elm$core$Array$shiftStep);
var $elm$core$Elm$JsArray$push = _JsArray_push;
var $elm$core$Elm$JsArray$singleton = _JsArray_singleton;
var $elm$core$Elm$JsArray$unsafeGet = _JsArray_unsafeGet;
var $elm$core$Elm$JsArray$unsafeSet = _JsArray_unsafeSet;
var $elm$core$Array$insertTailInTree = F4(
	function (shift, index, tail, tree) {
		var pos = $elm$core$Array$bitMask & (index >>> shift);
		if (_Utils_cmp(
			pos,
			$elm$core$Elm$JsArray$length(tree)) > -1) {
			if (shift === 5) {
				return A2(
					$elm$core$Elm$JsArray$push,
					$elm$core$Array$Leaf(tail),
					tree);
			} else {
				var newSub = $elm$core$Array$SubTree(
					A4($elm$core$Array$insertTailInTree, shift - $elm$core$Array$shiftStep, index, tail, $elm$core$Elm$JsArray$empty));
				return A2($elm$core$Elm$JsArray$push, newSub, tree);
			}
		} else {
			var value = A2($elm$core$Elm$JsArray$unsafeGet, pos, tree);
			if (value.$ === 'SubTree') {
				var subTree = value.a;
				var newSub = $elm$core$Array$SubTree(
					A4($elm$core$Array$insertTailInTree, shift - $elm$core$Array$shiftStep, index, tail, subTree));
				return A3($elm$core$Elm$JsArray$unsafeSet, pos, newSub, tree);
			} else {
				var newSub = $elm$core$Array$SubTree(
					A4(
						$elm$core$Array$insertTailInTree,
						shift - $elm$core$Array$shiftStep,
						index,
						tail,
						$elm$core$Elm$JsArray$singleton(value)));
				return A3($elm$core$Elm$JsArray$unsafeSet, pos, newSub, tree);
			}
		}
	});
var $elm$core$Array$unsafeReplaceTail = F2(
	function (newTail, _v0) {
		var len = _v0.a;
		var startShift = _v0.b;
		var tree = _v0.c;
		var tail = _v0.d;
		var originalTailLen = $elm$core$Elm$JsArray$length(tail);
		var newTailLen = $elm$core$Elm$JsArray$length(newTail);
		var newArrayLen = len + (newTailLen - originalTailLen);
		if (_Utils_eq(newTailLen, $elm$core$Array$branchFactor)) {
			var overflow = _Utils_cmp(newArrayLen >>> $elm$core$Array$shiftStep, 1 << startShift) > 0;
			if (overflow) {
				var newShift = startShift + $elm$core$Array$shiftStep;
				var newTree = A4(
					$elm$core$Array$insertTailInTree,
					newShift,
					len,
					newTail,
					$elm$core$Elm$JsArray$singleton(
						$elm$core$Array$SubTree(tree)));
				return A4($elm$core$Array$Array_elm_builtin, newArrayLen, newShift, newTree, $elm$core$Elm$JsArray$empty);
			} else {
				return A4(
					$elm$core$Array$Array_elm_builtin,
					newArrayLen,
					startShift,
					A4($elm$core$Array$insertTailInTree, startShift, len, newTail, tree),
					$elm$core$Elm$JsArray$empty);
			}
		} else {
			return A4($elm$core$Array$Array_elm_builtin, newArrayLen, startShift, tree, newTail);
		}
	});
var $elm$core$Array$appendHelpTree = F2(
	function (toAppend, array) {
		var len = array.a;
		var tree = array.c;
		var tail = array.d;
		var itemsToAppend = $elm$core$Elm$JsArray$length(toAppend);
		var notAppended = ($elm$core$Array$branchFactor - $elm$core$Elm$JsArray$length(tail)) - itemsToAppend;
		var appended = A3($elm$core$Elm$JsArray$appendN, $elm$core$Array$branchFactor, tail, toAppend);
		var newArray = A2($elm$core$Array$unsafeReplaceTail, appended, array);
		if (notAppended < 0) {
			var nextTail = A3($elm$core$Elm$JsArray$slice, notAppended, itemsToAppend, toAppend);
			return A2($elm$core$Array$unsafeReplaceTail, nextTail, newArray);
		} else {
			return newArray;
		}
	});
var $elm$core$Elm$JsArray$foldl = _JsArray_foldl;
var $elm$core$Array$builderFromArray = function (_v0) {
	var len = _v0.a;
	var tree = _v0.c;
	var tail = _v0.d;
	var helper = F2(
		function (node, acc) {
			if (node.$ === 'SubTree') {
				var subTree = node.a;
				return A3($elm$core$Elm$JsArray$foldl, helper, acc, subTree);
			} else {
				return A2($elm$core$List$cons, node, acc);
			}
		});
	return {
		nodeList: A3($elm$core$Elm$JsArray$foldl, helper, _List_Nil, tree),
		nodeListSize: (len / $elm$core$Array$branchFactor) | 0,
		tail: tail
	};
};
var $elm$core$Array$append = F2(
	function (a, _v0) {
		var aTail = a.d;
		var bLen = _v0.a;
		var bTree = _v0.c;
		var bTail = _v0.d;
		if (_Utils_cmp(bLen, $elm$core$Array$branchFactor * 4) < 1) {
			var foldHelper = F2(
				function (node, array) {
					if (node.$ === 'SubTree') {
						var tree = node.a;
						return A3($elm$core$Elm$JsArray$foldl, foldHelper, array, tree);
					} else {
						var leaf = node.a;
						return A2($elm$core$Array$appendHelpTree, leaf, array);
					}
				});
			return A2(
				$elm$core$Array$appendHelpTree,
				bTail,
				A3($elm$core$Elm$JsArray$foldl, foldHelper, a, bTree));
		} else {
			var foldHelper = F2(
				function (node, builder) {
					if (node.$ === 'SubTree') {
						var tree = node.a;
						return A3($elm$core$Elm$JsArray$foldl, foldHelper, builder, tree);
					} else {
						var leaf = node.a;
						return A2($elm$core$Array$appendHelpBuilder, leaf, builder);
					}
				});
			return A2(
				$elm$core$Array$builderToArray,
				true,
				A2(
					$elm$core$Array$appendHelpBuilder,
					bTail,
					A3(
						$elm$core$Elm$JsArray$foldl,
						foldHelper,
						$elm$core$Array$builderFromArray(a),
						bTree)));
		}
	});
var $elm$core$Array$getHelp = F3(
	function (shift, index, tree) {
		getHelp:
		while (true) {
			var pos = $elm$core$Array$bitMask & (index >>> shift);
			var _v0 = A2($elm$core$Elm$JsArray$unsafeGet, pos, tree);
			if (_v0.$ === 'SubTree') {
				var subTree = _v0.a;
				var $temp$shift = shift - $elm$core$Array$shiftStep,
					$temp$index = index,
					$temp$tree = subTree;
				shift = $temp$shift;
				index = $temp$index;
				tree = $temp$tree;
				continue getHelp;
			} else {
				var values = _v0.a;
				return A2($elm$core$Elm$JsArray$unsafeGet, $elm$core$Array$bitMask & index, values);
			}
		}
	});
var $elm$core$Array$tailIndex = function (len) {
	return (len >>> 5) << 5;
};
var $elm$core$Array$get = F2(
	function (index, _v0) {
		var len = _v0.a;
		var startShift = _v0.b;
		var tree = _v0.c;
		var tail = _v0.d;
		return ((index < 0) || (_Utils_cmp(index, len) > -1)) ? $elm$core$Maybe$Nothing : ((_Utils_cmp(
			index,
			$elm$core$Array$tailIndex(len)) > -1) ? $elm$core$Maybe$Just(
			A2($elm$core$Elm$JsArray$unsafeGet, $elm$core$Array$bitMask & index, tail)) : $elm$core$Maybe$Just(
			A3($elm$core$Array$getHelp, startShift, index, tree)));
	});
var $ktonon$elm_crypto$Crypto$SHA$MessageSchedule$at = function (i) {
	return A2(
		$elm$core$Basics$composeR,
		$elm$core$Array$get(i),
		$elm$core$Maybe$withDefault($ktonon$elm_word$Word$Mismatch));
};
var $ktonon$elm_word$Word$shiftRightZfBy = F2(
	function (n, word) {
		switch (word.$) {
			case 'W':
				var x = word.a;
				return $ktonon$elm_word$Word$W(
					A2($ktonon$elm_word$Word$Helpers$safeShiftRightZfBy, n, x));
			case 'D':
				var xh = word.a;
				var xl = word.b;
				var _v1 = A2(
					$ktonon$elm_word$Word$dShiftRightZfBy,
					n,
					_Utils_Tuple2(xh, xl));
				var zh = _v1.a;
				var zl = _v1.b;
				return A2($ktonon$elm_word$Word$D, zh, zl);
			default:
				return $ktonon$elm_word$Word$Mismatch;
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$MessageSchedule$sigma0 = F2(
	function (alg, word) {
		sigma0:
		while (true) {
			switch (alg.$) {
				case 'SHA224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma0;
				case 'SHA384':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma0;
				case 'SHA256':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$shiftRightZfBy, 3, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 18, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 7, word)));
				case 'SHA512':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$shiftRightZfBy, 7, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 8, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 1, word)));
				case 'SHA512_224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma0;
				default:
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma0;
			}
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$MessageSchedule$sigma1 = F2(
	function (alg, word) {
		sigma1:
		while (true) {
			switch (alg.$) {
				case 'SHA224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma1;
				case 'SHA384':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma1;
				case 'SHA256':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$shiftRightZfBy, 10, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 19, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 17, word)));
				case 'SHA512':
					return A2(
						$ktonon$elm_word$Word$xor,
						A2($ktonon$elm_word$Word$shiftRightZfBy, 6, word),
						A2(
							$ktonon$elm_word$Word$xor,
							A2($ktonon$elm_word$Word$rotateRightBy, 61, word),
							A2($ktonon$elm_word$Word$rotateRightBy, 19, word)));
				case 'SHA512_224':
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma1;
				default:
					var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512,
						$temp$word = word;
					alg = $temp$alg;
					word = $temp$word;
					continue sigma1;
			}
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$MessageSchedule$nextPart = F3(
	function (alg, i, w) {
		var i2 = A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$at, i - 2, w);
		var s1 = A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$sigma1, alg, i2);
		var i15 = A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$at, i - 15, w);
		var s0 = A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$sigma0, alg, i15);
		return A2(
			$elm$core$Array$append,
			w,
			$elm$core$Array$fromList(
				_List_fromArray(
					[
						A2(
						$ktonon$elm_word$Word$add,
						s1,
						A2(
							$ktonon$elm_word$Word$add,
							A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$at, i - 7, w),
							A2(
								$ktonon$elm_word$Word$add,
								s0,
								A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$at, i - 16, w))))
					])));
	});
var $ktonon$elm_crypto$Crypto$SHA$MessageSchedule$fromChunk = F2(
	function (alg, chunk) {
		var n = $elm$core$List$length(
			$ktonon$elm_crypto$Crypto$SHA$Constants$roundConstants(alg));
		return A3(
			$elm$core$List$foldl,
			$ktonon$elm_crypto$Crypto$SHA$MessageSchedule$nextPart(alg),
			$elm$core$Array$fromList(chunk),
			A2($elm$core$List$range, 16, n - 1));
	});
var $elm$core$List$isEmpty = function (xs) {
	if (!xs.b) {
		return true;
	} else {
		return false;
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInBytes = function (alg) {
	sizeInBytes:
	while (true) {
		switch (alg.$) {
			case 'SHA224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256;
				alg = $temp$alg;
				continue sizeInBytes;
			case 'SHA256':
				return 64;
			case 'SHA384':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue sizeInBytes;
			case 'SHA512':
				return 128;
			case 'SHA512_224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue sizeInBytes;
			default:
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue sizeInBytes;
		}
	}
};
var $ktonon$elm_word$Word$sizeInBytes = function (s) {
	if (s.$ === 'Bit32') {
		return 4;
	} else {
		return 8;
	}
};
var $ktonon$elm_word$Word$Bit32 = {$: 'Bit32'};
var $ktonon$elm_word$Word$Bit64 = {$: 'Bit64'};
var $ktonon$elm_crypto$Crypto$SHA$Alg$wordSize = function (alg) {
	wordSize:
	while (true) {
		switch (alg.$) {
			case 'SHA224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256;
				alg = $temp$alg;
				continue wordSize;
			case 'SHA256':
				return $ktonon$elm_word$Word$Bit32;
			case 'SHA384':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue wordSize;
			case 'SHA512':
				return $ktonon$elm_word$Word$Bit64;
			case 'SHA512_224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue wordSize;
			default:
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue wordSize;
		}
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInWords = function (alg) {
	return ($ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInBytes(alg) / $ktonon$elm_word$Word$sizeInBytes(
		$ktonon$elm_crypto$Crypto$SHA$Alg$wordSize(alg))) | 0;
};
var $ktonon$elm_crypto$Crypto$SHA$Chunk$next = F2(
	function (alg, words) {
		var n = $ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInWords(alg);
		var chunk = A2($elm$core$List$take, n, words);
		return _Utils_Tuple2(
			$elm$core$List$isEmpty(chunk) ? $elm$core$Maybe$Nothing : $elm$core$Maybe$Just(chunk),
			A2($elm$core$List$drop, n, words));
	});
var $ktonon$elm_crypto$Crypto$SHA$Process$chunks_ = F3(
	function (alg, words, currentHash) {
		chunks_:
		while (true) {
			var _v0 = A2($ktonon$elm_crypto$Crypto$SHA$Chunk$next, alg, words);
			if (_v0.a.$ === 'Nothing') {
				var _v1 = _v0.a;
				return currentHash;
			} else {
				var chunk = _v0.a.a;
				var rest = _v0.b;
				var vars = A2(
					$ktonon$elm_crypto$Crypto$SHA$Types$addWorkingVars,
					currentHash,
					A3(
						$ktonon$elm_crypto$Crypto$SHA$Process$compressLoop,
						alg,
						currentHash,
						A2($ktonon$elm_crypto$Crypto$SHA$MessageSchedule$fromChunk, alg, chunk)));
				var $temp$alg = alg,
					$temp$words = rest,
					$temp$currentHash = vars;
				alg = $temp$alg;
				words = $temp$words;
				currentHash = $temp$currentHash;
				continue chunks_;
			}
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$Constants$initialHashValues = function (alg) {
	switch (alg.$) {
		case 'SHA224':
			return A8(
				$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
				$ktonon$elm_word$Word$W(3238371032),
				$ktonon$elm_word$Word$W(914150663),
				$ktonon$elm_word$Word$W(812702999),
				$ktonon$elm_word$Word$W(4144912697),
				$ktonon$elm_word$Word$W(4290775857),
				$ktonon$elm_word$Word$W(1750603025),
				$ktonon$elm_word$Word$W(1694076839),
				$ktonon$elm_word$Word$W(3204075428));
		case 'SHA256':
			return A8(
				$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
				$ktonon$elm_word$Word$W(1779033703),
				$ktonon$elm_word$Word$W(3144134277),
				$ktonon$elm_word$Word$W(1013904242),
				$ktonon$elm_word$Word$W(2773480762),
				$ktonon$elm_word$Word$W(1359893119),
				$ktonon$elm_word$Word$W(2600822924),
				$ktonon$elm_word$Word$W(528734635),
				$ktonon$elm_word$Word$W(1541459225));
		case 'SHA384':
			return A8(
				$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
				A2($ktonon$elm_word$Word$D, 3418070365, 3238371032),
				A2($ktonon$elm_word$Word$D, 1654270250, 914150663),
				A2($ktonon$elm_word$Word$D, 2438529370, 812702999),
				A2($ktonon$elm_word$Word$D, 355462360, 4144912697),
				A2($ktonon$elm_word$Word$D, 1731405415, 4290775857),
				A2($ktonon$elm_word$Word$D, 2394180231, 1750603025),
				A2($ktonon$elm_word$Word$D, 3675008525, 1694076839),
				A2($ktonon$elm_word$Word$D, 1203062813, 3204075428));
		case 'SHA512':
			return A8(
				$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
				A2($ktonon$elm_word$Word$D, 1779033703, 4089235720),
				A2($ktonon$elm_word$Word$D, 3144134277, 2227873595),
				A2($ktonon$elm_word$Word$D, 1013904242, 4271175723),
				A2($ktonon$elm_word$Word$D, 2773480762, 1595750129),
				A2($ktonon$elm_word$Word$D, 1359893119, 2917565137),
				A2($ktonon$elm_word$Word$D, 2600822924, 725511199),
				A2($ktonon$elm_word$Word$D, 528734635, 4215389547),
				A2($ktonon$elm_word$Word$D, 1541459225, 327033209));
		case 'SHA512_224':
			return A8(
				$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
				A2($ktonon$elm_word$Word$D, 2352822216, 424955298),
				A2($ktonon$elm_word$Word$D, 1944164710, 2312950998),
				A2($ktonon$elm_word$Word$D, 502970286, 855612546),
				A2($ktonon$elm_word$Word$D, 1738396948, 1479516111),
				A2($ktonon$elm_word$Word$D, 258812777, 2077511080),
				A2($ktonon$elm_word$Word$D, 2011393907, 79989058),
				A2($ktonon$elm_word$Word$D, 1067287976, 1780299464),
				A2($ktonon$elm_word$Word$D, 286451373, 2446758561));
		default:
			return A8(
				$ktonon$elm_crypto$Crypto$SHA$Types$WorkingVars,
				A2($ktonon$elm_word$Word$D, 573645204, 4230739756),
				A2($ktonon$elm_word$Word$D, 2673172387, 3360449730),
				A2($ktonon$elm_word$Word$D, 596883563, 1867755857),
				A2($ktonon$elm_word$Word$D, 2520282905, 1497426621),
				A2($ktonon$elm_word$Word$D, 2519219938, 2827943907),
				A2($ktonon$elm_word$Word$D, 3193839141, 1401305490),
				A2($ktonon$elm_word$Word$D, 721525244, 746961066),
				A2($ktonon$elm_word$Word$D, 246885852, 2177182882));
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Types$toSingleWord = function (word) {
	if (word.$ === 'D') {
		var xh = word.a;
		var xl = word.b;
		return _List_fromArray(
			[
				$ktonon$elm_word$Word$W(xh),
				$ktonon$elm_word$Word$W(xl)
			]);
	} else {
		return _List_fromArray(
			[word]);
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Types$workingVarsToWords = F2(
	function (alg, _v0) {
		var a = _v0.a;
		var b = _v0.b;
		var c = _v0.c;
		var d = _v0.d;
		var e = _v0.e;
		var f = _v0.f;
		var g = _v0.g;
		var h = _v0.h;
		switch (alg.$) {
			case 'SHA224':
				return $elm$core$Array$fromList(
					_List_fromArray(
						[a, b, c, d, e, f, g]));
			case 'SHA256':
				return $elm$core$Array$fromList(
					_List_fromArray(
						[a, b, c, d, e, f, g, h]));
			case 'SHA384':
				return $elm$core$Array$fromList(
					_List_fromArray(
						[a, b, c, d, e, f]));
			case 'SHA512':
				return $elm$core$Array$fromList(
					_List_fromArray(
						[a, b, c, d, e, f, g, h]));
			case 'SHA512_224':
				return $elm$core$Array$fromList(
					A2(
						$elm$core$List$take,
						7,
						A2(
							$elm$core$List$concatMap,
							$ktonon$elm_crypto$Crypto$SHA$Types$toSingleWord,
							_List_fromArray(
								[a, b, c, d]))));
			default:
				return $elm$core$Array$fromList(
					_List_fromArray(
						[a, b, c, d]));
		}
	});
var $ktonon$elm_crypto$Crypto$SHA$Process$chunks = F2(
	function (alg, words) {
		return A2(
			$ktonon$elm_crypto$Crypto$SHA$Types$workingVarsToWords,
			alg,
			A3(
				$ktonon$elm_crypto$Crypto$SHA$Process$chunks_,
				alg,
				$elm$core$Array$toList(words),
				$ktonon$elm_crypto$Crypto$SHA$Constants$initialHashValues(alg)));
	});
var $ktonon$elm_word$Word$FourBytes = F4(
	function (a, b, c, d) {
		return {$: 'FourBytes', a: a, b: b, c: c, d: d};
	});
var $ktonon$elm_word$Word$int32FromBytes = function (_v0) {
	var x3 = _v0.a;
	var x2 = _v0.b;
	var x1 = _v0.c;
	var x0 = _v0.d;
	return ((x0 + (x1 * A2($elm$core$Basics$pow, 2, 8))) + (x2 * A2($elm$core$Basics$pow, 2, 16))) + (x3 * A2($elm$core$Basics$pow, 2, 24));
};
var $ktonon$elm_word$Word$pad4 = function (bytes) {
	_v0$4:
	while (true) {
		if (bytes.b) {
			if (bytes.b.b) {
				if (bytes.b.b.b) {
					if (bytes.b.b.b.b) {
						if (!bytes.b.b.b.b.b) {
							var x3 = bytes.a;
							var _v1 = bytes.b;
							var x2 = _v1.a;
							var _v2 = _v1.b;
							var x1 = _v2.a;
							var _v3 = _v2.b;
							var x0 = _v3.a;
							return A4($ktonon$elm_word$Word$FourBytes, x3, x2, x1, x0);
						} else {
							break _v0$4;
						}
					} else {
						var x3 = bytes.a;
						var _v4 = bytes.b;
						var x2 = _v4.a;
						var _v5 = _v4.b;
						var x1 = _v5.a;
						return A4($ktonon$elm_word$Word$FourBytes, x3, x2, x1, 0);
					}
				} else {
					var x3 = bytes.a;
					var _v6 = bytes.b;
					var x2 = _v6.a;
					return A4($ktonon$elm_word$Word$FourBytes, x3, x2, 0, 0);
				}
			} else {
				var x3 = bytes.a;
				return A4($ktonon$elm_word$Word$FourBytes, x3, 0, 0, 0);
			}
		} else {
			break _v0$4;
		}
	}
	return A4($ktonon$elm_word$Word$FourBytes, 0, 0, 0, 0);
};
var $elm$core$Array$push = F2(
	function (a, array) {
		var tail = array.d;
		return A2(
			$elm$core$Array$unsafeReplaceTail,
			A2($elm$core$Elm$JsArray$push, a, tail),
			array);
	});
var $ktonon$elm_word$Word$accWords = F3(
	function (wordSize, bytes, acc) {
		accWords:
		while (true) {
			var _v0 = _Utils_Tuple2(wordSize, bytes);
			_v0$2:
			while (true) {
				if (_v0.a.$ === 'Bit32') {
					if (_v0.b.b) {
						if ((_v0.b.b.b && _v0.b.b.b.b) && _v0.b.b.b.b.b) {
							var _v1 = _v0.a;
							var _v2 = _v0.b;
							var x3 = _v2.a;
							var _v3 = _v2.b;
							var x2 = _v3.a;
							var _v4 = _v3.b;
							var x1 = _v4.a;
							var _v5 = _v4.b;
							var x0 = _v5.a;
							var rest = _v5.b;
							var acc2 = A2(
								$elm$core$Array$push,
								$ktonon$elm_word$Word$W(
									$ktonon$elm_word$Word$int32FromBytes(
										A4($ktonon$elm_word$Word$FourBytes, x3, x2, x1, x0))),
								acc);
							var $temp$wordSize = wordSize,
								$temp$bytes = rest,
								$temp$acc = acc2;
							wordSize = $temp$wordSize;
							bytes = $temp$bytes;
							acc = $temp$acc;
							continue accWords;
						} else {
							var _v15 = _v0.a;
							var rest = _v0.b;
							return A2(
								$elm$core$Array$push,
								$ktonon$elm_word$Word$W(
									$ktonon$elm_word$Word$int32FromBytes(
										$ktonon$elm_word$Word$pad4(rest))),
								acc);
						}
					} else {
						break _v0$2;
					}
				} else {
					if (_v0.b.b) {
						if ((((((_v0.b.b.b && _v0.b.b.b.b) && _v0.b.b.b.b.b) && _v0.b.b.b.b.b.b) && _v0.b.b.b.b.b.b.b) && _v0.b.b.b.b.b.b.b.b) && _v0.b.b.b.b.b.b.b.b.b) {
							var _v6 = _v0.a;
							var _v7 = _v0.b;
							var x7 = _v7.a;
							var _v8 = _v7.b;
							var x6 = _v8.a;
							var _v9 = _v8.b;
							var x5 = _v9.a;
							var _v10 = _v9.b;
							var x4 = _v10.a;
							var _v11 = _v10.b;
							var x3 = _v11.a;
							var _v12 = _v11.b;
							var x2 = _v12.a;
							var _v13 = _v12.b;
							var x1 = _v13.a;
							var _v14 = _v13.b;
							var x0 = _v14.a;
							var rest = _v14.b;
							var acc2 = A2(
								$elm$core$Array$push,
								A2(
									$ktonon$elm_word$Word$D,
									$ktonon$elm_word$Word$int32FromBytes(
										A4($ktonon$elm_word$Word$FourBytes, x7, x6, x5, x4)),
									$ktonon$elm_word$Word$int32FromBytes(
										A4($ktonon$elm_word$Word$FourBytes, x3, x2, x1, x0))),
								acc);
							var $temp$wordSize = wordSize,
								$temp$bytes = rest,
								$temp$acc = acc2;
							wordSize = $temp$wordSize;
							bytes = $temp$bytes;
							acc = $temp$acc;
							continue accWords;
						} else {
							var _v16 = _v0.a;
							var rest = _v0.b;
							return A2(
								$elm$core$Array$push,
								A2(
									$ktonon$elm_word$Word$D,
									$ktonon$elm_word$Word$int32FromBytes(
										$ktonon$elm_word$Word$pad4(
											A2($elm$core$List$take, 4, rest))),
									$ktonon$elm_word$Word$int32FromBytes(
										$ktonon$elm_word$Word$pad4(
											A2($elm$core$List$drop, 4, rest)))),
								acc);
						}
					} else {
						break _v0$2;
					}
				}
			}
			return acc;
		}
	});
var $ktonon$elm_word$Word$fromBytes = F2(
	function (wordSize, bytes) {
		return A3($ktonon$elm_word$Word$accWords, wordSize, bytes, $elm$core$Array$empty);
	});
var $ktonon$elm_crypto$Crypto$SHA$Preprocess$messageSizeBytes = function (alg) {
	messageSizeBytes:
	while (true) {
		switch (alg.$) {
			case 'SHA224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA256;
				alg = $temp$alg;
				continue messageSizeBytes;
			case 'SHA256':
				return 8;
			case 'SHA384':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue messageSizeBytes;
			case 'SHA512':
				return 16;
			case 'SHA512_224':
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue messageSizeBytes;
			default:
				var $temp$alg = $ktonon$elm_crypto$Crypto$SHA$Alg$SHA512;
				alg = $temp$alg;
				continue messageSizeBytes;
		}
	}
};
var $ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInBits = A2(
	$elm$core$Basics$composeR,
	$ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInBytes,
	$elm$core$Basics$mul(8));
var $ktonon$elm_crypto$Crypto$SHA$Preprocess$calculateK = F2(
	function (alg, l) {
		var c = $ktonon$elm_crypto$Crypto$SHA$Chunk$sizeInBits(alg);
		return A2(
			$elm$core$Basics$modBy,
			c,
			((c - 1) - (8 * $ktonon$elm_crypto$Crypto$SHA$Preprocess$messageSizeBytes(alg))) - A2($elm$core$Basics$modBy, c, l));
	});
var $ktonon$elm_word$Word$Bytes$fromInt = F2(
	function (byteCount, value) {
		return (byteCount > 4) ? A2(
			$elm$core$List$append,
			A2(
				$ktonon$elm_word$Word$Bytes$fromInt,
				byteCount - 4,
				(value / A2($elm$core$Basics$pow, 2, 32)) | 0),
			A2($ktonon$elm_word$Word$Bytes$fromInt, 4, 4294967295 & value)) : A2(
			$elm$core$List$map,
			function (i) {
				return 255 & (value >>> ((byteCount - i) * A2($elm$core$Basics$pow, 2, 3)));
			},
			A2($elm$core$List$range, 1, byteCount));
	});
var $elm$core$List$repeatHelp = F3(
	function (result, n, value) {
		repeatHelp:
		while (true) {
			if (n <= 0) {
				return result;
			} else {
				var $temp$result = A2($elm$core$List$cons, value, result),
					$temp$n = n - 1,
					$temp$value = value;
				result = $temp$result;
				n = $temp$n;
				value = $temp$value;
				continue repeatHelp;
			}
		}
	});
var $elm$core$List$repeat = F2(
	function (n, value) {
		return A3($elm$core$List$repeatHelp, _List_Nil, n, value);
	});
var $ktonon$elm_crypto$Crypto$SHA$Preprocess$postfix = F2(
	function (alg, messageSize) {
		return $elm$core$List$concat(
			_List_fromArray(
				[
					_List_fromArray(
					[128]),
					A2(
					$elm$core$List$repeat,
					((A2($ktonon$elm_crypto$Crypto$SHA$Preprocess$calculateK, alg, messageSize) - 7) / 8) | 0,
					0),
					A2(
					$ktonon$elm_word$Word$Bytes$fromInt,
					$ktonon$elm_crypto$Crypto$SHA$Preprocess$messageSizeBytes(alg),
					messageSize)
				]));
	});
var $ktonon$elm_crypto$Crypto$SHA$Preprocess$preprocess = F2(
	function (alg, message) {
		return A2(
			$elm$core$List$append,
			message,
			A2(
				$ktonon$elm_crypto$Crypto$SHA$Preprocess$postfix,
				alg,
				8 * $elm$core$List$length(message)));
	});
var $ktonon$elm_crypto$Crypto$SHA$digest = function (alg) {
	return A2(
		$elm$core$Basics$composeR,
		$ktonon$elm_crypto$Crypto$SHA$Preprocess$preprocess(alg),
		A2(
			$elm$core$Basics$composeR,
			$ktonon$elm_word$Word$fromBytes(
				$ktonon$elm_crypto$Crypto$SHA$Alg$wordSize(alg)),
			$ktonon$elm_crypto$Crypto$SHA$Process$chunks(alg)));
};
var $ktonon$elm_word$Word$Bytes$splitUtf8 = function (x) {
	return (x < 128) ? _List_fromArray(
		[x]) : ((x < 2048) ? _List_fromArray(
		[192 | ((1984 & x) >>> 6), 128 | (63 & x)]) : _List_fromArray(
		[224 | ((61440 & x) >>> 12), 128 | ((4032 & x) >>> 6), 128 | (63 & x)]));
};
var $elm$core$String$foldr = _String_foldr;
var $elm$core$String$toList = function (string) {
	return A3($elm$core$String$foldr, $elm$core$List$cons, _List_Nil, string);
};
var $ktonon$elm_word$Word$Bytes$fromUTF8 = A2(
	$elm$core$Basics$composeR,
	$elm$core$String$toList,
	A2(
		$elm$core$List$foldl,
		F2(
			function (_char, acc) {
				return A2(
					$elm$core$List$append,
					acc,
					$ktonon$elm_word$Word$Bytes$splitUtf8(
						$elm$core$Char$toCode(_char)));
			}),
		_List_Nil));
var $elm$core$Array$foldl = F3(
	function (func, baseCase, _v0) {
		var tree = _v0.c;
		var tail = _v0.d;
		var helper = F2(
			function (node, acc) {
				if (node.$ === 'SubTree') {
					var subTree = node.a;
					return A3($elm$core$Elm$JsArray$foldl, helper, acc, subTree);
				} else {
					var values = node.a;
					return A3($elm$core$Elm$JsArray$foldl, func, acc, values);
				}
			});
		return A3(
			$elm$core$Elm$JsArray$foldl,
			func,
			A3($elm$core$Elm$JsArray$foldl, helper, baseCase, tree),
			tail);
	});
var $ktonon$elm_word$Word$Hex$fromArray = function (toHex) {
	return A2(
		$elm$core$Array$foldl,
		F2(
			function (val, acc) {
				return _Utils_ap(
					acc,
					toHex(val));
			}),
		'');
};
var $elm$core$String$cons = _String_cons;
var $ktonon$elm_word$Word$Hex$fromIntAccumulator = function (x) {
	return $elm$core$String$cons(
		$elm$core$Char$fromCode(
			(x < 10) ? (x + 48) : ((x + 97) - 10)));
};
var $ktonon$elm_word$Word$Hex$fromInt = F2(
	function (charCount, value) {
		return A3(
			$elm$core$List$foldl,
			function (i) {
				return $ktonon$elm_word$Word$Hex$fromIntAccumulator(
					15 & (value >>> (i * A2($elm$core$Basics$pow, 2, 2))));
			},
			'',
			A2($elm$core$List$range, 0, charCount - 1));
	});
var $ktonon$elm_word$Word$Hex$fromWord = function (word) {
	switch (word.$) {
		case 'W':
			var x = word.a;
			return A2($ktonon$elm_word$Word$Hex$fromInt, 8, x);
		case 'D':
			var h = word.a;
			var l = word.b;
			return _Utils_ap(
				A2($ktonon$elm_word$Word$Hex$fromInt, 8, h),
				A2($ktonon$elm_word$Word$Hex$fromInt, 8, l));
		default:
			return 'M';
	}
};
var $ktonon$elm_word$Word$Hex$fromWordArray = $ktonon$elm_word$Word$Hex$fromArray($ktonon$elm_word$Word$Hex$fromWord);
var $ktonon$elm_crypto$Crypto$Hash$sha256 = function (message) {
	return $ktonon$elm_word$Word$Hex$fromWordArray(
		A2(
			$ktonon$elm_crypto$Crypto$SHA$digest,
			$ktonon$elm_crypto$Crypto$SHA$Alg$SHA256,
			$ktonon$elm_word$Word$Bytes$fromUTF8(message)));
};
var $the_sett$elm_aws_core$AWS$Internal$Body$toString = function (body) {
	switch (body.$) {
		case 'Json':
			var value = body.a;
			return A2($elm$json$Json$Encode$encode, 0, value);
		case 'Empty':
			return '';
		default:
			var val = body.b;
			return val;
	}
};
var $the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalPayload = A2($elm$core$Basics$composeR, $the_sett$elm_aws_core$AWS$Internal$Body$toString, $ktonon$elm_crypto$Crypto$Hash$sha256);
var $ktonon$elm_word$Word$Hex$fromByte = $ktonon$elm_word$Word$Hex$fromInt(2);
var $elm$url$Url$percentEncode = _Url_percentEncode;
var $elm$core$String$toUpper = _String_toUpper;
var $the_sett$elm_aws_core$AWS$Uri$percentEncode = function (x) {
	return A3(
		$elm$regex$Regex$replace,
		A2(
			$elm$core$Maybe$withDefault,
			$elm$regex$Regex$never,
			$elm$regex$Regex$fromString('[!*\'()]')),
		function (match) {
			return A2(
				$elm$core$Maybe$withDefault,
				'',
				A2(
					$elm$core$Maybe$map,
					function (_char) {
						return '%' + $elm$core$String$toUpper(
							$ktonon$elm_word$Word$Hex$fromByte(
								$elm$core$Char$toCode(_char)));
					},
					$elm$core$List$head(
						$elm$core$String$toList(match.match))));
		},
		$elm$url$Url$percentEncode(x));
};
var $elm$regex$Regex$contains = _Regex_contains;
var $the_sett$elm_aws_core$AWS$Internal$Canonical$resolveRelativePath = function (path) {
	var rel = A2(
		$elm$core$Maybe$withDefault,
		$elm$regex$Regex$never,
		$elm$regex$Regex$fromString('(([^/]+)/[.]{2}|/[.])/?'));
	return A2($elm$regex$Regex$contains, rel, path) ? $the_sett$elm_aws_core$AWS$Internal$Canonical$resolveRelativePath(
		A3(
			$elm$regex$Regex$replace,
			rel,
			function (_v0) {
				var match = _v0.match;
				return ((match === '/./') || (match === '/.')) ? '/' : '';
			},
			path)) : path;
};
var $the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalUri = F2(
	function (signer, path) {
		if (signer.$ === 'SignS3') {
			return path;
		} else {
			return $elm$core$String$isEmpty(path) ? '/' : A2(
				$elm$core$String$join,
				'/',
				A2(
					$elm$core$List$map,
					$the_sett$elm_aws_core$AWS$Uri$percentEncode,
					A2(
						$elm$core$String$split,
						'/',
						$the_sett$elm_aws_core$AWS$Internal$Canonical$resolveRelativePath(
							A3(
								$elm$regex$Regex$replace,
								A2(
									$elm$core$Maybe$withDefault,
									$elm$regex$Regex$never,
									$elm$regex$Regex$fromString('/{2,}')),
								function (_v1) {
									return '/';
								},
								path)))));
		}
	});
var $the_sett$elm_aws_core$AWS$Internal$Canonical$encode2Tuple = F2(
	function (separator, _v0) {
		var a = _v0.a;
		var b = _v0.b;
		return A2(
			$elm$core$String$join,
			separator,
			_List_fromArray(
				[
					$the_sett$elm_aws_core$AWS$Uri$percentEncode(a),
					$the_sett$elm_aws_core$AWS$Uri$percentEncode(b)
				]));
	});
var $the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalUrlBuilder = function (params) {
	return A2(
		$elm$core$String$join,
		'&',
		A2(
			$elm$core$List$map,
			$the_sett$elm_aws_core$AWS$Internal$Canonical$encode2Tuple('='),
			$elm$core$List$sort(params)));
};
var $the_sett$elm_aws_core$AWS$Internal$Canonical$signedHeaders = function (headers) {
	return A2(
		$elm$core$String$join,
		';',
		$elm$core$List$sort(
			A2(
				$elm$core$List$map,
				function (_v0) {
					var a = _v0.a;
					return $elm$core$String$toLower(a);
				},
				A3($elm$core$List$foldl, $the_sett$elm_aws_core$AWS$Internal$Canonical$mergeSameHeaders, _List_Nil, headers))));
};
var $the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalRaw = F6(
	function (signer, method, path, headers, params, body) {
		return A2(
			$elm$core$String$join,
			'\n',
			_List_fromArray(
				[
					$elm$core$String$toUpper(method),
					A2($the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalUri, signer, path),
					$the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalUrlBuilder(params),
					$the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalHeaders(headers),
					'',
					$the_sett$elm_aws_core$AWS$Internal$Canonical$signedHeaders(headers),
					$the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalPayload(body)
				]));
	});
var $the_sett$elm_aws_core$AWS$Internal$Canonical$canonical = F6(
	function (signer, method, path, headers, params, body) {
		return $ktonon$elm_crypto$Crypto$Hash$sha256(
			A6($the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalRaw, signer, method, path, headers, params, body));
	});
var $rtfeldman$elm_iso8601_date_strings$Iso8601$fromMonth = function (month) {
	switch (month.$) {
		case 'Jan':
			return 1;
		case 'Feb':
			return 2;
		case 'Mar':
			return 3;
		case 'Apr':
			return 4;
		case 'May':
			return 5;
		case 'Jun':
			return 6;
		case 'Jul':
			return 7;
		case 'Aug':
			return 8;
		case 'Sep':
			return 9;
		case 'Oct':
			return 10;
		case 'Nov':
			return 11;
		default:
			return 12;
	}
};
var $elm$time$Time$flooredDiv = F2(
	function (numerator, denominator) {
		return $elm$core$Basics$floor(numerator / denominator);
	});
var $elm$time$Time$toAdjustedMinutesHelp = F3(
	function (defaultOffset, posixMinutes, eras) {
		toAdjustedMinutesHelp:
		while (true) {
			if (!eras.b) {
				return posixMinutes + defaultOffset;
			} else {
				var era = eras.a;
				var olderEras = eras.b;
				if (_Utils_cmp(era.start, posixMinutes) < 0) {
					return posixMinutes + era.offset;
				} else {
					var $temp$defaultOffset = defaultOffset,
						$temp$posixMinutes = posixMinutes,
						$temp$eras = olderEras;
					defaultOffset = $temp$defaultOffset;
					posixMinutes = $temp$posixMinutes;
					eras = $temp$eras;
					continue toAdjustedMinutesHelp;
				}
			}
		}
	});
var $elm$time$Time$toAdjustedMinutes = F2(
	function (_v0, time) {
		var defaultOffset = _v0.a;
		var eras = _v0.b;
		return A3(
			$elm$time$Time$toAdjustedMinutesHelp,
			defaultOffset,
			A2(
				$elm$time$Time$flooredDiv,
				$elm$time$Time$posixToMillis(time),
				60000),
			eras);
	});
var $elm$time$Time$toCivil = function (minutes) {
	var rawDay = A2($elm$time$Time$flooredDiv, minutes, 60 * 24) + 719468;
	var era = (((rawDay >= 0) ? rawDay : (rawDay - 146096)) / 146097) | 0;
	var dayOfEra = rawDay - (era * 146097);
	var yearOfEra = ((((dayOfEra - ((dayOfEra / 1460) | 0)) + ((dayOfEra / 36524) | 0)) - ((dayOfEra / 146096) | 0)) / 365) | 0;
	var dayOfYear = dayOfEra - (((365 * yearOfEra) + ((yearOfEra / 4) | 0)) - ((yearOfEra / 100) | 0));
	var mp = (((5 * dayOfYear) + 2) / 153) | 0;
	var month = mp + ((mp < 10) ? 3 : (-9));
	var year = yearOfEra + (era * 400);
	return {
		day: (dayOfYear - ((((153 * mp) + 2) / 5) | 0)) + 1,
		month: month,
		year: year + ((month <= 2) ? 1 : 0)
	};
};
var $elm$time$Time$toDay = F2(
	function (zone, time) {
		return $elm$time$Time$toCivil(
			A2($elm$time$Time$toAdjustedMinutes, zone, time)).day;
	});
var $elm$time$Time$toHour = F2(
	function (zone, time) {
		return A2(
			$elm$core$Basics$modBy,
			24,
			A2(
				$elm$time$Time$flooredDiv,
				A2($elm$time$Time$toAdjustedMinutes, zone, time),
				60));
	});
var $elm$time$Time$toMillis = F2(
	function (_v0, time) {
		return A2(
			$elm$core$Basics$modBy,
			1000,
			$elm$time$Time$posixToMillis(time));
	});
var $elm$time$Time$toMinute = F2(
	function (zone, time) {
		return A2(
			$elm$core$Basics$modBy,
			60,
			A2($elm$time$Time$toAdjustedMinutes, zone, time));
	});
var $elm$time$Time$Apr = {$: 'Apr'};
var $elm$time$Time$Aug = {$: 'Aug'};
var $elm$time$Time$Dec = {$: 'Dec'};
var $elm$time$Time$Feb = {$: 'Feb'};
var $elm$time$Time$Jan = {$: 'Jan'};
var $elm$time$Time$Jul = {$: 'Jul'};
var $elm$time$Time$Jun = {$: 'Jun'};
var $elm$time$Time$Mar = {$: 'Mar'};
var $elm$time$Time$May = {$: 'May'};
var $elm$time$Time$Nov = {$: 'Nov'};
var $elm$time$Time$Oct = {$: 'Oct'};
var $elm$time$Time$Sep = {$: 'Sep'};
var $elm$time$Time$toMonth = F2(
	function (zone, time) {
		var _v0 = $elm$time$Time$toCivil(
			A2($elm$time$Time$toAdjustedMinutes, zone, time)).month;
		switch (_v0) {
			case 1:
				return $elm$time$Time$Jan;
			case 2:
				return $elm$time$Time$Feb;
			case 3:
				return $elm$time$Time$Mar;
			case 4:
				return $elm$time$Time$Apr;
			case 5:
				return $elm$time$Time$May;
			case 6:
				return $elm$time$Time$Jun;
			case 7:
				return $elm$time$Time$Jul;
			case 8:
				return $elm$time$Time$Aug;
			case 9:
				return $elm$time$Time$Sep;
			case 10:
				return $elm$time$Time$Oct;
			case 11:
				return $elm$time$Time$Nov;
			default:
				return $elm$time$Time$Dec;
		}
	});
var $elm$core$String$fromChar = function (_char) {
	return A2($elm$core$String$cons, _char, '');
};
var $elm$core$Bitwise$shiftRightBy = _Bitwise_shiftRightBy;
var $elm$core$String$repeatHelp = F3(
	function (n, chunk, result) {
		return (n <= 0) ? result : A3(
			$elm$core$String$repeatHelp,
			n >> 1,
			_Utils_ap(chunk, chunk),
			(!(n & 1)) ? result : _Utils_ap(result, chunk));
	});
var $elm$core$String$repeat = F2(
	function (n, chunk) {
		return A3($elm$core$String$repeatHelp, n, chunk, '');
	});
var $elm$core$String$padLeft = F3(
	function (n, _char, string) {
		return _Utils_ap(
			A2(
				$elm$core$String$repeat,
				n - $elm$core$String$length(string),
				$elm$core$String$fromChar(_char)),
			string);
	});
var $rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString = F2(
	function (digits, time) {
		return A3(
			$elm$core$String$padLeft,
			digits,
			_Utils_chr('0'),
			$elm$core$String$fromInt(time));
	});
var $elm$time$Time$toSecond = F2(
	function (_v0, time) {
		return A2(
			$elm$core$Basics$modBy,
			60,
			A2(
				$elm$time$Time$flooredDiv,
				$elm$time$Time$posixToMillis(time),
				1000));
	});
var $elm$time$Time$toYear = F2(
	function (zone, time) {
		return $elm$time$Time$toCivil(
			A2($elm$time$Time$toAdjustedMinutes, zone, time)).year;
	});
var $elm$time$Time$utc = A2($elm$time$Time$Zone, 0, _List_Nil);
var $rtfeldman$elm_iso8601_date_strings$Iso8601$fromTime = function (time) {
	return A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		4,
		A2($elm$time$Time$toYear, $elm$time$Time$utc, time)) + ('-' + (A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		2,
		$rtfeldman$elm_iso8601_date_strings$Iso8601$fromMonth(
			A2($elm$time$Time$toMonth, $elm$time$Time$utc, time))) + ('-' + (A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		2,
		A2($elm$time$Time$toDay, $elm$time$Time$utc, time)) + ('T' + (A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		2,
		A2($elm$time$Time$toHour, $elm$time$Time$utc, time)) + (':' + (A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		2,
		A2($elm$time$Time$toMinute, $elm$time$Time$utc, time)) + (':' + (A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		2,
		A2($elm$time$Time$toSecond, $elm$time$Time$utc, time)) + ('.' + (A2(
		$rtfeldman$elm_iso8601_date_strings$Iso8601$toPaddedString,
		3,
		A2($elm$time$Time$toMillis, $elm$time$Time$utc, time)) + 'Z'))))))))))));
};
var $the_sett$elm_aws_core$AWS$Internal$V4$formatPosix = function (date) {
	return A3(
		$elm$regex$Regex$replace,
		A2(
			$elm$core$Maybe$withDefault,
			$elm$regex$Regex$never,
			$elm$regex$Regex$fromString('([-:]|\\.\\d{3})')),
		function (_v0) {
			return '';
		},
		$rtfeldman$elm_iso8601_date_strings$Iso8601$fromTime(date));
};
var $the_sett$elm_aws_core$AWS$Internal$Service$region = function (_v0) {
	var endpoint = _v0.endpoint;
	var regionResolver = _v0.regionResolver;
	return regionResolver(endpoint);
};
var $the_sett$elm_aws_core$AWS$Internal$V4$credentialScope = F3(
	function (date, creds, service) {
		return A2(
			$elm$core$String$join,
			'/',
			_List_fromArray(
				[
					A3(
					$elm$core$String$slice,
					0,
					8,
					$the_sett$elm_aws_core$AWS$Internal$V4$formatPosix(date)),
					$the_sett$elm_aws_core$AWS$Internal$Service$region(service),
					service.endpointPrefix,
					'aws4_request'
				]));
	});
var $elm$core$List$filter = F2(
	function (isGood, list) {
		return A3(
			$elm$core$List$foldr,
			F2(
				function (x, xs) {
					return isGood(x) ? A2($elm$core$List$cons, x, xs) : xs;
				}),
			_List_Nil,
			list);
	});
var $elm$core$List$any = F2(
	function (isOkay, list) {
		any:
		while (true) {
			if (!list.b) {
				return false;
			} else {
				var x = list.a;
				var xs = list.b;
				if (isOkay(x)) {
					return true;
				} else {
					var $temp$isOkay = isOkay,
						$temp$list = xs;
					isOkay = $temp$isOkay;
					list = $temp$list;
					continue any;
				}
			}
		}
	});
var $elm$core$List$member = F2(
	function (x, xs) {
		return A2(
			$elm$core$List$any,
			function (a) {
				return _Utils_eq(a, x);
			},
			xs);
	});
var $elm$core$Basics$not = _Basics_not;
var $the_sett$elm_aws_core$AWS$Internal$V4$filterHeaders = F2(
	function (headersToRemove, headersList) {
		var matches = function (_v0) {
			var head = _v0.a;
			return !A2(
				$elm$core$List$member,
				$elm$core$String$toLower(head),
				headersToRemove);
		};
		return A2($elm$core$List$filter, matches, headersList);
	});
var $ktonon$elm_crypto$Crypto$HMAC$SHA = function (a) {
	return {$: 'SHA', a: a};
};
var $ktonon$elm_crypto$Crypto$HMAC$blockSize = function (_v0) {
	blockSize:
	while (true) {
		var alg = _v0.a;
		switch (alg.$) {
			case 'SHA224':
				var $temp$_v0 = $ktonon$elm_crypto$Crypto$HMAC$SHA($ktonon$elm_crypto$Crypto$SHA$Alg$SHA256);
				_v0 = $temp$_v0;
				continue blockSize;
			case 'SHA256':
				return 64;
			case 'SHA384':
				var $temp$_v0 = $ktonon$elm_crypto$Crypto$HMAC$SHA($ktonon$elm_crypto$Crypto$SHA$Alg$SHA512);
				_v0 = $temp$_v0;
				continue blockSize;
			case 'SHA512':
				return 128;
			case 'SHA512_224':
				var $temp$_v0 = $ktonon$elm_crypto$Crypto$HMAC$SHA($ktonon$elm_crypto$Crypto$SHA$Alg$SHA512);
				_v0 = $temp$_v0;
				continue blockSize;
			default:
				var $temp$_v0 = $ktonon$elm_crypto$Crypto$HMAC$SHA($ktonon$elm_crypto$Crypto$SHA$Alg$SHA512);
				_v0 = $temp$_v0;
				continue blockSize;
		}
	}
};
var $ktonon$elm_word$Word$toBytes = A2(
	$elm$core$Basics$composeR,
	$elm$core$Array$toList,
	$elm$core$List$concatMap(
		function (word) {
			switch (word.$) {
				case 'W':
					var x = word.a;
					return A2($ktonon$elm_word$Word$Bytes$fromInt, 4, x);
				case 'D':
					var xh = word.a;
					var xl = word.b;
					return A2(
						$elm$core$List$append,
						A2($ktonon$elm_word$Word$Bytes$fromInt, 4, xh),
						A2($ktonon$elm_word$Word$Bytes$fromInt, 4, xl));
				default:
					return _List_Nil;
			}
		}));
var $ktonon$elm_crypto$Crypto$HMAC$Digest$hmac_ = F3(
	function (hash, message, key) {
		var oKeyPad = A2(
			$elm$core$List$map,
			$elm$core$Bitwise$xor(92),
			key);
		var iKeyPad = A2(
			$elm$core$List$map,
			$elm$core$Bitwise$xor(54),
			key);
		return hash(
			A2(
				$elm$core$List$append,
				oKeyPad,
				$ktonon$elm_word$Word$toBytes(
					hash(
						A2($elm$core$List$append, iKeyPad, message)))));
	});
var $ktonon$elm_crypto$Crypto$HMAC$Digest$padEnd = F2(
	function (blockSize, bytes) {
		return A2(
			$elm$core$List$append,
			bytes,
			A2(
				$elm$core$List$repeat,
				blockSize - $elm$core$List$length(bytes),
				0));
	});
var $ktonon$elm_crypto$Crypto$HMAC$Digest$normalizeKey = F3(
	function (hash, blockSize, key) {
		var _v0 = A2(
			$elm$core$Basics$compare,
			blockSize,
			$elm$core$List$length(key));
		switch (_v0.$) {
			case 'EQ':
				return key;
			case 'GT':
				return A2($ktonon$elm_crypto$Crypto$HMAC$Digest$padEnd, blockSize, key);
			default:
				return A2(
					$ktonon$elm_crypto$Crypto$HMAC$Digest$padEnd,
					blockSize,
					$ktonon$elm_word$Word$toBytes(
						hash(key)));
		}
	});
var $ktonon$elm_crypto$Crypto$HMAC$Digest$digestBytes = F4(
	function (hash, blockSize, key, message) {
		return A3(
			$ktonon$elm_crypto$Crypto$HMAC$Digest$hmac_,
			hash,
			message,
			A3($ktonon$elm_crypto$Crypto$HMAC$Digest$normalizeKey, hash, blockSize, key));
	});
var $ktonon$elm_crypto$Crypto$HMAC$hash = function (_v0) {
	var alg = _v0.a;
	return $ktonon$elm_crypto$Crypto$SHA$digest(alg);
};
var $ktonon$elm_crypto$Crypto$HMAC$digestBytes = F3(
	function (type_, key, message) {
		return $ktonon$elm_word$Word$toBytes(
			A4(
				$ktonon$elm_crypto$Crypto$HMAC$Digest$digestBytes,
				$ktonon$elm_crypto$Crypto$HMAC$hash(type_),
				$ktonon$elm_crypto$Crypto$HMAC$blockSize(type_),
				key,
				message));
	});
var $ktonon$elm_word$Word$Hex$fromList = function (toHex) {
	return A2(
		$elm$core$List$foldl,
		F2(
			function (val, acc) {
				return _Utils_ap(
					acc,
					toHex(val));
			}),
		'');
};
var $ktonon$elm_word$Word$Hex$fromByteList = $ktonon$elm_word$Word$Hex$fromList($ktonon$elm_word$Word$Hex$fromByte);
var $ktonon$elm_crypto$Crypto$HMAC$sha256 = $ktonon$elm_crypto$Crypto$HMAC$SHA($ktonon$elm_crypto$Crypto$SHA$Alg$SHA256);
var $the_sett$elm_aws_core$AWS$Internal$V4$signature = F4(
	function (creds, service, date, toSign) {
		var digest = F2(
			function (message, key) {
				return A3(
					$ktonon$elm_crypto$Crypto$HMAC$digestBytes,
					$ktonon$elm_crypto$Crypto$HMAC$sha256,
					key,
					$ktonon$elm_word$Word$Bytes$fromUTF8(message));
			});
		return $ktonon$elm_word$Word$Hex$fromByteList(
			A2(
				digest,
				toSign,
				A2(
					digest,
					'aws4_request',
					A2(
						digest,
						service.endpointPrefix,
						A2(
							digest,
							$the_sett$elm_aws_core$AWS$Internal$Service$region(service),
							A2(
								digest,
								A3(
									$elm$core$String$slice,
									0,
									8,
									$the_sett$elm_aws_core$AWS$Internal$V4$formatPosix(date)),
								$ktonon$elm_word$Word$Bytes$fromUTF8('AWS4' + creds.secretAccessKey)))))));
	});
var $the_sett$elm_aws_core$AWS$Internal$V4$stringToSign = F4(
	function (alg, date, scope, canon) {
		return A2(
			$elm$core$String$join,
			'\n',
			_List_fromArray(
				[
					alg,
					$the_sett$elm_aws_core$AWS$Internal$V4$formatPosix(date),
					scope,
					canon
				]));
	});
var $the_sett$elm_aws_core$AWS$Internal$V4$authorization = F5(
	function (creds, date, service, req, rawHeaders) {
		var scope = A3($the_sett$elm_aws_core$AWS$Internal$V4$credentialScope, date, creds, service);
		var filteredHeaders = A2(
			$the_sett$elm_aws_core$AWS$Internal$V4$filterHeaders,
			_List_fromArray(
				['content-type', 'accept']),
			rawHeaders);
		var canon = A6($the_sett$elm_aws_core$AWS$Internal$Canonical$canonical, service.signer, req.method, req.path, filteredHeaders, req.query, req.body);
		return A2(
			$elm$core$String$join,
			', ',
			_List_fromArray(
				[
					'AWS4-HMAC-SHA256 Credential=' + (creds.accessKeyId + ('/' + scope)),
					'SignedHeaders=' + $the_sett$elm_aws_core$AWS$Internal$Canonical$signedHeaders(filteredHeaders),
					'Signature=' + A4(
					$the_sett$elm_aws_core$AWS$Internal$V4$signature,
					creds,
					service,
					date,
					A4($the_sett$elm_aws_core$AWS$Internal$V4$stringToSign, $the_sett$elm_aws_core$AWS$Internal$V4$algorithm, date, scope, canon))
				]));
	});
var $the_sett$elm_aws_core$AWS$Internal$Service$host = function (spec) {
	return A2(spec.hostResolver, spec.endpoint, spec.endpointPrefix);
};
var $the_sett$elm_aws_core$AWS$Internal$V4$addAuthorization = F5(
	function (service, creds, date, req, headersList) {
		return A2(
			$elm$core$List$append,
			headersList,
			_List_fromArray(
				[
					_Utils_Tuple2(
					'Authorization',
					A5(
						$the_sett$elm_aws_core$AWS$Internal$V4$authorization,
						creds,
						date,
						service,
						req,
						A2(
							$elm$core$List$cons,
							_Utils_Tuple2(
								'Host',
								$the_sett$elm_aws_core$AWS$Internal$Service$host(service)),
							headersList)))
				]));
	});
var $the_sett$elm_aws_core$AWS$Internal$V4$addSessionToken = F2(
	function (creds, headersList) {
		return A2(
			$elm$core$Maybe$withDefault,
			headersList,
			A2(
				$elm$core$Maybe$map,
				function (token) {
					return A2(
						$elm$core$List$cons,
						_Utils_Tuple2('x-amz-security-token', token),
						headersList);
				},
				creds.sessionToken));
	});
var $elm$http$Http$Header = F2(
	function (a, b) {
		return {$: 'Header', a: a, b: b};
	});
var $elm$http$Http$header = $elm$http$Http$Header;
var $the_sett$elm_aws_core$AWS$Internal$Service$acceptType = function (spec) {
	var _v0 = spec.protocol;
	if (_v0.$ === 'REST_XML') {
		return 'application/xml';
	} else {
		return 'application/json';
	}
};
var $the_sett$elm_aws_core$AWS$Internal$Service$contentType = function (spec) {
	return function () {
		var _v0 = spec.protocol;
		if (_v0.$ === 'REST_XML') {
			return 'application/xml';
		} else {
			var _v1 = spec.jsonVersion;
			if (_v1.$ === 'Just') {
				var apiVersion = _v1.a;
				return 'application/x-amz-json-' + apiVersion;
			} else {
				return 'application/json';
			}
		}
	}() + '; charset=utf-8';
};
var $the_sett$elm_aws_core$AWS$Internal$Body$explicitMimetype = function (body) {
	if (body.$ === 'String') {
		var typ = body.a;
		return $elm$core$Maybe$Just(typ);
	} else {
		return $elm$core$Maybe$Nothing;
	}
};
var $elm$core$Basics$neq = _Utils_notEqual;
var $the_sett$elm_aws_core$AWS$Internal$V4$headers = F4(
	function (service, date, body, extraHeaders) {
		var extraNames = A2(
			$elm$core$List$map,
			$elm$core$String$toLower,
			A2($elm$core$List$map, $elm$core$Tuple$first, extraHeaders));
		return $elm$core$List$concat(
			_List_fromArray(
				[
					extraHeaders,
					_List_fromArray(
					[
						_Utils_Tuple2(
						'x-amz-date',
						$the_sett$elm_aws_core$AWS$Internal$V4$formatPosix(date)),
						_Utils_Tuple2(
						'x-amz-content-sha256',
						$the_sett$elm_aws_core$AWS$Internal$Canonical$canonicalPayload(body))
					]),
					A2($elm$core$List$member, 'accept', extraNames) ? _List_Nil : _List_fromArray(
					[
						_Utils_Tuple2(
						'Accept',
						$the_sett$elm_aws_core$AWS$Internal$Service$acceptType(service))
					]),
					(A2($elm$core$List$member, 'content-type', extraNames) || (!_Utils_eq(
					$the_sett$elm_aws_core$AWS$Internal$Body$explicitMimetype(body),
					$elm$core$Maybe$Nothing))) ? _List_Nil : _List_fromArray(
					[
						_Utils_Tuple2(
						'Content-Type',
						$the_sett$elm_aws_core$AWS$Internal$Service$contentType(service))
					])
				]));
	});
var $elm$http$Http$BadStatus_ = F2(
	function (a, b) {
		return {$: 'BadStatus_', a: a, b: b};
	});
var $elm$http$Http$BadUrl_ = function (a) {
	return {$: 'BadUrl_', a: a};
};
var $elm$http$Http$GoodStatus_ = F2(
	function (a, b) {
		return {$: 'GoodStatus_', a: a, b: b};
	});
var $elm$http$Http$NetworkError_ = {$: 'NetworkError_'};
var $elm$http$Http$Receiving = function (a) {
	return {$: 'Receiving', a: a};
};
var $elm$http$Http$Sending = function (a) {
	return {$: 'Sending', a: a};
};
var $elm$http$Http$Timeout_ = {$: 'Timeout_'};
var $elm$core$Maybe$isJust = function (maybe) {
	if (maybe.$ === 'Just') {
		return true;
	} else {
		return false;
	}
};
var $elm$core$Platform$sendToSelf = _Platform_sendToSelf;
var $elm$http$Http$stringResolver = A2(_Http_expect, '', $elm$core$Basics$identity);
var $elm$http$Http$resultToTask = function (result) {
	if (result.$ === 'Ok') {
		var a = result.a;
		return $elm$core$Task$succeed(a);
	} else {
		var x = result.a;
		return $elm$core$Task$fail(x);
	}
};
var $elm$http$Http$task = function (r) {
	return A3(
		_Http_toTask,
		_Utils_Tuple0,
		$elm$http$Http$resultToTask,
		{allowCookiesFromOtherDomains: false, body: r.body, expect: r.resolver, headers: r.headers, method: r.method, timeout: r.timeout, tracker: $elm$core$Maybe$Nothing, url: r.url});
};
var $elm$http$Http$emptyBody = _Http_emptyBody;
var $elm$http$Http$jsonBody = function (value) {
	return A2(
		_Http_pair,
		'application/json',
		A2($elm$json$Json$Encode$encode, 0, value));
};
var $elm$http$Http$stringBody = _Http_pair;
var $the_sett$elm_aws_core$AWS$Internal$Body$toHttp = function (body) {
	switch (body.$) {
		case 'Empty':
			return $elm$http$Http$emptyBody;
		case 'Json':
			var value = body.a;
			return $elm$http$Http$jsonBody(value);
		default:
			var mimetype = body.a;
			var val = body.b;
			return A2($elm$http$Http$stringBody, mimetype, val);
	}
};
var $the_sett$elm_aws_core$AWS$Internal$UrlBuilder$add = F3(
	function (k, v, qs) {
		var prepend = function (maybeXs) {
			if (maybeXs.$ === 'Nothing') {
				return $elm$core$Maybe$Just(
					_List_fromArray(
						[v]));
			} else {
				var xs = maybeXs.a;
				return $elm$core$Maybe$Just(
					A2($elm$core$List$cons, v, xs));
			}
		};
		return A3($elm$core$Dict$update, k, prepend, qs);
	});
var $the_sett$elm_aws_core$AWS$Internal$UrlBuilder$render = function (qs) {
	var flatten = function (_v0) {
		var k = _v0.a;
		var xs = _v0.b;
		return A2(
			$elm$core$List$map,
			function (x) {
				return k + ('=' + $elm$url$Url$percentEncode(x));
			},
			xs);
	};
	return '?' + A2(
		$elm$core$String$join,
		'&',
		A2(
			$elm$core$List$concatMap,
			flatten,
			$elm$core$Dict$toList(qs)));
};
var $the_sett$elm_aws_core$AWS$Internal$UrlBuilder$queryString = function (params) {
	if (!params.b) {
		return '';
	} else {
		return $the_sett$elm_aws_core$AWS$Internal$UrlBuilder$render(
			A3(
				$elm$core$List$foldl,
				F2(
					function (_v1, qs) {
						var key = _v1.a;
						var val = _v1.b;
						return A3(
							$the_sett$elm_aws_core$AWS$Internal$UrlBuilder$add,
							$the_sett$elm_aws_core$AWS$Uri$percentEncode(key),
							val,
							qs);
					}),
				$elm$core$Dict$empty,
				params));
	}
};
var $the_sett$elm_aws_core$AWS$Internal$UrlBuilder$url = F2(
	function (service, _v0) {
		var path = _v0.path;
		var query = _v0.query;
		return 'https://' + ($the_sett$elm_aws_core$AWS$Internal$Service$host(service) + (path + $the_sett$elm_aws_core$AWS$Internal$UrlBuilder$queryString(query)));
	});
var $the_sett$elm_aws_core$AWS$Internal$V4$sign = F4(
	function (service, creds, date, req) {
		var responseDecoder = function (response) {
			switch (response.$) {
				case 'BadUrl_':
					var url = response.a;
					return $elm$core$Result$Err(
						$the_sett$elm_aws_core$AWS$Internal$Error$HttpError(
							$elm$http$Http$BadUrl(url)));
				case 'Timeout_':
					return $elm$core$Result$Err(
						$the_sett$elm_aws_core$AWS$Internal$Error$HttpError($elm$http$Http$Timeout));
				case 'NetworkError_':
					return $elm$core$Result$Err(
						$the_sett$elm_aws_core$AWS$Internal$Error$HttpError($elm$http$Http$NetworkError));
				case 'BadStatus_':
					var metadata = response.a;
					var body = response.b;
					var _v2 = A2(req.errorDecoder, metadata, body);
					if (_v2.$ === 'Ok') {
						var appErr = _v2.a;
						return $elm$core$Result$Err(
							$the_sett$elm_aws_core$AWS$Internal$Error$AWSError(appErr));
					} else {
						var err = _v2.a;
						return $elm$core$Result$Err(
							$the_sett$elm_aws_core$AWS$Internal$Error$HttpError(
								$elm$http$Http$BadBody(err)));
					}
				default:
					var metadata = response.a;
					var body = response.b;
					var _v3 = A2(req.decoder, metadata, body);
					if (_v3.$ === 'Ok') {
						var resp = _v3.a;
						return $elm$core$Result$Ok(resp);
					} else {
						var err = _v3.a;
						return $elm$core$Result$Err(
							$the_sett$elm_aws_core$AWS$Internal$Error$HttpError(
								$elm$http$Http$BadBody(err)));
					}
			}
		};
		var resolver = $elm$http$Http$stringResolver(responseDecoder);
		return $elm$http$Http$task(
			{
				body: $the_sett$elm_aws_core$AWS$Internal$Body$toHttp(req.body),
				headers: A2(
					$elm$core$List$map,
					function (_v0) {
						var key = _v0.a;
						var val = _v0.b;
						return A2($elm$http$Http$header, key, val);
					},
					A2(
						$the_sett$elm_aws_core$AWS$Internal$V4$addSessionToken,
						creds,
						A5(
							$the_sett$elm_aws_core$AWS$Internal$V4$addAuthorization,
							service,
							creds,
							date,
							req,
							A4($the_sett$elm_aws_core$AWS$Internal$V4$headers, service, date, req.body, req.headers)))),
				method: req.method,
				resolver: resolver,
				timeout: $elm$core$Maybe$Nothing,
				url: A2($the_sett$elm_aws_core$AWS$Internal$UrlBuilder$url, service, req)
			});
	});
var $the_sett$elm_aws_core$AWS$Http$send = F3(
	function (service, credentials, req) {
		var signWithTimestamp = F2(
			function (innerReq, posix) {
				var _v1 = service.signer;
				if (_v1.$ === 'SignV4') {
					return A4($the_sett$elm_aws_core$AWS$Internal$V4$sign, service, credentials, posix, innerReq);
				} else {
					return $elm$core$Task$fail(
						$the_sett$elm_aws_core$AWS$Internal$Error$HttpError(
							$elm$http$Http$BadBody('TODO: S3 Signing Scheme not implemented.')));
				}
			});
		var prepareRequest = function (innerReq) {
			var _v0 = service.protocol;
			if (_v0.$ === 'JSON') {
				return A2(
					$the_sett$elm_aws_core$AWS$Http$addHeaders,
					_List_fromArray(
						[
							_Utils_Tuple2('x-amz-target', service.targetPrefix + ('.' + innerReq.name))
						]),
					innerReq);
			} else {
				return innerReq;
			}
		};
		return A2(
			$elm$core$Task$mapError,
			$the_sett$elm_aws_core$AWS$Http$internalErrToErr,
			A2(
				$elm$core$Task$andThen,
				signWithTimestamp(
					prepareRequest(req)),
				$elm$time$Time$now));
	});
var $the_sett$elm_aws_core$AWS$Http$POST = {$: 'POST'};
var $the_sett$elm_aws_core$AWS$Http$awsAppErrDecoder = F2(
	function (metadata, body) {
		var bodyDecoder = A3(
			$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
			'message',
			$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string),
			A3(
				$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$required,
				'__type',
				$elm$json$Json$Decode$string,
				$elm$json$Json$Decode$succeed(
					F2(
						function (type_, message) {
							return {message: message, statusCode: metadata.statusCode, type_: type_};
						}))));
		return A2(
			$elm$core$Result$mapError,
			function (_v0) {
				return body;
			},
			A2($elm$json$Json$Decode$decodeString, bodyDecoder, body));
	});
var $the_sett$json_optional$Json$Encode$Optional$WithValue = F2(
	function (a, b) {
		return {$: 'WithValue', a: a, b: b};
	});
var $the_sett$json_optional$Json$Encode$Optional$field = F2(
	function (encoder, _v0) {
		var name = _v0.a;
		var val = _v0.b;
		return A2(
			$the_sett$json_optional$Json$Encode$Optional$WithValue,
			name,
			encoder(val));
	});
var $the_sett$elm_aws_core$AWS$Internal$Body$Json = function (a) {
	return {$: 'Json', a: a};
};
var $the_sett$elm_aws_core$AWS$Internal$Body$json = $the_sett$elm_aws_core$AWS$Internal$Body$Json;
var $the_sett$elm_aws_core$AWS$Http$jsonBody = $the_sett$elm_aws_core$AWS$Internal$Body$json;
var $the_sett$elm_aws_core$AWS$Http$jsonBodyDecoder = function (decodeFn) {
	return F2(
		function (metadata, body) {
			var _v0 = A2($elm$json$Json$Decode$decodeString, decodeFn, body);
			if (_v0.$ === 'Ok') {
				var val = _v0.a;
				return $elm$core$Result$Ok(val);
			} else {
				var err = _v0.a;
				return $elm$core$Result$Err(
					$elm$json$Json$Decode$errorToString(err));
			}
		});
};
var $miniBill$elm_codec$Codec$composite = F3(
	function (enc, dec, _v0) {
		var codec = _v0.a;
		return $miniBill$elm_codec$Codec$Codec(
			{
				decoder: dec(codec.decoder),
				encoder: enc(codec.encoder)
			});
	});
var $elm$json$Json$Decode$dict = function (decoder) {
	return A2(
		$elm$json$Json$Decode$map,
		$elm$core$Dict$fromList,
		$elm$json$Json$Decode$keyValuePairs(decoder));
};
var $elm$core$Dict$map = F2(
	function (func, dict) {
		if (dict.$ === 'RBEmpty_elm_builtin') {
			return $elm$core$Dict$RBEmpty_elm_builtin;
		} else {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				color,
				key,
				A2(func, key, value),
				A2($elm$core$Dict$map, func, left),
				A2($elm$core$Dict$map, func, right));
		}
	});
var $miniBill$elm_codec$Codec$dict = A2(
	$miniBill$elm_codec$Codec$composite,
	function (e) {
		return A2(
			$elm$core$Basics$composeL,
			A2($elm$core$Basics$composeL, $elm$json$Json$Encode$object, $elm$core$Dict$toList),
			$elm$core$Dict$map(
				function (_v0) {
					return e;
				}));
	},
	$elm$json$Json$Decode$dict);
var $the_sett$elm_aws_messaging$AWS$Sqs$MessageAttributeValue = F5(
	function (binaryListValues, binaryValue, dataType, stringListValues, stringValue) {
		return {binaryListValues: binaryListValues, binaryValue: binaryValue, dataType: dataType, stringListValues: stringListValues, stringValue: stringValue};
	});
var $miniBill$elm_codec$Codec$list = A2($miniBill$elm_codec$Codec$composite, $elm$json$Json$Encode$list, $elm$json$Json$Decode$list);
var $the_sett$elm_aws_messaging$AWS$Sqs$binaryListCodec = $miniBill$elm_codec$Codec$list($miniBill$elm_codec$Codec$string);
var $miniBill$elm_codec$Codec$maybe = function (codec) {
	return $miniBill$elm_codec$Codec$Codec(
		{
			decoder: $elm$json$Json$Decode$maybe(
				$miniBill$elm_codec$Codec$decoder(codec)),
			encoder: function (v) {
				if (v.$ === 'Nothing') {
					return $elm$json$Json$Encode$null;
				} else {
					var x = v.a;
					return A2($miniBill$elm_codec$Codec$encoder, codec, x);
				}
			}
		});
};
var $miniBill$elm_codec$Codec$optionalField = F4(
	function (name, getter, codec, _v0) {
		var ocodec = _v0.a;
		return $miniBill$elm_codec$Codec$ObjectCodec(
			{
				decoder: A3(
					$elm$json$Json$Decode$map2,
					F2(
						function (f, x) {
							return f(x);
						}),
					ocodec.decoder,
					$elm$json$Json$Decode$maybe(
						A2(
							$elm$json$Json$Decode$field,
							name,
							$miniBill$elm_codec$Codec$decoder(codec)))),
				encoder: function (v) {
					return A2(
						$elm$core$List$cons,
						_Utils_Tuple2(
							name,
							A2(
								$miniBill$elm_codec$Codec$encoder,
								$miniBill$elm_codec$Codec$maybe(codec),
								getter(v))),
						ocodec.encoder(v));
				}
			});
	});
var $the_sett$elm_aws_messaging$AWS$Sqs$stringListCodec = $miniBill$elm_codec$Codec$list($miniBill$elm_codec$Codec$string);
var $the_sett$elm_aws_messaging$AWS$Sqs$messageAttributeValueCodec = $miniBill$elm_codec$Codec$buildObject(
	A4(
		$miniBill$elm_codec$Codec$optionalField,
		'StringValue',
		function ($) {
			return $.stringValue;
		},
		$miniBill$elm_codec$Codec$string,
		A4(
			$miniBill$elm_codec$Codec$optionalField,
			'StringListValues',
			function ($) {
				return $.stringListValues;
			},
			$the_sett$elm_aws_messaging$AWS$Sqs$stringListCodec,
			A4(
				$miniBill$elm_codec$Codec$field,
				'DataType',
				function ($) {
					return $.dataType;
				},
				$miniBill$elm_codec$Codec$string,
				A4(
					$miniBill$elm_codec$Codec$optionalField,
					'BinaryValue',
					function ($) {
						return $.binaryValue;
					},
					$miniBill$elm_codec$Codec$string,
					A4(
						$miniBill$elm_codec$Codec$optionalField,
						'BinaryListValues',
						function ($) {
							return $.binaryListValues;
						},
						$the_sett$elm_aws_messaging$AWS$Sqs$binaryListCodec,
						$miniBill$elm_codec$Codec$object($the_sett$elm_aws_messaging$AWS$Sqs$MessageAttributeValue)))))));
var $the_sett$elm_aws_messaging$AWS$Sqs$messageBodyAttributeMapCodec = $miniBill$elm_codec$Codec$dict($the_sett$elm_aws_messaging$AWS$Sqs$messageAttributeValueCodec);
var $the_sett$elm_refine$Dict$Refined$foldl = F3(
	function (f, acc, _v0) {
		var dict = _v0.a.dict;
		return A3(
			$elm$core$Dict$foldl,
			F2(
				function (_v1, _v2) {
					var k = _v2.a;
					var v = _v2.b;
					return A2(f, k, v);
				}),
			acc,
			dict);
	});
var $the_sett$elm_refine$Dict$Enum$foldl = F3(
	function (f, acc, dict) {
		return A3($the_sett$elm_refine$Dict$Refined$foldl, f, acc, dict);
	});
var $the_sett$elm_refine$Enum$toString = F2(
	function (_v0, val) {
		var toStringFn = _v0.b;
		return toStringFn(val);
	});
var $the_sett$elm_refine$Enum$dictEncoder = F3(
	function (_enum, valEncoder, dict) {
		return $elm$json$Json$Encode$object(
			A3(
				$the_sett$elm_refine$Dict$Enum$foldl,
				F3(
					function (k, v, accum) {
						return A2(
							$elm$core$List$cons,
							_Utils_Tuple2(
								A2($the_sett$elm_refine$Enum$toString, _enum, k),
								valEncoder(v)),
							accum);
					}),
				_List_Nil,
				dict));
	});
var $the_sett$elm_aws_messaging$AWS$Sqs$MessageSystemAttributeNameForSendsAwstraceHeader = {$: 'MessageSystemAttributeNameForSendsAwstraceHeader'};
var $the_sett$elm_refine$Enum$Enum = F2(
	function (a, b) {
		return {$: 'Enum', a: a, b: b};
	});
var $the_sett$elm_refine$Enum$define = F2(
	function (vals, toStringFn) {
		return A2($the_sett$elm_refine$Enum$Enum, vals, toStringFn);
	});
var $the_sett$elm_aws_messaging$AWS$Sqs$messageSystemAttributeNameForSends = A2(
	$the_sett$elm_refine$Enum$define,
	_List_fromArray(
		[$the_sett$elm_aws_messaging$AWS$Sqs$MessageSystemAttributeNameForSendsAwstraceHeader]),
	function (val) {
		return 'AWSTraceHeader';
	});
var $the_sett$json_optional$Json$Encode$Optional$objectMaySkip = function (fields) {
	return $elm$json$Json$Encode$object(
		A3(
			$elm$core$List$foldr,
			F2(
				function (fld, accum) {
					switch (fld.$) {
						case 'WithValue':
							var name = fld.a;
							var val = fld.b;
							return A2(
								$elm$core$List$cons,
								_Utils_Tuple2(name, val),
								accum);
						case 'Optional':
							var name = fld.a;
							return accum;
						case 'Nullable':
							var name = fld.a;
							return A2(
								$elm$core$List$cons,
								_Utils_Tuple2(name, $elm$json$Json$Encode$null),
								accum);
						default:
							return accum;
					}
				}),
			_List_Nil,
			fields));
};
var $the_sett$json_optional$Json$Encode$Optional$Optional = function (a) {
	return {$: 'Optional', a: a};
};
var $the_sett$json_optional$Json$Encode$Optional$optionalField = F2(
	function (encoder, _v0) {
		var name = _v0.a;
		var maybeVal = _v0.b;
		if (maybeVal.$ === 'Just') {
			var val = maybeVal.a;
			return A2(
				$the_sett$json_optional$Json$Encode$Optional$WithValue,
				name,
				encoder(val));
		} else {
			return $the_sett$json_optional$Json$Encode$Optional$Optional(name);
		}
	});
var $the_sett$elm_aws_messaging$AWS$Sqs$messageSystemAttributeValueEncoder = function (val) {
	return $the_sett$json_optional$Json$Encode$Optional$objectMaySkip(
		_List_fromArray(
			[
				A2(
				$the_sett$json_optional$Json$Encode$Optional$optionalField,
				$miniBill$elm_codec$Codec$encoder($the_sett$elm_aws_messaging$AWS$Sqs$binaryListCodec),
				_Utils_Tuple2('BinaryListValues', val.binaryListValues)),
				A2(
				$the_sett$json_optional$Json$Encode$Optional$optionalField,
				$elm$json$Json$Encode$string,
				_Utils_Tuple2('BinaryValue', val.binaryValue)),
				A2(
				$the_sett$json_optional$Json$Encode$Optional$field,
				$elm$json$Json$Encode$string,
				_Utils_Tuple2('DataType', val.dataType)),
				A2(
				$the_sett$json_optional$Json$Encode$Optional$optionalField,
				$miniBill$elm_codec$Codec$encoder($the_sett$elm_aws_messaging$AWS$Sqs$stringListCodec),
				_Utils_Tuple2('StringListValues', val.stringListValues)),
				A2(
				$the_sett$json_optional$Json$Encode$Optional$optionalField,
				$elm$json$Json$Encode$string,
				_Utils_Tuple2('StringValue', val.stringValue))
			]));
};
var $the_sett$elm_aws_messaging$AWS$Sqs$messageBodySystemAttributeMapEncoder = function (val) {
	return A3($the_sett$elm_refine$Enum$dictEncoder, $the_sett$elm_aws_messaging$AWS$Sqs$messageSystemAttributeNameForSends, $the_sett$elm_aws_messaging$AWS$Sqs$messageSystemAttributeValueEncoder, val);
};
var $NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optionalDecoder = F3(
	function (path, valDecoder, fallback) {
		var nullOr = function (decoder) {
			return $elm$json$Json$Decode$oneOf(
				_List_fromArray(
					[
						decoder,
						$elm$json$Json$Decode$null(fallback)
					]));
		};
		var handleResult = function (input) {
			var _v0 = A2(
				$elm$json$Json$Decode$decodeValue,
				A2($elm$json$Json$Decode$at, path, $elm$json$Json$Decode$value),
				input);
			if (_v0.$ === 'Ok') {
				var rawValue = _v0.a;
				var _v1 = A2(
					$elm$json$Json$Decode$decodeValue,
					nullOr(valDecoder),
					rawValue);
				if (_v1.$ === 'Ok') {
					var finalResult = _v1.a;
					return $elm$json$Json$Decode$succeed(finalResult);
				} else {
					return A2(
						$elm$json$Json$Decode$at,
						path,
						nullOr(valDecoder));
				}
			} else {
				return $elm$json$Json$Decode$succeed(fallback);
			}
		};
		return A2($elm$json$Json$Decode$andThen, handleResult, $elm$json$Json$Decode$value);
	});
var $NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optional = F4(
	function (key, valDecoder, fallback, decoder) {
		return A2(
			$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$custom,
			A3(
				$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optionalDecoder,
				_List_fromArray(
					[key]),
				valDecoder,
				fallback),
			decoder);
	});
var $the_sett$elm_aws_core$AWS$Http$methodToString = function (meth) {
	switch (meth.$) {
		case 'DELETE':
			return 'DELETE';
		case 'GET':
			return 'GET';
		case 'HEAD':
			return 'HEAD';
		case 'OPTIONS':
			return 'OPTIONS';
		case 'POST':
			return 'POST';
		default:
			return 'PUT';
	}
};
var $the_sett$elm_aws_core$AWS$Internal$Request$unsigned = F6(
	function (name, method, uri, body, decoder, errorDecoder) {
		return {body: body, decoder: decoder, errorDecoder: errorDecoder, headers: _List_Nil, method: method, name: name, path: uri, query: _List_Nil};
	});
var $the_sett$elm_aws_core$AWS$Http$request = F6(
	function (name, method, path, body, decoder, errorDecoder) {
		return A6(
			$the_sett$elm_aws_core$AWS$Internal$Request$unsigned,
			name,
			$the_sett$elm_aws_core$AWS$Http$methodToString(method),
			path,
			body,
			decoder,
			errorDecoder);
	});
var $the_sett$elm_aws_messaging$AWS$Sqs$sendMessage = function (req) {
	var url = '/';
	var encoder = function (val) {
		return $the_sett$json_optional$Json$Encode$Optional$objectMaySkip(
			_List_fromArray(
				[
					A2(
					$the_sett$json_optional$Json$Encode$Optional$field,
					$elm$json$Json$Encode$string,
					_Utils_Tuple2('QueueUrl', val.queueUrl)),
					A2(
					$the_sett$json_optional$Json$Encode$Optional$optionalField,
					$the_sett$elm_aws_messaging$AWS$Sqs$messageBodySystemAttributeMapEncoder,
					_Utils_Tuple2('MessageSystemAttributes', val.messageSystemAttributes)),
					A2(
					$the_sett$json_optional$Json$Encode$Optional$optionalField,
					$elm$json$Json$Encode$string,
					_Utils_Tuple2('MessageGroupId', val.messageGroupId)),
					A2(
					$the_sett$json_optional$Json$Encode$Optional$optionalField,
					$elm$json$Json$Encode$string,
					_Utils_Tuple2('MessageDeduplicationId', val.messageDeduplicationId)),
					A2(
					$the_sett$json_optional$Json$Encode$Optional$field,
					$elm$json$Json$Encode$string,
					_Utils_Tuple2('MessageBody', val.messageBody)),
					A2(
					$the_sett$json_optional$Json$Encode$Optional$optionalField,
					$miniBill$elm_codec$Codec$encoder($the_sett$elm_aws_messaging$AWS$Sqs$messageBodyAttributeMapCodec),
					_Utils_Tuple2('MessageAttributes', val.messageAttributes)),
					A2(
					$the_sett$json_optional$Json$Encode$Optional$optionalField,
					$elm$json$Json$Encode$int,
					_Utils_Tuple2('DelaySeconds', val.delaySeconds))
				]));
	};
	var jsonBody = $the_sett$elm_aws_core$AWS$Http$jsonBody(
		encoder(req));
	var decoder = $the_sett$elm_aws_core$AWS$Http$jsonBodyDecoder(
		A4(
			$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optional,
			'MD5OfMessageAttributes',
			$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string),
			$elm$core$Maybe$Nothing,
			A4(
				$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optional,
				'MD5OfMessageBody',
				$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string),
				$elm$core$Maybe$Nothing,
				A4(
					$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optional,
					'MD5OfMessageSystemAttributes',
					$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string),
					$elm$core$Maybe$Nothing,
					A4(
						$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optional,
						'MessageId',
						$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string),
						$elm$core$Maybe$Nothing,
						A4(
							$NoRedInk$elm_json_decode_pipeline$Json$Decode$Pipeline$optional,
							'SequenceNumber',
							$elm$json$Json$Decode$maybe($elm$json$Json$Decode$string),
							$elm$core$Maybe$Nothing,
							$elm$json$Json$Decode$succeed(
								F5(
									function (sequenceNumberFld, messageIdFld, md5OfMessageSystemAttributesFld, md5OfMessageBodyFld, md5OfMessageAttributesFld) {
										return {md5OfMessageAttributes: md5OfMessageAttributesFld, md5OfMessageBody: md5OfMessageBodyFld, md5OfMessageSystemAttributes: md5OfMessageSystemAttributesFld, messageId: messageIdFld, sequenceNumber: sequenceNumberFld};
									}))))))));
	return A6($the_sett$elm_aws_core$AWS$Http$request, 'SendMessage', $the_sett$elm_aws_core$AWS$Http$POST, url, jsonBody, decoder, $the_sett$elm_aws_core$AWS$Http$awsAppErrDecoder);
};
var $the_sett$elm_aws_core$AWS$Config$JSON = {$: 'JSON'};
var $the_sett$elm_aws_core$AWS$Config$SignV4 = {$: 'SignV4'};
var $the_sett$elm_aws_core$AWS$Config$RegionalEndpoint = function (a) {
	return {$: 'RegionalEndpoint', a: a};
};
var $the_sett$elm_aws_core$AWS$Config$GlobalEndpoint = {$: 'GlobalEndpoint'};
var $the_sett$elm_aws_core$AWS$Config$defineGlobal = F4(
	function (prefix, apiVersion, proto, signerType) {
		return {apiVersion: apiVersion, endpoint: $the_sett$elm_aws_core$AWS$Config$GlobalEndpoint, endpointPrefix: prefix, jsonVersion: $elm$core$Maybe$Nothing, protocol: proto, signer: signerType, signingName: $elm$core$Maybe$Nothing, targetPrefix: $elm$core$Maybe$Nothing, timestampFormat: $elm$core$Maybe$Nothing, xmlNamespace: $elm$core$Maybe$Nothing};
	});
var $the_sett$elm_aws_core$AWS$Config$defineRegional = F5(
	function (prefix, apiVersion, proto, signerType, rgn) {
		var svc = A4($the_sett$elm_aws_core$AWS$Config$defineGlobal, prefix, apiVersion, proto, signerType);
		return _Utils_update(
			svc,
			{
				endpoint: $the_sett$elm_aws_core$AWS$Config$RegionalEndpoint(rgn)
			});
	});
var $the_sett$elm_aws_core$AWS$Service$defaultHostResolver = F2(
	function (endpoint, prefix) {
		if (endpoint.$ === 'GlobalEndpoint') {
			return prefix + '.amazonaws.com';
		} else {
			var rgn = endpoint.a;
			return prefix + ('.' + (rgn + '.amazonaws.com'));
		}
	});
var $the_sett$elm_aws_core$AWS$Service$defaultRegionResolver = function (endpoint) {
	if (endpoint.$ === 'RegionalEndpoint') {
		var rgn = endpoint.a;
		return rgn;
	} else {
		return 'us-east-1';
	}
};
var $the_sett$elm_aws_core$AWS$Service$defaultTargetPrefix = F2(
	function (prefix, apiVersion) {
		return 'AWS' + ($elm$core$String$toUpper(prefix) + ('_' + A2(
			$elm$core$String$join,
			'',
			A2($elm$core$String$split, '-', apiVersion))));
	});
var $the_sett$elm_aws_core$AWS$Config$ISO8601 = {$: 'ISO8601'};
var $the_sett$elm_aws_core$AWS$Config$UnixTimestamp = {$: 'UnixTimestamp'};
var $the_sett$elm_aws_core$AWS$Service$defaultTimestampFormat = function (proto) {
	switch (proto.$) {
		case 'JSON':
			return $the_sett$elm_aws_core$AWS$Config$UnixTimestamp;
		case 'REST_JSON':
			return $the_sett$elm_aws_core$AWS$Config$UnixTimestamp;
		default:
			return $the_sett$elm_aws_core$AWS$Config$ISO8601;
	}
};
var $the_sett$elm_aws_core$AWS$Service$service = function (config) {
	return {
		apiVersion: config.apiVersion,
		endpoint: config.endpoint,
		endpointPrefix: config.endpointPrefix,
		hostResolver: $the_sett$elm_aws_core$AWS$Service$defaultHostResolver,
		jsonVersion: config.jsonVersion,
		protocol: config.protocol,
		regionResolver: $the_sett$elm_aws_core$AWS$Service$defaultRegionResolver,
		signer: config.signer,
		signingName: config.signingName,
		targetPrefix: A2(
			$elm$core$Maybe$withDefault,
			A2($the_sett$elm_aws_core$AWS$Service$defaultTargetPrefix, config.endpointPrefix, config.apiVersion),
			config.targetPrefix),
		timestampFormat: A2(
			$elm$core$Maybe$withDefault,
			$the_sett$elm_aws_core$AWS$Service$defaultTimestampFormat(config.protocol),
			config.timestampFormat),
		xmlNamespace: config.xmlNamespace
	};
};
var $the_sett$elm_aws_core$AWS$Config$withJsonVersion = F2(
	function (jsonVersion, service) {
		return _Utils_update(
			service,
			{
				jsonVersion: $elm$core$Maybe$Just(jsonVersion)
			});
	});
var $the_sett$elm_aws_core$AWS$Config$withTargetPrefix = F2(
	function (prefix, service) {
		return _Utils_update(
			service,
			{
				targetPrefix: $elm$core$Maybe$Just(prefix)
			});
	});
var $the_sett$elm_aws_messaging$AWS$Sqs$service = function (region) {
	return $the_sett$elm_aws_core$AWS$Service$service(
		A2(
			$the_sett$elm_aws_core$AWS$Config$withTargetPrefix,
			'AmazonSQS',
			A2(
				$the_sett$elm_aws_core$AWS$Config$withJsonVersion,
				'1.0',
				A5($the_sett$elm_aws_core$AWS$Config$defineRegional, 'sqs', '2012-11-05', $the_sett$elm_aws_core$AWS$Config$JSON, $the_sett$elm_aws_core$AWS$Config$SignV4, region))));
};
var $author$project$EventLog$SaveChannel$notifyCompactor = F3(
	function (component, channelName, drainState) {
		if (drainState.$ === 'DrainedNothing') {
			return $brian_watkins$elm_procedure$Procedure$provide(_Utils_Tuple0);
		} else {
			var lastSeqNo = drainState.a.lastSeqNo;
			var request = A2(
				$elm$json$Json$Encode$encode,
				2,
				A2($author$project$Realtime$encodeSnapshotRequestEvent, channelName, lastSeqNo));
			var sqsMessage = $the_sett$elm_aws_messaging$AWS$Sqs$sendMessage(
				{
					delaySeconds: $elm$core$Maybe$Nothing,
					messageAttributes: $elm$core$Maybe$Nothing,
					messageBody: request,
					messageDeduplicationId: $elm$core$Maybe$Just(
						channelName + (':' + $elm$core$String$fromInt(lastSeqNo))),
					messageGroupId: $elm$core$Maybe$Just(channelName),
					messageSystemAttributes: $elm$core$Maybe$Nothing,
					queueUrl: component.snapshotQueueUrl
				});
			var notifyCmd = A3(
				$the_sett$elm_aws_core$AWS$Http$send,
				$the_sett$elm_aws_messaging$AWS$Sqs$service(component.awsRegion),
				component.defaultCredentials,
				sqsMessage);
			return (!A2($elm$core$Basics$modBy, 5, lastSeqNo)) ? A2(
				$brian_watkins$elm_procedure$Procedure$map,
				$elm$core$Basics$always(_Utils_Tuple0),
				A2(
					$brian_watkins$elm_procedure$Procedure$mapError,
					$author$project$EventLog$SaveChannel$awsErrorToDetails,
					$brian_watkins$elm_procedure$Procedure$fromTask(notifyCmd))) : $brian_watkins$elm_procedure$Procedure$provide(_Utils_Tuple0);
		}
	});
var $author$project$EventLog$SaveChannel$setModel = F2(
	function (m, x) {
		return _Utils_update(
			m,
			{eventLog: x});
	});
var $author$project$EventLog$SaveChannel$switchState = F2(
	function (cons, state) {
		return _Utils_Tuple2(
			cons(state),
			$elm$core$Platform$Cmd$none);
	});
var $author$project$EventLog$SaveChannel$saveChannel = F5(
	function (session, state, apiRequest, channelName, component) {
		var procedure = A2(
			$brian_watkins$elm_procedure$Procedure$map,
			$elm$core$Basics$always(
				$author$project$Http$Response$ok200json($elm$json$Json$Encode$null)),
			A2(
				$brian_watkins$elm_procedure$Procedure$mapError,
				A2(
					$elm$core$Basics$composeR,
					$elm$core$Debug$log('error'),
					A2($elm$core$Basics$composeR, $author$project$ErrorFormat$encodeErrorFormat, $author$project$Http$Response$err500json)),
				A2(
					$brian_watkins$elm_procedure$Procedure$andThen,
					A2($author$project$EventLog$SaveChannel$notifyCompactor, component, channelName),
					A2(
						$brian_watkins$elm_procedure$Procedure$andThen,
						A2($author$project$EventLog$SaveChannel$drainSaveList, component, channelName),
						A2(
							$brian_watkins$elm_procedure$Procedure$andThen,
							$author$project$EventLog$OpenMomentoCache$openMomentoCache(component),
							$brian_watkins$elm_procedure$Procedure$provide(channelName))))));
		return A2(
			$elm$core$Tuple$mapFirst,
			$author$project$EventLog$SaveChannel$setModel(component),
			A2(
				$the_sett$elm_update_helper$Update2$andMap,
				$author$project$EventLog$SaveChannel$switchState($author$project$EventLog$Model$ModelReady),
				_Utils_Tuple2(
					state,
					A3(
						$brian_watkins$elm_procedure$Procedure$try,
						$author$project$EventLog$Msg$ProcedureMsg,
						$author$project$EventLog$Msg$HttpResponse(session),
						procedure))));
	});
var $author$project$EventLog$Component$processRoute = F4(
	function (protocol, session, apiRequest, component) {
		var model = component.eventLog;
		var _v0 = _Utils_Tuple3(
			$author$project$Http$Request$method(apiRequest.request),
			apiRequest.route,
			model);
		_v0$4:
		while (true) {
			if (_v0.c.$ === 'ModelReady') {
				switch (_v0.a.$) {
					case 'POST':
						switch (_v0.b.$) {
							case 'ChannelRoot':
								var _v3 = _v0.a;
								var _v4 = _v0.b;
								var state = _v0.c.a;
								return protocol.onUpdate(
									A2(
										$elm$core$Tuple$mapSecond,
										$elm$core$Platform$Cmd$map(protocol.toMsg),
										A2(
											$the_sett$elm_update_helper$Update2$andMap,
											A2($author$project$EventLog$CreateChannel$createChannel, session, state),
											$the_sett$elm_update_helper$Update2$pure(component))));
							case 'Channel':
								var _v5 = _v0.a;
								var channelName = _v0.b.a;
								var state = _v0.c.a;
								return protocol.onUpdate(
									A2(
										$elm$core$Tuple$mapSecond,
										$elm$core$Platform$Cmd$map(protocol.toMsg),
										A2(
											$the_sett$elm_update_helper$Update2$andMap,
											A4($author$project$EventLog$SaveChannel$saveChannel, session, state, apiRequest, channelName),
											$the_sett$elm_update_helper$Update2$pure(component))));
							default:
								break _v0$4;
						}
					case 'GET':
						switch (_v0.b.$) {
							case 'ChannelRoot':
								var _v1 = _v0.a;
								var _v2 = _v0.b;
								var state = _v0.c.a;
								return protocol.onUpdate(
									A2(
										$elm$core$Tuple$mapSecond,
										$elm$core$Platform$Cmd$map(protocol.toMsg),
										A2(
											$the_sett$elm_update_helper$Update2$andMap,
											A2($author$project$EventLog$GetAvailableChannel$getAvailableChannel, session, state),
											$the_sett$elm_update_helper$Update2$pure(component))));
							case 'ChannelJoin':
								var _v6 = _v0.a;
								var channelName = _v0.b.a;
								var state = _v0.c.a;
								return protocol.onUpdate(
									A2(
										$elm$core$Tuple$mapSecond,
										$elm$core$Platform$Cmd$map(protocol.toMsg),
										A2(
											$the_sett$elm_update_helper$Update2$andMap,
											A4($author$project$EventLog$JoinChannel$procedure, session, state, apiRequest, channelName),
											$the_sett$elm_update_helper$Update2$pure(component))));
							default:
								break _v0$4;
						}
					default:
						break _v0$4;
				}
			} else {
				break _v0$4;
			}
		}
		return protocol.onUpdate(
			$the_sett$elm_update_helper$Update2$pure(component));
	});
var $author$project$EventLog$Component$setModel = F2(
	function (m, x) {
		return _Utils_update(
			m,
			{eventLog: x});
	});
var $brian_watkins$elm_procedure$Procedure$Program$addChannel = F2(
	function (subGenerator, registry) {
		return _Utils_update(
			registry,
			{
				channels: A3(
					$elm$core$Dict$insert,
					registry.nextId,
					subGenerator(registry.nextId),
					registry.channels),
				nextId: registry.nextId + 1
			});
	});
var $brian_watkins$elm_procedure$Procedure$Program$deleteChannel = F2(
	function (channelId, procModel) {
		return _Utils_update(
			procModel,
			{
				channels: A2($elm$core$Dict$remove, channelId, procModel.channels)
			});
	});
var $brian_watkins$elm_procedure$Procedure$Program$sendMessage = function (msg) {
	return A2(
		$elm$core$Task$perform,
		$elm$core$Basics$always(msg),
		$elm$core$Task$succeed(_Utils_Tuple0));
};
var $brian_watkins$elm_procedure$Procedure$Program$updateProcedures = F2(
	function (msg, registry) {
		switch (msg.$) {
			case 'Initiate':
				var generator = msg.a;
				return _Utils_Tuple2(
					_Utils_update(
						registry,
						{nextId: registry.nextId + 1}),
					generator(registry.nextId));
			case 'Execute':
				var cmd = msg.b;
				return _Utils_Tuple2(registry, cmd);
			case 'Subscribe':
				var messageGenerator = msg.b;
				var subGenerator = msg.c;
				return _Utils_Tuple2(
					A2($brian_watkins$elm_procedure$Procedure$Program$addChannel, subGenerator, registry),
					$brian_watkins$elm_procedure$Procedure$Program$sendMessage(
						messageGenerator(registry.nextId)));
			case 'Unsubscribe':
				var channelId = msg.b;
				var nextMessage = msg.c;
				return _Utils_Tuple2(
					A2($brian_watkins$elm_procedure$Procedure$Program$deleteChannel, channelId, registry),
					$brian_watkins$elm_procedure$Procedure$Program$sendMessage(nextMessage));
			default:
				return _Utils_Tuple2(registry, $elm$core$Platform$Cmd$none);
		}
	});
var $brian_watkins$elm_procedure$Procedure$Program$update = F2(
	function (msg, _v0) {
		var registry = _v0.a;
		return A2(
			$elm$core$Tuple$mapFirst,
			$brian_watkins$elm_procedure$Procedure$Program$Model,
			A2($brian_watkins$elm_procedure$Procedure$Program$updateProcedures, msg, registry));
	});
var $author$project$EventLog$Component$update = F3(
	function (protocol, msg, component) {
		var model = component.eventLog;
		var _v0 = _Utils_Tuple2(model, msg);
		_v0$7:
		while (true) {
			switch (_v0.b.$) {
				case 'RandomSeed':
					if (_v0.a.$ === 'ModelStart') {
						var seed = _v0.b.a;
						return protocol.onUpdate(
							A2(
								$elm$core$Tuple$mapSecond,
								$elm$core$Platform$Cmd$map(protocol.toMsg),
								A2(
									$elm$core$Tuple$mapFirst,
									$author$project$EventLog$Component$setModel(component),
									A2(
										$the_sett$elm_update_helper$Update2$andMap,
										$author$project$EventLog$Component$switchState($author$project$EventLog$Model$ModelReady),
										$the_sett$elm_update_helper$Update2$pure(
											{cache: $elm$core$Dict$empty, procedure: $brian_watkins$elm_procedure$Procedure$Program$init, seed: seed})))));
					} else {
						break _v0$7;
					}
				case 'ProcedureMsg':
					if (_v0.a.$ === 'ModelReady') {
						var state = _v0.a.a;
						var innerMsg = _v0.b.a;
						var _v1 = A2($brian_watkins$elm_procedure$Procedure$Program$update, innerMsg, state.procedure);
						var procMdl = _v1.a;
						var procMsg = _v1.b;
						return protocol.onUpdate(
							A2(
								$elm$core$Tuple$mapSecond,
								$elm$core$Platform$Cmd$map(protocol.toMsg),
								A2(
									$elm$core$Tuple$mapFirst,
									$author$project$EventLog$Component$setModel(component),
									A2(
										$the_sett$elm_update_helper$Update2$andMap,
										$author$project$EventLog$Component$switchState($author$project$EventLog$Model$ModelReady),
										_Utils_Tuple2(
											_Utils_update(
												state,
												{procedure: procMdl}),
											procMsg)))));
					} else {
						break _v0$7;
					}
				case 'HttpRequest':
					if (_v0.a.$ === 'ModelReady') {
						var state = _v0.a.a;
						var _v2 = _v0.b;
						var session = _v2.a;
						var result = _v2.b;
						if (result.$ === 'Ok') {
							var apiRequest = result.a;
							return A4($author$project$EventLog$Component$processRoute, protocol, session, apiRequest, component);
						} else {
							var httpError = result.a;
							return protocol.onUpdate(
								A2(
									$elm$core$Tuple$mapSecond,
									$elm$core$Platform$Cmd$map(protocol.toMsg),
									A2(
										$elm$core$Tuple$mapFirst,
										$author$project$EventLog$Component$setModel(component),
										_Utils_Tuple2(
											$author$project$EventLog$Model$ModelReady(state),
											A2(
												$author$project$EventLog$Apis$httpServerApi.response,
												session,
												$author$project$Http$Response$err500(
													$author$project$HttpServer$errorToString(httpError)))))));
						}
					} else {
						break _v0$7;
					}
				case 'HttpResponse':
					var _v4 = _v0.b;
					var session = _v4.a;
					var result = _v4.b;
					return protocol.onUpdate(
						A2(
							$elm$core$Tuple$mapSecond,
							$elm$core$Platform$Cmd$map(protocol.toMsg),
							_Utils_Tuple2(
								component,
								A2(
									$author$project$EventLog$Apis$httpServerApi.response,
									session,
									$elm_community$result_extra$Result$Extra$merge(result)))));
				case 'SqsEvent':
					if (_v0.a.$ === 'ModelReady') {
						if (_v0.b.b.$ === 'Ok') {
							var state = _v0.a.a;
							var _v5 = _v0.b;
							var session = _v5.a;
							var event = _v5.b.a;
							return protocol.onUpdate(
								A2(
									$elm$core$Tuple$mapSecond,
									$elm$core$Platform$Cmd$map(protocol.toMsg),
									A2(
										$the_sett$elm_update_helper$Update2$andMap,
										A3($author$project$EventLog$SnapshotChannel$procedure, session, state, event),
										$the_sett$elm_update_helper$Update2$pure(component))));
						} else {
							var state = _v0.a.a;
							var _v6 = _v0.b;
							var session = _v6.a;
							var err = _v6.b.a;
							return protocol.onUpdate(
								A2(
									$elm$core$Tuple$mapSecond,
									$elm$core$Platform$Cmd$map(protocol.toMsg),
									A2(
										$elm$core$Tuple$mapFirst,
										$author$project$EventLog$Component$setModel(component),
										_Utils_Tuple2(
											$author$project$EventLog$Model$ModelReady(state),
											A2(
												$author$project$EventLog$Apis$httpServerApi.response,
												session,
												$author$project$Http$Response$err500json(
													$author$project$ErrorFormat$encodeErrorFormat(
														$author$project$SqsLambda$errorToDetails(err))))))));
						}
					} else {
						break _v0$7;
					}
				default:
					var error = _v0.b.a;
					return protocol.onUpdate(
						$the_sett$elm_update_helper$Update2$pure(component));
			}
		}
		return protocol.onUpdate(
			$the_sett$elm_update_helper$Update2$pure(component));
	});
var $author$project$API$update = F2(
	function (msg, model) {
		var innerMsg = msg.a;
		return A3($author$project$EventLog$Component$update, $author$project$API$eventLogProtocol, innerMsg, model);
	});
var $elm$core$Platform$worker = _Platform_worker;
var $author$project$API$main = $elm$core$Platform$worker(
	{init: $author$project$API$init, subscriptions: $author$project$API$subscriptions, update: $author$project$API$update});
_Platform_export({'API':{'init':$author$project$API$main(
	A2(
		$elm$json$Json$Decode$andThen,
		function (snapshotTable) {
			return A2(
				$elm$json$Json$Decode$andThen,
				function (snapshotQueueUrl) {
					return A2(
						$elm$json$Json$Decode$andThen,
						function (momentoSecret) {
							return A2(
								$elm$json$Json$Decode$andThen,
								function (eventLogTable) {
									return A2(
										$elm$json$Json$Decode$andThen,
										function (channelTable) {
											return A2(
												$elm$json$Json$Decode$andThen,
												function (channelApiUrl) {
													return A2(
														$elm$json$Json$Decode$andThen,
														function (awsSessionToken) {
															return A2(
																$elm$json$Json$Decode$andThen,
																function (awsSecretAccessKey) {
																	return A2(
																		$elm$json$Json$Decode$andThen,
																		function (awsRegion) {
																			return A2(
																				$elm$json$Json$Decode$andThen,
																				function (awsAccessKeyId) {
																					return $elm$json$Json$Decode$succeed(
																						{awsAccessKeyId: awsAccessKeyId, awsRegion: awsRegion, awsSecretAccessKey: awsSecretAccessKey, awsSessionToken: awsSessionToken, channelApiUrl: channelApiUrl, channelTable: channelTable, eventLogTable: eventLogTable, momentoSecret: momentoSecret, snapshotQueueUrl: snapshotQueueUrl, snapshotTable: snapshotTable});
																				},
																				A2($elm$json$Json$Decode$field, 'awsAccessKeyId', $elm$json$Json$Decode$string));
																		},
																		A2($elm$json$Json$Decode$field, 'awsRegion', $elm$json$Json$Decode$string));
																},
																A2($elm$json$Json$Decode$field, 'awsSecretAccessKey', $elm$json$Json$Decode$string));
														},
														A2($elm$json$Json$Decode$field, 'awsSessionToken', $elm$json$Json$Decode$string));
												},
												A2($elm$json$Json$Decode$field, 'channelApiUrl', $elm$json$Json$Decode$string));
										},
										A2($elm$json$Json$Decode$field, 'channelTable', $elm$json$Json$Decode$string));
								},
								A2($elm$json$Json$Decode$field, 'eventLogTable', $elm$json$Json$Decode$string));
						},
						A2(
							$elm$json$Json$Decode$field,
							'momentoSecret',
							A2(
								$elm$json$Json$Decode$andThen,
								function (restEndpoint) {
									return A2(
										$elm$json$Json$Decode$andThen,
										function (refreshToken) {
											return A2(
												$elm$json$Json$Decode$andThen,
												function (apiKey) {
													return $elm$json$Json$Decode$succeed(
														{apiKey: apiKey, refreshToken: refreshToken, restEndpoint: restEndpoint});
												},
												A2($elm$json$Json$Decode$field, 'apiKey', $elm$json$Json$Decode$string));
										},
										A2($elm$json$Json$Decode$field, 'refreshToken', $elm$json$Json$Decode$string));
								},
								A2($elm$json$Json$Decode$field, 'restEndpoint', $elm$json$Json$Decode$string))));
				},
				A2($elm$json$Json$Decode$field, 'snapshotQueueUrl', $elm$json$Json$Decode$string));
		},
		A2($elm$json$Json$Decode$field, 'snapshotTable', $elm$json$Json$Decode$string)))(0)}});}(this));