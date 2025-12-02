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

var _Debug_log = F2(function(tag, value)
{
	return value;
});

var _Debug_log_UNUSED = F2(function(tag, value)
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

function _Debug_toString(value)
{
	return '<internals>';
}

function _Debug_toString_UNUSED(value)
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


function _Debug_crash(identifier)
{
	throw new Error('https://github.com/elm/core/blob/1.0.0/hints/' + identifier + '.md');
}


function _Debug_crash_UNUSED(identifier, fact1, fact2, fact3, fact4)
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
	if (region.b9.cQ === region.cw.cQ)
	{
		return 'on line ' + region.b9.cQ;
	}
	return 'on lines ' + region.b9.cQ + ' through ' + region.cw.cQ;
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

	/**_UNUSED/
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

	/**/
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

	/**_UNUSED/
	if (x instanceof String)
	{
		var a = x.valueOf();
		var b = y.valueOf();
		return a === b ? 0 : a < b ? -1 : 1;
	}
	//*/

	/**/
	if (typeof x.$ === 'undefined')
	//*/
	/**_UNUSED/
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

var _Utils_Tuple0 = 0;
var _Utils_Tuple0_UNUSED = { $: '#0' };

function _Utils_Tuple2(a, b) { return { a: a, b: b }; }
function _Utils_Tuple2_UNUSED(a, b) { return { $: '#2', a: a, b: b }; }

function _Utils_Tuple3(a, b, c) { return { a: a, b: b, c: c }; }
function _Utils_Tuple3_UNUSED(a, b, c) { return { $: '#3', a: a, b: b, c: c }; }

function _Utils_chr(c) { return c; }
function _Utils_chr_UNUSED(c) { return new String(c); }


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



var _List_Nil = { $: 0 };
var _List_Nil_UNUSED = { $: '[]' };

function _List_Cons(hd, tl) { return { $: 1, a: hd, b: tl }; }
function _List_Cons_UNUSED(hd, tl) { return { $: '::', a: hd, b: tl }; }


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



/**_UNUSED/
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

function _Json_wrap_UNUSED(value) { return { $: 0, a: value }; }
function _Json_unwrap_UNUSED(value) { return value.a; }

function _Json_wrap(value) { return value; }
function _Json_unwrap(value) { return value; }

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
		impl.dP,
		impl.ep,
		impl.ek,
		function() { return function() {} }
	);
});



// INITIALIZE A PROGRAM


function _Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder)
{
	var result = A2(_Json_run, flagDecoder, _Json_wrap(args ? args['flags'] : undefined));
	$elm$core$Result$isOk(result) || _Debug_crash(2 /**_UNUSED/, _Json_errorToString(result.a) /**/);
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


function _Platform_export(exports)
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


function _Platform_export_UNUSED(exports)
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



// SEND REQUEST

var _Http_toTask = F3(function(router, toTask, request)
{
	return _Scheduler_binding(function(callback)
	{
		function done(response) {
			callback(toTask(request.bY.a(response)));
		}

		var xhr = new XMLHttpRequest();
		xhr.addEventListener('error', function() { done($elm$http$Http$NetworkError_); });
		xhr.addEventListener('timeout', function() { done($elm$http$Http$Timeout_); });
		xhr.addEventListener('load', function() { done(_Http_toResponse(request.bY.b, xhr)); });
		$elm$core$Maybe$isJust(request.dq) && _Http_track(router, xhr, request.dq.a);

		try {
			xhr.open(request.dV, request.eq, true);
		} catch (e) {
			return done($elm$http$Http$BadUrl_(request.eq));
		}

		_Http_configureRequest(xhr, request);

		request.dA.a && xhr.setRequestHeader('Content-Type', request.dA.a);
		xhr.send(request.dA.b);

		return function() { xhr.c = true; xhr.abort(); };
	});
});


// CONFIGURE

function _Http_configureRequest(xhr, request)
{
	for (var headers = request.dM; headers.b; headers = headers.b) // WHILE_CONS
	{
		xhr.setRequestHeader(headers.a.a, headers.a.b);
	}
	xhr.timeout = request.en.a || 0;
	xhr.responseType = request.bY.d;
	xhr.withCredentials = request.dw;
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
		eq: xhr.responseURL,
		ca: xhr.status,
		ej: xhr.statusText,
		dM: _Http_parseHeaders(xhr.getAllResponseHeaders())
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
			ei: event.loaded,
			dd: event.total
		}))));
	});
	xhr.addEventListener('progress', function(event) {
		if (xhr.c) { return; }
		_Scheduler_rawSpawn(A2($elm$core$Platform$sendToSelf, router, _Utils_Tuple2(tracker, $elm$http$Http$Receiving({
			ec: event.loaded,
			dd: event.lengthComputable ? $elm$core$Maybe$Just(event.total) : $elm$core$Maybe$Nothing
		}))));
	});
}

// BYTES

function _Bytes_width(bytes)
{
	return bytes.byteLength;
}

var _Bytes_getHostEndianness = F2(function(le, be)
{
	return _Scheduler_binding(function(callback)
	{
		callback(_Scheduler_succeed(new Uint8Array(new Uint32Array([1]))[0] === 1 ? le : be));
	});
});


// ENCODERS

function _Bytes_encode(encoder)
{
	var mutableBytes = new DataView(new ArrayBuffer($elm$bytes$Bytes$Encode$getWidth(encoder)));
	$elm$bytes$Bytes$Encode$write(encoder)(mutableBytes)(0);
	return mutableBytes;
}


// SIGNED INTEGERS

var _Bytes_write_i8  = F3(function(mb, i, n) { mb.setInt8(i, n); return i + 1; });
var _Bytes_write_i16 = F4(function(mb, i, n, isLE) { mb.setInt16(i, n, isLE); return i + 2; });
var _Bytes_write_i32 = F4(function(mb, i, n, isLE) { mb.setInt32(i, n, isLE); return i + 4; });


// UNSIGNED INTEGERS

var _Bytes_write_u8  = F3(function(mb, i, n) { mb.setUint8(i, n); return i + 1 ;});
var _Bytes_write_u16 = F4(function(mb, i, n, isLE) { mb.setUint16(i, n, isLE); return i + 2; });
var _Bytes_write_u32 = F4(function(mb, i, n, isLE) { mb.setUint32(i, n, isLE); return i + 4; });


// FLOATS

var _Bytes_write_f32 = F4(function(mb, i, n, isLE) { mb.setFloat32(i, n, isLE); return i + 4; });
var _Bytes_write_f64 = F4(function(mb, i, n, isLE) { mb.setFloat64(i, n, isLE); return i + 8; });


// BYTES

var _Bytes_write_bytes = F3(function(mb, offset, bytes)
{
	for (var i = 0, len = bytes.byteLength, limit = len - 4; i <= limit; i += 4)
	{
		mb.setUint32(offset + i, bytes.getUint32(i));
	}
	for (; i < len; i++)
	{
		mb.setUint8(offset + i, bytes.getUint8(i));
	}
	return offset + len;
});


// STRINGS

function _Bytes_getStringWidth(string)
{
	for (var width = 0, i = 0; i < string.length; i++)
	{
		var code = string.charCodeAt(i);
		width +=
			(code < 0x80) ? 1 :
			(code < 0x800) ? 2 :
			(code < 0xD800 || 0xDBFF < code) ? 3 : (i++, 4);
	}
	return width;
}

var _Bytes_write_string = F3(function(mb, offset, string)
{
	for (var i = 0; i < string.length; i++)
	{
		var code = string.charCodeAt(i);
		offset +=
			(code < 0x80)
				? (mb.setUint8(offset, code)
				, 1
				)
				:
			(code < 0x800)
				? (mb.setUint16(offset, 0xC080 /* 0b1100000010000000 */
					| (code >>> 6 & 0x1F /* 0b00011111 */) << 8
					| code & 0x3F /* 0b00111111 */)
				, 2
				)
				:
			(code < 0xD800 || 0xDBFF < code)
				? (mb.setUint16(offset, 0xE080 /* 0b1110000010000000 */
					| (code >>> 12 & 0xF /* 0b00001111 */) << 8
					| code >>> 6 & 0x3F /* 0b00111111 */)
				, mb.setUint8(offset + 2, 0x80 /* 0b10000000 */
					| code & 0x3F /* 0b00111111 */)
				, 3
				)
				:
			(code = (code - 0xD800) * 0x400 + string.charCodeAt(++i) - 0xDC00 + 0x10000
			, mb.setUint32(offset, 0xF0808080 /* 0b11110000100000001000000010000000 */
				| (code >>> 18 & 0x7 /* 0b00000111 */) << 24
				| (code >>> 12 & 0x3F /* 0b00111111 */) << 16
				| (code >>> 6 & 0x3F /* 0b00111111 */) << 8
				| code & 0x3F /* 0b00111111 */)
			, 4
			);
	}
	return offset;
});


// DECODER

var _Bytes_decode = F2(function(decoder, bytes)
{
	try {
		return $elm$core$Maybe$Just(A2(decoder, bytes, 0).b);
	} catch(e) {
		return $elm$core$Maybe$Nothing;
	}
});

var _Bytes_read_i8  = F2(function(      bytes, offset) { return _Utils_Tuple2(offset + 1, bytes.getInt8(offset)); });
var _Bytes_read_i16 = F3(function(isLE, bytes, offset) { return _Utils_Tuple2(offset + 2, bytes.getInt16(offset, isLE)); });
var _Bytes_read_i32 = F3(function(isLE, bytes, offset) { return _Utils_Tuple2(offset + 4, bytes.getInt32(offset, isLE)); });
var _Bytes_read_u8  = F2(function(      bytes, offset) { return _Utils_Tuple2(offset + 1, bytes.getUint8(offset)); });
var _Bytes_read_u16 = F3(function(isLE, bytes, offset) { return _Utils_Tuple2(offset + 2, bytes.getUint16(offset, isLE)); });
var _Bytes_read_u32 = F3(function(isLE, bytes, offset) { return _Utils_Tuple2(offset + 4, bytes.getUint32(offset, isLE)); });
var _Bytes_read_f32 = F3(function(isLE, bytes, offset) { return _Utils_Tuple2(offset + 4, bytes.getFloat32(offset, isLE)); });
var _Bytes_read_f64 = F3(function(isLE, bytes, offset) { return _Utils_Tuple2(offset + 8, bytes.getFloat64(offset, isLE)); });

var _Bytes_read_bytes = F3(function(len, bytes, offset)
{
	return _Utils_Tuple2(offset + len, new DataView(bytes.buffer, bytes.byteOffset + offset, len));
});

var _Bytes_read_string = F3(function(len, bytes, offset)
{
	var string = '';
	var end = offset + len;
	for (; offset < end;)
	{
		var byte = bytes.getUint8(offset++);
		string +=
			(byte < 128)
				? String.fromCharCode(byte)
				:
			((byte & 0xE0 /* 0b11100000 */) === 0xC0 /* 0b11000000 */)
				? String.fromCharCode((byte & 0x1F /* 0b00011111 */) << 6 | bytes.getUint8(offset++) & 0x3F /* 0b00111111 */)
				:
			((byte & 0xF0 /* 0b11110000 */) === 0xE0 /* 0b11100000 */)
				? String.fromCharCode(
					(byte & 0xF /* 0b00001111 */) << 12
					| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
					| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
				)
				:
				(byte =
					((byte & 0x7 /* 0b00000111 */) << 18
						| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 12
						| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
						| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
					) - 0x10000
				, String.fromCharCode(Math.floor(byte / 0x400) + 0xD800, byte % 0x400 + 0xDC00)
				);
	}
	return _Utils_Tuple2(offset, string);
});

var _Bytes_decodeFailure = F2(function() { throw 0; });



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
var $elm$core$List$cons = _List_cons;
var $elm$core$Elm$JsArray$foldr = _JsArray_foldr;
var $elm$core$Array$foldr = F3(
	function (func, baseCase, _v0) {
		var tree = _v0.c;
		var tail = _v0.d;
		var helper = F2(
			function (node, acc) {
				if (!node.$) {
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
			if (t.$ === -2) {
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
	var dict = _v0;
	return $elm$core$Dict$keys(dict);
};
var $elm$core$Basics$EQ = 1;
var $elm$core$Basics$GT = 2;
var $elm$core$Basics$LT = 0;
var $elm$core$Basics$apR = F2(
	function (x, f) {
		return f(x);
	});
var $elm$core$Task$andThen = _Scheduler_andThen;
var $author$project$System$IO$bind = $elm$core$Task$andThen;
var $author$project$Utils$Impure$Crash = {$: 4};
var $author$project$Utils$Impure$JsonBody = function (a) {
	return {$: 2, a: a};
};
var $elm$core$Maybe$Nothing = {$: 1};
var $elm$core$Result$Ok = function (a) {
	return {$: 0, a: a};
};
var $elm$core$Basics$append = _Utils_append;
var $elm$http$Http$BadStatus_ = F2(
	function (a, b) {
		return {$: 3, a: a, b: b};
	});
var $elm$http$Http$BadUrl_ = function (a) {
	return {$: 0, a: a};
};
var $elm$http$Http$GoodStatus_ = F2(
	function (a, b) {
		return {$: 4, a: a, b: b};
	});
var $elm$core$Maybe$Just = function (a) {
	return {$: 0, a: a};
};
var $elm$http$Http$NetworkError_ = {$: 2};
var $elm$http$Http$Receiving = function (a) {
	return {$: 1, a: a};
};
var $elm$http$Http$Sending = function (a) {
	return {$: 0, a: a};
};
var $elm$http$Http$Timeout_ = {$: 1};
var $elm$core$Dict$RBEmpty_elm_builtin = {$: -2};
var $elm$core$Dict$empty = $elm$core$Dict$RBEmpty_elm_builtin;
var $elm$core$Basics$False = 1;
var $elm$core$Basics$True = 0;
var $elm$core$Maybe$isJust = function (maybe) {
	if (!maybe.$) {
		return true;
	} else {
		return false;
	}
};
var $elm$core$Result$Err = function (a) {
	return {$: 1, a: a};
};
var $elm$json$Json$Decode$Failure = F2(
	function (a, b) {
		return {$: 3, a: a, b: b};
	});
var $elm$json$Json$Decode$Field = F2(
	function (a, b) {
		return {$: 0, a: a, b: b};
	});
var $elm$json$Json$Decode$Index = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $elm$json$Json$Decode$OneOf = function (a) {
	return {$: 2, a: a};
};
var $elm$core$Basics$add = _Basics_add;
var $elm$core$String$all = _String_all;
var $elm$core$Basics$and = _Basics_and;
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
				case 0:
					var f = error.a;
					var err = error.b;
					var isSimple = function () {
						var _v1 = $elm$core$String$uncons(f);
						if (_v1.$ === 1) {
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
				case 1:
					var i = error.a;
					var err = error.b;
					var indexName = '[' + ($elm$core$String$fromInt(i) + ']');
					var $temp$error = err,
						$temp$context = A2($elm$core$List$cons, indexName, context);
					error = $temp$error;
					context = $temp$context;
					continue errorToStringHelp;
				case 2:
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
		return {$: 0, a: a, b: b, c: c, d: d};
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
	return {$: 1, a: a};
};
var $elm$core$Basics$apL = F2(
	function (f, x) {
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
	return {$: 0, a: a};
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
		if (!builder.v) {
			return A4(
				$elm$core$Array$Array_elm_builtin,
				$elm$core$Elm$JsArray$length(builder.x),
				$elm$core$Array$shiftStep,
				$elm$core$Elm$JsArray$empty,
				builder.x);
		} else {
			var treeLen = builder.v * $elm$core$Array$branchFactor;
			var depth = $elm$core$Basics$floor(
				A2($elm$core$Basics$logBase, $elm$core$Array$branchFactor, treeLen - 1));
			var correctNodeList = reverseNodeList ? $elm$core$List$reverse(builder.B) : builder.B;
			var tree = A2($elm$core$Array$treeFromBuilder, correctNodeList, builder.v);
			return A4(
				$elm$core$Array$Array_elm_builtin,
				$elm$core$Elm$JsArray$length(builder.x) + treeLen,
				A2($elm$core$Basics$max, 5, depth * $elm$core$Array$shiftStep),
				tree,
				builder.x);
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
					{B: nodeList, v: (len / $elm$core$Array$branchFactor) | 0, x: tail});
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
var $elm$core$Result$isOk = function (result) {
	if (!result.$) {
		return true;
	} else {
		return false;
	}
};
var $elm$core$Platform$sendToSelf = _Platform_sendToSelf;
var $elm$core$Basics$compare = _Utils_compare;
var $elm$core$Dict$get = F2(
	function (targetKey, dict) {
		get:
		while (true) {
			if (dict.$ === -2) {
				return $elm$core$Maybe$Nothing;
			} else {
				var key = dict.b;
				var value = dict.c;
				var left = dict.d;
				var right = dict.e;
				var _v1 = A2($elm$core$Basics$compare, targetKey, key);
				switch (_v1) {
					case 0:
						var $temp$targetKey = targetKey,
							$temp$dict = left;
						targetKey = $temp$targetKey;
						dict = $temp$dict;
						continue get;
					case 1:
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
var $elm$core$Dict$Black = 1;
var $elm$core$Dict$RBNode_elm_builtin = F5(
	function (a, b, c, d, e) {
		return {$: -1, a: a, b: b, c: c, d: d, e: e};
	});
var $elm$core$Dict$Red = 0;
var $elm$core$Dict$balance = F5(
	function (color, key, value, left, right) {
		if ((right.$ === -1) && (!right.a)) {
			var _v1 = right.a;
			var rK = right.b;
			var rV = right.c;
			var rLeft = right.d;
			var rRight = right.e;
			if ((left.$ === -1) && (!left.a)) {
				var _v3 = left.a;
				var lK = left.b;
				var lV = left.c;
				var lLeft = left.d;
				var lRight = left.e;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					0,
					key,
					value,
					A5($elm$core$Dict$RBNode_elm_builtin, 1, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, 1, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					color,
					rK,
					rV,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, key, value, left, rLeft),
					rRight);
			}
		} else {
			if ((((left.$ === -1) && (!left.a)) && (left.d.$ === -1)) && (!left.d.a)) {
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
					0,
					lK,
					lV,
					A5($elm$core$Dict$RBNode_elm_builtin, 1, llK, llV, llLeft, llRight),
					A5($elm$core$Dict$RBNode_elm_builtin, 1, key, value, lRight, right));
			} else {
				return A5($elm$core$Dict$RBNode_elm_builtin, color, key, value, left, right);
			}
		}
	});
var $elm$core$Dict$insertHelp = F3(
	function (key, value, dict) {
		if (dict.$ === -2) {
			return A5($elm$core$Dict$RBNode_elm_builtin, 0, key, value, $elm$core$Dict$RBEmpty_elm_builtin, $elm$core$Dict$RBEmpty_elm_builtin);
		} else {
			var nColor = dict.a;
			var nKey = dict.b;
			var nValue = dict.c;
			var nLeft = dict.d;
			var nRight = dict.e;
			var _v1 = A2($elm$core$Basics$compare, key, nKey);
			switch (_v1) {
				case 0:
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						A3($elm$core$Dict$insertHelp, key, value, nLeft),
						nRight);
				case 1:
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
		if ((_v0.$ === -1) && (!_v0.a)) {
			var _v1 = _v0.a;
			var k = _v0.b;
			var v = _v0.c;
			var l = _v0.d;
			var r = _v0.e;
			return A5($elm$core$Dict$RBNode_elm_builtin, 1, k, v, l, r);
		} else {
			var x = _v0;
			return x;
		}
	});
var $elm$core$Dict$getMin = function (dict) {
	getMin:
	while (true) {
		if ((dict.$ === -1) && (dict.d.$ === -1)) {
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
	if (((dict.$ === -1) && (dict.d.$ === -1)) && (dict.e.$ === -1)) {
		if ((dict.e.d.$ === -1) && (!dict.e.d.a)) {
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
				0,
				rlK,
				rlV,
				A5(
					$elm$core$Dict$RBNode_elm_builtin,
					1,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, lK, lV, lLeft, lRight),
					rlL),
				A5($elm$core$Dict$RBNode_elm_builtin, 1, rK, rV, rlR, rRight));
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
			if (clr === 1) {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					1,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, 0, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					1,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, 0, rK, rV, rLeft, rRight));
			}
		}
	} else {
		return dict;
	}
};
var $elm$core$Dict$moveRedRight = function (dict) {
	if (((dict.$ === -1) && (dict.d.$ === -1)) && (dict.e.$ === -1)) {
		if ((dict.d.d.$ === -1) && (!dict.d.d.a)) {
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
				0,
				lK,
				lV,
				A5($elm$core$Dict$RBNode_elm_builtin, 1, llK, llV, llLeft, llRight),
				A5(
					$elm$core$Dict$RBNode_elm_builtin,
					1,
					k,
					v,
					lRight,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, rK, rV, rLeft, rRight)));
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
			if (clr === 1) {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					1,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, 0, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					1,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, 0, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, 0, rK, rV, rLeft, rRight));
			}
		}
	} else {
		return dict;
	}
};
var $elm$core$Dict$removeHelpPrepEQGT = F7(
	function (targetKey, dict, color, key, value, left, right) {
		if ((left.$ === -1) && (!left.a)) {
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
				A5($elm$core$Dict$RBNode_elm_builtin, 0, key, value, lRight, right));
		} else {
			_v2$2:
			while (true) {
				if ((right.$ === -1) && (right.a === 1)) {
					if (right.d.$ === -1) {
						if (right.d.a === 1) {
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
	if ((dict.$ === -1) && (dict.d.$ === -1)) {
		var color = dict.a;
		var key = dict.b;
		var value = dict.c;
		var left = dict.d;
		var lColor = left.a;
		var lLeft = left.d;
		var right = dict.e;
		if (lColor === 1) {
			if ((lLeft.$ === -1) && (!lLeft.a)) {
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
				if (_v4.$ === -1) {
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
		if (dict.$ === -2) {
			return $elm$core$Dict$RBEmpty_elm_builtin;
		} else {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			if (_Utils_cmp(targetKey, key) < 0) {
				if ((left.$ === -1) && (left.a === 1)) {
					var _v4 = left.a;
					var lLeft = left.d;
					if ((lLeft.$ === -1) && (!lLeft.a)) {
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
						if (_v7.$ === -1) {
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
		if (dict.$ === -1) {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			if (_Utils_eq(targetKey, key)) {
				var _v1 = $elm$core$Dict$getMin(right);
				if (_v1.$ === -1) {
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
		if ((_v0.$ === -1) && (!_v0.a)) {
			var _v1 = _v0.a;
			var k = _v0.b;
			var v = _v0.c;
			var l = _v0.d;
			var r = _v0.e;
			return A5($elm$core$Dict$RBNode_elm_builtin, 1, k, v, l, r);
		} else {
			var x = _v0;
			return x;
		}
	});
var $elm$core$Dict$update = F3(
	function (targetKey, alter, dictionary) {
		var _v0 = alter(
			A2($elm$core$Dict$get, targetKey, dictionary));
		if (!_v0.$) {
			var value = _v0.a;
			return A3($elm$core$Dict$insert, targetKey, value, dictionary);
		} else {
			return A2($elm$core$Dict$remove, targetKey, dictionary);
		}
	});
var $elm$http$Http$bytesBody = _Http_pair;
var $elm$http$Http$bytesResolver = A2(_Http_expect, 'arraybuffer', _Http_toDataView);
var $author$project$Utils$Crash$crash = function (str) {
	crash:
	while (true) {
		var $temp$str = str;
		str = $temp$str;
		continue crash;
	}
};
var $elm$bytes$Bytes$Encode$getWidth = function (builder) {
	switch (builder.$) {
		case 0:
			return 1;
		case 1:
			return 2;
		case 2:
			return 4;
		case 3:
			return 1;
		case 4:
			return 2;
		case 5:
			return 4;
		case 6:
			return 4;
		case 7:
			return 8;
		case 8:
			var w = builder.a;
			return w;
		case 9:
			var w = builder.a;
			return w;
		default:
			var bs = builder.a;
			return _Bytes_width(bs);
	}
};
var $elm$bytes$Bytes$LE = 0;
var $elm$bytes$Bytes$Encode$write = F3(
	function (builder, mb, offset) {
		switch (builder.$) {
			case 0:
				var n = builder.a;
				return A3(_Bytes_write_i8, mb, offset, n);
			case 1:
				var e = builder.a;
				var n = builder.b;
				return A4(_Bytes_write_i16, mb, offset, n, !e);
			case 2:
				var e = builder.a;
				var n = builder.b;
				return A4(_Bytes_write_i32, mb, offset, n, !e);
			case 3:
				var n = builder.a;
				return A3(_Bytes_write_u8, mb, offset, n);
			case 4:
				var e = builder.a;
				var n = builder.b;
				return A4(_Bytes_write_u16, mb, offset, n, !e);
			case 5:
				var e = builder.a;
				var n = builder.b;
				return A4(_Bytes_write_u32, mb, offset, n, !e);
			case 6:
				var e = builder.a;
				var n = builder.b;
				return A4(_Bytes_write_f32, mb, offset, n, !e);
			case 7:
				var e = builder.a;
				var n = builder.b;
				return A4(_Bytes_write_f64, mb, offset, n, !e);
			case 8:
				var bs = builder.b;
				return A3($elm$bytes$Bytes$Encode$writeSequence, bs, mb, offset);
			case 9:
				var s = builder.b;
				return A3(_Bytes_write_string, mb, offset, s);
			default:
				var bs = builder.a;
				return A3(_Bytes_write_bytes, mb, offset, bs);
		}
	});
var $elm$bytes$Bytes$Encode$writeSequence = F3(
	function (builders, mb, offset) {
		writeSequence:
		while (true) {
			if (!builders.b) {
				return offset;
			} else {
				var b = builders.a;
				var bs = builders.b;
				var $temp$builders = bs,
					$temp$mb = mb,
					$temp$offset = A3($elm$bytes$Bytes$Encode$write, b, mb, offset);
				builders = $temp$builders;
				mb = $temp$mb;
				offset = $temp$offset;
				continue writeSequence;
			}
		}
	});
var $elm$bytes$Bytes$Decode$decode = F2(
	function (_v0, bs) {
		var decoder = _v0;
		return A2(_Bytes_decode, decoder, bs);
	});
var $author$project$Utils$Bytes$Decode$decode = $elm$bytes$Bytes$Decode$decode;
var $elm$json$Json$Decode$decodeString = _Json_runOnString;
var $elm$http$Http$emptyBody = _Http_emptyBody;
var $elm$bytes$Bytes$Encode$encode = _Bytes_encode;
var $author$project$Utils$Bytes$Encode$encode = $elm$bytes$Bytes$Encode$encode;
var $elm$http$Http$jsonBody = function (value) {
	return A2(
		_Http_pair,
		'application/json',
		A2($elm$json$Json$Encode$encode, 0, value));
};
var $elm$http$Http$stringBody = _Http_pair;
var $elm$core$Basics$identity = function (x) {
	return x;
};
var $elm$http$Http$stringResolver = A2(_Http_expect, '', $elm$core$Basics$identity);
var $elm$core$Task$fail = _Scheduler_fail;
var $elm$core$Task$succeed = _Scheduler_succeed;
var $elm$http$Http$resultToTask = function (result) {
	if (!result.$) {
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
		0,
		$elm$http$Http$resultToTask,
		{dw: false, dA: r.dA, bY: r.ef, dM: r.dM, dV: r.dV, en: r.en, dq: $elm$core$Maybe$Nothing, eq: r.eq});
};
var $author$project$Utils$Impure$customTask = F5(
	function (method, url, headers, body, resolver) {
		return $elm$http$Http$task(
			{
				dA: function () {
					switch (body.$) {
						case 0:
							return $elm$http$Http$emptyBody;
						case 1:
							var string = body.a;
							return A2($elm$http$Http$stringBody, 'text/plain', string);
						case 2:
							var value = body.a;
							return $elm$http$Http$jsonBody(value);
						default:
							var encoder = body.a;
							return A2(
								$elm$http$Http$bytesBody,
								'application/octet-stream',
								$author$project$Utils$Bytes$Encode$encode(encoder));
					}
				}(),
				dM: headers,
				dV: method,
				ef: function () {
					switch (resolver.$) {
						case 0:
							var x = resolver.a;
							return $elm$http$Http$stringResolver(
								function (_v2) {
									return $elm$core$Result$Ok(x);
								});
						case 1:
							var fn = resolver.a;
							return $elm$http$Http$stringResolver(
								function (response) {
									switch (response.$) {
										case 0:
											var url_ = response.a;
											return $author$project$Utils$Crash$crash('Unexpected BadUrl: ' + url_);
										case 1:
											return $author$project$Utils$Crash$crash('Unexpected Timeout');
										case 2:
											return $author$project$Utils$Crash$crash('Unexpected NetworkError');
										case 3:
											var metadata = response.a;
											return $author$project$Utils$Crash$crash(
												'Unexpected BadStatus. Status code: ' + $elm$core$String$fromInt(metadata.ca));
										default:
											var body_ = response.b;
											return $elm$core$Result$Ok(
												fn(body_));
									}
								});
						case 2:
							var decoder = resolver.a;
							return $elm$http$Http$stringResolver(
								function (response) {
									switch (response.$) {
										case 0:
											var url_ = response.a;
											return $author$project$Utils$Crash$crash('Unexpected BadUrl: ' + url_);
										case 1:
											return $author$project$Utils$Crash$crash('Unexpected Timeout');
										case 2:
											return $author$project$Utils$Crash$crash('Unexpected NetworkError');
										case 3:
											var metadata = response.a;
											return $author$project$Utils$Crash$crash(
												'Unexpected BadStatus. Status code: ' + $elm$core$String$fromInt(metadata.ca));
										default:
											var body_ = response.b;
											var _v5 = A2($elm$json$Json$Decode$decodeString, decoder, body_);
											if (!_v5.$) {
												var value = _v5.a;
												return $elm$core$Result$Ok(value);
											} else {
												var err = _v5.a;
												return $author$project$Utils$Crash$crash(
													'Decoding error: ' + $elm$json$Json$Decode$errorToString(err));
											}
									}
								});
						case 3:
							var decoder = resolver.a;
							return $elm$http$Http$bytesResolver(
								function (response) {
									switch (response.$) {
										case 0:
											var url_ = response.a;
											return $author$project$Utils$Crash$crash('Unexpected BadUrl: ' + url_);
										case 1:
											return $author$project$Utils$Crash$crash('Unexpected Timeout');
										case 2:
											return $author$project$Utils$Crash$crash('Unexpected NetworkError');
										case 3:
											var metadata = response.a;
											return $author$project$Utils$Crash$crash(
												'Unexpected BadStatus. Status code: ' + $elm$core$String$fromInt(metadata.ca));
										default:
											var body_ = response.b;
											var _v7 = A2($author$project$Utils$Bytes$Decode$decode, decoder, body_);
											if (!_v7.$) {
												var value = _v7.a;
												return $elm$core$Result$Ok(value);
											} else {
												return $author$project$Utils$Crash$crash('Decoding bytes error...');
											}
									}
								});
						default:
							return $elm$http$Http$stringResolver(
								function (_v8) {
									return $author$project$Utils$Crash$crash(url);
								});
					}
				}(),
				en: $elm$core$Maybe$Nothing,
				eq: url
			});
	});
var $author$project$Utils$Impure$task = F4(
	function (url, headers, body, resolver) {
		return A5($author$project$Utils$Impure$customTask, 'POST', url, headers, body, resolver);
	});
var $author$project$Node$Main$exitWithResponse = function (value) {
	return A4(
		$author$project$Utils$Impure$task,
		'exitWithResponse',
		_List_Nil,
		$author$project$Utils$Impure$JsonBody(value),
		$author$project$Utils$Impure$Crash);
};
var $author$project$Utils$Impure$DecoderResolver = function (a) {
	return {$: 2, a: a};
};
var $author$project$Utils$Impure$EmptyBody = {$: 0};
var $author$project$Node$Main$FormatArgs = $elm$core$Basics$identity;
var $elm$json$Json$Decode$andThen = _Json_andThen;
var $elm$json$Json$Decode$fail = _Json_fail;
var $elm$json$Json$Decode$field = _Json_decodeField;
var $elm$json$Json$Decode$map = _Json_map1;
var $elm$json$Json$Decode$string = _Json_decodeString;
var $author$project$Node$Main$argsDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (command) {
		if (command === 'format') {
			return A2(
				$elm$json$Json$Decode$map,
				$elm$core$Basics$identity,
				A2($elm$json$Json$Decode$field, 'content', $elm$json$Json$Decode$string));
		} else {
			return $elm$json$Json$Decode$fail('Unknown command: ' + command);
		}
	},
	A2($elm$json$Json$Decode$field, 'command', $elm$json$Json$Decode$string));
var $author$project$Node$Main$getArgs = A4(
	$author$project$Utils$Impure$task,
	'getArgs',
	_List_Nil,
	$author$project$Utils$Impure$EmptyBody,
	$author$project$Utils$Impure$DecoderResolver($author$project$Node$Main$argsDecoder));
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
			_Json_emptyObject(0),
			pairs));
};
var $stil4m$elm_syntax$Elm$Syntax$Module$EffectModule = function (a) {
	return {$: 2, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Node$Node = F2(
	function (a, b) {
		return {$: 0, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Module$NormalModule = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Module$PortModule = function (a) {
	return {$: 1, a: a};
};
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
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeLikelyFilledToListInto = F2(
	function (initialAcc, ropeLikelyFilled) {
		ropeLikelyFilledToListInto:
		while (true) {
			if (!ropeLikelyFilled.$) {
				var onlyElement = ropeLikelyFilled.a;
				return A2($elm$core$List$cons, onlyElement, initialAcc);
			} else {
				var left = ropeLikelyFilled.a;
				var right = ropeLikelyFilled.b;
				var $temp$initialAcc = A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeLikelyFilledToListInto, initialAcc, right),
					$temp$ropeLikelyFilled = left;
				initialAcc = $temp$initialAcc;
				ropeLikelyFilled = $temp$ropeLikelyFilled;
				continue ropeLikelyFilledToListInto;
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeToList = function (rope) {
	if (rope.$ === 1) {
		return _List_Nil;
	} else {
		var ropeLikelyFilled = rope.a;
		return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeLikelyFilledToListInto, _List_Nil, ropeLikelyFilled);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$commentsToList = function (comments) {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeToList(comments);
};
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
var $elm$core$List$concatMap = F2(
	function (f, list) {
		return $elm$core$List$concat(
			A2($elm$core$List$map, f, list));
	});
var $stil4m$elm_syntax$Elm$Syntax$Declaration$AliasDeclaration = function (a) {
	return {$: 1, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Declaration$CustomTypeDeclaration = function (a) {
	return {$: 2, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Declaration$FunctionDeclaration = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Declaration$PortDeclaration = function (a) {
	return {$: 3, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Node$combine = F3(
	function (f, a, b) {
		var start = a.a.b9;
		var end = b.a.cw;
		return A2(
			$stil4m$elm_syntax$Elm$Syntax$Node$Node,
			{cw: end, b9: start},
			A2(f, a, b));
	});
var $lue_bird$elm_syntax_format$ParserFast$Done = function (a) {
	return {$: 1, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$Loop = function (a) {
	return {$: 0, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$Good = F2(
	function (a, b) {
		return {$: 0, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ParserFast$Parser = $elm$core$Basics$identity;
var $elm$core$String$any = _String_any;
var $elm$core$Basics$isNaN = _Basics_isNaN;
var $lue_bird$elm_syntax_format$Char$Extra$isUtf16Surrogate = function (c) {
	return $elm$core$Basics$isNaN(
		$elm$core$Char$toCode(c));
};
var $lue_bird$elm_syntax_format$ParserFast$charStringIsUtf16HighSurrogate = function (charString) {
	return A2($elm$core$String$any, $lue_bird$elm_syntax_format$Char$Extra$isUtf16Surrogate, charString);
};
var $elm$core$Basics$negate = function (n) {
	return -n;
};
var $elm$core$String$slice = _String_slice;
var $lue_bird$elm_syntax_format$ParserFast$charOrEnd = F2(
	function (offset, string) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, string);
		switch (_v0) {
			case '\n':
				return -2;
			case '':
				return -1;
			default:
				var charNotLinebreakNotEndOfSource = _v0;
				return $lue_bird$elm_syntax_format$ParserFast$charStringIsUtf16HighSurrogate(charNotLinebreakNotEndOfSource) ? (offset + 2) : (offset + 1);
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$Bad = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking = A2($lue_bird$elm_syntax_format$ParserFast$Bad, false, 0);
var $lue_bird$elm_syntax_format$ParserFast$skipWhileHelp = F6(
	function (isGood, offset, row, col, src, indent) {
		skipWhileHelp:
		while (true) {
			var actualChar = A3($elm$core$String$slice, offset, offset + 1, src);
			if (A2($elm$core$String$any, isGood, actualChar)) {
				if (actualChar === '\n') {
					var $temp$isGood = isGood,
						$temp$offset = offset + 1,
						$temp$row = row + 1,
						$temp$col = 1,
						$temp$src = src,
						$temp$indent = indent;
					isGood = $temp$isGood;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileHelp;
				} else {
					var $temp$isGood = isGood,
						$temp$offset = offset + 1,
						$temp$row = row,
						$temp$col = col + 1,
						$temp$src = src,
						$temp$indent = indent;
					isGood = $temp$isGood;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileHelp;
				}
			} else {
				if ($lue_bird$elm_syntax_format$ParserFast$charStringIsUtf16HighSurrogate(actualChar) && A2(
					$elm$core$String$any,
					isGood,
					A3($elm$core$String$slice, offset, offset + 2, src))) {
					var $temp$isGood = isGood,
						$temp$offset = offset + 2,
						$temp$row = row,
						$temp$col = col + 1,
						$temp$src = src,
						$temp$indent = indent;
					isGood = $temp$isGood;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileHelp;
				} else {
					return {co: col, m: indent, i: offset, c9: row, g: src};
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$anyCharFollowedByWhileMap = F2(
	function (consumedStringToRes, afterFirstIsOkay) {
		return function (s) {
			var firstOffset = A2($lue_bird$elm_syntax_format$ParserFast$charOrEnd, s.i, s.g);
			if (_Utils_eq(firstOffset, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var s1 = _Utils_eq(firstOffset, -2) ? A6($lue_bird$elm_syntax_format$ParserFast$skipWhileHelp, afterFirstIsOkay, s.i + 1, s.c9 + 1, 1, s.g, s.m) : A6($lue_bird$elm_syntax_format$ParserFast$skipWhileHelp, afterFirstIsOkay, firstOffset, s.c9, s.co + 1, s.g, s.m);
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					consumedStringToRes(
						A3($elm$core$String$slice, s.i, s1.i, s.g)),
					s1);
			}
		};
	});
var $elm$core$String$cons = _String_cons;
var $lue_bird$elm_syntax_format$ParserFast$loopHelp = F5(
	function (committedSoFar, state, element, reduce, s0) {
		loopHelp:
		while (true) {
			var parseElement = element;
			var _v0 = parseElement(s0);
			if (!_v0.$) {
				var step = _v0.a;
				var s1 = _v0.b;
				var _v1 = A2(reduce, step, state);
				if (!_v1.$) {
					var newState = _v1.a;
					var $temp$committedSoFar = true,
						$temp$state = newState,
						$temp$element = element,
						$temp$reduce = reduce,
						$temp$s0 = s1;
					committedSoFar = $temp$committedSoFar;
					state = $temp$state;
					element = $temp$element;
					reduce = $temp$reduce;
					s0 = $temp$s0;
					continue loopHelp;
				} else {
					var result = _v1.a;
					return A2($lue_bird$elm_syntax_format$ParserFast$Good, result, s1);
				}
			} else {
				var elementCommitted = _v0.a;
				var x = _v0.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committedSoFar || elementCommitted, x);
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$loop = F3(
	function (state, element, reduce) {
		return function (s) {
			return A5($lue_bird$elm_syntax_format$ParserFast$loopHelp, false, state, element, reduce, s);
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map2WithRange = F3(
	function (func, _v0, _v1) {
		var parseA = _v0;
		var parseB = _v1;
		return function (s0) {
			var _v2 = parseA(s0);
			if (_v2.$ === 1) {
				var committed = _v2.a;
				var x = _v2.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v2.a;
				var s1 = _v2.b;
				var _v3 = parseB(s1);
				if (_v3.$ === 1) {
					var x = _v3.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v3.a;
					var s2 = _v3.b;
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						A3(
							func,
							{
								cw: {cp: s2.co, c9: s2.c9},
								b9: {cp: s0.co, c9: s0.c9}
							},
							a,
							b),
						s2);
				}
			}
		};
	});
var $elm$core$Basics$neq = _Utils_notEqual;
var $elm$core$Basics$not = _Basics_not;
var $lue_bird$elm_syntax_format$ParserFast$oneOf2 = F2(
	function (_v0, _v1) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		return function (s) {
			var _v2 = attemptFirst(s);
			if (!_v2.$) {
				var firstGood = _v2;
				return firstGood;
			} else {
				var firstBad = _v2;
				var firstCommitted = firstBad.a;
				if (firstCommitted) {
					return firstBad;
				} else {
					var _v3 = attemptSecond(s);
					if (!_v3.$) {
						var secondGood = _v3;
						return secondGood;
					} else {
						var secondBad = _v3;
						var secondCommitted = secondBad.a;
						return secondCommitted ? secondBad : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$oneOf3 = F3(
	function (_v0, _v1, _v2) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		var attemptThird = _v2;
		return function (s) {
			var _v3 = attemptFirst(s);
			if (!_v3.$) {
				var firstGood = _v3;
				return firstGood;
			} else {
				var firstBad = _v3;
				var firstCommitted = firstBad.a;
				if (firstCommitted) {
					return firstBad;
				} else {
					var _v4 = attemptSecond(s);
					if (!_v4.$) {
						var secondGood = _v4;
						return secondGood;
					} else {
						var secondBad = _v4;
						var secondCommitted = secondBad.a;
						if (secondCommitted) {
							return secondBad;
						} else {
							var _v5 = attemptThird(s);
							if (!_v5.$) {
								var thirdGood = _v5;
								return thirdGood;
							} else {
								var thirdBad = _v5;
								var thirdCommitted = thirdBad.a;
								return thirdCommitted ? thirdBad : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
							}
						}
					}
				}
			}
		};
	});
var $elm$core$String$length = _String_length;
var $lue_bird$elm_syntax_format$ParserFast$symbol = F2(
	function (str, res) {
		var strLength = $elm$core$String$length(str);
		return function (s) {
			var newOffset = s.i + strLength;
			return _Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				str) ? A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				res,
				{co: s.co + strLength, m: s.m, i: newOffset, c9: s.c9, g: s.g}) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$pStepCommit = function (pStep) {
	if (!pStep.$) {
		var good = pStep;
		return good;
	} else {
		var x = pStep.b;
		return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
	}
};
var $lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy = F2(
	function (str, _v0) {
		var parseNext = _v0;
		var strLength = $elm$core$String$length(str);
		return function (s) {
			var newOffset = s.i + strLength;
			return _Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				str) ? $lue_bird$elm_syntax_format$ParserFast$pStepCommit(
				parseNext(
					{co: s.co + strLength, m: s.m, i: newOffset, c9: s.c9, g: s.g})) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$while = function (isGood) {
	return function (s0) {
		var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileHelp, isGood, s0.i, s0.c9, s0.co, s0.g, s0.m);
		return A2(
			$lue_bird$elm_syntax_format$ParserFast$Good,
			A3($elm$core$String$slice, s0.i, s1.i, s0.g),
			s1);
	};
};
var $lue_bird$elm_syntax_format$ParserFast$nestableMultiCommentMapWithRange = F3(
	function (rangeContentToRes, _v0, _v1) {
		var openChar = _v0.a;
		var openTail = _v0.b;
		var closeChar = _v1.a;
		var closeTail = _v1.b;
		var open = A2($elm$core$String$cons, openChar, openTail);
		var isNotRelevant = function (_char) {
			return (!_Utils_eq(_char, openChar)) && ((!_Utils_eq(_char, closeChar)) && (!$lue_bird$elm_syntax_format$Char$Extra$isUtf16Surrogate(_char)));
		};
		var close = A2($elm$core$String$cons, closeChar, closeTail);
		return A3(
			$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
			F3(
				function (range, afterOpen, contentAfterAfterOpen) {
					return A2(
						rangeContentToRes,
						range,
						_Utils_ap(
							open,
							_Utils_ap(
								afterOpen,
								_Utils_ap(contentAfterAfterOpen, close))));
				}),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
				open,
				$lue_bird$elm_syntax_format$ParserFast$while(isNotRelevant)),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2($lue_bird$elm_syntax_format$ParserFast$symbol, close, ''),
				A3(
					$lue_bird$elm_syntax_format$ParserFast$loop,
					_Utils_Tuple2('', 1),
					A3(
						$lue_bird$elm_syntax_format$ParserFast$oneOf3,
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbol,
							close,
							_Utils_Tuple2(close, -1)),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbol,
							open,
							_Utils_Tuple2(open, 1)),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$anyCharFollowedByWhileMap,
							function (consumed) {
								return _Utils_Tuple2(consumed, 0);
							},
							isNotRelevant)),
					F2(
						function (_v2, _v3) {
							var toAppend = _v2.a;
							var nestingChange = _v2.b;
							var soFarContent = _v3.a;
							var soFarNesting = _v3.b;
							var newNesting = soFarNesting + nestingChange;
							return (!newNesting) ? $lue_bird$elm_syntax_format$ParserFast$Done(soFarContent) : $lue_bird$elm_syntax_format$ParserFast$Loop(
								_Utils_Tuple2(soFarContent + (toAppend + ''), newNesting));
						}))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$documentationComment = A3(
	$lue_bird$elm_syntax_format$ParserFast$nestableMultiCommentMapWithRange,
	$stil4m$elm_syntax$Elm$Syntax$Node$Node,
	_Utils_Tuple2('{', '-'),
	_Utils_Tuple2('-', '}'));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FunctionDeclarationAfterDocumentation = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$Application = function (a) {
	return {$: 1, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$CaseExpression = function (a) {
	return {$: 16, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ExtendRightByOperation = $elm$core$Basics$identity;
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FieldsFirstValue = function (a) {
	return {$: 1, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FieldsFirstValuePunned = function (a) {
	return {$: 2, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$FunctionOrValue = F2(
	function (a, b) {
		return {$: 3, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Expression$IfBlock = F3(
	function (a, b, c) {
		return {$: 4, a: a, b: b, c: c};
	});
var $stil4m$elm_syntax$Elm$Syntax$Expression$LambdaExpression = function (a) {
	return {$: 17, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Infix$Left = 0;
var $stil4m$elm_syntax$Elm$Syntax$Expression$LetDestructuring = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Expression$LetExpression = function (a) {
	return {$: 15, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$LetFunction = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$ListExpr = function (a) {
	return {$: 19, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$Negation = function (a) {
	return {$: 10, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Infix$Non = 2;
var $stil4m$elm_syntax$Elm$Syntax$Expression$ParenthesizedExpression = function (a) {
	return {$: 14, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$RecordExpr = function (a) {
	return {$: 18, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$RecordUpdateExpression = F2(
	function (a, b) {
		return {$: 22, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RecordUpdateFirstSetter = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Infix$Right = 1;
var $stil4m$elm_syntax$Elm$Syntax$Expression$TupledExpression = function (a) {
	return {$: 13, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TupledParenthesized = F2(
	function (a, b) {
		return {$: 0, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TupledTwoOrThree = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Expression$UnitExpr = {$: 0};
var $stil4m$elm_syntax$Elm$Syntax$Expression$PrefixOperator = function (a) {
	return {$: 5, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isAllowedOperatorToken = function (operatorCandidateToValidate) {
	switch (operatorCandidateToValidate) {
		case '==':
			return true;
		case '/=':
			return true;
		case '::':
			return true;
		case '++':
			return true;
		case '+':
			return true;
		case '*':
			return true;
		case '<|':
			return true;
		case '|>':
			return true;
		case '||':
			return true;
		case '<=':
			return true;
		case '>=':
			return true;
		case '|=':
			return true;
		case '|.':
			return true;
		case '//':
			return true;
		case '</>':
			return true;
		case '<?>':
			return true;
		case '^':
			return true;
		case '<<':
			return true;
		case '>>':
			return true;
		case '<':
			return true;
		case '>':
			return true;
		case '/':
			return true;
		case '&&':
			return true;
		case '-':
			return true;
		default:
			return false;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isOperatorSymbolCharAsString = function (c) {
	switch (c) {
		case '|':
			return true;
		case '+':
			return true;
		case '<':
			return true;
		case '>':
			return true;
		case '=':
			return true;
		case '*':
			return true;
		case ':':
			return true;
		case '-':
			return true;
		case '/':
			return true;
		case '&':
			return true;
		case '.':
			return true;
		case '?':
			return true;
		case '^':
			return true;
		case '!':
			return true;
		default:
			return false;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty = $elm$core$Maybe$Nothing;
var $lue_bird$elm_syntax_format$ParserFast$whileAtMost3WithoutLinebreakAnd2PartUtf16ValidateMapWithRangeBacktrackableFollowedBySymbol = F4(
	function (whileRangeAndContentToRes, whileCharIsOkay, whileResultIsOkay, mandatoryFinalSymbol) {
		var mandatoryFinalSymbolLength = $elm$core$String$length(mandatoryFinalSymbol);
		return function (s0) {
			var src = s0.g;
			var s0Offset = s0.i;
			var _v0 = whileCharIsOkay(
				A3($elm$core$String$slice, s0Offset, s0Offset + 1, src)) ? (whileCharIsOkay(
				A3($elm$core$String$slice, s0Offset + 1, s0Offset + 2, src)) ? (whileCharIsOkay(
				A3($elm$core$String$slice, s0Offset + 2, s0Offset + 3, src)) ? _Utils_Tuple2(
				3,
				A3($elm$core$String$slice, s0Offset, s0Offset + 3, src)) : _Utils_Tuple2(
				2,
				A3($elm$core$String$slice, s0Offset, s0Offset + 2, src))) : _Utils_Tuple2(
				1,
				A3($elm$core$String$slice, s0Offset, s0Offset + 1, src))) : _Utils_Tuple2(0, '');
			var consumedBeforeFinalSymbolLength = _v0.a;
			var consumedBeforeFinalSymbolString = _v0.b;
			return (_Utils_eq(
				A3($elm$core$String$slice, s0Offset + consumedBeforeFinalSymbolLength, (s0Offset + consumedBeforeFinalSymbolLength) + mandatoryFinalSymbolLength, src),
				mandatoryFinalSymbol) && whileResultIsOkay(consumedBeforeFinalSymbolString)) ? A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				A2(
					whileRangeAndContentToRes,
					{
						cw: {cp: s0.co + consumedBeforeFinalSymbolLength, c9: s0.c9},
						b9: {cp: s0.co, c9: s0.c9}
					},
					consumedBeforeFinalSymbolString),
				{co: (s0.co + consumedBeforeFinalSymbolLength) + mandatoryFinalSymbolLength, m: s0.m, i: (s0Offset + consumedBeforeFinalSymbolLength) + mandatoryFinalSymbolLength, c9: s0.c9, g: src}) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$allowedPrefixOperatorFollowedByClosingParensOneOf = A4(
	$lue_bird$elm_syntax_format$ParserFast$whileAtMost3WithoutLinebreakAnd2PartUtf16ValidateMapWithRangeBacktrackableFollowedBySymbol,
	F2(
		function (operatorRange, operator) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					{
						cw: {cp: operatorRange.cw.cp + 1, c9: operatorRange.cw.c9},
						b9: {cp: operatorRange.b9.cp - 1, c9: operatorRange.b9.c9}
					},
					$stil4m$elm_syntax$Elm$Syntax$Expression$PrefixOperator(operator))
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isOperatorSymbolCharAsString,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isAllowedOperatorToken,
	')');
var $stil4m$elm_syntax$Elm$Syntax$Expression$OperatorApplication = F4(
	function (a, b, c, d) {
		return {$: 2, a: a, b: b, c: c, d: d};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$applyExtensionRight = F2(
	function (_v0, leftNode) {
		var operation = _v0;
		var _v1 = operation.u;
		var rightExpressionRange = _v1.a;
		var _v2 = leftNode;
		var leftRange = _v2.a;
		return A2(
			$stil4m$elm_syntax$Elm$Syntax$Node$Node,
			{cw: rightExpressionRange.cw, b9: leftRange.b9},
			A4($stil4m$elm_syntax$Elm$Syntax$Expression$OperatorApplication, operation.ad, operation.aw, leftNode, operation.u));
	});
var $stil4m$elm_syntax$Elm$Syntax$Expression$CharLiteral = function (a) {
	return {$: 12, a: a};
};
var $elm$core$String$foldr = _String_foldr;
var $elm$core$String$toList = function (string) {
	return A3($elm$core$String$foldr, $elm$core$List$cons, _List_Nil, string);
};
var $lue_bird$elm_syntax_format$ParserFast$anyChar = function (s) {
	var newOffset = A2($lue_bird$elm_syntax_format$ParserFast$charOrEnd, s.i, s.g);
	if (_Utils_eq(newOffset, -1)) {
		return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
	} else {
		if (_Utils_eq(newOffset, -2)) {
			return A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				'\n',
				{co: 1, m: s.m, i: s.i + 1, c9: s.c9 + 1, g: s.g});
		} else {
			var _v0 = $elm$core$String$toList(
				A3($elm$core$String$slice, s.i, newOffset, s.g));
			if (!_v0.b) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var c = _v0.a;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					c,
					{co: s.co + 1, m: s.m, i: newOffset, c9: s.c9, g: s.g});
			}
		}
	}
};
var $lue_bird$elm_syntax_format$ParserFast$pStepBadCommitting = A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, 0);
var $lue_bird$elm_syntax_format$ParserFast$followedBySymbol = F2(
	function (str, _v0) {
		var parsePrevious = _v0;
		var strLength = $elm$core$String$length(str);
		return function (s0) {
			var _v1 = parsePrevious(s0);
			if (!_v1.$) {
				var res = _v1.a;
				var s1 = _v1.b;
				var newOffset = s1.i + strLength;
				return _Utils_eq(
					A3($elm$core$String$slice, s1.i, newOffset, s1.g),
					str) ? A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					res,
					{co: s1.co + strLength, m: s1.m, i: newOffset, c9: s1.c9, g: s1.g}) : $lue_bird$elm_syntax_format$ParserFast$pStepBadCommitting;
			} else {
				var bad = _v1;
				return bad;
			}
		};
	});
var $elm$core$Char$fromCode = _Char_fromCode;
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charToHex = function (c) {
	switch (c) {
		case '0':
			return 0;
		case '1':
			return 1;
		case '2':
			return 2;
		case '3':
			return 3;
		case '4':
			return 4;
		case '5':
			return 5;
		case '6':
			return 6;
		case '7':
			return 7;
		case '8':
			return 8;
		case '9':
			return 9;
		case 'a':
			return 10;
		case 'b':
			return 11;
		case 'c':
			return 12;
		case 'd':
			return 13;
		case 'e':
			return 14;
		case 'f':
			return 15;
		case 'A':
			return 10;
		case 'B':
			return 11;
		case 'C':
			return 12;
		case 'D':
			return 13;
		case 'E':
			return 14;
		default:
			return 15;
	}
};
var $elm$core$Basics$pow = _Basics_pow;
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$hexStringToInt = function (string) {
	return A3(
		$elm$core$String$foldr,
		F2(
			function (c, soFar) {
				return {
					bo: soFar.bo + 1,
					bJ: soFar.bJ + (A2($elm$core$Basics$pow, 16, soFar.bo) * $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charToHex(c))
				};
			}),
		{bo: 0, bJ: 0},
		string).bJ;
};
var $lue_bird$elm_syntax_format$ParserFast$isSubCharWithoutLinebreak = F3(
	function (predicate, offset, string) {
		var actualChar = A3($elm$core$String$slice, offset, offset + 1, string);
		return A2($elm$core$String$any, predicate, actualChar) ? (offset + 1) : (($lue_bird$elm_syntax_format$ParserFast$charStringIsUtf16HighSurrogate(actualChar) && A2(
			$elm$core$String$any,
			predicate,
			A3($elm$core$String$slice, offset, offset + 2, string))) ? (offset + 2) : (-1));
	});
var $lue_bird$elm_syntax_format$ParserFast$skipWhileWithoutLinebreakHelp = F6(
	function (isGood, offset, row, col, src, indent) {
		skipWhileWithoutLinebreakHelp:
		while (true) {
			var actualChar = A3($elm$core$String$slice, offset, offset + 1, src);
			if (A2($elm$core$String$any, isGood, actualChar)) {
				var $temp$isGood = isGood,
					$temp$offset = offset + 1,
					$temp$row = row,
					$temp$col = col + 1,
					$temp$src = src,
					$temp$indent = indent;
				isGood = $temp$isGood;
				offset = $temp$offset;
				row = $temp$row;
				col = $temp$col;
				src = $temp$src;
				indent = $temp$indent;
				continue skipWhileWithoutLinebreakHelp;
			} else {
				if ($lue_bird$elm_syntax_format$ParserFast$charStringIsUtf16HighSurrogate(actualChar) && A2(
					$elm$core$String$any,
					isGood,
					A3($elm$core$String$slice, offset, offset + 2, src))) {
					var $temp$isGood = isGood,
						$temp$offset = offset + 2,
						$temp$row = row,
						$temp$col = col + 1,
						$temp$src = src,
						$temp$indent = indent;
					isGood = $temp$isGood;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileWithoutLinebreakHelp;
				} else {
					return {co: col, m: indent, i: offset, c9: row, g: src};
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithoutLinebreak = F3(
	function (consumedStringToRes, firstIsOkay, afterFirstIsOkay) {
		return function (s0) {
			var firstOffset = A3($lue_bird$elm_syntax_format$ParserFast$isSubCharWithoutLinebreak, firstIsOkay, s0.i, s0.g);
			if (_Utils_eq(firstOffset, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileWithoutLinebreakHelp, afterFirstIsOkay, firstOffset, s0.c9, s0.co + 1, s0.g, s0.m);
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					consumedStringToRes(
						A3($elm$core$String$slice, s0.i, s1.i, s0.g)),
					s1);
			}
		};
	});
var $elm$core$Char$isHexDigit = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return ((48 <= code) && (code <= 57)) || (((65 <= code) && (code <= 70)) || ((97 <= code) && (code <= 102)));
};
var $lue_bird$elm_syntax_format$ParserFast$oneOf7 = F7(
	function (_v0, _v1, _v2, _v3, _v4, _v5, _v6) {
		var attempt0 = _v0;
		var attempt1 = _v1;
		var attempt2 = _v2;
		var attempt3 = _v3;
		var attempt4 = _v4;
		var attempt5 = _v5;
		var attempt6 = _v6;
		return function (s) {
			var _v7 = attempt0(s);
			if (!_v7.$) {
				var good = _v7;
				return good;
			} else {
				var bad0 = _v7;
				var committed0 = bad0.a;
				if (committed0) {
					return bad0;
				} else {
					var _v8 = attempt1(s);
					if (!_v8.$) {
						var good = _v8;
						return good;
					} else {
						var bad1 = _v8;
						var committed1 = bad1.a;
						if (committed1) {
							return bad1;
						} else {
							var _v9 = attempt2(s);
							if (!_v9.$) {
								var good = _v9;
								return good;
							} else {
								var bad2 = _v9;
								var committed2 = bad2.a;
								if (committed2) {
									return bad2;
								} else {
									var _v10 = attempt3(s);
									if (!_v10.$) {
										var good = _v10;
										return good;
									} else {
										var bad3 = _v10;
										var committed3 = bad3.a;
										if (committed3) {
											return bad3;
										} else {
											var _v11 = attempt4(s);
											if (!_v11.$) {
												var good = _v11;
												return good;
											} else {
												var bad4 = _v11;
												var committed4 = bad4.a;
												if (committed4) {
													return bad4;
												} else {
													var _v12 = attempt5(s);
													if (!_v12.$) {
														var good = _v12;
														return good;
													} else {
														var bad5 = _v12;
														var committed5 = bad5.a;
														if (committed5) {
															return bad5;
														} else {
															var _v13 = attempt6(s);
															if (!_v13.$) {
																var good = _v13;
																return good;
															} else {
																var bad6 = _v13;
																var committed6 = bad6.a;
																return committed6 ? bad6 : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
															}
														}
													}
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$escapedCharValueMap = function (charToRes) {
	return A7(
		$lue_bird$elm_syntax_format$ParserFast$oneOf7,
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'\'',
			charToRes('\'')),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'\"',
			charToRes('\"')),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'n',
			charToRes('\n')),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			't',
			charToRes('\t')),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'r',
			charToRes('\u000D')),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'\\',
			charToRes('\\')),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'u{',
			A2(
				$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
				'}',
				A3(
					$lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithoutLinebreak,
					function (hex) {
						return charToRes(
							$elm$core$Char$fromCode(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$hexStringToInt(hex)));
					},
					$elm$core$Char$isHexDigit,
					$elm$core$Char$isHexDigit))));
};
var $lue_bird$elm_syntax_format$ParserFast$oneOf2MapWithStartRowColumnAndEndRowColumn = F4(
	function (firstToChoice, _v0, secondToChoice, _v1) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		return function (s) {
			var _v2 = attemptFirst(s);
			if (!_v2.$) {
				var first = _v2.a;
				var s1 = _v2.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A5(firstToChoice, s.c9, s.co, first, s1.c9, s1.co),
					s1);
			} else {
				var firstCommitted = _v2.a;
				var firstX = _v2.b;
				if (firstCommitted) {
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, firstCommitted, firstX);
				} else {
					var _v3 = attemptSecond(s);
					if (!_v3.$) {
						var second = _v3.a;
						var s1 = _v3.b;
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							A5(secondToChoice, s.c9, s.co, second, s1.c9, s1.co),
							s1);
					} else {
						var secondCommitted = _v3.a;
						var secondX = _v3.b;
						return secondCommitted ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, secondCommitted, secondX) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$characterLiteralMapWithRange = function (rangeAndCharToRes) {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'\'',
		A2(
			$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
			'\'',
			A4(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2MapWithStartRowColumnAndEndRowColumn,
				F5(
					function (startRow, startColumn, _char, endRow, endColumn) {
						return A2(
							rangeAndCharToRes,
							{
								cw: {cp: endColumn + 1, c9: endRow},
								b9: {cp: startColumn - 1, c9: startRow}
							},
							_char);
					}),
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
					'\\',
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$escapedCharValueMap($elm$core$Basics$identity)),
				F5(
					function (startRow, startColumn, _char, endRow, endColumn) {
						return A2(
							rangeAndCharToRes,
							{
								cw: {cp: endColumn + 1, c9: endRow},
								b9: {cp: startColumn - 1, c9: startRow}
							},
							_char);
					}),
				$lue_bird$elm_syntax_format$ParserFast$anyChar)));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charLiteralExpression = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$characterLiteralMapWithRange(
	F2(
		function (range, _char) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Expression$CharLiteral(_char))
			};
		}));
var $lue_bird$elm_syntax_format$ParserFast$map2 = F3(
	function (func, _v0, _v1) {
		var parseA = _v0;
		var parseB = _v1;
		return function (s0) {
			var _v2 = parseA(s0);
			if (_v2.$ === 1) {
				var committed = _v2.a;
				var x = _v2.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v2.a;
				var s1 = _v2.b;
				var _v3 = parseB(s1);
				if (_v3.$ === 1) {
					var x = _v3.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v3.a;
					var s2 = _v3.b;
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						A2(func, a, b),
						s2);
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RopeBranch2 = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo = F2(
	function (right, left) {
		if (left.$ === 1) {
			return right;
		} else {
			var leftLikelyFilled = left.a;
			if (right.$ === 1) {
				return left;
			} else {
				var rightLikelyFilled = right.a;
				return $elm$core$Maybe$Just(
					A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RopeBranch2, leftLikelyFilled, rightLikelyFilled));
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$skipWhileWhitespaceHelp = F5(
	function (offset, row, col, src, indent) {
		skipWhileWhitespaceHelp:
		while (true) {
			var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
			switch (_v0) {
				case ' ':
					var $temp$offset = offset + 1,
						$temp$row = row,
						$temp$col = col + 1,
						$temp$src = src,
						$temp$indent = indent;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileWhitespaceHelp;
				case '\n':
					var $temp$offset = offset + 1,
						$temp$row = row + 1,
						$temp$col = 1,
						$temp$src = src,
						$temp$indent = indent;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileWhitespaceHelp;
				case '\u000D':
					var $temp$offset = offset + 1,
						$temp$row = row,
						$temp$col = col + 1,
						$temp$src = src,
						$temp$indent = indent;
					offset = $temp$offset;
					row = $temp$row;
					col = $temp$col;
					src = $temp$src;
					indent = $temp$indent;
					continue skipWhileWhitespaceHelp;
				default:
					return {co: col, m: indent, i: offset, c9: row, g: src};
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$followedBySkipWhileWhitespace = function (_v0) {
	var parseBefore = _v0;
	return function (s0) {
		var _v1 = parseBefore(s0);
		if (!_v1.$) {
			var res = _v1.a;
			var s1 = _v1.b;
			return A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				res,
				A5($lue_bird$elm_syntax_format$ParserFast$skipWhileWhitespaceHelp, s1.i, s1.c9, s1.co, s1.g, s1.m));
		} else {
			var bad = _v1;
			return bad;
		}
	};
};
var $lue_bird$elm_syntax_format$ParserFast$map2OrSucceed = F4(
	function (func, _v0, _v1, fallback) {
		var parseA = _v0;
		var parseB = _v1;
		return function (s0) {
			var _v2 = parseA(s0);
			if (_v2.$ === 1) {
				var c1 = _v2.a;
				var x = _v2.b;
				return c1 ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x) : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallback, s0);
			} else {
				var a = _v2.a;
				var s1 = _v2.b;
				var _v3 = parseB(s1);
				if (_v3.$ === 1) {
					var x = _v3.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v3.a;
					var s2 = _v3.b;
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						A2(func, a, b),
						s2);
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$multiLineCommentNoCheck = A3(
	$lue_bird$elm_syntax_format$ParserFast$nestableMultiCommentMapWithRange,
	$stil4m$elm_syntax$Elm$Syntax$Node$Node,
	_Utils_Tuple2('{', '-'),
	_Utils_Tuple2('-', '}'));
var $lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThen = function (callback) {
	return function (s) {
		var _v0 = A2(callback, s.i, s.g);
		var parse = _v0;
		return parse(s);
	};
};
var $lue_bird$elm_syntax_format$ParserFast$problem = function (_v0) {
	return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$multiLineComment = $lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThen(
	F2(
		function (offset, source) {
			var _v0 = A3($elm$core$String$slice, offset + 2, offset + 3, source);
			if (_v0 === '|') {
				return $lue_bird$elm_syntax_format$ParserFast$problem;
			} else {
				return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$multiLineCommentNoCheck;
			}
		}));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeFilledPrependTo = F2(
	function (right, leftLikelyFilled) {
		return $elm$core$Maybe$Just(
			function () {
				if (right.$ === 1) {
					return leftLikelyFilled;
				} else {
					var rightLikelyFilled = right.a;
					return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RopeBranch2, leftLikelyFilled, rightLikelyFilled);
				}
			}());
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RopeLeaf = F2(
	function (a, b) {
		return {$: 0, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeOne = function (onlyElement) {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RopeLeaf, onlyElement, 0);
};
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsHelp = F5(
	function (element, soFar, reduce, foldedToRes, s0) {
		loopWhileSucceedsHelp:
		while (true) {
			var parseElement = element;
			var _v0 = parseElement(s0);
			if (!_v0.$) {
				var elementResult = _v0.a;
				var s1 = _v0.b;
				var $temp$element = element,
					$temp$soFar = A2(reduce, elementResult, soFar),
					$temp$reduce = reduce,
					$temp$foldedToRes = foldedToRes,
					$temp$s0 = s1;
				element = $temp$element;
				soFar = $temp$soFar;
				reduce = $temp$reduce;
				foldedToRes = $temp$foldedToRes;
				s0 = $temp$s0;
				continue loopWhileSucceedsHelp;
			} else {
				var elementCommitted = _v0.a;
				var x = _v0.b;
				return elementCommitted ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x) : A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					foldedToRes(soFar),
					s0);
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceeds = F4(
	function (element, initialFolded, reduce, foldedToRes) {
		return function (s) {
			return A5($lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsHelp, element, initialFolded, reduce, foldedToRes, s);
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependToFilled = F2(
	function (rightLikelyFilled, left) {
		return $elm$core$Maybe$Just(
			function () {
				if (left.$ === 1) {
					return rightLikelyFilled;
				} else {
					var leftLikelyFilled = left.a;
					return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RopeBranch2, leftLikelyFilled, rightLikelyFilled);
				}
			}());
	});
var $lue_bird$elm_syntax_format$ParserFast$whileMapWithRange = F2(
	function (isGood, rangeAndConsumedStringToRes) {
		return function (s0) {
			var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileHelp, isGood, s0.i, s0.c9, s0.co, s0.g, s0.m);
			return A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				A2(
					rangeAndConsumedStringToRes,
					{
						cw: {cp: s1.co, c9: s1.c9},
						b9: {cp: s0.co, c9: s0.c9}
					},
					A3($elm$core$String$slice, s0.i, s1.i, s0.g)),
				s1);
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleLineComment = A2(
	$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
	'--',
	A2(
		$lue_bird$elm_syntax_format$ParserFast$whileMapWithRange,
		function (c) {
			return (c !== '\u000D') && ((c !== '\n') && (!$lue_bird$elm_syntax_format$Char$Extra$isUtf16Surrogate(c)));
		},
		F2(
			function (range, content) {
				return A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					{
						cw: {cp: range.cw.cp, c9: range.b9.c9},
						b9: {cp: range.b9.cp - 2, c9: range.b9.c9}
					},
					'--' + content);
			})));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsOrEmptyLoop = A4(
	$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceeds,
	$lue_bird$elm_syntax_format$ParserFast$followedBySkipWhileWhitespace(
		A2($lue_bird$elm_syntax_format$ParserFast$oneOf2, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleLineComment, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$multiLineComment)),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
	F2(
		function (right, soFar) {
			return A2(
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependToFilled,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeOne(right),
				soFar);
		}),
	$elm$core$Basics$identity);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$fromMultilineCommentNodeOrEmptyOnProblem = A4(
	$lue_bird$elm_syntax_format$ParserFast$map2OrSucceed,
	F2(
		function (comment, commentsAfter) {
			return A2(
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeFilledPrependTo,
				commentsAfter,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeOne(comment));
		}),
	$lue_bird$elm_syntax_format$ParserFast$followedBySkipWhileWhitespace($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$multiLineComment),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsOrEmptyLoop,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$fromSingleLineCommentNode = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2,
	F2(
		function (content, commentsAfter) {
			return A2(
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeFilledPrependTo,
				commentsAfter,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeOne(content));
		}),
	$lue_bird$elm_syntax_format$ParserFast$followedBySkipWhileWhitespace($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleLineComment),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsOrEmptyLoop);
var $lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThenOrSucceed = F2(
	function (callback, fallback) {
		return function (s) {
			var _v0 = A2(callback, s.i, s.g);
			if (_v0.$ === 1) {
				return A2($lue_bird$elm_syntax_format$ParserFast$Good, fallback, s);
			} else {
				var parse = _v0.a;
				return parse(s);
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$skipWhileWhitespaceBacktrackableFollowedBy = function (_v0) {
	var parseNext = _v0;
	return function (s0) {
		return parseNext(
			A5($lue_bird$elm_syntax_format$ParserFast$skipWhileWhitespaceHelp, s0.i, s0.c9, s0.co, s0.g, s0.m));
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments = $lue_bird$elm_syntax_format$ParserFast$skipWhileWhitespaceBacktrackableFollowedBy(
	A2(
		$lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThenOrSucceed,
		F2(
			function (offset, source) {
				var _v0 = A3($elm$core$String$slice, offset, offset + 2, source);
				switch (_v0) {
					case '--':
						return $elm$core$Maybe$Just($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$fromSingleLineCommentNode);
					case '{-':
						return $elm$core$Maybe$Just($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$fromMultilineCommentNodeOrEmptyOnProblem);
					default:
						return $elm$core$Maybe$Nothing;
				}
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByOptimisticLayout = function (parser) {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (result, commentsAfter) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, result.b),
					a: result.a
				};
			}),
		parser,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments);
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charLiteralExpressionOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByOptimisticLayout($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charLiteralExpression);
var $stil4m$elm_syntax$Elm$Syntax$Expression$RecordAccess = F2(
	function (a, b) {
		return {$: 20, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsOntoResultFromParser = F4(
	function (element, _v0, reduce, foldedToRes) {
		var parseInitialFolded = _v0;
		return function (s0) {
			var _v1 = parseInitialFolded(s0);
			if (!_v1.$) {
				var initialFolded = _v1.a;
				var s1 = _v1.b;
				return A5($lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsHelp, element, initialFolded, reduce, foldedToRes, s1);
			} else {
				var committed = _v1.a;
				var x = _v1.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithRangeWithoutLinebreak = F3(
	function (rangeAndConsumedStringToRes, firstIsOkay, afterFirstIsOkay) {
		return function (s0) {
			var firstOffset = A3($lue_bird$elm_syntax_format$ParserFast$isSubCharWithoutLinebreak, firstIsOkay, s0.i, s0.g);
			if (_Utils_eq(firstOffset, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileWithoutLinebreakHelp, afterFirstIsOkay, firstOffset, s0.c9, s0.co + 1, s0.g, s0.m);
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A2(
						rangeAndConsumedStringToRes,
						{
							cw: {cp: s1.co, c9: s1.c9},
							b9: {cp: s0.co, c9: s0.c9}
						},
						A3($elm$core$String$slice, s0.i, s1.i, s0.g)),
					s1);
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifKeywordUnderscoreSuffix = function (name) {
	switch (name) {
		case 'module':
			return 'module_';
		case 'exposing':
			return 'exposing_';
		case 'import':
			return 'import_';
		case 'as':
			return 'as_';
		case 'if':
			return 'if_';
		case 'then':
			return 'then_';
		case 'else':
			return 'else_';
		case 'let':
			return 'let_';
		case 'in':
			return 'in_';
		case 'case':
			return 'case_';
		case 'of':
			return 'of_';
		case 'port':
			return 'port_';
		case 'type':
			return 'type_';
		case 'where':
			return 'where_';
		default:
			return name;
	}
};
var $lue_bird$elm_syntax_format$Char$Extra$charCodeIsDigit = function (code) {
	return (code <= 57) && (48 <= code);
};
var $lue_bird$elm_syntax_format$Char$Extra$charCodeIsLower = function (code) {
	return (97 <= code) && (code <= 122);
};
var $lue_bird$elm_syntax_format$Char$Extra$charCodeIsUpper = function (code) {
	return (code <= 90) && (65 <= code);
};
var $elm$core$Basics$modBy = _Basics_modBy;
var $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast = function (c) {
	var code = $elm$core$Char$toCode(c);
	return $lue_bird$elm_syntax_format$Char$Extra$charCodeIsLower(code) || ($lue_bird$elm_syntax_format$Char$Extra$charCodeIsUpper(code) || ($lue_bird$elm_syntax_format$Char$Extra$charCodeIsDigit(code) || ((code === 95) || (((code !== 32) && (code !== 10)) && ((code < 256) ? (((48 <= code) && (code <= 57)) || (((65 <= code) && (code <= 90)) || (((97 <= code) && (code <= 122)) || ((code === 170) || (((178 <= code) && (code <= 179)) || ((code === 181) || (((185 <= code) && (code <= 186)) || (((188 <= code) && (code <= 190)) || (((192 <= code) && (code <= 214)) || (((216 <= code) && (code <= 246)) || ((248 <= code) && (code <= 255)))))))))))) : ((code < 43700) ? ((code < 4347) ? ((code < 2868) ? ((code < 2364) ? ((code < 1648) ? ((code < 930) ? (((256 <= code) && (code <= 705)) || (((710 <= code) && (code <= 721)) || (((736 <= code) && (code <= 740)) || (((880 <= code) && (code <= 884)) || (((886 <= code) && (code <= 887)) || (((890 <= code) && (code <= 893)) || ((code === 895) || ((code === 902) || (((904 <= code) && (code <= 906)) || ((code === 908) || (((910 <= code) && (code <= 929)) || ((!A2($elm$core$Basics$modBy, 2, code)) && ((748 <= code) && (code <= 750)))))))))))))) : (((931 <= code) && (code <= 1013)) || (((1015 <= code) && (code <= 1153)) || (((1162 <= code) && (code <= 1327)) || (((1329 <= code) && (code <= 1366)) || ((code === 1369) || (((1376 <= code) && (code <= 1416)) || (((1488 <= code) && (code <= 1514)) || (((1519 <= code) && (code <= 1522)) || (((1568 <= code) && (code <= 1610)) || (((1632 <= code) && (code <= 1641)) || ((1646 <= code) && (code <= 1647))))))))))))) : ((code < 2041) ? (((1649 <= code) && (code <= 1747)) || ((code === 1749) || (((1765 <= code) && (code <= 1766)) || (((1774 <= code) && (code <= 1788)) || ((code === 1791) || ((code === 1808) || (((1810 <= code) && (code <= 1839)) || (((1869 <= code) && (code <= 1957)) || ((code === 1969) || (((1984 <= code) && (code <= 2026)) || ((2036 <= code) && (code <= 2037)))))))))))) : ((code === 2042) || (((2048 <= code) && (code <= 2069)) || ((code === 2074) || ((code === 2084) || ((code === 2088) || (((2112 <= code) && (code <= 2136)) || (((2144 <= code) && (code <= 2154)) || (((2160 <= code) && (code <= 2183)) || (((2185 <= code) && (code <= 2190)) || (((2208 <= code) && (code <= 2249)) || ((2308 <= code) && (code <= 2361)))))))))))))) : ((code < 2609) ? ((code < 2492) ? ((code === 2365) || ((code === 2384) || (((2392 <= code) && (code <= 2401)) || (((2406 <= code) && (code <= 2415)) || (((2417 <= code) && (code <= 2432)) || (((2437 <= code) && (code <= 2444)) || (((2447 <= code) && (code <= 2448)) || (((2451 <= code) && (code <= 2472)) || (((2474 <= code) && (code <= 2480)) || ((code === 2482) || ((2486 <= code) && (code <= 2489)))))))))))) : ((code === 2493) || ((code === 2510) || (((2524 <= code) && (code <= 2525)) || (((2527 <= code) && (code <= 2529)) || (((2534 <= code) && (code <= 2545)) || (((2548 <= code) && (code <= 2553)) || ((code === 2556) || (((2565 <= code) && (code <= 2570)) || (((2575 <= code) && (code <= 2576)) || (((2579 <= code) && (code <= 2600)) || ((2602 <= code) && (code <= 2608))))))))))))) : ((code < 2737) ? (((2610 <= code) && (code <= 2611)) || (((2613 <= code) && (code <= 2614)) || (((2616 <= code) && (code <= 2617)) || (((2649 <= code) && (code <= 2652)) || ((code === 2654) || (((2662 <= code) && (code <= 2671)) || (((2674 <= code) && (code <= 2676)) || (((2693 <= code) && (code <= 2701)) || (((2703 <= code) && (code <= 2705)) || (((2707 <= code) && (code <= 2728)) || ((2730 <= code) && (code <= 2736)))))))))))) : (((2738 <= code) && (code <= 2739)) || (((2741 <= code) && (code <= 2745)) || ((code === 2749) || ((code === 2768) || (((2784 <= code) && (code <= 2785)) || (((2790 <= code) && (code <= 2799)) || ((code === 2809) || (((2821 <= code) && (code <= 2828)) || (((2831 <= code) && (code <= 2832)) || (((2835 <= code) && (code <= 2856)) || (((2858 <= code) && (code <= 2864)) || ((2866 <= code) && (code <= 2867)))))))))))))))) : ((code < 3411) ? ((code < 3132) ? ((code < 2971) ? (((2869 <= code) && (code <= 2873)) || ((code === 2877) || (((2908 <= code) && (code <= 2909)) || (((2911 <= code) && (code <= 2913)) || (((2918 <= code) && (code <= 2927)) || (((2929 <= code) && (code <= 2935)) || ((code === 2947) || (((2949 <= code) && (code <= 2954)) || (((2958 <= code) && (code <= 2960)) || (((2962 <= code) && (code <= 2965)) || ((2969 <= code) && (code <= 2970)))))))))))) : ((code === 2972) || (((2974 <= code) && (code <= 2975)) || (((2979 <= code) && (code <= 2980)) || (((2984 <= code) && (code <= 2986)) || (((2990 <= code) && (code <= 3001)) || ((code === 3024) || (((3046 <= code) && (code <= 3058)) || (((3077 <= code) && (code <= 3084)) || (((3086 <= code) && (code <= 3088)) || (((3090 <= code) && (code <= 3112)) || ((3114 <= code) && (code <= 3129))))))))))))) : ((code < 3252) ? ((code === 3133) || (((3160 <= code) && (code <= 3162)) || ((code === 3165) || (((3168 <= code) && (code <= 3169)) || (((3174 <= code) && (code <= 3183)) || (((3192 <= code) && (code <= 3198)) || ((code === 3200) || (((3205 <= code) && (code <= 3212)) || (((3214 <= code) && (code <= 3216)) || (((3218 <= code) && (code <= 3240)) || ((3242 <= code) && (code <= 3251)))))))))))) : (((3253 <= code) && (code <= 3257)) || ((code === 3261) || (((3293 <= code) && (code <= 3294)) || (((3296 <= code) && (code <= 3297)) || (((3302 <= code) && (code <= 3311)) || (((3313 <= code) && (code <= 3314)) || (((3332 <= code) && (code <= 3340)) || (((3342 <= code) && (code <= 3344)) || (((3346 <= code) && (code <= 3386)) || ((code === 3389) || (code === 3406))))))))))))) : ((code < 3775) ? ((code < 3633) ? (((3412 <= code) && (code <= 3414)) || (((3416 <= code) && (code <= 3425)) || (((3430 <= code) && (code <= 3448)) || (((3450 <= code) && (code <= 3455)) || (((3461 <= code) && (code <= 3478)) || (((3482 <= code) && (code <= 3505)) || (((3507 <= code) && (code <= 3515)) || ((code === 3517) || (((3520 <= code) && (code <= 3526)) || (((3558 <= code) && (code <= 3567)) || ((3585 <= code) && (code <= 3632)))))))))))) : (((3634 <= code) && (code <= 3635)) || (((3648 <= code) && (code <= 3654)) || (((3664 <= code) && (code <= 3673)) || (((3713 <= code) && (code <= 3714)) || ((code === 3716) || (((3718 <= code) && (code <= 3722)) || (((3724 <= code) && (code <= 3747)) || ((code === 3749) || (((3751 <= code) && (code <= 3760)) || (((3762 <= code) && (code <= 3763)) || (code === 3773)))))))))))) : ((code < 4175) ? (((3776 <= code) && (code <= 3780)) || ((code === 3782) || (((3792 <= code) && (code <= 3801)) || (((3804 <= code) && (code <= 3807)) || ((code === 3840) || (((3872 <= code) && (code <= 3891)) || (((3904 <= code) && (code <= 3911)) || (((3913 <= code) && (code <= 3948)) || (((3976 <= code) && (code <= 3980)) || (((4096 <= code) && (code <= 4138)) || ((4159 <= code) && (code <= 4169)))))))))))) : (((4176 <= code) && (code <= 4181)) || (((4186 <= code) && (code <= 4189)) || ((code === 4193) || (((4197 <= code) && (code <= 4198)) || (((4206 <= code) && (code <= 4208)) || (((4213 <= code) && (code <= 4225)) || ((code === 4238) || (((4240 <= code) && (code <= 4249)) || (((4256 <= code) && (code <= 4293)) || ((code === 4295) || ((code === 4301) || ((4304 <= code) && (code <= 4346))))))))))))))))) : ((code < 8454) ? ((code < 6527) ? ((code < 5760) ? ((code < 4801) ? (((4348 <= code) && (code <= 4680)) || (((4682 <= code) && (code <= 4685)) || (((4688 <= code) && (code <= 4694)) || ((code === 4696) || (((4698 <= code) && (code <= 4701)) || (((4704 <= code) && (code <= 4744)) || (((4746 <= code) && (code <= 4749)) || (((4752 <= code) && (code <= 4784)) || (((4786 <= code) && (code <= 4789)) || (((4792 <= code) && (code <= 4798)) || (code === 4800))))))))))) : (((4802 <= code) && (code <= 4805)) || (((4808 <= code) && (code <= 4822)) || (((4824 <= code) && (code <= 4880)) || (((4882 <= code) && (code <= 4885)) || (((4888 <= code) && (code <= 4954)) || (((4969 <= code) && (code <= 4988)) || (((4992 <= code) && (code <= 5007)) || (((5024 <= code) && (code <= 5109)) || (((5112 <= code) && (code <= 5117)) || (((5121 <= code) && (code <= 5740)) || ((5743 <= code) && (code <= 5759))))))))))))) : ((code < 6111) ? (((5761 <= code) && (code <= 5786)) || (((5792 <= code) && (code <= 5866)) || (((5870 <= code) && (code <= 5880)) || (((5888 <= code) && (code <= 5905)) || (((5919 <= code) && (code <= 5937)) || (((5952 <= code) && (code <= 5969)) || (((5984 <= code) && (code <= 5996)) || (((5998 <= code) && (code <= 6000)) || (((6016 <= code) && (code <= 6067)) || ((code === 6103) || (code === 6108))))))))))) : (((6112 <= code) && (code <= 6121)) || (((6128 <= code) && (code <= 6137)) || (((6160 <= code) && (code <= 6169)) || (((6176 <= code) && (code <= 6264)) || (((6272 <= code) && (code <= 6276)) || (((6279 <= code) && (code <= 6312)) || ((code === 6314) || (((6320 <= code) && (code <= 6389)) || (((6400 <= code) && (code <= 6430)) || (((6470 <= code) && (code <= 6509)) || ((6512 <= code) && (code <= 6516)))))))))))))) : ((code < 7417) ? ((code < 7042) ? (((6528 <= code) && (code <= 6571)) || (((6576 <= code) && (code <= 6601)) || (((6608 <= code) && (code <= 6618)) || (((6656 <= code) && (code <= 6678)) || (((6688 <= code) && (code <= 6740)) || (((6784 <= code) && (code <= 6793)) || (((6800 <= code) && (code <= 6809)) || ((code === 6823) || (((6917 <= code) && (code <= 6963)) || (((6981 <= code) && (code <= 6988)) || ((6992 <= code) && (code <= 7001)))))))))))) : (((7043 <= code) && (code <= 7072)) || (((7086 <= code) && (code <= 7141)) || (((7168 <= code) && (code <= 7203)) || (((7232 <= code) && (code <= 7241)) || (((7245 <= code) && (code <= 7293)) || (((7296 <= code) && (code <= 7304)) || (((7312 <= code) && (code <= 7354)) || (((7357 <= code) && (code <= 7359)) || (((7401 <= code) && (code <= 7404)) || (((7406 <= code) && (code <= 7411)) || ((7413 <= code) && (code <= 7414))))))))))))) : ((code < 8129) ? ((code === 7418) || (((7424 <= code) && (code <= 7615)) || (((7680 <= code) && (code <= 7957)) || (((7960 <= code) && (code <= 7965)) || (((7968 <= code) && (code <= 8005)) || (((8008 <= code) && (code <= 8013)) || (((8016 <= code) && (code <= 8023)) || (((8032 <= code) && (code <= 8061)) || (((8064 <= code) && (code <= 8116)) || (((8118 <= code) && (code <= 8124)) || ((code === 8126) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && ((8025 <= code) && (code <= 8031)))))))))))))) : (((8130 <= code) && (code <= 8132)) || (((8134 <= code) && (code <= 8140)) || (((8144 <= code) && (code <= 8147)) || (((8150 <= code) && (code <= 8155)) || (((8160 <= code) && (code <= 8172)) || (((8178 <= code) && (code <= 8180)) || (((8182 <= code) && (code <= 8188)) || (((8304 <= code) && (code <= 8305)) || (((8308 <= code) && (code <= 8313)) || (((8319 <= code) && (code <= 8329)) || (((8336 <= code) && (code <= 8348)) || (code === 8450))))))))))))))) : ((code < 12783) ? ((code < 11647) ? ((code < 9449) ? ((code === 8455) || (((8458 <= code) && (code <= 8467)) || ((code === 8469) || (((8473 <= code) && (code <= 8477)) || (((8490 <= code) && (code <= 8493)) || (((8495 <= code) && (code <= 8505)) || (((8508 <= code) && (code <= 8511)) || (((8517 <= code) && (code <= 8521)) || ((code === 8526) || (((8528 <= code) && (code <= 8585)) || (((9312 <= code) && (code <= 9371)) || ((!A2($elm$core$Basics$modBy, 2, code)) && ((8484 <= code) && (code <= 8488)))))))))))))) : (((9450 <= code) && (code <= 9471)) || (((10102 <= code) && (code <= 10131)) || (((11264 <= code) && (code <= 11492)) || (((11499 <= code) && (code <= 11502)) || (((11506 <= code) && (code <= 11507)) || ((code === 11517) || (((11520 <= code) && (code <= 11557)) || ((code === 11559) || ((code === 11565) || (((11568 <= code) && (code <= 11623)) || (code === 11631)))))))))))) : ((code < 12320) ? (((11648 <= code) && (code <= 11670)) || (((11680 <= code) && (code <= 11686)) || (((11688 <= code) && (code <= 11694)) || (((11696 <= code) && (code <= 11702)) || (((11704 <= code) && (code <= 11710)) || (((11712 <= code) && (code <= 11718)) || (((11720 <= code) && (code <= 11726)) || (((11728 <= code) && (code <= 11734)) || (((11736 <= code) && (code <= 11742)) || ((code === 11823) || ((12293 <= code) && (code <= 12295)))))))))))) : (((12321 <= code) && (code <= 12329)) || (((12337 <= code) && (code <= 12341)) || (((12344 <= code) && (code <= 12348)) || (((12353 <= code) && (code <= 12438)) || (((12445 <= code) && (code <= 12447)) || (((12449 <= code) && (code <= 12538)) || (((12540 <= code) && (code <= 12543)) || (((12549 <= code) && (code <= 12591)) || (((12593 <= code) && (code <= 12686)) || (((12690 <= code) && (code <= 12693)) || ((12704 <= code) && (code <= 12735)))))))))))))) : ((code < 43019) ? ((code < 42559) ? (((12784 <= code) && (code <= 12799)) || (((12832 <= code) && (code <= 12841)) || (((12872 <= code) && (code <= 12879)) || (((12881 <= code) && (code <= 12895)) || (((12928 <= code) && (code <= 12937)) || (((12977 <= code) && (code <= 12991)) || (((13312 <= code) && (code <= 19903)) || (((19968 <= code) && (code <= 42124)) || (((42192 <= code) && (code <= 42237)) || (((42240 <= code) && (code <= 42508)) || ((42512 <= code) && (code <= 42539)))))))))))) : (((42560 <= code) && (code <= 42606)) || (((42623 <= code) && (code <= 42653)) || (((42656 <= code) && (code <= 42735)) || (((42775 <= code) && (code <= 42783)) || (((42786 <= code) && (code <= 42888)) || (((42891 <= code) && (code <= 42954)) || (((42960 <= code) && (code <= 42961)) || (((42966 <= code) && (code <= 42969)) || (((42994 <= code) && (code <= 43009)) || (((43011 <= code) && (code <= 43013)) || (((43015 <= code) && (code <= 43018)) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && ((42963 <= code) && (code <= 42965))))))))))))))) : ((code < 43395) ? (((43020 <= code) && (code <= 43042)) || (((43056 <= code) && (code <= 43061)) || (((43072 <= code) && (code <= 43123)) || (((43138 <= code) && (code <= 43187)) || (((43216 <= code) && (code <= 43225)) || (((43250 <= code) && (code <= 43255)) || ((code === 43259) || (((43261 <= code) && (code <= 43262)) || (((43264 <= code) && (code <= 43301)) || (((43312 <= code) && (code <= 43334)) || ((43360 <= code) && (code <= 43388)))))))))))) : (((43396 <= code) && (code <= 43442)) || (((43471 <= code) && (code <= 43481)) || (((43488 <= code) && (code <= 43492)) || (((43494 <= code) && (code <= 43518)) || (((43520 <= code) && (code <= 43560)) || (((43584 <= code) && (code <= 43586)) || (((43588 <= code) && (code <= 43595)) || (((43600 <= code) && (code <= 43609)) || (((43616 <= code) && (code <= 43638)) || ((code === 43642) || (((43646 <= code) && (code <= 43695)) || (code === 43697))))))))))))))))) : ((code < 71351) ? ((code < 67671) ? ((code < 65548) ? ((code < 64286) ? ((code < 43867) ? (((43701 <= code) && (code <= 43702)) || (((43705 <= code) && (code <= 43709)) || (((43739 <= code) && (code <= 43741)) || (((43744 <= code) && (code <= 43754)) || (((43762 <= code) && (code <= 43764)) || (((43777 <= code) && (code <= 43782)) || (((43785 <= code) && (code <= 43790)) || (((43793 <= code) && (code <= 43798)) || (((43808 <= code) && (code <= 43814)) || (((43816 <= code) && (code <= 43822)) || (((43824 <= code) && (code <= 43866)) || ((!A2($elm$core$Basics$modBy, 2, code)) && ((43712 <= code) && (code <= 43714)))))))))))))) : (((43868 <= code) && (code <= 43881)) || (((43888 <= code) && (code <= 44002)) || (((44016 <= code) && (code <= 44025)) || (((44032 <= code) && (code <= 55203)) || (((55216 <= code) && (code <= 55238)) || (((55243 <= code) && (code <= 55291)) || (((63744 <= code) && (code <= 64109)) || (((64112 <= code) && (code <= 64217)) || (((64256 <= code) && (code <= 64262)) || (((64275 <= code) && (code <= 64279)) || (code === 64285)))))))))))) : ((code < 65135) ? (((64287 <= code) && (code <= 64296)) || (((64298 <= code) && (code <= 64310)) || (((64312 <= code) && (code <= 64316)) || ((code === 64318) || (((64320 <= code) && (code <= 64321)) || (((64323 <= code) && (code <= 64324)) || (((64326 <= code) && (code <= 64433)) || (((64467 <= code) && (code <= 64829)) || (((64848 <= code) && (code <= 64911)) || (((64914 <= code) && (code <= 64967)) || ((65008 <= code) && (code <= 65019)))))))))))) : (((65136 <= code) && (code <= 65140)) || (((65142 <= code) && (code <= 65276)) || (((65296 <= code) && (code <= 65305)) || (((65313 <= code) && (code <= 65338)) || (((65345 <= code) && (code <= 65370)) || (((65382 <= code) && (code <= 65470)) || (((65474 <= code) && (code <= 65479)) || (((65482 <= code) && (code <= 65487)) || (((65490 <= code) && (code <= 65495)) || (((65498 <= code) && (code <= 65500)) || ((65536 <= code) && (code <= 65547)))))))))))))) : ((code < 66775) ? ((code < 66272) ? (((65549 <= code) && (code <= 65574)) || (((65576 <= code) && (code <= 65594)) || (((65596 <= code) && (code <= 65597)) || (((65599 <= code) && (code <= 65613)) || (((65616 <= code) && (code <= 65629)) || (((65664 <= code) && (code <= 65786)) || (((65799 <= code) && (code <= 65843)) || (((65856 <= code) && (code <= 65912)) || (((65930 <= code) && (code <= 65931)) || (((66176 <= code) && (code <= 66204)) || ((66208 <= code) && (code <= 66256)))))))))))) : (((66273 <= code) && (code <= 66299)) || (((66304 <= code) && (code <= 66339)) || (((66349 <= code) && (code <= 66378)) || (((66384 <= code) && (code <= 66421)) || (((66432 <= code) && (code <= 66461)) || (((66464 <= code) && (code <= 66499)) || (((66504 <= code) && (code <= 66511)) || (((66513 <= code) && (code <= 66517)) || (((66560 <= code) && (code <= 66717)) || (((66720 <= code) && (code <= 66729)) || ((66736 <= code) && (code <= 66771))))))))))))) : ((code < 67071) ? (((66776 <= code) && (code <= 66811)) || (((66816 <= code) && (code <= 66855)) || (((66864 <= code) && (code <= 66915)) || (((66928 <= code) && (code <= 66938)) || (((66940 <= code) && (code <= 66954)) || (((66956 <= code) && (code <= 66962)) || (((66964 <= code) && (code <= 66965)) || (((66967 <= code) && (code <= 66977)) || (((66979 <= code) && (code <= 66993)) || (((66995 <= code) && (code <= 67001)) || ((67003 <= code) && (code <= 67004)))))))))))) : (((67072 <= code) && (code <= 67382)) || (((67392 <= code) && (code <= 67413)) || (((67424 <= code) && (code <= 67431)) || (((67456 <= code) && (code <= 67461)) || (((67463 <= code) && (code <= 67504)) || (((67506 <= code) && (code <= 67514)) || (((67584 <= code) && (code <= 67589)) || ((code === 67592) || (((67594 <= code) && (code <= 67637)) || (((67639 <= code) && (code <= 67640)) || ((code === 67644) || ((67647 <= code) && (code <= 67669)))))))))))))))) : ((code < 69871) ? ((code < 68471) ? ((code < 68116) ? (((67672 <= code) && (code <= 67702)) || (((67705 <= code) && (code <= 67742)) || (((67751 <= code) && (code <= 67759)) || (((67808 <= code) && (code <= 67826)) || (((67828 <= code) && (code <= 67829)) || (((67835 <= code) && (code <= 67867)) || (((67872 <= code) && (code <= 67897)) || (((67968 <= code) && (code <= 68023)) || (((68028 <= code) && (code <= 68047)) || (((68050 <= code) && (code <= 68096)) || ((68112 <= code) && (code <= 68115)))))))))))) : (((68117 <= code) && (code <= 68119)) || (((68121 <= code) && (code <= 68149)) || (((68160 <= code) && (code <= 68168)) || (((68192 <= code) && (code <= 68222)) || (((68224 <= code) && (code <= 68255)) || (((68288 <= code) && (code <= 68295)) || (((68297 <= code) && (code <= 68324)) || (((68331 <= code) && (code <= 68335)) || (((68352 <= code) && (code <= 68405)) || (((68416 <= code) && (code <= 68437)) || ((68440 <= code) && (code <= 68466))))))))))))) : ((code < 69423) ? (((68472 <= code) && (code <= 68497)) || (((68521 <= code) && (code <= 68527)) || (((68608 <= code) && (code <= 68680)) || (((68736 <= code) && (code <= 68786)) || (((68800 <= code) && (code <= 68850)) || (((68858 <= code) && (code <= 68899)) || (((68912 <= code) && (code <= 68921)) || (((69216 <= code) && (code <= 69246)) || (((69248 <= code) && (code <= 69289)) || (((69296 <= code) && (code <= 69297)) || ((69376 <= code) && (code <= 69415)))))))))))) : (((69424 <= code) && (code <= 69445)) || (((69457 <= code) && (code <= 69460)) || (((69488 <= code) && (code <= 69505)) || (((69552 <= code) && (code <= 69579)) || (((69600 <= code) && (code <= 69622)) || (((69635 <= code) && (code <= 69687)) || (((69714 <= code) && (code <= 69743)) || (((69745 <= code) && (code <= 69746)) || ((code === 69749) || (((69763 <= code) && (code <= 69807)) || ((69840 <= code) && (code <= 69864)))))))))))))) : ((code < 70404) ? ((code < 70112) ? (((69872 <= code) && (code <= 69881)) || (((69891 <= code) && (code <= 69926)) || (((69942 <= code) && (code <= 69951)) || ((code === 69956) || ((code === 69959) || (((69968 <= code) && (code <= 70002)) || ((code === 70006) || (((70019 <= code) && (code <= 70066)) || (((70081 <= code) && (code <= 70084)) || (((70096 <= code) && (code <= 70106)) || (code === 70108))))))))))) : (((70113 <= code) && (code <= 70132)) || (((70144 <= code) && (code <= 70161)) || (((70163 <= code) && (code <= 70187)) || (((70207 <= code) && (code <= 70208)) || (((70272 <= code) && (code <= 70278)) || ((code === 70280) || (((70282 <= code) && (code <= 70285)) || (((70287 <= code) && (code <= 70301)) || (((70303 <= code) && (code <= 70312)) || (((70320 <= code) && (code <= 70366)) || ((70384 <= code) && (code <= 70393))))))))))))) : ((code < 70735) ? (((70405 <= code) && (code <= 70412)) || (((70415 <= code) && (code <= 70416)) || (((70419 <= code) && (code <= 70440)) || (((70442 <= code) && (code <= 70448)) || (((70450 <= code) && (code <= 70451)) || (((70453 <= code) && (code <= 70457)) || ((code === 70461) || ((code === 70480) || (((70493 <= code) && (code <= 70497)) || (((70656 <= code) && (code <= 70708)) || ((70727 <= code) && (code <= 70730)))))))))))) : (((70736 <= code) && (code <= 70745)) || (((70751 <= code) && (code <= 70753)) || (((70784 <= code) && (code <= 70831)) || (((70852 <= code) && (code <= 70853)) || ((code === 70855) || (((70864 <= code) && (code <= 70873)) || (((71040 <= code) && (code <= 71086)) || (((71128 <= code) && (code <= 71131)) || (((71168 <= code) && (code <= 71215)) || ((code === 71236) || (((71248 <= code) && (code <= 71257)) || ((71296 <= code) && (code <= 71338))))))))))))))))) : ((code < 119893) ? ((code < 73727) ? ((code < 72703) ? ((code < 71959) ? ((code === 71352) || (((71360 <= code) && (code <= 71369)) || (((71424 <= code) && (code <= 71450)) || (((71472 <= code) && (code <= 71483)) || (((71488 <= code) && (code <= 71494)) || (((71680 <= code) && (code <= 71723)) || (((71840 <= code) && (code <= 71922)) || (((71935 <= code) && (code <= 71942)) || ((code === 71945) || (((71948 <= code) && (code <= 71955)) || ((71957 <= code) && (code <= 71958)))))))))))) : (((71960 <= code) && (code <= 71983)) || (((72016 <= code) && (code <= 72025)) || (((72096 <= code) && (code <= 72103)) || (((72106 <= code) && (code <= 72144)) || ((code === 72192) || (((72203 <= code) && (code <= 72242)) || ((code === 72250) || ((code === 72272) || (((72284 <= code) && (code <= 72329)) || ((code === 72349) || (((72368 <= code) && (code <= 72440)) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && (((71999 <= code) && (code <= 72001)) || ((72161 <= code) && (code <= 72163)))))))))))))))) : ((code < 73062) ? (((72704 <= code) && (code <= 72712)) || (((72714 <= code) && (code <= 72750)) || ((code === 72768) || (((72784 <= code) && (code <= 72812)) || (((72818 <= code) && (code <= 72847)) || (((72960 <= code) && (code <= 72966)) || (((72968 <= code) && (code <= 72969)) || (((72971 <= code) && (code <= 73008)) || ((code === 73030) || (((73040 <= code) && (code <= 73049)) || ((73056 <= code) && (code <= 73061)))))))))))) : (((73063 <= code) && (code <= 73064)) || (((73066 <= code) && (code <= 73097)) || ((code === 73112) || (((73120 <= code) && (code <= 73129)) || (((73440 <= code) && (code <= 73458)) || ((code === 73474) || (((73476 <= code) && (code <= 73488)) || (((73490 <= code) && (code <= 73523)) || (((73552 <= code) && (code <= 73561)) || ((code === 73648) || ((73664 <= code) && (code <= 73684)))))))))))))) : ((code < 94098) ? ((code < 92863) ? (((73728 <= code) && (code <= 74649)) || (((74752 <= code) && (code <= 74862)) || (((74880 <= code) && (code <= 75075)) || (((77712 <= code) && (code <= 77808)) || (((77824 <= code) && (code <= 78895)) || (((78913 <= code) && (code <= 78918)) || (((82944 <= code) && (code <= 83526)) || (((92160 <= code) && (code <= 92728)) || (((92736 <= code) && (code <= 92766)) || (((92768 <= code) && (code <= 92777)) || ((92784 <= code) && (code <= 92862)))))))))))) : (((92864 <= code) && (code <= 92873)) || (((92880 <= code) && (code <= 92909)) || (((92928 <= code) && (code <= 92975)) || (((92992 <= code) && (code <= 92995)) || (((93008 <= code) && (code <= 93017)) || (((93019 <= code) && (code <= 93025)) || (((93027 <= code) && (code <= 93047)) || (((93053 <= code) && (code <= 93071)) || (((93760 <= code) && (code <= 93846)) || (((93952 <= code) && (code <= 94026)) || (code === 94032)))))))))))) : ((code < 110927) ? (((94099 <= code) && (code <= 94111)) || (((94176 <= code) && (code <= 94177)) || ((code === 94179) || (((94208 <= code) && (code <= 100343)) || (((100352 <= code) && (code <= 101589)) || (((101632 <= code) && (code <= 101640)) || (((110576 <= code) && (code <= 110579)) || (((110581 <= code) && (code <= 110587)) || (((110589 <= code) && (code <= 110590)) || (((110592 <= code) && (code <= 110882)) || (code === 110898))))))))))) : (((110928 <= code) && (code <= 110930)) || ((code === 110933) || (((110948 <= code) && (code <= 110951)) || (((110960 <= code) && (code <= 111355)) || (((113664 <= code) && (code <= 113770)) || (((113776 <= code) && (code <= 113788)) || (((113792 <= code) && (code <= 113800)) || (((113808 <= code) && (code <= 113817)) || (((119488 <= code) && (code <= 119507)) || (((119520 <= code) && (code <= 119539)) || (((119648 <= code) && (code <= 119672)) || ((119808 <= code) && (code <= 119892)))))))))))))))) : ((code < 124911) ? ((code < 120597) ? ((code < 120085) ? (((119894 <= code) && (code <= 119964)) || (((119966 <= code) && (code <= 119967)) || ((code === 119970) || (((119973 <= code) && (code <= 119974)) || (((119977 <= code) && (code <= 119980)) || (((119982 <= code) && (code <= 119993)) || ((code === 119995) || (((119997 <= code) && (code <= 120003)) || (((120005 <= code) && (code <= 120069)) || (((120071 <= code) && (code <= 120074)) || ((120077 <= code) && (code <= 120084)))))))))))) : (((120086 <= code) && (code <= 120092)) || (((120094 <= code) && (code <= 120121)) || (((120123 <= code) && (code <= 120126)) || (((120128 <= code) && (code <= 120132)) || ((code === 120134) || (((120138 <= code) && (code <= 120144)) || (((120146 <= code) && (code <= 120485)) || (((120488 <= code) && (code <= 120512)) || (((120514 <= code) && (code <= 120538)) || (((120540 <= code) && (code <= 120570)) || ((120572 <= code) && (code <= 120596))))))))))))) : ((code < 123135) ? (((120598 <= code) && (code <= 120628)) || (((120630 <= code) && (code <= 120654)) || (((120656 <= code) && (code <= 120686)) || (((120688 <= code) && (code <= 120712)) || (((120714 <= code) && (code <= 120744)) || (((120746 <= code) && (code <= 120770)) || (((120772 <= code) && (code <= 120779)) || (((120782 <= code) && (code <= 120831)) || (((122624 <= code) && (code <= 122654)) || (((122661 <= code) && (code <= 122666)) || ((122928 <= code) && (code <= 122989)))))))))))) : (((123136 <= code) && (code <= 123180)) || (((123191 <= code) && (code <= 123197)) || (((123200 <= code) && (code <= 123209)) || ((code === 123214) || (((123536 <= code) && (code <= 123565)) || (((123584 <= code) && (code <= 123627)) || (((123632 <= code) && (code <= 123641)) || (((124112 <= code) && (code <= 124139)) || (((124144 <= code) && (code <= 124153)) || (((124896 <= code) && (code <= 124902)) || (((124904 <= code) && (code <= 124907)) || ((124909 <= code) && (code <= 124910))))))))))))))) : ((code < 126560) ? ((code < 126463) ? (((124912 <= code) && (code <= 124926)) || (((124928 <= code) && (code <= 125124)) || (((125127 <= code) && (code <= 125135)) || (((125184 <= code) && (code <= 125251)) || ((code === 125259) || (((125264 <= code) && (code <= 125273)) || (((126065 <= code) && (code <= 126123)) || (((126125 <= code) && (code <= 126127)) || (((126129 <= code) && (code <= 126132)) || (((126209 <= code) && (code <= 126253)) || ((126255 <= code) && (code <= 126269)))))))))))) : (((126464 <= code) && (code <= 126467)) || (((126469 <= code) && (code <= 126495)) || (((126497 <= code) && (code <= 126498)) || ((code === 126500) || ((code === 126503) || (((126505 <= code) && (code <= 126514)) || (((126516 <= code) && (code <= 126519)) || ((code === 126530) || (((126541 <= code) && (code <= 126543)) || (((126545 <= code) && (code <= 126546)) || ((code === 126548) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && (((126521 <= code) && (code <= 126523)) || (((126535 <= code) && (code <= 126539)) || ((126551 <= code) && (code <= 126559))))))))))))))))) : ((code < 126634) ? (((126561 <= code) && (code <= 126562)) || ((code === 126564) || (((126567 <= code) && (code <= 126570)) || (((126572 <= code) && (code <= 126578)) || (((126580 <= code) && (code <= 126583)) || (((126585 <= code) && (code <= 126588)) || ((code === 126590) || (((126592 <= code) && (code <= 126601)) || (((126603 <= code) && (code <= 126619)) || (((126625 <= code) && (code <= 126627)) || ((126629 <= code) && (code <= 126633)))))))))))) : (((126635 <= code) && (code <= 126651)) || (((127232 <= code) && (code <= 127244)) || (((130032 <= code) && (code <= 130041)) || (((131072 <= code) && (code <= 173791)) || (((173824 <= code) && (code <= 177977)) || (((177984 <= code) && (code <= 178205)) || (((178208 <= code) && (code <= 183969)) || (((183984 <= code) && (code <= 191456)) || (((191472 <= code) && (code <= 192093)) || (((194560 <= code) && (code <= 195101)) || (((196608 <= code) && (code <= 201546)) || ((201552 <= code) && (code <= 205743))))))))))))))))))))))));
};
var $elm$core$String$fromChar = function (_char) {
	return A2($elm$core$String$cons, _char, '');
};
var $elm$core$String$toLower = _String_toLower;
var $elm$core$String$toUpper = _String_toUpper;
var $lue_bird$elm_syntax_format$Char$Extra$unicodeIsLowerFast = function (c) {
	var code = $elm$core$Char$toCode(c);
	var cString = $elm$core$String$fromChar(c);
	return $lue_bird$elm_syntax_format$Char$Extra$charCodeIsLower(code) || ((_Utils_eq(
		$elm$core$String$toLower(cString),
		cString) && (!_Utils_eq(
		$elm$core$String$toUpper(cString),
		cString))) ? ((code <= 836) || (((838 <= code) && (code <= 8559)) || (((8576 <= code) && (code <= 9423)) || ((9450 <= code) && (code <= 983040))))) : ((code < 43001) ? ((code < 8457) ? ((code < 590) ? (((311 <= code) && (code <= 312)) || (((396 <= code) && (code <= 397)) || (((409 <= code) && (code <= 411)) || (((426 <= code) && (code <= 427)) || (((441 <= code) && (code <= 442)) || (((445 <= code) && (code <= 447)) || ((code === 545) || ((563 <= code) && (code <= 569))))))))) : (((591 <= code) && (code <= 659)) || (((661 <= code) && (code <= 687)) || (((1019 <= code) && (code <= 1020)) || (((1376 <= code) && (code <= 1416)) || (((7424 <= code) && (code <= 7467)) || (((7531 <= code) && (code <= 7543)) || (((7545 <= code) && (code <= 7578)) || (((7829 <= code) && (code <= 7837)) || (code === 7839)))))))))) : ((code < 11376) ? ((code === 8458) || (((8462 <= code) && (code <= 8463)) || ((code === 8467) || ((code === 8495) || ((code === 8500) || ((code === 8505) || (((8508 <= code) && (code <= 8509)) || ((8518 <= code) && (code <= 8521))))))))) : ((code === 11377) || (((11379 <= code) && (code <= 11380)) || (((11382 <= code) && (code <= 11387)) || (((11491 <= code) && (code <= 11492)) || (((42799 <= code) && (code <= 42801)) || (((42865 <= code) && (code <= 42872)) || ((code === 42894) || (((42899 <= code) && (code <= 42901)) || ((code === 42927) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && ((42963 <= code) && (code <= 42965)))))))))))))) : ((code < 120353) ? ((code < 119994) ? ((code === 43002) || (((43824 <= code) && (code <= 43866)) || (((43872 <= code) && (code <= 43880)) || (((119834 <= code) && (code <= 119859)) || (((119886 <= code) && (code <= 119892)) || (((119894 <= code) && (code <= 119911)) || (((119938 <= code) && (code <= 119963)) || ((119990 <= code) && (code <= 119993))))))))) : ((code === 119995) || (((119997 <= code) && (code <= 120003)) || (((120005 <= code) && (code <= 120015)) || (((120042 <= code) && (code <= 120067)) || (((120094 <= code) && (code <= 120119)) || (((120146 <= code) && (code <= 120171)) || (((120198 <= code) && (code <= 120223)) || (((120250 <= code) && (code <= 120275)) || ((120302 <= code) && (code <= 120327))))))))))) : ((code < 120655) ? (((120354 <= code) && (code <= 120379)) || (((120406 <= code) && (code <= 120431)) || (((120458 <= code) && (code <= 120485)) || (((120514 <= code) && (code <= 120538)) || (((120540 <= code) && (code <= 120545)) || (((120572 <= code) && (code <= 120596)) || (((120598 <= code) && (code <= 120603)) || ((120630 <= code) && (code <= 120654))))))))) : (((120656 <= code) && (code <= 120661)) || (((120688 <= code) && (code <= 120712)) || (((120714 <= code) && (code <= 120719)) || (((120746 <= code) && (code <= 120770)) || (((120772 <= code) && (code <= 120777)) || ((code === 120779) || (((122624 <= code) && (code <= 122633)) || (((122635 <= code) && (code <= 122654)) || ((122661 <= code) && (code <= 122666))))))))))))));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords = A3(
	$lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithRangeWithoutLinebreak,
	F2(
		function (range, name) {
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				range,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifKeywordUnderscoreSuffix(name));
		}),
	$lue_bird$elm_syntax_format$Char$Extra$unicodeIsLowerFast,
	$lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiRecordAccess = function (beforeRecordAccesses) {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsOntoResultFromParser,
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '.', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords),
		beforeRecordAccesses,
		F2(
			function (fieldNode, leftResult) {
				var _v0 = leftResult.a;
				var leftRange = _v0.a;
				var _v1 = fieldNode;
				var fieldRange = _v1.a;
				return {
					b: leftResult.b,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: fieldRange.cw, b9: leftRange.b9},
						A2($stil4m$elm_syntax$Elm$Syntax$Expression$RecordAccess, leftResult.a, fieldNode))
				};
			}),
		$elm$core$Basics$identity);
};
var $elm$core$Basics$ge = _Utils_ge;
var $stil4m$elm_syntax$Elm$Syntax$Expression$GLSLExpression = function (a) {
	return {$: 23, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$loopUntilHelp = F6(
	function (endParser, element, soFar, reduce, foldedToRes, s0) {
		loopUntilHelp:
		while (true) {
			var parseEnd = endParser;
			var parseElement = element;
			var _v0 = parseEnd(s0);
			if (!_v0.$) {
				var s1 = _v0.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					foldedToRes(soFar),
					s1);
			} else {
				var endCommitted = _v0.a;
				var endX = _v0.b;
				if (endCommitted) {
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, endX);
				} else {
					var _v1 = parseElement(s0);
					if (!_v1.$) {
						var elementResult = _v1.a;
						var s1 = _v1.b;
						var $temp$endParser = endParser,
							$temp$element = element,
							$temp$soFar = A2(reduce, elementResult, soFar),
							$temp$reduce = reduce,
							$temp$foldedToRes = foldedToRes,
							$temp$s0 = s1;
						endParser = $temp$endParser;
						element = $temp$element;
						soFar = $temp$soFar;
						reduce = $temp$reduce;
						foldedToRes = $temp$foldedToRes;
						s0 = $temp$s0;
						continue loopUntilHelp;
					} else {
						return $lue_bird$elm_syntax_format$ParserFast$pStepBadCommitting;
					}
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$loopUntil = F5(
	function (endParser, element, initialFolded, reduce, foldedToRes) {
		return function (s) {
			return A6($lue_bird$elm_syntax_format$ParserFast$loopUntilHelp, endParser, element, initialFolded, reduce, foldedToRes, s);
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$mapWithRange = F2(
	function (combineStartAndResult, _v0) {
		var parse = _v0;
		return function (s0) {
			var _v1 = parse(s0);
			if (!_v1.$) {
				var a = _v1.a;
				var s1 = _v1.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A2(
						combineStartAndResult,
						{
							cw: {cp: s1.co, c9: s1.c9},
							b9: {cp: s0.co, c9: s0.c9}
						},
						a),
					s1);
			} else {
				var committed = _v1.a;
				var x = _v1.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$glslExpressionAfterOpeningSquareBracket = A2(
	$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
	'glsl|',
	A2(
		$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
		F2(
			function (range, s) {
				return {
					b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{
							cw: {cp: range.cw.cp + 2, c9: range.cw.c9},
							b9: {cp: range.b9.cp - 6, c9: range.b9.c9}
						},
						$stil4m$elm_syntax$Elm$Syntax$Expression$GLSLExpression(s))
				};
			}),
		A5(
			$lue_bird$elm_syntax_format$ParserFast$loopUntil,
			A2($lue_bird$elm_syntax_format$ParserFast$symbol, '|]', 0),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2($lue_bird$elm_syntax_format$ParserFast$symbol, '|', '|'),
				$lue_bird$elm_syntax_format$ParserFast$while(
					function (c) {
						if ('|' === c) {
							return false;
						} else {
							return true;
						}
					})),
			'',
			F2(
				function (extension, soFar) {
					return soFar + (extension + '');
				}),
			$elm$core$Basics$identity)));
var $lue_bird$elm_syntax_format$Char$Extra$isLatinAlphaNumOrUnderscoreFast = function (c) {
	var code = $elm$core$Char$toCode(c);
	return $lue_bird$elm_syntax_format$Char$Extra$charCodeIsLower(code) || ($lue_bird$elm_syntax_format$Char$Extra$charCodeIsUpper(code) || ($lue_bird$elm_syntax_format$Char$Extra$charCodeIsDigit(code) || (code === 95)));
};
var $lue_bird$elm_syntax_format$ParserFast$isSubCharAlphaNumOrUnderscore = F2(
	function (offset, string) {
		return A2(
			$elm$core$String$any,
			$lue_bird$elm_syntax_format$Char$Extra$isLatinAlphaNumOrUnderscoreFast,
			A3($elm$core$String$slice, offset, offset + 1, string));
	});
var $lue_bird$elm_syntax_format$ParserFast$keyword = F2(
	function (kwd, res) {
		var kwdLength = $elm$core$String$length(kwd);
		return function (s) {
			var newOffset = s.i + kwdLength;
			return (_Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				kwd) && (!A2($lue_bird$elm_syntax_format$ParserFast$isSubCharAlphaNumOrUnderscore, newOffset, s.g))) ? A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				res,
				{co: s.co + kwdLength, m: s.m, i: newOffset, c9: s.c9, g: s.g}) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy = F2(
	function (kwd, _v0) {
		var parseNext = _v0;
		var kwdLength = $elm$core$String$length(kwd);
		return function (s) {
			var newOffset = s.i + kwdLength;
			return (_Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				kwd) && (!A2($lue_bird$elm_syntax_format$ParserFast$isSubCharAlphaNumOrUnderscore, newOffset, s.g))) ? $lue_bird$elm_syntax_format$ParserFast$pStepCommit(
				parseNext(
					{co: s.co + kwdLength, m: s.m, i: newOffset, c9: s.c9, g: s.g})) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$lazy = function (thunk) {
	return function (s) {
		var _v0 = thunk(0);
		var parse = _v0;
		return parse(s);
	};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$Literal = function (a) {
	return {$: 11, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$whileAtLeast1WithoutLinebreak = function (isGood) {
	return function (s0) {
		var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileWithoutLinebreakHelp, isGood, s0.i, s0.c9, s0.co, s0.g, s0.m);
		return (!(s1.i - s0.i)) ? $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking : A2(
			$lue_bird$elm_syntax_format$ParserFast$Good,
			A3($elm$core$String$slice, s0.i, s1.i, s0.g),
			s1);
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleQuotedStringLiteralAfterDoubleQuote = A5(
	$lue_bird$elm_syntax_format$ParserFast$loopUntil,
	A2($lue_bird$elm_syntax_format$ParserFast$symbol, '\"', 0),
	A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		$lue_bird$elm_syntax_format$ParserFast$whileAtLeast1WithoutLinebreak(
			function (c) {
				return (c !== '\"') && ((c !== '\\') && (!$lue_bird$elm_syntax_format$Char$Extra$isUtf16Surrogate(c)));
			}),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'\\',
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$escapedCharValueMap($elm$core$String$fromChar))),
	'',
	F2(
		function (extension, soFar) {
			return soFar + (extension + '');
		}),
	$elm$core$Basics$identity);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tripleQuotedStringLiteralOfterTripleDoubleQuote = A5(
	$lue_bird$elm_syntax_format$ParserFast$loopUntil,
	A2($lue_bird$elm_syntax_format$ParserFast$symbol, '\"\"\"', 0),
	A3(
		$lue_bird$elm_syntax_format$ParserFast$oneOf3,
		A2($lue_bird$elm_syntax_format$ParserFast$symbol, '\"', '\"'),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'\\',
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$escapedCharValueMap($elm$core$String$fromChar)),
		$lue_bird$elm_syntax_format$ParserFast$while(
			function (c) {
				return (c !== '\"') && ((c !== '\\') && (!$lue_bird$elm_syntax_format$Char$Extra$isUtf16Surrogate(c)));
			})),
	'',
	F2(
		function (extension, soFar) {
			return soFar + (extension + '');
		}),
	$elm$core$Basics$identity);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleOrTripleQuotedStringLiteralMapWithRange = function (rangeAndStringToRes) {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'\"',
		A4(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2MapWithStartRowColumnAndEndRowColumn,
			F5(
				function (startRow, startColumn, string, endRow, endColumn) {
					return A2(
						rangeAndStringToRes,
						{
							cw: {cp: endColumn, c9: endRow},
							b9: {cp: startColumn - 1, c9: startRow}
						},
						string);
				}),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '\"\"', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tripleQuotedStringLiteralOfterTripleDoubleQuote),
			F5(
				function (startRow, startColumn, string, endRow, endColumn) {
					return A2(
						rangeAndStringToRes,
						{
							cw: {cp: endColumn, c9: endRow},
							b9: {cp: startColumn - 1, c9: startRow}
						},
						string);
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleQuotedStringLiteralAfterDoubleQuote));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$literalExpression = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleOrTripleQuotedStringLiteralMapWithRange(
	F2(
		function (range, string) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Expression$Literal(string))
			};
		}));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$literalExpressionOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByOptimisticLayout($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$literalExpression);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments = function (p) {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceeds,
		p,
		_Utils_Tuple2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, _List_Nil),
		F2(
			function (pResult, _v0) {
				var commentsSoFar = _v0.a;
				var itemsSoFar = _v0.b;
				return _Utils_Tuple2(
					A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, pResult.b, commentsSoFar),
					A2($elm$core$List$cons, pResult.a, itemsSoFar));
			}),
		function (_v1) {
			var commentsSoFar = _v1.a;
			var itemsSoFar = _v1.b;
			return {
				b: commentsSoFar,
				a: $elm$core$List$reverse(itemsSoFar)
			};
		});
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse = function (p) {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceeds,
		p,
		{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: _List_Nil},
		F2(
			function (pResult, soFar) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, pResult.b, soFar.b),
					a: A2($elm$core$List$cons, pResult.a, soFar.a)
				};
			}),
		function (result) {
			return result;
		});
};
var $lue_bird$elm_syntax_format$ParserFast$map = F2(
	function (func, _v0) {
		var parse = _v0;
		return function (s0) {
			var _v1 = parse(s0);
			if (!_v1.$) {
				var a = _v1.a;
				var s1 = _v1.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					func(a),
					s1);
			} else {
				var committed = _v1.a;
				var x = _v1.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map3 = F4(
	function (func, _v0, _v1, _v2) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		return function (s0) {
			var _v3 = parseA(s0);
			if (_v3.$ === 1) {
				var committed = _v3.a;
				var x = _v3.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v3.a;
				var s1 = _v3.b;
				var _v4 = parseB(s1);
				if (_v4.$ === 1) {
					var x = _v4.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v4.a;
					var s2 = _v4.b;
					var _v5 = parseC(s2);
					if (_v5.$ === 1) {
						var x = _v5.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v5.a;
						var s3 = _v5.b;
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							A3(func, a, b, c),
							s3);
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map3WithRange = F4(
	function (func, _v0, _v1, _v2) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		return function (s0) {
			var _v3 = parseA(s0);
			if (_v3.$ === 1) {
				var committed = _v3.a;
				var x = _v3.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v3.a;
				var s1 = _v3.b;
				var _v4 = parseB(s1);
				if (_v4.$ === 1) {
					var x = _v4.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v4.a;
					var s2 = _v4.b;
					var _v5 = parseC(s2);
					if (_v5.$ === 1) {
						var x = _v5.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v5.a;
						var s3 = _v5.b;
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							A4(
								func,
								{
									cw: {cp: s3.co, c9: s3.c9},
									b9: {cp: s0.co, c9: s0.c9}
								},
								a,
								b,
								c),
							s3);
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map3WithStartLocation = F4(
	function (func, _v0, _v1, _v2) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		return function (s0) {
			var _v3 = parseA(s0);
			if (_v3.$ === 1) {
				var committed = _v3.a;
				var x = _v3.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v3.a;
				var s1 = _v3.b;
				var _v4 = parseB(s1);
				if (_v4.$ === 1) {
					var x = _v4.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v4.a;
					var s2 = _v4.b;
					var _v5 = parseC(s2);
					if (_v5.$ === 1) {
						var x = _v5.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v5.a;
						var s3 = _v5.b;
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							A4(
								func,
								{cp: s0.co, c9: s0.c9},
								a,
								b,
								c),
							s3);
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map4 = F5(
	function (func, _v0, _v1, _v2, _v3) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		return function (s0) {
			var _v4 = parseA(s0);
			if (_v4.$ === 1) {
				var committed = _v4.a;
				var x = _v4.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v4.a;
				var s1 = _v4.b;
				var _v5 = parseB(s1);
				if (_v5.$ === 1) {
					var x = _v5.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v5.a;
					var s2 = _v5.b;
					var _v6 = parseC(s2);
					if (_v6.$ === 1) {
						var x = _v6.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v6.a;
						var s3 = _v6.b;
						var _v7 = parseD(s3);
						if (_v7.$ === 1) {
							var x = _v7.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v7.a;
							var s4 = _v7.b;
							return A2(
								$lue_bird$elm_syntax_format$ParserFast$Good,
								A4(func, a, b, c, d),
								s4);
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map4OrSucceed = F6(
	function (func, _v0, _v1, _v2, _v3, fallback) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		return function (s0) {
			var _v4 = parseA(s0);
			if (_v4.$ === 1) {
				var c1 = _v4.a;
				var x = _v4.b;
				return c1 ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x) : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallback, s0);
			} else {
				var a = _v4.a;
				var s1 = _v4.b;
				var _v5 = parseB(s1);
				if (_v5.$ === 1) {
					var x = _v5.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v5.a;
					var s2 = _v5.b;
					var _v6 = parseC(s2);
					if (_v6.$ === 1) {
						var x = _v6.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v6.a;
						var s3 = _v6.b;
						var _v7 = parseD(s3);
						if (_v7.$ === 1) {
							var x = _v7.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v7.a;
							var s4 = _v7.b;
							return A2(
								$lue_bird$elm_syntax_format$ParserFast$Good,
								A4(func, a, b, c, d),
								s4);
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map4WithRange = F5(
	function (func, _v0, _v1, _v2, _v3) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		return function (s0) {
			var _v4 = parseA(s0);
			if (_v4.$ === 1) {
				var committed = _v4.a;
				var x = _v4.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v4.a;
				var s1 = _v4.b;
				var _v5 = parseB(s1);
				if (_v5.$ === 1) {
					var x = _v5.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v5.a;
					var s2 = _v5.b;
					var _v6 = parseC(s2);
					if (_v6.$ === 1) {
						var x = _v6.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v6.a;
						var s3 = _v6.b;
						var _v7 = parseD(s3);
						if (_v7.$ === 1) {
							var x = _v7.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v7.a;
							var s4 = _v7.b;
							return A2(
								$lue_bird$elm_syntax_format$ParserFast$Good,
								A5(
									func,
									{
										cw: {cp: s4.co, c9: s4.c9},
										b9: {cp: s0.co, c9: s0.c9}
									},
									a,
									b,
									c,
									d),
								s4);
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map4WithStartLocation = F5(
	function (func, _v0, _v1, _v2, _v3) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		return function (s0) {
			var _v4 = parseA(s0);
			if (_v4.$ === 1) {
				var committed = _v4.a;
				var x = _v4.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v4.a;
				var s1 = _v4.b;
				var _v5 = parseB(s1);
				if (_v5.$ === 1) {
					var x = _v5.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v5.a;
					var s2 = _v5.b;
					var _v6 = parseC(s2);
					if (_v6.$ === 1) {
						var x = _v6.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v6.a;
						var s3 = _v6.b;
						var _v7 = parseD(s3);
						if (_v7.$ === 1) {
							var x = _v7.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v7.a;
							var s4 = _v7.b;
							return A2(
								$lue_bird$elm_syntax_format$ParserFast$Good,
								A5(
									func,
									{cp: s0.co, c9: s0.c9},
									a,
									b,
									c,
									d),
								s4);
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map5 = F6(
	function (func, _v0, _v1, _v2, _v3, _v4) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		return function (s0) {
			var _v5 = parseA(s0);
			if (_v5.$ === 1) {
				var committed = _v5.a;
				var x = _v5.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v5.a;
				var s1 = _v5.b;
				var _v6 = parseB(s1);
				if (_v6.$ === 1) {
					var x = _v6.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v6.a;
					var s2 = _v6.b;
					var _v7 = parseC(s2);
					if (_v7.$ === 1) {
						var x = _v7.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v7.a;
						var s3 = _v7.b;
						var _v8 = parseD(s3);
						if (_v8.$ === 1) {
							var x = _v8.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v8.a;
							var s4 = _v8.b;
							var _v9 = parseE(s4);
							if (_v9.$ === 1) {
								var x = _v9.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v9.a;
								var s5 = _v9.b;
								return A2(
									$lue_bird$elm_syntax_format$ParserFast$Good,
									A5(func, a, b, c, d, e),
									s5);
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map6WithStartLocation = F7(
	function (func, _v0, _v1, _v2, _v3, _v4, _v5) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		var parseF = _v5;
		return function (s0) {
			var _v6 = parseA(s0);
			if (_v6.$ === 1) {
				var committed = _v6.a;
				var x = _v6.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v6.a;
				var s1 = _v6.b;
				var _v7 = parseB(s1);
				if (_v7.$ === 1) {
					var x = _v7.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v7.a;
					var s2 = _v7.b;
					var _v8 = parseC(s2);
					if (_v8.$ === 1) {
						var x = _v8.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v8.a;
						var s3 = _v8.b;
						var _v9 = parseD(s3);
						if (_v9.$ === 1) {
							var x = _v9.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v9.a;
							var s4 = _v9.b;
							var _v10 = parseE(s4);
							if (_v10.$ === 1) {
								var x = _v10.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v10.a;
								var s5 = _v10.b;
								var _v11 = parseF(s5);
								if (_v11.$ === 1) {
									var x = _v11.b;
									return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
								} else {
									var f = _v11.a;
									var s6 = _v11.b;
									return A2(
										$lue_bird$elm_syntax_format$ParserFast$Good,
										A7(
											func,
											{cp: s0.co, c9: s0.c9},
											a,
											b,
											c,
											d,
											e,
											f),
										s6);
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map8WithStartLocation = F9(
	function (func, _v0, _v1, _v2, _v3, _v4, _v5, _v6, _v7) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		var parseF = _v5;
		var parseG = _v6;
		var parseH = _v7;
		return function (s0) {
			var _v8 = parseA(s0);
			if (_v8.$ === 1) {
				var committed = _v8.a;
				var x = _v8.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v8.a;
				var s1 = _v8.b;
				var _v9 = parseB(s1);
				if (_v9.$ === 1) {
					var x = _v9.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v9.a;
					var s2 = _v9.b;
					var _v10 = parseC(s2);
					if (_v10.$ === 1) {
						var x = _v10.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v10.a;
						var s3 = _v10.b;
						var _v11 = parseD(s3);
						if (_v11.$ === 1) {
							var x = _v11.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v11.a;
							var s4 = _v11.b;
							var _v12 = parseE(s4);
							if (_v12.$ === 1) {
								var x = _v12.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v12.a;
								var s5 = _v12.b;
								var _v13 = parseF(s5);
								if (_v13.$ === 1) {
									var x = _v13.b;
									return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
								} else {
									var f = _v13.a;
									var s6 = _v13.b;
									var _v14 = parseG(s6);
									if (_v14.$ === 1) {
										var x = _v14.b;
										return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
									} else {
										var g = _v14.a;
										var s7 = _v14.b;
										var _v15 = parseH(s7);
										if (_v15.$ === 1) {
											var x = _v15.b;
											return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
										} else {
											var h = _v15.a;
											var s8 = _v15.b;
											return A2(
												$lue_bird$elm_syntax_format$ParserFast$Good,
												A9(
													func,
													{cp: s0.co, c9: s0.c9},
													a,
													b,
													c,
													d,
													e,
													f,
													g,
													h),
												s8);
										}
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$mapOrSucceed = F3(
	function (attemptToResult, _v0, fallbackResult) {
		var attempt = _v0;
		return function (s) {
			var _v1 = attempt(s);
			if (!_v1.$) {
				var attemptResult = _v1.a;
				var s1 = _v1.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					attemptToResult(attemptResult),
					s1);
			} else {
				var firstCommitted = _v1.a;
				return firstCommitted ? $lue_bird$elm_syntax_format$ParserFast$pStepBadCommitting : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallbackResult, s);
			}
		};
	});
var $stil4m$elm_syntax$Elm$Syntax$Expression$Floatable = function (a) {
	return {$: 9, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$Hex = function (a) {
	return {$: 8, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$Integer = function (a) {
	return {$: 7, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$Decimal = 0;
var $lue_bird$elm_syntax_format$ParserFast$Hexadecimal = 1;
var $lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s = F3(
	function (soFar, offset, src) {
		convert0OrMore0To9s:
		while (true) {
			var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
			switch (_v0) {
				case '0':
					var $temp$soFar = soFar * 10,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '1':
					var $temp$soFar = (soFar * 10) + 1,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '2':
					var $temp$soFar = (soFar * 10) + 2,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '3':
					var $temp$soFar = (soFar * 10) + 3,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '4':
					var $temp$soFar = (soFar * 10) + 4,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '5':
					var $temp$soFar = (soFar * 10) + 5,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '6':
					var $temp$soFar = (soFar * 10) + 6,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '7':
					var $temp$soFar = (soFar * 10) + 7,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '8':
					var $temp$soFar = (soFar * 10) + 8,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				case '9':
					var $temp$soFar = (soFar * 10) + 9,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMore0To9s;
				default:
					return {cI: soFar, i: offset};
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal = F3(
	function (soFar, offset, src) {
		convert0OrMoreHexadecimal:
		while (true) {
			var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
			switch (_v0) {
				case '0':
					var $temp$soFar = soFar * 16,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '1':
					var $temp$soFar = (soFar * 16) + 1,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '2':
					var $temp$soFar = (soFar * 16) + 2,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '3':
					var $temp$soFar = (soFar * 16) + 3,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '4':
					var $temp$soFar = (soFar * 16) + 4,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '5':
					var $temp$soFar = (soFar * 16) + 5,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '6':
					var $temp$soFar = (soFar * 16) + 6,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '7':
					var $temp$soFar = (soFar * 16) + 7,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '8':
					var $temp$soFar = (soFar * 16) + 8,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case '9':
					var $temp$soFar = (soFar * 16) + 9,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'a':
					var $temp$soFar = (soFar * 16) + 10,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'A':
					var $temp$soFar = (soFar * 16) + 10,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'b':
					var $temp$soFar = (soFar * 16) + 11,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'B':
					var $temp$soFar = (soFar * 16) + 11,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'c':
					var $temp$soFar = (soFar * 16) + 12,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'C':
					var $temp$soFar = (soFar * 16) + 12,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'd':
					var $temp$soFar = (soFar * 16) + 13,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'D':
					var $temp$soFar = (soFar * 16) + 13,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'e':
					var $temp$soFar = (soFar * 16) + 14,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'E':
					var $temp$soFar = (soFar * 16) + 14,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'f':
					var $temp$soFar = (soFar * 16) + 15,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				case 'F':
					var $temp$soFar = (soFar * 16) + 15,
						$temp$offset = offset + 1,
						$temp$src = src;
					soFar = $temp$soFar;
					offset = $temp$offset;
					src = $temp$src;
					continue convert0OrMoreHexadecimal;
				default:
					return {cI: soFar, i: offset};
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$convert1OrMoreHexadecimal = F2(
	function (offset, src) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
		switch (_v0) {
			case '0':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 0, offset + 1, src);
			case '1':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 1, offset + 1, src);
			case '2':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 2, offset + 1, src);
			case '3':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 3, offset + 1, src);
			case '4':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 4, offset + 1, src);
			case '5':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 5, offset + 1, src);
			case '6':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 6, offset + 1, src);
			case '7':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 7, offset + 1, src);
			case '8':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 8, offset + 1, src);
			case '9':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 9, offset + 1, src);
			case 'a':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 10, offset + 1, src);
			case 'A':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 10, offset + 1, src);
			case 'b':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 11, offset + 1, src);
			case 'B':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 11, offset + 1, src);
			case 'c':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 12, offset + 1, src);
			case 'C':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 12, offset + 1, src);
			case 'd':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 13, offset + 1, src);
			case 'D':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 13, offset + 1, src);
			case 'e':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 14, offset + 1, src);
			case 'E':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 14, offset + 1, src);
			case 'f':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 15, offset + 1, src);
			case 'F':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMoreHexadecimal, 15, offset + 1, src);
			default:
				return {cI: 0, i: -1};
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$errorAsBaseOffsetAndInt = {
	J: 0,
	r: {cI: 0, i: -1}
};
var $lue_bird$elm_syntax_format$ParserFast$convertIntegerDecimalOrHexadecimal = F2(
	function (offset, src) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
		switch (_v0) {
			case '0':
				var _v1 = A3($elm$core$String$slice, offset + 1, offset + 2, src);
				if (_v1 === 'x') {
					var hex = A2($lue_bird$elm_syntax_format$ParserFast$convert1OrMoreHexadecimal, offset + 2, src);
					return {
						J: 1,
						r: {cI: hex.cI, i: hex.i}
					};
				} else {
					return {
						J: 0,
						r: {cI: 0, i: offset + 1}
					};
				}
			case '1':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 1, offset + 1, src)
				};
			case '2':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 2, offset + 1, src)
				};
			case '3':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 3, offset + 1, src)
				};
			case '4':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 4, offset + 1, src)
				};
			case '5':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 5, offset + 1, src)
				};
			case '6':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 6, offset + 1, src)
				};
			case '7':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 7, offset + 1, src)
				};
			case '8':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 8, offset + 1, src)
				};
			case '9':
				return {
					J: 0,
					r: A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 9, offset + 1, src)
				};
			default:
				return $lue_bird$elm_syntax_format$ParserFast$errorAsBaseOffsetAndInt;
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9 = F2(
	function (offset, src) {
		skip0OrMoreDigits0To9:
		while (true) {
			var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
			switch (_v0) {
				case '0':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '1':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '2':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '3':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '4':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '5':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '6':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '7':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '8':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				case '9':
					var $temp$offset = offset + 1,
						$temp$src = src;
					offset = $temp$offset;
					src = $temp$src;
					continue skip0OrMoreDigits0To9;
				default:
					return offset;
			}
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$skip1OrMoreDigits0To9 = F2(
	function (offset, src) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
		switch (_v0) {
			case '0':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '1':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '2':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '3':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '4':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '5':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '6':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '7':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '8':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			case '9':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip0OrMoreDigits0To9, offset + 1, src);
			default:
				return -1;
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$skipAfterFloatExponentMark = F2(
	function (offset, src) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
		switch (_v0) {
			case '+':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip1OrMoreDigits0To9, offset + 1, src);
			case '-':
				return A2($lue_bird$elm_syntax_format$ParserFast$skip1OrMoreDigits0To9, offset + 1, src);
			default:
				return A2($lue_bird$elm_syntax_format$ParserFast$skip1OrMoreDigits0To9, offset, src);
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$skipFloatAfterIntegerDecimal = F2(
	function (offset, src) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
		switch (_v0) {
			case '.':
				var offsetAfterDigits = A2($lue_bird$elm_syntax_format$ParserFast$skip1OrMoreDigits0To9, offset + 1, src);
				if (_Utils_eq(offsetAfterDigits, -1)) {
					return -1;
				} else {
					var _v1 = A3($elm$core$String$slice, offsetAfterDigits, offsetAfterDigits + 1, src);
					switch (_v1) {
						case 'e':
							return A2($lue_bird$elm_syntax_format$ParserFast$skipAfterFloatExponentMark, offsetAfterDigits + 1, src);
						case 'E':
							return A2($lue_bird$elm_syntax_format$ParserFast$skipAfterFloatExponentMark, offsetAfterDigits + 1, src);
						default:
							return offsetAfterDigits;
					}
				}
			case 'e':
				return A2($lue_bird$elm_syntax_format$ParserFast$skipAfterFloatExponentMark, offset + 1, src);
			case 'E':
				return A2($lue_bird$elm_syntax_format$ParserFast$skipAfterFloatExponentMark, offset + 1, src);
			default:
				return -1;
		}
	});
var $elm$core$String$toFloat = _String_toFloat;
var $lue_bird$elm_syntax_format$ParserFast$floatOrIntegerDecimalOrHexadecimalMapWithRange = F3(
	function (rangeAndFloatToRes, rangeAndIntDecimalToRes, rangeAndIntHexadecimalToRes) {
		return function (s0) {
			var s1 = A2($lue_bird$elm_syntax_format$ParserFast$convertIntegerDecimalOrHexadecimal, s0.i, s0.g);
			if (_Utils_eq(s1.r.i, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var offsetAfterFloat = A2($lue_bird$elm_syntax_format$ParserFast$skipFloatAfterIntegerDecimal, s1.r.i, s0.g);
				if (_Utils_eq(offsetAfterFloat, -1)) {
					var newColumn = s0.co + (s1.r.i - s0.i);
					var range = {
						cw: {cp: newColumn, c9: s0.c9},
						b9: {cp: s0.co, c9: s0.c9}
					};
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						function () {
							var _v0 = s1.J;
							if (!_v0) {
								return A2(rangeAndIntDecimalToRes, range, s1.r.cI);
							} else {
								return A2(rangeAndIntHexadecimalToRes, range, s1.r.cI);
							}
						}(),
						{co: newColumn, m: s0.m, i: s1.r.i, c9: s0.c9, g: s0.g});
				} else {
					var _v1 = $elm$core$String$toFloat(
						A3($elm$core$String$slice, s0.i, offsetAfterFloat, s0.g));
					if (!_v1.$) {
						var _float = _v1.a;
						var newColumn = s0.co + (offsetAfterFloat - s0.i);
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							A2(
								rangeAndFloatToRes,
								{
									cw: {cp: newColumn, c9: s0.c9},
									b9: {cp: s0.co, c9: s0.c9}
								},
								_float),
							{co: newColumn, m: s0.m, i: offsetAfterFloat, c9: s0.c9, g: s0.g});
					} else {
						return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$numberExpression = A3(
	$lue_bird$elm_syntax_format$ParserFast$floatOrIntegerDecimalOrHexadecimalMapWithRange,
	F2(
		function (range, n) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Expression$Floatable(n))
			};
		}),
	F2(
		function (range, n) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Expression$Integer(n))
			};
		}),
	F2(
		function (range, n) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Expression$Hex(n))
			};
		}));
var $lue_bird$elm_syntax_format$ParserFast$oneOf2OrSucceed = F3(
	function (_v0, _v1, fallbackResult) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		return function (s) {
			var _v2 = attemptFirst(s);
			if (!_v2.$) {
				var firstGood = _v2;
				return firstGood;
			} else {
				var firstBad = _v2;
				var firstCommitted = firstBad.a;
				if (firstCommitted) {
					return firstBad;
				} else {
					var _v3 = attemptSecond(s);
					if (!_v3.$) {
						var secondGood = _v3;
						return secondGood;
					} else {
						var secondBad = _v3;
						var secondCommitted = secondBad.a;
						return secondCommitted ? secondBad : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallbackResult, s);
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$orSucceed = F2(
	function (_v0, fallbackResult) {
		var attempt = _v0;
		return function (s) {
			var _v1 = attempt(s);
			if (!_v1.$) {
				var firstGood = _v1;
				return firstGood;
			} else {
				var firstBad = _v1;
				var firstCommitted = firstBad.a;
				return firstCommitted ? firstBad : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallbackResult, s);
			}
		};
	});
var $elm$core$Tuple$pair = F2(
	function (a, b) {
		return _Utils_Tuple2(a, b);
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$AsPattern = F2(
	function (a, b) {
		return {$: 13, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$ListPattern = function (a) {
	return {$: 10, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Pattern$NamedPattern = F2(
	function (a, b) {
		return {$: 12, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$ParenthesizedPattern = function (a) {
	return {$: 14, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern = function (a) {
	return {$: 7, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Pattern$UnConsPattern = F2(
	function (a, b) {
		return {$: 9, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$UnitPattern = {$: 1};
var $stil4m$elm_syntax$Elm$Syntax$Pattern$AllPattern = {$: 0};
var $lue_bird$elm_syntax_format$ParserFast$symbolWithRange = F2(
	function (str, startAndEndLocationToRes) {
		var strLength = $elm$core$String$length(str);
		return function (s) {
			var newOffset = s.i + strLength;
			if (_Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				str)) {
				var newCol = s.co + strLength;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					startAndEndLocationToRes(
						{
							cw: {cp: newCol, c9: s.c9},
							b9: {cp: s.co, c9: s.c9}
						}),
					{co: newCol, m: s.m, i: newOffset, c9: s.c9, g: s.g});
			} else {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$allPattern = A2(
	$lue_bird$elm_syntax_format$ParserFast$symbolWithRange,
	'_',
	function (range) {
		return {
			b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
			a: A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, $stil4m$elm_syntax$Elm$Syntax$Pattern$AllPattern)
		};
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$CharPattern = function (a) {
	return {$: 2, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charPattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$characterLiteralMapWithRange(
	F2(
		function (range, _char) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$CharPattern(_char))
			};
		}));
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsRightToLeftStackUnsafeHelp = F3(
	function (element, reduce, s0) {
		var parseElement = element;
		var _v0 = parseElement(s0);
		if (!_v0.$) {
			var elementResult = _v0.a;
			var s1 = _v0.b;
			var _v1 = A3($lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsRightToLeftStackUnsafeHelp, element, reduce, s1);
			if (!_v1.$) {
				var tailFolded = _v1.a;
				var s2 = _v1.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A2(reduce, elementResult, tailFolded),
					s2);
			} else {
				var tailBad = _v1;
				var tailCommitted = tailBad.a;
				return tailCommitted ? tailBad : A2($lue_bird$elm_syntax_format$ParserFast$Good, elementResult, s1);
			}
		} else {
			var elementCommitted = _v0.a;
			var x = _v0.b;
			return A2($lue_bird$elm_syntax_format$ParserFast$Bad, elementCommitted, x);
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsOntoResultFromParserRightToLeftStackUnsafe = F3(
	function (_v0, taiElement, reduce) {
		var parseLeftestElement = _v0;
		return function (s0) {
			var _v1 = parseLeftestElement(s0);
			if (!_v1.$) {
				var elementResult = _v1.a;
				var s1 = _v1.b;
				var _v2 = A3($lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsRightToLeftStackUnsafeHelp, taiElement, reduce, s1);
				if (!_v2.$) {
					var tailFolded = _v2.a;
					var s2 = _v2.b;
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						A2(reduce, elementResult, tailFolded),
						s2);
				} else {
					var tailBad = _v2;
					var tailCommitted = tailBad.a;
					return tailCommitted ? tailBad : A2($lue_bird$elm_syntax_format$ParserFast$Good, elementResult, s1);
				}
			} else {
				var elementCommitted = _v1.a;
				var x = _v1.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, elementCommitted, x);
			}
		};
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$HexPattern = function (a) {
	return {$: 5, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Pattern$IntPattern = function (a) {
	return {$: 4, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$integerDecimalOrHexadecimalMapWithRange = F2(
	function (rangeAndIntDecimalToRes, rangeAndIntHexadecimalToRes) {
		return function (s0) {
			var s1 = A2($lue_bird$elm_syntax_format$ParserFast$convertIntegerDecimalOrHexadecimal, s0.i, s0.g);
			if (_Utils_eq(s1.r.i, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var newColumn = s0.co + (s1.r.i - s0.i);
				var range = {
					cw: {cp: newColumn, c9: s0.c9},
					b9: {cp: s0.co, c9: s0.c9}
				};
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					function () {
						var _v0 = s1.J;
						if (!_v0) {
							return A2(rangeAndIntDecimalToRes, range, s1.r.cI);
						} else {
							return A2(rangeAndIntHexadecimalToRes, range, s1.r.cI);
						}
					}(),
					{co: newColumn, m: s0.m, i: s1.r.i, c9: s0.c9, g: s0.g});
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$numberPart = A2(
	$lue_bird$elm_syntax_format$ParserFast$integerDecimalOrHexadecimalMapWithRange,
	F2(
		function (range, n) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$IntPattern(n))
			};
		}),
	F2(
		function (range, n) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$HexPattern(n))
			};
		}));
var $lue_bird$elm_syntax_format$ParserFast$oneOf9 = F9(
	function (_v0, _v1, _v2, _v3, _v4, _v5, _v6, _v7, _v8) {
		var attempt0 = _v0;
		var attempt1 = _v1;
		var attempt2 = _v2;
		var attempt3 = _v3;
		var attempt4 = _v4;
		var attempt5 = _v5;
		var attempt6 = _v6;
		var attempt7 = _v7;
		var attempt8 = _v8;
		return function (s) {
			var _v9 = attempt0(s);
			if (!_v9.$) {
				var good = _v9;
				return good;
			} else {
				var bad0 = _v9;
				var committed0 = bad0.a;
				if (committed0) {
					return bad0;
				} else {
					var _v10 = attempt1(s);
					if (!_v10.$) {
						var good = _v10;
						return good;
					} else {
						var bad1 = _v10;
						var committed1 = bad1.a;
						if (committed1) {
							return bad1;
						} else {
							var _v11 = attempt2(s);
							if (!_v11.$) {
								var good = _v11;
								return good;
							} else {
								var bad2 = _v11;
								var committed2 = bad2.a;
								if (committed2) {
									return bad2;
								} else {
									var _v12 = attempt3(s);
									if (!_v12.$) {
										var good = _v12;
										return good;
									} else {
										var bad3 = _v12;
										var committed3 = bad3.a;
										if (committed3) {
											return bad3;
										} else {
											var _v13 = attempt4(s);
											if (!_v13.$) {
												var good = _v13;
												return good;
											} else {
												var bad4 = _v13;
												var committed4 = bad4.a;
												if (committed4) {
													return bad4;
												} else {
													var _v14 = attempt5(s);
													if (!_v14.$) {
														var good = _v14;
														return good;
													} else {
														var bad5 = _v14;
														var committed5 = bad5.a;
														if (committed5) {
															return bad5;
														} else {
															var _v15 = attempt6(s);
															if (!_v15.$) {
																var good = _v15;
																return good;
															} else {
																var bad6 = _v15;
																var committed6 = bad6.a;
																if (committed6) {
																	return bad6;
																} else {
																	var _v16 = attempt7(s);
																	if (!_v16.$) {
																		var good = _v16;
																		return good;
																	} else {
																		var bad7 = _v16;
																		var committed7 = bad7.a;
																		if (committed7) {
																			return bad7;
																		} else {
																			var _v17 = attempt8(s);
																			if (!_v17.$) {
																				var good = _v17;
																				return good;
																			} else {
																				var bad8 = _v17;
																				var committed8 = bad8.a;
																				return committed8 ? bad8 : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
																			}
																		}
																	}
																}
															}
														}
													}
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternListEmpty = $stil4m$elm_syntax$Elm$Syntax$Pattern$ListPattern(_List_Nil);
var $lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileWithoutLinebreak = F2(
	function (firstIsOkay, afterFirstIsOkay) {
		return function (s) {
			var firstOffset = A3($lue_bird$elm_syntax_format$ParserFast$isSubCharWithoutLinebreak, firstIsOkay, s.i, s.g);
			if (_Utils_eq(firstOffset, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileWithoutLinebreakHelp, afterFirstIsOkay, firstOffset, s.c9, s.co + 1, s.g, s.m);
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A3($elm$core$String$slice, s.i, s1.i, s.g),
					s1);
			}
		};
	});
var $lue_bird$elm_syntax_format$Char$Extra$unicodeIsUpperFast = function (c) {
	var code = $elm$core$Char$toCode(c);
	return $lue_bird$elm_syntax_format$Char$Extra$charCodeIsUpper(code) || function () {
		var cString = $elm$core$String$fromChar(c);
		return (_Utils_eq(
			$elm$core$String$toUpper(cString),
			cString) && (!_Utils_eq(
			$elm$core$String$toLower(cString),
			cString))) ? ((code <= 8543) || (((8560 <= code) && (code <= 9397)) || ((9424 <= code) && (code <= 983040)))) : ((code < 120015) ? ((code < 8509) ? (((978 <= code) && (code <= 980)) || ((code === 8450) || ((code === 8455) || (((8459 <= code) && (code <= 8461)) || (((8464 <= code) && (code <= 8466)) || ((code === 8469) || (((8473 <= code) && (code <= 8477)) || ((code === 8484) || ((code === 8488) || (((8490 <= code) && (code <= 8493)) || ((8496 <= code) && (code <= 8499)))))))))))) : (((8510 <= code) && (code <= 8511)) || ((code === 8517) || (((119808 <= code) && (code <= 119833)) || (((119860 <= code) && (code <= 119885)) || (((119912 <= code) && (code <= 119937)) || ((code === 119964) || (((119966 <= code) && (code <= 119967)) || ((code === 119970) || (((119973 <= code) && (code <= 119974)) || (((119977 <= code) && (code <= 119980)) || ((119982 <= code) && (code <= 119989))))))))))))) : ((code < 120223) ? (((120016 <= code) && (code <= 120041)) || (((120068 <= code) && (code <= 120069)) || (((120071 <= code) && (code <= 120074)) || (((120077 <= code) && (code <= 120084)) || (((120086 <= code) && (code <= 120092)) || (((120120 <= code) && (code <= 120121)) || (((120123 <= code) && (code <= 120126)) || (((120128 <= code) && (code <= 120132)) || ((code === 120134) || (((120138 <= code) && (code <= 120144)) || ((120172 <= code) && (code <= 120197)))))))))))) : (((120224 <= code) && (code <= 120249)) || (((120276 <= code) && (code <= 120301)) || (((120328 <= code) && (code <= 120353)) || (((120380 <= code) && (code <= 120405)) || (((120432 <= code) && (code <= 120457)) || (((120488 <= code) && (code <= 120512)) || (((120546 <= code) && (code <= 120570)) || (((120604 <= code) && (code <= 120628)) || (((120662 <= code) && (code <= 120686)) || (((120720 <= code) && (code <= 120744)) || (code === 120778)))))))))))));
	}();
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase = A2($lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileWithoutLinebreak, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsUpperFast, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast);
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotNamesUppercaseTuple() {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$map2OrSucceed,
		F2(
			function (firstName, afterFirstName) {
				if (afterFirstName.$ === 1) {
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(_List_Nil, firstName));
				} else {
					var _v1 = afterFirstName.a;
					var qualificationAfter = _v1.a;
					var unqualified = _v1.b;
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(
							A2($elm$core$List$cons, firstName, qualificationAfter),
							unqualified));
				}
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '.', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase),
		$lue_bird$elm_syntax_format$ParserFast$lazy(
			function (_v2) {
				return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotNamesUppercaseTuple();
			}),
		$elm$core$Maybe$Nothing);
}
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotNamesUppercaseTuple = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotNamesUppercaseTuple();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotNamesUppercaseTuple = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotNamesUppercaseTuple;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedNameRefNode = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, firstName, after) {
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				range,
				function () {
					if (after.$ === 1) {
						return {T: _List_Nil, aN: firstName};
					} else {
						var _v1 = after.a;
						var qualificationAfter = _v1.a;
						var unqualified = _v1.b;
						return {
							T: A2($elm$core$List$cons, firstName, qualificationAfter),
							aN: unqualified
						};
					}
				}());
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotNamesUppercaseTuple);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedPatternWithoutConsumeArgs = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, firstName, after) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					A2(
						$stil4m$elm_syntax$Elm$Syntax$Pattern$NamedPattern,
						function () {
							if (after.$ === 1) {
								return {T: _List_Nil, aN: firstName};
							} else {
								var _v1 = after.a;
								var qualificationAfter = _v1.a;
								var unqualified = _v1.b;
								return {
									T: A2($elm$core$List$cons, firstName, qualificationAfter),
									aN: unqualified
								};
							}
						}(),
						_List_Nil))
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotNamesUppercaseTuple);
var $stil4m$elm_syntax$Elm$Syntax$Pattern$RecordPattern = function (a) {
	return {$: 8, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordPattern = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, commentsBeforeElements, elements) {
			return {
				b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, elements.b, commentsBeforeElements),
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$RecordPattern(elements.a))
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '{', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'}',
			{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: _List_Nil}),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
			'}',
			A5(
				$lue_bird$elm_syntax_format$ParserFast$map4,
				F4(
					function (commentsBeforeHead, head, commentsAfterHead, tail) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								tail.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterHead, commentsBeforeHead)),
							a: A2($elm$core$List$cons, head, tail.a)
						};
					}),
				A2(
					$lue_bird$elm_syntax_format$ParserFast$orSucceed,
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
					A2(
						$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
						',',
						A5(
							$lue_bird$elm_syntax_format$ParserFast$map4,
							F4(
								function (commentsBeforeName, commentsWithExtraComma, name, afterName) {
									return {
										b: A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											afterName,
											A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBeforeName)),
										a: name
									};
								}),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
							A2(
								$lue_bird$elm_syntax_format$ParserFast$orSucceed,
								A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)))))));
var $stil4m$elm_syntax$Elm$Syntax$Pattern$StringPattern = function (a) {
	return {$: 3, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$stringPattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$singleOrTripleQuotedStringLiteralMapWithRange(
	F2(
		function (range, string) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$StringPattern(string))
			};
		}));
var $stil4m$elm_syntax$Elm$Syntax$Pattern$VarPattern = function (a) {
	return {$: 11, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileValidateMapWithRangeWithoutLinebreak = F4(
	function (toResult, firstIsOkay, afterFirstIsOkay, resultIsOkay) {
		return function (s0) {
			var firstOffset = A3($lue_bird$elm_syntax_format$ParserFast$isSubCharWithoutLinebreak, firstIsOkay, s0.i, s0.g);
			if (_Utils_eq(firstOffset, -1)) {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			} else {
				var s1 = A6($lue_bird$elm_syntax_format$ParserFast$skipWhileWithoutLinebreakHelp, afterFirstIsOkay, firstOffset, s0.c9, s0.co + 1, s0.g, s0.m);
				var name = A3($elm$core$String$slice, s0.i, s1.i, s0.g);
				return resultIsOkay(name) ? A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A2(
						toResult,
						{
							cw: {cp: s1.co, c9: s1.c9},
							b9: {cp: s0.co, c9: s0.c9}
						},
						name),
					s1) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isNotReserved = function (name) {
	switch (name) {
		case 'module':
			return false;
		case 'exposing':
			return false;
		case 'import':
			return false;
		case 'as':
			return false;
		case 'if':
			return false;
		case 'then':
			return false;
		case 'else':
			return false;
		case 'let':
			return false;
		case 'in':
			return false;
		case 'case':
			return false;
		case 'of':
			return false;
		case 'port':
			return false;
		case 'type':
			return false;
		case 'where':
			return false;
		default:
			return true;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseMapWithRange = function (rangeAndNameToResult) {
	return A4($lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileValidateMapWithRangeWithoutLinebreak, rangeAndNameToResult, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsLowerFast, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isNotReserved);
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$varPattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseMapWithRange(
	F2(
		function (range, _var) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$VarPattern(_var))
			};
		}));
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$composablePattern() {
	return A9(
		$lue_bird$elm_syntax_format$ParserFast$oneOf9,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$varPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$qualifiedPatternWithConsumeArgs(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$allPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensPattern(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$stringPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listPattern(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$numberPart,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charPattern);
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$qualifiedPatternWithConsumeArgs() {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$map3,
		F3(
			function (_v6, afterStartName, argsReverse) {
				var nameRange = _v6.a;
				var name = _v6.b;
				var range = function () {
					var _v7 = argsReverse.a;
					if (!_v7.b) {
						return nameRange;
					} else {
						var _v8 = _v7.a;
						var lastArgRange = _v8.a;
						return {cw: lastArgRange.cw, b9: nameRange.b9};
					}
				}();
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, argsReverse.b, afterStartName),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						range,
						A2(
							$stil4m$elm_syntax$Elm$Syntax$Pattern$NamedPattern,
							name,
							$elm$core$List$reverse(argsReverse.a)))
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedNameRefNode,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
			A3(
				$lue_bird$elm_syntax_format$ParserFast$map2,
				F2(
					function (arg, commentsAfterArg) {
						return {
							b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterArg, arg.b),
							a: arg.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$patternNotSpaceSeparated(),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$patternNotSpaceSeparated() {
	return A9(
		$lue_bird$elm_syntax_format$ParserFast$oneOf9,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$varPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedPatternWithoutConsumeArgs,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$allPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensPattern(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$stringPattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listPattern(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$numberPart,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charPattern);
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listPattern() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
		F3(
			function (range, commentsBeforeElements, maybeElements) {
				if (maybeElements.$ === 1) {
					return {
						b: commentsBeforeElements,
						a: A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternListEmpty)
					};
				} else {
					var elements = maybeElements.a;
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, elements.b, commentsBeforeElements),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							range,
							$stil4m$elm_syntax$Elm$Syntax$Pattern$ListPattern(elements.a))
					};
				}
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '[', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2,
			A2($lue_bird$elm_syntax_format$ParserFast$symbol, ']', $elm$core$Maybe$Nothing),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
				']',
				A5(
					$lue_bird$elm_syntax_format$ParserFast$map4,
					F4(
						function (commentsBeforeHead, head, commentsAfterHead, tail) {
							return $elm$core$Maybe$Just(
								{
									b: A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										commentsAfterHead,
										A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											tail.b,
											A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, head.b, commentsBeforeHead))),
									a: A2($elm$core$List$cons, head.a, tail.a)
								});
						}),
					A2(
						$lue_bird$elm_syntax_format$ParserFast$orSucceed,
						A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern(),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
							',',
							A5(
								$lue_bird$elm_syntax_format$ParserFast$map4,
								F4(
									function (commentsBefore, commentsWithExtraComma, v, commentsAfter) {
										return {
											b: A2(
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
												commentsAfter,
												A2(
													$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
													v.b,
													A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBefore))),
											a: v.a
										};
									}),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
								A2(
									$lue_bird$elm_syntax_format$ParserFast$orSucceed,
									A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern(),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)))))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensPattern() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'(',
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
			F3(
				function (range, commentsBeforeHead, contentResult) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, contentResult.b, commentsBeforeHead),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{
								cw: range.cw,
								b9: {cp: range.b9.cp - 1, c9: range.b9.c9}
							},
							contentResult.a)
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbol,
					')',
					{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $stil4m$elm_syntax$Elm$Syntax$Pattern$UnitPattern}),
				A4(
					$lue_bird$elm_syntax_format$ParserFast$map3,
					F3(
						function (headResult, commentsAfterHead, tailResult) {
							return {
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									tailResult.b,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterHead, headResult.b)),
								a: function () {
									var _v3 = tailResult.a;
									if (_v3.$ === 1) {
										return $stil4m$elm_syntax$Elm$Syntax$Pattern$ParenthesizedPattern(headResult.a);
									} else {
										var secondAndMaybeThirdPart = _v3.a;
										var _v4 = secondAndMaybeThirdPart.bx;
										if (_v4.$ === 1) {
											return $stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
												_List_fromArray(
													[headResult.a, secondAndMaybeThirdPart.aR]));
										} else {
											var thirdPart = _v4.a;
											return $stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
												_List_fromArray(
													[headResult.a, secondAndMaybeThirdPart.aR, thirdPart]));
										}
									}
								}()
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern(),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					A2(
						$lue_bird$elm_syntax_format$ParserFast$oneOf2,
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbol,
							')',
							{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
							',',
							A5(
								$lue_bird$elm_syntax_format$ParserFast$map4,
								F4(
									function (commentsBefore, secondPart, commentsAfter, maybeThirdPart) {
										return {
											b: A2(
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
												maybeThirdPart.b,
												A2(
													$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
													commentsAfter,
													A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, secondPart.b, commentsBefore))),
											a: $elm$core$Maybe$Just(
												{bx: maybeThirdPart.a, aR: secondPart.a})
										};
									}),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern(),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
								A2(
									$lue_bird$elm_syntax_format$ParserFast$oneOf2,
									A2(
										$lue_bird$elm_syntax_format$ParserFast$symbol,
										')',
										{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
									A2(
										$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
										',',
										A2(
											$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
											')',
											A4(
												$lue_bird$elm_syntax_format$ParserFast$map3,
												F3(
													function (commentsBefore, thirdPart, commentsAfter) {
														return {
															b: A2(
																$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
																commentsAfter,
																A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, thirdPart.b, commentsBefore)),
															a: $elm$core$Maybe$Just(thirdPart.a)
														};
													}),
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern(),
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)))))))))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (leftMaybeConsed, maybeAsExtension) {
				if (maybeAsExtension.$ === 1) {
					return leftMaybeConsed;
				} else {
					var asExtension = maybeAsExtension.a;
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, asExtension.b, leftMaybeConsed.b),
						a: A3($stil4m$elm_syntax$Elm$Syntax$Node$combine, $stil4m$elm_syntax$Elm$Syntax$Pattern$AsPattern, leftMaybeConsed.a, asExtension.a)
					};
				}
			}),
		A3(
			$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsOntoResultFromParserRightToLeftStackUnsafe,
			A3(
				$lue_bird$elm_syntax_format$ParserFast$map2,
				F2(
					function (startPatternResult, commentsAfter) {
						return {
							b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, startPatternResult.b),
							a: startPatternResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ParserFast$lazy(
					function (_v1) {
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$composablePattern();
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
				'::',
				A4(
					$lue_bird$elm_syntax_format$ParserFast$map3,
					F3(
						function (commentsAfterCons, patternResult, commentsAfterTailSubPattern) {
							return {
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfterTailSubPattern,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, patternResult.b, commentsAfterCons)),
								a: patternResult.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					$lue_bird$elm_syntax_format$ParserFast$lazy(
						function (_v2) {
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$composablePattern();
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
			F2(
				function (consed, afterCons) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, afterCons.b, consed.b),
						a: A3($stil4m$elm_syntax$Elm$Syntax$Node$combine, $stil4m$elm_syntax$Elm$Syntax$Pattern$UnConsPattern, consed.a, afterCons.a)
					};
				})),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$orSucceed,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy,
				'as',
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (commentsAfterAs, name) {
							return $elm$core$Maybe$Just(
								{b: commentsAfterAs, a: name});
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords)),
			$elm$core$Maybe$Nothing));
}
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$composablePattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$composablePattern();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$composablePattern = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$composablePattern;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedPatternWithConsumeArgs = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$qualifiedPatternWithConsumeArgs();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$qualifiedPatternWithConsumeArgs = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedPatternWithConsumeArgs;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternNotSpaceSeparated = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$patternNotSpaceSeparated();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$patternNotSpaceSeparated = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternNotSpaceSeparated;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listPattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listPattern();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listPattern = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listPattern;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parensPattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensPattern();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensPattern = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parensPattern;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$pattern = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$pattern = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$pattern;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$untilWithComments = F2(
	function (end, element) {
		return A5(
			$lue_bird$elm_syntax_format$ParserFast$loopUntil,
			end,
			element,
			_Utils_Tuple2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, _List_Nil),
			F2(
				function (pResult, _v0) {
					var commentsSoFar = _v0.a;
					var itemsSoFar = _v0.b;
					return _Utils_Tuple2(
						A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, pResult.b, commentsSoFar),
						A2($elm$core$List$cons, pResult.a, itemsSoFar));
				}),
			function (_v1) {
				var commentsSoFar = _v1.a;
				var itemsSoFar = _v1.b;
				return {
					b: commentsSoFar,
					a: $elm$core$List$reverse(itemsSoFar)
				};
			});
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual = A2(
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$untilWithComments,
	A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		A2($lue_bird$elm_syntax_format$ParserFast$symbol, '=', 0),
		A2($lue_bird$elm_syntax_format$ParserFast$symbol, '->', 0)),
	A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (patternResult, commentsAfterPattern) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterPattern, patternResult.b),
					a: patternResult.a
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternNotSpaceSeparated,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments));
var $elm$core$Basics$composeL = F3(
	function (g, f, x) {
		return g(
			f(x));
	});
var $elm$core$List$all = F2(
	function (isOkay, list) {
		return !A2(
			$elm$core$List$any,
			A2($elm$core$Basics$composeL, $elm$core$Basics$not, isOkay),
			list);
	});
var $lue_bird$elm_syntax_format$ParserFast$columnIndentAndThen = function (callback) {
	return function (s) {
		var _v0 = A2(callback, s.co, s.m);
		var parse = _v0;
		return parse(s);
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$positivelyIndentedFollowedBy = function (nextParser) {
	return $lue_bird$elm_syntax_format$ParserFast$columnIndentAndThen(
		F2(
			function (column, indent) {
				return ((column > 1) && A2(
					$elm$core$List$all,
					function (nestedIndent) {
						return !_Utils_eq(column, nestedIndent);
					},
					indent)) ? nextParser : $lue_bird$elm_syntax_format$ParserFast$problem;
			}));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseUnderscoreSuffixingKeywords = A3($lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithoutLinebreak, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifKeywordUnderscoreSuffix, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsLowerFast, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast);
var $lue_bird$elm_syntax_format$ParserFast$oneOf2Map = F4(
	function (firstToChoice, _v0, secondToChoice, _v1) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		return function (s) {
			var _v2 = attemptFirst(s);
			if (!_v2.$) {
				var first = _v2.a;
				var s1 = _v2.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					firstToChoice(first),
					s1);
			} else {
				var firstCommitted = _v2.a;
				var firstX = _v2.b;
				if (firstCommitted) {
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, firstCommitted, firstX);
				} else {
					var _v3 = attemptSecond(s);
					if (!_v3.$) {
						var second = _v3.a;
						var s1 = _v3.b;
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							secondToChoice(second),
							s1);
					} else {
						var secondCommitted = _v3.a;
						var secondX = _v3.b;
						return secondCommitted ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, secondCommitted, secondX) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
					}
				}
			}
		};
	});
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotReferenceExpressionTuple() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$orSucceed,
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'.',
			A4(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2Map,
				$elm$core$Maybe$Just,
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (firstName, after) {
							if (after.$ === 1) {
								return _Utils_Tuple2(_List_Nil, firstName);
							} else {
								var _v1 = after.a;
								var qualificationAfter = _v1.a;
								var unqualified = _v1.b;
								return _Utils_Tuple2(
									A2($elm$core$List$cons, firstName, qualificationAfter),
									unqualified);
							}
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
					$lue_bird$elm_syntax_format$ParserFast$lazy(
						function (_v2) {
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotReferenceExpressionTuple();
						})),
				function (name) {
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(_List_Nil, name));
				},
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseUnderscoreSuffixingKeywords)),
		$elm$core$Maybe$Nothing);
}
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotReferenceExpressionTuple = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotReferenceExpressionTuple();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$maybeDotReferenceExpressionTuple = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotReferenceExpressionTuple;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedOrVariantOrRecordConstructorReferenceExpressionFollowedByRecordAccess = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiRecordAccess(
	A3(
		$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
		F3(
			function (range, firstName, after) {
				return {
					b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						range,
						function () {
							if (after.$ === 1) {
								return A2($stil4m$elm_syntax$Elm$Syntax$Expression$FunctionOrValue, _List_Nil, firstName);
							} else {
								var _v1 = after.a;
								var qualificationAfter = _v1.a;
								var unqualified = _v1.b;
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Expression$FunctionOrValue,
									A2($elm$core$List$cons, firstName, qualificationAfter),
									unqualified);
							}
						}())
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotReferenceExpressionTuple));
var $stil4m$elm_syntax$Elm$Syntax$Node$range = function (_v0) {
	var r = _v0.a;
	return r;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$rangeMoveStartLeftByOneColumn = function (range) {
	return {
		cw: range.cw,
		b9: {cp: range.b9.cp - 1, c9: range.b9.c9}
	};
};
var $stil4m$elm_syntax$Elm$Syntax$Expression$RecordAccessFunction = function (a) {
	return {$: 21, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordAccessFunctionExpression = A2(
	$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
	'.',
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseMapWithRange(
		F2(
			function (range, field) {
				return {
					b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$rangeMoveStartLeftByOneColumn(range),
						$stil4m$elm_syntax$Elm$Syntax$Expression$RecordAccessFunction('.' + field))
				};
			})));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$unqualifiedFunctionReferenceExpressionFollowedByRecordAccess = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiRecordAccess(
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseMapWithRange(
		F2(
			function (range, unqualified) {
				return {
					b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						range,
						A2($stil4m$elm_syntax$Elm$Syntax$Expression$FunctionOrValue, _List_Nil, unqualified))
				};
			})));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$referenceOrNumberExpression = A3($lue_bird$elm_syntax_format$ParserFast$oneOf3, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedOrVariantOrRecordConstructorReferenceExpressionFollowedByRecordAccess, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$unqualifiedFunctionReferenceExpressionFollowedByRecordAccess, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$numberExpression);
var $lue_bird$elm_syntax_format$ParserFast$symbolBacktrackableFollowedBy = F2(
	function (str, _v0) {
		var parseNext = _v0;
		var strLength = $elm$core$String$length(str);
		return function (s) {
			var newOffset = s.i + strLength;
			return _Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				str) ? parseNext(
				{co: s.co + strLength, m: s.m, i: newOffset, c9: s.c9, g: s.g}) : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$symbolWithEndLocation = F2(
	function (str, endLocationToRes) {
		var strLength = $elm$core$String$length(str);
		return function (s) {
			var newOffset = s.i + strLength;
			if (_Utils_eq(
				A3($elm$core$String$slice, s.i, newOffset, s.g),
				str)) {
				var newCol = s.co + strLength;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					endLocationToRes(
						{cp: newCol, c9: s.c9}),
					{co: newCol, m: s.m, i: newOffset, c9: s.c9, g: s.g});
			} else {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy = function (nextParser) {
	return $lue_bird$elm_syntax_format$ParserFast$columnIndentAndThen(
		F2(
			function (column, indent) {
				if (!indent.b) {
					return (column === 1) ? nextParser : $lue_bird$elm_syntax_format$ParserFast$problem;
				} else {
					var highestIndent = indent.a;
					return (!(column - highestIndent)) ? nextParser : $lue_bird$elm_syntax_format$ParserFast$problem;
				}
			}));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FieldsAfterName = function (a) {
	return {$: 1, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$FunctionTypeAnnotation = F2(
	function (a, b) {
		return {$: 6, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$GenericRecord = F2(
	function (a, b) {
		return {$: 5, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Record = function (a) {
	return {$: 4, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RecordExtensionExpressionAfterName = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Tupled = function (a) {
	return {$: 3, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Typed = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Unit = {$: 2};
var $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$GenericType = function (a) {
	return {$: 0, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$genericTypeAnnotation = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseMapWithRange(
	F2(
		function (range, _var) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$GenericType(_var))
			};
		}));
var $lue_bird$elm_syntax_format$ParserFast$map5WithRange = F6(
	function (func, _v0, _v1, _v2, _v3, _v4) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		return function (s0) {
			var _v5 = parseA(s0);
			if (_v5.$ === 1) {
				var committed = _v5.a;
				var x = _v5.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v5.a;
				var s1 = _v5.b;
				var _v6 = parseB(s1);
				if (_v6.$ === 1) {
					var x = _v6.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v6.a;
					var s2 = _v6.b;
					var _v7 = parseC(s2);
					if (_v7.$ === 1) {
						var x = _v7.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v7.a;
						var s3 = _v7.b;
						var _v8 = parseD(s3);
						if (_v8.$ === 1) {
							var x = _v8.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v8.a;
							var s4 = _v8.b;
							var _v9 = parseE(s4);
							if (_v9.$ === 1) {
								var x = _v9.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v9.a;
								var s5 = _v9.b;
								return A2(
									$lue_bird$elm_syntax_format$ParserFast$Good,
									A6(
										func,
										{
											cw: {cp: s5.co, c9: s5.c9},
											b9: {cp: s0.co, c9: s0.c9}
										},
										a,
										b,
										c,
										d,
										e),
									s5);
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$oneOf4 = F4(
	function (_v0, _v1, _v2, _v3) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		var attemptThird = _v2;
		var attemptFourth = _v3;
		return function (s) {
			var _v4 = attemptFirst(s);
			if (!_v4.$) {
				var firstGood = _v4;
				return firstGood;
			} else {
				var firstBad = _v4;
				var firstCommitted = firstBad.a;
				if (firstCommitted) {
					return firstBad;
				} else {
					var _v5 = attemptSecond(s);
					if (!_v5.$) {
						var secondGood = _v5;
						return secondGood;
					} else {
						var secondBad = _v5;
						var secondCommitted = secondBad.a;
						if (secondCommitted) {
							return secondBad;
						} else {
							var _v6 = attemptThird(s);
							if (!_v6.$) {
								var thirdGood = _v6;
								return thirdGood;
							} else {
								var thirdBad = _v6;
								var thirdCommitted = thirdBad.a;
								if (thirdCommitted) {
									return thirdBad;
								} else {
									var _v7 = attemptFourth(s);
									if (!_v7.$) {
										var fourthGood = _v7;
										return fourthGood;
									} else {
										var fourthBad = _v7;
										var fourthCommitted = fourthBad.a;
										return fourthCommitted ? fourthBad : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAnnotationRecordEmpty = $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Record(_List_Nil);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typedTypeAnnotationWithoutArguments = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, startName, afterStartName) {
			var name = function () {
				if (afterStartName.$ === 1) {
					return _Utils_Tuple2(_List_Nil, startName);
				} else {
					var _v1 = afterStartName.a;
					var qualificationAfterStartName = _v1.a;
					var unqualified = _v1.b;
					return _Utils_Tuple2(
						A2($elm$core$List$cons, startName, qualificationAfterStartName),
						unqualified);
				}
			}();
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					A2(
						$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Typed,
						A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, name),
						_List_Nil))
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotNamesUppercaseTuple);
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeAnnotationNotFunction() {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$oneOf4,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensTypeAnnotation(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typedTypeAnnotationWithArgumentsFollowedByWhitespaceAndComments(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$genericTypeAnnotation,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordTypeAnnotation());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typedTypeAnnotationWithArgumentsFollowedByWhitespaceAndComments() {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$map3,
		F3(
			function (nameNode, commentsAfterName, argsReverse) {
				var _v7 = nameNode;
				var nameRange = _v7.a;
				var range = function () {
					var _v8 = argsReverse.a;
					if (!_v8.b) {
						return nameRange;
					} else {
						var _v9 = _v8.a;
						var lastArgRange = _v9.a;
						return {cw: lastArgRange.cw, b9: nameRange.b9};
					}
				}();
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, argsReverse.b, commentsAfterName),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						range,
						A2(
							$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Typed,
							nameNode,
							$elm$core$List$reverse(argsReverse.a)))
				};
			}),
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
			F3(
				function (range, startName, afterStartName) {
					var name = function () {
						if (afterStartName.$ === 1) {
							return _Utils_Tuple2(_List_Nil, startName);
						} else {
							var _v11 = afterStartName.a;
							var qualificationAfterStartName = _v11.a;
							var unqualified = _v11.b;
							return _Utils_Tuple2(
								A2($elm$core$List$cons, startName, qualificationAfterStartName),
								unqualified);
						}
					}();
					return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, name);
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$maybeDotNamesUppercaseTuple),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$positivelyIndentedFollowedBy(
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (typeAnnotationResult, commentsAfter) {
							return {
								b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, typeAnnotationResult.b),
								a: typeAnnotationResult.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeNotSpaceSeparated(),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeNotSpaceSeparated() {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$oneOf4,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensTypeAnnotation(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typedTypeAnnotationWithoutArguments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$genericTypeAnnotation,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordTypeAnnotation());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensTypeAnnotation() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'(',
		A2(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolWithEndLocation,
				')',
				function (end) {
					return {
						b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{
								cw: end,
								b9: {cp: end.cp - 2, c9: end.c9}
							},
							$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Unit)
					};
				}),
			A5(
				$lue_bird$elm_syntax_format$ParserFast$map4WithRange,
				F5(
					function (rangeAfterOpeningParens, commentsBeforeFirstPart, firstPart, commentsAfterFirstPart, lastToSecondPart) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								lastToSecondPart.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfterFirstPart,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, firstPart.b, commentsBeforeFirstPart))),
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{
									cw: rangeAfterOpeningParens.cw,
									b9: {cp: rangeAfterOpeningParens.b9.cp - 1, c9: rangeAfterOpeningParens.b9.c9}
								},
								function () {
									var _v4 = lastToSecondPart.a;
									if (_v4.$ === 1) {
										var _v5 = firstPart.a;
										var firstPartType = _v5.b;
										return firstPartType;
									} else {
										var firstAndMaybeThirdPart = _v4.a;
										var _v6 = firstAndMaybeThirdPart.bx;
										if (_v6.$ === 1) {
											return $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Tupled(
												_List_fromArray(
													[firstPart.a, firstAndMaybeThirdPart.aR]));
										} else {
											var thirdPart = _v6.a;
											return $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Tupled(
												_List_fromArray(
													[firstPart.a, firstAndMaybeThirdPart.aR, thirdPart]));
										}
									}
								}())
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_(),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$oneOf2,
					A2(
						$lue_bird$elm_syntax_format$ParserFast$symbol,
						')',
						{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
					A2(
						$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
						',',
						A5(
							$lue_bird$elm_syntax_format$ParserFast$map4,
							F4(
								function (commentsBefore, secondPartResult, commentsAfter, maybeThirdPartResult) {
									return {
										b: A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											commentsAfter,
											A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, secondPartResult.b, commentsBefore)),
										a: $elm$core$Maybe$Just(
											{bx: maybeThirdPartResult.a, aR: secondPartResult.a})
									};
								}),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_(),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
							A2(
								$lue_bird$elm_syntax_format$ParserFast$oneOf2,
								A2(
									$lue_bird$elm_syntax_format$ParserFast$symbol,
									')',
									{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
								A2(
									$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
									',',
									A2(
										$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
										')',
										A4(
											$lue_bird$elm_syntax_format$ParserFast$map3,
											F3(
												function (commentsBefore, thirdPartResult, commentsAfter) {
													return {
														b: A2(
															$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
															commentsAfter,
															A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, thirdPartResult.b, commentsBefore)),
														a: $elm$core$Maybe$Just(thirdPartResult.a)
													};
												}),
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_(),
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))))))))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordTypeAnnotation() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
		F3(
			function (range, commentsBefore, afterCurly) {
				if (afterCurly.$ === 1) {
					return {
						b: commentsBefore,
						a: A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAnnotationRecordEmpty)
					};
				} else {
					var afterCurlyResult = afterCurly.a;
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, afterCurlyResult.b, commentsBefore),
						a: A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, afterCurlyResult.a)
					};
				}
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '{', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2,
			A2($lue_bird$elm_syntax_format$ParserFast$symbol, '}', $elm$core$Maybe$Nothing),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
				'}',
				A5(
					$lue_bird$elm_syntax_format$ParserFast$map4,
					F4(
						function (commentsBeforeFirstName, firstNameNode, commentsAfterFirstName, afterFirstName) {
							return $elm$core$Maybe$Just(
								{
									b: A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										afterFirstName.b,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterFirstName, commentsBeforeFirstName)),
									a: function () {
										var _v3 = afterFirstName.a;
										if (!_v3.$) {
											var fields = _v3.a;
											return A2($stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$GenericRecord, firstNameNode, fields);
										} else {
											var fieldsAfterName = _v3.a;
											return $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Record(
												A2(
													$elm$core$List$cons,
													A3($stil4m$elm_syntax$Elm$Syntax$Node$combine, $elm$core$Tuple$pair, firstNameNode, fieldsAfterName.cy),
													fieldsAfterName.$7));
										}
									}()
								});
						}),
					A2(
						$lue_bird$elm_syntax_format$ParserFast$orSucceed,
						A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					A2(
						$lue_bird$elm_syntax_format$ParserFast$oneOf2,
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
							'|',
							A4(
								$lue_bird$elm_syntax_format$ParserFast$map3WithRange,
								F4(
									function (range, commentsBefore, head, tail) {
										return {
											b: A2(
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
												tail.b,
												A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, head.b, commentsBefore)),
											a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RecordExtensionExpressionAfterName(
												A2(
													$stil4m$elm_syntax$Elm$Syntax$Node$Node,
													range,
													A2($elm$core$List$cons, head.a, tail.a)))
										};
									}),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments(),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
									A2(
										$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
										',',
										A4(
											$lue_bird$elm_syntax_format$ParserFast$map3,
											F3(
												function (commentsBefore, commentsWithExtraComma, field) {
													return {
														b: A2(
															$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
															field.b,
															A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBefore)),
														a: field.a
													};
												}),
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
											A2(
												$lue_bird$elm_syntax_format$ParserFast$orSucceed,
												A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments()))))),
						A5(
							$lue_bird$elm_syntax_format$ParserFast$map4,
							F4(
								function (commentsBeforeFirstFieldValue, firstFieldValue, commentsAfterFirstFieldValue, tailFields) {
									return {
										b: A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											tailFields.b,
											A2(
												$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
												commentsAfterFirstFieldValue,
												A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, firstFieldValue.b, commentsBeforeFirstFieldValue))),
										a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FieldsAfterName(
											{cy: firstFieldValue.a, $7: tailFields.a})
									};
								}),
							A3(
								$lue_bird$elm_syntax_format$ParserFast$oneOf2OrSucceed,
								A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
								A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_(),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
							A2(
								$lue_bird$elm_syntax_format$ParserFast$orSucceed,
								A2(
									$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
									',',
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFieldsTypeAnnotation()),
								{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: _List_Nil})))))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFieldsTypeAnnotation() {
	return A5(
		$lue_bird$elm_syntax_format$ParserFast$map4,
		F4(
			function (commentsBefore, commentsWithExtraComma, head, tail) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						tail.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							head.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsBefore, commentsWithExtraComma))),
					a: A2($elm$core$List$cons, head.a, tail.a)
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A2(
			$lue_bird$elm_syntax_format$ParserFast$orSucceed,
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
				',',
				A4(
					$lue_bird$elm_syntax_format$ParserFast$map3,
					F3(
						function (commentsBefore, commentsWithExtraComma, field) {
							return {
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									field.b,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBefore)),
								a: field.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					A2(
						$lue_bird$elm_syntax_format$ParserFast$orSucceed,
						A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments()))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments() {
	return A6(
		$lue_bird$elm_syntax_format$ParserFast$map5WithRange,
		F6(
			function (range, name, commentsAfterName, commentsAfterColon, value, commentsAfterValue) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						commentsAfterValue,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							value.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterColon, commentsAfterName))),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						range,
						_Utils_Tuple2(name, value.a))
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A3(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2OrSucceed,
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments);
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsOntoResultFromParserRightToLeftStackUnsafe,
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2,
			F2(
				function (startType, commentsAfter) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, startType.b),
						a: startType.a
					};
				}),
			$lue_bird$elm_syntax_format$ParserFast$lazy(
				function (_v0) {
					return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeAnnotationNotFunction();
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'->',
			A5(
				$lue_bird$elm_syntax_format$ParserFast$map4,
				F4(
					function (commentsAfterArrow, commentsWithExtraArrow, typeAnnotationResult, commentsAfterType) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterType,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									typeAnnotationResult.b,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraArrow, commentsAfterArrow))),
							a: typeAnnotationResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$orSucceed,
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '->', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
				$lue_bird$elm_syntax_format$ParserFast$lazy(
					function (_v1) {
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeAnnotationNotFunction();
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
		F2(
			function (inType, outType) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, outType.b, inType.b),
					a: A3($stil4m$elm_syntax$Elm$Syntax$Node$combine, $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$FunctionTypeAnnotation, inType.a, outType.a)
				};
			}));
}
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAnnotationNotFunction = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeAnnotationNotFunction();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeAnnotationNotFunction = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAnnotationNotFunction;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typedTypeAnnotationWithArgumentsFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typedTypeAnnotationWithArgumentsFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typedTypeAnnotationWithArgumentsFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typedTypeAnnotationWithArgumentsFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeNotSpaceSeparated = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeNotSpaceSeparated();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeNotSpaceSeparated = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeNotSpaceSeparated;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parensTypeAnnotation = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensTypeAnnotation();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$parensTypeAnnotation = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parensTypeAnnotation;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordTypeAnnotation = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordTypeAnnotation();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordTypeAnnotation = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordTypeAnnotation;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordFieldsTypeAnnotation = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFieldsTypeAnnotation();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFieldsTypeAnnotation = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordFieldsTypeAnnotation;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeRecordFieldDefinitionFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$typeRecordFieldDefinitionFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeRecordFieldDefinitionFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_ = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$type_ = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_;
};
var $lue_bird$elm_syntax_format$ParserFast$validate = F2(
	function (isOkay, _v0) {
		var parseA = _v0;
		return function (s0) {
			var _v1 = parseA(s0);
			if (_v1.$ === 1) {
				var committed = _v1.a;
				var x = _v1.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var good = _v1;
				var a = good.a;
				return isOkay(a) ? good : $lue_bird$elm_syntax_format$ParserFast$pStepBadCommitting;
			}
		};
	});
var $stil4m$elm_syntax$Elm$Syntax$Node$value = function (_v0) {
	var v = _v0.b;
	return v;
};
var $lue_bird$elm_syntax_format$ParserFast$whileAtMost3WithoutLinebreakAnd2PartUtf16ToResultAndThen = F3(
	function (charAsStringIsOkay, consumedStringToIntermediateOrErr, intermediateToFollowupParser) {
		return function (s0) {
			var src = s0.g;
			var s0Offset = s0.i;
			var consumed = charAsStringIsOkay(
				A3($elm$core$String$slice, s0Offset, s0Offset + 1, src)) ? (charAsStringIsOkay(
				A3($elm$core$String$slice, s0Offset + 1, s0Offset + 2, src)) ? (charAsStringIsOkay(
				A3($elm$core$String$slice, s0Offset + 2, s0Offset + 3, src)) ? {
				w: 3,
				a5: A3($elm$core$String$slice, s0Offset, s0Offset + 3, src)
			} : {
				w: 2,
				a5: A3($elm$core$String$slice, s0Offset, s0Offset + 2, src)
			}) : {
				w: 1,
				a5: A3($elm$core$String$slice, s0Offset, s0Offset + 1, src)
			}) : {w: 0, a5: ''};
			var _v0 = consumedStringToIntermediateOrErr(consumed.a5);
			if (!_v0.$) {
				var intermediate = _v0.a;
				var _v1 = intermediateToFollowupParser(intermediate);
				var parseFollowup = _v1;
				return $lue_bird$elm_syntax_format$ParserFast$pStepCommit(
					parseFollowup(
						{co: s0.co + consumed.w, m: s0.m, i: s0Offset + consumed.w, c9: s0.c9, g: src}));
			} else {
				return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$validateEndColumnIndentation = F2(
	function (isOkay, _v0) {
		var parse = _v0;
		return function (s0) {
			var _v1 = parse(s0);
			if (!_v1.$) {
				var good = _v1;
				var s1 = good.b;
				return A2(isOkay, s1.co, s1.m) ? good : $lue_bird$elm_syntax_format$ParserFast$pStepBadCommitting;
			} else {
				var bad = _v1;
				return bad;
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$endsTopIndented = function (parser) {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$validateEndColumnIndentation,
		F2(
			function (column, indent) {
				if (!indent.b) {
					return column === 1;
				} else {
					var highestIndent = indent.a;
					return !(column - highestIndent);
				}
			}),
		parser);
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndented = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$endsTopIndented($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedBy = function (nextParser) {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (commentsBefore, after) {
				return {b: commentsBefore, a: after};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(nextParser));
};
var $lue_bird$elm_syntax_format$ParserFast$changeIndent = F2(
	function (newIndent, s) {
		return {
			co: s.co,
			m: newIndent(s.m),
			i: s.i,
			c9: s.c9,
			g: s.g
		};
	});
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
var $lue_bird$elm_syntax_format$ParserFast$withIndentSetToColumn = function (_v0) {
	var parse = _v0;
	return function (s0) {
		var _v1 = parse(
			A2(
				$lue_bird$elm_syntax_format$ParserFast$changeIndent,
				function (indent) {
					return A2($elm$core$List$cons, s0.co, indent);
				},
				s0));
		if (!_v1.$) {
			var a = _v1.a;
			var s1 = _v1.b;
			return A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				a,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$changeIndent,
					function (indent) {
						return A2($elm$core$List$drop, 1, indent);
					},
					s1));
		} else {
			var bad = _v1;
			return bad;
		}
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extendedSubExpressionFollowedByWhitespaceAndComments = function (info) {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsOntoResultFromParser,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixOperatorAndThen(info),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpressionMaybeAppliedFollowedByWhitespaceAndComments(),
		F2(
			function (extensionRightResult, leftNodeWithComments) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, extensionRightResult.b, leftNodeWithComments.b),
					a: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$applyExtensionRight, extensionRightResult.a, leftNodeWithComments.a)
				};
			}),
		$elm$core$Basics$identity);
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extensionRightParser = function (extensionRightInfo) {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (commentsBefore, right) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, right.b, commentsBefore),
					a: {aw: extensionRightInfo.aw, u: right.a, ad: extensionRightInfo.ad}
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ParserFast$lazy(
			function (_v8) {
				return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extendedSubExpressionFollowedByWhitespaceAndComments(extensionRightInfo);
			}));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication = function (appliedExpressionParser) {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$map3,
		F3(
			function (leftExpressionResult, commentsBeforeExtension, maybeArgsReverse) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						maybeArgsReverse.b,
						A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsBeforeExtension, leftExpressionResult.b)),
					a: function () {
						var _v5 = maybeArgsReverse.a;
						if (!_v5.b) {
							return leftExpressionResult.a;
						} else {
							var _v6 = _v5.a;
							var lastArgRange = _v6.a;
							var _v7 = leftExpressionResult.a;
							var leftRange = _v7.a;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: lastArgRange.cw, b9: leftRange.b9},
								$stil4m$elm_syntax$Elm$Syntax$Expression$Application(
									A2(
										$elm$core$List$cons,
										leftExpressionResult.a,
										$elm$core$List$reverse(maybeArgsReverse.a))));
						}
					}()
				};
			}),
		appliedExpressionParser,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$positivelyIndentedFollowedBy(
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (arg, commentsAfter) {
							return {
								b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, arg.b),
								a: arg.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpression(),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft = F2(
	function (leftPrecedence, symbol) {
		return {
			am: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extensionRightParser(
				{
					aW: function ($) {
						return $.am;
					},
					aw: 0,
					ad: symbol,
					ba: function (rightInfo) {
						return (_Utils_cmp(rightInfo.an, leftPrecedence) > 0) ? $elm$core$Maybe$Just(rightInfo) : $elm$core$Maybe$Nothing;
					}
				}),
			an: leftPrecedence,
			ad: symbol
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative = F2(
	function (leftPrecedence, symbol) {
		return {
			am: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extensionRightParser(
				{
					aW: function (rightInfo) {
						return _Utils_eq(rightInfo.an, leftPrecedence) ? $lue_bird$elm_syntax_format$ParserFast$problem : rightInfo.am;
					},
					aw: 2,
					ad: symbol,
					ba: function (rightInfo) {
						return (_Utils_cmp(rightInfo.an, leftPrecedence) > -1) ? $elm$core$Maybe$Just(rightInfo) : $elm$core$Maybe$Nothing;
					}
				}),
			an: leftPrecedence,
			ad: symbol
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixOperatorAndThen = function (extensionRightConstraints) {
	var toResult = extensionRightConstraints.ba;
	var subResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Sub());
	var slashResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Slash());
	var questionMarkResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8QuestionMark());
	var powResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8Pow());
	var orResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence2Or());
	var neqResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Neq());
	var mulResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Mul());
	var ltResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Lt());
	var leResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Le());
	var keepResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Keep());
	var ignoreResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Ignore());
	var idivResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Idiv());
	var gtResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Gt());
	var geResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Ge());
	var fdivResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Fdiv());
	var eqResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Eq());
	var consResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Cons());
	var composeRResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeR());
	var composeLResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeL());
	var appendResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5append());
	var apRResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApR());
	var apLResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApL());
	var andResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence3And());
	var addResult = toResult(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Add());
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$whileAtMost3WithoutLinebreakAnd2PartUtf16ToResultAndThen,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isOperatorSymbolCharAsString,
		function (operator) {
			switch (operator) {
				case '|>':
					return apRResult;
				case '|':
					return apRResult;
				case '++':
					return appendResult;
				case '<|':
					return apLResult;
				case '>>':
					return composeRResult;
				case '==':
					return eqResult;
				case '===':
					return eqResult;
				case '*':
					return mulResult;
				case '::':
					return consResult;
				case '+':
					return addResult;
				case '-':
					return subResult;
				case '|.':
					return ignoreResult;
				case '&&':
					return andResult;
				case '|=':
					return keepResult;
				case '<<':
					return composeLResult;
				case '/=':
					return neqResult;
				case '!=':
					return neqResult;
				case '!==':
					return neqResult;
				case '//':
					return idivResult;
				case '/':
					return fdivResult;
				case '</>':
					return slashResult;
				case '||':
					return orResult;
				case '<=':
					return leResult;
				case '>=':
					return geResult;
				case '>':
					return gtResult;
				case '<?>':
					return questionMarkResult;
				case '<':
					return ltResult;
				case '^':
					return powResult;
				case '**':
					return powResult;
				default:
					return $elm$core$Maybe$Nothing;
			}
		},
		extensionRightConstraints.aW);
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight = F2(
	function (leftPrecedence, symbol) {
		return {
			am: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extensionRightParser(
				{
					aW: function ($) {
						return $.am;
					},
					aw: 1,
					ad: symbol,
					ba: function (rightInfo) {
						return (_Utils_cmp(rightInfo.an, leftPrecedence) > -1) ? $elm$core$Maybe$Just(rightInfo) : $elm$core$Maybe$Nothing;
					}
				}),
			an: leftPrecedence,
			ad: symbol
		};
	});
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseOrUnqualifiedReferenceExpressionMaybeApplied() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionCaseOfFollowedByOptimisticLayout(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$unqualifiedFunctionReferenceExpressionFollowedByRecordAccess));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionCaseOfFollowedByOptimisticLayout() {
	return A5(
		$lue_bird$elm_syntax_format$ParserFast$map4WithStartLocation,
		F5(
			function (start, commentsAfterCase, casedExpressionResult, commentsAfterOf, casesResult) {
				var _v38 = casesResult.a;
				var firstCase = _v38.a;
				var lastToSecondCase = _v38.b;
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						casesResult.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterOf,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, casedExpressionResult.b, commentsAfterCase))),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{
							cw: function () {
								if (lastToSecondCase.b) {
									var _v40 = lastToSecondCase.a;
									var _v41 = _v40.b;
									var lastCaseExpressionRange = _v41.a;
									return lastCaseExpressionRange.cw;
								} else {
									var _v42 = firstCase;
									var _v43 = _v42.b;
									var firstCaseExpressionRange = _v43.a;
									return firstCaseExpressionRange.cw;
								}
							}(),
							b9: start
						},
						$stil4m$elm_syntax$Elm$Syntax$Expression$CaseExpression(
							{
								be: A2(
									$elm$core$List$cons,
									firstCase,
									$elm$core$List$reverse(lastToSecondCase)),
								u: casedExpressionResult.a
							}))
				};
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'case', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
		A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'of', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ParserFast$withIndentSetToColumn(
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementsFollowedByWhitespaceAndComments()));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementsFollowedByWhitespaceAndComments() {
	return A6(
		$lue_bird$elm_syntax_format$ParserFast$map5,
		F5(
			function (firstCasePatternResult, commentsAfterFirstCasePattern, commentsAfterFirstCaseArrowRight, firstCaseExpressionResult, lastToSecondCase) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						lastToSecondCase.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							firstCaseExpressionResult.b,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterFirstCaseArrowRight,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterFirstCasePattern, firstCasePatternResult.b)))),
					a: _Utils_Tuple2(
						_Utils_Tuple2(firstCasePatternResult.a, firstCaseExpressionResult.a),
						lastToSecondCase.a)
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$pattern,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A3(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2OrSucceed,
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '->', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '.', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementFollowedByWhitespaceAndComments()));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementFollowedByWhitespaceAndComments() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(
		A5(
			$lue_bird$elm_syntax_format$ParserFast$map4,
			F4(
				function (patternResult, commentsBeforeArrowRight, commentsAfterArrowRight, expr) {
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							expr.b,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterArrowRight,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsBeforeArrowRight, patternResult.b))),
						a: _Utils_Tuple2(patternResult.a, expr.a)
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$pattern,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '->', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments()));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpressionOptimisticLayout() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByOptimisticLayout(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpression());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpression() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'[',
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionAfterOpeningSquareBracket());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionAfterOpeningSquareBracket() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$glslExpressionAfterOpeningSquareBracket,
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
			F3(
				function (range, commentsBefore, elements) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, elements.b, commentsBefore),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{
								cw: range.cw,
								b9: {cp: range.b9.cp - 1, c9: range.b9.c9}
							},
							elements.a)
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbol,
					']',
					{
						b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
						a: $stil4m$elm_syntax$Elm$Syntax$Expression$ListExpr(_List_Nil)
					}),
				A2(
					$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
					']',
					A4(
						$lue_bird$elm_syntax_format$ParserFast$map3,
						F3(
							function (commentsBeforeHead, head, tail) {
								return {
									b: A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										tail.b,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, head.b, commentsBeforeHead)),
									a: $stil4m$elm_syntax$Elm$Syntax$Expression$ListExpr(
										A2($elm$core$List$cons, head.a, tail.a))
								};
							}),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$orSucceed,
							A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
							A2(
								$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
								',',
								A4(
									$lue_bird$elm_syntax_format$ParserFast$map3,
									F3(
										function (commentsBefore, commentsWithExtraComma, expressionResult) {
											return {
												b: A2(
													$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
													expressionResult.b,
													A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBefore)),
												a: expressionResult.a
											};
										}),
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
									A2(
										$lue_bird$elm_syntax_format$ParserFast$orSucceed,
										A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments()))))))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccessMaybeApplied() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccess());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccess() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'(',
		A3(
			$lue_bird$elm_syntax_format$ParserFast$oneOf3,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolWithEndLocation,
				')',
				function (end) {
					return {
						b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{
								cw: end,
								b9: {cp: end.cp - 2, c9: end.c9}
							},
							$stil4m$elm_syntax$Elm$Syntax$Expression$UnitExpr)
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$allowedPrefixOperatorFollowedByClosingParensOneOf,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionInnerAfterOpeningParens()));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionInnerAfterOpeningParens() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiRecordAccess(
		A4(
			$lue_bird$elm_syntax_format$ParserFast$map3WithRange,
			F4(
				function (rangeAfterOpeningParens, commentsBeforeFirstPart, firstPart, tailParts) {
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							tailParts.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, firstPart.b, commentsBeforeFirstPart)),
						a: function () {
							var _v36 = tailParts.a;
							if (!_v36.$) {
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{
										cw: rangeAfterOpeningParens.cw,
										b9: {cp: rangeAfterOpeningParens.b9.cp - 1, c9: rangeAfterOpeningParens.b9.c9}
									},
									$stil4m$elm_syntax$Elm$Syntax$Expression$ParenthesizedExpression(firstPart.a));
							} else {
								var secondPart = _v36.a;
								var maybeThirdPart = _v36.b;
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{
										cw: rangeAfterOpeningParens.cw,
										b9: {cp: rangeAfterOpeningParens.b9.cp - 1, c9: rangeAfterOpeningParens.b9.c9}
									},
									function () {
										if (maybeThirdPart.$ === 1) {
											return $stil4m$elm_syntax$Elm$Syntax$Expression$TupledExpression(
												_List_fromArray(
													[firstPart.a, secondPart]));
										} else {
											var thirdPart = maybeThirdPart.a;
											return $stil4m$elm_syntax$Elm$Syntax$Expression$TupledExpression(
												_List_fromArray(
													[firstPart.a, secondPart, thirdPart]));
										}
									}());
							}
						}()
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbol,
					')',
					{
						b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
						a: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TupledParenthesized, 0, 0)
					}),
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
					',',
					A4(
						$lue_bird$elm_syntax_format$ParserFast$map3,
						F3(
							function (commentsBefore, partResult, maybeThirdPart) {
								return {
									b: A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										maybeThirdPart.b,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, partResult.b, commentsBefore)),
									a: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TupledTwoOrThree, partResult.a, maybeThirdPart.a)
								};
							}),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$oneOf2,
							A2(
								$lue_bird$elm_syntax_format$ParserFast$symbol,
								')',
								{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
							A2(
								$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
								',',
								A2(
									$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
									')',
									A3(
										$lue_bird$elm_syntax_format$ParserFast$map2,
										F2(
											function (commentsBefore, partResult) {
												return {
													b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, partResult.b, commentsBefore),
													a: $elm$core$Maybe$Just(partResult.a)
												};
											}),
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments())))))))));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccessMaybeApplied() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccess());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccess() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'{',
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiRecordAccess(
			A3(
				$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
				F3(
					function (range, commentsBefore, afterCurly) {
						return {
							b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, afterCurly.b, commentsBefore),
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$rangeMoveStartLeftByOneColumn(range),
								afterCurly.a)
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordContentsFollowedByCurlyEnd())));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordContentsFollowedByCurlyEnd() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$oneOf3,
		A6(
			$lue_bird$elm_syntax_format$ParserFast$map5,
			F5(
				function (nameNode, commentsAfterName, afterNameBeforeFields, tailFields, commentsBeforeClosingCurly) {
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsBeforeClosingCurly,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								tailFields.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, afterNameBeforeFields.b, commentsAfterName))),
						a: function () {
							var _v34 = afterNameBeforeFields.a;
							switch (_v34.$) {
								case 0:
									var firstField = _v34.a;
									return A2(
										$stil4m$elm_syntax$Elm$Syntax$Expression$RecordUpdateExpression,
										nameNode,
										A2($elm$core$List$cons, firstField, tailFields.a));
								case 1:
									var firstFieldValue = _v34.a;
									return $stil4m$elm_syntax$Elm$Syntax$Expression$RecordExpr(
										A2(
											$elm$core$List$cons,
											A3($stil4m$elm_syntax$Elm$Syntax$Node$combine, $elm$core$Tuple$pair, nameNode, firstFieldValue),
											tailFields.a));
								default:
									return $stil4m$elm_syntax$Elm$Syntax$Expression$RecordExpr(
										A2(
											$elm$core$List$cons,
											A2(
												$stil4m$elm_syntax$Elm$Syntax$Node$Node,
												$stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode),
												_Utils_Tuple2(
													nameNode,
													A2(
														$stil4m$elm_syntax$Elm$Syntax$Node$Node,
														{
															cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode).cw,
															b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode).cw
														},
														A2(
															$stil4m$elm_syntax$Elm$Syntax$Expression$FunctionOrValue,
															_List_Nil,
															$stil4m$elm_syntax$Elm$Syntax$Node$value(nameNode))))),
											tailFields.a));
							}
						}()
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
					'|',
					A3(
						$lue_bird$elm_syntax_format$ParserFast$map2,
						F2(
							function (commentsBefore, setterResult) {
								return {
									b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, setterResult.b, commentsBefore),
									a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$RecordUpdateFirstSetter(setterResult.a)
								};
							}),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordSetterNodeFollowedByWhitespaceAndComments())),
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (commentsBefore, maybeValueResult) {
							if (maybeValueResult.$ === 1) {
								return {
									b: commentsBefore,
									a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FieldsFirstValuePunned(0)
								};
							} else {
								var expressionResult = maybeValueResult.a;
								return {
									b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, expressionResult.b, commentsBefore),
									a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FieldsFirstValue(expressionResult.a)
								};
							}
						}),
					A3(
						$lue_bird$elm_syntax_format$ParserFast$oneOf2OrSucceed,
						A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
						A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
					A3(
						$lue_bird$elm_syntax_format$ParserFast$mapOrSucceed,
						$elm$core$Maybe$Just,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
						$elm$core$Maybe$Nothing))),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFields(),
			A2($lue_bird$elm_syntax_format$ParserFast$followedBySymbol, '}', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbol,
			'}',
			{
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: $stil4m$elm_syntax$Elm$Syntax$Expression$RecordExpr(_List_Nil)
			}),
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2,
			F2(
				function (recordFieldsResult, commentsAfterFields) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterFields, recordFieldsResult.b),
						a: $stil4m$elm_syntax$Elm$Syntax$Expression$RecordExpr(recordFieldsResult.a)
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFields(),
			A2($lue_bird$elm_syntax_format$ParserFast$followedBySymbol, '}', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFields() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			',',
			A4(
				$lue_bird$elm_syntax_format$ParserFast$map3,
				F3(
					function (commentsBefore, commentsWithExtraComma, setterResult) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								setterResult.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBefore)),
							a: setterResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$orSucceed,
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordSetterNodeFollowedByWhitespaceAndComments())));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordSetterNodeFollowedByWhitespaceAndComments() {
	return A5(
		$lue_bird$elm_syntax_format$ParserFast$map4WithRange,
		F5(
			function (range, nameNode, commentsAfterName, commentsAfterEquals, maybeValueResult) {
				if (maybeValueResult.$ === 1) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterEquals, commentsAfterName),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							range,
							_Utils_Tuple2(
								nameNode,
								A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode).cw,
										b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode).cw
									},
									A2(
										$stil4m$elm_syntax$Elm$Syntax$Expression$FunctionOrValue,
										_List_Nil,
										$stil4m$elm_syntax$Elm$Syntax$Node$value(nameNode)))))
					};
				} else {
					var expressionResult = maybeValueResult.a;
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							expressionResult.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterEquals, commentsAfterName)),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							range,
							_Utils_Tuple2(nameNode, expressionResult.a))
					};
				}
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A3(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2OrSucceed,
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
		A3(
			$lue_bird$elm_syntax_format$ParserFast$mapOrSucceed,
			$elm$core$Maybe$Just,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
			$elm$core$Maybe$Nothing));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letOrUnqualifiedReferenceExpressionMaybeApplied() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letExpressionFollowedByOptimisticLayout(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$unqualifiedFunctionReferenceExpressionFollowedByRecordAccess));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letExpressionFollowedByOptimisticLayout() {
	return A4(
		$lue_bird$elm_syntax_format$ParserFast$map3WithStartLocation,
		F4(
			function (start, letDeclarationsResult, commentsAfterIn, expressionResult) {
				var _v32 = expressionResult.a;
				var expressionRange = _v32.a;
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						expressionResult.b,
						A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterIn, letDeclarationsResult.b)),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: expressionRange.cw, b9: start},
						$stil4m$elm_syntax$Elm$Syntax$Expression$LetExpression(
							{bl: letDeclarationsResult.bl, u: expressionResult.a}))
				};
			}),
		$lue_bird$elm_syntax_format$ParserFast$withIndentSetToColumn(
			A2(
				$lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy,
				'let',
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (commentsAfterLet, letDeclarationsResult) {
							return {
								b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, letDeclarationsResult.b, commentsAfterLet),
								bl: letDeclarationsResult.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					$lue_bird$elm_syntax_format$ParserFast$withIndentSetToColumn(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDeclarationsIn())))),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDeclarationsIn() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(
		A4(
			$lue_bird$elm_syntax_format$ParserFast$map3,
			F3(
				function (headLetResult, commentsAfter, tailLetResult) {
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							tailLetResult.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, headLetResult.b)),
						a: A2($elm$core$List$cons, headLetResult.a, tailLetResult.a)
					};
				}),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letFunctionFollowedByOptimisticLayout(),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDestructuringDeclarationFollowedByOptimisticLayout()),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A2(
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$untilWithComments,
				A2($lue_bird$elm_syntax_format$ParserFast$keyword, 'in', 0),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letBlockElementFollowedByOptimisticLayout())));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letBlockElementFollowedByOptimisticLayout() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(
		A2(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letFunctionFollowedByOptimisticLayout(),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDestructuringDeclarationFollowedByOptimisticLayout()));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letFunctionFollowedByOptimisticLayout() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		A2(
			$lue_bird$elm_syntax_format$ParserFast$validate,
			function (result) {
				var _v25 = result.a;
				var letDeclaration = _v25.b;
				if (letDeclaration.$ === 1) {
					return true;
				} else {
					var letFunctionDeclaration = letDeclaration.a;
					var _v27 = letFunctionDeclaration.K;
					if (_v27.$ === 1) {
						return true;
					} else {
						var _v28 = _v27.a;
						var signature = _v28.b;
						var _v29 = signature.aN;
						var signatureName = _v29.b;
						var _v30 = letFunctionDeclaration.G;
						var implementation = _v30.b;
						var _v31 = implementation.aN;
						var implementationName = _v31.b;
						return _Utils_eq(implementationName, signatureName);
					}
				}
			},
			A7(
				$lue_bird$elm_syntax_format$ParserFast$map6WithStartLocation,
				F7(
					function (startNameStart, startNameNode, commentsAfterStartName, maybeSignature, _arguments, commentsAfterEqual, expressionResult) {
						if (maybeSignature.$ === 1) {
							var _v22 = expressionResult.a;
							var expressionRange = _v22.a;
							return {
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									expressionResult.b,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										commentsAfterEqual,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, _arguments.b, commentsAfterStartName))),
								a: A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{cw: expressionRange.cw, b9: startNameStart},
									$stil4m$elm_syntax$Elm$Syntax$Expression$LetFunction(
										{
											G: A2(
												$stil4m$elm_syntax$Elm$Syntax$Node$Node,
												{cw: expressionRange.cw, b9: startNameStart},
												{M: _arguments.a, u: expressionResult.a, aN: startNameNode}),
											Q: $elm$core$Maybe$Nothing,
											K: $elm$core$Maybe$Nothing
										}))
							};
						} else {
							var signature = maybeSignature.a;
							var _v23 = signature.Z;
							var implementationNameRange = _v23.a;
							var _v24 = expressionResult.a;
							var expressionRange = _v24.a;
							return {
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									expressionResult.b,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										commentsAfterEqual,
										A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											_arguments.b,
											A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, signature.b, commentsAfterStartName)))),
								a: A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{cw: expressionRange.cw, b9: startNameStart},
									$stil4m$elm_syntax$Elm$Syntax$Expression$LetFunction(
										{
											G: A2(
												$stil4m$elm_syntax$Elm$Syntax$Node$Node,
												{cw: expressionRange.cw, b9: implementationNameRange.b9},
												{M: _arguments.a, u: expressionResult.a, aN: signature.Z}),
											Q: $elm$core$Maybe$Nothing,
											K: $elm$core$Maybe$Just(
												A3(
													$stil4m$elm_syntax$Elm$Syntax$Node$combine,
													F2(
														function (name, value) {
															return {aN: name, o: value};
														}),
													startNameNode,
													signature.o))
										}))
							};
						}
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				A6(
					$lue_bird$elm_syntax_format$ParserFast$map4OrSucceed,
					F4(
						function (commentsBeforeTypeAnnotation, typeAnnotationResult, implementationName, afterImplementationName) {
							return $elm$core$Maybe$Just(
								{
									b: A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										afterImplementationName,
										A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											implementationName.b,
											A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, typeAnnotationResult.b, commentsBeforeTypeAnnotation))),
									Z: implementationName.a,
									o: typeAnnotationResult.a
								});
						}),
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_,
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedBy($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					$elm$core$Maybe$Nothing),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments())),
		A9(
			$lue_bird$elm_syntax_format$ParserFast$map8WithStartLocation,
			F9(
				function (start, commentsBeforeTypeAnnotation, typeAnnotationResult, commentsBetweenTypeAndName, nameNode, afterImplementationName, _arguments, commentsAfterEqual, result) {
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							result.b,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterEqual,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									_arguments.b,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										afterImplementationName,
										A2(
											$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
											commentsBetweenTypeAndName,
											A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, typeAnnotationResult.b, commentsBeforeTypeAnnotation)))))),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{
								cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(result.a).cw,
								b9: start
							},
							$stil4m$elm_syntax$Elm$Syntax$Expression$LetFunction(
								{
									G: A2(
										$stil4m$elm_syntax$Elm$Syntax$Node$Node,
										{
											cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(result.a).cw,
											b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode).b9
										},
										{M: _arguments.a, u: result.a, aN: nameNode}),
									Q: $elm$core$Maybe$Nothing,
									K: $elm$core$Maybe$Just(
										A2(
											$stil4m$elm_syntax$Elm$Syntax$Node$Node,
											{
												cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(typeAnnotationResult.a).cw,
												b9: start
											},
											{
												aN: A2(
													$stil4m$elm_syntax$Elm$Syntax$Node$Node,
													{cw: start, b9: start},
													$stil4m$elm_syntax$Elm$Syntax$Node$value(nameNode)),
												o: typeAnnotationResult.a
											}))
								}))
					};
				}),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndented,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments()));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDestructuringDeclarationFollowedByOptimisticLayout() {
	return A5(
		$lue_bird$elm_syntax_format$ParserFast$map4,
		F4(
			function (patternResult, commentsAfterPattern, commentsAfterEquals, expressionResult) {
				var _v19 = patternResult.a;
				var patternRange = _v19.a;
				var _v20 = expressionResult.a;
				var destructuredExpressionRange = _v20.a;
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						expressionResult.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterEquals,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterPattern, patternResult.b))),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: destructuredExpressionRange.cw, b9: patternRange.b9},
						A2($stil4m$elm_syntax$Elm$Syntax$Expression$LetDestructuring, patternResult.a, expressionResult.a))
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternNotSpaceSeparated,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$lambdaExpressionFollowedByWhitespaceAndComments() {
	return A7(
		$lue_bird$elm_syntax_format$ParserFast$map6WithStartLocation,
		F7(
			function (start, commentsAfterBackslash, firstArg, commentsAfterFirstArg, secondUpArgs, commentsAfterArrow, expressionResult) {
				var _v18 = expressionResult.a;
				var expressionRange = _v18.a;
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						expressionResult.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterArrow,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								secondUpArgs.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfterFirstArg,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, firstArg.b, commentsAfterBackslash))))),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: expressionRange.cw, b9: start},
						$stil4m$elm_syntax$Elm$Syntax$Expression$LambdaExpression(
							{
								dx: A2($elm$core$List$cons, firstArg.a, secondUpArgs.a),
								u: expressionResult.a
							}))
				};
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '\\', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternNotSpaceSeparated,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A2(
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$untilWithComments,
			A3(
				$lue_bird$elm_syntax_format$ParserFast$oneOf3,
				A2($lue_bird$elm_syntax_format$ParserFast$symbol, '->', 0),
				A2($lue_bird$elm_syntax_format$ParserFast$symbol, '=>', 0),
				A2($lue_bird$elm_syntax_format$ParserFast$symbol, '.', 0)),
			A3(
				$lue_bird$elm_syntax_format$ParserFast$map2,
				F2(
					function (patternResult, commentsAfter) {
						return {
							b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, patternResult.b),
							a: patternResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$patternNotSpaceSeparated,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifOrUnqualifiedReferenceExpressionMaybeApplied() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$oneOf2,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifBlockExpressionFollowedByOptimisticLayout(),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$unqualifiedFunctionReferenceExpressionFollowedByRecordAccess));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifBlockExpressionFollowedByOptimisticLayout() {
	return A7(
		$lue_bird$elm_syntax_format$ParserFast$map6WithStartLocation,
		F7(
			function (start, commentsAfterIf, condition, commentsAfterThen, ifTrue, commentsAfterElse, ifFalse) {
				var _v17 = ifFalse.a;
				var ifFalseRange = _v17.a;
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						ifFalse.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterElse,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								ifTrue.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfterThen,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, condition.b, commentsAfterIf))))),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: ifFalseRange.cw, b9: start},
						A3($stil4m$elm_syntax$Elm$Syntax$Expression$IfBlock, condition.a, ifTrue.a, ifFalse.a))
				};
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'if', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$oneOf2,
			A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'then', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, '->', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments(),
		A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'else', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (expressionResult, maybeCases) {
				if (maybeCases.$ === 1) {
					return expressionResult;
				} else {
					var cases = maybeCases.a;
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, cases.b, expressionResult.b),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{
								cw: cases.cw,
								b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(expressionResult.a).b9
							},
							$stil4m$elm_syntax$Elm$Syntax$Expression$CaseExpression(
								{be: cases.be, u: expressionResult.a}))
					};
				}
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$extendedSubExpressionFollowedByWhitespaceAndComments(
			{
				aW: function ($) {
					return $.am;
				},
				ba: $elm$core$Maybe$Just
			}),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$orSucceed,
			A2(
				$lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy,
				'case',
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (commentsAfterCase, casesResult) {
							var _v10 = casesResult.a;
							var firstCase = _v10.a;
							var lastToSecondCase = _v10.b;
							return $elm$core$Maybe$Just(
								{
									be: A2(
										$elm$core$List$cons,
										firstCase,
										$elm$core$List$reverse(lastToSecondCase)),
									b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, casesResult.b, commentsAfterCase),
									cw: function () {
										if (lastToSecondCase.b) {
											var _v12 = lastToSecondCase.a;
											var _v13 = _v12.b;
											var lastCaseExpressionRange = _v13.a;
											return lastCaseExpressionRange.cw;
										} else {
											var _v14 = firstCase;
											var _v15 = _v14.b;
											var firstCaseExpressionRange = _v15.a;
											return firstCaseExpressionRange.cw;
										}
									}()
								});
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					$lue_bird$elm_syntax_format$ParserFast$withIndentSetToColumn(
						$lue_bird$elm_syntax_format$ParserFast$lazy(
							function (_v16) {
								return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementsFollowedByWhitespaceAndComments();
							})))),
			$elm$core$Maybe$Nothing));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$referenceOrNumberExpressionMaybeApplied() {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$oneOf3,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$qualifiedOrVariantOrRecordConstructorReferenceExpressionFollowedByRecordAccess),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$unqualifiedFunctionReferenceExpressionFollowedByRecordAccess),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByOptimisticLayout($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$numberExpression));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordAccessFunctionExpressionMaybeApplied() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByMultiArgumentApplication($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordAccessFunctionExpression);
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeL() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 9, '<<');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8QuestionMark() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 8, '<?>');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Mul() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 7, '*');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Idiv() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 7, '//');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Fdiv() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 7, '/');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Sub() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 6, '-');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Ignore() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 6, '|.');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Add() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 6, '+');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Keep() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 5, '|=');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApR() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixLeft, 1, '|>');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Neq() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative, 4, '/=');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Lt() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative, 4, '<');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Le() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative, 4, '<=');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Gt() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative, 4, '>');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Ge() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative, 4, '>=');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Eq() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixNonAssociative, 4, '==');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeR() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 9, '>>');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8Pow() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 8, '^');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Slash() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 7, '</>');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5append() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 5, '++');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Cons() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 5, '::');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence3And() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 3, '&&');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence2Or() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 2, '||');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApL() {
	return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixRight, 1, '<|');
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$map,
		function (subExpressionResult) {
			var _v3 = subExpressionResult.a;
			var subExpressionRange = _v3.a;
			return {
				b: subExpressionResult.b,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					{
						cw: subExpressionRange.cw,
						b9: {cp: subExpressionRange.b9.cp - 1, c9: subExpressionRange.b9.c9}
					},
					$stil4m$elm_syntax$Elm$Syntax$Expression$Negation(subExpressionResult.a))
			};
		},
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpression());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperationOptimisticLayout() {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$followedByOptimisticLayout(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperation());
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperation() {
	return A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolBacktrackableFollowedBy,
		'-',
		$lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThen(
			F2(
				function (offset, source) {
					var _v2 = A3($elm$core$String$slice, offset - 2, offset - 1, source);
					switch (_v2) {
						case ' ':
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus();
						case '(':
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus();
						case ')':
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus();
						case '}':
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus();
						case '':
							return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus();
						default:
							return $lue_bird$elm_syntax_format$ParserFast$problem;
					}
				})));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpression() {
	return $lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThen(
		F2(
			function (offset, source) {
				var _v1 = A3($elm$core$String$slice, offset, offset + 1, source);
				switch (_v1) {
					case '\"':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$literalExpression;
					case '(':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccess();
					case '[':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpression();
					case '{':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccess();
					case '.':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordAccessFunctionExpression;
					case '-':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperation();
					case '\'':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charLiteralExpression;
					default:
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$referenceOrNumberExpression;
				}
			}));
}
function $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpressionMaybeAppliedFollowedByWhitespaceAndComments() {
	return $lue_bird$elm_syntax_format$ParserFast$offsetSourceAndThen(
		F2(
			function (offset, source) {
				var _v0 = A3($elm$core$String$slice, offset, offset + 1, source);
				switch (_v0) {
					case '\"':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$literalExpressionOptimisticLayout;
					case '(':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccessMaybeApplied();
					case '[':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpressionOptimisticLayout();
					case '{':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccessMaybeApplied();
					case 'c':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseOrUnqualifiedReferenceExpressionMaybeApplied();
					case '\\':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$lambdaExpressionFollowedByWhitespaceAndComments();
					case 'l':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letOrUnqualifiedReferenceExpressionMaybeApplied();
					case 'i':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifOrUnqualifiedReferenceExpressionMaybeApplied();
					case '.':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordAccessFunctionExpressionMaybeApplied();
					case '-':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperationOptimisticLayout();
					case '\'':
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$charLiteralExpressionOptimisticLayout;
					default:
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$referenceOrNumberExpressionMaybeApplied();
				}
			}));
}
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$caseOrUnqualifiedReferenceExpressionMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseOrUnqualifiedReferenceExpressionMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseOrUnqualifiedReferenceExpressionMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$caseOrUnqualifiedReferenceExpressionMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionCaseOfFollowedByOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionCaseOfFollowedByOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionCaseOfFollowedByOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionCaseOfFollowedByOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$caseStatementsFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementsFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementsFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$caseStatementsFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$caseStatementFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$caseStatementFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$caseStatementFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listOrGlslExpressionOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpressionOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpressionOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listOrGlslExpressionOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listOrGlslExpression = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpression();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$listOrGlslExpression = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listOrGlslExpression;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionAfterOpeningSquareBracket = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionAfterOpeningSquareBracket();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionAfterOpeningSquareBracket = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionAfterOpeningSquareBracket;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tupledExpressionIfNecessaryFollowedByRecordAccessMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccessMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccessMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tupledExpressionIfNecessaryFollowedByRecordAccessMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tupledExpressionIfNecessaryFollowedByRecordAccess = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccess();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionIfNecessaryFollowedByRecordAccess = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tupledExpressionIfNecessaryFollowedByRecordAccess;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tupledExpressionInnerAfterOpeningParens = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionInnerAfterOpeningParens();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$tupledExpressionInnerAfterOpeningParens = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$tupledExpressionInnerAfterOpeningParens;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordExpressionFollowedByRecordAccessMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccessMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccessMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordExpressionFollowedByRecordAccessMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordExpressionFollowedByRecordAccess = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccess();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordExpressionFollowedByRecordAccess = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordExpressionFollowedByRecordAccess;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordContentsFollowedByCurlyEnd = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordContentsFollowedByCurlyEnd();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordContentsFollowedByCurlyEnd = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordContentsFollowedByCurlyEnd;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordFields = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFields();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordFields = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordFields;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordSetterNodeFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordSetterNodeFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordSetterNodeFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordSetterNodeFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letOrUnqualifiedReferenceExpressionMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letOrUnqualifiedReferenceExpressionMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letOrUnqualifiedReferenceExpressionMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letOrUnqualifiedReferenceExpressionMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letExpressionFollowedByOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letExpressionFollowedByOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letExpressionFollowedByOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letExpressionFollowedByOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letDeclarationsIn = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDeclarationsIn();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDeclarationsIn = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letDeclarationsIn;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letBlockElementFollowedByOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letBlockElementFollowedByOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letBlockElementFollowedByOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letBlockElementFollowedByOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letFunctionFollowedByOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letFunctionFollowedByOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letFunctionFollowedByOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letFunctionFollowedByOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letDestructuringDeclarationFollowedByOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDestructuringDeclarationFollowedByOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$letDestructuringDeclarationFollowedByOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$letDestructuringDeclarationFollowedByOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$lambdaExpressionFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$lambdaExpressionFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$lambdaExpressionFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$lambdaExpressionFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifOrUnqualifiedReferenceExpressionMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifOrUnqualifiedReferenceExpressionMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifOrUnqualifiedReferenceExpressionMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifOrUnqualifiedReferenceExpressionMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifBlockExpressionFollowedByOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifBlockExpressionFollowedByOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$ifBlockExpressionFollowedByOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ifBlockExpressionFollowedByOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$expressionFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$referenceOrNumberExpressionMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$referenceOrNumberExpressionMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$referenceOrNumberExpressionMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$referenceOrNumberExpressionMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordAccessFunctionExpressionMaybeApplied = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordAccessFunctionExpressionMaybeApplied();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$recordAccessFunctionExpressionMaybeApplied = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$recordAccessFunctionExpressionMaybeApplied;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence9ComposeL = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeL();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeL = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence9ComposeL;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence8QuestionMark = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8QuestionMark();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8QuestionMark = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence8QuestionMark;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Mul = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Mul();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Mul = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Mul;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Idiv = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Idiv();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Idiv = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Idiv;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Fdiv = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Fdiv();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Fdiv = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Fdiv;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence6Sub = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Sub();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Sub = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence6Sub;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence6Ignore = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Ignore();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Ignore = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence6Ignore;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence6Add = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Add();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence6Add = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence6Add;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence5Keep = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Keep();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Keep = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence5Keep;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence1ApR = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApR();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApR = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence1ApR;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Neq = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Neq();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Neq = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Neq;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Lt = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Lt();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Lt = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Lt;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Le = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Le();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Le = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Le;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Gt = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Gt();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Gt = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Gt;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Ge = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Ge();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Ge = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Ge;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Eq = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Eq();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence4Eq = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence4Eq;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence9ComposeR = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeR();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence9ComposeR = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence9ComposeR;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence8Pow = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8Pow();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence8Pow = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence8Pow;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Slash = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Slash();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence7Slash = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence7Slash;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence5append = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5append();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5append = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence5append;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence5Cons = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Cons();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence5Cons = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence5Cons;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence3And = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence3And();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence3And = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence3And;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence2Or = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence2Or();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence2Or = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence2Or;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence1ApL = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApL();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$precedence1ApL = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$precedence1ApL;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$negationAfterMinus = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationAfterMinus = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$negationAfterMinus;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$negationOperationOptimisticLayout = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperationOptimisticLayout();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperationOptimisticLayout = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$negationOperationOptimisticLayout;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$negationOperation = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperation();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$negationOperation = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$negationOperation;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$subExpression = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpression();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpression = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$subExpression;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$subExpressionMaybeAppliedFollowedByWhitespaceAndComments = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpressionMaybeAppliedFollowedByWhitespaceAndComments();
$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$cyclic$subExpressionMaybeAppliedFollowedByWhitespaceAndComments = function () {
	return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$subExpressionMaybeAppliedFollowedByWhitespaceAndComments;
};
var $lue_bird$elm_syntax_format$ParserFast$map6 = F7(
	function (func, _v0, _v1, _v2, _v3, _v4, _v5) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		var parseF = _v5;
		return function (s0) {
			var _v6 = parseA(s0);
			if (_v6.$ === 1) {
				var committed = _v6.a;
				var x = _v6.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v6.a;
				var s1 = _v6.b;
				var _v7 = parseB(s1);
				if (_v7.$ === 1) {
					var x = _v7.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v7.a;
					var s2 = _v7.b;
					var _v8 = parseC(s2);
					if (_v8.$ === 1) {
						var x = _v8.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v8.a;
						var s3 = _v8.b;
						var _v9 = parseD(s3);
						if (_v9.$ === 1) {
							var x = _v9.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v9.a;
							var s4 = _v9.b;
							var _v10 = parseE(s4);
							if (_v10.$ === 1) {
								var x = _v10.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v10.a;
								var s5 = _v10.b;
								var _v11 = parseF(s5);
								if (_v11.$ === 1) {
									var x = _v11.b;
									return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
								} else {
									var f = _v11.a;
									var s6 = _v11.b;
									return A2(
										$lue_bird$elm_syntax_format$ParserFast$Good,
										A6(func, a, b, c, d, e, f),
										s6);
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode = A4($lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileValidateMapWithRangeWithoutLinebreak, $stil4m$elm_syntax$Elm$Syntax$Node$Node, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsLowerFast, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isNotReserved);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionAfterDocumentation = A2(
	$lue_bird$elm_syntax_format$ParserFast$oneOf2,
	A7(
		$lue_bird$elm_syntax_format$ParserFast$map6,
		F6(
			function (startName, commentsAfterStartName, maybeSignature, _arguments, commentsAfterEqual, result) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						result.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterEqual,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								_arguments.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, maybeSignature.b, commentsAfterStartName)))),
					a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FunctionDeclarationAfterDocumentation(
						{M: _arguments.a, u: result.a, K: maybeSignature.a, a4: startName})
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		A6(
			$lue_bird$elm_syntax_format$ParserFast$map4OrSucceed,
			F4(
				function (commentsBeforeTypeAnnotation, typeAnnotationResult, implementationName, afterImplementationName) {
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							afterImplementationName,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								implementationName.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, typeAnnotationResult.b, commentsBeforeTypeAnnotation))),
						a: $elm$core$Maybe$Just(
							{Z: implementationName.a, o: typeAnnotationResult.a})
					};
				}),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedBy($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionFollowedByWhitespaceAndComments),
	A9(
		$lue_bird$elm_syntax_format$ParserFast$map8WithStartLocation,
		F9(
			function (start, commentsBeforeTypeAnnotation, typeAnnotationResult, commentsBetweenTypeAndName, nameNode, afterImplementationName, _arguments, commentsAfterEqual, result) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						result.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterEqual,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								_arguments.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									afterImplementationName,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										commentsBetweenTypeAndName,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, typeAnnotationResult.b, commentsBeforeTypeAnnotation)))))),
					a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$FunctionDeclarationAfterDocumentation(
						{
							M: _arguments.a,
							u: result.a,
							K: $elm$core$Maybe$Just(
								{Z: nameNode, o: typeAnnotationResult.a}),
							a4: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: start, b9: start},
								$stil4m$elm_syntax$Elm$Syntax$Node$value(nameNode))
						})
				};
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndented,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionFollowedByWhitespaceAndComments));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$PortDeclarationAfterDocumentation = function (a) {
	return {$: 3, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$portDeclarationAfterDocumentation = A6(
	$lue_bird$elm_syntax_format$ParserFast$map5,
	F5(
		function (commentsAfterPort, nameNode, commentsAfterName, commentsAfterColon, typeAnnotationResult) {
			var _v0 = nameNode;
			var nameRange = _v0.a;
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					commentsAfterColon,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						typeAnnotationResult.b,
						A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterName, commentsAfterPort))),
				a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$PortDeclarationAfterDocumentation(
					{
						aN: nameNode,
						dh: {cp: 1, c9: nameRange.b9.c9},
						o: typeAnnotationResult.a
					})
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'port', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeDeclarationAfterDocumentation = function (a) {
	return {$: 1, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$map7 = F8(
	function (func, _v0, _v1, _v2, _v3, _v4, _v5, _v6) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		var parseF = _v5;
		var parseG = _v6;
		return function (s0) {
			var _v7 = parseA(s0);
			if (_v7.$ === 1) {
				var committed = _v7.a;
				var x = _v7.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v7.a;
				var s1 = _v7.b;
				var _v8 = parseB(s1);
				if (_v8.$ === 1) {
					var x = _v8.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v8.a;
					var s2 = _v8.b;
					var _v9 = parseC(s2);
					if (_v9.$ === 1) {
						var x = _v9.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v9.a;
						var s3 = _v9.b;
						var _v10 = parseD(s3);
						if (_v10.$ === 1) {
							var x = _v10.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v10.a;
							var s4 = _v10.b;
							var _v11 = parseE(s4);
							if (_v11.$ === 1) {
								var x = _v11.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v11.a;
								var s5 = _v11.b;
								var _v12 = parseF(s5);
								if (_v12.$ === 1) {
									var x = _v12.b;
									return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
								} else {
									var f = _v12.a;
									var s6 = _v12.b;
									var _v13 = parseG(s6);
									if (_v13.$ === 1) {
										var x = _v13.b;
										return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
									} else {
										var g = _v13.a;
										var s7 = _v13.b;
										return A2(
											$lue_bird$elm_syntax_format$ParserFast$Good,
											A7(func, a, b, c, d, e, f, g),
											s7);
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode = A3($lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithRangeWithoutLinebreak, $stil4m$elm_syntax$Elm$Syntax$Node$Node, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsUpperFast, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeGenericListEquals = A2(
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$untilWithComments,
	A2($lue_bird$elm_syntax_format$ParserFast$symbol, '=', 0),
	A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (name, commentsAfterName) {
				return {b: commentsAfterName, a: name};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$variantDeclarationFollowedByWhitespaceAndComments = A4(
	$lue_bird$elm_syntax_format$ParserFast$map3,
	F3(
		function (nameNode, commentsAfterName, argumentsReverse) {
			var _v0 = nameNode;
			var nameRange = _v0.a;
			var fullRange = function () {
				var _v1 = argumentsReverse.a;
				if (_v1.b) {
					var _v2 = _v1.a;
					var lastArgRange = _v2.a;
					return {cw: lastArgRange.cw, b9: nameRange.b9};
				} else {
					return nameRange;
				}
			}();
			return {
				b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, argumentsReverse.b, commentsAfterName),
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fullRange,
					{
						M: $elm$core$List$reverse(argumentsReverse.a),
						aN: nameNode
					})
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$positivelyIndentedFollowedBy(
			A3(
				$lue_bird$elm_syntax_format$ParserFast$map2,
				F2(
					function (typeAnnotationResult, commentsAfter) {
						return {
							b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, typeAnnotationResult.b),
							a: typeAnnotationResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeNotSpaceSeparated,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$customTypeDefinitionAfterDocumentationAfterTypePrefix = A8(
	$lue_bird$elm_syntax_format$ParserFast$map7,
	F7(
		function (name, commentsAfterName, parameters, commentsAfterEqual, commentsBeforeHeadVariant, headVariant, tailVariantsReverse) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					tailVariantsReverse.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						headVariant.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsBeforeHeadVariant,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterEqual,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, parameters.b, commentsAfterName))))),
				a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeDeclarationAfterDocumentation(
					{aJ: headVariant.a, aN: name, ap: parameters.a, aT: tailVariantsReverse.a})
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeGenericListEquals,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A2(
		$lue_bird$elm_syntax_format$ParserFast$orSucceed,
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '|', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$variantDeclarationFollowedByWhitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'|',
			A4(
				$lue_bird$elm_syntax_format$ParserFast$map3,
				F3(
					function (commentsBeforePipe, commentsWithExtraPipe, variantResult) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								variantResult.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraPipe, commentsBeforePipe)),
							a: variantResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$orSucceed,
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '|', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$variantDeclarationFollowedByWhitespaceAndComments))));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeAliasDeclarationAfterDocumentation = function (a) {
	return {$: 2, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAliasDefinitionAfterDocumentationAfterTypePrefix = A7(
	$lue_bird$elm_syntax_format$ParserFast$map6,
	F6(
		function (commentsAfterAlias, name, commentsAfterName, parameters, commentsAfterEquals, typeAnnotationResult) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					typeAnnotationResult.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						commentsAfterEquals,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							parameters.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterName, commentsAfterAlias)))),
				a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeAliasDeclarationAfterDocumentation(
					{aN: name, ap: parameters.a, o: typeAnnotationResult.a})
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'alias', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeGenericListEquals,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeOrTypeAliasDefinitionAfterDocumentation = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2,
	F2(
		function (commentsAfterType, declarationAfterDocumentation) {
			return {
				b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, declarationAfterDocumentation.b, commentsAfterType),
				a: declarationAfterDocumentation.a
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'type', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	A2($lue_bird$elm_syntax_format$ParserFast$oneOf2, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAliasDefinitionAfterDocumentationAfterTypePrefix, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$customTypeDefinitionAfterDocumentationAfterTypePrefix));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedByWithComments = function (nextParser) {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (commentsBefore, after) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, after.b, commentsBefore),
					a: after.a
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(nextParser));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$declarationWithDocumentation = A2(
	$lue_bird$elm_syntax_format$ParserFast$validate,
	function (result) {
		var _v11 = result.a;
		var decl = _v11.b;
		if (!decl.$) {
			var letFunctionDeclaration = decl.a;
			var _v13 = letFunctionDeclaration.K;
			if (_v13.$ === 1) {
				return true;
			} else {
				var _v14 = _v13.a;
				var signature = _v14.b;
				var _v15 = signature.aN;
				var signatureName = _v15.b;
				var _v16 = letFunctionDeclaration.G;
				var implementation = _v16.b;
				var _v17 = implementation.aN;
				var implementationName = _v17.b;
				return _Utils_eq(implementationName, signatureName);
			}
		} else {
			return true;
		}
	},
	A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (documentation, afterDocumentation) {
				var start = $stil4m$elm_syntax$Elm$Syntax$Node$range(documentation).b9;
				var _v0 = afterDocumentation.a;
				switch (_v0.$) {
					case 0:
						var functionDeclarationAfterDocumentation = _v0.a;
						var _v1 = functionDeclarationAfterDocumentation.K;
						if (!_v1.$) {
							var signature = _v1.a;
							var _v2 = signature.Z;
							var implementationNameRange = _v2.a;
							var _v3 = functionDeclarationAfterDocumentation.u;
							var expressionRange = _v3.a;
							return {
								b: afterDocumentation.b,
								a: A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{cw: expressionRange.cw, b9: start},
									$stil4m$elm_syntax$Elm$Syntax$Declaration$FunctionDeclaration(
										{
											G: A2(
												$stil4m$elm_syntax$Elm$Syntax$Node$Node,
												{cw: expressionRange.cw, b9: implementationNameRange.b9},
												{M: functionDeclarationAfterDocumentation.M, u: functionDeclarationAfterDocumentation.u, aN: signature.Z}),
											Q: $elm$core$Maybe$Just(documentation),
											K: $elm$core$Maybe$Just(
												A3(
													$stil4m$elm_syntax$Elm$Syntax$Node$combine,
													F2(
														function (name, value) {
															return {aN: name, o: value};
														}),
													functionDeclarationAfterDocumentation.a4,
													signature.o))
										}))
							};
						} else {
							var _v4 = functionDeclarationAfterDocumentation.a4;
							var startNameRange = _v4.a;
							var _v5 = functionDeclarationAfterDocumentation.u;
							var expressionRange = _v5.a;
							return {
								b: afterDocumentation.b,
								a: A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{cw: expressionRange.cw, b9: start},
									$stil4m$elm_syntax$Elm$Syntax$Declaration$FunctionDeclaration(
										{
											G: A2(
												$stil4m$elm_syntax$Elm$Syntax$Node$Node,
												{cw: expressionRange.cw, b9: startNameRange.b9},
												{M: functionDeclarationAfterDocumentation.M, u: functionDeclarationAfterDocumentation.u, aN: functionDeclarationAfterDocumentation.a4}),
											Q: $elm$core$Maybe$Just(documentation),
											K: $elm$core$Maybe$Nothing
										}))
							};
						}
					case 1:
						var typeDeclarationAfterDocumentation = _v0.a;
						var end = function () {
							var _v6 = typeDeclarationAfterDocumentation.aT;
							if (_v6.b) {
								var _v7 = _v6.a;
								var range = _v7.a;
								return range.cw;
							} else {
								var _v8 = typeDeclarationAfterDocumentation.aJ;
								var headVariantRange = _v8.a;
								return headVariantRange.cw;
							}
						}();
						return {
							b: afterDocumentation.b,
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: end, b9: start},
								$stil4m$elm_syntax$Elm$Syntax$Declaration$CustomTypeDeclaration(
									{
										cq: A2(
											$elm$core$List$cons,
											typeDeclarationAfterDocumentation.aJ,
											$elm$core$List$reverse(typeDeclarationAfterDocumentation.aT)),
										Q: $elm$core$Maybe$Just(documentation),
										bs: typeDeclarationAfterDocumentation.ap,
										aN: typeDeclarationAfterDocumentation.aN
									}))
						};
					case 2:
						var typeAliasDeclarationAfterDocumentation = _v0.a;
						var _v9 = typeAliasDeclarationAfterDocumentation.o;
						var typeAnnotationRange = _v9.a;
						return {
							b: afterDocumentation.b,
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: typeAnnotationRange.cw, b9: start},
								$stil4m$elm_syntax$Elm$Syntax$Declaration$AliasDeclaration(
									{
										Q: $elm$core$Maybe$Just(documentation),
										bs: typeAliasDeclarationAfterDocumentation.ap,
										aN: typeAliasDeclarationAfterDocumentation.aN,
										o: typeAliasDeclarationAfterDocumentation.o
									}))
						};
					default:
						var portDeclarationAfterName = _v0.a;
						var _v10 = portDeclarationAfterName.o;
						var typeAnnotationRange = _v10.a;
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeFilledPrependTo,
								afterDocumentation.b,
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeOne(documentation)),
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: typeAnnotationRange.cw, b9: portDeclarationAfterName.dh},
								$stil4m$elm_syntax$Elm$Syntax$Declaration$PortDeclaration(
									{aN: portDeclarationAfterName.aN, o: portDeclarationAfterName.o}))
						};
				}
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$documentationComment,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedByWithComments(
			A3($lue_bird$elm_syntax_format$ParserFast$oneOf3, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionAfterDocumentation, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeOrTypeAliasDefinitionAfterDocumentation, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$portDeclarationAfterDocumentation))));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionNameNotInfixNode = A4(
	$lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileValidateMapWithRangeWithoutLinebreak,
	$stil4m$elm_syntax$Elm$Syntax$Node$Node,
	$lue_bird$elm_syntax_format$Char$Extra$unicodeIsLowerFast,
	$lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast,
	function (name) {
		if (name === 'infix') {
			return false;
		} else {
			var nameNotInfix = name;
			return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isNotReserved(nameNotInfix);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionDeclarationWithoutDocumentation = A2(
	$lue_bird$elm_syntax_format$ParserFast$oneOf2,
	A2(
		$lue_bird$elm_syntax_format$ParserFast$validate,
		function (result) {
			var _v3 = result.a;
			var decl = _v3.b;
			switch (decl.$) {
				case 0:
					var letFunctionDeclaration = decl.a;
					var _v5 = letFunctionDeclaration.K;
					if (_v5.$ === 1) {
						return true;
					} else {
						var _v6 = _v5.a;
						var signature = _v6.b;
						var _v7 = signature.aN;
						var signatureName = _v7.b;
						var _v8 = letFunctionDeclaration.G;
						var implementation = _v8.b;
						var _v9 = implementation.aN;
						var implementationName = _v9.b;
						return _Utils_eq(implementationName, signatureName);
					}
				case 1:
					return true;
				case 2:
					return true;
				case 3:
					return true;
				case 4:
					return true;
				default:
					return true;
			}
		},
		A7(
			$lue_bird$elm_syntax_format$ParserFast$map6WithStartLocation,
			F7(
				function (startNameStart, startNameNode, commentsAfterStartName, maybeSignature, _arguments, commentsAfterEqual, result) {
					var _v0 = result.a;
					var expressionRange = _v0.a;
					if (maybeSignature.$ === 1) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								result.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfterEqual,
									A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, _arguments.b, commentsAfterStartName))),
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: expressionRange.cw, b9: startNameStart},
								$stil4m$elm_syntax$Elm$Syntax$Declaration$FunctionDeclaration(
									{
										G: A2(
											$stil4m$elm_syntax$Elm$Syntax$Node$Node,
											{cw: expressionRange.cw, b9: startNameStart},
											{M: _arguments.a, u: result.a, aN: startNameNode}),
										Q: $elm$core$Maybe$Nothing,
										K: $elm$core$Maybe$Nothing
									}))
						};
					} else {
						var signature = maybeSignature.a;
						var _v2 = signature.Z;
						var implementationNameRange = _v2.a;
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								result.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfterEqual,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										_arguments.b,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, signature.b, commentsAfterStartName)))),
							a: A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: expressionRange.cw, b9: startNameStart},
								$stil4m$elm_syntax$Elm$Syntax$Declaration$FunctionDeclaration(
									{
										G: A2(
											$stil4m$elm_syntax$Elm$Syntax$Node$Node,
											{cw: expressionRange.cw, b9: implementationNameRange.b9},
											{M: _arguments.a, u: result.a, aN: signature.Z}),
										Q: $elm$core$Maybe$Nothing,
										K: $elm$core$Maybe$Just(
											A3(
												$stil4m$elm_syntax$Elm$Syntax$Node$combine,
												F2(
													function (name, typeAnnotation) {
														return {aN: name, o: typeAnnotation};
													}),
												startNameNode,
												signature.o))
									}))
						};
					}
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionNameNotInfixNode,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A6(
				$lue_bird$elm_syntax_format$ParserFast$map4OrSucceed,
				F4(
					function (commentsBeforeTypeAnnotation, typeAnnotationResult, implementationName, afterImplementationName) {
						return $elm$core$Maybe$Just(
							{
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									afterImplementationName,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										implementationName.b,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, typeAnnotationResult.b, commentsBeforeTypeAnnotation))),
								Z: implementationName.a,
								o: typeAnnotationResult.a
							});
					}),
				A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedBy($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				$elm$core$Maybe$Nothing),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionFollowedByWhitespaceAndComments)),
	A9(
		$lue_bird$elm_syntax_format$ParserFast$map8WithStartLocation,
		F9(
			function (start, commentsBeforeTypeAnnotation, typeAnnotationResult, commentsBetweenTypeAndName, nameNode, afterImplementationName, _arguments, commentsAfterEqual, result) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						result.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterEqual,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								_arguments.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									afterImplementationName,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										commentsBetweenTypeAndName,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, typeAnnotationResult.b, commentsBeforeTypeAnnotation)))))),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{
							cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(result.a).cw,
							b9: start
						},
						$stil4m$elm_syntax$Elm$Syntax$Declaration$FunctionDeclaration(
							{
								G: A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(result.a).cw,
										b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(nameNode).b9
									},
									{M: _arguments.a, u: result.a, aN: nameNode}),
								Q: $elm$core$Maybe$Nothing,
								K: $elm$core$Maybe$Just(
									A2(
										$stil4m$elm_syntax$Elm$Syntax$Node$Node,
										{
											cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(typeAnnotationResult.a).cw,
											b9: start
										},
										{
											aN: A2(
												$stil4m$elm_syntax$Elm$Syntax$Node$Node,
												{cw: start, b9: start},
												$stil4m$elm_syntax$Elm$Syntax$Node$value(nameNode)),
											o: typeAnnotationResult.a
										}))
							}))
				};
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndented,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$parameterPatternsEqual,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expressionFollowedByWhitespaceAndComments));
var $stil4m$elm_syntax$Elm$Syntax$Declaration$InfixDeclaration = function (a) {
	return {$: 4, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixDirection = A3(
	$lue_bird$elm_syntax_format$ParserFast$oneOf3,
	A2(
		$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
		$stil4m$elm_syntax$Elm$Syntax$Node$Node,
		A2($lue_bird$elm_syntax_format$ParserFast$keyword, 'right', 1)),
	A2(
		$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
		$stil4m$elm_syntax$Elm$Syntax$Node$Node,
		A2($lue_bird$elm_syntax_format$ParserFast$keyword, 'left', 0)),
	A2(
		$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
		$stil4m$elm_syntax$Elm$Syntax$Node$Node,
		A2($lue_bird$elm_syntax_format$ParserFast$keyword, 'non', 2)));
var $lue_bird$elm_syntax_format$ParserFast$errorAsOffsetAndInt = {cI: 0, i: -1};
var $lue_bird$elm_syntax_format$ParserFast$convertIntegerDecimal = F2(
	function (offset, src) {
		var _v0 = A3($elm$core$String$slice, offset, offset + 1, src);
		switch (_v0) {
			case '0':
				return {cI: 0, i: offset + 1};
			case '1':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 1, offset + 1, src);
			case '2':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 2, offset + 1, src);
			case '3':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 3, offset + 1, src);
			case '4':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 4, offset + 1, src);
			case '5':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 5, offset + 1, src);
			case '6':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 6, offset + 1, src);
			case '7':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 7, offset + 1, src);
			case '8':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 8, offset + 1, src);
			case '9':
				return A3($lue_bird$elm_syntax_format$ParserFast$convert0OrMore0To9s, 9, offset + 1, src);
			default:
				return $lue_bird$elm_syntax_format$ParserFast$errorAsOffsetAndInt;
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$integerDecimalMapWithRange = function (rangeAndIntToRes) {
	return function (s0) {
		var s1 = A2($lue_bird$elm_syntax_format$ParserFast$convertIntegerDecimal, s0.i, s0.g);
		if (_Utils_eq(s1.i, -1)) {
			return $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
		} else {
			var newColumn = s0.co + (s1.i - s0.i);
			return A2(
				$lue_bird$elm_syntax_format$ParserFast$Good,
				A2(
					rangeAndIntToRes,
					{
						cw: {cp: newColumn, c9: s0.c9},
						b9: {cp: s0.co, c9: s0.c9}
					},
					s1.cI),
				{co: newColumn, m: s0.m, i: s1.i, c9: s0.c9, g: s0.g});
		}
	};
};
var $lue_bird$elm_syntax_format$ParserFast$map9WithRange = function (func) {
	return function (_v0) {
		return function (_v1) {
			return function (_v2) {
				return function (_v3) {
					return function (_v4) {
						return function (_v5) {
							return function (_v6) {
								return function (_v7) {
									return function (_v8) {
										var parseA = _v0;
										var parseB = _v1;
										var parseC = _v2;
										var parseD = _v3;
										var parseE = _v4;
										var parseF = _v5;
										var parseG = _v6;
										var parseH = _v7;
										var parseI = _v8;
										return function (s0) {
											var _v9 = parseA(s0);
											if (_v9.$ === 1) {
												var committed = _v9.a;
												var x = _v9.b;
												return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
											} else {
												var a = _v9.a;
												var s1 = _v9.b;
												var _v10 = parseB(s1);
												if (_v10.$ === 1) {
													var x = _v10.b;
													return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
												} else {
													var b = _v10.a;
													var s2 = _v10.b;
													var _v11 = parseC(s2);
													if (_v11.$ === 1) {
														var x = _v11.b;
														return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
													} else {
														var c = _v11.a;
														var s3 = _v11.b;
														var _v12 = parseD(s3);
														if (_v12.$ === 1) {
															var x = _v12.b;
															return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
														} else {
															var d = _v12.a;
															var s4 = _v12.b;
															var _v13 = parseE(s4);
															if (_v13.$ === 1) {
																var x = _v13.b;
																return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
															} else {
																var e = _v13.a;
																var s5 = _v13.b;
																var _v14 = parseF(s5);
																if (_v14.$ === 1) {
																	var x = _v14.b;
																	return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
																} else {
																	var f = _v14.a;
																	var s6 = _v14.b;
																	var _v15 = parseG(s6);
																	if (_v15.$ === 1) {
																		var x = _v15.b;
																		return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
																	} else {
																		var g = _v15.a;
																		var s7 = _v15.b;
																		var _v16 = parseH(s7);
																		if (_v16.$ === 1) {
																			var x = _v16.b;
																			return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
																		} else {
																			var h = _v16.a;
																			var s8 = _v16.b;
																			var _v17 = parseI(s8);
																			if (_v17.$ === 1) {
																				var x = _v17.b;
																				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
																			} else {
																				var i = _v17.a;
																				var s9 = _v17.b;
																				return A2(
																					$lue_bird$elm_syntax_format$ParserFast$Good,
																					func(
																						{
																							cw: {cp: s9.co, c9: s9.c9},
																							b9: {cp: s0.co, c9: s0.c9}
																						})(a)(b)(c)(d)(e)(f)(g)(h)(i),
																					s9);
																			}
																		}
																	}
																}
															}
														}
													}
												}
											}
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
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixDeclaration = $lue_bird$elm_syntax_format$ParserFast$map9WithRange(
	function (range) {
		return function (commentsAfterInfix) {
			return function (direction) {
				return function (commentsAfterDirection) {
					return function (precedence) {
						return function (commentsAfterPrecedence) {
							return function (operator) {
								return function (commentsAfterOperator) {
									return function (commentsAfterEqual) {
										return function (fn) {
											return {
												b: A2(
													$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
													commentsAfterEqual,
													A2(
														$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
														commentsAfterOperator,
														A2(
															$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
															commentsAfterPrecedence,
															A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterDirection, commentsAfterInfix)))),
												a: A2(
													$stil4m$elm_syntax$Elm$Syntax$Node$Node,
													range,
													$stil4m$elm_syntax$Elm$Syntax$Declaration$InfixDeclaration(
														{aw: direction, dL: fn, d7: operator, d9: precedence}))
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
	})(
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'infix', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixDirection)($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)(
	$lue_bird$elm_syntax_format$ParserFast$integerDecimalMapWithRange($stil4m$elm_syntax$Elm$Syntax$Node$Node))($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)(
	A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'(',
		A4(
			$lue_bird$elm_syntax_format$ParserFast$whileAtMost3WithoutLinebreakAnd2PartUtf16ValidateMapWithRangeBacktrackableFollowedBySymbol,
			F2(
				function (operatorRange, operator) {
					return A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{
							cw: {cp: operatorRange.cw.cp + 1, c9: operatorRange.cw.c9},
							b9: {cp: operatorRange.b9.cp - 1, c9: operatorRange.b9.c9}
						},
						operator);
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isOperatorSymbolCharAsString,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$isAllowedOperatorToken,
			')')))($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)(
	A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNode);
var $lue_bird$elm_syntax_format$ParserFast$oneOf5 = F5(
	function (_v0, _v1, _v2, _v3, _v4) {
		var attemptFirst = _v0;
		var attemptSecond = _v1;
		var attemptThird = _v2;
		var attemptFourth = _v3;
		var attemptFifth = _v4;
		return function (s) {
			var _v5 = attemptFirst(s);
			if (!_v5.$) {
				var firstGood = _v5;
				return firstGood;
			} else {
				var firstBad = _v5;
				var firstCommitted = firstBad.a;
				if (firstCommitted) {
					return firstBad;
				} else {
					var _v6 = attemptSecond(s);
					if (!_v6.$) {
						var secondGood = _v6;
						return secondGood;
					} else {
						var secondBad = _v6;
						var secondCommitted = secondBad.a;
						if (secondCommitted) {
							return secondBad;
						} else {
							var _v7 = attemptThird(s);
							if (!_v7.$) {
								var thirdGood = _v7;
								return thirdGood;
							} else {
								var thirdBad = _v7;
								var thirdCommitted = thirdBad.a;
								if (thirdCommitted) {
									return thirdBad;
								} else {
									var _v8 = attemptFourth(s);
									if (!_v8.$) {
										var fourthGood = _v8;
										return fourthGood;
									} else {
										var fourthBad = _v8;
										var fourthCommitted = fourthBad.a;
										if (fourthCommitted) {
											return fourthBad;
										} else {
											var _v9 = attemptFifth(s);
											if (!_v9.$) {
												var fifthGood = _v9;
												return fifthGood;
											} else {
												var fifthBad = _v9;
												var fifthCommitted = fifthBad.a;
												return fifthCommitted ? fifthBad : $lue_bird$elm_syntax_format$ParserFast$pStepBadBacktracking;
											}
										}
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$portDeclarationWithoutDocumentation = A6(
	$lue_bird$elm_syntax_format$ParserFast$map5,
	F5(
		function (commentsAfterPort, nameNode, commentsAfterName, commentsAfterColon, typeAnnotationResult) {
			var _v0 = typeAnnotationResult.a;
			var typeRange = _v0.a;
			var _v1 = nameNode;
			var nameRange = _v1.a;
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					typeAnnotationResult.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						commentsAfterColon,
						A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterName, commentsAfterPort))),
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					{
						cw: typeRange.cw,
						b9: {cp: 1, c9: nameRange.b9.c9}
					},
					$stil4m$elm_syntax$Elm$Syntax$Declaration$PortDeclaration(
						{aN: nameNode, o: typeAnnotationResult.a}))
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'port', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseNodeUnderscoreSuffixingKeywords,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ':', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeDeclarationWithoutDocumentation = function (a) {
	return {$: 0, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$customTypeDefinitionWithoutDocumentationAfterTypePrefix = A8(
	$lue_bird$elm_syntax_format$ParserFast$map7,
	F7(
		function (name, commentsAfterName, parameters, commentsAfterEqual, commentsBeforeHeadVariant, headVariant, tailVariantsReverse) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					tailVariantsReverse.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						headVariant.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsBeforeHeadVariant,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterEqual,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, parameters.b, commentsAfterName))))),
				a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeDeclarationWithoutDocumentation(
					{aJ: headVariant.a, aN: name, ap: parameters.a, aT: tailVariantsReverse.a})
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeGenericListEquals,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A2(
		$lue_bird$elm_syntax_format$ParserFast$orSucceed,
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '|', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$variantDeclarationFollowedByWhitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithCommentsReverse(
		A2(
			$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
			'|',
			A4(
				$lue_bird$elm_syntax_format$ParserFast$map3,
				F3(
					function (commentsBeforePipe, commentsWithExtraPipe, variantResult) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								variantResult.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraPipe, commentsBeforePipe)),
							a: variantResult.a
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$orSucceed,
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '|', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$variantDeclarationFollowedByWhitespaceAndComments))));
var $lue_bird$elm_syntax_format$ParserFast$map2WithStartLocation = F3(
	function (func, _v0, _v1) {
		var parseA = _v0;
		var parseB = _v1;
		return function (s0) {
			var _v2 = parseA(s0);
			if (_v2.$ === 1) {
				var committed = _v2.a;
				var x = _v2.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v2.a;
				var s1 = _v2.b;
				var _v3 = parseB(s1);
				if (_v3.$ === 1) {
					var x = _v3.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v3.a;
					var s2 = _v3.b;
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						A3(
							func,
							{cp: s0.co, c9: s0.c9},
							a,
							b),
						s2);
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeAliasDeclarationWithoutDocumentation = function (a) {
	return {$: 1, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAliasDefinitionWithoutDocumentationAfterTypePrefix = A7(
	$lue_bird$elm_syntax_format$ParserFast$map6,
	F6(
		function (commentsAfterAlias, name, commentsAfterName, parameters, commentsAfterEqual, typeAnnotationResult) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					typeAnnotationResult.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						commentsAfterEqual,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							parameters.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterName, commentsAfterAlias)))),
				a: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$TypeAliasDeclarationWithoutDocumentation(
					{aN: name, ap: parameters.a, o: typeAnnotationResult.a})
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'alias', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeGenericListEquals,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$type_);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeOrTypeAliasDefinitionWithoutDocumentation = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithStartLocation,
	F3(
		function (start, commentsAfterType, afterStart) {
			var allComments = A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, afterStart.b, commentsAfterType);
			var _v0 = afterStart.a;
			if (!_v0.$) {
				var typeDeclarationAfterDocumentation = _v0.a;
				var end = function () {
					var _v1 = typeDeclarationAfterDocumentation.aT;
					if (_v1.b) {
						var _v2 = _v1.a;
						var range = _v2.a;
						return range.cw;
					} else {
						var _v3 = typeDeclarationAfterDocumentation.aJ;
						var headVariantRange = _v3.a;
						return headVariantRange.cw;
					}
				}();
				return {
					b: allComments,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: end, b9: start},
						$stil4m$elm_syntax$Elm$Syntax$Declaration$CustomTypeDeclaration(
							{
								cq: A2(
									$elm$core$List$cons,
									typeDeclarationAfterDocumentation.aJ,
									$elm$core$List$reverse(typeDeclarationAfterDocumentation.aT)),
								Q: $elm$core$Maybe$Nothing,
								bs: typeDeclarationAfterDocumentation.ap,
								aN: typeDeclarationAfterDocumentation.aN
							}))
				};
			} else {
				var typeAliasDeclarationAfterDocumentation = _v0.a;
				var _v4 = typeAliasDeclarationAfterDocumentation.o;
				var typeAnnotationRange = _v4.a;
				return {
					b: allComments,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: typeAnnotationRange.cw, b9: start},
						$stil4m$elm_syntax$Elm$Syntax$Declaration$AliasDeclaration(
							{Q: $elm$core$Maybe$Nothing, bs: typeAliasDeclarationAfterDocumentation.ap, aN: typeAliasDeclarationAfterDocumentation.aN, o: typeAliasDeclarationAfterDocumentation.o}))
				};
			}
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'type', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	A2($lue_bird$elm_syntax_format$ParserFast$oneOf2, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeAliasDefinitionWithoutDocumentationAfterTypePrefix, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$customTypeDefinitionWithoutDocumentationAfterTypePrefix));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$declaration = A5($lue_bird$elm_syntax_format$ParserFast$oneOf5, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionDeclarationWithoutDocumentation, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$declarationWithDocumentation, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeOrTypeAliasDefinitionWithoutDocumentation, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$portDeclarationWithoutDocumentation, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixDeclaration);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$declarationIsPort = function (syntaxDeclaration) {
	switch (syntaxDeclaration.$) {
		case 3:
			return true;
		case 0:
			return false;
		case 1:
			return false;
		case 2:
			return false;
		case 4:
			return false;
		default:
			return false;
	}
};
var $stil4m$elm_syntax$Elm$Syntax$Exposing$All = function (a) {
	return {$: 0, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Exposing$Explicit = function (a) {
	return {$: 1, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Exposing$FunctionExpose = function (a) {
	return {$: 1, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionExpose = $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseMapWithRange(
	F2(
		function (range, name) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Exposing$FunctionExpose(name))
			};
		}));
var $stil4m$elm_syntax$Elm$Syntax$Exposing$InfixExpose = function (a) {
	return {$: 0, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixExpose = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, infixName, _v0) {
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty,
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Exposing$InfixExpose(infixName))
			};
		}),
	A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'(',
		A2(
			$lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileWithoutLinebreak,
			function (c) {
				return (c !== ')') && ((c !== '\n') && (c !== ' '));
			},
			function (c) {
				return (c !== ')') && ((c !== '\n') && (c !== ' '));
			})),
	A2($lue_bird$elm_syntax_format$ParserFast$symbol, ')', 0));
var $stil4m$elm_syntax$Elm$Syntax$Exposing$TypeExpose = function (a) {
	return {$: 3, a: a};
};
var $stil4m$elm_syntax$Elm$Syntax$Exposing$TypeOrAliasExpose = function (a) {
	return {$: 2, a: a};
};
var $lue_bird$elm_syntax_format$ParserFast$map2WithRangeOrSucceed = F4(
	function (func, _v0, _v1, fallback) {
		var parseA = _v0;
		var parseB = _v1;
		return function (s0) {
			var _v2 = parseA(s0);
			if (_v2.$ === 1) {
				var c1 = _v2.a;
				var x = _v2.b;
				return c1 ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x) : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallback, s0);
			} else {
				var a = _v2.a;
				var s1 = _v2.b;
				var _v3 = parseB(s1);
				if (_v3.$ === 1) {
					var x = _v3.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v3.a;
					var s2 = _v3.b;
					return A2(
						$lue_bird$elm_syntax_format$ParserFast$Good,
						A3(
							func,
							{
								cw: {cp: s2.co, c9: s2.c9},
								b9: {cp: s0.co, c9: s0.c9}
							},
							a,
							b),
						s2);
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeExpose = A4(
	$lue_bird$elm_syntax_format$ParserFast$map3,
	F3(
		function (_v0, commentsBeforeMaybeOpen, maybeOpen) {
			var typeNameRange = _v0.a;
			var typeExposeName = _v0.b;
			if (maybeOpen.$ === 1) {
				return {
					b: commentsBeforeMaybeOpen,
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						typeNameRange,
						$stil4m$elm_syntax$Elm$Syntax$Exposing$TypeOrAliasExpose(typeExposeName))
				};
			} else {
				var open = maybeOpen.a;
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, open.b, commentsBeforeMaybeOpen),
					a: A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						{cw: open.a.cw, b9: typeNameRange.b9},
						$stil4m$elm_syntax$Elm$Syntax$Exposing$TypeExpose(
							{
								aN: typeExposeName,
								d6: $elm$core$Maybe$Just(open.a)
							}))
				};
			}
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A4(
		$lue_bird$elm_syntax_format$ParserFast$map2WithRangeOrSucceed,
		F3(
			function (range, left, right) {
				return $elm$core$Maybe$Just(
					{
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, right, left),
						a: range
					});
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '(', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
			')',
			A2(
				$lue_bird$elm_syntax_format$ParserFast$oneOf2,
				A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '...', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
				A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '..', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))),
		$elm$core$Maybe$Nothing));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expose = A3($lue_bird$elm_syntax_format$ParserFast$oneOf3, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$functionExpose, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$typeExpose, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$infixExpose);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposingWithinParensExplicitFollowedByWhitespaceAndCommentsMap = function (exposingToSyntax) {
	return A5(
		$lue_bird$elm_syntax_format$ParserFast$map4,
		F4(
			function (commentsBeforeHeadElement, headElement, commentsAfterHeadElement, tailElements) {
				return {
					b: A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						tailElements.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							commentsAfterHeadElement,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, headElement.b, commentsBeforeHeadElement))),
					a: exposingToSyntax(
						$stil4m$elm_syntax$Elm$Syntax$Exposing$Explicit(
							A2($elm$core$List$cons, headElement.a, tailElements.a)))
				};
			}),
		A2(
			$lue_bird$elm_syntax_format$ParserFast$orSucceed,
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expose,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
				',',
				A5(
					$lue_bird$elm_syntax_format$ParserFast$map4,
					F4(
						function (commentsBefore, commentsWithExtraComma, result, commentsAfter) {
							return {
								b: A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
									commentsAfter,
									A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										result.b,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsWithExtraComma, commentsBefore))),
								a: result.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					A2(
						$lue_bird$elm_syntax_format$ParserFast$orSucceed,
						A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, ',', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$expose,
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))));
};
var $lue_bird$elm_syntax_format$ParserFast$map3OrSucceed = F5(
	function (func, _v0, _v1, _v2, fallback) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		return function (s0) {
			var _v3 = parseA(s0);
			if (_v3.$ === 1) {
				var c1 = _v3.a;
				var x = _v3.b;
				return c1 ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x) : A2($lue_bird$elm_syntax_format$ParserFast$Good, fallback, s0);
			} else {
				var a = _v3.a;
				var s1 = _v3.b;
				var _v4 = parseB(s1);
				if (_v4.$ === 1) {
					var x = _v4.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v4.a;
					var s2 = _v4.b;
					var _v5 = parseC(s2);
					if (_v5.$ === 1) {
						var x = _v5.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v5.a;
						var s3 = _v5.b;
						return A2(
							$lue_bird$elm_syntax_format$ParserFast$Good,
							A3(func, a, b, c),
							s3);
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$map5WithStartLocation = F6(
	function (func, _v0, _v1, _v2, _v3, _v4) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		return function (s0) {
			var _v5 = parseA(s0);
			if (_v5.$ === 1) {
				var committed = _v5.a;
				var x = _v5.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v5.a;
				var s1 = _v5.b;
				var _v6 = parseB(s1);
				if (_v6.$ === 1) {
					var x = _v6.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v6.a;
					var s2 = _v6.b;
					var _v7 = parseC(s2);
					if (_v7.$ === 1) {
						var x = _v7.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v7.a;
						var s3 = _v7.b;
						var _v8 = parseD(s3);
						if (_v8.$ === 1) {
							var x = _v8.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v8.a;
							var s4 = _v8.b;
							var _v9 = parseE(s4);
							if (_v9.$ === 1) {
								var x = _v9.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v9.a;
								var s5 = _v9.b;
								return A2(
									$lue_bird$elm_syntax_format$ParserFast$Good,
									A6(
										func,
										{cp: s0.co, c9: s0.c9},
										a,
										b,
										c,
										d,
										e),
									s5);
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsFromRightToLeftStackUnsafeHelp = F4(
	function (element, initialFolded, reduce, s0) {
		var parseElement = element;
		var _v0 = parseElement(s0);
		if (!_v0.$) {
			var elementResult = _v0.a;
			var s1 = _v0.b;
			var _v1 = A4($lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsFromRightToLeftStackUnsafeHelp, element, initialFolded, reduce, s1);
			if (!_v1.$) {
				var tailFolded = _v1.a;
				var s2 = _v1.b;
				return A2(
					$lue_bird$elm_syntax_format$ParserFast$Good,
					A2(reduce, elementResult, tailFolded),
					s2);
			} else {
				var tailBad = _v1;
				return tailBad;
			}
		} else {
			var elementCommitted = _v0.a;
			var x = _v0.b;
			return elementCommitted ? A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x) : A2($lue_bird$elm_syntax_format$ParserFast$Good, initialFolded, s0);
		}
	});
var $lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsRightToLeftStackUnsafe = F3(
	function (element, initialFolded, reduce) {
		return function (s) {
			return A4($lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsFromRightToLeftStackUnsafeHelp, element, initialFolded, reduce, s);
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleName = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, head, tail) {
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				range,
				A2($elm$core$List$cons, head, tail));
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase,
	A3(
		$lue_bird$elm_syntax_format$ParserFast$loopWhileSucceedsRightToLeftStackUnsafe,
		A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '.', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercase),
		_List_Nil,
		$elm$core$List$cons));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseMapWithRange = function (rangeAndNameToRes) {
	return A3($lue_bird$elm_syntax_format$ParserFast$ifFollowedByWhileMapWithRangeWithoutLinebreak, rangeAndNameToRes, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsUpperFast, $lue_bird$elm_syntax_format$Char$Extra$unicodeIsAlphaNumOrUnderscoreFast);
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$import_ = A6(
	$lue_bird$elm_syntax_format$ParserFast$map5WithStartLocation,
	F6(
		function (start, commentsAfterImport, mod, commentsAfterModuleName, maybeModuleAlias, maybeExposingResult) {
			var commentsBeforeAlias = A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterModuleName, commentsAfterImport);
			if (maybeModuleAlias.$ === 1) {
				var _v1 = maybeExposingResult.a;
				if (_v1.$ === 1) {
					var _v2 = mod;
					var modRange = _v2.a;
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, maybeExposingResult.b, commentsBeforeAlias),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{cw: modRange.cw, b9: start},
							{ax: $elm$core$Maybe$Nothing, bz: $elm$core$Maybe$Nothing, T: mod})
					};
				} else {
					var exposingListValue = _v1.a;
					var _v3 = exposingListValue;
					var exposingRange = _v3.a;
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, maybeExposingResult.b, commentsBeforeAlias),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{cw: exposingRange.cw, b9: start},
							{
								ax: $elm$core$Maybe$Just(exposingListValue),
								bz: $elm$core$Maybe$Nothing,
								T: mod
							})
					};
				}
			} else {
				var moduleAliasResult = maybeModuleAlias.a;
				var _v4 = maybeExposingResult.a;
				if (_v4.$ === 1) {
					var _v5 = moduleAliasResult.a;
					var aliasRange = _v5.a;
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							maybeExposingResult.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, moduleAliasResult.b, commentsBeforeAlias)),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{cw: aliasRange.cw, b9: start},
							{
								ax: $elm$core$Maybe$Nothing,
								bz: $elm$core$Maybe$Just(moduleAliasResult.a),
								T: mod
							})
					};
				} else {
					var exposingListValue = _v4.a;
					var _v6 = exposingListValue;
					var exposingRange = _v6.a;
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							maybeExposingResult.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, moduleAliasResult.b, commentsBeforeAlias)),
						a: A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							{cw: exposingRange.cw, b9: start},
							{
								ax: $elm$core$Maybe$Just(exposingListValue),
								bz: $elm$core$Maybe$Just(moduleAliasResult.a),
								T: mod
							})
					};
				}
			}
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'import', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleName,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A5(
		$lue_bird$elm_syntax_format$ParserFast$map3OrSucceed,
		F3(
			function (commentsBefore, moduleAliasNode, commentsAfter) {
				return $elm$core$Maybe$Just(
					{
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, commentsBefore),
						a: moduleAliasNode
					});
			}),
		A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'as', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseMapWithRange(
			F2(
				function (range, moduleAlias) {
					return A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						range,
						_List_fromArray(
							[moduleAlias]));
				})),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$elm$core$Maybe$Nothing),
	A4(
		$lue_bird$elm_syntax_format$ParserFast$map2OrSucceed,
		F2(
			function (exposingResult, commentsAfter) {
				return {
					b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, exposingResult.b),
					a: exposingResult.a
				};
			}),
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
			F3(
				function (range, commentsAfterExposing, exposingListInnerResult) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, exposingListInnerResult.b, commentsAfterExposing),
						a: function () {
							var _v7 = exposingListInnerResult.a;
							if (_v7.$ === 1) {
								return $elm$core$Maybe$Nothing;
							} else {
								var exposingListInner = _v7.a;
								return $elm$core$Maybe$Just(
									A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, exposingListInner));
							}
						}()
					};
				}),
			A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, 'exposing', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
			A2(
				$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
				'(',
				A3(
					$lue_bird$elm_syntax_format$ParserFast$map2,
					F2(
						function (commentsBefore, inner) {
							return {
								b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, inner.b, commentsBefore),
								a: inner.a
							};
						}),
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
					A4(
						$lue_bird$elm_syntax_format$ParserFast$oneOf4,
						A2(
							$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
							')',
							A2(
								$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
								F2(
									function (range, comments) {
										return {
											b: comments,
											a: $elm$core$Maybe$Just(
												$stil4m$elm_syntax$Elm$Syntax$Exposing$All(range))
										};
									}),
								A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '...', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
							')',
							A2(
								$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
								F2(
									function (range, comments) {
										return {
											b: comments,
											a: $elm$core$Maybe$Just(
												$stil4m$elm_syntax$Elm$Syntax$Exposing$All(range))
										};
									}),
								A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '..', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$symbol,
							')',
							{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}),
						A2(
							$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
							')',
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposingWithinParensExplicitFollowedByWhitespaceAndCommentsMap($elm$core$Maybe$Just)))))),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		{b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty, a: $elm$core$Maybe$Nothing}));
var $stil4m$elm_syntax$Elm$Syntax$Node$map = F2(
	function (f, _v0) {
		var r = _v0.a;
		var a = _v0.b;
		return A2(
			$stil4m$elm_syntax$Elm$Syntax$Node$Node,
			r,
			f(a));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectWhereClause = A5(
	$lue_bird$elm_syntax_format$ParserFast$map4,
	F4(
		function (fnName, commentsAfterFnName, commentsAfterEqual, fnTypeName) {
			return {
				b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterEqual, commentsAfterFnName),
				a: _Utils_Tuple2(fnName, fnTypeName)
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameLowercaseUnderscoreSuffixingKeywords,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '=', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$nameUppercaseNode);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listFirstWhere = F2(
	function (predicate, list) {
		listFirstWhere:
		while (true) {
			if (!list.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var x = list.a;
				var xs = list.b;
				if (predicate(x)) {
					return $elm$core$Maybe$Just(x);
				} else {
					var $temp$predicate = predicate,
						$temp$list = xs;
					predicate = $temp$predicate;
					list = $temp$list;
					continue listFirstWhere;
				}
			}
		}
	});
var $elm$core$Maybe$map = F2(
	function (f, maybe) {
		if (!maybe.$) {
			var value = maybe.a;
			return $elm$core$Maybe$Just(
				f(value));
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $elm$core$Tuple$second = function (_v0) {
	var y = _v0.b;
	return y;
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whereBlock = A2(
	$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
	'}',
	A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'{',
		A5(
			$lue_bird$elm_syntax_format$ParserFast$map4,
			F4(
				function (commentsBeforeHead, head, commentsAfterHead, tail) {
					var pairs = A2($elm$core$List$cons, head.a, tail.a);
					return {
						b: A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							tail.b,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterHead,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, head.b, commentsBeforeHead))),
						a: {
							bT: A2(
								$elm$core$Maybe$map,
								$elm$core$Tuple$second,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listFirstWhere,
									function (_v0) {
										var fnName = _v0.a;
										if (fnName === 'command') {
											return true;
										} else {
											return false;
										}
									},
									pairs)),
							cc: A2(
								$elm$core$Maybe$map,
								$elm$core$Tuple$second,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$listFirstWhere,
									function (_v2) {
										var fnName = _v2.a;
										if (fnName === 'subscription') {
											return true;
										} else {
											return false;
										}
									},
									pairs))
						}
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectWhereClause,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
				A2(
					$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
					',',
					A4(
						$lue_bird$elm_syntax_format$ParserFast$map3,
						F3(
							function (commentsBefore, v, commentsAfter) {
								return {
									b: A2(
										$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
										commentsAfter,
										A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, v.b, commentsBefore)),
									a: v.a
								};
							}),
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectWhereClause,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments))))));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectWhereClauses = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2,
	F2(
		function (commentsBefore, whereResult) {
			return {
				b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, whereResult.b, commentsBefore),
				a: whereResult.a
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'where', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whereBlock);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposing_ = A2(
	$lue_bird$elm_syntax_format$ParserFast$followedBySymbol,
	')',
	A2(
		$lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy,
		'(',
		A3(
			$lue_bird$elm_syntax_format$ParserFast$map2,
			F2(
				function (commentsBefore, inner) {
					return {
						b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, inner.b, commentsBefore),
						a: inner.a
					};
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
			A3(
				$lue_bird$elm_syntax_format$ParserFast$oneOf3,
				A2(
					$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
					F2(
						function (range, comments) {
							return {
								b: comments,
								a: $stil4m$elm_syntax$Elm$Syntax$Exposing$All(range)
							};
						}),
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '...', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
				A2(
					$lue_bird$elm_syntax_format$ParserFast$mapWithRange,
					F2(
						function (range, comments) {
							return {
								b: comments,
								a: $stil4m$elm_syntax$Elm$Syntax$Exposing$All(range)
							};
						}),
					A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, '..', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments)),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposingWithinParensExplicitFollowedByWhitespaceAndCommentsMap($elm$core$Basics$identity)))));
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposeDefinition = A3(
	$lue_bird$elm_syntax_format$ParserFast$map2WithRange,
	F3(
		function (range, commentsAfterExposing, exposingListInnerResult) {
			return {
				b: A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, exposingListInnerResult.b, commentsAfterExposing),
				a: A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, range, exposingListInnerResult.a)
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$symbolFollowedBy, 'exposing', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposing_);
var $lue_bird$elm_syntax_format$ParserFast$map7WithRange = F8(
	function (func, _v0, _v1, _v2, _v3, _v4, _v5, _v6) {
		var parseA = _v0;
		var parseB = _v1;
		var parseC = _v2;
		var parseD = _v3;
		var parseE = _v4;
		var parseF = _v5;
		var parseG = _v6;
		return function (s0) {
			var _v7 = parseA(s0);
			if (_v7.$ === 1) {
				var committed = _v7.a;
				var x = _v7.b;
				return A2($lue_bird$elm_syntax_format$ParserFast$Bad, committed, x);
			} else {
				var a = _v7.a;
				var s1 = _v7.b;
				var _v8 = parseB(s1);
				if (_v8.$ === 1) {
					var x = _v8.b;
					return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
				} else {
					var b = _v8.a;
					var s2 = _v8.b;
					var _v9 = parseC(s2);
					if (_v9.$ === 1) {
						var x = _v9.b;
						return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
					} else {
						var c = _v9.a;
						var s3 = _v9.b;
						var _v10 = parseD(s3);
						if (_v10.$ === 1) {
							var x = _v10.b;
							return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
						} else {
							var d = _v10.a;
							var s4 = _v10.b;
							var _v11 = parseE(s4);
							if (_v11.$ === 1) {
								var x = _v11.b;
								return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
							} else {
								var e = _v11.a;
								var s5 = _v11.b;
								var _v12 = parseF(s5);
								if (_v12.$ === 1) {
									var x = _v12.b;
									return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
								} else {
									var f = _v12.a;
									var s6 = _v12.b;
									var _v13 = parseG(s6);
									if (_v13.$ === 1) {
										var x = _v13.b;
										return A2($lue_bird$elm_syntax_format$ParserFast$Bad, true, x);
									} else {
										var g = _v13.a;
										var s7 = _v13.b;
										return A2(
											$lue_bird$elm_syntax_format$ParserFast$Good,
											A8(
												func,
												{
													cw: {cp: s7.co, c9: s7.c9},
													b9: {cp: s0.co, c9: s0.c9}
												},
												a,
												b,
												c,
												d,
												e,
												f,
												g),
											s7);
									}
								}
							}
						}
					}
				}
			}
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectModuleDefinition = A8(
	$lue_bird$elm_syntax_format$ParserFast$map7WithRange,
	F8(
		function (range, commentsAfterEffect, commentsAfterModule, name, commentsAfterName, whereClauses, commentsAfterWhereClauses, exp) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					exp.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						commentsAfterWhereClauses,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							whereClauses.b,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								commentsAfterName,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterModule, commentsAfterEffect))))),
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Module$EffectModule(
						{bT: whereClauses.a.bT, ax: exp.a, T: name, cc: whereClauses.a.cc}))
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'effect', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'module', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleName,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectWhereClauses,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposeDefinition);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$normalModuleDefinition = A5(
	$lue_bird$elm_syntax_format$ParserFast$map4WithRange,
	F5(
		function (range, commentsAfterModule, moduleNameNode, commentsAfterModuleName, exposingList) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					exposingList.b,
					A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterModuleName, commentsAfterModule)),
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Module$NormalModule(
						{ax: exposingList.a, T: moduleNameNode}))
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'module', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleName,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposeDefinition);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$portModuleDefinition = A6(
	$lue_bird$elm_syntax_format$ParserFast$map5WithRange,
	F6(
		function (range, commentsAfterPort, commentsAfterModule, moduleNameNode, commentsAfterModuleName, exposingList) {
			return {
				b: A2(
					$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
					exposingList.b,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						commentsAfterModuleName,
						A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfterModule, commentsAfterPort))),
				a: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					range,
					$stil4m$elm_syntax$Elm$Syntax$Module$PortModule(
						{ax: exposingList.a, T: moduleNameNode}))
			};
		}),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'port', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	A2($lue_bird$elm_syntax_format$ParserFast$keywordFollowedBy, 'module', $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleName,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$exposeDefinition);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleHeader = A3($lue_bird$elm_syntax_format$ParserFast$oneOf3, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$normalModuleDefinition, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$portModuleDefinition, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$effectModuleDefinition);
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedByComments = function (nextParser) {
	return A3(
		$lue_bird$elm_syntax_format$ParserFast$map2,
		F2(
			function (commentsBefore, afterComments) {
				return A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, afterComments, commentsBefore);
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(nextParser));
};
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$module_ = A5(
	$lue_bird$elm_syntax_format$ParserFast$map4,
	F4(
		function (moduleHeaderResult, moduleComments, importsResult, declarationsResult) {
			var moduleHeaderBasedOnExistingPorts = function (existingModuleHeaderInfo) {
				return A2(
					$elm$core$List$any,
					function (declarationAndLateImports) {
						return $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$declarationIsPort(
							$stil4m$elm_syntax$Elm$Syntax$Node$value(declarationAndLateImports.G));
					},
					declarationsResult.a) ? $stil4m$elm_syntax$Elm$Syntax$Module$PortModule(existingModuleHeaderInfo) : $stil4m$elm_syntax$Elm$Syntax$Module$NormalModule(existingModuleHeaderInfo);
			};
			var importStartLocation = function () {
				var _v2 = importsResult.a;
				if (_v2.b) {
					var _v3 = _v2.a;
					var import0Range = _v3.a;
					return import0Range.b9;
				} else {
					var _v4 = declarationsResult.a;
					if (_v4.b) {
						var declarationAndLateImports0 = _v4.a;
						return $stil4m$elm_syntax$Elm$Syntax$Node$range(declarationAndLateImports0.G).b9;
					} else {
						return {cp: 1, c9: 2};
					}
				}
			}();
			return {
				b: $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$commentsToList(
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
						declarationsResult.b,
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
							importsResult.b,
							A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, moduleComments, moduleHeaderResult.b)))),
				bl: A2(
					$elm$core$List$map,
					function ($) {
						return $.G;
					},
					declarationsResult.a),
				dN: _Utils_ap(
					A2(
						$elm$core$List$map,
						function (_v0) {
							var lateImport = _v0.b;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								{cw: importStartLocation, b9: importStartLocation},
								lateImport);
						},
						A2(
							$elm$core$List$concatMap,
							function ($) {
								return $.cM;
							},
							declarationsResult.a)),
					importsResult.a),
				dY: A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$map,
					function (syntaxModuleHeader) {
						switch (syntaxModuleHeader.$) {
							case 2:
								var effectModuleHeader = syntaxModuleHeader.a;
								return $stil4m$elm_syntax$Elm$Syntax$Module$EffectModule(effectModuleHeader);
							case 0:
								var normalModuleHeader = syntaxModuleHeader.a;
								return moduleHeaderBasedOnExistingPorts(normalModuleHeader);
							default:
								var normalModuleHeader = syntaxModuleHeader.a;
								return moduleHeaderBasedOnExistingPorts(normalModuleHeader);
						}
					},
					moduleHeaderResult.a)
			};
		}),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedByWithComments($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$moduleHeader),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndentedFollowedByComments(
		A4(
			$lue_bird$elm_syntax_format$ParserFast$map2OrSucceed,
			F2(
				function (moduleDocumentation, commentsAfter) {
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeFilledPrependTo,
						commentsAfter,
						$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeOne(moduleDocumentation));
				}),
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$documentationComment,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndCommentsEndsTopIndented,
			$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropeEmpty)),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$import_),
	$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments(
		$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$topIndentedFollowedBy(
			A4(
				$lue_bird$elm_syntax_format$ParserFast$map3,
				F3(
					function (declarationParsed, commentsAfter, lateImportsResult) {
						return {
							b: A2(
								$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo,
								lateImportsResult.b,
								A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$ropePrependTo, commentsAfter, declarationParsed.b)),
							a: {G: declarationParsed.a, cM: lateImportsResult.a}
						};
					}),
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$declaration,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$whitespaceAndComments,
				$lue_bird$elm_syntax_format$ElmSyntaxParserLenient$manyWithComments($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$import_)))));
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast = F2(
	function (left, right) {
		return ((left.c9 - right.c9) < 0) ? 0 : (((left.c9 - right.c9) > 0) ? 2 : A2($elm$core$Basics$compare, left.cp, right.cp));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsAfter = F2(
	function (end, sortedComments) {
		commentsAfter:
		while (true) {
			if (!sortedComments.b) {
				return _List_Nil;
			} else {
				var _v1 = sortedComments.a;
				var headCommentRange = _v1.a;
				var headComment = _v1.b;
				var tailComments = sortedComments.b;
				var _v2 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.b9, end);
				switch (_v2) {
					case 0:
						var $temp$end = end,
							$temp$sortedComments = tailComments;
						end = $temp$end;
						sortedComments = $temp$sortedComments;
						continue commentsAfter;
					case 2:
						return A2(
							$elm$core$List$cons,
							headComment,
							A2($elm$core$List$map, $stil4m$elm_syntax$Elm$Syntax$Node$value, tailComments));
					default:
						return A2(
							$elm$core$List$cons,
							headComment,
							A2($elm$core$List$map, $stil4m$elm_syntax$Elm$Syntax$Node$value, tailComments));
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange = F2(
	function (range, sortedComments) {
		commentsInRange:
		while (true) {
			if (!sortedComments.b) {
				return _List_Nil;
			} else {
				var _v1 = sortedComments.a;
				var headCommentRange = _v1.a;
				var headComment = _v1.b;
				var tailComments = sortedComments.b;
				var _v2 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.b9, range.b9);
				switch (_v2) {
					case 0:
						var $temp$range = range,
							$temp$sortedComments = tailComments;
						range = $temp$range;
						sortedComments = $temp$sortedComments;
						continue commentsInRange;
					case 1:
						return A2(
							$elm$core$List$cons,
							headComment,
							A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, range, tailComments));
					default:
						var _v3 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.cw, range.cw);
						switch (_v3) {
							case 2:
								return _List_Nil;
							case 0:
								return A2(
									$elm$core$List$cons,
									headComment,
									A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, range, tailComments));
							default:
								return A2(
									$elm$core$List$cons,
									headComment,
									A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, range, tailComments));
						}
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentNodesInRange = F2(
	function (range, sortedComments) {
		commentNodesInRange:
		while (true) {
			if (!sortedComments.b) {
				return _List_Nil;
			} else {
				var headCommentNode = sortedComments.a;
				var tailComments = sortedComments.b;
				var _v1 = headCommentNode;
				var headCommentRange = _v1.a;
				var _v2 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.b9, range.b9);
				switch (_v2) {
					case 0:
						var $temp$range = range,
							$temp$sortedComments = tailComments;
						range = $temp$range;
						sortedComments = $temp$sortedComments;
						continue commentNodesInRange;
					case 1:
						return A2(
							$elm$core$List$cons,
							headCommentNode,
							A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentNodesInRange, range, tailComments));
					default:
						var _v3 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.cw, range.cw);
						switch (_v3) {
							case 2:
								return _List_Nil;
							case 0:
								return A2(
									$elm$core$List$cons,
									headCommentNode,
									A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentNodesInRange, range, tailComments));
							default:
								return A2(
									$elm$core$List$cons,
									headCommentNode,
									A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentNodesInRange, range, tailComments));
						}
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$Print$SingleLine = 0;
var $lue_bird$elm_syntax_format$Print$MultipleLines = 1;
var $elm$core$String$dropLeft = F2(
	function (n, string) {
		return (n < 1) ? string : A3(
			$elm$core$String$slice,
			n,
			$elm$core$String$length(string),
			string);
	});
var $elm$core$String$dropRight = F2(
	function (n, string) {
		return (n < 1) ? string : A3($elm$core$String$slice, 0, -n, string);
	});
var $lue_bird$elm_syntax_format$Print$Exact = F2(
	function (a, b) {
		return {$: 0, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$Print$exactly = function (exactNextString) {
	return A2($lue_bird$elm_syntax_format$Print$Exact, exactNextString, 0);
};
var $lue_bird$elm_syntax_format$Print$FollowedBy = F2(
	function (a, b) {
		return {$: 1, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$Print$followedBy = $lue_bird$elm_syntax_format$Print$FollowedBy;
var $lue_bird$elm_syntax_format$Print$LinebreakIndented = F2(
	function (a, b) {
		return {$: 3, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$Print$linebreakIndented = A2($lue_bird$elm_syntax_format$Print$LinebreakIndented, 0, 0);
var $elm$core$String$lines = _String_lines;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listDropLastIfIs = F2(
	function (lastElementShouldBeRemoved, list) {
		if (!list.b) {
			return _List_Nil;
		} else {
			if (!list.b.b) {
				var onlyElement = list.a;
				return lastElementShouldBeRemoved(onlyElement) ? _List_Nil : _List_fromArray(
					[onlyElement]);
			} else {
				var element0 = list.a;
				var _v1 = list.b;
				var element1 = _v1.a;
				var element2Up = _v1.b;
				return A2(
					$elm$core$List$cons,
					element0,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listDropLastIfIs,
						lastElementShouldBeRemoved,
						A2($elm$core$List$cons, element1, element2Up)));
			}
		}
	});
var $lue_bird$elm_syntax_format$Print$empty = $lue_bird$elm_syntax_format$Print$exactly('');
var $lue_bird$elm_syntax_format$Print$listMapAndFlatten = F2(
	function (elementToPrint, elements) {
		return A3(
			$elm$core$List$foldl,
			F2(
				function (next, soFar) {
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						elementToPrint(next),
						soFar);
				}),
			$lue_bird$elm_syntax_format$Print$empty,
			elements);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningDotDotCurlyClosing = $lue_bird$elm_syntax_format$Print$exactly('{--}');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningMinus = $lue_bird$elm_syntax_format$Print$exactly('{-');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusCurlyClosing = $lue_bird$elm_syntax_format$Print$exactly('-}');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySpaceSpace = $lue_bird$elm_syntax_format$Print$exactly('  ');
var $elm$core$String$startsWith = _String_startsWith;
var $elm$core$String$trim = _String_trim;
var $elm$core$String$trimLeft = _String_trimLeft;
var $elm$core$String$trimRight = _String_trimRight;
var $elm$core$List$maybeCons = F3(
	function (f, mx, xs) {
		var _v0 = f(mx);
		if (!_v0.$) {
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
var $elm$core$String$foldl = _String_foldl;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$spaceCount0OnlySpacesTrue = {bB: true, aS: 0};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineIndentation = function (line) {
	return A3(
		$elm$core$String$foldl,
		F2(
			function (_char, soFar) {
				if (soFar.bB) {
					if (' ' === _char) {
						return {bB: true, aS: soFar.aS + 1};
					} else {
						return {bB: false, aS: soFar.aS};
					}
				} else {
					return soFar;
				}
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$spaceCount0OnlySpacesTrue,
		line).aS;
};
var $elm$core$Basics$min = F2(
	function (x, y) {
		return (_Utils_cmp(x, y) < 0) ? x : y;
	});
var $elm$core$List$minimum = function (list) {
	if (list.b) {
		var x = list.a;
		var xs = list.b;
		return $elm$core$Maybe$Just(
			A3($elm$core$List$foldl, $elm$core$Basics$min, x, xs));
	} else {
		return $elm$core$Maybe$Nothing;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$unindent = function (lines) {
	var nonBlankLines = A2(
		$elm$core$List$filterMap,
		function (line) {
			var _v1 = $elm$core$String$trim(line);
			if (_v1 === '') {
				return $elm$core$Maybe$Nothing;
			} else {
				return $elm$core$Maybe$Just(line);
			}
		},
		lines);
	var _v0 = $elm$core$List$minimum(
		A2($elm$core$List$map, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineIndentation, nonBlankLines));
	if (_v0.$ === 1) {
		return lines;
	} else {
		var minimumIndentation = _v0.a;
		return A2(
			$elm$core$List$map,
			function (line) {
				return A2($elm$core$String$dropLeft, minimumIndentation, line);
			},
			lines);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comment = function (syntaxComment) {
	if (syntaxComment === '{--}') {
		return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningDotDotCurlyClosing;
	} else {
		var nonDirectlyClosingMultiLineComment = syntaxComment;
		if (A2($elm$core$String$startsWith, '--', nonDirectlyClosingMultiLineComment)) {
			return $lue_bird$elm_syntax_format$Print$exactly(
				$elm$core$String$trimRight(nonDirectlyClosingMultiLineComment));
		} else {
			var commentContentLines = $elm$core$String$lines(
				A2(
					$elm$core$String$dropRight,
					2,
					A2($elm$core$String$dropLeft, 2, nonDirectlyClosingMultiLineComment)));
			var commentContentNormal = function () {
				if (!commentContentLines.b) {
					return _List_Nil;
				} else {
					var commentContentLine0 = commentContentLines.a;
					var commentContentLine1Up = commentContentLines.b;
					return A2(
						$elm$core$List$map,
						$elm$core$String$trimRight,
						A2(
							$elm$core$List$cons,
							$elm$core$String$trimLeft(commentContentLine0),
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$unindent(
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listDropLastIfIs,
									function (line) {
										var _v6 = $elm$core$String$trim(line);
										if (_v6 === '') {
											return true;
										} else {
											return false;
										}
									},
									commentContentLine1Up))));
				}
			}();
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusCurlyClosing,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentContentNormal.b) {
							return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySpaceSpace;
						} else {
							if (!commentContentNormal.b.b) {
								var singleLine = commentContentNormal.a;
								return $lue_bird$elm_syntax_format$Print$exactly(' ' + (singleLine + ' '));
							} else {
								var firstLine = commentContentNormal.a;
								var _v2 = commentContentNormal.b;
								var secondLine = _v2.a;
								var thirdLineUp = _v2.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									A2(
										$lue_bird$elm_syntax_format$Print$listMapAndFlatten,
										function (line) {
											if (line === '') {
												return $lue_bird$elm_syntax_format$Print$linebreakIndented;
											} else {
												var lineNotEmpty = line;
												return A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$linebreakIndented,
													$lue_bird$elm_syntax_format$Print$exactly('   ' + lineNotEmpty));
											}
										},
										A2($elm$core$List$cons, secondLine, thirdLineUp)),
									function () {
										if (firstLine === '') {
											return $lue_bird$elm_syntax_format$Print$linebreakIndented;
										} else {
											var lineNotEmpty = firstLine;
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$linebreakIndented,
												$lue_bird$elm_syntax_format$Print$exactly(' ' + lineNotEmpty));
										}
									}());
							}
						}
					}(),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningMinus));
		}
	}
};
var $elm$core$String$contains = _String_contains;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentCanBePartOfCollapsible = function (syntaxComment) {
	if (syntaxComment === '{--}') {
		return false;
	} else {
		var commentNotDirectlyClosed = syntaxComment;
		return A2($elm$core$String$startsWith, '{-', commentNotDirectlyClosed) && (!A2($elm$core$String$contains, '\n', commentNotDirectlyClosed));
	}
};
var $lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten = F3(
	function (elementToPrint, inBetweenPrint, prints) {
		if (!prints.b) {
			return $lue_bird$elm_syntax_format$Print$empty;
		} else {
			var head = prints.a;
			var tail = prints.b;
			return A3(
				$elm$core$List$foldl,
				F2(
					function (next, soFar) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							elementToPrint(next),
							A2($lue_bird$elm_syntax_format$Print$followedBy, inBetweenPrint, soFar));
					}),
				elementToPrint(head),
				tail);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments = function (syntaxComments) {
	return A3($lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comment, $lue_bird$elm_syntax_format$Print$linebreakIndented, syntaxComments);
};
var $lue_bird$elm_syntax_format$Print$listIntersperseAndFlatten = F2(
	function (inBetweenPrint, elements) {
		if (!elements.b) {
			return $lue_bird$elm_syntax_format$Print$empty;
		} else {
			var head = elements.a;
			var tail = elements.b;
			return A3(
				$elm$core$List$foldl,
				F2(
					function (next, soFar) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							next,
							A2($lue_bird$elm_syntax_format$Print$followedBy, inBetweenPrint, soFar));
					}),
				head,
				tail);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printEmptyLineSpreadSingleLine = {e: 0, h: $lue_bird$elm_syntax_format$Print$empty};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySpace = $lue_bird$elm_syntax_format$Print$exactly(' ');
var $lue_bird$elm_syntax_format$Print$indentAtMost4 = function (atMost4) {
	switch (atMost4) {
		case 1:
			return ' ';
		case 2:
			return '  ';
		case 3:
			return '   ';
		default:
			return '    ';
	}
};
var $lue_bird$elm_syntax_format$Print$indentInverseRemainderBy4 = function (inverseRemainderBy4) {
	switch (inverseRemainderBy4) {
		case 0:
			return '    ';
		case 1:
			return '   ';
		case 2:
			return '  ';
		default:
			return ' ';
	}
};
var $lue_bird$elm_syntax_format$Print$toStringWithIndentAndLinebreakIndentAsStringWithRight = F4(
	function (indentIgnoringMultiplesOfBy4, linebreakIndentAsString, right, print) {
		toStringWithIndentAndLinebreakIndentAsStringWithRight:
		while (true) {
			switch (print.$) {
				case 0:
					var string = print.a;
					return string + (right + '');
				case 1:
					var b = print.a;
					var a = print.b;
					var $temp$indentIgnoringMultiplesOfBy4 = indentIgnoringMultiplesOfBy4,
						$temp$linebreakIndentAsString = linebreakIndentAsString,
						$temp$right = A4($lue_bird$elm_syntax_format$Print$toStringWithIndentAndLinebreakIndentAsStringWithRight, indentIgnoringMultiplesOfBy4, linebreakIndentAsString, right, b),
						$temp$print = a;
					indentIgnoringMultiplesOfBy4 = $temp$indentIgnoringMultiplesOfBy4;
					linebreakIndentAsString = $temp$linebreakIndentAsString;
					right = $temp$right;
					print = $temp$print;
					continue toStringWithIndentAndLinebreakIndentAsStringWithRight;
				case 2:
					return '\n' + right;
				case 3:
					return linebreakIndentAsString + (right + '');
				case 4:
					var increase = print.a;
					var innerPrint = print.b;
					var $temp$indentIgnoringMultiplesOfBy4 = (indentIgnoringMultiplesOfBy4 + increase) + 0,
						$temp$linebreakIndentAsString = linebreakIndentAsString + ($lue_bird$elm_syntax_format$Print$indentAtMost4(increase) + ''),
						$temp$right = right,
						$temp$print = innerPrint;
					indentIgnoringMultiplesOfBy4 = $temp$indentIgnoringMultiplesOfBy4;
					linebreakIndentAsString = $temp$linebreakIndentAsString;
					right = $temp$right;
					print = $temp$print;
					continue toStringWithIndentAndLinebreakIndentAsStringWithRight;
				default:
					var innerPrint = print.a;
					var $temp$indentIgnoringMultiplesOfBy4 = 0,
						$temp$linebreakIndentAsString = linebreakIndentAsString + ($lue_bird$elm_syntax_format$Print$indentInverseRemainderBy4(indentIgnoringMultiplesOfBy4 - (((indentIgnoringMultiplesOfBy4 / 4) | 0) * 4)) + ''),
						$temp$right = right,
						$temp$print = innerPrint;
					indentIgnoringMultiplesOfBy4 = $temp$indentIgnoringMultiplesOfBy4;
					linebreakIndentAsString = $temp$linebreakIndentAsString;
					right = $temp$right;
					print = $temp$print;
					continue toStringWithIndentAndLinebreakIndentAsStringWithRight;
			}
		}
	});
var $lue_bird$elm_syntax_format$Print$toStringWithIndent = F2(
	function (indent, print) {
		return A4($lue_bird$elm_syntax_format$Print$toStringWithIndentAndLinebreakIndentAsStringWithRight, indent, '\n', '', print);
	});
var $lue_bird$elm_syntax_format$Print$toString = function (print) {
	return A2($lue_bird$elm_syntax_format$Print$toStringWithIndent, 0, print);
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments = function (commentsToPrint) {
	if (!commentsToPrint.b) {
		return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printEmptyLineSpreadSingleLine;
	} else {
		var comment0 = commentsToPrint.a;
		var comment1Up = commentsToPrint.b;
		var commentPrints = A2(
			$elm$core$List$map,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comment,
			A2($elm$core$List$cons, comment0, comment1Up));
		return A2(
			$elm$core$List$all,
			function (commentPrint) {
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentCanBePartOfCollapsible(
					$lue_bird$elm_syntax_format$Print$toString(commentPrint));
			},
			commentPrints) ? {
			e: 0,
			h: A2($lue_bird$elm_syntax_format$Print$listIntersperseAndFlatten, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySpace, commentPrints)
		} : {
			e: 1,
			h: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
				A2($elm$core$List$cons, comment0, comment1Up))
		};
	}
};
var $lue_bird$elm_syntax_format$Print$Linebreak = F2(
	function (a, b) {
		return {$: 2, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$Print$linebreak = A2($lue_bird$elm_syntax_format$Print$Linebreak, 0, 0);
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$Print$linebreak, $lue_bird$elm_syntax_format$Print$linebreak);
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelMultiLneCommentWithoutWhitespace = A2(
	$lue_bird$elm_syntax_format$Print$followedBy,
	$lue_bird$elm_syntax_format$Print$linebreak,
	A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningDotDotCurlyClosing, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak));
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments = function (syntaxComments) {
	if (!syntaxComments.b) {
		return $lue_bird$elm_syntax_format$Print$empty;
	} else {
		var comment0 = syntaxComments.a;
		var comment1Up = syntaxComments.b;
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A2(
				$lue_bird$elm_syntax_format$Print$listMapAndFlatten,
				function (syntaxComment) {
					if (syntaxComment === '{--}') {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelMultiLneCommentWithoutWhitespace;
					} else {
						var notEmptyMultiLineComment = syntaxComment;
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$linebreak,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comment(notEmptyMultiLineComment));
					}
				},
				comment1Up),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$linebreak,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comment(comment0)));
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak = A2(
	$lue_bird$elm_syntax_format$Print$followedBy,
	$lue_bird$elm_syntax_format$Print$linebreak,
	A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$Print$linebreak, $lue_bird$elm_syntax_format$Print$linebreak));
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsBetweenDocumentationAndDeclaration = function (syntaxComments) {
	if (!syntaxComments.b) {
		return $lue_bird$elm_syntax_format$Print$empty;
	} else {
		var comment0 = syntaxComments.a;
		var comment1Up = syntaxComments.b;
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments(
					A2($elm$core$List$cons, comment0, comment1Up)),
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak));
	}
};
var $lue_bird$elm_syntax_format$Print$lineSpreadWithRemaining = F2(
	function (print, remainingPrints) {
		lineSpreadWithRemaining:
		while (true) {
			switch (print.$) {
				case 0:
					if (!remainingPrints.b) {
						return 0;
					} else {
						var nextPrint = remainingPrints.a;
						var nextRemainingPrints = remainingPrints.b;
						var $temp$print = nextPrint,
							$temp$remainingPrints = nextRemainingPrints;
						print = $temp$print;
						remainingPrints = $temp$remainingPrints;
						continue lineSpreadWithRemaining;
					}
				case 1:
					var b = print.a;
					var a = print.b;
					var $temp$print = a,
						$temp$remainingPrints = A2($elm$core$List$cons, b, remainingPrints);
					print = $temp$print;
					remainingPrints = $temp$remainingPrints;
					continue lineSpreadWithRemaining;
				case 2:
					return 1;
				case 3:
					return 1;
				case 4:
					var innerPrint = print.b;
					var $temp$print = innerPrint,
						$temp$remainingPrints = remainingPrints;
					print = $temp$print;
					remainingPrints = $temp$remainingPrints;
					continue lineSpreadWithRemaining;
				default:
					var innerPrint = print.a;
					var $temp$print = innerPrint,
						$temp$remainingPrints = remainingPrints;
					print = $temp$print;
					remainingPrints = $temp$remainingPrints;
					continue lineSpreadWithRemaining;
			}
		}
	});
var $lue_bird$elm_syntax_format$Print$lineSpread = function (print) {
	lineSpread:
	while (true) {
		switch (print.$) {
			case 0:
				return 0;
			case 1:
				var b = print.a;
				var a = print.b;
				return A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadWithRemaining,
					a,
					_List_fromArray(
						[b]));
			case 2:
				return 1;
			case 3:
				return 1;
			case 4:
				var innerPrint = print.b;
				var $temp$print = innerPrint;
				print = $temp$print;
				continue lineSpread;
			default:
				var innerPrint = print.a;
				var $temp$print = innerPrint;
				print = $temp$print;
				continue lineSpread;
		}
	}
};
var $lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine = F2(
	function (elementLineSpread, lineSpreads) {
		lineSpreadListMapAndCombine:
		while (true) {
			if (!lineSpreads.b) {
				return 0;
			} else {
				var head = lineSpreads.a;
				var tail = lineSpreads.b;
				var _v1 = elementLineSpread(head);
				if (_v1 === 1) {
					return 1;
				} else {
					var $temp$elementLineSpread = elementLineSpread,
						$temp$lineSpreads = tail;
					elementLineSpread = $temp$elementLineSpread;
					lineSpreads = $temp$lineSpreads;
					continue lineSpreadListMapAndCombine;
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$Print$lineSpreadMergeWith = F2(
	function (bLineSpreadLazy, aLineSpread) {
		if (aLineSpread === 1) {
			return 1;
		} else {
			return bLineSpreadLazy(0);
		}
	});
var $lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten = F2(
	function (elementToPrint, elements) {
		return A3(
			$elm$core$List$foldr,
			F2(
				function (next, soFar) {
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						elementToPrint(next),
						soFar);
				}),
			$lue_bird$elm_syntax_format$Print$empty,
			elements);
	});
var $lue_bird$elm_syntax_format$Print$space = $lue_bird$elm_syntax_format$Print$exactly(' ');
var $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented = function (lineSpreadToUse) {
	if (!lineSpreadToUse) {
		return $lue_bird$elm_syntax_format$Print$space;
	} else {
		return $lue_bird$elm_syntax_format$Print$linebreakIndented;
	}
};
var $lue_bird$elm_syntax_format$Print$WithIndentAtNextMultipleOf4 = F2(
	function (a, b) {
		return {$: 5, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4 = function (print) {
	return A2($lue_bird$elm_syntax_format$Print$WithIndentAtNextMultipleOf4, print, 0);
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$construct = F3(
	function (specific, syntaxComments, syntaxConstruct) {
		var argumentPrintsAndCommentsBeforeReverse = A3(
			$elm$core$List$foldl,
			F2(
				function (argument, soFar) {
					var print = A2(specific.bF, syntaxComments, argument);
					return {
						aq: $stil4m$elm_syntax$Elm$Syntax$Node$range(argument).cw,
						at: A2(
							$elm$core$List$cons,
							function () {
								var _v1 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(argument).b9,
										b9: soFar.aq
									},
									syntaxComments);
								if (!_v1.b) {
									return print;
								} else {
									var comment0 = _v1.a;
									var comment1Up = _v1.b;
									var commentsBeforeArgument = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										print,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v2) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(print);
													},
													commentsBeforeArgument.e)),
											commentsBeforeArgument.h));
								}
							}(),
							soFar.at)
					};
				}),
			{aq: syntaxConstruct.c.b9, at: _List_Nil},
			syntaxConstruct.M).at;
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v0) {
				return A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, argumentPrintsAndCommentsBeforeReverse);
			},
			specific.R);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten,
					function (argumentPrintWithCommentsBefore) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							argumentPrintWithCommentsBefore,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread));
					},
					argumentPrintsAndCommentsBeforeReverse)),
			$lue_bird$elm_syntax_format$Print$exactly(syntaxConstruct.b9));
	});
var $lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten = F3(
	function (elementToPrint, inBetweenPrint, elements) {
		if (!elements.b) {
			return $lue_bird$elm_syntax_format$Print$empty;
		} else {
			var head = elements.a;
			var tail = elements.b;
			return A3(
				$elm$core$List$foldl,
				F2(
					function (next, soFar) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							soFar,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								inBetweenPrint,
								elementToPrint(next)));
					}),
				elementToPrint(head),
				tail);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyEqualsSpace = $lue_bird$elm_syntax_format$Print$exactly('= ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyType = $lue_bird$elm_syntax_format$Print$exactly('type');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyVerticalBarSpace = $lue_bird$elm_syntax_format$Print$exactly('| ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedVerticalBarSpace = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyVerticalBarSpace, $lue_bird$elm_syntax_format$Print$linebreakIndented);
var $lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented = function (lineSpreadToUse) {
	if (!lineSpreadToUse) {
		return $lue_bird$elm_syntax_format$Print$empty;
	} else {
		return $lue_bird$elm_syntax_format$Print$linebreakIndented;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange = function (range) {
	return (!(range.cw.c9 - range.b9.c9)) ? 0 : 1;
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace = $lue_bird$elm_syntax_format$Print$exactly(', ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing = $lue_bird$elm_syntax_format$Print$exactly(')');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningSpace = $lue_bird$elm_syntax_format$Print$exactly('( ');
var $lue_bird$elm_syntax_format$Print$WithIndentIncreasedBy = F2(
	function (a, b) {
		return {$: 4, a: a, b: b};
	});
var $lue_bird$elm_syntax_format$Print$withIndentIncreasedBy = $lue_bird$elm_syntax_format$Print$WithIndentIncreasedBy;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$invalidNTuple = F3(
	function (printPartNotParenthesized, syntaxComments, syntaxTuple) {
		var lineSpread = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxTuple.c);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A3(
						$lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten,
						function (part) {
							return A2(
								$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
								2,
								A2(printPartNotParenthesized, syntaxComments, part));
						},
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
							$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
						A2(
							$elm$core$List$cons,
							syntaxTuple.E,
							A2(
								$elm$core$List$cons,
								syntaxTuple.F,
								A2(
									$elm$core$List$cons,
									syntaxTuple.aa,
									A2($elm$core$List$cons, syntaxTuple.bC, syntaxTuple.bD))))),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningSpace)));
	});
var $lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict = F2(
	function (bLineSpreadLazy, aLineSpread) {
		if (aLineSpread === 1) {
			return 1;
		} else {
			return bLineSpreadLazy;
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpening = $lue_bird$elm_syntax_format$Print$exactly('(');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized = F3(
	function (printNotParenthesized, syntax, syntaxComments) {
		var notParenthesizedPrint = A2(printNotParenthesized, syntaxComments, syntax.U);
		var commentsBeforeInner = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntax.U).b9,
				b9: syntax.c.b9
			},
			syntaxComments);
		var commentsBeforeInnerCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsBeforeInner);
		var commentsAfterInner = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: syntax.c.cw,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntax.U).cw
			},
			syntaxComments);
		var commentsAfterInnerCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsAfterInner);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
			commentsAfterInnerCollapsible.e,
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
				commentsBeforeInnerCollapsible.e,
				$lue_bird$elm_syntax_format$Print$lineSpread(notParenthesizedPrint)));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
						1,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!commentsAfterInner.b) {
									return $lue_bird$elm_syntax_format$Print$empty;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										commentsAfterInnerCollapsible.h,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread));
								}
							}(),
							function () {
								if (!commentsBeforeInner.b) {
									return notParenthesizedPrint;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										notParenthesizedPrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
											commentsBeforeInnerCollapsible.h));
								}
							}())),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpening)));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing = $lue_bird$elm_syntax_format$Print$exactly('}');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningSpace = $lue_bird$elm_syntax_format$Print$exactly('{ ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusGreaterThan = $lue_bird$elm_syntax_format$Print$exactly('->');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed = $lue_bird$elm_syntax_format$Print$exactly('()');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listMapAndFlattenToString = F2(
	function (elementToString, elements) {
		return A3(
			$elm$core$List$foldl,
			F2(
				function (next, soFar) {
					return soFar + (elementToString(next) + '');
				}),
			'',
			elements);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$qualifiedReference = function (syntaxReference) {
	var _v0 = syntaxReference.bG;
	if (!_v0.b) {
		return syntaxReference.a9;
	} else {
		var modulePartHead = _v0.a;
		var modulePartTail = _v0.b;
		return modulePartHead + (A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listMapAndFlattenToString,
			function (modulePart) {
				return '.' + modulePart;
			},
			modulePartTail) + ('.' + syntaxReference.a9));
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpening = $lue_bird$elm_syntax_format$Print$exactly('{');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$recordLiteral = F3(
	function (fieldSpecific, syntaxComments, syntaxRecord) {
		var _v0 = syntaxRecord.ag;
		if (!_v0.b) {
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				function () {
					var _v1 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, syntaxRecord.c, syntaxComments);
					if (!_v1.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing;
					} else {
						var comment0 = _v1.a;
						var comment1Up = _v1.b;
						var commentsCollapsed = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
							A2($elm$core$List$cons, comment0, comment1Up));
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(commentsCollapsed.e),
								A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 1, commentsCollapsed.h)));
					}
				}(),
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpening);
		} else {
			var field0 = _v0.a;
			var field1Up = _v0.b;
			var fieldPrintsAndComments = A3(
				$elm$core$List$foldl,
				F2(
					function (_v17, soFar) {
						var _v18 = _v17.b;
						var _v19 = _v18.a;
						var fieldNameRange = _v19.a;
						var fieldName = _v19.b;
						var fieldValueNode = _v18.b;
						var commentsBeforeName = A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
							{cw: fieldNameRange.b9, b9: soFar.cw},
							syntaxComments);
						var _v20 = fieldValueNode;
						var fieldValueRange = _v20.a;
						var commentsBetweenNameAndValue = A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
							{cw: fieldValueRange.b9, b9: fieldNameRange.b9},
							syntaxComments);
						return {
							cw: fieldValueRange.cw,
							d: A2(
								$elm$core$List$cons,
								{
									bU: function () {
										if (!commentsBeforeName.b) {
											return $elm$core$Maybe$Nothing;
										} else {
											var comment0 = commentsBeforeName.a;
											var comment1Up = commentsBeforeName.b;
											return $elm$core$Maybe$Just(
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
													A2($elm$core$List$cons, comment0, comment1Up)));
										}
									}(),
									bV: function () {
										if (!commentsBetweenNameAndValue.b) {
											return $elm$core$Maybe$Nothing;
										} else {
											var comment0 = commentsBetweenNameAndValue.a;
											var comment1Up = commentsBetweenNameAndValue.b;
											return $elm$core$Maybe$Just(
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
													A2($elm$core$List$cons, comment0, comment1Up)));
										}
									}(),
									a: _Utils_Tuple2(
										A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fieldNameRange, fieldName),
										fieldValueNode),
									ae: A2(fieldSpecific.b8, syntaxComments, fieldValueNode)
								},
								soFar.d)
						};
					}),
				{cw: syntaxRecord.c.b9, d: _List_Nil},
				A2($elm$core$List$cons, field0, field1Up));
			var commentsAfterFields = A2(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
				{cw: syntaxRecord.c.cw, b9: fieldPrintsAndComments.cw},
				syntaxComments);
			var lineSpread = A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v15) {
					if (!commentsAfterFields.b) {
						return 0;
					} else {
						return 1;
					}
				},
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
					function (_v10) {
						return A2(
							$lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine,
							function (field) {
								return A2(
									$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
									function (_v13) {
										var _v14 = field.bV;
										if (_v14.$ === 1) {
											return 0;
										} else {
											var commentsBetweenNameAndValue = _v14.a;
											return commentsBetweenNameAndValue.e;
										}
									},
									A2(
										$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
										function (_v11) {
											var _v12 = field.bU;
											if (_v12.$ === 1) {
												return 0;
											} else {
												var commentsBeforeName = _v12.a;
												return commentsBeforeName.e;
											}
										},
										$lue_bird$elm_syntax_format$Print$lineSpread(field.ae)));
							},
							fieldPrintsAndComments.d);
					},
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxRecord.c)));
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentsAfterFields.b) {
							return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread);
						} else {
							var comment0 = commentsAfterFields.a;
							var comment1Up = commentsAfterFields.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
										A2($elm$core$List$cons, comment0, comment1Up)),
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
										$lue_bird$elm_syntax_format$Print$linebreak)));
						}
					}(),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A3(
							$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
							function (field) {
								var _v2 = field.a;
								var _v3 = _v2.a;
								var fieldNameRange = _v3.a;
								var fieldName = _v3.b;
								var fieldValue = _v2.b;
								var lineSpreadBetweenNameAndValueNotConsideringComments = function (_v8) {
									return A2(
										$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
										function (_v7) {
											return $lue_bird$elm_syntax_format$Print$lineSpread(field.ae);
										},
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(
											{
												cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(fieldValue).cw,
												b9: fieldNameRange.b9
											}));
								};
								var nameSeparatorValuePrint = A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											field.ae,
											function () {
												var _v5 = field.bV;
												if (_v5.$ === 1) {
													return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
														lineSpreadBetweenNameAndValueNotConsideringComments(0));
												} else {
													var commentsBetweenNameAndValue = _v5.a;
													return A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
															A2(
																$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
																function (_v6) {
																	return $lue_bird$elm_syntax_format$Print$lineSpread(field.ae);
																},
																commentsBetweenNameAndValue.e)),
														A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															commentsBetweenNameAndValue.h,
															$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																A2($lue_bird$elm_syntax_format$Print$lineSpreadMergeWith, lineSpreadBetweenNameAndValueNotConsideringComments, commentsBetweenNameAndValue.e))));
												}
											}())),
									$lue_bird$elm_syntax_format$Print$exactly(fieldName + (' ' + fieldSpecific.b3)));
								return A2(
									$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
									2,
									function () {
										var _v4 = field.bU;
										if (_v4.$ === 1) {
											return nameSeparatorValuePrint;
										} else {
											var commentsBeforeName = _v4.a;
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												nameSeparatorValuePrint,
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsBeforeName.e),
													commentsBeforeName.h));
										}
									}());
							},
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
							fieldPrintsAndComments.d),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningSpace)));
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$triple = F3(
	function (config, syntaxComments, syntaxTriple) {
		var part2Print = A2(config.V, syntaxComments, syntaxTriple.aa);
		var part1Print = A2(config.V, syntaxComments, syntaxTriple.F);
		var part0Print = A2(config.V, syntaxComments, syntaxTriple.E);
		var beforePart2Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTriple.aa).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTriple.F).cw
			},
			syntaxComments);
		var beforePart2CommentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(beforePart2Comments);
		var beforePart1Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTriple.F).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTriple.E).cw
			},
			syntaxComments);
		var beforePart1CommentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(beforePart1Comments);
		var beforePart0Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTriple.E).b9,
				b9: syntaxTriple.c.b9
			},
			syntaxComments);
		var beforePart0CommentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(beforePart0Comments);
		var afterPart2Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: syntaxTriple.c.cw,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTriple.aa).cw
			},
			syntaxComments);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v7) {
				if (afterPart2Comments.b) {
					return 1;
				} else {
					return 0;
				}
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
				beforePart2CommentsCollapsible.e,
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
					beforePart1CommentsCollapsible.e,
					A2($lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict, beforePart0CommentsCollapsible.e, config.R))));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
						2,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!afterPart2Comments.b) {
									return $lue_bird$elm_syntax_format$Print$empty;
								} else {
									var comment0 = afterPart2Comments.a;
									var comment1Up = afterPart2Comments.b;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										$lue_bird$elm_syntax_format$Print$linebreakIndented);
								}
							}(),
							function () {
								if (!beforePart2Comments.b) {
									return part2Print;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										part2Print,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v5) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(part2Print);
													},
													beforePart2CommentsCollapsible.e)),
											beforePart2CommentsCollapsible.h));
								}
							}())),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								A2(
									$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
									2,
									function () {
										if (!beforePart1Comments.b) {
											return part1Print;
										} else {
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												part1Print,
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
														A2(
															$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
															function (_v3) {
																return $lue_bird$elm_syntax_format$Print$lineSpread(part1Print);
															},
															beforePart1CommentsCollapsible.e)),
													beforePart1CommentsCollapsible.h));
										}
									}()),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											A2(
												$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
												2,
												function () {
													if (!beforePart0Comments.b) {
														return part0Print;
													} else {
														return A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															part0Print,
															A2(
																$lue_bird$elm_syntax_format$Print$followedBy,
																$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																	A2(
																		$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
																		function (_v1) {
																			return $lue_bird$elm_syntax_format$Print$lineSpread(part0Print);
																		},
																		beforePart0CommentsCollapsible.e)),
																beforePart0CommentsCollapsible.h));
													}
												}()),
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningSpace)))))))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tuple = F3(
	function (config, syntaxComments, syntaxTuple) {
		var part1Print = A2(config.V, syntaxComments, syntaxTuple.F);
		var part0Print = A2(config.V, syntaxComments, syntaxTuple.E);
		var beforePart1Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTuple.F).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTuple.E).cw
			},
			syntaxComments);
		var beforePart1CommentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(beforePart1Comments);
		var beforePart0Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTuple.E).b9,
				b9: syntaxTuple.c.b9
			},
			syntaxComments);
		var beforePart0CommentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(beforePart0Comments);
		var afterPart1Comments = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: syntaxTuple.c.cw,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTuple.F).cw
			},
			syntaxComments);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v5) {
				if (afterPart1Comments.b) {
					return 1;
				} else {
					return 0;
				}
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
				beforePart1CommentsCollapsible.e,
				A2($lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict, beforePart0CommentsCollapsible.e, config.R)));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
						2,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!afterPart1Comments.b) {
									return $lue_bird$elm_syntax_format$Print$empty;
								} else {
									var comment0 = afterPart1Comments.a;
									var comment1Up = afterPart1Comments.b;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										$lue_bird$elm_syntax_format$Print$linebreakIndented);
								}
							}(),
							function () {
								if (!beforePart1Comments.b) {
									return part1Print;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										part1Print,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v3) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(part1Print);
													},
													beforePart1CommentsCollapsible.e)),
											beforePart1CommentsCollapsible.h));
								}
							}())),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								A2(
									$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
									2,
									function () {
										if (!beforePart0Comments.b) {
											return part0Print;
										} else {
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												part0Print,
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
														A2(
															$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
															function (_v1) {
																return $lue_bird$elm_syntax_format$Print$lineSpread(part0Print);
															},
															beforePart0CommentsCollapsible.e)),
													beforePart0CommentsCollapsible.h));
										}
									}()),
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningSpace))))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeFunctionExpand = function (typeNode) {
	if (typeNode.b.$ === 6) {
		var _v1 = typeNode.b;
		var inType = _v1.a;
		var outType = _v1.b;
		var outTypeExpanded = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeFunctionExpand(outType);
		return {
			bd: A2($elm$core$List$cons, inType, outTypeExpanded.bd),
			a3: outTypeExpanded.a3
		};
	} else {
		var typeNodeNotFunction = typeNode;
		return {bd: _List_Nil, a3: typeNodeNotFunction};
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeIsSpaceSeparated = function (syntaxType) {
	typeIsSpaceSeparated:
	while (true) {
		switch (syntaxType.$) {
			case 0:
				return false;
			case 1:
				var _arguments = syntaxType.b;
				if (!_arguments.b) {
					return false;
				} else {
					return true;
				}
			case 2:
				return false;
			case 3:
				var parts = syntaxType.a;
				if (!parts.b) {
					return false;
				} else {
					if (!parts.b.b) {
						var _v3 = parts.a;
						var inParens = _v3.b;
						var $temp$syntaxType = inParens;
						syntaxType = $temp$syntaxType;
						continue typeIsSpaceSeparated;
					} else {
						if (!parts.b.b.b) {
							var _v4 = parts.b;
							return false;
						} else {
							if (!parts.b.b.b.b) {
								var _v5 = parts.b;
								var _v6 = _v5.b;
								return false;
							} else {
								var _v7 = parts.b;
								var _v8 = _v7.b;
								var _v9 = _v8.b;
								return false;
							}
						}
					}
				}
			case 4:
				return false;
			case 5:
				return false;
			default:
				return true;
		}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeToNotParenthesized = function (_v0) {
	typeToNotParenthesized:
	while (true) {
		var typeRange = _v0.a;
		var syntaxType = _v0.b;
		switch (syntaxType.$) {
			case 0:
				var name = syntaxType.a;
				return A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					typeRange,
					$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$GenericType(name));
			case 1:
				var reference = syntaxType.a;
				var _arguments = syntaxType.b;
				return A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					typeRange,
					A2($stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Typed, reference, _arguments));
			case 2:
				return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, typeRange, $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Unit);
			case 3:
				var parts = syntaxType.a;
				if (!parts.b) {
					return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, typeRange, $stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Unit);
				} else {
					if (!parts.b.b) {
						var inParens = parts.a;
						var $temp$_v0 = inParens;
						_v0 = $temp$_v0;
						continue typeToNotParenthesized;
					} else {
						if (!parts.b.b.b) {
							var part0 = parts.a;
							var _v3 = parts.b;
							var part1 = _v3.a;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								typeRange,
								$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Tupled(
									_List_fromArray(
										[part0, part1])));
						} else {
							if (!parts.b.b.b.b) {
								var part0 = parts.a;
								var _v4 = parts.b;
								var part1 = _v4.a;
								var _v5 = _v4.b;
								var part2 = _v5.a;
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									typeRange,
									$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Tupled(
										_List_fromArray(
											[part0, part1, part2])));
							} else {
								var part0 = parts.a;
								var _v6 = parts.b;
								var part1 = _v6.a;
								var _v7 = _v6.b;
								var part2 = _v7.a;
								var _v8 = _v7.b;
								var part3 = _v8.a;
								var part4Up = _v8.b;
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									typeRange,
									$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Tupled(
										A2(
											$elm$core$List$cons,
											part0,
											A2(
												$elm$core$List$cons,
												part1,
												A2(
													$elm$core$List$cons,
													part2,
													A2($elm$core$List$cons, part3, part4Up))))));
							}
						}
					}
				}
			case 4:
				var fields = syntaxType.a;
				return A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					typeRange,
					$stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$Record(fields));
			case 5:
				var extendedRecordVariableName = syntaxType.a;
				var additionalFieldsNode = syntaxType.b;
				return A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					typeRange,
					A2($stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$GenericRecord, extendedRecordVariableName, additionalFieldsNode));
			default:
				var inType = syntaxType.a;
				var outType = syntaxType.b;
				return A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					typeRange,
					A2($stil4m$elm_syntax$Elm$Syntax$TypeAnnotation$FunctionTypeAnnotation, inType, outType));
		}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeToFunction = function (typeNode) {
	var _v0 = $stil4m$elm_syntax$Elm$Syntax$Node$value(
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeToNotParenthesized(typeNode));
	switch (_v0.$) {
		case 6:
			var inType = _v0.a;
			var outType = _v0.b;
			return $elm$core$Maybe$Just(
				{bt: inType, b5: outType});
		case 0:
			return $elm$core$Maybe$Nothing;
		case 1:
			return $elm$core$Maybe$Nothing;
		case 2:
			return $elm$core$Maybe$Nothing;
		case 3:
			return $elm$core$Maybe$Nothing;
		case 4:
			return $elm$core$Maybe$Nothing;
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeFunctionNotParenthesized = F2(
	function (syntaxComments, _function) {
		var inTypePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfFunction, syntaxComments, _function.bt);
		var afterArrowTypes = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeFunctionExpand(_function.b5);
		var afterArrowTypesBeforeRightestPrintsWithCommentsBefore = A3(
			$elm$core$List$foldl,
			F2(
				function (afterArrowTypeNode, soFar) {
					var print = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfFunction, syntaxComments, afterArrowTypeNode);
					var _v43 = afterArrowTypeNode;
					var afterArrowTypeRange = _v43.a;
					return {
						cw: afterArrowTypeRange.cw,
						d: A2(
							$elm$core$List$cons,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								print,
								function () {
									var _v44 = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
										{cw: afterArrowTypeRange.b9, b9: soFar.cw},
										syntaxComments);
									if (!_v44.b) {
										return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
											$lue_bird$elm_syntax_format$Print$lineSpread(print));
									} else {
										var comment0 = _v44.a;
										var comment1Up = _v44.b;
										var commentsBeforeAfterArrowType = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
											A2($elm$core$List$cons, comment0, comment1Up));
										var lineSpread = A2(
											$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
											function (_v45) {
												return $lue_bird$elm_syntax_format$Print$lineSpread(print);
											},
											commentsBeforeAfterArrowType.e);
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												commentsBeforeAfterArrowType.h,
												$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread)));
									}
								}()),
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(_function.bt).cw,
				d: _List_Nil
			},
			afterArrowTypes.bd);
		var commentsBeforeRightestAfterArrowType = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(afterArrowTypes.a3).b9,
				b9: afterArrowTypesBeforeRightestPrintsWithCommentsBefore.cw
			},
			syntaxComments);
		var commentsCollapsibleBeforeRightestAfterArrowType = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsBeforeRightestAfterArrowType);
		var rightestAfterArrowTypePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfParenthesizedFunction, syntaxComments, afterArrowTypes.a3);
		var rightestAfterArrowTypeWithCommentsBeforePrint = A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			rightestAfterArrowTypePrint,
			function () {
				if (!commentsBeforeRightestAfterArrowType.b) {
					return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
						$lue_bird$elm_syntax_format$Print$lineSpread(rightestAfterArrowTypePrint));
				} else {
					var comment0 = commentsBeforeRightestAfterArrowType.a;
					var comment1Up = commentsBeforeRightestAfterArrowType.b;
					var commentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
						A2($elm$core$List$cons, comment0, comment1Up));
					var lineSpread = A2(
						$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
						function (_v42) {
							return $lue_bird$elm_syntax_format$Print$lineSpread(rightestAfterArrowTypePrint);
						},
						commentsCollapsible.e);
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							commentsCollapsible.h,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread)));
				}
			}());
		var fullLineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v40) {
				return A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, afterArrowTypesBeforeRightestPrintsWithCommentsBefore.d);
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
				commentsCollapsibleBeforeRightestAfterArrowType.e,
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
					function (_v39) {
						return $lue_bird$elm_syntax_format$Print$lineSpread(rightestAfterArrowTypeWithCommentsBeforePrint);
					},
					A2(
						$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
						function (_v38) {
							return $lue_bird$elm_syntax_format$Print$lineSpread(inTypePrint);
						},
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(_function.c)))));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(rightestAfterArrowTypeWithCommentsBeforePrint),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusGreaterThan,
					$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(fullLineSpread))),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				A2(
					$lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten,
					function (printWithCommentsBefore) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(printWithCommentsBefore),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusGreaterThan,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(fullLineSpread)));
					},
					afterArrowTypesBeforeRightestPrintsWithCommentsBefore.d),
				inTypePrint));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized = F2(
	function (syntaxComments, _v25) {
		typeNotParenthesized:
		while (true) {
			var fullRange = _v25.a;
			var syntaxType = _v25.b;
			switch (syntaxType.$) {
				case 2:
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
				case 0:
					var name = syntaxType.a;
					return $lue_bird$elm_syntax_format$Print$exactly(name);
				case 1:
					var _v27 = syntaxType.a;
					var _v28 = _v27.b;
					var referenceQualification = _v28.a;
					var referenceUnqualified = _v28.b;
					var _arguments = syntaxType.b;
					return A3(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$construct,
						{
							R: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(fullRange),
							bF: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfSpaceSeparated
						},
						syntaxComments,
						{
							M: _arguments,
							c: fullRange,
							b9: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$qualifiedReference(
								{bG: referenceQualification, a9: referenceUnqualified})
						});
				case 3:
					var parts = syntaxType.a;
					if (!parts.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
					} else {
						if (!parts.b.b) {
							var inParens = parts.a;
							var commentsBeforeInParens = A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
								{
									cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).b9,
									b9: fullRange.b9
								},
								syntaxComments);
							var commentsAfterInParens = A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
								{
									cw: fullRange.cw,
									b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).cw
								},
								syntaxComments);
							var _v30 = _Utils_Tuple2(commentsBeforeInParens, commentsAfterInParens);
							if ((!_v30.a.b) && (!_v30.b.b)) {
								var $temp$syntaxComments = syntaxComments,
									$temp$_v25 = inParens;
								syntaxComments = $temp$syntaxComments;
								_v25 = $temp$_v25;
								continue typeNotParenthesized;
							} else {
								return A3(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized,
									{
										c: fullRange,
										U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeToNotParenthesized(inParens)
									},
									syntaxComments);
							}
						} else {
							if (!parts.b.b.b) {
								var part0 = parts.a;
								var _v31 = parts.b;
								var part1 = _v31.a;
								return A3(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tuple,
									{
										R: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(fullRange),
										V: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized
									},
									syntaxComments,
									{c: fullRange, E: part0, F: part1});
							} else {
								if (!parts.b.b.b.b) {
									var part0 = parts.a;
									var _v32 = parts.b;
									var part1 = _v32.a;
									var _v33 = _v32.b;
									var part2 = _v33.a;
									return A3(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$triple,
										{
											R: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(fullRange),
											V: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized
										},
										syntaxComments,
										{c: fullRange, E: part0, F: part1, aa: part2});
								} else {
									var part0 = parts.a;
									var _v34 = parts.b;
									var part1 = _v34.a;
									var _v35 = _v34.b;
									var part2 = _v35.a;
									var _v36 = _v35.b;
									var part3 = _v36.a;
									var part4Up = _v36.b;
									return A3(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$invalidNTuple,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized,
										syntaxComments,
										{c: fullRange, E: part0, F: part1, aa: part2, bC: part3, bD: part4Up});
								}
							}
						}
					}
				case 4:
					var fields = syntaxType.a;
					return A3(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$recordLiteral,
						{b3: ':', b8: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized},
						syntaxComments,
						{ag: fields, c: fullRange});
				case 5:
					var recordVariable = syntaxType.a;
					var _v37 = syntaxType.b;
					var fields = _v37.b;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeRecordExtension,
						syntaxComments,
						{ag: fields, c: fullRange, as: recordVariable});
				default:
					var inType = syntaxType.a;
					var outType = syntaxType.b;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeFunctionNotParenthesized,
						syntaxComments,
						{c: fullRange, bt: inType, b5: outType});
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesized = F2(
	function (syntaxComments, typeNode) {
		return A3(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized,
			{
				c: $stil4m$elm_syntax$Elm$Syntax$Node$range(typeNode),
				U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeToNotParenthesized(typeNode)
			},
			syntaxComments);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfFunction = F2(
	function (syntaxComments, typeNode) {
		var _v24 = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeToFunction(typeNode);
		if (!_v24.$) {
			return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesized, syntaxComments, typeNode);
		} else {
			return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized, syntaxComments, typeNode);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfParenthesizedFunction = F2(
	function (syntaxComments, typeNode) {
		var _v22 = $stil4m$elm_syntax$Elm$Syntax$Node$value(typeNode);
		if (((_v22.$ === 3) && _v22.a.b) && (!_v22.a.b.b)) {
			var _v23 = _v22.a;
			var inParens = _v23.a;
			return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfFunction, syntaxComments, inParens);
		} else {
			return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized, syntaxComments, typeNode);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfSpaceSeparated = F2(
	function (syntaxComments, typeNode) {
		return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeIsSpaceSeparated(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(typeNode)) ? A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesized, syntaxComments, typeNode) : A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized, syntaxComments, typeNode);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeRecordExtension = F2(
	function (syntaxComments, syntaxRecordExtension) {
		var recordVariablePrint = $lue_bird$elm_syntax_format$Print$exactly(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxRecordExtension.as));
		var fieldPrintsAndComments = A3(
			$elm$core$List$foldl,
			F2(
				function (_v16, soFar) {
					var _v17 = _v16.b;
					var _v18 = _v17.a;
					var fieldNameRange = _v18.a;
					var fieldName = _v18.b;
					var fieldValueNode = _v17.b;
					var commentsBeforeName = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{cw: fieldNameRange.b9, b9: soFar.cw},
						syntaxComments);
					var _v19 = fieldValueNode;
					var fieldValueRange = _v19.a;
					var commentsBetweenNameAndValue = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{cw: fieldValueRange.b9, b9: fieldNameRange.b9},
						syntaxComments);
					return {
						cw: fieldValueRange.cw,
						d: A2(
							$elm$core$List$cons,
							{
								b0: function () {
									if (!commentsBeforeName.b) {
										return $elm$core$Maybe$Nothing;
									} else {
										var comment0 = commentsBeforeName.a;
										var comment1Up = commentsBeforeName.b;
										return $elm$core$Maybe$Just(
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
												A2($elm$core$List$cons, comment0, comment1Up)));
									}
								}(),
								b1: function () {
									if (!commentsBetweenNameAndValue.b) {
										return $elm$core$Maybe$Nothing;
									} else {
										var comment0 = commentsBetweenNameAndValue.a;
										var comment1Up = commentsBetweenNameAndValue.b;
										return $elm$core$Maybe$Just(
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
												A2($elm$core$List$cons, comment0, comment1Up)));
									}
								}(),
								a: _Utils_Tuple2(
									A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fieldNameRange, fieldName),
									fieldValueNode),
								ae: A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized, syntaxComments, fieldValueNode)
							},
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxRecordExtension.as).cw,
				d: _List_Nil
			},
			syntaxRecordExtension.ag);
		var commentsBeforeRecordVariable = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxRecordExtension.as).b9,
				b9: syntaxRecordExtension.c.b9
			},
			syntaxComments);
		var commentsCollapsibleBeforeRecordVariable = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsBeforeRecordVariable);
		var commentsAfterFields = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{cw: syntaxRecordExtension.c.cw, b9: fieldPrintsAndComments.cw},
			syntaxComments);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v14) {
				if (!commentsAfterFields.b) {
					return 0;
				} else {
					return 1;
				}
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v9) {
					return A2(
						$lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine,
						function (field) {
							return A2(
								$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
								function (_v12) {
									var _v13 = field.b1;
									if (_v13.$ === 1) {
										return 0;
									} else {
										var commentsBetweenNameAndValue = _v13.a;
										return commentsBetweenNameAndValue.e;
									}
								},
								A2(
									$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
									function (_v10) {
										var _v11 = field.b0;
										if (_v11.$ === 1) {
											return 0;
										} else {
											var commentsBeforeName = _v11.a;
											return commentsBeforeName.e;
										}
									},
									$lue_bird$elm_syntax_format$Print$lineSpread(field.ae)));
						},
						fieldPrintsAndComments.d);
				},
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
					commentsCollapsibleBeforeRecordVariable.e,
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxRecordExtension.c))));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!commentsAfterFields.b) {
									return $lue_bird$elm_syntax_format$Print$empty;
								} else {
									var comment0 = commentsAfterFields.a;
									var comment1Up = commentsAfterFields.b;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
											$lue_bird$elm_syntax_format$Print$linebreak));
								}
							}(),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								A3(
									$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
									function (field) {
										var _v1 = field.a;
										var _v2 = _v1.a;
										var fieldNameRange = _v2.a;
										var fieldName = _v2.b;
										var fieldValueNode = _v1.b;
										var lineSpreadBetweenNameAndValueNotConsideringComments = function (_v7) {
											return A2(
												$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
												function (_v6) {
													return $lue_bird$elm_syntax_format$Print$lineSpread(field.ae);
												},
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(
													{
														cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(fieldValueNode).cw,
														b9: fieldNameRange.b9
													}));
										};
										return A2(
											$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
											2,
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
													A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														field.ae,
														function () {
															var _v4 = field.b1;
															if (_v4.$ === 1) {
																return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																	lineSpreadBetweenNameAndValueNotConsideringComments(0));
															} else {
																var commentsBetweenNameAndValue = _v4.a;
																return A2(
																	$lue_bird$elm_syntax_format$Print$followedBy,
																	$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																		A2(
																			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
																			function (_v5) {
																				return $lue_bird$elm_syntax_format$Print$lineSpread(field.ae);
																			},
																			commentsBetweenNameAndValue.e)),
																	A2(
																		$lue_bird$elm_syntax_format$Print$followedBy,
																		commentsBetweenNameAndValue.h,
																		$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																			A2($lue_bird$elm_syntax_format$Print$lineSpreadMergeWith, lineSpreadBetweenNameAndValueNotConsideringComments, commentsBetweenNameAndValue.e))));
															}
														}())),
												function () {
													var _v3 = field.b0;
													if (_v3.$ === 1) {
														return $lue_bird$elm_syntax_format$Print$exactly(fieldName + ' :');
													} else {
														var commentsBeforeName = _v3.a;
														return A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															$lue_bird$elm_syntax_format$Print$exactly(fieldName + ' :'),
															A2(
																$lue_bird$elm_syntax_format$Print$followedBy,
																$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsBeforeName.e),
																commentsBeforeName.h));
													}
												}()));
									},
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
										$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
									fieldPrintsAndComments.d),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyVerticalBarSpace,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))))),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A2(
							$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
							2,
							function () {
								if (!commentsBeforeRecordVariable.b) {
									return recordVariablePrint;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										recordVariablePrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsCollapsibleBeforeRecordVariable.e),
											commentsCollapsibleBeforeRecordVariable.h));
								}
							}()),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningSpace))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationChoiceType = F2(
	function (syntaxComments, syntaxChoiceTypeDeclaration) {
		var parameterPrints = A3(
			$elm$core$List$foldl,
			F2(
				function (parameterName, soFar) {
					var parameterPrintedRange = $stil4m$elm_syntax$Elm$Syntax$Node$range(parameterName);
					var parameterNamePrint = $lue_bird$elm_syntax_format$Print$exactly(
						$stil4m$elm_syntax$Elm$Syntax$Node$value(parameterName));
					return {
						cw: parameterPrintedRange.cw,
						d: A2(
							$elm$core$List$cons,
							function () {
								var _v5 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{cw: parameterPrintedRange.b9, b9: soFar.cw},
									syntaxComments);
								if (!_v5.b) {
									return parameterNamePrint;
								} else {
									var comment0 = _v5.a;
									var comment1Up = _v5.b;
									var commentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										parameterNamePrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsCollapsible.e),
											commentsCollapsible.h));
								}
							}(),
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxChoiceTypeDeclaration.aN).cw,
				d: _List_Nil
			},
			syntaxChoiceTypeDeclaration.bs);
		var parametersLineSpread = A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, parameterPrints.d);
		var variantPrintsWithCommentsBeforeReverse = A3(
			$elm$core$List$foldl,
			F2(
				function (_v2, soFar) {
					var variantRange = _v2.a;
					var variant = _v2.b;
					var variantPrint = A3(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$construct,
						{R: 0, bF: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeParenthesizedIfSpaceSeparated},
						syntaxComments,
						{
							M: variant.M,
							c: variantRange,
							b9: $stil4m$elm_syntax$Elm$Syntax$Node$value(variant.aN)
						});
					var commentsVariantPrint = function () {
						var _v3 = A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
							{
								cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(variant.aN).b9,
								b9: soFar.cw
							},
							syntaxComments);
						if (!_v3.b) {
							return variantPrint;
						} else {
							var comment0 = _v3.a;
							var comment1Up = _v3.b;
							var commentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
								A2($elm$core$List$cons, comment0, comment1Up));
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								variantPrint,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
										A2(
											$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
											function (_v4) {
												return $lue_bird$elm_syntax_format$Print$lineSpread(variantPrint);
											},
											commentsCollapsible.e)),
									commentsCollapsible.h));
						}
					}();
					return {
						cw: variantRange.cw,
						ar: A2($elm$core$List$cons, commentsVariantPrint, soFar.ar)
					};
				}),
			{cw: parameterPrints.cw, ar: _List_Nil},
			syntaxChoiceTypeDeclaration.cq).ar;
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A3(
						$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
						function (variantPrint) {
							return A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 2, variantPrint);
						},
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedVerticalBarSpace,
						variantPrintsWithCommentsBeforeReverse),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyEqualsSpace,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$linebreakIndented,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten,
										function (parameterPrint) {
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												parameterPrint,
												$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread));
										},
										parameterPrints.d)),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$exactly(
										$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxChoiceTypeDeclaration.aN)),
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread))))))),
			function () {
				var _v0 = syntaxChoiceTypeDeclaration.Q;
				if (_v0.$ === 1) {
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyType;
				} else {
					var _v1 = _v0.a;
					var documentationRange = _v1.a;
					var documentation = _v1.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyType,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsBetweenDocumentationAndDeclaration(
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxChoiceTypeDeclaration.aN).b9,
										b9: documentationRange.b9
									},
									syntaxComments)),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$linebreak,
								$lue_bird$elm_syntax_format$Print$exactly(documentation))));
				}
			}());
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$unsafeHexDigitIntToString = function (_int) {
	switch (_int) {
		case 0:
			return '0';
		case 1:
			return '1';
		case 2:
			return '2';
		case 3:
			return '3';
		case 4:
			return '4';
		case 5:
			return '5';
		case 6:
			return '6';
		case 7:
			return '7';
		case 8:
			return '8';
		case 9:
			return '9';
		case 10:
			return 'A';
		case 11:
			return 'B';
		case 12:
			return 'C';
		case 13:
			return 'D';
		case 14:
			return 'E';
		default:
			return 'F';
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intToHexString = function (_int) {
	return (_int < 16) ? $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$unsafeHexDigitIntToString(_int) : ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intToHexString((_int / 16) | 0) + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$unsafeHexDigitIntToString(_int % 16) + ''));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterHex = function (character) {
	return $elm$core$String$toUpper(
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intToHexString(
			$elm$core$Char$toCode(character)));
};
var $miniBill$elm_unicode$Unicode$LetterLowercase = 1;
var $miniBill$elm_unicode$Unicode$LetterModifier = 17;
var $miniBill$elm_unicode$Unicode$LetterOther = 18;
var $miniBill$elm_unicode$Unicode$LetterTitlecase = 2;
var $miniBill$elm_unicode$Unicode$LetterUppercase = 0;
var $miniBill$elm_unicode$Unicode$MarkEnclosing = 5;
var $miniBill$elm_unicode$Unicode$MarkNonSpacing = 3;
var $miniBill$elm_unicode$Unicode$MarkSpacingCombining = 4;
var $miniBill$elm_unicode$Unicode$NumberDecimalDigit = 6;
var $miniBill$elm_unicode$Unicode$NumberLetter = 7;
var $miniBill$elm_unicode$Unicode$NumberOther = 8;
var $miniBill$elm_unicode$Unicode$OtherControl = 12;
var $miniBill$elm_unicode$Unicode$OtherFormat = 13;
var $miniBill$elm_unicode$Unicode$OtherPrivateUse = 15;
var $miniBill$elm_unicode$Unicode$OtherSurrogate = 14;
var $miniBill$elm_unicode$Unicode$PunctuationClose = 22;
var $miniBill$elm_unicode$Unicode$PunctuationConnector = 19;
var $miniBill$elm_unicode$Unicode$PunctuationDash = 20;
var $miniBill$elm_unicode$Unicode$PunctuationFinalQuote = 24;
var $miniBill$elm_unicode$Unicode$PunctuationInitialQuote = 23;
var $miniBill$elm_unicode$Unicode$PunctuationOpen = 21;
var $miniBill$elm_unicode$Unicode$PunctuationOther = 25;
var $miniBill$elm_unicode$Unicode$SeparatorLine = 10;
var $miniBill$elm_unicode$Unicode$SeparatorParagraph = 11;
var $miniBill$elm_unicode$Unicode$SeparatorSpace = 9;
var $miniBill$elm_unicode$Unicode$SymbolCurrency = 27;
var $miniBill$elm_unicode$Unicode$SymbolMath = 26;
var $miniBill$elm_unicode$Unicode$SymbolModifier = 28;
var $miniBill$elm_unicode$Unicode$SymbolOther = 29;
var $miniBill$elm_unicode$Unicode$getCategory = function (c) {
	var code = $elm$core$Char$toCode(c);
	var e = function (hex) {
		return _Utils_eq(hex, code);
	};
	var l = function (hex) {
		return _Utils_cmp(code, hex) < 0;
	};
	var r = F2(
		function (from, to) {
			return (_Utils_cmp(from, code) < 1) && (_Utils_cmp(code, to) < 1);
		});
	return l(256) ? (l(160) ? (l(59) ? (l(41) ? ((code <= 31) ? $elm$core$Maybe$Just(12) : (e(32) ? $elm$core$Maybe$Just(9) : ((A2(r, 33, 35) || A2(r, 37, 39)) ? $elm$core$Maybe$Just(25) : (e(36) ? $elm$core$Maybe$Just(27) : (e(40) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing))))) : (e(41) ? $elm$core$Maybe$Just(22) : ((e(42) || (e(44) || (A2(r, 46, 47) || e(58)))) ? $elm$core$Maybe$Just(25) : (e(43) ? $elm$core$Maybe$Just(26) : (e(45) ? $elm$core$Maybe$Just(20) : (A2(r, 48, 57) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))))) : (l(94) ? ((e(59) || (A2(r, 63, 64) || e(92))) ? $elm$core$Maybe$Just(25) : (A2(r, 60, 62) ? $elm$core$Maybe$Just(26) : (A2(r, 65, 90) ? $elm$core$Maybe$Just(0) : (e(91) ? $elm$core$Maybe$Just(21) : (e(93) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing))))) : ((e(94) || e(96)) ? $elm$core$Maybe$Just(28) : (e(95) ? $elm$core$Maybe$Just(19) : (A2(r, 97, 122) ? $elm$core$Maybe$Just(1) : (e(123) ? $elm$core$Maybe$Just(21) : ((e(124) || e(126)) ? $elm$core$Maybe$Just(26) : (e(125) ? $elm$core$Maybe$Just(22) : (A2(r, 127, 159) ? $elm$core$Maybe$Just(12) : $elm$core$Maybe$Nothing))))))))) : (l(177) ? (l(169) ? (e(160) ? $elm$core$Maybe$Just(9) : ((e(161) || e(167)) ? $elm$core$Maybe$Just(25) : (A2(r, 162, 165) ? $elm$core$Maybe$Just(27) : (e(166) ? $elm$core$Maybe$Just(29) : (e(168) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing))))) : ((e(169) || (e(174) || e(176))) ? $elm$core$Maybe$Just(29) : (e(170) ? $elm$core$Maybe$Just(18) : (e(171) ? $elm$core$Maybe$Just(23) : (e(172) ? $elm$core$Maybe$Just(26) : (e(173) ? $elm$core$Maybe$Just(13) : (e(175) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing))))))) : (l(186) ? (e(177) ? $elm$core$Maybe$Just(26) : ((A2(r, 178, 179) || e(185)) ? $elm$core$Maybe$Just(8) : ((e(180) || e(184)) ? $elm$core$Maybe$Just(28) : (e(181) ? $elm$core$Maybe$Just(1) : (A2(r, 182, 183) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : (e(186) ? $elm$core$Maybe$Just(18) : (e(187) ? $elm$core$Maybe$Just(24) : (A2(r, 188, 190) ? $elm$core$Maybe$Just(8) : (e(191) ? $elm$core$Maybe$Just(25) : ((A2(r, 192, 214) || A2(r, 216, 222)) ? $elm$core$Maybe$Just(0) : ((e(215) || e(247)) ? $elm$core$Maybe$Just(26) : ((A2(r, 223, 246) || A2(r, 248, 255)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))))))))) : (l(9084) ? (l(3085) ? (l(1166) ? (l(488) ? (l(356) ? (l(304) ? (l(279) ? (l(266) ? ((e(256) || (e(258) || (e(260) || (e(262) || e(264))))) ? $elm$core$Maybe$Just(0) : ((e(257) || (e(259) || (e(261) || (e(263) || e(265))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(271) ? ((e(266) || (e(268) || e(270))) ? $elm$core$Maybe$Just(0) : ((e(267) || e(269)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(271) || (e(273) || (e(275) || e(277)))) ? $elm$core$Maybe$Just(1) : ((e(272) || (e(274) || (e(276) || e(278)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(290) ? ((e(279) || (e(281) || (e(283) || (e(285) || (e(287) || e(289)))))) ? $elm$core$Maybe$Just(1) : ((e(280) || (e(282) || (e(284) || (e(286) || e(288))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(296) ? ((e(290) || (e(292) || e(294))) ? $elm$core$Maybe$Just(0) : ((e(291) || (e(293) || e(295))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(296) || (e(298) || (e(300) || e(302)))) ? $elm$core$Maybe$Just(0) : ((e(297) || (e(299) || (e(301) || e(303)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(330) ? (l(316) ? ((e(304) || (e(306) || (e(308) || (e(310) || (e(313) || e(315)))))) ? $elm$core$Maybe$Just(0) : ((e(305) || (e(307) || (e(309) || (A2(r, 311, 312) || e(314))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(321) ? ((e(316) || (e(318) || e(320))) ? $elm$core$Maybe$Just(1) : ((e(317) || e(319)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(321) || (e(323) || (e(325) || e(327)))) ? $elm$core$Maybe$Just(0) : ((e(322) || (e(324) || (e(326) || A2(r, 328, 329)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(342) ? ((e(330) || (e(332) || (e(334) || (e(336) || (e(338) || e(340)))))) ? $elm$core$Maybe$Just(0) : ((e(331) || (e(333) || (e(335) || (e(337) || (e(339) || e(341)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(348) ? ((e(342) || (e(344) || e(346))) ? $elm$core$Maybe$Just(0) : ((e(343) || (e(345) || e(347))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(348) || (e(350) || (e(352) || e(354)))) ? $elm$core$Maybe$Just(0) : ((e(349) || (e(351) || (e(353) || e(355)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))))) : (l(424) ? (l(380) ? (l(366) ? ((e(356) || (e(358) || (e(360) || (e(362) || e(364))))) ? $elm$core$Maybe$Just(0) : ((e(357) || (e(359) || (e(361) || (e(363) || e(365))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(371) ? ((e(366) || (e(368) || e(370))) ? $elm$core$Maybe$Just(0) : ((e(367) || e(369)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(371) || (e(373) || (e(375) || e(378)))) ? $elm$core$Maybe$Just(1) : ((e(372) || (e(374) || (A2(r, 376, 377) || e(379)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(402) ? ((e(380) || (A2(r, 382, 384) || (e(387) || (e(389) || (e(392) || A2(r, 396, 397)))))) ? $elm$core$Maybe$Just(1) : ((e(381) || (A2(r, 385, 386) || (e(388) || (A2(r, 390, 391) || (A2(r, 393, 395) || A2(r, 398, 401)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(414) ? ((e(402) || (e(405) || A2(r, 409, 411))) ? $elm$core$Maybe$Just(1) : ((A2(r, 403, 404) || (A2(r, 406, 408) || A2(r, 412, 413))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(414) || (e(417) || (e(419) || e(421)))) ? $elm$core$Maybe$Just(1) : ((A2(r, 415, 416) || (e(418) || (e(420) || A2(r, 422, 423)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))) : (l(460) ? (l(440) ? ((e(424) || (A2(r, 426, 427) || (e(429) || (e(432) || (e(436) || e(438)))))) ? $elm$core$Maybe$Just(1) : ((e(425) || (e(428) || (A2(r, 430, 431) || (A2(r, 433, 435) || (e(437) || e(439)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(452) ? ((e(440) || e(444)) ? $elm$core$Maybe$Just(0) : ((A2(r, 441, 442) || A2(r, 445, 447)) ? $elm$core$Maybe$Just(1) : ((e(443) || A2(r, 448, 451)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((e(452) || (e(455) || e(458))) ? $elm$core$Maybe$Just(0) : ((e(453) || (e(456) || e(459))) ? $elm$core$Maybe$Just(2) : ((e(454) || e(457)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(472) ? ((e(460) || (e(462) || (e(464) || (e(466) || (e(468) || e(470)))))) ? $elm$core$Maybe$Just(1) : ((e(461) || (e(463) || (e(465) || (e(467) || (e(469) || e(471)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(479) ? ((e(472) || (e(474) || A2(r, 476, 477))) ? $elm$core$Maybe$Just(1) : ((e(473) || (e(475) || e(478))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(479) || (e(481) || (e(483) || (e(485) || e(487))))) ? $elm$core$Maybe$Just(1) : ((e(480) || (e(482) || (e(484) || e(486)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))))) : (l(767) ? (l(540) ? (l(514) ? (l(499) ? ((e(488) || (e(490) || (e(492) || (e(494) || e(497))))) ? $elm$core$Maybe$Just(0) : ((e(489) || (e(491) || (e(493) || A2(r, 495, 496)))) ? $elm$core$Maybe$Just(1) : (e(498) ? $elm$core$Maybe$Just(2) : $elm$core$Maybe$Nothing))) : (l(506) ? ((e(499) || (e(501) || e(505))) ? $elm$core$Maybe$Just(1) : ((e(500) || A2(r, 502, 504)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(506) || (e(508) || (e(510) || e(512)))) ? $elm$core$Maybe$Just(0) : ((e(507) || (e(509) || (e(511) || e(513)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(526) ? ((e(514) || (e(516) || (e(518) || (e(520) || (e(522) || e(524)))))) ? $elm$core$Maybe$Just(0) : ((e(515) || (e(517) || (e(519) || (e(521) || (e(523) || e(525)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(532) ? ((e(526) || (e(528) || e(530))) ? $elm$core$Maybe$Just(0) : ((e(527) || (e(529) || e(531))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(532) || (e(534) || (e(536) || e(538)))) ? $elm$core$Maybe$Just(0) : ((e(533) || (e(535) || (e(537) || e(539)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(572) ? (l(551) ? ((e(540) || (e(542) || (e(544) || (e(546) || (e(548) || e(550)))))) ? $elm$core$Maybe$Just(0) : ((e(541) || (e(543) || (e(545) || (e(547) || e(549))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(557) ? ((e(551) || (e(553) || e(555))) ? $elm$core$Maybe$Just(1) : ((e(552) || (e(554) || e(556))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(557) || (e(559) || (e(561) || A2(r, 563, 569)))) ? $elm$core$Maybe$Just(1) : ((e(558) || (e(560) || (e(562) || A2(r, 570, 571)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(589) ? ((e(572) || (A2(r, 575, 576) || (e(578) || (e(583) || (e(585) || e(587)))))) ? $elm$core$Maybe$Just(1) : ((A2(r, 573, 574) || (e(577) || (A2(r, 579, 582) || (e(584) || (e(586) || e(588)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(709) ? ((e(589) || (A2(r, 591, 659) || A2(r, 661, 687))) ? $elm$core$Maybe$Just(1) : (e(590) ? $elm$core$Maybe$Just(0) : (e(660) ? $elm$core$Maybe$Just(18) : (A2(r, 688, 705) ? $elm$core$Maybe$Just(17) : (A2(r, 706, 708) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing))))) : ((e(709) || (A2(r, 722, 735) || (A2(r, 741, 747) || (e(749) || A2(r, 751, 766))))) ? $elm$core$Maybe$Just(28) : ((A2(r, 710, 721) || (A2(r, 736, 740) || (e(748) || e(750)))) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing)))))) : (l(1006) ? (l(975) ? (l(893) ? ((e(767) || e(885)) ? $elm$core$Maybe$Just(28) : (A2(r, 768, 879) ? $elm$core$Maybe$Just(3) : ((e(880) || (e(882) || e(886))) ? $elm$core$Maybe$Just(0) : ((e(881) || (e(883) || (e(887) || A2(r, 891, 892)))) ? $elm$core$Maybe$Just(1) : ((e(884) || e(890)) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))) : (l(903) ? (e(893) ? $elm$core$Maybe$Just(1) : (e(894) ? $elm$core$Maybe$Just(25) : ((e(895) || e(902)) ? $elm$core$Maybe$Just(0) : (A2(r, 900, 901) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing)))) : (e(903) ? $elm$core$Maybe$Just(25) : ((A2(r, 904, 906) || (e(908) || (A2(r, 910, 911) || (A2(r, 913, 929) || A2(r, 931, 939))))) ? $elm$core$Maybe$Just(0) : ((e(912) || A2(r, 940, 974)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(992) ? ((e(975) || (A2(r, 978, 980) || (e(984) || (e(986) || (e(988) || e(990)))))) ? $elm$core$Maybe$Just(0) : ((A2(r, 976, 977) || (A2(r, 981, 983) || (e(985) || (e(987) || (e(989) || e(991)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(998) ? ((e(992) || (e(994) || e(996))) ? $elm$core$Maybe$Just(0) : ((e(993) || (e(995) || e(997))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(998) || (e(1000) || (e(1002) || e(1004)))) ? $elm$core$Maybe$Just(0) : ((e(999) || (e(1001) || (e(1003) || e(1005)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(1134) ? (l(1120) ? ((e(1006) || (e(1012) || (e(1015) || (A2(r, 1017, 1018) || A2(r, 1021, 1071))))) ? $elm$core$Maybe$Just(0) : ((A2(r, 1007, 1011) || (e(1013) || (e(1016) || (A2(r, 1019, 1020) || A2(r, 1072, 1119))))) ? $elm$core$Maybe$Just(1) : (e(1014) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing))) : (l(1126) ? ((e(1120) || (e(1122) || e(1124))) ? $elm$core$Maybe$Just(0) : ((e(1121) || (e(1123) || e(1125))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(1126) || (e(1128) || (e(1130) || e(1132)))) ? $elm$core$Maybe$Just(0) : ((e(1127) || (e(1129) || (e(1131) || e(1133)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(1146) ? ((e(1134) || (e(1136) || (e(1138) || (e(1140) || (e(1142) || e(1144)))))) ? $elm$core$Maybe$Just(0) : ((e(1135) || (e(1137) || (e(1139) || (e(1141) || (e(1143) || e(1145)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(1152) ? ((e(1146) || (e(1148) || e(1150))) ? $elm$core$Maybe$Just(0) : ((e(1147) || (e(1149) || e(1151))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(1152) || (e(1162) || e(1164))) ? $elm$core$Maybe$Just(0) : ((e(1153) || (e(1163) || e(1165))) ? $elm$core$Maybe$Just(1) : (e(1154) ? $elm$core$Maybe$Just(29) : (A2(r, 1155, 1159) ? $elm$core$Maybe$Just(3) : (A2(r, 1160, 1161) ? $elm$core$Maybe$Just(5) : $elm$core$Maybe$Nothing))))))))))) : (l(1756) ? (l(1268) ? (l(1215) ? (l(1189) ? (l(1176) ? ((e(1166) || (e(1168) || (e(1170) || (e(1172) || e(1174))))) ? $elm$core$Maybe$Just(0) : ((e(1167) || (e(1169) || (e(1171) || (e(1173) || e(1175))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(1181) ? ((e(1176) || (e(1178) || e(1180))) ? $elm$core$Maybe$Just(0) : ((e(1177) || e(1179)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(1181) || (e(1183) || (e(1185) || e(1187)))) ? $elm$core$Maybe$Just(1) : ((e(1182) || (e(1184) || (e(1186) || e(1188)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(1201) ? ((e(1189) || (e(1191) || (e(1193) || (e(1195) || (e(1197) || e(1199)))))) ? $elm$core$Maybe$Just(1) : ((e(1190) || (e(1192) || (e(1194) || (e(1196) || (e(1198) || e(1200)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(1207) ? ((e(1201) || (e(1203) || e(1205))) ? $elm$core$Maybe$Just(1) : ((e(1202) || (e(1204) || e(1206))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(1207) || (e(1209) || (e(1211) || e(1213)))) ? $elm$core$Maybe$Just(1) : ((e(1208) || (e(1210) || (e(1212) || e(1214)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))) : (l(1241) ? (l(1227) ? ((e(1215) || (e(1218) || (e(1220) || (e(1222) || (e(1224) || e(1226)))))) ? $elm$core$Maybe$Just(1) : ((A2(r, 1216, 1217) || (e(1219) || (e(1221) || (e(1223) || e(1225))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(1233) ? ((e(1227) || (e(1229) || e(1232))) ? $elm$core$Maybe$Just(0) : ((e(1228) || A2(r, 1230, 1231)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(1233) || (e(1235) || (e(1237) || e(1239)))) ? $elm$core$Maybe$Just(1) : ((e(1234) || (e(1236) || (e(1238) || e(1240)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(1253) ? ((e(1241) || (e(1243) || (e(1245) || (e(1247) || (e(1249) || e(1251)))))) ? $elm$core$Maybe$Just(1) : ((e(1242) || (e(1244) || (e(1246) || (e(1248) || (e(1250) || e(1252)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(1259) ? ((e(1253) || (e(1255) || e(1257))) ? $elm$core$Maybe$Just(1) : ((e(1254) || (e(1256) || e(1258))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(1259) || (e(1261) || (e(1263) || (e(1265) || e(1267))))) ? $elm$core$Maybe$Just(1) : ((e(1260) || (e(1262) || (e(1264) || e(1266)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))))) : (l(1318) ? (l(1292) ? (l(1279) ? ((e(1268) || (e(1270) || (e(1272) || (e(1274) || (e(1276) || e(1278)))))) ? $elm$core$Maybe$Just(0) : ((e(1269) || (e(1271) || (e(1273) || (e(1275) || e(1277))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(1284) ? ((e(1279) || (e(1281) || e(1283))) ? $elm$core$Maybe$Just(1) : ((e(1280) || e(1282)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(1284) || (e(1286) || (e(1288) || e(1290)))) ? $elm$core$Maybe$Just(0) : ((e(1285) || (e(1287) || (e(1289) || e(1291)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(1304) ? ((e(1292) || (e(1294) || (e(1296) || (e(1298) || (e(1300) || e(1302)))))) ? $elm$core$Maybe$Just(0) : ((e(1293) || (e(1295) || (e(1297) || (e(1299) || (e(1301) || e(1303)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(1310) ? ((e(1304) || (e(1306) || e(1308))) ? $elm$core$Maybe$Just(0) : ((e(1305) || (e(1307) || e(1309))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(1310) || (e(1312) || (e(1314) || e(1316)))) ? $elm$core$Maybe$Just(0) : ((e(1311) || (e(1313) || (e(1315) || e(1317)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(1478) ? (l(1369) ? ((e(1318) || (e(1320) || (e(1322) || (e(1324) || (e(1326) || A2(r, 1329, 1366)))))) ? $elm$core$Maybe$Just(0) : ((e(1319) || (e(1321) || (e(1323) || (e(1325) || e(1327))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(1424) ? (e(1369) ? $elm$core$Maybe$Just(17) : ((A2(r, 1370, 1375) || e(1417)) ? $elm$core$Maybe$Just(25) : (A2(r, 1376, 1416) ? $elm$core$Maybe$Just(1) : (e(1418) ? $elm$core$Maybe$Just(20) : (A2(r, 1421, 1422) ? $elm$core$Maybe$Just(29) : (e(1423) ? $elm$core$Maybe$Just(27) : $elm$core$Maybe$Nothing)))))) : ((A2(r, 1425, 1469) || (e(1471) || (A2(r, 1473, 1474) || A2(r, 1476, 1477)))) ? $elm$core$Maybe$Just(3) : (e(1470) ? $elm$core$Maybe$Just(20) : ((e(1472) || e(1475)) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : (l(1563) ? ((e(1478) || (A2(r, 1523, 1524) || (A2(r, 1545, 1546) || A2(r, 1548, 1549)))) ? $elm$core$Maybe$Just(25) : ((e(1479) || A2(r, 1552, 1562)) ? $elm$core$Maybe$Just(3) : ((A2(r, 1488, 1514) || A2(r, 1519, 1522)) ? $elm$core$Maybe$Just(18) : (A2(r, 1536, 1541) ? $elm$core$Maybe$Just(13) : (A2(r, 1542, 1544) ? $elm$core$Maybe$Just(26) : (e(1547) ? $elm$core$Maybe$Just(27) : (A2(r, 1550, 1551) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))))))) : (l(1631) ? ((e(1563) || A2(r, 1565, 1567)) ? $elm$core$Maybe$Just(25) : (e(1564) ? $elm$core$Maybe$Just(13) : ((A2(r, 1568, 1599) || A2(r, 1601, 1610)) ? $elm$core$Maybe$Just(18) : (e(1600) ? $elm$core$Maybe$Just(17) : (A2(r, 1611, 1630) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))) : ((e(1631) || (e(1648) || A2(r, 1750, 1755))) ? $elm$core$Maybe$Just(3) : (A2(r, 1632, 1641) ? $elm$core$Maybe$Just(6) : ((A2(r, 1642, 1645) || e(1748)) ? $elm$core$Maybe$Just(25) : ((A2(r, 1646, 1647) || (A2(r, 1649, 1747) || e(1749))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))))))) : (l(2556) ? (l(2248) ? (l(2035) ? (l(1790) ? ((e(1756) || (A2(r, 1759, 1764) || (A2(r, 1767, 1768) || A2(r, 1770, 1773)))) ? $elm$core$Maybe$Just(3) : (e(1757) ? $elm$core$Maybe$Just(13) : ((e(1758) || (e(1769) || e(1789))) ? $elm$core$Maybe$Just(29) : (A2(r, 1765, 1766) ? $elm$core$Maybe$Just(17) : ((A2(r, 1774, 1775) || A2(r, 1786, 1788)) ? $elm$core$Maybe$Just(18) : (A2(r, 1776, 1785) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))))) : (l(1839) ? (e(1790) ? $elm$core$Maybe$Just(29) : ((e(1791) || (e(1808) || A2(r, 1810, 1838))) ? $elm$core$Maybe$Just(18) : (A2(r, 1792, 1805) ? $elm$core$Maybe$Just(25) : (e(1807) ? $elm$core$Maybe$Just(13) : (e(1809) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))) : ((e(1839) || (A2(r, 1869, 1957) || (e(1969) || A2(r, 1994, 2026)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 1840, 1866) || (A2(r, 1958, 1968) || A2(r, 2027, 2034))) ? $elm$core$Maybe$Just(3) : (A2(r, 1984, 1993) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : (l(2087) ? (l(2045) ? (e(2035) ? $elm$core$Maybe$Just(3) : ((A2(r, 2036, 2037) || e(2042)) ? $elm$core$Maybe$Just(17) : (e(2038) ? $elm$core$Maybe$Just(29) : (A2(r, 2039, 2041) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : ((e(2045) || (A2(r, 2070, 2073) || (A2(r, 2075, 2083) || A2(r, 2085, 2086)))) ? $elm$core$Maybe$Just(3) : (A2(r, 2046, 2047) ? $elm$core$Maybe$Just(27) : (A2(r, 2048, 2069) ? $elm$core$Maybe$Just(18) : ((e(2074) || e(2084)) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))) : (l(2143) ? ((e(2087) || (A2(r, 2089, 2093) || A2(r, 2137, 2139))) ? $elm$core$Maybe$Just(3) : (e(2088) ? $elm$core$Maybe$Just(17) : ((A2(r, 2096, 2110) || e(2142)) ? $elm$core$Maybe$Just(25) : (A2(r, 2112, 2136) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : ((A2(r, 2144, 2154) || (A2(r, 2160, 2183) || (A2(r, 2185, 2190) || A2(r, 2208, 2247)))) ? $elm$core$Maybe$Just(18) : (e(2184) ? $elm$core$Maybe$Just(28) : (A2(r, 2192, 2193) ? $elm$core$Maybe$Just(13) : (A2(r, 2200, 2207) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))))) : (l(2432) ? (l(2368) ? ((e(2248) || (A2(r, 2308, 2361) || e(2365))) ? $elm$core$Maybe$Just(18) : (e(2249) ? $elm$core$Maybe$Just(17) : ((A2(r, 2250, 2273) || (A2(r, 2275, 2306) || (e(2362) || e(2364)))) ? $elm$core$Maybe$Just(3) : (e(2274) ? $elm$core$Maybe$Just(13) : ((e(2307) || (e(2363) || A2(r, 2366, 2367))) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))) : (l(2391) ? ((e(2368) || (A2(r, 2377, 2380) || A2(r, 2382, 2383))) ? $elm$core$Maybe$Just(4) : ((A2(r, 2369, 2376) || (e(2381) || A2(r, 2385, 2390))) ? $elm$core$Maybe$Just(3) : (e(2384) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((e(2391) || A2(r, 2402, 2403)) ? $elm$core$Maybe$Just(3) : ((A2(r, 2392, 2401) || A2(r, 2418, 2431)) ? $elm$core$Maybe$Just(18) : ((A2(r, 2404, 2405) || e(2416)) ? $elm$core$Maybe$Just(25) : (A2(r, 2406, 2415) ? $elm$core$Maybe$Just(6) : (e(2417) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))))) : (l(2502) ? (l(2473) ? ((e(2432) || (A2(r, 2437, 2444) || (A2(r, 2447, 2448) || A2(r, 2451, 2472)))) ? $elm$core$Maybe$Just(18) : (e(2433) ? $elm$core$Maybe$Just(3) : (A2(r, 2434, 2435) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((A2(r, 2474, 2480) || (e(2482) || (A2(r, 2486, 2489) || e(2493)))) ? $elm$core$Maybe$Just(18) : ((e(2492) || A2(r, 2497, 2500)) ? $elm$core$Maybe$Just(3) : (A2(r, 2494, 2496) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))) : (l(2529) ? ((A2(r, 2503, 2504) || (A2(r, 2507, 2508) || e(2519))) ? $elm$core$Maybe$Just(4) : (e(2509) ? $elm$core$Maybe$Just(3) : ((e(2510) || (A2(r, 2524, 2525) || A2(r, 2527, 2528))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((e(2529) || A2(r, 2544, 2545)) ? $elm$core$Maybe$Just(18) : (A2(r, 2530, 2531) ? $elm$core$Maybe$Just(3) : (A2(r, 2534, 2543) ? $elm$core$Maybe$Just(6) : ((A2(r, 2546, 2547) || e(2555)) ? $elm$core$Maybe$Just(27) : (A2(r, 2548, 2553) ? $elm$core$Maybe$Just(8) : (e(2554) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))))))))) : (l(2820) ? (l(2688) ? (l(2619) ? ((e(2556) || (A2(r, 2565, 2570) || (A2(r, 2575, 2576) || (A2(r, 2579, 2600) || (A2(r, 2602, 2608) || (A2(r, 2610, 2611) || (A2(r, 2613, 2614) || A2(r, 2616, 2617)))))))) ? $elm$core$Maybe$Just(18) : (e(2557) ? $elm$core$Maybe$Just(25) : ((e(2558) || A2(r, 2561, 2562)) ? $elm$core$Maybe$Just(3) : (e(2563) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))) : (l(2648) ? ((e(2620) || (A2(r, 2625, 2626) || (A2(r, 2631, 2632) || (A2(r, 2635, 2637) || e(2641))))) ? $elm$core$Maybe$Just(3) : (A2(r, 2622, 2624) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)) : ((A2(r, 2649, 2652) || (e(2654) || A2(r, 2674, 2676))) ? $elm$core$Maybe$Just(18) : (A2(r, 2662, 2671) ? $elm$core$Maybe$Just(6) : ((A2(r, 2672, 2673) || e(2677)) ? $elm$core$Maybe$Just(3) : (e(2678) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))) : (l(2760) ? (l(2737) ? (A2(r, 2689, 2690) ? $elm$core$Maybe$Just(3) : (e(2691) ? $elm$core$Maybe$Just(4) : ((A2(r, 2693, 2701) || (A2(r, 2703, 2705) || (A2(r, 2707, 2728) || A2(r, 2730, 2736)))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((A2(r, 2738, 2739) || (A2(r, 2741, 2745) || e(2749))) ? $elm$core$Maybe$Just(18) : ((e(2748) || (A2(r, 2753, 2757) || e(2759))) ? $elm$core$Maybe$Just(3) : (A2(r, 2750, 2752) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))) : (l(2789) ? ((e(2760) || (e(2765) || A2(r, 2786, 2787))) ? $elm$core$Maybe$Just(3) : ((e(2761) || A2(r, 2763, 2764)) ? $elm$core$Maybe$Just(4) : ((e(2768) || A2(r, 2784, 2785)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : (A2(r, 2790, 2799) ? $elm$core$Maybe$Just(6) : (e(2800) ? $elm$core$Maybe$Just(25) : (e(2801) ? $elm$core$Maybe$Just(27) : (e(2809) ? $elm$core$Maybe$Just(18) : ((A2(r, 2810, 2815) || e(2817)) ? $elm$core$Maybe$Just(3) : (A2(r, 2818, 2819) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))))))) : (l(2948) ? (l(2890) ? (l(2875) ? ((A2(r, 2821, 2828) || (A2(r, 2831, 2832) || (A2(r, 2835, 2856) || (A2(r, 2858, 2864) || (A2(r, 2866, 2867) || A2(r, 2869, 2873)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing) : ((e(2876) || (e(2879) || A2(r, 2881, 2884))) ? $elm$core$Maybe$Just(3) : (e(2877) ? $elm$core$Maybe$Just(18) : ((e(2878) || (e(2880) || A2(r, 2887, 2888))) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))) : (l(2913) ? ((A2(r, 2891, 2892) || e(2903)) ? $elm$core$Maybe$Just(4) : ((e(2893) || A2(r, 2901, 2902)) ? $elm$core$Maybe$Just(3) : ((A2(r, 2908, 2909) || A2(r, 2911, 2912)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((e(2913) || (e(2929) || e(2947))) ? $elm$core$Maybe$Just(18) : ((A2(r, 2914, 2915) || e(2946)) ? $elm$core$Maybe$Just(3) : (A2(r, 2918, 2927) ? $elm$core$Maybe$Just(6) : (e(2928) ? $elm$core$Maybe$Just(29) : (A2(r, 2930, 2935) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))))) : (l(3017) ? (l(2978) ? ((A2(r, 2949, 2954) || (A2(r, 2958, 2960) || (A2(r, 2962, 2965) || (A2(r, 2969, 2970) || (e(2972) || A2(r, 2974, 2975)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing) : ((A2(r, 2979, 2980) || (A2(r, 2984, 2986) || A2(r, 2990, 3001))) ? $elm$core$Maybe$Just(18) : ((A2(r, 3006, 3007) || (A2(r, 3009, 3010) || A2(r, 3014, 3016))) ? $elm$core$Maybe$Just(4) : (e(3008) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))) : (l(3058) ? ((A2(r, 3018, 3020) || e(3031)) ? $elm$core$Maybe$Just(4) : (e(3021) ? $elm$core$Maybe$Just(3) : (e(3024) ? $elm$core$Maybe$Just(18) : (A2(r, 3046, 3055) ? $elm$core$Maybe$Just(6) : (A2(r, 3056, 3057) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))) : (e(3058) ? $elm$core$Maybe$Just(8) : ((A2(r, 3059, 3064) || e(3066)) ? $elm$core$Maybe$Just(29) : (e(3065) ? $elm$core$Maybe$Just(27) : ((e(3072) || e(3076)) ? $elm$core$Maybe$Just(3) : (A2(r, 3073, 3075) ? $elm$core$Maybe$Just(4) : (A2(r, 3077, 3084) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))))))))))) : (l(7695) ? (l(4881) ? (l(3763) ? (l(3389) ? (l(3217) ? (l(3167) ? ((A2(r, 3086, 3088) || (A2(r, 3090, 3112) || (A2(r, 3114, 3129) || (e(3133) || (A2(r, 3160, 3162) || e(3165)))))) ? $elm$core$Maybe$Just(18) : ((e(3132) || (A2(r, 3134, 3136) || (A2(r, 3142, 3144) || (A2(r, 3146, 3149) || A2(r, 3157, 3158))))) ? $elm$core$Maybe$Just(3) : (A2(r, 3137, 3140) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((A2(r, 3168, 3169) || (e(3200) || (A2(r, 3205, 3212) || A2(r, 3214, 3216)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 3170, 3171) || e(3201)) ? $elm$core$Maybe$Just(3) : (A2(r, 3174, 3183) ? $elm$core$Maybe$Just(6) : ((e(3191) || e(3204)) ? $elm$core$Maybe$Just(25) : (A2(r, 3192, 3198) ? $elm$core$Maybe$Just(8) : (e(3199) ? $elm$core$Maybe$Just(29) : (A2(r, 3202, 3203) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))))))) : (l(3284) ? ((A2(r, 3218, 3240) || (A2(r, 3242, 3251) || (A2(r, 3253, 3257) || e(3261)))) ? $elm$core$Maybe$Just(18) : ((e(3260) || (e(3263) || (e(3270) || A2(r, 3276, 3277)))) ? $elm$core$Maybe$Just(3) : ((e(3262) || (A2(r, 3264, 3268) || (A2(r, 3271, 3272) || A2(r, 3274, 3275)))) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : (l(3314) ? (A2(r, 3285, 3286) ? $elm$core$Maybe$Just(4) : ((A2(r, 3293, 3294) || (A2(r, 3296, 3297) || e(3313))) ? $elm$core$Maybe$Just(18) : (A2(r, 3298, 3299) ? $elm$core$Maybe$Just(3) : (A2(r, 3302, 3311) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))) : ((e(3314) || (A2(r, 3332, 3340) || (A2(r, 3342, 3344) || A2(r, 3346, 3386)))) ? $elm$core$Maybe$Just(18) : ((e(3315) || A2(r, 3330, 3331)) ? $elm$core$Maybe$Just(4) : ((A2(r, 3328, 3329) || A2(r, 3387, 3388)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : (l(3534) ? (l(3425) ? ((e(3389) || (e(3406) || (A2(r, 3412, 3414) || A2(r, 3423, 3424)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 3390, 3392) || (A2(r, 3398, 3400) || (A2(r, 3402, 3404) || e(3415)))) ? $elm$core$Maybe$Just(4) : ((A2(r, 3393, 3396) || e(3405)) ? $elm$core$Maybe$Just(3) : (e(3407) ? $elm$core$Maybe$Just(29) : (A2(r, 3416, 3422) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))) : (l(3457) ? ((e(3425) || A2(r, 3450, 3455)) ? $elm$core$Maybe$Just(18) : (A2(r, 3426, 3427) ? $elm$core$Maybe$Just(3) : (A2(r, 3430, 3439) ? $elm$core$Maybe$Just(6) : (A2(r, 3440, 3448) ? $elm$core$Maybe$Just(8) : (e(3449) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))))) : ((e(3457) || e(3530)) ? $elm$core$Maybe$Just(3) : (A2(r, 3458, 3459) ? $elm$core$Maybe$Just(4) : ((A2(r, 3461, 3478) || (A2(r, 3482, 3505) || (A2(r, 3507, 3515) || (e(3517) || A2(r, 3520, 3526))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))) : (l(3653) ? (l(3571) ? ((A2(r, 3535, 3537) || (A2(r, 3544, 3551) || e(3570))) ? $elm$core$Maybe$Just(4) : ((A2(r, 3538, 3540) || e(3542)) ? $elm$core$Maybe$Just(3) : (A2(r, 3558, 3567) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))) : (e(3571) ? $elm$core$Maybe$Just(4) : (e(3572) ? $elm$core$Maybe$Just(25) : ((A2(r, 3585, 3632) || (A2(r, 3634, 3635) || A2(r, 3648, 3652))) ? $elm$core$Maybe$Just(18) : ((e(3633) || A2(r, 3636, 3642)) ? $elm$core$Maybe$Just(3) : (e(3647) ? $elm$core$Maybe$Just(27) : $elm$core$Maybe$Nothing)))))) : (l(3715) ? ((e(3653) || A2(r, 3713, 3714)) ? $elm$core$Maybe$Just(18) : (e(3654) ? $elm$core$Maybe$Just(17) : (A2(r, 3655, 3662) ? $elm$core$Maybe$Just(3) : ((e(3663) || A2(r, 3674, 3675)) ? $elm$core$Maybe$Just(25) : (A2(r, 3664, 3673) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : ((e(3716) || (A2(r, 3718, 3722) || (A2(r, 3724, 3747) || (e(3749) || (A2(r, 3751, 3760) || e(3762)))))) ? $elm$core$Maybe$Just(18) : (e(3761) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : (l(4151) ? (l(3898) ? (l(3859) ? ((e(3763) || (e(3773) || (A2(r, 3776, 3780) || (A2(r, 3804, 3807) || e(3840))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 3764, 3772) || A2(r, 3784, 3790)) ? $elm$core$Maybe$Just(3) : (e(3782) ? $elm$core$Maybe$Just(17) : (A2(r, 3792, 3801) ? $elm$core$Maybe$Just(6) : (A2(r, 3841, 3843) ? $elm$core$Maybe$Just(29) : (A2(r, 3844, 3858) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))) : (l(3881) ? ((e(3859) || (A2(r, 3861, 3863) || A2(r, 3866, 3871))) ? $elm$core$Maybe$Just(29) : (e(3860) ? $elm$core$Maybe$Just(25) : (A2(r, 3864, 3865) ? $elm$core$Maybe$Just(3) : (A2(r, 3872, 3880) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))) : (e(3881) ? $elm$core$Maybe$Just(6) : (A2(r, 3882, 3891) ? $elm$core$Maybe$Just(8) : ((e(3892) || (e(3894) || e(3896))) ? $elm$core$Maybe$Just(29) : ((e(3893) || (e(3895) || e(3897))) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : (l(3980) ? (l(3912) ? ((e(3898) || e(3900)) ? $elm$core$Maybe$Just(21) : ((e(3899) || e(3901)) ? $elm$core$Maybe$Just(22) : (A2(r, 3902, 3903) ? $elm$core$Maybe$Just(4) : (A2(r, 3904, 3911) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : ((A2(r, 3913, 3948) || A2(r, 3976, 3979)) ? $elm$core$Maybe$Just(18) : ((A2(r, 3953, 3966) || (A2(r, 3968, 3972) || A2(r, 3974, 3975))) ? $elm$core$Maybe$Just(3) : (e(3967) ? $elm$core$Maybe$Just(4) : (e(3973) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : (l(4047) ? (e(3980) ? $elm$core$Maybe$Just(18) : ((A2(r, 3981, 3991) || (A2(r, 3993, 4028) || e(4038))) ? $elm$core$Maybe$Just(3) : ((A2(r, 4030, 4037) || (A2(r, 4039, 4044) || e(4046))) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))) : ((e(4047) || A2(r, 4053, 4056)) ? $elm$core$Maybe$Just(29) : ((A2(r, 4048, 4052) || A2(r, 4057, 4058)) ? $elm$core$Maybe$Just(25) : (A2(r, 4096, 4138) ? $elm$core$Maybe$Just(18) : ((A2(r, 4139, 4140) || e(4145)) ? $elm$core$Maybe$Just(4) : ((A2(r, 4141, 4144) || A2(r, 4146, 4150)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))))) : (l(4238) ? (l(4189) ? ((e(4151) || (A2(r, 4153, 4154) || (A2(r, 4157, 4158) || A2(r, 4184, 4185)))) ? $elm$core$Maybe$Just(3) : ((e(4152) || (A2(r, 4155, 4156) || A2(r, 4182, 4183))) ? $elm$core$Maybe$Just(4) : ((e(4159) || (A2(r, 4176, 4181) || A2(r, 4186, 4188))) ? $elm$core$Maybe$Just(18) : (A2(r, 4160, 4169) ? $elm$core$Maybe$Just(6) : (A2(r, 4170, 4175) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : (l(4208) ? ((e(4189) || (e(4193) || (A2(r, 4197, 4198) || A2(r, 4206, 4207)))) ? $elm$core$Maybe$Just(18) : (A2(r, 4190, 4192) ? $elm$core$Maybe$Just(3) : ((A2(r, 4194, 4196) || A2(r, 4199, 4205)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((e(4208) || A2(r, 4213, 4225)) ? $elm$core$Maybe$Just(18) : ((A2(r, 4209, 4212) || (e(4226) || (A2(r, 4229, 4230) || e(4237)))) ? $elm$core$Maybe$Just(3) : ((A2(r, 4227, 4228) || A2(r, 4231, 4236)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))) : (l(4351) ? (l(4255) ? (e(4238) ? $elm$core$Maybe$Just(18) : ((e(4239) || A2(r, 4250, 4252)) ? $elm$core$Maybe$Just(4) : (A2(r, 4240, 4249) ? $elm$core$Maybe$Just(6) : (e(4253) ? $elm$core$Maybe$Just(3) : (e(4254) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))))) : (e(4255) ? $elm$core$Maybe$Just(29) : ((A2(r, 4256, 4293) || (e(4295) || e(4301))) ? $elm$core$Maybe$Just(0) : ((A2(r, 4304, 4346) || A2(r, 4349, 4350)) ? $elm$core$Maybe$Just(1) : (e(4347) ? $elm$core$Maybe$Just(25) : (e(4348) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing)))))) : (l(4745) ? (e(4351) ? $elm$core$Maybe$Just(1) : ((A2(r, 4352, 4680) || (A2(r, 4682, 4685) || (A2(r, 4688, 4694) || (e(4696) || (A2(r, 4698, 4701) || A2(r, 4704, 4744)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)) : ((A2(r, 4746, 4749) || (A2(r, 4752, 4784) || (A2(r, 4786, 4789) || (A2(r, 4792, 4798) || (e(4800) || (A2(r, 4802, 4805) || (A2(r, 4808, 4822) || A2(r, 4824, 4880)))))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))) : (l(6764) ? (l(6143) ? (l(5918) ? (l(5741) ? ((A2(r, 4882, 4885) || (A2(r, 4888, 4954) || (A2(r, 4992, 5007) || A2(r, 5121, 5740)))) ? $elm$core$Maybe$Just(18) : (A2(r, 4957, 4959) ? $elm$core$Maybe$Just(3) : (A2(r, 4960, 4968) ? $elm$core$Maybe$Just(25) : (A2(r, 4969, 4988) ? $elm$core$Maybe$Just(8) : (A2(r, 5008, 5017) ? $elm$core$Maybe$Just(29) : (A2(r, 5024, 5109) ? $elm$core$Maybe$Just(0) : (A2(r, 5112, 5117) ? $elm$core$Maybe$Just(1) : (e(5120) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing)))))))) : (l(5791) ? (e(5741) ? $elm$core$Maybe$Just(29) : (e(5742) ? $elm$core$Maybe$Just(25) : ((A2(r, 5743, 5759) || A2(r, 5761, 5786)) ? $elm$core$Maybe$Just(18) : (e(5760) ? $elm$core$Maybe$Just(9) : (e(5787) ? $elm$core$Maybe$Just(21) : (e(5788) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))))) : ((A2(r, 5792, 5866) || (A2(r, 5873, 5880) || A2(r, 5888, 5905))) ? $elm$core$Maybe$Just(18) : (A2(r, 5867, 5869) ? $elm$core$Maybe$Just(25) : (A2(r, 5870, 5872) ? $elm$core$Maybe$Just(7) : (A2(r, 5906, 5908) ? $elm$core$Maybe$Just(3) : (e(5909) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))))) : (l(6070) ? ((A2(r, 5919, 5937) || (A2(r, 5952, 5969) || (A2(r, 5984, 5996) || (A2(r, 5998, 6000) || A2(r, 6016, 6067))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 5938, 5939) || (A2(r, 5970, 5971) || (A2(r, 6002, 6003) || A2(r, 6068, 6069)))) ? $elm$core$Maybe$Just(3) : (e(5940) ? $elm$core$Maybe$Just(4) : (A2(r, 5941, 5942) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : (l(6102) ? ((e(6070) || (A2(r, 6078, 6085) || A2(r, 6087, 6088))) ? $elm$core$Maybe$Just(4) : ((A2(r, 6071, 6077) || (e(6086) || A2(r, 6089, 6099))) ? $elm$core$Maybe$Just(3) : (A2(r, 6100, 6101) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))) : ((e(6102) || A2(r, 6104, 6106)) ? $elm$core$Maybe$Just(25) : (e(6103) ? $elm$core$Maybe$Just(17) : (e(6107) ? $elm$core$Maybe$Just(27) : (e(6108) ? $elm$core$Maybe$Just(18) : (e(6109) ? $elm$core$Maybe$Just(3) : (A2(r, 6112, 6121) ? $elm$core$Maybe$Just(6) : (A2(r, 6128, 6137) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing)))))))))) : (l(6463) ? (l(6278) ? ((A2(r, 6144, 6149) || A2(r, 6151, 6154)) ? $elm$core$Maybe$Just(25) : (e(6150) ? $elm$core$Maybe$Just(20) : ((A2(r, 6155, 6157) || (e(6159) || e(6277))) ? $elm$core$Maybe$Just(3) : (e(6158) ? $elm$core$Maybe$Just(13) : (A2(r, 6160, 6169) ? $elm$core$Maybe$Just(6) : ((A2(r, 6176, 6210) || (A2(r, 6212, 6264) || A2(r, 6272, 6276))) ? $elm$core$Maybe$Just(18) : (e(6211) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))))) : (l(6434) ? ((e(6278) || (e(6313) || A2(r, 6432, 6433))) ? $elm$core$Maybe$Just(3) : ((A2(r, 6279, 6312) || (e(6314) || (A2(r, 6320, 6389) || A2(r, 6400, 6430)))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)) : ((e(6434) || (A2(r, 6439, 6440) || (e(6450) || A2(r, 6457, 6459)))) ? $elm$core$Maybe$Just(3) : ((A2(r, 6435, 6438) || (A2(r, 6441, 6443) || (A2(r, 6448, 6449) || A2(r, 6451, 6456)))) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))) : (l(6680) ? ((e(6464) || A2(r, 6622, 6655)) ? $elm$core$Maybe$Just(29) : (A2(r, 6468, 6469) ? $elm$core$Maybe$Just(25) : ((A2(r, 6470, 6479) || A2(r, 6608, 6617)) ? $elm$core$Maybe$Just(6) : ((A2(r, 6480, 6509) || (A2(r, 6512, 6516) || (A2(r, 6528, 6571) || (A2(r, 6576, 6601) || A2(r, 6656, 6678))))) ? $elm$core$Maybe$Just(18) : (e(6618) ? $elm$core$Maybe$Just(8) : (e(6679) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : (l(6742) ? ((e(6680) || e(6683)) ? $elm$core$Maybe$Just(3) : ((A2(r, 6681, 6682) || e(6741)) ? $elm$core$Maybe$Just(4) : (A2(r, 6686, 6687) ? $elm$core$Maybe$Just(25) : (A2(r, 6688, 6740) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : ((e(6742) || (A2(r, 6744, 6750) || (e(6752) || (e(6754) || A2(r, 6757, 6763))))) ? $elm$core$Maybe$Just(3) : ((e(6743) || (e(6753) || A2(r, 6755, 6756))) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))))) : (l(7167) ? (l(7001) ? (l(6911) ? ((e(6764) || (A2(r, 6771, 6780) || (e(6783) || (A2(r, 6832, 6845) || A2(r, 6847, 6862))))) ? $elm$core$Maybe$Just(3) : (A2(r, 6765, 6770) ? $elm$core$Maybe$Just(4) : ((A2(r, 6784, 6793) || A2(r, 6800, 6809)) ? $elm$core$Maybe$Just(6) : ((A2(r, 6816, 6822) || A2(r, 6824, 6829)) ? $elm$core$Maybe$Just(25) : (e(6823) ? $elm$core$Maybe$Just(17) : (e(6846) ? $elm$core$Maybe$Just(5) : $elm$core$Maybe$Nothing)))))) : (l(6970) ? ((A2(r, 6912, 6915) || (e(6964) || A2(r, 6966, 6969))) ? $elm$core$Maybe$Just(3) : ((e(6916) || e(6965)) ? $elm$core$Maybe$Just(4) : (A2(r, 6917, 6963) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((e(6970) || (e(6972) || e(6978))) ? $elm$core$Maybe$Just(3) : ((e(6971) || (A2(r, 6973, 6977) || A2(r, 6979, 6980))) ? $elm$core$Maybe$Just(4) : (A2(r, 6981, 6988) ? $elm$core$Maybe$Just(18) : (A2(r, 6992, 7000) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))))) : (l(7081) ? (l(7039) ? (e(7001) ? $elm$core$Maybe$Just(6) : ((A2(r, 7002, 7008) || A2(r, 7037, 7038)) ? $elm$core$Maybe$Just(25) : ((A2(r, 7009, 7018) || A2(r, 7028, 7036)) ? $elm$core$Maybe$Just(29) : (A2(r, 7019, 7027) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))) : ((A2(r, 7040, 7041) || (A2(r, 7074, 7077) || e(7080))) ? $elm$core$Maybe$Just(3) : ((e(7042) || (e(7073) || A2(r, 7078, 7079))) ? $elm$core$Maybe$Just(4) : (A2(r, 7043, 7072) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (l(7142) ? ((e(7081) || A2(r, 7083, 7085)) ? $elm$core$Maybe$Just(3) : (e(7082) ? $elm$core$Maybe$Just(4) : ((A2(r, 7086, 7087) || A2(r, 7098, 7141)) ? $elm$core$Maybe$Just(18) : (A2(r, 7088, 7097) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))) : ((e(7142) || (A2(r, 7144, 7145) || (e(7149) || A2(r, 7151, 7153)))) ? $elm$core$Maybe$Just(3) : ((e(7143) || (A2(r, 7146, 7148) || (e(7150) || A2(r, 7154, 7155)))) ? $elm$core$Maybe$Just(4) : (A2(r, 7164, 7166) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))) : (l(7412) ? (l(7293) ? ((e(7167) || A2(r, 7227, 7231)) ? $elm$core$Maybe$Just(25) : ((A2(r, 7168, 7203) || (A2(r, 7245, 7247) || A2(r, 7258, 7287))) ? $elm$core$Maybe$Just(18) : ((A2(r, 7204, 7211) || A2(r, 7220, 7221)) ? $elm$core$Maybe$Just(4) : ((A2(r, 7212, 7219) || A2(r, 7222, 7223)) ? $elm$core$Maybe$Just(3) : ((A2(r, 7232, 7241) || A2(r, 7248, 7257)) ? $elm$core$Maybe$Just(6) : (A2(r, 7288, 7292) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing)))))) : (l(7378) ? (e(7293) ? $elm$core$Maybe$Just(17) : ((A2(r, 7294, 7295) || A2(r, 7360, 7367)) ? $elm$core$Maybe$Just(25) : (A2(r, 7296, 7304) ? $elm$core$Maybe$Just(1) : ((A2(r, 7312, 7354) || A2(r, 7357, 7359)) ? $elm$core$Maybe$Just(0) : (A2(r, 7376, 7377) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))) : ((e(7378) || (A2(r, 7380, 7392) || (A2(r, 7394, 7400) || e(7405)))) ? $elm$core$Maybe$Just(3) : (e(7379) ? $elm$core$Maybe$Just(25) : (e(7393) ? $elm$core$Maybe$Just(4) : ((A2(r, 7401, 7404) || A2(r, 7406, 7411)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))) : (l(7680) ? ((e(7412) || (A2(r, 7416, 7417) || A2(r, 7616, 7679))) ? $elm$core$Maybe$Just(3) : ((A2(r, 7413, 7414) || e(7418)) ? $elm$core$Maybe$Just(18) : (e(7415) ? $elm$core$Maybe$Just(4) : ((A2(r, 7424, 7467) || (A2(r, 7531, 7543) || A2(r, 7545, 7578))) ? $elm$core$Maybe$Just(1) : ((A2(r, 7468, 7530) || (e(7544) || A2(r, 7579, 7615))) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))) : (l(7686) ? ((e(7680) || (e(7682) || e(7684))) ? $elm$core$Maybe$Just(0) : ((e(7681) || (e(7683) || e(7685))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(7686) || (e(7688) || (e(7690) || (e(7692) || e(7694))))) ? $elm$core$Maybe$Just(0) : ((e(7687) || (e(7689) || (e(7691) || e(7693)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))))))) : (l(7904) ? (l(7794) ? (l(7743) ? (l(7718) ? (l(7705) ? ((e(7695) || (e(7697) || (e(7699) || (e(7701) || e(7703))))) ? $elm$core$Maybe$Just(1) : ((e(7696) || (e(7698) || (e(7700) || (e(7702) || e(7704))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(7710) ? ((e(7705) || (e(7707) || e(7709))) ? $elm$core$Maybe$Just(1) : ((e(7706) || e(7708)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7710) || (e(7712) || (e(7714) || e(7716)))) ? $elm$core$Maybe$Just(0) : ((e(7711) || (e(7713) || (e(7715) || e(7717)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(7729) ? ((e(7718) || (e(7720) || (e(7722) || (e(7724) || (e(7726) || e(7728)))))) ? $elm$core$Maybe$Just(0) : ((e(7719) || (e(7721) || (e(7723) || (e(7725) || e(7727))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(7735) ? ((e(7729) || (e(7731) || e(7733))) ? $elm$core$Maybe$Just(1) : ((e(7730) || (e(7732) || e(7734))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7735) || (e(7737) || (e(7739) || e(7741)))) ? $elm$core$Maybe$Just(1) : ((e(7736) || (e(7738) || (e(7740) || e(7742)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))) : (l(7767) ? (l(7754) ? ((e(7743) || (e(7745) || (e(7747) || (e(7749) || (e(7751) || e(7753)))))) ? $elm$core$Maybe$Just(1) : ((e(7744) || (e(7746) || (e(7748) || (e(7750) || e(7752))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(7759) ? ((e(7754) || (e(7756) || e(7758))) ? $elm$core$Maybe$Just(0) : ((e(7755) || e(7757)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(7759) || (e(7761) || (e(7763) || e(7765)))) ? $elm$core$Maybe$Just(1) : ((e(7760) || (e(7762) || (e(7764) || e(7766)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(7779) ? ((e(7767) || (e(7769) || (e(7771) || (e(7773) || (e(7775) || e(7777)))))) ? $elm$core$Maybe$Just(1) : ((e(7768) || (e(7770) || (e(7772) || (e(7774) || (e(7776) || e(7778)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(7785) ? ((e(7779) || (e(7781) || e(7783))) ? $elm$core$Maybe$Just(1) : ((e(7780) || (e(7782) || e(7784))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7785) || (e(7787) || (e(7789) || (e(7791) || e(7793))))) ? $elm$core$Maybe$Just(1) : ((e(7786) || (e(7788) || (e(7790) || e(7792)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))))) : (l(7852) ? (l(7818) ? (l(7805) ? ((e(7794) || (e(7796) || (e(7798) || (e(7800) || (e(7802) || e(7804)))))) ? $elm$core$Maybe$Just(0) : ((e(7795) || (e(7797) || (e(7799) || (e(7801) || e(7803))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(7810) ? ((e(7805) || (e(7807) || e(7809))) ? $elm$core$Maybe$Just(1) : ((e(7806) || e(7808)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7810) || (e(7812) || (e(7814) || e(7816)))) ? $elm$core$Maybe$Just(0) : ((e(7811) || (e(7813) || (e(7815) || e(7817)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(7838) ? ((e(7818) || (e(7820) || (e(7822) || (e(7824) || (e(7826) || e(7828)))))) ? $elm$core$Maybe$Just(0) : ((e(7819) || (e(7821) || (e(7823) || (e(7825) || (e(7827) || A2(r, 7829, 7837)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(7844) ? ((e(7838) || (e(7840) || e(7842))) ? $elm$core$Maybe$Just(0) : ((e(7839) || (e(7841) || e(7843))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(7844) || (e(7846) || (e(7848) || e(7850)))) ? $elm$core$Maybe$Just(0) : ((e(7845) || (e(7847) || (e(7849) || e(7851)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(7877) ? (l(7863) ? ((e(7852) || (e(7854) || (e(7856) || (e(7858) || (e(7860) || e(7862)))))) ? $elm$core$Maybe$Just(0) : ((e(7853) || (e(7855) || (e(7857) || (e(7859) || e(7861))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(7869) ? ((e(7863) || (e(7865) || e(7867))) ? $elm$core$Maybe$Just(1) : ((e(7864) || (e(7866) || e(7868))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7869) || (e(7871) || (e(7873) || e(7875)))) ? $elm$core$Maybe$Just(1) : ((e(7870) || (e(7872) || (e(7874) || e(7876)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(7889) ? ((e(7877) || (e(7879) || (e(7881) || (e(7883) || (e(7885) || e(7887)))))) ? $elm$core$Maybe$Just(1) : ((e(7878) || (e(7880) || (e(7882) || (e(7884) || (e(7886) || e(7888)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(7895) ? ((e(7889) || (e(7891) || e(7893))) ? $elm$core$Maybe$Just(1) : ((e(7890) || (e(7892) || e(7894))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7895) || (e(7897) || (e(7899) || (e(7901) || e(7903))))) ? $elm$core$Maybe$Just(1) : ((e(7896) || (e(7898) || (e(7900) || e(7902)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))))) : (l(8273) ? (l(8103) ? (l(7928) ? (l(7915) ? ((e(7904) || (e(7906) || (e(7908) || (e(7910) || (e(7912) || e(7914)))))) ? $elm$core$Maybe$Just(0) : ((e(7905) || (e(7907) || (e(7909) || (e(7911) || e(7913))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(7920) ? ((e(7915) || (e(7917) || e(7919))) ? $elm$core$Maybe$Just(1) : ((e(7916) || e(7918)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(7920) || (e(7922) || (e(7924) || e(7926)))) ? $elm$core$Maybe$Just(0) : ((e(7921) || (e(7923) || (e(7925) || e(7927)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(7983) ? (l(7933) ? ((e(7928) || (e(7930) || e(7932))) ? $elm$core$Maybe$Just(0) : ((e(7929) || e(7931)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(7933) || (A2(r, 7935, 7943) || (A2(r, 7952, 7957) || A2(r, 7968, 7975)))) ? $elm$core$Maybe$Just(1) : ((e(7934) || (A2(r, 7944, 7951) || (A2(r, 7960, 7965) || A2(r, 7976, 7982)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))) : (l(8039) ? ((e(7983) || (A2(r, 7992, 7999) || (A2(r, 8008, 8013) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && A2(r, 8025, 8031))))) ? $elm$core$Maybe$Just(0) : ((A2(r, 7984, 7991) || (A2(r, 8000, 8005) || (A2(r, 8016, 8023) || A2(r, 8032, 8038)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(8039) || (A2(r, 8048, 8061) || (A2(r, 8064, 8071) || (A2(r, 8080, 8087) || A2(r, 8096, 8102))))) ? $elm$core$Maybe$Just(1) : (A2(r, 8040, 8047) ? $elm$core$Maybe$Just(0) : ((A2(r, 8072, 8079) || A2(r, 8088, 8095)) ? $elm$core$Maybe$Just(2) : $elm$core$Maybe$Nothing)))))) : (l(8191) ? (l(8140) ? ((e(8103) || (A2(r, 8112, 8116) || (A2(r, 8118, 8119) || (e(8126) || (A2(r, 8130, 8132) || A2(r, 8134, 8135)))))) ? $elm$core$Maybe$Just(1) : ((A2(r, 8104, 8111) || e(8124)) ? $elm$core$Maybe$Just(2) : ((A2(r, 8120, 8123) || A2(r, 8136, 8139)) ? $elm$core$Maybe$Just(0) : ((e(8125) || A2(r, 8127, 8129)) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing)))) : (l(8167) ? (e(8140) ? $elm$core$Maybe$Just(2) : ((A2(r, 8141, 8143) || A2(r, 8157, 8159)) ? $elm$core$Maybe$Just(28) : ((A2(r, 8144, 8147) || (A2(r, 8150, 8151) || A2(r, 8160, 8166))) ? $elm$core$Maybe$Just(1) : (A2(r, 8152, 8155) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : ((e(8167) || (A2(r, 8178, 8180) || A2(r, 8182, 8183))) ? $elm$core$Maybe$Just(1) : ((A2(r, 8168, 8172) || A2(r, 8184, 8187)) ? $elm$core$Maybe$Just(0) : ((A2(r, 8173, 8175) || A2(r, 8189, 8190)) ? $elm$core$Maybe$Just(28) : (e(8188) ? $elm$core$Maybe$Just(2) : $elm$core$Maybe$Nothing)))))) : (l(8232) ? (A2(r, 8192, 8202) ? $elm$core$Maybe$Just(9) : (A2(r, 8203, 8207) ? $elm$core$Maybe$Just(13) : (A2(r, 8208, 8213) ? $elm$core$Maybe$Just(20) : ((A2(r, 8214, 8215) || A2(r, 8224, 8231)) ? $elm$core$Maybe$Just(25) : ((e(8216) || (A2(r, 8219, 8220) || e(8223))) ? $elm$core$Maybe$Just(23) : ((e(8217) || e(8221)) ? $elm$core$Maybe$Just(24) : ((e(8218) || e(8222)) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing))))))) : (l(8250) ? (e(8232) ? $elm$core$Maybe$Just(10) : (e(8233) ? $elm$core$Maybe$Just(11) : (A2(r, 8234, 8238) ? $elm$core$Maybe$Just(13) : (e(8239) ? $elm$core$Maybe$Just(9) : (A2(r, 8240, 8248) ? $elm$core$Maybe$Just(25) : (e(8249) ? $elm$core$Maybe$Just(23) : $elm$core$Maybe$Nothing)))))) : (e(8250) ? $elm$core$Maybe$Just(24) : ((A2(r, 8251, 8254) || (A2(r, 8257, 8259) || A2(r, 8263, 8272))) ? $elm$core$Maybe$Just(25) : (A2(r, 8255, 8256) ? $elm$core$Maybe$Just(19) : (e(8260) ? $elm$core$Maybe$Just(26) : (e(8261) ? $elm$core$Maybe$Just(21) : (e(8262) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))))))))) : (l(8495) ? (l(8420) ? (l(8316) ? ((e(8273) || (e(8275) || A2(r, 8277, 8286))) ? $elm$core$Maybe$Just(25) : ((e(8274) || A2(r, 8314, 8315)) ? $elm$core$Maybe$Just(26) : (e(8276) ? $elm$core$Maybe$Just(19) : (e(8287) ? $elm$core$Maybe$Just(9) : ((A2(r, 8288, 8292) || A2(r, 8294, 8303)) ? $elm$core$Maybe$Just(13) : ((e(8304) || A2(r, 8308, 8313)) ? $elm$core$Maybe$Just(8) : (e(8305) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))))) : (l(8333) ? ((e(8316) || A2(r, 8330, 8332)) ? $elm$core$Maybe$Just(26) : (e(8317) ? $elm$core$Maybe$Just(21) : (e(8318) ? $elm$core$Maybe$Just(22) : (e(8319) ? $elm$core$Maybe$Just(17) : (A2(r, 8320, 8329) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))) : (e(8333) ? $elm$core$Maybe$Just(21) : (e(8334) ? $elm$core$Maybe$Just(22) : (A2(r, 8336, 8348) ? $elm$core$Maybe$Just(17) : (A2(r, 8352, 8384) ? $elm$core$Maybe$Just(27) : ((A2(r, 8400, 8412) || e(8417)) ? $elm$core$Maybe$Just(3) : ((A2(r, 8413, 8416) || A2(r, 8418, 8419)) ? $elm$core$Maybe$Just(5) : $elm$core$Maybe$Nothing)))))))) : (l(8468) ? (e(8420) ? $elm$core$Maybe$Just(5) : (A2(r, 8421, 8432) ? $elm$core$Maybe$Just(3) : ((A2(r, 8448, 8449) || (A2(r, 8451, 8454) || A2(r, 8456, 8457))) ? $elm$core$Maybe$Just(29) : ((e(8450) || (e(8455) || (A2(r, 8459, 8461) || A2(r, 8464, 8466)))) ? $elm$core$Maybe$Just(0) : ((e(8458) || (A2(r, 8462, 8463) || e(8467))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(8484) ? ((e(8468) || (A2(r, 8470, 8471) || A2(r, 8478, 8483))) ? $elm$core$Maybe$Just(29) : ((e(8469) || A2(r, 8473, 8477)) ? $elm$core$Maybe$Just(0) : (e(8472) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing))) : ((e(8484) || (e(8486) || (e(8488) || A2(r, 8490, 8493)))) ? $elm$core$Maybe$Just(0) : ((e(8485) || (e(8487) || (e(8489) || e(8494)))) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))))) : (l(8603) ? (l(8523) ? ((e(8495) || (e(8500) || (e(8505) || (A2(r, 8508, 8509) || A2(r, 8518, 8521))))) ? $elm$core$Maybe$Just(1) : ((A2(r, 8496, 8499) || (A2(r, 8510, 8511) || e(8517))) ? $elm$core$Maybe$Just(0) : (A2(r, 8501, 8504) ? $elm$core$Maybe$Just(18) : ((A2(r, 8506, 8507) || e(8522)) ? $elm$core$Maybe$Just(29) : (A2(r, 8512, 8516) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing))))) : (l(8579) ? (e(8523) ? $elm$core$Maybe$Just(26) : ((A2(r, 8524, 8525) || e(8527)) ? $elm$core$Maybe$Just(29) : (e(8526) ? $elm$core$Maybe$Just(1) : (A2(r, 8528, 8543) ? $elm$core$Maybe$Just(8) : (A2(r, 8544, 8578) ? $elm$core$Maybe$Just(7) : $elm$core$Maybe$Nothing))))) : (e(8579) ? $elm$core$Maybe$Just(0) : (e(8580) ? $elm$core$Maybe$Just(1) : (A2(r, 8581, 8584) ? $elm$core$Maybe$Just(7) : (e(8585) ? $elm$core$Maybe$Just(8) : ((A2(r, 8586, 8587) || A2(r, 8597, 8601)) ? $elm$core$Maybe$Just(29) : ((A2(r, 8592, 8596) || e(8602)) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing)))))))) : (l(8659) ? (l(8613) ? ((e(8603) || (e(8608) || e(8611))) ? $elm$core$Maybe$Just(26) : ((A2(r, 8604, 8607) || (A2(r, 8609, 8610) || e(8612))) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)) : ((e(8613) || (A2(r, 8615, 8621) || (A2(r, 8623, 8653) || A2(r, 8656, 8657)))) ? $elm$core$Maybe$Just(29) : ((e(8614) || (e(8622) || (A2(r, 8654, 8655) || e(8658)))) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing))) : (l(8969) ? ((e(8659) || (A2(r, 8661, 8691) || A2(r, 8960, 8967))) ? $elm$core$Maybe$Just(29) : ((e(8660) || A2(r, 8692, 8959)) ? $elm$core$Maybe$Just(26) : (e(8968) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing))) : ((e(8969) || (e(8971) || e(9002))) ? $elm$core$Maybe$Just(22) : ((e(8970) || e(9001)) ? $elm$core$Maybe$Just(21) : ((A2(r, 8972, 8991) || (A2(r, 8994, 9000) || A2(r, 9003, 9083))) ? $elm$core$Maybe$Just(29) : (A2(r, 8992, 8993) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing)))))))))))) : (l(65103) ? (l(42587) ? (l(11483) ? (l(11370) ? (l(10223) ? (l(10092) ? (l(9654) ? ((e(9084) || (A2(r, 9115, 9139) || A2(r, 9180, 9185))) ? $elm$core$Maybe$Just(26) : ((A2(r, 9085, 9114) || (A2(r, 9140, 9179) || (A2(r, 9186, 9254) || (A2(r, 9280, 9290) || (A2(r, 9372, 9449) || A2(r, 9472, 9653)))))) ? $elm$core$Maybe$Just(29) : ((A2(r, 9312, 9371) || A2(r, 9450, 9471)) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))) : (l(9727) ? ((e(9654) || (A2(r, 9656, 9664) || A2(r, 9666, 9719))) ? $elm$core$Maybe$Just(29) : ((e(9655) || (e(9665) || A2(r, 9720, 9726))) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing)) : ((e(9727) || e(9839)) ? $elm$core$Maybe$Just(26) : ((A2(r, 9728, 9838) || A2(r, 9840, 10087)) ? $elm$core$Maybe$Just(29) : ((e(10088) || e(10090)) ? $elm$core$Maybe$Just(21) : ((e(10089) || e(10091)) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))))) : (l(10175) ? ((e(10092) || (e(10094) || (e(10096) || (e(10098) || e(10100))))) ? $elm$core$Maybe$Just(21) : ((e(10093) || (e(10095) || (e(10097) || (e(10099) || e(10101))))) ? $elm$core$Maybe$Just(22) : (A2(r, 10102, 10131) ? $elm$core$Maybe$Just(8) : (A2(r, 10132, 10174) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : (l(10215) ? (e(10175) ? $elm$core$Maybe$Just(29) : ((A2(r, 10176, 10180) || A2(r, 10183, 10213)) ? $elm$core$Maybe$Just(26) : ((e(10181) || e(10214)) ? $elm$core$Maybe$Just(21) : (e(10182) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))) : ((e(10215) || (e(10217) || (e(10219) || e(10221)))) ? $elm$core$Maybe$Just(22) : ((e(10216) || (e(10218) || (e(10220) || e(10222)))) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing))))) : (l(10647) ? (l(10634) ? ((e(10223) || (e(10628) || (e(10630) || e(10632)))) ? $elm$core$Maybe$Just(22) : ((A2(r, 10224, 10239) || A2(r, 10496, 10626)) ? $elm$core$Maybe$Just(26) : (A2(r, 10240, 10495) ? $elm$core$Maybe$Just(29) : ((e(10627) || (e(10629) || (e(10631) || e(10633)))) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing)))) : (l(10639) ? ((e(10634) || (e(10636) || e(10638))) ? $elm$core$Maybe$Just(22) : ((e(10635) || e(10637)) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing)) : ((e(10639) || (e(10641) || (e(10643) || e(10645)))) ? $elm$core$Maybe$Just(21) : ((e(10640) || (e(10642) || (e(10644) || e(10646)))) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))) : (l(11076) ? (l(10714) ? ((e(10647) || e(10712)) ? $elm$core$Maybe$Just(21) : ((e(10648) || e(10713)) ? $elm$core$Maybe$Just(22) : (A2(r, 10649, 10711) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing))) : ((e(10714) || e(10748)) ? $elm$core$Maybe$Just(21) : ((e(10715) || e(10749)) ? $elm$core$Maybe$Just(22) : ((A2(r, 10716, 10747) || (A2(r, 10750, 11007) || A2(r, 11056, 11075))) ? $elm$core$Maybe$Just(26) : (A2(r, 11008, 11055) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))))) : (l(11311) ? ((e(11076) || A2(r, 11079, 11084)) ? $elm$core$Maybe$Just(26) : ((A2(r, 11077, 11078) || (A2(r, 11085, 11123) || (A2(r, 11126, 11157) || A2(r, 11159, 11263)))) ? $elm$core$Maybe$Just(29) : (A2(r, 11264, 11310) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))) : ((e(11311) || (e(11360) || (A2(r, 11362, 11364) || (e(11367) || e(11369))))) ? $elm$core$Maybe$Just(0) : ((A2(r, 11312, 11359) || (e(11361) || (A2(r, 11365, 11366) || e(11368)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))))) : (l(11431) ? (l(11405) ? (l(11392) ? ((e(11370) || (e(11372) || (e(11377) || (A2(r, 11379, 11380) || A2(r, 11382, 11387))))) ? $elm$core$Maybe$Just(1) : ((e(11371) || (A2(r, 11373, 11376) || (e(11378) || (e(11381) || A2(r, 11390, 11391))))) ? $elm$core$Maybe$Just(0) : (A2(r, 11388, 11389) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))) : (l(11397) ? ((e(11392) || (e(11394) || e(11396))) ? $elm$core$Maybe$Just(0) : ((e(11393) || e(11395)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(11397) || (e(11399) || (e(11401) || e(11403)))) ? $elm$core$Maybe$Just(1) : ((e(11398) || (e(11400) || (e(11402) || e(11404)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))) : (l(11417) ? ((e(11405) || (e(11407) || (e(11409) || (e(11411) || (e(11413) || e(11415)))))) ? $elm$core$Maybe$Just(1) : ((e(11406) || (e(11408) || (e(11410) || (e(11412) || (e(11414) || e(11416)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(11423) ? ((e(11417) || (e(11419) || e(11421))) ? $elm$core$Maybe$Just(1) : ((e(11418) || (e(11420) || e(11422))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(11423) || (e(11425) || (e(11427) || e(11429)))) ? $elm$core$Maybe$Just(1) : ((e(11424) || (e(11426) || (e(11428) || e(11430)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))) : (l(11456) ? (l(11442) ? ((e(11431) || (e(11433) || (e(11435) || (e(11437) || (e(11439) || e(11441)))))) ? $elm$core$Maybe$Just(1) : ((e(11432) || (e(11434) || (e(11436) || (e(11438) || e(11440))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(11448) ? ((e(11442) || (e(11444) || e(11446))) ? $elm$core$Maybe$Just(0) : ((e(11443) || (e(11445) || e(11447))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(11448) || (e(11450) || (e(11452) || e(11454)))) ? $elm$core$Maybe$Just(0) : ((e(11449) || (e(11451) || (e(11453) || e(11455)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(11468) ? ((e(11456) || (e(11458) || (e(11460) || (e(11462) || (e(11464) || e(11466)))))) ? $elm$core$Maybe$Just(0) : ((e(11457) || (e(11459) || (e(11461) || (e(11463) || (e(11465) || e(11467)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(11474) ? ((e(11468) || (e(11470) || e(11472))) ? $elm$core$Maybe$Just(0) : ((e(11469) || (e(11471) || e(11473))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(11474) || (e(11476) || (e(11478) || (e(11480) || e(11482))))) ? $elm$core$Maybe$Just(0) : ((e(11475) || (e(11477) || (e(11479) || e(11481)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))))) : (l(12300) ? (l(11799) ? (l(11630) ? (l(11500) ? ((e(11483) || (e(11485) || (e(11487) || (e(11489) || A2(r, 11491, 11492))))) ? $elm$core$Maybe$Just(1) : ((e(11484) || (e(11486) || (e(11488) || (e(11490) || e(11499))))) ? $elm$core$Maybe$Just(0) : (A2(r, 11493, 11498) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))) : (l(11512) ? ((e(11500) || (e(11502) || e(11507))) ? $elm$core$Maybe$Just(1) : ((e(11501) || e(11506)) ? $elm$core$Maybe$Just(0) : (A2(r, 11503, 11505) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))) : ((A2(r, 11513, 11516) || A2(r, 11518, 11519)) ? $elm$core$Maybe$Just(25) : (e(11517) ? $elm$core$Maybe$Just(8) : ((A2(r, 11520, 11557) || (e(11559) || e(11565))) ? $elm$core$Maybe$Just(1) : (A2(r, 11568, 11623) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))) : (l(11743) ? (e(11631) ? $elm$core$Maybe$Just(17) : (e(11632) ? $elm$core$Maybe$Just(25) : (e(11647) ? $elm$core$Maybe$Just(3) : ((A2(r, 11648, 11670) || (A2(r, 11680, 11686) || (A2(r, 11688, 11694) || (A2(r, 11696, 11702) || (A2(r, 11704, 11710) || (A2(r, 11712, 11718) || (A2(r, 11720, 11726) || (A2(r, 11728, 11734) || A2(r, 11736, 11742))))))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (l(11781) ? (A2(r, 11744, 11775) ? $elm$core$Maybe$Just(3) : (A2(r, 11776, 11777) ? $elm$core$Maybe$Just(25) : ((e(11778) || e(11780)) ? $elm$core$Maybe$Just(23) : (e(11779) ? $elm$core$Maybe$Just(24) : $elm$core$Maybe$Nothing)))) : ((e(11781) || (e(11786) || e(11789))) ? $elm$core$Maybe$Just(24) : ((A2(r, 11782, 11784) || (e(11787) || A2(r, 11790, 11798))) ? $elm$core$Maybe$Just(25) : ((e(11785) || e(11788)) ? $elm$core$Maybe$Just(23) : $elm$core$Maybe$Nothing)))))) : (l(11842) ? (l(11812) ? ((e(11799) || e(11802)) ? $elm$core$Maybe$Just(20) : ((A2(r, 11800, 11801) || (e(11803) || A2(r, 11806, 11807))) ? $elm$core$Maybe$Just(25) : ((e(11804) || e(11808)) ? $elm$core$Maybe$Just(23) : ((e(11805) || e(11809)) ? $elm$core$Maybe$Just(24) : (e(11810) ? $elm$core$Maybe$Just(21) : (e(11811) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))))) : (l(11817) ? ((e(11812) || (e(11814) || e(11816))) ? $elm$core$Maybe$Just(21) : ((e(11813) || e(11815)) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)) : (e(11817) ? $elm$core$Maybe$Just(22) : ((A2(r, 11818, 11822) || (A2(r, 11824, 11833) || (A2(r, 11836, 11839) || e(11841)))) ? $elm$core$Maybe$Just(25) : (e(11823) ? $elm$core$Maybe$Just(17) : ((A2(r, 11834, 11835) || e(11840)) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing)))))) : (l(11903) ? (l(11862) ? ((e(11842) || e(11861)) ? $elm$core$Maybe$Just(21) : ((A2(r, 11843, 11855) || A2(r, 11858, 11860)) ? $elm$core$Maybe$Just(25) : (A2(r, 11856, 11857) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))) : ((e(11862) || (e(11864) || (e(11866) || e(11868)))) ? $elm$core$Maybe$Just(22) : ((e(11863) || (e(11865) || e(11867))) ? $elm$core$Maybe$Just(21) : (e(11869) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing)))) : (l(12292) ? ((A2(r, 11904, 11929) || (A2(r, 11931, 12019) || (A2(r, 12032, 12245) || A2(r, 12272, 12287)))) ? $elm$core$Maybe$Just(29) : (e(12288) ? $elm$core$Maybe$Just(9) : (A2(r, 12289, 12291) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))) : (e(12292) ? $elm$core$Maybe$Just(29) : (e(12293) ? $elm$core$Maybe$Just(17) : (e(12294) ? $elm$core$Maybe$Just(18) : (e(12295) ? $elm$core$Maybe$Just(7) : ((e(12296) || e(12298)) ? $elm$core$Maybe$Just(21) : ((e(12297) || e(12299)) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)))))))))) : (l(12841) ? (l(12343) ? (l(12312) ? ((e(12300) || (e(12302) || (e(12304) || (e(12308) || e(12310))))) ? $elm$core$Maybe$Just(21) : ((e(12301) || (e(12303) || (e(12305) || (e(12309) || e(12311))))) ? $elm$core$Maybe$Just(22) : (A2(r, 12306, 12307) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))) : (l(12319) ? ((e(12312) || (e(12314) || e(12317))) ? $elm$core$Maybe$Just(21) : ((e(12313) || (e(12315) || e(12318))) ? $elm$core$Maybe$Just(22) : (e(12316) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing))) : (e(12319) ? $elm$core$Maybe$Just(22) : ((e(12320) || e(12342)) ? $elm$core$Maybe$Just(29) : (A2(r, 12321, 12329) ? $elm$core$Maybe$Just(7) : (A2(r, 12330, 12333) ? $elm$core$Maybe$Just(3) : (A2(r, 12334, 12335) ? $elm$core$Maybe$Just(4) : (e(12336) ? $elm$core$Maybe$Just(20) : (A2(r, 12337, 12341) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))))))) : (l(12538) ? (l(12352) ? ((e(12343) || A2(r, 12350, 12351)) ? $elm$core$Maybe$Just(29) : (A2(r, 12344, 12346) ? $elm$core$Maybe$Just(7) : (e(12347) ? $elm$core$Maybe$Just(17) : (e(12348) ? $elm$core$Maybe$Just(18) : (e(12349) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : ((A2(r, 12353, 12438) || (e(12447) || A2(r, 12449, 12537))) ? $elm$core$Maybe$Just(18) : (A2(r, 12441, 12442) ? $elm$core$Maybe$Just(3) : (A2(r, 12443, 12444) ? $elm$core$Maybe$Just(28) : (A2(r, 12445, 12446) ? $elm$core$Maybe$Just(17) : (e(12448) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing)))))) : (l(12689) ? ((e(12538) || (e(12543) || (A2(r, 12549, 12591) || A2(r, 12593, 12686)))) ? $elm$core$Maybe$Just(18) : (e(12539) ? $elm$core$Maybe$Just(25) : (A2(r, 12540, 12542) ? $elm$core$Maybe$Just(17) : (e(12688) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : ((e(12689) || (A2(r, 12694, 12703) || (A2(r, 12736, 12771) || (e(12783) || A2(r, 12800, 12830))))) ? $elm$core$Maybe$Just(29) : ((A2(r, 12690, 12693) || A2(r, 12832, 12840)) ? $elm$core$Maybe$Just(8) : ((A2(r, 12704, 12735) || A2(r, 12784, 12799)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))) : (l(42560) ? (l(19967) ? ((e(12841) || (A2(r, 12872, 12879) || (A2(r, 12881, 12895) || (A2(r, 12928, 12937) || A2(r, 12977, 12991))))) ? $elm$core$Maybe$Just(8) : ((A2(r, 12842, 12871) || (e(12880) || (A2(r, 12896, 12927) || (A2(r, 12938, 12976) || (A2(r, 12992, 13311) || A2(r, 19904, 19966)))))) ? $elm$core$Maybe$Just(29) : (A2(r, 13312, 19903) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : (l(42237) ? ((e(19967) || A2(r, 42128, 42182)) ? $elm$core$Maybe$Just(29) : ((A2(r, 19968, 40980) || (A2(r, 40982, 42124) || A2(r, 42192, 42231))) ? $elm$core$Maybe$Just(18) : ((e(40981) || A2(r, 42232, 42236)) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))) : ((e(42237) || e(42508)) ? $elm$core$Maybe$Just(17) : ((A2(r, 42238, 42239) || A2(r, 42509, 42511)) ? $elm$core$Maybe$Just(25) : ((A2(r, 42240, 42507) || (A2(r, 42512, 42527) || A2(r, 42538, 42539))) ? $elm$core$Maybe$Just(18) : (A2(r, 42528, 42537) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))))) : (l(42572) ? ((e(42560) || (e(42562) || (e(42564) || (e(42566) || (e(42568) || e(42570)))))) ? $elm$core$Maybe$Just(0) : ((e(42561) || (e(42563) || (e(42565) || (e(42567) || (e(42569) || e(42571)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(42578) ? ((e(42572) || (e(42574) || e(42576))) ? $elm$core$Maybe$Just(0) : ((e(42573) || (e(42575) || e(42577))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(42578) || (e(42580) || (e(42582) || (e(42584) || e(42586))))) ? $elm$core$Maybe$Just(0) : ((e(42579) || (e(42581) || (e(42583) || e(42585)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))))))) : (l(42945) ? (l(42824) ? (l(42646) ? (l(42621) ? (l(42598) ? ((e(42587) || (e(42589) || (e(42591) || (e(42593) || (e(42595) || e(42597)))))) ? $elm$core$Maybe$Just(1) : ((e(42588) || (e(42590) || (e(42592) || (e(42594) || e(42596))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(42603) ? ((e(42598) || (e(42600) || e(42602))) ? $elm$core$Maybe$Just(0) : ((e(42599) || e(42601)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(42603) || e(42605)) ? $elm$core$Maybe$Just(1) : (e(42604) ? $elm$core$Maybe$Just(0) : (e(42606) ? $elm$core$Maybe$Just(18) : ((e(42607) || A2(r, 42612, 42620)) ? $elm$core$Maybe$Just(3) : (A2(r, 42608, 42610) ? $elm$core$Maybe$Just(5) : (e(42611) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))))) : (l(42632) ? (e(42621) ? $elm$core$Maybe$Just(3) : (e(42622) ? $elm$core$Maybe$Just(25) : (e(42623) ? $elm$core$Maybe$Just(17) : ((e(42624) || (e(42626) || (e(42628) || e(42630)))) ? $elm$core$Maybe$Just(0) : ((e(42625) || (e(42627) || (e(42629) || e(42631)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(42638) ? ((e(42632) || (e(42634) || e(42636))) ? $elm$core$Maybe$Just(0) : ((e(42633) || (e(42635) || e(42637))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(42638) || (e(42640) || (e(42642) || e(42644)))) ? $elm$core$Maybe$Just(0) : ((e(42639) || (e(42641) || (e(42643) || e(42645)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(42795) ? (l(42751) ? ((e(42646) || (e(42648) || e(42650))) ? $elm$core$Maybe$Just(0) : ((e(42647) || (e(42649) || e(42651))) ? $elm$core$Maybe$Just(1) : (A2(r, 42652, 42653) ? $elm$core$Maybe$Just(17) : ((A2(r, 42654, 42655) || A2(r, 42736, 42737)) ? $elm$core$Maybe$Just(3) : (A2(r, 42656, 42725) ? $elm$core$Maybe$Just(18) : (A2(r, 42726, 42735) ? $elm$core$Maybe$Just(7) : (A2(r, 42738, 42743) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))))) : ((A2(r, 42752, 42774) || A2(r, 42784, 42785)) ? $elm$core$Maybe$Just(28) : (A2(r, 42775, 42783) ? $elm$core$Maybe$Just(17) : ((e(42786) || (e(42788) || (e(42790) || (e(42792) || e(42794))))) ? $elm$core$Maybe$Just(0) : ((e(42787) || (e(42789) || (e(42791) || e(42793)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(42809) ? ((e(42795) || (e(42797) || (A2(r, 42799, 42801) || (e(42803) || (e(42805) || e(42807)))))) ? $elm$core$Maybe$Just(1) : ((e(42796) || (e(42798) || (e(42802) || (e(42804) || (e(42806) || e(42808)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(42815) ? ((e(42809) || (e(42811) || e(42813))) ? $elm$core$Maybe$Just(1) : ((e(42810) || (e(42812) || e(42814))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(42815) || (e(42817) || (e(42819) || (e(42821) || e(42823))))) ? $elm$core$Maybe$Just(1) : ((e(42816) || (e(42818) || (e(42820) || e(42822)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))))) : (l(42882) ? (l(42848) ? (l(42835) ? ((e(42824) || (e(42826) || (e(42828) || (e(42830) || (e(42832) || e(42834)))))) ? $elm$core$Maybe$Just(0) : ((e(42825) || (e(42827) || (e(42829) || (e(42831) || e(42833))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(42840) ? ((e(42835) || (e(42837) || e(42839))) ? $elm$core$Maybe$Just(1) : ((e(42836) || e(42838)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((e(42840) || (e(42842) || (e(42844) || e(42846)))) ? $elm$core$Maybe$Just(0) : ((e(42841) || (e(42843) || (e(42845) || e(42847)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(42860) ? ((e(42848) || (e(42850) || (e(42852) || (e(42854) || (e(42856) || e(42858)))))) ? $elm$core$Maybe$Just(0) : ((e(42849) || (e(42851) || (e(42853) || (e(42855) || (e(42857) || e(42859)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(42873) ? ((e(42860) || e(42862)) ? $elm$core$Maybe$Just(0) : ((e(42861) || (e(42863) || A2(r, 42865, 42872))) ? $elm$core$Maybe$Just(1) : (e(42864) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))) : ((e(42873) || (e(42875) || (A2(r, 42877, 42878) || e(42880)))) ? $elm$core$Maybe$Just(0) : ((e(42874) || (e(42876) || (e(42879) || e(42881)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))) : (l(42910) ? (l(42894) ? ((e(42882) || (e(42884) || (e(42886) || (e(42891) || e(42893))))) ? $elm$core$Maybe$Just(0) : ((e(42883) || (e(42885) || (e(42887) || e(42892)))) ? $elm$core$Maybe$Just(1) : (e(42888) ? $elm$core$Maybe$Just(17) : (A2(r, 42889, 42890) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing)))) : (l(42902) ? ((e(42894) || (e(42897) || A2(r, 42899, 42901))) ? $elm$core$Maybe$Just(1) : (e(42895) ? $elm$core$Maybe$Just(18) : ((e(42896) || e(42898)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))) : ((e(42902) || (e(42904) || (e(42906) || e(42908)))) ? $elm$core$Maybe$Just(0) : ((e(42903) || (e(42905) || (e(42907) || e(42909)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(42926) ? (l(42915) ? ((e(42910) || (e(42912) || e(42914))) ? $elm$core$Maybe$Just(0) : ((e(42911) || e(42913)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(42915) || (e(42917) || (e(42919) || e(42921)))) ? $elm$core$Maybe$Just(1) : ((e(42916) || (e(42918) || (e(42920) || A2(r, 42922, 42925)))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))) : (l(42936) ? ((e(42926) || (A2(r, 42928, 42932) || e(42934))) ? $elm$core$Maybe$Just(0) : ((e(42927) || (e(42933) || e(42935))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : ((e(42936) || (e(42938) || (e(42940) || (e(42942) || e(42944))))) ? $elm$core$Maybe$Just(0) : ((e(42937) || (e(42939) || (e(42941) || e(42943)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))))) : (l(43697) ? (l(43273) ? (l(43042) ? (l(42993) ? ((e(42945) || (e(42947) || (e(42952) || (e(42954) || (e(42967) || (e(42969) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && A2(r, 42961, 42965)))))))) ? $elm$core$Maybe$Just(1) : ((e(42946) || (A2(r, 42948, 42951) || (e(42953) || (e(42960) || (e(42966) || e(42968)))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : (l(43002) ? ((A2(r, 42994, 42996) || A2(r, 43000, 43001)) ? $elm$core$Maybe$Just(17) : (e(42997) ? $elm$core$Maybe$Just(0) : (e(42998) ? $elm$core$Maybe$Just(1) : (e(42999) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (e(43002) ? $elm$core$Maybe$Just(1) : ((A2(r, 43003, 43009) || (A2(r, 43011, 43013) || (A2(r, 43015, 43018) || A2(r, 43020, 43041)))) ? $elm$core$Maybe$Just(18) : ((e(43010) || (e(43014) || e(43019))) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))) : (l(43137) ? (l(43055) ? (e(43042) ? $elm$core$Maybe$Just(18) : ((A2(r, 43043, 43044) || e(43047)) ? $elm$core$Maybe$Just(4) : ((A2(r, 43045, 43046) || e(43052)) ? $elm$core$Maybe$Just(3) : (A2(r, 43048, 43051) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : (A2(r, 43056, 43061) ? $elm$core$Maybe$Just(8) : ((A2(r, 43062, 43063) || e(43065)) ? $elm$core$Maybe$Just(29) : (e(43064) ? $elm$core$Maybe$Just(27) : (A2(r, 43072, 43123) ? $elm$core$Maybe$Just(18) : (A2(r, 43124, 43127) ? $elm$core$Maybe$Just(25) : (e(43136) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))))) : (l(43249) ? ((e(43137) || A2(r, 43188, 43203)) ? $elm$core$Maybe$Just(4) : (A2(r, 43138, 43187) ? $elm$core$Maybe$Just(18) : ((A2(r, 43204, 43205) || A2(r, 43232, 43248)) ? $elm$core$Maybe$Just(3) : (A2(r, 43214, 43215) ? $elm$core$Maybe$Just(25) : (A2(r, 43216, 43225) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : ((e(43249) || e(43263)) ? $elm$core$Maybe$Just(3) : ((A2(r, 43250, 43255) || (e(43259) || A2(r, 43261, 43262))) ? $elm$core$Maybe$Just(18) : ((A2(r, 43256, 43258) || e(43260)) ? $elm$core$Maybe$Just(25) : (A2(r, 43264, 43272) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))))) : (l(43494) ? (l(43442) ? (e(43273) ? $elm$core$Maybe$Just(6) : ((A2(r, 43274, 43301) || (A2(r, 43312, 43334) || (A2(r, 43360, 43388) || A2(r, 43396, 43441)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 43302, 43309) || (A2(r, 43335, 43345) || A2(r, 43392, 43394))) ? $elm$core$Maybe$Just(3) : ((A2(r, 43310, 43311) || e(43359)) ? $elm$core$Maybe$Just(25) : ((A2(r, 43346, 43347) || e(43395)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))) : (l(43453) ? (e(43442) ? $elm$core$Maybe$Just(18) : ((e(43443) || (A2(r, 43446, 43449) || e(43452))) ? $elm$core$Maybe$Just(3) : ((A2(r, 43444, 43445) || A2(r, 43450, 43451)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((e(43453) || e(43493)) ? $elm$core$Maybe$Just(3) : (A2(r, 43454, 43456) ? $elm$core$Maybe$Just(4) : ((A2(r, 43457, 43469) || A2(r, 43486, 43487)) ? $elm$core$Maybe$Just(25) : (e(43471) ? $elm$core$Maybe$Just(17) : (A2(r, 43472, 43481) ? $elm$core$Maybe$Just(6) : (A2(r, 43488, 43492) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))))) : (l(43595) ? (l(43566) ? (e(43494) ? $elm$core$Maybe$Just(17) : ((A2(r, 43495, 43503) || (A2(r, 43514, 43518) || A2(r, 43520, 43560))) ? $elm$core$Maybe$Just(18) : (A2(r, 43504, 43513) ? $elm$core$Maybe$Just(6) : (A2(r, 43561, 43565) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))) : ((e(43566) || (A2(r, 43569, 43570) || (A2(r, 43573, 43574) || e(43587)))) ? $elm$core$Maybe$Just(3) : ((A2(r, 43567, 43568) || A2(r, 43571, 43572)) ? $elm$core$Maybe$Just(4) : ((A2(r, 43584, 43586) || A2(r, 43588, 43594)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (l(43632) ? ((e(43595) || A2(r, 43616, 43631)) ? $elm$core$Maybe$Just(18) : (e(43596) ? $elm$core$Maybe$Just(3) : (e(43597) ? $elm$core$Maybe$Just(4) : (A2(r, 43600, 43609) ? $elm$core$Maybe$Just(6) : (A2(r, 43612, 43615) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : (e(43632) ? $elm$core$Maybe$Just(17) : ((A2(r, 43633, 43638) || (e(43642) || A2(r, 43646, 43695))) ? $elm$core$Maybe$Just(18) : (A2(r, 43639, 43641) ? $elm$core$Maybe$Just(29) : ((e(43643) || e(43645)) ? $elm$core$Maybe$Just(4) : ((e(43644) || e(43696)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))))))) : (l(64274) ? (l(43815) ? (l(43743) ? ((e(43697) || (A2(r, 43701, 43702) || (A2(r, 43705, 43709) || (e(43712) || (e(43714) || A2(r, 43739, 43740)))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 43698, 43700) || (A2(r, 43703, 43704) || (A2(r, 43710, 43711) || e(43713)))) ? $elm$core$Maybe$Just(3) : (e(43741) ? $elm$core$Maybe$Just(17) : (e(43742) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : (l(43762) ? ((e(43743) || A2(r, 43760, 43761)) ? $elm$core$Maybe$Just(25) : (A2(r, 43744, 43754) ? $elm$core$Maybe$Just(18) : ((e(43755) || A2(r, 43758, 43759)) ? $elm$core$Maybe$Just(4) : (A2(r, 43756, 43757) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))) : ((e(43762) || (A2(r, 43777, 43782) || (A2(r, 43785, 43790) || (A2(r, 43793, 43798) || A2(r, 43808, 43814))))) ? $elm$core$Maybe$Just(18) : (A2(r, 43763, 43764) ? $elm$core$Maybe$Just(17) : (e(43765) ? $elm$core$Maybe$Just(4) : (e(43766) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : (l(44008) ? ((A2(r, 43816, 43822) || A2(r, 43968, 44002)) ? $elm$core$Maybe$Just(18) : ((A2(r, 43824, 43866) || (A2(r, 43872, 43880) || A2(r, 43888, 43967))) ? $elm$core$Maybe$Just(1) : ((e(43867) || A2(r, 43882, 43883)) ? $elm$core$Maybe$Just(28) : ((A2(r, 43868, 43871) || e(43881)) ? $elm$core$Maybe$Just(17) : ((A2(r, 44003, 44004) || A2(r, 44006, 44007)) ? $elm$core$Maybe$Just(4) : (e(44005) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : (l(55215) ? ((e(44008) || e(44013)) ? $elm$core$Maybe$Just(3) : ((A2(r, 44009, 44010) || e(44012)) ? $elm$core$Maybe$Just(4) : (e(44011) ? $elm$core$Maybe$Just(25) : (A2(r, 44016, 44025) ? $elm$core$Maybe$Just(6) : (A2(r, 44032, 55203) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))) : ((A2(r, 55216, 55238) || (A2(r, 55243, 55291) || (A2(r, 63744, 64109) || A2(r, 64112, 64217)))) ? $elm$core$Maybe$Just(18) : (A2(r, 55296, 57343) ? $elm$core$Maybe$Just(14) : (A2(r, 57344, 63743) ? $elm$core$Maybe$Just(15) : (A2(r, 64256, 64262) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))))) : (l(65048) ? (l(64466) ? (A2(r, 64275, 64279) ? $elm$core$Maybe$Just(1) : ((e(64285) || (A2(r, 64287, 64296) || (A2(r, 64298, 64310) || (A2(r, 64312, 64316) || (e(64318) || (A2(r, 64320, 64321) || (A2(r, 64323, 64324) || A2(r, 64326, 64433)))))))) ? $elm$core$Maybe$Just(18) : (e(64286) ? $elm$core$Maybe$Just(3) : (e(64297) ? $elm$core$Maybe$Just(26) : (A2(r, 64434, 64450) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing))))) : (l(64974) ? ((A2(r, 64467, 64829) || (A2(r, 64848, 64911) || A2(r, 64914, 64967))) ? $elm$core$Maybe$Just(18) : (e(64830) ? $elm$core$Maybe$Just(22) : (e(64831) ? $elm$core$Maybe$Just(21) : (A2(r, 64832, 64847) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : ((e(64975) || A2(r, 65021, 65023)) ? $elm$core$Maybe$Just(29) : (A2(r, 65008, 65019) ? $elm$core$Maybe$Just(18) : (e(65020) ? $elm$core$Maybe$Just(27) : (A2(r, 65024, 65039) ? $elm$core$Maybe$Just(3) : (A2(r, 65040, 65046) ? $elm$core$Maybe$Just(25) : (e(65047) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing)))))))) : (l(65083) ? ((e(65048) || (e(65078) || (e(65080) || e(65082)))) ? $elm$core$Maybe$Just(22) : ((e(65049) || e(65072)) ? $elm$core$Maybe$Just(25) : (A2(r, 65056, 65071) ? $elm$core$Maybe$Just(3) : (A2(r, 65073, 65074) ? $elm$core$Maybe$Just(20) : (A2(r, 65075, 65076) ? $elm$core$Maybe$Just(19) : ((e(65077) || (e(65079) || e(65081))) ? $elm$core$Maybe$Just(21) : $elm$core$Maybe$Nothing)))))) : (l(65089) ? ((e(65083) || (e(65085) || e(65087))) ? $elm$core$Maybe$Just(21) : ((e(65084) || (e(65086) || e(65088))) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing)) : ((e(65089) || (e(65091) || e(65095))) ? $elm$core$Maybe$Just(21) : ((e(65090) || (e(65092) || e(65096))) ? $elm$core$Maybe$Just(22) : ((A2(r, 65093, 65094) || A2(r, 65097, 65100)) ? $elm$core$Maybe$Just(25) : (A2(r, 65101, 65102) ? $elm$core$Maybe$Just(19) : $elm$core$Maybe$Nothing))))))))))) : (l(71996) ? (l(69404) ? (l(66421) ? (l(65378) ? (l(65288) ? (l(65121) ? (e(65103) ? $elm$core$Maybe$Just(19) : ((A2(r, 65104, 65106) || (A2(r, 65108, 65111) || A2(r, 65119, 65120))) ? $elm$core$Maybe$Just(25) : (e(65112) ? $elm$core$Maybe$Just(20) : ((e(65113) || (e(65115) || e(65117))) ? $elm$core$Maybe$Just(21) : ((e(65114) || (e(65116) || e(65118))) ? $elm$core$Maybe$Just(22) : $elm$core$Maybe$Nothing))))) : (l(65129) ? ((e(65121) || e(65128)) ? $elm$core$Maybe$Just(25) : ((e(65122) || A2(r, 65124, 65126)) ? $elm$core$Maybe$Just(26) : (e(65123) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing))) : ((e(65129) || e(65284)) ? $elm$core$Maybe$Just(27) : ((A2(r, 65130, 65131) || (A2(r, 65281, 65283) || A2(r, 65285, 65287))) ? $elm$core$Maybe$Just(25) : ((A2(r, 65136, 65140) || A2(r, 65142, 65276)) ? $elm$core$Maybe$Just(18) : (e(65279) ? $elm$core$Maybe$Just(13) : $elm$core$Maybe$Nothing)))))) : (l(65339) ? (e(65288) ? $elm$core$Maybe$Just(21) : (e(65289) ? $elm$core$Maybe$Just(22) : ((e(65290) || (e(65292) || (A2(r, 65294, 65295) || (A2(r, 65306, 65307) || A2(r, 65311, 65312))))) ? $elm$core$Maybe$Just(25) : ((e(65291) || A2(r, 65308, 65310)) ? $elm$core$Maybe$Just(26) : (e(65293) ? $elm$core$Maybe$Just(20) : (A2(r, 65296, 65305) ? $elm$core$Maybe$Just(6) : (A2(r, 65313, 65338) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))))))) : (l(65370) ? (e(65339) ? $elm$core$Maybe$Just(21) : (e(65340) ? $elm$core$Maybe$Just(25) : (e(65341) ? $elm$core$Maybe$Just(22) : ((e(65342) || e(65344)) ? $elm$core$Maybe$Just(28) : (e(65343) ? $elm$core$Maybe$Just(19) : (A2(r, 65345, 65369) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))))) : (e(65370) ? $elm$core$Maybe$Just(1) : ((e(65371) || e(65375)) ? $elm$core$Maybe$Just(21) : ((e(65372) || e(65374)) ? $elm$core$Maybe$Just(26) : ((e(65373) || e(65376)) ? $elm$core$Maybe$Just(22) : (e(65377) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))))) : (l(65598) ? (l(65505) ? (l(65437) ? (e(65378) ? $elm$core$Maybe$Just(21) : (e(65379) ? $elm$core$Maybe$Just(22) : (A2(r, 65380, 65381) ? $elm$core$Maybe$Just(25) : ((A2(r, 65382, 65391) || A2(r, 65393, 65436)) ? $elm$core$Maybe$Just(18) : (e(65392) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))) : ((e(65437) || (A2(r, 65440, 65470) || (A2(r, 65474, 65479) || (A2(r, 65482, 65487) || (A2(r, 65490, 65495) || A2(r, 65498, 65500)))))) ? $elm$core$Maybe$Just(18) : (A2(r, 65438, 65439) ? $elm$core$Maybe$Just(17) : (e(65504) ? $elm$core$Maybe$Just(27) : $elm$core$Maybe$Nothing)))) : (l(65516) ? ((e(65505) || A2(r, 65509, 65510)) ? $elm$core$Maybe$Just(27) : ((e(65506) || A2(r, 65513, 65515)) ? $elm$core$Maybe$Just(26) : (e(65507) ? $elm$core$Maybe$Just(28) : ((e(65508) || e(65512)) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : (e(65516) ? $elm$core$Maybe$Just(26) : ((A2(r, 65517, 65518) || A2(r, 65532, 65533)) ? $elm$core$Maybe$Just(29) : (A2(r, 65529, 65531) ? $elm$core$Maybe$Just(13) : ((A2(r, 65536, 65547) || (A2(r, 65549, 65574) || (A2(r, 65576, 65594) || A2(r, 65596, 65597)))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))) : (l(65999) ? (l(65855) ? ((A2(r, 65599, 65613) || (A2(r, 65616, 65629) || A2(r, 65664, 65786))) ? $elm$core$Maybe$Just(18) : (A2(r, 65792, 65794) ? $elm$core$Maybe$Just(25) : (A2(r, 65799, 65843) ? $elm$core$Maybe$Just(8) : (A2(r, 65847, 65854) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : ((e(65855) || (A2(r, 65913, 65929) || (A2(r, 65932, 65934) || (A2(r, 65936, 65948) || e(65952))))) ? $elm$core$Maybe$Just(29) : (A2(r, 65856, 65908) ? $elm$core$Maybe$Just(7) : ((A2(r, 65909, 65912) || A2(r, 65930, 65931)) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing)))) : (l(66303) ? (A2(r, 66000, 66044) ? $elm$core$Maybe$Just(29) : ((e(66045) || e(66272)) ? $elm$core$Maybe$Just(3) : ((A2(r, 66176, 66204) || A2(r, 66208, 66256)) ? $elm$core$Maybe$Just(18) : (A2(r, 66273, 66299) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing)))) : ((A2(r, 66304, 66335) || (A2(r, 66349, 66368) || (A2(r, 66370, 66377) || A2(r, 66384, 66420)))) ? $elm$core$Maybe$Just(18) : (A2(r, 66336, 66339) ? $elm$core$Maybe$Just(8) : ((e(66369) || e(66378)) ? $elm$core$Maybe$Just(7) : $elm$core$Maybe$Nothing))))))) : (l(67902) ? (l(67071) ? (l(66735) ? ((e(66421) || (A2(r, 66432, 66461) || (A2(r, 66464, 66499) || (A2(r, 66504, 66511) || A2(r, 66640, 66717))))) ? $elm$core$Maybe$Just(18) : (A2(r, 66422, 66426) ? $elm$core$Maybe$Just(3) : ((e(66463) || e(66512)) ? $elm$core$Maybe$Just(25) : (A2(r, 66513, 66517) ? $elm$core$Maybe$Just(7) : (A2(r, 66560, 66599) ? $elm$core$Maybe$Just(0) : (A2(r, 66600, 66639) ? $elm$core$Maybe$Just(1) : (A2(r, 66720, 66729) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))))) : (l(66939) ? ((A2(r, 66736, 66771) || A2(r, 66928, 66938)) ? $elm$core$Maybe$Just(0) : (A2(r, 66776, 66811) ? $elm$core$Maybe$Just(1) : ((A2(r, 66816, 66855) || A2(r, 66864, 66915)) ? $elm$core$Maybe$Just(18) : (e(66927) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : ((A2(r, 66940, 66954) || (A2(r, 66956, 66962) || A2(r, 66964, 66965))) ? $elm$core$Maybe$Just(0) : ((A2(r, 66967, 66977) || (A2(r, 66979, 66993) || (A2(r, 66995, 67001) || A2(r, 67003, 67004)))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (l(67671) ? ((A2(r, 67072, 67382) || (A2(r, 67392, 67413) || (A2(r, 67424, 67431) || (A2(r, 67584, 67589) || (e(67592) || (A2(r, 67594, 67637) || (A2(r, 67639, 67640) || (e(67644) || A2(r, 67647, 67669))))))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 67456, 67461) || (A2(r, 67463, 67504) || A2(r, 67506, 67514))) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing)) : (l(67807) ? (e(67671) ? $elm$core$Maybe$Just(25) : ((A2(r, 67672, 67679) || (A2(r, 67705, 67711) || A2(r, 67751, 67759))) ? $elm$core$Maybe$Just(8) : ((A2(r, 67680, 67702) || A2(r, 67712, 67742)) ? $elm$core$Maybe$Just(18) : (A2(r, 67703, 67704) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : ((A2(r, 67808, 67826) || (A2(r, 67828, 67829) || (A2(r, 67840, 67861) || A2(r, 67872, 67897)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 67835, 67839) || A2(r, 67862, 67867)) ? $elm$core$Maybe$Just(8) : (e(67871) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))) : (l(68324) ? (l(68120) ? (e(67903) ? $elm$core$Maybe$Just(25) : ((A2(r, 67968, 68023) || (A2(r, 68030, 68031) || (e(68096) || (A2(r, 68112, 68115) || A2(r, 68117, 68119))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 68028, 68029) || (A2(r, 68032, 68047) || A2(r, 68050, 68095))) ? $elm$core$Maybe$Just(8) : ((A2(r, 68097, 68099) || (A2(r, 68101, 68102) || A2(r, 68108, 68111))) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))) : (l(68220) ? ((A2(r, 68121, 68149) || A2(r, 68192, 68219)) ? $elm$core$Maybe$Just(18) : ((A2(r, 68152, 68154) || e(68159)) ? $elm$core$Maybe$Just(3) : (A2(r, 68160, 68168) ? $elm$core$Maybe$Just(8) : (A2(r, 68176, 68184) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : ((e(68220) || (A2(r, 68224, 68252) || (A2(r, 68288, 68295) || A2(r, 68297, 68323)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 68221, 68222) || A2(r, 68253, 68255)) ? $elm$core$Maybe$Just(8) : (e(68223) ? $elm$core$Maybe$Just(25) : (e(68296) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))))) : (l(68607) ? (l(68415) ? ((e(68324) || A2(r, 68352, 68405)) ? $elm$core$Maybe$Just(18) : (A2(r, 68325, 68326) ? $elm$core$Maybe$Just(3) : (A2(r, 68331, 68335) ? $elm$core$Maybe$Just(8) : ((A2(r, 68336, 68342) || A2(r, 68409, 68414)) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : ((e(68415) || A2(r, 68505, 68508)) ? $elm$core$Maybe$Just(25) : ((A2(r, 68416, 68437) || (A2(r, 68448, 68466) || A2(r, 68480, 68497))) ? $elm$core$Maybe$Just(18) : ((A2(r, 68440, 68447) || (A2(r, 68472, 68479) || A2(r, 68521, 68527))) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing)))) : (l(69215) ? ((A2(r, 68608, 68680) || A2(r, 68864, 68899)) ? $elm$core$Maybe$Just(18) : (A2(r, 68736, 68786) ? $elm$core$Maybe$Just(0) : (A2(r, 68800, 68850) ? $elm$core$Maybe$Just(1) : (A2(r, 68858, 68863) ? $elm$core$Maybe$Just(8) : (A2(r, 68900, 68903) ? $elm$core$Maybe$Just(3) : (A2(r, 68912, 68921) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))))) : (A2(r, 69216, 69246) ? $elm$core$Maybe$Just(8) : ((A2(r, 69248, 69289) || (A2(r, 69296, 69297) || A2(r, 69376, 69403))) ? $elm$core$Maybe$Just(18) : ((A2(r, 69291, 69292) || A2(r, 69373, 69375)) ? $elm$core$Maybe$Just(3) : (e(69293) ? $elm$core$Maybe$Just(20) : $elm$core$Maybe$Nothing))))))))) : (l(70452) ? (l(70002) ? (l(69758) ? (l(69599) ? ((e(69404) || (e(69415) || (A2(r, 69424, 69445) || (A2(r, 69488, 69505) || A2(r, 69552, 69572))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 69405, 69414) || (A2(r, 69457, 69460) || A2(r, 69573, 69579))) ? $elm$core$Maybe$Just(8) : ((A2(r, 69446, 69456) || A2(r, 69506, 69509)) ? $elm$core$Maybe$Just(3) : ((A2(r, 69461, 69465) || A2(r, 69510, 69513)) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : (l(69702) ? ((A2(r, 69600, 69622) || A2(r, 69635, 69687)) ? $elm$core$Maybe$Just(18) : ((e(69632) || e(69634)) ? $elm$core$Maybe$Just(4) : ((e(69633) || A2(r, 69688, 69701)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))) : ((e(69702) || (e(69744) || A2(r, 69747, 69748))) ? $elm$core$Maybe$Just(3) : (A2(r, 69703, 69709) ? $elm$core$Maybe$Just(25) : (A2(r, 69714, 69733) ? $elm$core$Maybe$Just(8) : (A2(r, 69734, 69743) ? $elm$core$Maybe$Just(6) : ((A2(r, 69745, 69746) || e(69749)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))))) : (l(69839) ? ((A2(r, 69759, 69761) || (A2(r, 69811, 69814) || (A2(r, 69817, 69818) || e(69826)))) ? $elm$core$Maybe$Just(3) : ((e(69762) || (A2(r, 69808, 69810) || A2(r, 69815, 69816))) ? $elm$core$Maybe$Just(4) : (A2(r, 69763, 69807) ? $elm$core$Maybe$Just(18) : ((A2(r, 69819, 69820) || A2(r, 69822, 69825)) ? $elm$core$Maybe$Just(25) : ((e(69821) || e(69837)) ? $elm$core$Maybe$Just(13) : $elm$core$Maybe$Nothing))))) : (l(69932) ? ((A2(r, 69840, 69864) || A2(r, 69891, 69926)) ? $elm$core$Maybe$Just(18) : (A2(r, 69872, 69881) ? $elm$core$Maybe$Just(6) : ((A2(r, 69888, 69890) || A2(r, 69927, 69931)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))) : ((e(69932) || A2(r, 69957, 69958)) ? $elm$core$Maybe$Just(4) : (A2(r, 69933, 69940) ? $elm$core$Maybe$Just(3) : (A2(r, 69942, 69951) ? $elm$core$Maybe$Just(6) : (A2(r, 69952, 69955) ? $elm$core$Maybe$Just(25) : ((e(69956) || (e(69959) || A2(r, 69968, 70001))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))))))) : (l(70193) ? (l(70092) ? (l(70018) ? ((e(70002) || e(70006)) ? $elm$core$Maybe$Just(18) : ((e(70003) || A2(r, 70016, 70017)) ? $elm$core$Maybe$Just(3) : (A2(r, 70004, 70005) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))) : ((e(70018) || (A2(r, 70067, 70069) || A2(r, 70079, 70080))) ? $elm$core$Maybe$Just(4) : ((A2(r, 70019, 70066) || A2(r, 70081, 70084)) ? $elm$core$Maybe$Just(18) : ((A2(r, 70070, 70078) || A2(r, 70089, 70091)) ? $elm$core$Maybe$Just(3) : (A2(r, 70085, 70088) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : (l(70107) ? ((e(70092) || e(70095)) ? $elm$core$Maybe$Just(3) : (e(70093) ? $elm$core$Maybe$Just(25) : (e(70094) ? $elm$core$Maybe$Just(4) : (A2(r, 70096, 70105) ? $elm$core$Maybe$Just(6) : (e(70106) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))) : ((e(70107) || A2(r, 70109, 70111)) ? $elm$core$Maybe$Just(25) : ((e(70108) || (A2(r, 70144, 70161) || A2(r, 70163, 70187))) ? $elm$core$Maybe$Just(18) : (A2(r, 70113, 70132) ? $elm$core$Maybe$Just(8) : (A2(r, 70188, 70190) ? $elm$core$Maybe$Just(4) : (A2(r, 70191, 70192) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))))) : (l(70302) ? (l(70205) ? ((e(70193) || (e(70196) || A2(r, 70198, 70199))) ? $elm$core$Maybe$Just(3) : ((A2(r, 70194, 70195) || e(70197)) ? $elm$core$Maybe$Just(4) : (A2(r, 70200, 70204) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))) : (e(70205) ? $elm$core$Maybe$Just(25) : ((e(70206) || e(70209)) ? $elm$core$Maybe$Just(3) : ((A2(r, 70207, 70208) || (A2(r, 70272, 70278) || (e(70280) || (A2(r, 70282, 70285) || A2(r, 70287, 70301))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (l(70399) ? ((A2(r, 70303, 70312) || A2(r, 70320, 70366)) ? $elm$core$Maybe$Just(18) : (e(70313) ? $elm$core$Maybe$Just(25) : ((e(70367) || A2(r, 70371, 70378)) ? $elm$core$Maybe$Just(3) : (A2(r, 70368, 70370) ? $elm$core$Maybe$Just(4) : (A2(r, 70384, 70393) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : (A2(r, 70400, 70401) ? $elm$core$Maybe$Just(3) : (A2(r, 70402, 70403) ? $elm$core$Maybe$Just(4) : ((A2(r, 70405, 70412) || (A2(r, 70415, 70416) || (A2(r, 70419, 70440) || (A2(r, 70442, 70448) || A2(r, 70450, 70451))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))))) : (l(71167) ? (l(70748) ? (l(70501) ? ((A2(r, 70453, 70457) || (e(70461) || (e(70480) || A2(r, 70493, 70497)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 70459, 70460) || e(70464)) ? $elm$core$Maybe$Just(3) : ((A2(r, 70462, 70463) || (A2(r, 70465, 70468) || (A2(r, 70471, 70472) || (A2(r, 70475, 70477) || (e(70487) || A2(r, 70498, 70499)))))) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : (l(70721) ? ((A2(r, 70502, 70508) || (A2(r, 70512, 70516) || A2(r, 70712, 70719))) ? $elm$core$Maybe$Just(3) : (A2(r, 70656, 70708) ? $elm$core$Maybe$Just(18) : ((A2(r, 70709, 70711) || e(70720)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((e(70721) || e(70725)) ? $elm$core$Maybe$Just(4) : ((A2(r, 70722, 70724) || e(70726)) ? $elm$core$Maybe$Just(3) : (A2(r, 70727, 70730) ? $elm$core$Maybe$Just(18) : ((A2(r, 70731, 70735) || A2(r, 70746, 70747)) ? $elm$core$Maybe$Just(25) : (A2(r, 70736, 70745) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))))) : (l(70853) ? (l(70840) ? (e(70749) ? $elm$core$Maybe$Just(25) : ((e(70750) || A2(r, 70835, 70839)) ? $elm$core$Maybe$Just(3) : ((A2(r, 70751, 70753) || A2(r, 70784, 70831)) ? $elm$core$Maybe$Just(18) : (A2(r, 70832, 70834) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))) : ((e(70840) || (e(70842) || (A2(r, 70847, 70848) || A2(r, 70850, 70851)))) ? $elm$core$Maybe$Just(3) : ((e(70841) || (A2(r, 70843, 70846) || e(70849))) ? $elm$core$Maybe$Just(4) : (e(70852) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (l(71095) ? ((e(70853) || (e(70855) || A2(r, 71040, 71086))) ? $elm$core$Maybe$Just(18) : (e(70854) ? $elm$core$Maybe$Just(25) : (A2(r, 70864, 70873) ? $elm$core$Maybe$Just(6) : (A2(r, 71087, 71089) ? $elm$core$Maybe$Just(4) : (A2(r, 71090, 71093) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))) : ((A2(r, 71096, 71099) || e(71102)) ? $elm$core$Maybe$Just(4) : ((A2(r, 71100, 71101) || (A2(r, 71103, 71104) || A2(r, 71132, 71133))) ? $elm$core$Maybe$Just(3) : (A2(r, 71105, 71127) ? $elm$core$Maybe$Just(25) : (A2(r, 71128, 71131) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))))) : (l(71457) ? (l(71338) ? ((A2(r, 71168, 71215) || (e(71236) || A2(r, 71296, 71337))) ? $elm$core$Maybe$Just(18) : ((A2(r, 71216, 71218) || (A2(r, 71227, 71228) || e(71230))) ? $elm$core$Maybe$Just(4) : ((A2(r, 71219, 71226) || (e(71229) || A2(r, 71231, 71232))) ? $elm$core$Maybe$Just(3) : ((A2(r, 71233, 71235) || A2(r, 71264, 71276)) ? $elm$core$Maybe$Just(25) : (A2(r, 71248, 71257) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : (l(71350) ? (e(71338) ? $elm$core$Maybe$Just(18) : ((e(71339) || (e(71341) || A2(r, 71344, 71349))) ? $elm$core$Maybe$Just(3) : ((e(71340) || A2(r, 71342, 71343)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((e(71350) || e(71456)) ? $elm$core$Maybe$Just(4) : ((e(71351) || A2(r, 71453, 71455)) ? $elm$core$Maybe$Just(3) : ((e(71352) || A2(r, 71424, 71450)) ? $elm$core$Maybe$Just(18) : (e(71353) ? $elm$core$Maybe$Just(25) : (A2(r, 71360, 71369) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))))) : (l(71736) ? ((e(71457) || (e(71462) || A2(r, 71724, 71726))) ? $elm$core$Maybe$Just(4) : ((A2(r, 71458, 71461) || (A2(r, 71463, 71467) || A2(r, 71727, 71735))) ? $elm$core$Maybe$Just(3) : (A2(r, 71472, 71481) ? $elm$core$Maybe$Just(6) : (A2(r, 71482, 71483) ? $elm$core$Maybe$Just(8) : (A2(r, 71484, 71486) ? $elm$core$Maybe$Just(25) : (e(71487) ? $elm$core$Maybe$Just(29) : ((A2(r, 71488, 71494) || A2(r, 71680, 71723)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))))) : (l(71934) ? (e(71736) ? $elm$core$Maybe$Just(4) : (A2(r, 71737, 71738) ? $elm$core$Maybe$Just(3) : (e(71739) ? $elm$core$Maybe$Just(25) : (A2(r, 71840, 71871) ? $elm$core$Maybe$Just(0) : (A2(r, 71872, 71903) ? $elm$core$Maybe$Just(1) : (A2(r, 71904, 71913) ? $elm$core$Maybe$Just(6) : (A2(r, 71914, 71922) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))))) : ((A2(r, 71935, 71942) || (e(71945) || (A2(r, 71948, 71955) || (A2(r, 71957, 71958) || A2(r, 71960, 71983))))) ? $elm$core$Maybe$Just(18) : ((A2(r, 71984, 71989) || A2(r, 71991, 71992)) ? $elm$core$Maybe$Just(4) : (e(71995) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))))))) : (l(119893) ? (l(73647) ? (l(72767) ? (l(72242) ? (l(72144) ? ((e(71996) || (e(71998) || e(72003))) ? $elm$core$Maybe$Just(3) : ((e(71997) || (e(72000) || e(72002))) ? $elm$core$Maybe$Just(4) : ((e(71999) || (e(72001) || (A2(r, 72096, 72103) || A2(r, 72106, 72143)))) ? $elm$core$Maybe$Just(18) : (A2(r, 72004, 72006) ? $elm$core$Maybe$Just(25) : (A2(r, 72016, 72025) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : (l(72160) ? (e(72144) ? $elm$core$Maybe$Just(18) : ((A2(r, 72145, 72147) || A2(r, 72156, 72159)) ? $elm$core$Maybe$Just(4) : ((A2(r, 72148, 72151) || A2(r, 72154, 72155)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))) : ((e(72160) || A2(r, 72193, 72202)) ? $elm$core$Maybe$Just(3) : ((e(72161) || (e(72163) || (e(72192) || A2(r, 72203, 72241)))) ? $elm$core$Maybe$Just(18) : (e(72162) ? $elm$core$Maybe$Just(25) : (e(72164) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))))) : (l(72342) ? (l(72262) ? ((e(72242) || e(72250)) ? $elm$core$Maybe$Just(18) : ((A2(r, 72243, 72248) || A2(r, 72251, 72254)) ? $elm$core$Maybe$Just(3) : (e(72249) ? $elm$core$Maybe$Just(4) : (A2(r, 72255, 72261) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))) : (e(72262) ? $elm$core$Maybe$Just(25) : ((e(72263) || (A2(r, 72273, 72278) || (A2(r, 72281, 72283) || A2(r, 72330, 72341)))) ? $elm$core$Maybe$Just(3) : ((e(72272) || A2(r, 72284, 72329)) ? $elm$core$Maybe$Just(18) : (A2(r, 72279, 72280) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))))) : (l(72447) ? ((e(72342) || A2(r, 72344, 72345)) ? $elm$core$Maybe$Just(3) : (e(72343) ? $elm$core$Maybe$Just(4) : ((A2(r, 72346, 72348) || A2(r, 72350, 72354)) ? $elm$core$Maybe$Just(25) : ((e(72349) || A2(r, 72368, 72440)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)))) : (A2(r, 72448, 72457) ? $elm$core$Maybe$Just(25) : ((A2(r, 72704, 72712) || A2(r, 72714, 72750)) ? $elm$core$Maybe$Just(18) : ((e(72751) || e(72766)) ? $elm$core$Maybe$Just(4) : ((A2(r, 72752, 72758) || A2(r, 72760, 72765)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))))))) : (l(73065) ? (l(72884) ? ((e(72767) || (A2(r, 72850, 72871) || (A2(r, 72874, 72880) || A2(r, 72882, 72883)))) ? $elm$core$Maybe$Just(3) : ((e(72768) || A2(r, 72818, 72847)) ? $elm$core$Maybe$Just(18) : ((A2(r, 72769, 72773) || A2(r, 72816, 72817)) ? $elm$core$Maybe$Just(25) : (A2(r, 72784, 72793) ? $elm$core$Maybe$Just(6) : (A2(r, 72794, 72812) ? $elm$core$Maybe$Just(8) : ((e(72873) || e(72881)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing)))))) : (l(73019) ? (e(72884) ? $elm$core$Maybe$Just(4) : ((A2(r, 72885, 72886) || (A2(r, 73009, 73014) || e(73018))) ? $elm$core$Maybe$Just(3) : ((A2(r, 72960, 72966) || (A2(r, 72968, 72969) || A2(r, 72971, 73008))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))) : ((A2(r, 73020, 73021) || (A2(r, 73023, 73029) || e(73031))) ? $elm$core$Maybe$Just(3) : ((e(73030) || (A2(r, 73056, 73061) || A2(r, 73063, 73064))) ? $elm$core$Maybe$Just(18) : (A2(r, 73040, 73049) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))))) : (l(73471) ? (l(73110) ? (A2(r, 73066, 73097) ? $elm$core$Maybe$Just(18) : ((A2(r, 73098, 73102) || A2(r, 73107, 73108)) ? $elm$core$Maybe$Just(4) : ((A2(r, 73104, 73105) || e(73109)) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))) : ((e(73110) || A2(r, 73461, 73462)) ? $elm$core$Maybe$Just(4) : ((e(73111) || A2(r, 73459, 73460)) ? $elm$core$Maybe$Just(3) : ((e(73112) || A2(r, 73440, 73458)) ? $elm$core$Maybe$Just(18) : (A2(r, 73120, 73129) ? $elm$core$Maybe$Just(6) : (A2(r, 73463, 73464) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))) : (l(73525) ? (A2(r, 73472, 73473) ? $elm$core$Maybe$Just(3) : ((e(73474) || (A2(r, 73476, 73488) || A2(r, 73490, 73523))) ? $elm$core$Maybe$Just(18) : ((e(73475) || e(73524)) ? $elm$core$Maybe$Just(4) : $elm$core$Maybe$Nothing))) : ((e(73525) || (A2(r, 73534, 73535) || e(73537))) ? $elm$core$Maybe$Just(4) : ((A2(r, 73526, 73530) || (e(73536) || e(73538))) ? $elm$core$Maybe$Just(3) : (A2(r, 73539, 73551) ? $elm$core$Maybe$Just(25) : (A2(r, 73552, 73561) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))))))) : (l(94178) ? (l(92879) ? (l(77823) ? ((e(73648) || (A2(r, 73728, 74649) || (A2(r, 74880, 75075) || A2(r, 77712, 77808)))) ? $elm$core$Maybe$Just(18) : (A2(r, 73664, 73684) ? $elm$core$Maybe$Just(8) : ((A2(r, 73685, 73692) || A2(r, 73697, 73713)) ? $elm$core$Maybe$Just(29) : (A2(r, 73693, 73696) ? $elm$core$Maybe$Just(27) : ((e(73727) || (A2(r, 74864, 74868) || A2(r, 77809, 77810))) ? $elm$core$Maybe$Just(25) : (A2(r, 74752, 74862) ? $elm$core$Maybe$Just(7) : $elm$core$Maybe$Nothing)))))) : ((A2(r, 77824, 78895) || (A2(r, 78913, 78918) || (A2(r, 82944, 83526) || (A2(r, 92160, 92728) || (A2(r, 92736, 92766) || A2(r, 92784, 92862)))))) ? $elm$core$Maybe$Just(18) : (A2(r, 78896, 78911) ? $elm$core$Maybe$Just(13) : ((e(78912) || A2(r, 78919, 78933)) ? $elm$core$Maybe$Just(3) : ((A2(r, 92768, 92777) || A2(r, 92864, 92873)) ? $elm$core$Maybe$Just(6) : (A2(r, 92782, 92783) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing)))))) : (l(93026) ? ((A2(r, 92880, 92909) || A2(r, 92928, 92975)) ? $elm$core$Maybe$Just(18) : ((A2(r, 92912, 92916) || A2(r, 92976, 92982)) ? $elm$core$Maybe$Just(3) : ((e(92917) || (A2(r, 92983, 92987) || e(92996))) ? $elm$core$Maybe$Just(25) : ((A2(r, 92988, 92991) || e(92997)) ? $elm$core$Maybe$Just(29) : (A2(r, 92992, 92995) ? $elm$core$Maybe$Just(17) : (A2(r, 93008, 93017) ? $elm$core$Maybe$Just(6) : (A2(r, 93019, 93025) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))))) : (l(93951) ? ((A2(r, 93027, 93047) || A2(r, 93053, 93071)) ? $elm$core$Maybe$Just(18) : (A2(r, 93760, 93791) ? $elm$core$Maybe$Just(0) : (A2(r, 93792, 93823) ? $elm$core$Maybe$Just(1) : (A2(r, 93824, 93846) ? $elm$core$Maybe$Just(8) : (A2(r, 93847, 93850) ? $elm$core$Maybe$Just(25) : $elm$core$Maybe$Nothing))))) : ((A2(r, 93952, 94026) || e(94032)) ? $elm$core$Maybe$Just(18) : ((e(94031) || A2(r, 94095, 94098)) ? $elm$core$Maybe$Just(3) : (A2(r, 94033, 94087) ? $elm$core$Maybe$Just(4) : ((A2(r, 94099, 94111) || A2(r, 94176, 94177)) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))))))) : (l(118607) ? (l(110932) ? (l(101631) ? (e(94178) ? $elm$core$Maybe$Just(25) : (e(94179) ? $elm$core$Maybe$Just(17) : (e(94180) ? $elm$core$Maybe$Just(3) : (A2(r, 94192, 94193) ? $elm$core$Maybe$Just(4) : ((A2(r, 94208, 100343) || A2(r, 100352, 101589)) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing))))) : ((A2(r, 101632, 101640) || (A2(r, 110592, 110882) || (e(110898) || A2(r, 110928, 110930)))) ? $elm$core$Maybe$Just(18) : ((A2(r, 110576, 110579) || (A2(r, 110581, 110587) || A2(r, 110589, 110590))) ? $elm$core$Maybe$Just(17) : $elm$core$Maybe$Nothing))) : (l(113807) ? ((e(110933) || (A2(r, 110948, 110951) || (A2(r, 110960, 111355) || (A2(r, 113664, 113770) || (A2(r, 113776, 113788) || A2(r, 113792, 113800)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing) : (A2(r, 113808, 113817) ? $elm$core$Maybe$Just(18) : (e(113820) ? $elm$core$Maybe$Just(29) : ((A2(r, 113821, 113822) || (A2(r, 118528, 118573) || A2(r, 118576, 118598))) ? $elm$core$Maybe$Just(3) : (e(113823) ? $elm$core$Maybe$Just(25) : (A2(r, 113824, 113827) ? $elm$core$Maybe$Just(13) : $elm$core$Maybe$Nothing))))))) : (l(119209) ? (l(119145) ? ((A2(r, 118608, 118723) || (A2(r, 118784, 119029) || (A2(r, 119040, 119078) || A2(r, 119081, 119140)))) ? $elm$core$Maybe$Just(29) : (A2(r, 119141, 119142) ? $elm$core$Maybe$Just(4) : (A2(r, 119143, 119144) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing))) : ((e(119145) || (A2(r, 119163, 119170) || A2(r, 119173, 119179))) ? $elm$core$Maybe$Just(3) : ((A2(r, 119146, 119148) || (A2(r, 119171, 119172) || A2(r, 119180, 119208))) ? $elm$core$Maybe$Just(29) : (A2(r, 119149, 119154) ? $elm$core$Maybe$Just(4) : (A2(r, 119155, 119162) ? $elm$core$Maybe$Just(13) : $elm$core$Maybe$Nothing))))) : (l(119519) ? ((e(119209) || (A2(r, 119214, 119274) || (A2(r, 119296, 119361) || e(119365)))) ? $elm$core$Maybe$Just(29) : ((A2(r, 119210, 119213) || A2(r, 119362, 119364)) ? $elm$core$Maybe$Just(3) : (A2(r, 119488, 119507) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))) : ((A2(r, 119520, 119539) || A2(r, 119648, 119672)) ? $elm$core$Maybe$Just(8) : (A2(r, 119552, 119638) ? $elm$core$Maybe$Just(29) : ((A2(r, 119808, 119833) || A2(r, 119860, 119885)) ? $elm$core$Maybe$Just(0) : ((A2(r, 119834, 119859) || A2(r, 119886, 119892)) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing))))))))) : (l(124111) ? (l(120629) ? (l(120137) ? (l(120004) ? ((A2(r, 119894, 119911) || (A2(r, 119938, 119963) || (A2(r, 119990, 119993) || (e(119995) || A2(r, 119997, 120003))))) ? $elm$core$Maybe$Just(1) : ((A2(r, 119912, 119937) || (e(119964) || (A2(r, 119966, 119967) || (e(119970) || (A2(r, 119973, 119974) || (A2(r, 119977, 119980) || A2(r, 119982, 119989))))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)) : ((A2(r, 120005, 120015) || (A2(r, 120042, 120067) || A2(r, 120094, 120119))) ? $elm$core$Maybe$Just(1) : ((A2(r, 120016, 120041) || (A2(r, 120068, 120069) || (A2(r, 120071, 120074) || (A2(r, 120077, 120084) || (A2(r, 120086, 120092) || (A2(r, 120120, 120121) || (A2(r, 120123, 120126) || (A2(r, 120128, 120132) || e(120134))))))))) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))) : (l(120431) ? ((A2(r, 120138, 120144) || (A2(r, 120172, 120197) || (A2(r, 120224, 120249) || (A2(r, 120276, 120301) || (A2(r, 120328, 120353) || A2(r, 120380, 120405)))))) ? $elm$core$Maybe$Just(0) : ((A2(r, 120146, 120171) || (A2(r, 120198, 120223) || (A2(r, 120250, 120275) || (A2(r, 120302, 120327) || (A2(r, 120354, 120379) || A2(r, 120406, 120430)))))) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)) : (l(120539) ? ((e(120431) || (A2(r, 120458, 120485) || A2(r, 120514, 120538))) ? $elm$core$Maybe$Just(1) : ((A2(r, 120432, 120457) || A2(r, 120488, 120512)) ? $elm$core$Maybe$Just(0) : (e(120513) ? $elm$core$Maybe$Just(26) : $elm$core$Maybe$Nothing))) : ((e(120539) || (e(120571) || e(120597))) ? $elm$core$Maybe$Just(26) : ((A2(r, 120540, 120545) || (A2(r, 120572, 120596) || A2(r, 120598, 120603))) ? $elm$core$Maybe$Just(1) : ((A2(r, 120546, 120570) || A2(r, 120604, 120628)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))))) : (l(121478) ? (l(120771) ? ((e(120629) || (e(120655) || (e(120687) || (e(120713) || e(120745))))) ? $elm$core$Maybe$Just(26) : ((A2(r, 120630, 120654) || (A2(r, 120656, 120661) || (A2(r, 120688, 120712) || (A2(r, 120714, 120719) || A2(r, 120746, 120770))))) ? $elm$core$Maybe$Just(1) : ((A2(r, 120662, 120686) || A2(r, 120720, 120744)) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing))) : (l(121398) ? (e(120771) ? $elm$core$Maybe$Just(26) : ((A2(r, 120772, 120777) || e(120779)) ? $elm$core$Maybe$Just(1) : (e(120778) ? $elm$core$Maybe$Just(0) : (A2(r, 120782, 120831) ? $elm$core$Maybe$Just(6) : (A2(r, 120832, 121343) ? $elm$core$Maybe$Just(29) : (A2(r, 121344, 121397) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))))) : ((e(121398) || (A2(r, 121403, 121452) || (e(121461) || e(121476)))) ? $elm$core$Maybe$Just(3) : ((A2(r, 121399, 121402) || (A2(r, 121453, 121460) || (A2(r, 121462, 121475) || e(121477)))) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))) : (l(122927) ? (l(122634) ? (e(121478) ? $elm$core$Maybe$Just(29) : (A2(r, 121479, 121483) ? $elm$core$Maybe$Just(25) : ((A2(r, 121499, 121503) || A2(r, 121505, 121519)) ? $elm$core$Maybe$Just(3) : (A2(r, 122624, 122633) ? $elm$core$Maybe$Just(1) : $elm$core$Maybe$Nothing)))) : (e(122634) ? $elm$core$Maybe$Just(18) : ((A2(r, 122635, 122654) || A2(r, 122661, 122666)) ? $elm$core$Maybe$Just(1) : ((A2(r, 122880, 122886) || (A2(r, 122888, 122904) || (A2(r, 122907, 122913) || (A2(r, 122915, 122916) || A2(r, 122918, 122922))))) ? $elm$core$Maybe$Just(3) : $elm$core$Maybe$Nothing)))) : (l(123214) ? ((A2(r, 122928, 122989) || A2(r, 123191, 123197)) ? $elm$core$Maybe$Just(17) : ((e(123023) || A2(r, 123184, 123190)) ? $elm$core$Maybe$Just(3) : (A2(r, 123136, 123180) ? $elm$core$Maybe$Just(18) : (A2(r, 123200, 123209) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing)))) : ((e(123214) || (A2(r, 123536, 123565) || A2(r, 123584, 123627))) ? $elm$core$Maybe$Just(18) : (e(123215) ? $elm$core$Maybe$Just(29) : ((e(123566) || A2(r, 123628, 123631)) ? $elm$core$Maybe$Just(3) : (A2(r, 123632, 123641) ? $elm$core$Maybe$Just(6) : (e(123647) ? $elm$core$Maybe$Just(27) : $elm$core$Maybe$Nothing))))))))) : (l(127135) ? (l(126463) ? (l(125217) ? ((A2(r, 124112, 124138) || (A2(r, 124896, 124902) || (A2(r, 124904, 124907) || (A2(r, 124909, 124910) || (A2(r, 124912, 124926) || A2(r, 124928, 125124)))))) ? $elm$core$Maybe$Just(18) : (e(124139) ? $elm$core$Maybe$Just(17) : ((A2(r, 124140, 124143) || A2(r, 125136, 125142)) ? $elm$core$Maybe$Just(3) : (A2(r, 124144, 124153) ? $elm$core$Maybe$Just(6) : (A2(r, 125127, 125135) ? $elm$core$Maybe$Just(8) : (A2(r, 125184, 125216) ? $elm$core$Maybe$Just(0) : $elm$core$Maybe$Nothing)))))) : (l(126123) ? (e(125217) ? $elm$core$Maybe$Just(0) : (A2(r, 125218, 125251) ? $elm$core$Maybe$Just(1) : (A2(r, 125252, 125258) ? $elm$core$Maybe$Just(3) : (e(125259) ? $elm$core$Maybe$Just(17) : (A2(r, 125264, 125273) ? $elm$core$Maybe$Just(6) : (A2(r, 125278, 125279) ? $elm$core$Maybe$Just(25) : (A2(r, 126065, 126122) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing))))))) : ((e(126123) || (A2(r, 126125, 126127) || (A2(r, 126129, 126132) || (A2(r, 126209, 126253) || A2(r, 126255, 126269))))) ? $elm$core$Maybe$Just(8) : ((e(126124) || e(126254)) ? $elm$core$Maybe$Just(29) : (e(126128) ? $elm$core$Maybe$Just(27) : $elm$core$Maybe$Nothing))))) : (l(126566) ? (l(126515) ? ((A2(r, 126464, 126467) || (A2(r, 126469, 126495) || (A2(r, 126497, 126498) || (e(126500) || (e(126503) || A2(r, 126505, 126514)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing) : ((A2(r, 126516, 126519) || (e(126530) || (A2(r, 126541, 126543) || (A2(r, 126545, 126546) || (e(126548) || (A2(r, 126561, 126562) || (e(126564) || ((A2($elm$core$Basics$modBy, 2, code) === 1) && (A2(r, 126521, 126523) || (A2(r, 126535, 126539) || A2(r, 126551, 126559))))))))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing)) : (l(126602) ? ((A2(r, 126567, 126570) || (A2(r, 126572, 126578) || (A2(r, 126580, 126583) || (A2(r, 126585, 126588) || (e(126590) || A2(r, 126592, 126601)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing) : ((A2(r, 126603, 126619) || (A2(r, 126625, 126627) || (A2(r, 126629, 126633) || A2(r, 126635, 126651)))) ? $elm$core$Maybe$Just(18) : (A2(r, 126704, 126705) ? $elm$core$Maybe$Just(26) : ((A2(r, 126976, 127019) || A2(r, 127024, 127123)) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing)))))) : (l(129199) ? (l(127994) ? ((A2(r, 127136, 127150) || (A2(r, 127153, 127167) || (A2(r, 127169, 127183) || (A2(r, 127185, 127221) || (A2(r, 127245, 127405) || (A2(r, 127462, 127490) || (A2(r, 127504, 127547) || (A2(r, 127552, 127560) || (A2(r, 127568, 127569) || (A2(r, 127584, 127589) || A2(r, 127744, 127993))))))))))) ? $elm$core$Maybe$Just(29) : (A2(r, 127232, 127244) ? $elm$core$Maybe$Just(8) : $elm$core$Maybe$Nothing)) : (l(128991) ? ((e(127994) || (A2(r, 128000, 128727) || (A2(r, 128732, 128748) || (A2(r, 128752, 128764) || (A2(r, 128768, 128886) || A2(r, 128891, 128985)))))) ? $elm$core$Maybe$Just(29) : (A2(r, 127995, 127999) ? $elm$core$Maybe$Just(28) : $elm$core$Maybe$Nothing)) : ((A2(r, 128992, 129003) || (e(129008) || (A2(r, 129024, 129035) || (A2(r, 129040, 129095) || (A2(r, 129104, 129113) || (A2(r, 129120, 129159) || A2(r, 129168, 129197))))))) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing))) : (l(131071) ? (l(129726) ? ((A2(r, 129200, 129201) || (A2(r, 129280, 129619) || (A2(r, 129632, 129645) || (A2(r, 129648, 129660) || (A2(r, 129664, 129672) || A2(r, 129680, 129725)))))) ? $elm$core$Maybe$Just(29) : $elm$core$Maybe$Nothing) : ((A2(r, 129727, 129733) || (A2(r, 129742, 129755) || (A2(r, 129760, 129768) || (A2(r, 129776, 129784) || (A2(r, 129792, 129938) || A2(r, 129940, 129994)))))) ? $elm$core$Maybe$Just(29) : (A2(r, 130032, 130041) ? $elm$core$Maybe$Just(6) : $elm$core$Maybe$Nothing))) : (l(194559) ? ((A2(r, 131072, 173791) || (A2(r, 173824, 177977) || (A2(r, 177984, 178205) || (A2(r, 178208, 183969) || (A2(r, 183984, 191456) || A2(r, 191472, 192093)))))) ? $elm$core$Maybe$Just(18) : $elm$core$Maybe$Nothing) : ((A2(r, 194560, 195101) || (A2(r, 196608, 201546) || A2(r, 201552, 205743))) ? $elm$core$Maybe$Just(18) : ((e(917505) || A2(r, 917536, 917631)) ? $elm$core$Maybe$Just(13) : (A2(r, 917760, 917999) ? $elm$core$Maybe$Just(3) : (A2(r, 983040, 1114109) ? $elm$core$Maybe$Just(15) : $elm$core$Maybe$Nothing)))))))))))));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterIsNotPrint = function (character) {
	if ($lue_bird$elm_syntax_format$Char$Extra$isLatinAlphaNumOrUnderscoreFast(character) || ((character === ' ') || ((character === '.') || ((character === '!') || ((character === '?') || ((character === '-') || (character === ':'))))))) {
		return false;
	} else {
		var _v0 = $miniBill$elm_unicode$Unicode$getCategory(character);
		if (_v0.$ === 1) {
			return true;
		} else {
			var category = _v0.a;
			switch (category) {
				case 10:
					return true;
				case 11:
					return true;
				case 12:
					return true;
				case 13:
					return true;
				case 14:
					return true;
				case 15:
					return true;
				case 16:
					return true;
				case 0:
					return false;
				case 1:
					return false;
				case 2:
					return false;
				case 3:
					return false;
				case 4:
					return false;
				case 5:
					return false;
				case 6:
					return false;
				case 7:
					return false;
				case 8:
					return false;
				case 9:
					return true;
				case 17:
					return false;
				case 18:
					return false;
				case 19:
					return false;
				case 20:
					return false;
				case 21:
					return false;
				case 22:
					return false;
				case 23:
					return false;
				case 24:
					return false;
				case 25:
					return false;
				case 26:
					return false;
				case 27:
					return false;
				case 28:
					return false;
				default:
					return false;
			}
		}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$quotedCharToEscaped = function (character) {
	switch (character) {
		case '\'':
			return '\\\'';
		case '\\':
			return '\\\\';
		case '\t':
			return '\\t';
		case '\n':
			return '\\n';
		case '\u000D':
			return '\\u{000D}';
		default:
			var otherCharacter = character;
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterIsNotPrint(otherCharacter) ? ('\\u{' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterHex(otherCharacter) + '}')) : $elm$core$String$fromChar(otherCharacter);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$charLiteral = function (charContent) {
	return '\'' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$quotedCharToEscaped(charContent) + '\'');
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationSignature = F2(
	function (syntaxComments, signature) {
		var typePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized, syntaxComments, signature.o);
		var rangeBetweenNameAndType = {
			cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(signature.o).b9,
			b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(signature.aN).cw
		};
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					typePrint,
					function () {
						var _v0 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, rangeBetweenNameAndType, syntaxComments);
						if (!_v0.b) {
							return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
								$lue_bird$elm_syntax_format$Print$lineSpread(typePrint));
						} else {
							var comment0 = _v0.a;
							var comment1Up = _v0.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$linebreakIndented,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
										A2($elm$core$List$cons, comment0, comment1Up)),
									$lue_bird$elm_syntax_format$Print$linebreakIndented));
						}
					}())),
			$lue_bird$elm_syntax_format$Print$exactly(
				$stil4m$elm_syntax$Elm$Syntax$Node$value(signature.aN) + ' :'));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionGlsl = function (glslContent) {
	return A2(
		$lue_bird$elm_syntax_format$Print$followedBy,
		$lue_bird$elm_syntax_format$Print$exactly('|]'),
		A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A3(
				$lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten,
				$lue_bird$elm_syntax_format$Print$exactly,
				$lue_bird$elm_syntax_format$Print$linebreak,
				$elm$core$String$lines(glslContent)),
			$lue_bird$elm_syntax_format$Print$exactly('[glsl|')));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIsSpaceSeparated = function (syntaxExpression) {
	expressionIsSpaceSeparated:
	while (true) {
		switch (syntaxExpression.$) {
			case 0:
				return false;
			case 1:
				var application = syntaxExpression.a;
				if (!application.b) {
					return false;
				} else {
					if (!application.b.b) {
						var _v2 = application.a;
						var notActuallyApplied = _v2.b;
						var $temp$syntaxExpression = notActuallyApplied;
						syntaxExpression = $temp$syntaxExpression;
						continue expressionIsSpaceSeparated;
					} else {
						var _v3 = application.b;
						return true;
					}
				}
			case 2:
				return true;
			case 3:
				return false;
			case 4:
				return true;
			case 5:
				return false;
			case 6:
				return false;
			case 7:
				return false;
			case 8:
				return false;
			case 9:
				return false;
			case 10:
				return false;
			case 11:
				return false;
			case 12:
				return false;
			case 13:
				var parts = syntaxExpression.a;
				if (!parts.b) {
					return false;
				} else {
					if (!parts.b.b) {
						var _v5 = parts.a;
						var inParens = _v5.b;
						var $temp$syntaxExpression = inParens;
						syntaxExpression = $temp$syntaxExpression;
						continue expressionIsSpaceSeparated;
					} else {
						if (!parts.b.b.b) {
							var _v6 = parts.b;
							return false;
						} else {
							if (!parts.b.b.b.b) {
								var _v7 = parts.b;
								var _v8 = _v7.b;
								return false;
							} else {
								var _v9 = parts.b;
								var _v10 = _v9.b;
								var _v11 = _v10.b;
								return false;
							}
						}
					}
				}
			case 14:
				var _v12 = syntaxExpression.a;
				var inParens = _v12.b;
				var $temp$syntaxExpression = inParens;
				syntaxExpression = $temp$syntaxExpression;
				continue expressionIsSpaceSeparated;
			case 15:
				return true;
			case 16:
				return true;
			case 17:
				return true;
			case 18:
				return false;
			case 19:
				return false;
			case 20:
				return false;
			case 21:
				return false;
			case 22:
				return false;
			default:
				return false;
		}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized = function (_v0) {
	var fullRange = _v0.a;
	var syntaxExpression = _v0.b;
	switch (syntaxExpression.$) {
		case 14:
			var inParens = syntaxExpression.a;
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(inParens);
		case 13:
			var parts = syntaxExpression.a;
			if (!parts.b) {
				return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, $stil4m$elm_syntax$Elm$Syntax$Expression$UnitExpr);
			} else {
				if (!parts.b.b) {
					var inParens = parts.a;
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(inParens);
				} else {
					if (!parts.b.b.b) {
						var part0 = parts.a;
						var _v3 = parts.b;
						var part1 = _v3.a;
						return A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							fullRange,
							$stil4m$elm_syntax$Elm$Syntax$Expression$TupledExpression(
								_List_fromArray(
									[part0, part1])));
					} else {
						if (!parts.b.b.b.b) {
							var part0 = parts.a;
							var _v4 = parts.b;
							var part1 = _v4.a;
							var _v5 = _v4.b;
							var part2 = _v5.a;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								fullRange,
								$stil4m$elm_syntax$Elm$Syntax$Expression$TupledExpression(
									_List_fromArray(
										[part0, part1, part2])));
						} else {
							var part0 = parts.a;
							var _v6 = parts.b;
							var part1 = _v6.a;
							var _v7 = _v6.b;
							var part2 = _v7.a;
							var _v8 = _v7.b;
							var part3 = _v8.a;
							var part4Up = _v8.b;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								fullRange,
								$stil4m$elm_syntax$Elm$Syntax$Expression$TupledExpression(
									A2(
										$elm$core$List$cons,
										part0,
										A2(
											$elm$core$List$cons,
											part1,
											A2(
												$elm$core$List$cons,
												part2,
												A2($elm$core$List$cons, part3, part4Up))))));
						}
					}
				}
			}
		default:
			var syntaxExpressionNotParenthesized = syntaxExpression;
			return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, syntaxExpressionNotParenthesized);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIsSpaceSeparatedExceptApplication = function (expressionNode) {
	if ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIsSpaceSeparated(
		$stil4m$elm_syntax$Elm$Syntax$Node$value(expressionNode))) {
		var _v0 = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(expressionNode);
		if (_v0.b.$ === 1) {
			return false;
		} else {
			return true;
		}
	} else {
		return false;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionOperationExpand = F3(
	function (left, operator, right) {
		var rightExpanded = function () {
			if (right.b.$ === 2) {
				var _v3 = right.b;
				var rightOperator = _v3.a;
				var rightLeft = _v3.c;
				var rightRight = _v3.d;
				var rightOperationExpanded = A3($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionOperationExpand, rightLeft, rightOperator, rightRight);
				return {
					af: A2(
						$elm$core$List$cons,
						{u: rightOperationExpanded.aL, d7: operator},
						rightOperationExpanded.af),
					X: rightOperationExpanded.X,
					aj: rightOperationExpanded.aj
				};
			} else {
				var rightNotOperation = right;
				return {af: _List_Nil, X: rightNotOperation, aj: operator};
			}
		}();
		if (left.b.$ === 2) {
			var _v1 = left.b;
			var leftOperator = _v1.a;
			var leftLeft = _v1.c;
			var leftRight = _v1.d;
			var leftOperationExpanded = A3($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionOperationExpand, leftLeft, leftOperator, leftRight);
			return {
				af: _Utils_ap(
					leftOperationExpanded.af,
					A2(
						$elm$core$List$cons,
						{u: leftOperationExpanded.X, d7: leftOperationExpanded.aj},
						rightExpanded.af)),
				aL: leftOperationExpanded.aL,
				X: rightExpanded.X,
				aj: rightExpanded.aj
			};
		} else {
			var leftNotOperation = left;
			return {af: rightExpanded.af, aL: leftNotOperation, X: rightExpanded.X, aj: rightExpanded.aj};
		}
	});
var $elm$core$String$fromFloat = _String_fromNumber;
var $elm$core$Basics$truncate = _Basics_truncate;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$floatLiteral = function (_float) {
	return _Utils_eq(_float | 0, _float) ? ($elm$core$String$fromFloat(_float) + '.0') : $elm$core$String$fromFloat(_float);
};
var $elm$core$Basics$abs = function (n) {
	return (n < 0) ? (-n) : n;
};
var $elm$core$String$left = F2(
	function (n, string) {
		return (n < 1) ? '' : A3($elm$core$String$slice, 0, n, string);
	});
var $elm$core$Bitwise$and = _Bitwise_and;
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
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringResizePadLeftWith0s = F2(
	function (length, unpaddedString) {
		return (_Utils_cmp(
			length,
			$elm$core$String$length(unpaddedString)) < 0) ? A2($elm$core$String$left, length, unpaddedString) : (A2(
			$elm$core$String$repeat,
			length - $elm$core$String$length(unpaddedString),
			'0') + (unpaddedString + ''));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$hexLiteral = function (_int) {
	var maybeSignPrint = (_int < 0) ? '-' : '';
	var intAbs = $elm$core$Basics$abs(_int);
	var digitCountToPrint = (intAbs <= 255) ? 2 : ((intAbs <= 65535) ? 4 : ((intAbs <= 4294967295) ? 8 : 16));
	return maybeSignPrint + ('0x' + A2(
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringResizePadLeftWith0s,
		digitCountToPrint,
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intToHexString(_int)));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intLiteral = $elm$core$String$fromInt;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadBetweenNodes = F2(
	function (_v0, _v1) {
		var earlierRange = _v0.a;
		var laterRange = _v1.a;
		return (!(laterRange.cw.c9 - earlierRange.b9.c9)) ? 0 : 1;
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadBetweenRanges = F2(
	function (earlierRange, laterRange) {
		return (!(laterRange.cw.c9 - earlierRange.b9.c9)) ? 0 : 1;
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInNode = function (_v0) {
	var range = _v0.a;
	return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(range);
};
var $lue_bird$elm_syntax_format$Print$listReverseAndIntersperseAndFlatten = F2(
	function (inBetweenPrint, prints) {
		if (!prints.b) {
			return $lue_bird$elm_syntax_format$Print$empty;
		} else {
			var head = prints.a;
			var tail = prints.b;
			return A3(
				$elm$core$List$foldl,
				F2(
					function (next, soFar) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							soFar,
							A2($lue_bird$elm_syntax_format$Print$followedBy, inBetweenPrint, next));
					}),
				head,
				tail);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$maybeLineSpread = F2(
	function (valueToLineSpread, maybe) {
		if (maybe.$ === 1) {
			return 0;
		} else {
			var value = maybe.a;
			return valueToLineSpread(value);
		}
	});
var $stil4m$elm_syntax$Elm$Syntax$Pattern$FloatPattern = function (a) {
	return {$: 6, a: a};
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternConsExpand = function (_v0) {
	var fulRange = _v0.a;
	var syntaxPattern = _v0.b;
	switch (syntaxPattern.$) {
		case 9:
			var headPattern = syntaxPattern.a;
			var tailPattern = syntaxPattern.b;
			return A2(
				$elm$core$List$cons,
				headPattern,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternConsExpand(tailPattern));
		case 0:
			return _List_fromArray(
				[
					A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fulRange, $stil4m$elm_syntax$Elm$Syntax$Pattern$AllPattern)
				]);
		case 1:
			return _List_fromArray(
				[
					A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fulRange, $stil4m$elm_syntax$Elm$Syntax$Pattern$UnitPattern)
				]);
		case 2:
			var _char = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$CharPattern(_char))
				]);
		case 3:
			var string = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$StringPattern(string))
				]);
		case 4:
			var _int = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$IntPattern(_int))
				]);
		case 5:
			var _int = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$HexPattern(_int))
				]);
		case 6:
			var _float = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$FloatPattern(_float))
				]);
		case 7:
			var parts = syntaxPattern.a;
			if (!parts.b) {
				return _List_fromArray(
					[
						A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fulRange, $stil4m$elm_syntax$Elm$Syntax$Pattern$UnitPattern)
					]);
			} else {
				if (!parts.b.b) {
					var inParens = parts.a;
					return _List_fromArray(
						[
							A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							fulRange,
							$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
								_List_fromArray(
									[inParens])))
						]);
				} else {
					if (!parts.b.b.b) {
						var part0 = parts.a;
						var _v3 = parts.b;
						var part1 = _v3.a;
						return _List_fromArray(
							[
								A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								fulRange,
								$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
									_List_fromArray(
										[part0, part1])))
							]);
					} else {
						if (!parts.b.b.b.b) {
							var part0 = parts.a;
							var _v4 = parts.b;
							var part1 = _v4.a;
							var _v5 = _v4.b;
							var part2 = _v5.a;
							return _List_fromArray(
								[
									A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									fulRange,
									$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
										_List_fromArray(
											[part0, part1, part2])))
								]);
						} else {
							var part0 = parts.a;
							var _v6 = parts.b;
							var part1 = _v6.a;
							var _v7 = _v6.b;
							var part2 = _v7.a;
							var _v8 = _v7.b;
							var part3 = _v8.a;
							var part4Up = _v8.b;
							return _List_fromArray(
								[
									A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									fulRange,
									$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
										A2(
											$elm$core$List$cons,
											part0,
											A2(
												$elm$core$List$cons,
												part1,
												A2(
													$elm$core$List$cons,
													part2,
													A2($elm$core$List$cons, part3, part4Up))))))
								]);
						}
					}
				}
			}
		case 8:
			var fields = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$RecordPattern(fields))
				]);
		case 10:
			var elements = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$ListPattern(elements))
				]);
		case 11:
			var variableName = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$VarPattern(variableName))
				]);
		case 12:
			var reference = syntaxPattern.a;
			var parameters = syntaxPattern.b;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					A2($stil4m$elm_syntax$Elm$Syntax$Pattern$NamedPattern, reference, parameters))
				]);
		case 13:
			var aliasedPattern = syntaxPattern.a;
			var aliasName = syntaxPattern.b;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					A2($stil4m$elm_syntax$Elm$Syntax$Pattern$AsPattern, aliasedPattern, aliasName))
				]);
		default:
			var inParens = syntaxPattern.a;
			return _List_fromArray(
				[
					A2(
					$stil4m$elm_syntax$Elm$Syntax$Node$Node,
					fulRange,
					$stil4m$elm_syntax$Elm$Syntax$Pattern$ParenthesizedPattern(inParens))
				]);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternIsSpaceSeparated = function (syntaxPattern) {
	patternIsSpaceSeparated:
	while (true) {
		switch (syntaxPattern.$) {
			case 0:
				return false;
			case 1:
				return false;
			case 11:
				return false;
			case 2:
				return false;
			case 3:
				return false;
			case 4:
				return false;
			case 5:
				return false;
			case 6:
				return false;
			case 14:
				var _v1 = syntaxPattern.a;
				var inParens = _v1.b;
				var $temp$syntaxPattern = inParens;
				syntaxPattern = $temp$syntaxPattern;
				continue patternIsSpaceSeparated;
			case 7:
				var parts = syntaxPattern.a;
				if (!parts.b) {
					return false;
				} else {
					if (!parts.b.b) {
						var _v3 = parts.a;
						var inParens = _v3.b;
						var $temp$syntaxPattern = inParens;
						syntaxPattern = $temp$syntaxPattern;
						continue patternIsSpaceSeparated;
					} else {
						if (!parts.b.b.b) {
							var _v4 = parts.b;
							return false;
						} else {
							if (!parts.b.b.b.b) {
								var _v5 = parts.b;
								var _v6 = _v5.b;
								return false;
							} else {
								var _v7 = parts.b;
								var _v8 = _v7.b;
								var _v9 = _v8.b;
								return false;
							}
						}
					}
				}
			case 8:
				return false;
			case 9:
				return true;
			case 10:
				return false;
			case 12:
				var argumentPatterns = syntaxPattern.b;
				if (!argumentPatterns.b) {
					return false;
				} else {
					return true;
				}
			default:
				return true;
		}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternRecord = F2(
	function (syntaxComments, syntaxRecord) {
		var _v0 = syntaxRecord.ag;
		if (!_v0.b) {
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				function () {
					var _v1 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, syntaxRecord.c, syntaxComments);
					if (!_v1.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing;
					} else {
						var comment0 = _v1.a;
						var comment1Up = _v1.b;
						var commentsCollapsed = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
							A2($elm$core$List$cons, comment0, comment1Up));
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(commentsCollapsed.e),
								A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 1, commentsCollapsed.h)));
					}
				}(),
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpening);
		} else {
			var field0 = _v0.a;
			var field1Up = _v0.b;
			var fieldPrintsWithCommentsBefore = A3(
				$elm$core$List$foldl,
				F2(
					function (_v5, soFar) {
						var elementRange = _v5.a;
						var fieldName = _v5.b;
						return {
							cw: elementRange.cw,
							d: A2(
								$elm$core$List$cons,
								function () {
									var _v6 = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
										{cw: elementRange.b9, b9: soFar.cw},
										syntaxComments);
									if (!_v6.b) {
										return $lue_bird$elm_syntax_format$Print$exactly(fieldName);
									} else {
										var comment0 = _v6.a;
										var comment1Up = _v6.b;
										var commentsBefore = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
											A2($elm$core$List$cons, comment0, comment1Up));
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$exactly(fieldName),
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsBefore.e),
												commentsBefore.h));
									}
								}(),
								soFar.d)
						};
					}),
				{cw: syntaxRecord.c.b9, d: _List_Nil},
				A2($elm$core$List$cons, field0, field1Up));
			var maybeCommentsAfterFields = function () {
				var _v4 = A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
					{cw: syntaxRecord.c.cw, b9: fieldPrintsWithCommentsBefore.cw},
					syntaxComments);
				if (!_v4.b) {
					return $elm$core$Maybe$Nothing;
				} else {
					var comment0 = _v4.a;
					var comment1Up = _v4.b;
					return $elm$core$Maybe$Just(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
							A2($elm$core$List$cons, comment0, comment1Up)));
				}
			}();
			var lineSpread = A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v3) {
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$maybeLineSpread,
						function ($) {
							return $.e;
						},
						maybeCommentsAfterFields);
				},
				A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, fieldPrintsWithCommentsBefore.d));
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (maybeCommentsAfterFields.$ === 1) {
							return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread);
						} else {
							var commentsAfterFields = maybeCommentsAfterFields.a;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
								A2(
									$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
									2,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										commentsAfterFields.h,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))));
						}
					}(),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A3(
							$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
							function (fieldPrintWithComments) {
								return A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 2, fieldPrintWithComments);
							},
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
							fieldPrintsWithCommentsBefore.d),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningSpace)));
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternToNotParenthesized = function (_v0) {
	var fullRange = _v0.a;
	var syntaxPattern = _v0.b;
	switch (syntaxPattern.$) {
		case 14:
			var inParens = syntaxPattern.a;
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternToNotParenthesized(inParens);
		case 7:
			var parts = syntaxPattern.a;
			if (!parts.b) {
				return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, $stil4m$elm_syntax$Elm$Syntax$Pattern$UnitPattern);
			} else {
				if (!parts.b.b) {
					var inParens = parts.a;
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternToNotParenthesized(inParens);
				} else {
					if (!parts.b.b.b) {
						var part0 = parts.a;
						var _v3 = parts.b;
						var part1 = _v3.a;
						return A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							fullRange,
							$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
								_List_fromArray(
									[part0, part1])));
					} else {
						if (!parts.b.b.b.b) {
							var part0 = parts.a;
							var _v4 = parts.b;
							var part1 = _v4.a;
							var _v5 = _v4.b;
							var part2 = _v5.a;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								fullRange,
								$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
									_List_fromArray(
										[part0, part1, part2])));
						} else {
							var part0 = parts.a;
							var _v6 = parts.b;
							var part1 = _v6.a;
							var _v7 = _v6.b;
							var part2 = _v7.a;
							var _v8 = _v7.b;
							var part3 = _v8.a;
							var part4Up = _v8.b;
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								fullRange,
								$stil4m$elm_syntax$Elm$Syntax$Pattern$TuplePattern(
									A2(
										$elm$core$List$cons,
										part0,
										A2(
											$elm$core$List$cons,
											part1,
											A2(
												$elm$core$List$cons,
												part2,
												A2($elm$core$List$cons, part3, part4Up))))));
						}
					}
				}
			}
		case 0:
			return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, $stil4m$elm_syntax$Elm$Syntax$Pattern$AllPattern);
		case 1:
			return A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, $stil4m$elm_syntax$Elm$Syntax$Pattern$UnitPattern);
		case 11:
			var name = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$VarPattern(name));
		case 2:
			var _char = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$CharPattern(_char));
		case 3:
			var string = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$StringPattern(string));
		case 4:
			var _int = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$IntPattern(_int));
		case 5:
			var _int = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$HexPattern(_int));
		case 6:
			var _float = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$FloatPattern(_float));
		case 8:
			var fields = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$RecordPattern(fields));
		case 9:
			var headPattern = syntaxPattern.a;
			var tailPattern = syntaxPattern.b;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				A2($stil4m$elm_syntax$Elm$Syntax$Pattern$UnConsPattern, headPattern, tailPattern));
		case 10:
			var elementPatterns = syntaxPattern.a;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				$stil4m$elm_syntax$Elm$Syntax$Pattern$ListPattern(elementPatterns));
		case 12:
			var syntaxQualifiedNameRef = syntaxPattern.a;
			var argumentPatterns = syntaxPattern.b;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				A2($stil4m$elm_syntax$Elm$Syntax$Pattern$NamedPattern, syntaxQualifiedNameRef, argumentPatterns));
		default:
			var aliasedPattern = syntaxPattern.a;
			var aliasNameNode = syntaxPattern.b;
			return A2(
				$stil4m$elm_syntax$Elm$Syntax$Node$Node,
				fullRange,
				A2($stil4m$elm_syntax$Elm$Syntax$Pattern$AsPattern, aliasedPattern, aliasNameNode));
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyAs = $lue_bird$elm_syntax_format$Print$exactly('as');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyColonColonSpace = $lue_bird$elm_syntax_format$Print$exactly(':: ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing = $lue_bird$elm_syntax_format$Print$exactly(']');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareOpening = $lue_bird$elm_syntax_format$Print$exactly('[');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareOpeningSpace = $lue_bird$elm_syntax_format$Print$exactly('[ ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyUnderscore = $lue_bird$elm_syntax_format$Print$exactly('_');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyDoubleQuoteDoubleQuoteDoubleQuote = $lue_bird$elm_syntax_format$Print$exactly('\"\"\"');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$singleDoubleQuotedStringCharToEscaped = function (character) {
	switch (character) {
		case '\"':
			return '\\\"';
		case '\\':
			return '\\\\';
		case '\t':
			return '\\t';
		case '\n':
			return '\\n';
		case '\u000D':
			return '\\u{000D}';
		default:
			var otherCharacter = character;
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterIsNotPrint(otherCharacter) ? ('\\u{' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterHex(otherCharacter) + '}')) : $elm$core$String$fromChar(otherCharacter);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringUnicodeLength = function (string) {
	return A3(
		$elm$core$String$foldl,
		F2(
			function (_v0, soFar) {
				return soFar + 1;
			}),
		0,
		string);
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tripleDoubleQuotedStringCharToEscaped = function (character) {
	switch (character) {
		case '\"':
			return '\"';
		case '\\':
			return '\\\\';
		case '\t':
			return '\\t';
		case '\n':
			return '\n';
		case '\u000D':
			return '\u000D';
		default:
			var otherCharacter = character;
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterIsNotPrint(otherCharacter) ? ('\\u{' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$characterHex(otherCharacter) + '}')) : $elm$core$String$fromChar(otherCharacter);
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tripleDoubleQuotedStringEscapeDoubleQuotes = function (string) {
	var beforeLastCharEscaped = A3(
		$elm$core$String$foldl,
		F2(
			function (_char, soFar) {
				if ('\"' === _char) {
					return {aG: soFar.aG + 1, bJ: soFar.bJ};
				} else {
					var firstCharNotDoubleQuote = _char;
					return {
						aG: 0,
						bJ: soFar.bJ + (function () {
							var _v1 = soFar.aG;
							switch (_v1) {
								case 0:
									return '';
								case 1:
									return '\"';
								case 2:
									return '\"\"';
								default:
									var atLeast3ConsecutiveDoubleQuoteCount = _v1;
									return A2($elm$core$String$repeat, atLeast3ConsecutiveDoubleQuoteCount, '\\\"');
							}
						}() + ($elm$core$String$fromChar(firstCharNotDoubleQuote) + ''))
					};
				}
			}),
		{aG: 0, bJ: ''},
		string);
	return beforeLastCharEscaped.bJ + (A2($elm$core$String$repeat, beforeLastCharEscaped.aG, '\\\"') + '');
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringLiteral = function (_v0) {
	var range = _v0.a;
	var stringContent = _v0.b;
	var singleDoubleQuotedStringContentEscaped = A3(
		$elm$core$String$foldl,
		F2(
			function (contentChar, soFar) {
				return soFar + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$singleDoubleQuotedStringCharToEscaped(contentChar) + '');
			}),
		'',
		stringContent);
	var wasProbablyTripleDoubleQuoteOriginally = (!_Utils_eq(range.b9.c9, range.cw.c9)) || (((range.cw.cp - range.b9.cp) - $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringUnicodeLength(singleDoubleQuotedStringContentEscaped)) !== 2);
	return wasProbablyTripleDoubleQuoteOriginally ? A2(
		$lue_bird$elm_syntax_format$Print$followedBy,
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyDoubleQuoteDoubleQuoteDoubleQuote,
		A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A3(
				$lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten,
				$lue_bird$elm_syntax_format$Print$exactly,
				$lue_bird$elm_syntax_format$Print$linebreak,
				$elm$core$String$lines(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tripleDoubleQuotedStringEscapeDoubleQuotes(
						A3(
							$elm$core$String$foldl,
							F2(
								function (contentChar, soFar) {
									return soFar + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tripleDoubleQuotedStringCharToEscaped(contentChar) + '');
								}),
							'',
							stringContent)))),
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyDoubleQuoteDoubleQuoteDoubleQuote)) : $lue_bird$elm_syntax_format$Print$exactly('\"' + (singleDoubleQuotedStringContentEscaped + '\"'));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternAs = F2(
	function (syntaxComments, syntaxAs) {
		var namePrint = $lue_bird$elm_syntax_format$Print$exactly(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxAs.bR));
		var commentsBeforeAliasName = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxAs.bR).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxAs.bS).cw
			},
			syntaxComments);
		var commentsCollapsibleBeforeAliasName = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsBeforeAliasName);
		var aliasedPatternPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, syntaxAs.bS);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v24) {
				return $lue_bird$elm_syntax_format$Print$lineSpread(aliasedPatternPrint);
			},
			commentsCollapsibleBeforeAliasName.e);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentsBeforeAliasName.b) {
							return namePrint;
						} else {
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								namePrint,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsCollapsibleBeforeAliasName.e),
									commentsCollapsibleBeforeAliasName.h));
						}
					}(),
					$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyAs,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
					aliasedPatternPrint)));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternCons = F2(
	function (syntaxComments, syntaxCons) {
		var tailPatterns = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternConsExpand(syntaxCons.x);
		var tailPatternPrintsAndCommentsBeforeReverse = A3(
			$elm$core$List$foldl,
			F2(
				function (tailPatternNode, soFar) {
					var print = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, tailPatternNode);
					var _v20 = tailPatternNode;
					var tailPatternRange = _v20.a;
					return {
						cw: tailPatternRange.cw,
						d: A2(
							$elm$core$List$cons,
							function () {
								var _v21 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{cw: tailPatternRange.b9, b9: soFar.cw},
									syntaxComments);
								if (!_v21.b) {
									return print;
								} else {
									var comment0 = _v21.a;
									var comment1Up = _v21.b;
									var commentsBefore = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										print,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v22) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(print);
													},
													commentsBefore.e)),
											commentsBefore.h));
								}
							}(),
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxCons.b$).cw,
				d: _List_Nil
			},
			tailPatterns).d;
		var headPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, syntaxCons.b$);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v19) {
				return A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, tailPatternPrintsAndCommentsBeforeReverse);
			},
			$lue_bird$elm_syntax_format$Print$lineSpread(headPrint));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A3(
						$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
						function (tailPatternElementPrintWithCommentsBefore) {
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 3, tailPatternElementPrintWithCommentsBefore),
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyColonColonSpace);
						},
						$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
						tailPatternPrintsAndCommentsBeforeReverse),
					$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
			headPrint);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternList = F2(
	function (syntaxComments, syntaxList) {
		var _v11 = syntaxList.bm;
		if (!_v11.b) {
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				function () {
					var _v12 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, syntaxList.c, syntaxComments);
					if (!_v12.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing;
					} else {
						var comment0 = _v12.a;
						var comment1Up = _v12.b;
						var commentsCollapsed = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
							A2($elm$core$List$cons, comment0, comment1Up));
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(commentsCollapsed.e),
								A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 1, commentsCollapsed.h)));
					}
				}(),
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareOpening);
		} else {
			var element0 = _v11.a;
			var element1Up = _v11.b;
			var elementPrintsWithCommentsBefore = A3(
				$elm$core$List$foldl,
				F2(
					function (elementNode, soFar) {
						var elementPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized, syntaxComments, elementNode);
						var _v16 = elementNode;
						var elementRange = _v16.a;
						return {
							cw: elementRange.cw,
							d: A2(
								$elm$core$List$cons,
								function () {
									var _v17 = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
										{cw: elementRange.b9, b9: soFar.cw},
										syntaxComments);
									if (!_v17.b) {
										return elementPrint;
									} else {
										var comment0 = _v17.a;
										var comment1Up = _v17.b;
										var commentsBeforeElement = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
											A2($elm$core$List$cons, comment0, comment1Up));
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											elementPrint,
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
													A2(
														$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
														function (_v18) {
															return $lue_bird$elm_syntax_format$Print$lineSpread(elementPrint);
														},
														commentsBeforeElement.e)),
												commentsBeforeElement.h));
									}
								}(),
								soFar.d)
						};
					}),
				{cw: syntaxList.c.b9, d: _List_Nil},
				A2($elm$core$List$cons, element0, element1Up));
			var commentsAfterElements = function () {
				var _v15 = A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
					{cw: syntaxList.c.cw, b9: elementPrintsWithCommentsBefore.cw},
					syntaxComments);
				if (!_v15.b) {
					return $elm$core$Maybe$Nothing;
				} else {
					var comment0 = _v15.a;
					var comment1Up = _v15.b;
					return $elm$core$Maybe$Just(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
							A2($elm$core$List$cons, comment0, comment1Up)));
				}
			}();
			var lineSpread = A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v14) {
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$maybeLineSpread,
						function ($) {
							return $.e;
						},
						commentsAfterElements);
				},
				A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, elementPrintsWithCommentsBefore.d));
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (commentsAfterElements.$ === 1) {
							return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread);
						} else {
							var commentsCollapsibleAfterElements = commentsAfterElements.a;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
								A2(
									$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
									2,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										commentsCollapsibleAfterElements.h,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))));
						}
					}(),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A3(
							$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
							function (elementPrintWithCommentsBefore) {
								return A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 2, elementPrintWithCommentsBefore);
							},
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
							elementPrintsWithCommentsBefore.d),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareOpeningSpace)));
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized = F2(
	function (syntaxComments, _v0) {
		patternNotParenthesized:
		while (true) {
			var fullRange = _v0.a;
			var syntaxPattern = _v0.b;
			switch (syntaxPattern.$) {
				case 0:
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyUnderscore;
				case 1:
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
				case 11:
					var name = syntaxPattern.a;
					return $lue_bird$elm_syntax_format$Print$exactly(name);
				case 2:
					var _char = syntaxPattern.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$charLiteral(_char));
				case 3:
					var string = syntaxPattern.a;
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringLiteral(
						A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, string));
				case 4:
					var _int = syntaxPattern.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intLiteral(_int));
				case 5:
					var _int = syntaxPattern.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$hexLiteral(_int));
				case 6:
					var _float = syntaxPattern.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$elm$core$String$fromFloat(_float));
				case 14:
					var inParens = syntaxPattern.a;
					var commentsBeforeInParens = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{
							cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).b9,
							b9: fullRange.b9
						},
						syntaxComments);
					var commentsAfterInParens = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{
							cw: fullRange.cw,
							b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).cw
						},
						syntaxComments);
					var _v2 = _Utils_Tuple2(commentsBeforeInParens, commentsAfterInParens);
					if ((!_v2.a.b) && (!_v2.b.b)) {
						var $temp$syntaxComments = syntaxComments,
							$temp$_v0 = inParens;
						syntaxComments = $temp$syntaxComments;
						_v0 = $temp$_v0;
						continue patternNotParenthesized;
					} else {
						return A3(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized,
							{
								c: fullRange,
								U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternToNotParenthesized(inParens)
							},
							syntaxComments);
					}
				case 7:
					var parts = syntaxPattern.a;
					if (!parts.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
					} else {
						if (!parts.b.b) {
							var inParens = parts.a;
							var commentsBeforeInParens = A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
								{
									cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).b9,
									b9: fullRange.b9
								},
								syntaxComments);
							var commentsAfterInParens = A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
								{
									cw: fullRange.cw,
									b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).cw
								},
								syntaxComments);
							var _v7 = _Utils_Tuple2(commentsBeforeInParens, commentsAfterInParens);
							if ((!_v7.a.b) && (!_v7.b.b)) {
								var $temp$syntaxComments = syntaxComments,
									$temp$_v0 = inParens;
								syntaxComments = $temp$syntaxComments;
								_v0 = $temp$_v0;
								continue patternNotParenthesized;
							} else {
								return A3(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized,
									{
										c: fullRange,
										U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternToNotParenthesized(inParens)
									},
									syntaxComments);
							}
						} else {
							if (!parts.b.b.b) {
								var part0 = parts.a;
								var _v4 = parts.b;
								var part1 = _v4.a;
								return A3(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tuple,
									{R: 0, V: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized},
									syntaxComments,
									{c: fullRange, E: part0, F: part1});
							} else {
								if (!parts.b.b.b.b) {
									var part0 = parts.a;
									var _v5 = parts.b;
									var part1 = _v5.a;
									var _v6 = _v5.b;
									var part2 = _v6.a;
									return A3(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$triple,
										{R: 0, V: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized},
										syntaxComments,
										{c: fullRange, E: part0, F: part1, aa: part2});
								} else {
									var part0 = parts.a;
									var _v8 = parts.b;
									var part1 = _v8.a;
									var _v9 = _v8.b;
									var part2 = _v9.a;
									var _v10 = _v9.b;
									var part3 = _v10.a;
									var part4Up = _v10.b;
									return A3(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$invalidNTuple,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized,
										syntaxComments,
										{c: fullRange, E: part0, F: part1, aa: part2, bC: part3, bD: part4Up});
								}
							}
						}
					}
				case 8:
					var fields = syntaxPattern.a;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternRecord,
						syntaxComments,
						{ag: fields, c: fullRange});
				case 9:
					var headPattern = syntaxPattern.a;
					var tailPattern = syntaxPattern.b;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternCons,
						syntaxComments,
						{b$: headPattern, x: tailPattern});
				case 10:
					var elementPatterns = syntaxPattern.a;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternList,
						syntaxComments,
						{bm: elementPatterns, c: fullRange});
				case 12:
					var syntaxQualifiedNameRef = syntaxPattern.a;
					var argumentPatterns = syntaxPattern.b;
					return A3(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$construct,
						{R: 0, bF: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated},
						syntaxComments,
						{
							M: argumentPatterns,
							c: fullRange,
							b9: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$qualifiedReference(
								{bG: syntaxQualifiedNameRef.T, a9: syntaxQualifiedNameRef.aN})
						});
				default:
					var aliasedPattern = syntaxPattern.a;
					var aliasNameNode = syntaxPattern.b;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternAs,
						syntaxComments,
						{bR: aliasNameNode, bS: aliasedPattern});
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesized = F2(
	function (syntaxComments, patternNode) {
		return A3(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized,
			{
				c: $stil4m$elm_syntax$Elm$Syntax$Node$range(patternNode),
				U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternToNotParenthesized(patternNode)
			},
			syntaxComments);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated = F2(
	function (syntaxComments, syntaxPattern) {
		return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternIsSpaceSeparated(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxPattern)) ? A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesized, syntaxComments, syntaxPattern) : A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized, syntaxComments, syntaxPattern);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyEquals = $lue_bird$elm_syntax_format$Print$exactly('=');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printEqualsLinebreakIndented = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$Print$linebreakIndented, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyEquals);
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyBackSlash = $lue_bird$elm_syntax_format$Print$exactly('\\');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCase = $lue_bird$elm_syntax_format$Print$exactly('case');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyElse = $lue_bird$elm_syntax_format$Print$exactly('else');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyIf = $lue_bird$elm_syntax_format$Print$exactly('if');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyLessThanVerticalBar = $lue_bird$elm_syntax_format$Print$exactly('<|');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyLet = $lue_bird$elm_syntax_format$Print$exactly('let');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinus = $lue_bird$elm_syntax_format$Print$exactly('-');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyOf = $lue_bird$elm_syntax_format$Print$exactly('of');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyThen = $lue_bird$elm_syntax_format$Print$exactly('then');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyIn = $lue_bird$elm_syntax_format$Print$exactly('in');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedInLinebreakIndented = A2(
	$lue_bird$elm_syntax_format$Print$followedBy,
	$lue_bird$elm_syntax_format$Print$linebreakIndented,
	A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyIn, $lue_bird$elm_syntax_format$Print$linebreakIndented));
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakIndented = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$Print$linebreakIndented, $lue_bird$elm_syntax_format$Print$linebreak);
var $elm$core$String$replace = F3(
	function (before, after, string) {
		return A2(
			$elm$core$String$join,
			after,
			A2($elm$core$String$split, before, string));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$case_ = F2(
	function (syntaxComments, _v91) {
		var casePattern = _v91.a;
		var caseResult = _v91.b;
		var patternPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternNotParenthesized, syntaxComments, casePattern);
		var commentsBeforeExpression = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(caseResult).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(casePattern).cw
			},
			syntaxComments);
		var caseResultPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, caseResult);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentsBeforeExpression.b) {
							return caseResultPrint;
						} else {
							var comment0 = commentsBeforeExpression.a;
							var comment1Up = commentsBeforeExpression.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								caseResultPrint,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$linebreakIndented,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
										A2($elm$core$List$cons, comment0, comment1Up))));
						}
					}(),
					$lue_bird$elm_syntax_format$Print$linebreakIndented)),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusGreaterThan,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
						$lue_bird$elm_syntax_format$Print$lineSpread(patternPrint)),
					patternPrint)));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationExpressionImplementation = F2(
	function (syntaxComments, implementation) {
		var parameterPrintsWithCommentsBefore = A3(
			$elm$core$List$foldl,
			F2(
				function (parameterPattern, soFar) {
					var parameterRange = $stil4m$elm_syntax$Elm$Syntax$Node$range(parameterPattern);
					var parameterPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, parameterPattern);
					return {
						cw: parameterRange.cw,
						d: A2(
							$elm$core$List$cons,
							function () {
								var _v89 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{cw: parameterRange.b9, b9: soFar.cw},
									syntaxComments);
								if (!_v89.b) {
									return parameterPrint;
								} else {
									var comment0 = _v89.a;
									var comment1Up = _v89.b;
									var commentsBefore = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										parameterPrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v90) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(parameterPrint);
													},
													commentsBefore.e)),
											commentsBefore.h));
								}
							}(),
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(implementation.aN).cw,
				d: _List_Nil
			},
			implementation.M);
		var parametersLineSpread = A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, parameterPrintsWithCommentsBefore.d);
		var expressionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, implementation.u);
		var commentsBetweenParametersAndResult = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(implementation.u).b9,
				b9: parameterPrintsWithCommentsBefore.cw
			},
			syntaxComments);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						function () {
							if (!commentsBetweenParametersAndResult.b) {
								return expressionPrint;
							} else {
								var comment0 = commentsBetweenParametersAndResult.a;
								var comment1Up = commentsBetweenParametersAndResult.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									expressionPrint,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$linebreakIndented,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up))));
							}
						}(),
						$lue_bird$elm_syntax_format$Print$linebreakIndented),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyEquals,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread),
							A2(
								$lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten,
								function (parameterPrintWithCommentsBefore) {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										parameterPrintWithCommentsBefore,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread));
								},
								parameterPrintsWithCommentsBefore.d))))),
			$lue_bird$elm_syntax_format$Print$exactly(
				$stil4m$elm_syntax$Elm$Syntax$Node$value(implementation.aN)));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionCall = F2(
	function (syntaxComments, syntaxCall) {
		var commentsBeforeArgument0 = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxCall.aY).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxCall.bb).cw
			},
			syntaxComments);
		var collapsibleCommentsBeforeArgument0 = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsBeforeArgument0);
		var argument1UpPrintsWithCommentsBeforeReverse = A3(
			$elm$core$List$foldl,
			F2(
				function (argument, soFar) {
					var print = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparated, syntaxComments, argument);
					return {
						aq: $stil4m$elm_syntax$Elm$Syntax$Node$range(argument).cw,
						at: A2(
							$elm$core$List$cons,
							function () {
								var _v86 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(argument).b9,
										b9: soFar.aq
									},
									syntaxComments);
								if (!_v86.b) {
									return print;
								} else {
									var comment0 = _v86.a;
									var comment1Up = _v86.b;
									var commentsBefore = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										print,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v87) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(print);
													},
													commentsBefore.e)),
											commentsBefore.h));
								}
							}(),
							soFar.at)
					};
				}),
			{
				aq: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxCall.aY).cw,
				at: _List_Nil
			},
			syntaxCall.ch).at;
		var argument0Print = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparated, syntaxComments, syntaxCall.aY);
		var appliedPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparated, syntaxComments, syntaxCall.bb);
		var argument0LineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v85) {
				return $lue_bird$elm_syntax_format$Print$lineSpread(argument0Print);
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
				collapsibleCommentsBeforeArgument0.e,
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
					function (_v84) {
						return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadBetweenNodes, syntaxCall.bb, syntaxCall.aY);
					},
					$lue_bird$elm_syntax_format$Print$lineSpread(appliedPrint))));
		var argument1UpLineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v83) {
				return A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, argument1UpPrintsWithCommentsBeforeReverse);
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
				argument0LineSpread,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxCall.c)));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten,
						function (argumentPrintWithCommentsBefore) {
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								argumentPrintWithCommentsBefore,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(argument1UpLineSpread));
						},
						argument1UpPrintsWithCommentsBeforeReverse),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						function () {
							if (!commentsBeforeArgument0.b) {
								return argument0Print;
							} else {
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									argument0Print,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
											A2(
												$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
												function (_v82) {
													return $lue_bird$elm_syntax_format$Print$lineSpread(argument0Print);
												},
												collapsibleCommentsBeforeArgument0.e)),
										collapsibleCommentsBeforeArgument0.h));
							}
						}(),
						$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(argument0LineSpread)))),
			appliedPrint);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionCaseOf = F2(
	function (syntaxComments, syntaxCaseOf) {
		var commentsBeforeCasedExpression = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxCaseOf.u).b9,
				b9: syntaxCaseOf.c.b9
			},
			syntaxComments);
		var casedExpressionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, syntaxCaseOf.u);
		var casedExpressionLineSpread = function () {
			if (commentsBeforeCasedExpression.b) {
				return 1;
			} else {
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInNode(syntaxCaseOf.u);
			}
		}();
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$listReverseAndIntersperseAndFlatten,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakIndented,
						A3(
							$elm$core$List$foldl,
							F2(
								function (_v78, soFar) {
									var casePattern = _v78.a;
									var caseResult = _v78.b;
									var commentsBeforeCasePattern = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
										{
											cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(casePattern).b9,
											b9: soFar.cw
										},
										syntaxComments);
									var casePrint = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$case_,
										syntaxComments,
										_Utils_Tuple2(casePattern, caseResult));
									var commentsAndCasePrint = function () {
										if (!commentsBeforeCasePattern.b) {
											return casePrint;
										} else {
											var comment0 = commentsBeforeCasePattern.a;
											var comment1Up = commentsBeforeCasePattern.b;
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												casePrint,
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$linebreakIndented,
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
														A2($elm$core$List$cons, comment0, comment1Up))));
										}
									}();
									return {
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(caseResult).cw,
										d: A2($elm$core$List$cons, commentsAndCasePrint, soFar.d)
									};
								}),
							{
								cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxCaseOf.u).cw,
								d: _List_Nil
							},
							syntaxCaseOf.be).d),
					$lue_bird$elm_syntax_format$Print$linebreakIndented)),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyOf,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(casedExpressionLineSpread),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								function () {
									if (!commentsBeforeCasedExpression.b) {
										return casedExpressionPrint;
									} else {
										var comment0 = commentsBeforeCasedExpression.a;
										var comment1Up = commentsBeforeCasedExpression.b;
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											casedExpressionPrint,
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$linebreakIndented,
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
													A2($elm$core$List$cons, comment0, comment1Up))));
									}
								}(),
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(casedExpressionLineSpread))),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCase))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIfThenElse = F2(
	function (syntaxComments, syntaxIfThenElse) {
		var onTruePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, syntaxIfThenElse.aO);
		var onFalseNotParenthesized = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(syntaxIfThenElse.aB);
		var conditionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, syntaxIfThenElse.aF);
		var commentsBeforeOnTrue = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxIfThenElse.aO).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxIfThenElse.aF).cw
			},
			syntaxComments);
		var commentsBeforeOnFalseNotParenthesizedInParens = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(onFalseNotParenthesized).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxIfThenElse.aB).b9
			},
			syntaxComments);
		var commentsBeforeOnFalse = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxIfThenElse.aB).b9,
				b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxIfThenElse.aO).cw
			},
			syntaxComments);
		var commentsBeforeCondition = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxIfThenElse.aF).b9,
				b9: syntaxIfThenElse.c.b9
			},
			syntaxComments);
		var conditionLineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v75) {
				if (commentsBeforeCondition.b) {
					return 1;
				} else {
					return 0;
				}
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v74) {
					return $lue_bird$elm_syntax_format$Print$lineSpread(conditionPrint);
				},
				syntaxIfThenElse.bh));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			function () {
				var _v69 = _Utils_Tuple2(commentsBeforeOnFalseNotParenthesizedInParens, onFalseNotParenthesized);
				if ((!_v69.a.b) && (_v69.b.b.$ === 4)) {
					var _v70 = _v69.b;
					var onFalseNotParenthesizedRange = _v70.a;
					var _v71 = _v70.b;
					var onFalseCondition = _v71.a;
					var onFalseOnTrue = _v71.b;
					var onFalseOnFalse = _v71.c;
					if (!commentsBeforeOnFalse.b) {
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIfThenElse,
								syntaxComments,
								{aF: onFalseCondition, bh: 0, c: onFalseNotParenthesizedRange, aB: onFalseOnFalse, aO: onFalseOnTrue}),
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySpace);
					} else {
						var comment0 = commentsBeforeOnFalse.a;
						var comment1Up = commentsBeforeOnFalse.b;
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIfThenElse,
								syntaxComments,
								{aF: onFalseCondition, bh: 1, c: onFalseNotParenthesizedRange, aB: onFalseOnFalse, aO: onFalseOnTrue}),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$linebreakIndented,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
										A2($elm$core$List$cons, comment0, comment1Up)),
									$lue_bird$elm_syntax_format$Print$linebreakIndented)));
					}
				} else {
					var onFalsePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, syntaxIfThenElse.aB);
					return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!commentsBeforeOnFalse.b) {
									return onFalsePrint;
								} else {
									var comment0 = commentsBeforeOnFalse.a;
									var comment1Up = commentsBeforeOnFalse.b;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										onFalsePrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$linebreakIndented,
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
												A2($elm$core$List$cons, comment0, comment1Up))));
								}
							}(),
							$lue_bird$elm_syntax_format$Print$linebreakIndented));
				}
			}(),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyElse,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$linebreakIndented,
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$linebreak,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									function () {
										if (!commentsBeforeOnTrue.b) {
											return onTruePrint;
										} else {
											var comment0 = commentsBeforeOnTrue.a;
											var comment1Up = commentsBeforeOnTrue.b;
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												onTruePrint,
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$linebreakIndented,
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
														A2($elm$core$List$cons, comment0, comment1Up))));
										}
									}(),
									$lue_bird$elm_syntax_format$Print$linebreakIndented))),
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyThen,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(conditionLineSpread),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											function () {
												if (!commentsBeforeCondition.b) {
													return conditionPrint;
												} else {
													var comment0 = commentsBeforeCondition.a;
													var comment1Up = commentsBeforeCondition.b;
													return A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														conditionPrint,
														A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															$lue_bird$elm_syntax_format$Print$linebreakIndented,
															$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
																A2($elm$core$List$cons, comment0, comment1Up))));
												}
											}(),
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(conditionLineSpread))),
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyIf)))))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionLambda = F2(
	function (syntaxComments, _v61) {
		var fullRange = _v61.a;
		var syntaxLambda = _v61.b;
		var resultPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, syntaxLambda.u);
		var parameterPrintsWithCommentsBefore = A3(
			$elm$core$List$foldl,
			F2(
				function (parameterPattern, soFar) {
					var print = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, parameterPattern);
					var parameterRange = $stil4m$elm_syntax$Elm$Syntax$Node$range(parameterPattern);
					return {
						cw: parameterRange.cw,
						d: A2(
							$elm$core$List$cons,
							function () {
								var _v65 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{cw: parameterRange.b9, b9: soFar.cw},
									syntaxComments);
								if (!_v65.b) {
									return print;
								} else {
									var comment0 = _v65.a;
									var comment1Up = _v65.b;
									var commentsBefore = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										print,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v66) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(print);
													},
													commentsBefore.e)),
											commentsBefore.h));
								}
							}(),
							soFar.d)
					};
				}),
			{cw: fullRange.b9, d: _List_Nil},
			syntaxLambda.dx);
		var parametersLineSpread = A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, parameterPrintsWithCommentsBefore.d);
		var commentsBeforeResult = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxLambda.u).b9,
				b9: parameterPrintsWithCommentsBefore.cw
			},
			syntaxComments);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						resultPrint,
						function () {
							if (!commentsBeforeResult.b) {
								return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
									A2(
										$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
										function (_v64) {
											return $lue_bird$elm_syntax_format$Print$lineSpread(resultPrint);
										},
										A2(
											$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
											function (_v63) {
												return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(fullRange);
											},
											parametersLineSpread)));
							} else {
								var comment0 = commentsBeforeResult.a;
								var comment1Up = commentsBeforeResult.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$linebreakIndented,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										$lue_bird$elm_syntax_format$Print$linebreakIndented));
							}
						}())),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinusGreaterThan,
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread),
						A2(
							$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
							1,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								A2(
									$lue_bird$elm_syntax_format$Print$listReverseAndIntersperseAndFlatten,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread),
									parameterPrintsWithCommentsBefore.d),
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(parametersLineSpread)))))),
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyBackSlash);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionLetDeclaration = F2(
	function (syntaxComments, letDeclaration) {
		if (!letDeclaration.$) {
			var letDeclarationExpression = letDeclaration.a;
			var implementationPrint = A2(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationExpressionImplementation,
				syntaxComments,
				$stil4m$elm_syntax$Elm$Syntax$Node$value(letDeclarationExpression.G));
			var _v57 = letDeclarationExpression.K;
			if (_v57.$ === 1) {
				return implementationPrint;
			} else {
				var _v58 = _v57.a;
				var signatureRange = _v58.a;
				var signature = _v58.b;
				var commentsBetweenSignatureAndImplementationName = A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
					{
						cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(letDeclarationExpression.G).b9,
						b9: signatureRange.cw
					},
					syntaxComments);
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					implementationPrint,
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						function () {
							if (!commentsBetweenSignatureAndImplementationName.b) {
								return $lue_bird$elm_syntax_format$Print$linebreakIndented;
							} else {
								var comment0 = commentsBetweenSignatureAndImplementationName.a;
								var comment1Up = commentsBetweenSignatureAndImplementationName.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$linebreakIndented,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										$lue_bird$elm_syntax_format$Print$linebreakIndented));
							}
						}(),
						A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationSignature, syntaxComments, signature)));
			}
		} else {
			var destructuringPattern = letDeclaration.a;
			var destructuredExpression = letDeclaration.b;
			var destructuringPatternPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, destructuringPattern);
			var destructuredExpressionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, destructuredExpression);
			var commentsBeforeDestructuredExpression = A2(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
				{
					cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(destructuredExpression).b9,
					b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(destructuringPattern).cw
				},
				syntaxComments);
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						function () {
							if (!commentsBeforeDestructuredExpression.b) {
								return destructuredExpressionPrint;
							} else {
								var comment0 = commentsBeforeDestructuredExpression.a;
								var comment1Up = commentsBeforeDestructuredExpression.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									destructuredExpressionPrint,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$linebreakIndented,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up))));
							}
						}(),
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printEqualsLinebreakIndented,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
								$lue_bird$elm_syntax_format$Print$lineSpread(destructuringPatternPrint))))),
				destructuringPatternPrint);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionLetIn = F2(
	function (syntaxComments, syntaxLetIn) {
		var letInResultPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, syntaxLetIn.bJ);
		var letDeclarationPrints = A3(
			$elm$core$List$foldl,
			F2(
				function (_v54, soFar) {
					var letDeclarationRange = _v54.a;
					var letDeclaration = _v54.b;
					var letDeclarationPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionLetDeclaration, syntaxComments, letDeclaration);
					var commentsBefore = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{cw: letDeclarationRange.b9, b9: soFar.cw},
						syntaxComments);
					var letDeclarationWithCommentsBeforePrint = function () {
						if (!commentsBefore.b) {
							return letDeclarationPrint;
						} else {
							var comment0 = commentsBefore.a;
							var comment1Up = commentsBefore.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								letDeclarationPrint,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$linebreakIndented,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
										A2($elm$core$List$cons, comment0, comment1Up))));
						}
					}();
					return {
						cw: letDeclarationRange.cw,
						d: A2($elm$core$List$cons, letDeclarationWithCommentsBeforePrint, soFar.d)
					};
				}),
			{cw: syntaxLetIn.c.b9, d: _List_Nil},
			A2($elm$core$List$cons, syntaxLetIn.cO, syntaxLetIn.cP));
		var commentsBeforeResult = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxLetIn.bJ).b9,
				b9: letDeclarationPrints.cw
			},
			syntaxComments);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			function () {
				if (!commentsBeforeResult.b) {
					return letInResultPrint;
				} else {
					var comment0 = commentsBeforeResult.a;
					var comment1Up = commentsBeforeResult.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						letInResultPrint,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$linebreakIndented,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
								A2($elm$core$List$cons, comment0, comment1Up))));
				}
			}(),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedInLinebreakIndented,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							A2($lue_bird$elm_syntax_format$Print$listReverseAndIntersperseAndFlatten, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakIndented, letDeclarationPrints.d),
							$lue_bird$elm_syntax_format$Print$linebreakIndented)),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyLet)));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionList = F2(
	function (syntaxComments, syntaxList) {
		var _v44 = syntaxList.bm;
		if (!_v44.b) {
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				function () {
					var _v45 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, syntaxList.c, syntaxComments);
					if (!_v45.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing;
					} else {
						var comment0 = _v45.a;
						var comment1Up = _v45.b;
						var commentsCollapsed = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
							A2($elm$core$List$cons, comment0, comment1Up));
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(commentsCollapsed.e),
								A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 1, commentsCollapsed.h)));
					}
				}(),
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareOpening);
		} else {
			var element0 = _v44.a;
			var element1Up = _v44.b;
			var elementPrintsWithCommentsBefore = A3(
				$elm$core$List$foldl,
				F2(
					function (elementNode, soFar) {
						var print = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, elementNode);
						var _v50 = elementNode;
						var elementRange = _v50.a;
						return {
							cw: elementRange.cw,
							d: A2(
								$elm$core$List$cons,
								function () {
									var _v51 = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
										{cw: elementRange.b9, b9: soFar.cw},
										syntaxComments);
									if (!_v51.b) {
										return print;
									} else {
										var comment0 = _v51.a;
										var comment1Up = _v51.b;
										var commentsBefore = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
											A2($elm$core$List$cons, comment0, comment1Up));
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											print,
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
													A2(
														$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
														function (_v52) {
															return $lue_bird$elm_syntax_format$Print$lineSpread(print);
														},
														commentsBefore.e)),
												commentsBefore.h));
									}
								}(),
								soFar.d)
						};
					}),
				{cw: syntaxList.c.b9, d: _List_Nil},
				A2($elm$core$List$cons, element0, element1Up));
			var commentsAfterElements = A2(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
				{cw: syntaxList.c.cw, b9: elementPrintsWithCommentsBefore.cw},
				syntaxComments);
			var lineSpread = A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v48) {
					if (!commentsAfterElements.b) {
						return 0;
					} else {
						return 1;
					}
				},
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
					function (_v47) {
						return A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, elementPrintsWithCommentsBefore.d);
					},
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxList.c)));
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareClosing,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentsAfterElements.b) {
							return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread);
						} else {
							var comment0 = commentsAfterElements.a;
							var comment1Up = commentsAfterElements.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
										A2($elm$core$List$cons, comment0, comment1Up)),
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
										$lue_bird$elm_syntax_format$Print$linebreak)));
						}
					}(),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A3(
							$lue_bird$elm_syntax_format$Print$listReverseAndMapAndIntersperseAndFlatten,
							function (elementPrintWithCommentsBefore) {
								return A2($lue_bird$elm_syntax_format$Print$withIndentIncreasedBy, 2, elementPrintWithCommentsBefore);
							},
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
								$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
							elementPrintsWithCommentsBefore.d),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlySquareOpeningSpace)));
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized = F2(
	function (syntaxComments, _v29) {
		expressionNotParenthesized:
		while (true) {
			var fullRange = _v29.a;
			var syntaxExpression = _v29.b;
			switch (syntaxExpression.$) {
				case 0:
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
				case 1:
					var application = syntaxExpression.a;
					if (!application.b) {
						return $lue_bird$elm_syntax_format$Print$empty;
					} else {
						if (!application.b.b) {
							var notAppliedAfterAll = application.a;
							var $temp$syntaxComments = syntaxComments,
								$temp$_v29 = notAppliedAfterAll;
							syntaxComments = $temp$syntaxComments;
							_v29 = $temp$_v29;
							continue expressionNotParenthesized;
						} else {
							var applied = application.a;
							var _v32 = application.b;
							var argument0 = _v32.a;
							var argument1Up = _v32.b;
							return A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionCall,
								syntaxComments,
								{bb: applied, aY: argument0, ch: argument1Up, c: fullRange});
						}
					}
				case 2:
					var operator = syntaxExpression.a;
					var left = syntaxExpression.c;
					var right = syntaxExpression.d;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionOperation,
						syntaxComments,
						{c: fullRange, cN: left, d7: operator, c8: right});
				case 3:
					var qualification = syntaxExpression.a;
					var unqualified = syntaxExpression.b;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$qualifiedReference(
							{bG: qualification, a9: unqualified}));
				case 4:
					var condition = syntaxExpression.a;
					var onTrue = syntaxExpression.b;
					var onFalse = syntaxExpression.c;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIfThenElse,
						syntaxComments,
						{aF: condition, bh: 0, c: fullRange, aB: onFalse, aO: onTrue});
				case 5:
					var operatorSymbol = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly('(' + (operatorSymbol + ')'));
				case 6:
					var operatorSymbol = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly(operatorSymbol);
				case 7:
					var _int = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$intLiteral(_int));
				case 8:
					var _int = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$hexLiteral(_int));
				case 9:
					var _float = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$floatLiteral(_float));
				case 10:
					var negated = syntaxExpression.a;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparated, syntaxComments, negated),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyMinus);
				case 11:
					var string = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$stringLiteral(
						A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, string));
				case 12:
					var _char = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$charLiteral(_char));
				case 13:
					var parts = syntaxExpression.a;
					if (!parts.b) {
						return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
					} else {
						if (!parts.b.b) {
							var inParens = parts.a;
							var commentsBeforeInParens = A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
								{
									cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).b9,
									b9: fullRange.b9
								},
								syntaxComments);
							var commentsAfterInParens = A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
								{
									cw: fullRange.cw,
									b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).cw
								},
								syntaxComments);
							var _v34 = _Utils_Tuple2(commentsBeforeInParens, commentsAfterInParens);
							if ((!_v34.a.b) && (!_v34.b.b)) {
								var $temp$syntaxComments = syntaxComments,
									$temp$_v29 = inParens;
								syntaxComments = $temp$syntaxComments;
								_v29 = $temp$_v29;
								continue expressionNotParenthesized;
							} else {
								return A3(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized,
									{
										c: fullRange,
										U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(inParens)
									},
									syntaxComments);
							}
						} else {
							if (!parts.b.b.b) {
								var part0 = parts.a;
								var _v35 = parts.b;
								var part1 = _v35.a;
								return A3(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$tuple,
									{
										R: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(fullRange),
										V: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized
									},
									syntaxComments,
									{c: fullRange, E: part0, F: part1});
							} else {
								if (!parts.b.b.b.b) {
									var part0 = parts.a;
									var _v36 = parts.b;
									var part1 = _v36.a;
									var _v37 = _v36.b;
									var part2 = _v37.a;
									return A3(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$triple,
										{
											R: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(fullRange),
											V: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized
										},
										syntaxComments,
										{c: fullRange, E: part0, F: part1, aa: part2});
								} else {
									var part0 = parts.a;
									var _v38 = parts.b;
									var part1 = _v38.a;
									var _v39 = _v38.b;
									var part2 = _v39.a;
									var _v40 = _v39.b;
									var part3 = _v40.a;
									var part4Up = _v40.b;
									return A3(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$invalidNTuple,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized,
										syntaxComments,
										{c: fullRange, E: part0, F: part1, aa: part2, bC: part3, bD: part4Up});
								}
							}
						}
					}
				case 14:
					var inParens = syntaxExpression.a;
					var commentsBeforeInParens = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{
							cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).b9,
							b9: fullRange.b9
						},
						syntaxComments);
					var commentsAfterInParens = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{
							cw: fullRange.cw,
							b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(inParens).cw
						},
						syntaxComments);
					var _v41 = _Utils_Tuple2(commentsBeforeInParens, commentsAfterInParens);
					if ((!_v41.a.b) && (!_v41.b.b)) {
						var $temp$syntaxComments = syntaxComments,
							$temp$_v29 = inParens;
						syntaxComments = $temp$syntaxComments;
						_v29 = $temp$_v29;
						continue expressionNotParenthesized;
					} else {
						return A3(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized,
							{
								c: fullRange,
								U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(inParens)
							},
							syntaxComments);
					}
				case 15:
					var syntaxLetIn = syntaxExpression.a;
					var _v42 = syntaxLetIn.bl;
					if (!_v42.b) {
						var $temp$syntaxComments = syntaxComments,
							$temp$_v29 = syntaxLetIn.u;
						syntaxComments = $temp$syntaxComments;
						_v29 = $temp$_v29;
						continue expressionNotParenthesized;
					} else {
						var letDeclaration0 = _v42.a;
						var letDeclaration1Up = _v42.b;
						return A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionLetIn,
							syntaxComments,
							{c: fullRange, cO: letDeclaration0, cP: letDeclaration1Up, bJ: syntaxLetIn.u});
					}
				case 16:
					var syntaxCaseOf = syntaxExpression.a;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionCaseOf,
						syntaxComments,
						{be: syntaxCaseOf.be, u: syntaxCaseOf.u, c: fullRange});
				case 17:
					var syntaxLambda = syntaxExpression.a;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionLambda,
						syntaxComments,
						A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, fullRange, syntaxLambda));
				case 18:
					var fields = syntaxExpression.a;
					return A3(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$recordLiteral,
						{b3: '=', b8: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized},
						syntaxComments,
						{ag: fields, c: fullRange});
				case 19:
					var elements = syntaxExpression.a;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionList,
						syntaxComments,
						{bm: elements, c: fullRange});
				case 20:
					var syntaxRecord = syntaxExpression.a;
					var _v43 = syntaxExpression.b;
					var accessedFieldName = _v43.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$exactly('.' + accessedFieldName),
						A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparated, syntaxComments, syntaxRecord));
				case 21:
					var dotFieldName = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$Print$exactly(
						'.' + A3($elm$core$String$replace, '.', '', dotFieldName));
				case 22:
					var recordVariableNode = syntaxExpression.a;
					var fields = syntaxExpression.b;
					return A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionRecordUpdate,
						syntaxComments,
						{ag: fields, c: fullRange, as: recordVariableNode});
				default:
					var glsl = syntaxExpression.a;
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionGlsl(glsl);
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionOperation = F2(
	function (syntaxComments, syntaxOperation) {
		var operationExpanded = A3($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionOperationExpand, syntaxOperation.cN, syntaxOperation.d7, syntaxOperation.c8);
		var leftestPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparatedExceptApplication, syntaxComments, operationExpanded.aL);
		var beforeRightestPrintsAndComments = A3(
			$elm$core$List$foldl,
			F2(
				function (operatorAndExpressionBeforeRightest, soFar) {
					var expressionRange = $stil4m$elm_syntax$Elm$Syntax$Node$range(operatorAndExpressionBeforeRightest.u);
					var commentsBefore = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{cw: expressionRange.b9, b9: soFar.cw},
						syntaxComments);
					return {
						cw: expressionRange.cw,
						d: A2(
							$elm$core$List$cons,
							{
								u: operatorAndExpressionBeforeRightest.u,
								aM: function () {
									if (!commentsBefore.b) {
										return $elm$core$Maybe$Nothing;
									} else {
										var comment0 = commentsBefore.a;
										var comment1Up = commentsBefore.b;
										return $elm$core$Maybe$Just(
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
												A2($elm$core$List$cons, comment0, comment1Up)));
									}
								}(),
								d7: operatorAndExpressionBeforeRightest.d7
							},
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(operationExpanded.aL).cw,
				d: _List_Nil
			},
			operationExpanded.af);
		var commentsBeforeRightestExpression = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(operationExpanded.X).b9,
				b9: beforeRightestPrintsAndComments.cw
			},
			syntaxComments);
		var commentsCollapsibleBeforeRightestExpression = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(commentsBeforeRightestExpression);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWithStrict,
			commentsCollapsibleBeforeRightestExpression.e,
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v27) {
					return A2(
						$lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine,
						function (c) {
							return A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$maybeLineSpread,
								function ($) {
									return $.e;
								},
								c.aM);
						},
						beforeRightestPrintsAndComments.d);
				},
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxOperation.c)));
		var beforeRightestOperatorExpressionChainWithPreviousLineSpread = A3(
			$elm$core$List$foldr,
			F2(
				function (operatorExpression, soFar) {
					var expressionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparatedExceptApplication, syntaxComments, operatorExpression.u);
					return {
						aP: $lue_bird$elm_syntax_format$Print$lineSpread(expressionPrint),
						bK: A2(
							$elm$core$List$cons,
							{u: operatorExpression.u, ay: expressionPrint, aM: operatorExpression.aM, d7: operatorExpression.d7, aP: soFar.aP},
							soFar.bK)
					};
				}),
			{
				aP: $lue_bird$elm_syntax_format$Print$lineSpread(leftestPrint),
				bK: _List_Nil
			},
			beforeRightestPrintsAndComments.d);
		var rightestOperatorExpressionPrint = function () {
			var _v22 = operationExpanded.aj;
			if (_v22 === '<|') {
				var expressionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparatedExceptApplicationAndLambda, syntaxComments, operationExpanded.X);
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!commentsBeforeRightestExpression.b) {
									return expressionPrint;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										expressionPrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v24) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(expressionPrint);
													},
													commentsCollapsibleBeforeRightestExpression.e)),
											commentsCollapsibleBeforeRightestExpression.h));
								}
							}(),
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyLessThanVerticalBar,
						$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(beforeRightestOperatorExpressionChainWithPreviousLineSpread.aP)));
			} else {
				var nonApLOperator = _v22;
				var expressionPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparatedExceptApplication, syntaxComments, operationExpanded.X);
				return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A2(
							$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
							$elm$core$String$length(nonApLOperator) + 1,
							function () {
								if (!commentsBeforeRightestExpression.b) {
									return expressionPrint;
								} else {
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										expressionPrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
												A2(
													$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
													function (_v26) {
														return $lue_bird$elm_syntax_format$Print$lineSpread(expressionPrint);
													},
													commentsCollapsibleBeforeRightestExpression.e)),
											commentsCollapsibleBeforeRightestExpression.h));
								}
							}()),
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$exactly(nonApLOperator + ' '),
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))));
			}
		}();
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A3(
				$elm$core$List$foldl,
				F2(
					function (operatorExpression, chainRightPrint) {
						var _v17 = operatorExpression.d7;
						if (_v17 === '<|') {
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										chainRightPrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											function () {
												var _v18 = operatorExpression.aM;
												if (_v18.$ === 1) {
													return operatorExpression.ay;
												} else {
													var commentsBeforeExpression = _v18.a;
													return A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														operatorExpression.ay,
														A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																A2(
																	$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
																	function (_v19) {
																		return $lue_bird$elm_syntax_format$Print$lineSpread(operatorExpression.ay);
																	},
																	commentsBeforeExpression.e)),
															commentsBeforeExpression.h));
												}
											}(),
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread)))),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyLessThanVerticalBar,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(operatorExpression.aP)));
						} else {
							var nonApLOperator = _v17;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								chainRightPrint,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										A2(
											$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
											$elm$core$String$length(nonApLOperator) + 1,
											function () {
												var _v20 = operatorExpression.aM;
												if (_v20.$ === 1) {
													return operatorExpression.ay;
												} else {
													var commentsBeforeExpression = _v20.a;
													return A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														operatorExpression.ay,
														A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
																A2(
																	$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
																	function (_v21) {
																		return $lue_bird$elm_syntax_format$Print$lineSpread(operatorExpression.ay);
																	},
																	commentsBeforeExpression.e)),
															commentsBeforeExpression.h));
												}
											}()),
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$exactly(nonApLOperator + ' '),
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread)))));
						}
					}),
				rightestOperatorExpressionPrint,
				beforeRightestOperatorExpressionChainWithPreviousLineSpread.bK),
			leftestPrint);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesized = F2(
	function (syntaxComments, expressionNode) {
		return A3(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$parenthesized,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized,
			{
				c: $stil4m$elm_syntax$Elm$Syntax$Node$range(expressionNode),
				U: $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(expressionNode)
			},
			syntaxComments);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparated = F2(
	function (syntaxComments, expressionNode) {
		return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIsSpaceSeparated(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(expressionNode)) ? A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesized, syntaxComments, expressionNode) : A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, expressionNode);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparatedExceptApplication = F2(
	function (syntaxComments, expressionNode) {
		return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIsSpaceSeparatedExceptApplication(expressionNode) ? A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesized, syntaxComments, expressionNode) : A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, expressionNode);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesizedIfSpaceSeparatedExceptApplicationAndLambda = F2(
	function (syntaxComments, expressionNode) {
		if ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionIsSpaceSeparated(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(expressionNode))) {
			var _v16 = $stil4m$elm_syntax$Elm$Syntax$Node$value(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionToNotParenthesized(expressionNode));
			switch (_v16.$) {
				case 1:
					return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, expressionNode);
				case 17:
					return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, expressionNode);
				default:
					return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionParenthesized, syntaxComments, expressionNode);
			}
		} else {
			return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, expressionNode);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionRecordUpdate = F2(
	function (syntaxComments, syntaxRecordUpdate) {
		var recordVariablePrint = $lue_bird$elm_syntax_format$Print$exactly(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxRecordUpdate.as));
		var maybeCommentsBeforeRecordVariable = function () {
			var _v15 = A2(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
				{
					cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxRecordUpdate.as).b9,
					b9: syntaxRecordUpdate.c.b9
				},
				syntaxComments);
			if (!_v15.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var comment0 = _v15.a;
				var comment1Up = _v15.b;
				return $elm$core$Maybe$Just(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
						A2($elm$core$List$cons, comment0, comment1Up)));
			}
		}();
		var fieldPrintsWithCommentsBefore = A3(
			$elm$core$List$foldl,
			F2(
				function (_v6, soFar) {
					var fieldSyntax = _v6.b;
					var _v7 = fieldSyntax;
					var _v8 = _v7.a;
					var fieldNameRange = _v8.a;
					var fieldName = _v8.b;
					var fieldValueNode = _v7.b;
					var _v9 = fieldValueNode;
					var fieldValueRange = _v9.a;
					var valuePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, syntaxComments, fieldValueNode);
					return {
						cw: fieldValueRange.cw,
						d: A2(
							$elm$core$List$cons,
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										valuePrint,
										function () {
											var _v11 = A2(
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
												{cw: fieldValueRange.b9, b9: fieldNameRange.b9},
												syntaxComments);
											if (!_v11.b) {
												return $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
													A2(
														$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
														function (_v12) {
															return $lue_bird$elm_syntax_format$Print$lineSpread(valuePrint);
														},
														A2(
															$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadBetweenRanges,
															fieldNameRange,
															$stil4m$elm_syntax$Elm$Syntax$Node$range(fieldValueNode))));
											} else {
												var comment0 = _v11.a;
												var comment1Up = _v11.b;
												var commentsBeforeValue = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
													A2($elm$core$List$cons, comment0, comment1Up));
												var layout = $lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(
													A2(
														$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
														function (_v14) {
															return $lue_bird$elm_syntax_format$Print$lineSpread(valuePrint);
														},
														A2(
															$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
															function (_v13) {
																return A2(
																	$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadBetweenRanges,
																	fieldNameRange,
																	$stil4m$elm_syntax$Elm$Syntax$Node$range(fieldValueNode));
															},
															commentsBeforeValue.e)));
												return A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													layout,
													A2($lue_bird$elm_syntax_format$Print$followedBy, commentsBeforeValue.h, layout));
											}
										}())),
								A2(
									$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
									2,
									function () {
										var _v10 = A2(
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
											{cw: fieldNameRange.b9, b9: soFar.cw},
											syntaxComments);
										if (!_v10.b) {
											return $lue_bird$elm_syntax_format$Print$exactly(fieldName + ' =');
										} else {
											var comment0 = _v10.a;
											var comment1Up = _v10.b;
											var commentsBeforeName = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
												A2($elm$core$List$cons, comment0, comment1Up));
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$exactly(fieldName + ' ='),
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsBeforeName.e),
													commentsBeforeName.h));
										}
									}())),
							soFar.d)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxRecordUpdate.as).cw,
				d: _List_Nil
			},
			syntaxRecordUpdate.ag);
		var commentsAfterFields = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
			{cw: syntaxRecordUpdate.c.cw, b9: fieldPrintsWithCommentsBefore.cw},
			syntaxComments);
		var lineSpread = A2(
			$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
			function (_v5) {
				return A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, fieldPrintsWithCommentsBefore.d);
			},
			A2(
				$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
				function (_v3) {
					if (!commentsAfterFields.b) {
						return 0;
					} else {
						return 1;
					}
				},
				A2(
					$lue_bird$elm_syntax_format$Print$lineSpreadMergeWith,
					function (_v2) {
						return A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$maybeLineSpread,
							function ($) {
								return $.e;
							},
							maybeCommentsBeforeRecordVariable);
					},
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxRecordUpdate.c))));
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyClosing,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								if (!commentsAfterFields.b) {
									return $lue_bird$elm_syntax_format$Print$empty;
								} else {
									var comment0 = commentsAfterFields.a;
									var comment1Up = commentsAfterFields.b;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread),
											$lue_bird$elm_syntax_format$Print$linebreak));
								}
							}(),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								A2(
									$lue_bird$elm_syntax_format$Print$listReverseAndIntersperseAndFlatten,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
										$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
									fieldPrintsWithCommentsBefore.d),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyVerticalBarSpace,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))))),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						A2(
							$lue_bird$elm_syntax_format$Print$withIndentIncreasedBy,
							2,
							function () {
								if (maybeCommentsBeforeRecordVariable.$ === 1) {
									return recordVariablePrint;
								} else {
									var commentsCollapsibleBeforeRecordVariable = maybeCommentsBeforeRecordVariable.a;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										recordVariablePrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsCollapsibleBeforeRecordVariable.e),
											commentsCollapsibleBeforeRecordVariable.h));
								}
							}()),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCurlyOpeningSpace))));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationDestructuring = F3(
	function (syntaxComments, destructuringPattern, destructuringExpression) {
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expressionNotParenthesized, _List_Nil, destructuringExpression),
					$lue_bird$elm_syntax_format$Print$linebreakIndented)),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$exactly(' ='),
				A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$patternParenthesizedIfSpaceSeparated, syntaxComments, destructuringPattern)));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationExpression = F2(
	function (syntaxComments, syntaxExpressionDeclaration) {
		var implementationPrint = A2(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationExpressionImplementation,
			syntaxComments,
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxExpressionDeclaration.G));
		var withoutDocumentationPrint = function () {
			var _v4 = syntaxExpressionDeclaration.K;
			if (_v4.$ === 1) {
				return implementationPrint;
			} else {
				var _v5 = _v4.a;
				var signatureRange = _v5.a;
				var signature = _v5.b;
				var commentsBetweenSignatureAndImplementationName = A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
					{
						cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxExpressionDeclaration.G).b9,
						b9: signatureRange.cw
					},
					syntaxComments);
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentsBetweenSignatureAndImplementationName.b) {
							return implementationPrint;
						} else {
							var comment0 = commentsBetweenSignatureAndImplementationName.a;
							var comment1Up = commentsBetweenSignatureAndImplementationName.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								implementationPrint,
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments(
											A2($elm$core$List$cons, comment0, comment1Up)),
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak)));
						}
					}(),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$linebreak,
						A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationSignature, syntaxComments, signature)));
			}
		}();
		var _v0 = syntaxExpressionDeclaration.Q;
		if (_v0.$ === 1) {
			return withoutDocumentationPrint;
		} else {
			var _v1 = _v0.a;
			var documentationRange = _v1.a;
			var documentation = _v1.b;
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				withoutDocumentationPrint,
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsBetweenDocumentationAndDeclaration(
						A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
							{
								cw: function () {
									var _v2 = syntaxExpressionDeclaration.K;
									if (_v2.$ === 1) {
										return $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxExpressionDeclaration.G).b9;
									} else {
										var _v3 = _v2.a;
										var signatureRange = _v3.a;
										return signatureRange.b9;
									}
								}(),
								b9: documentationRange.b9
							},
							syntaxComments)),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$linebreak,
						$lue_bird$elm_syntax_format$Print$exactly(documentation))));
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$infixDirection = function (syntaxInfixDirection) {
	switch (syntaxInfixDirection) {
		case 0:
			return 'left ';
		case 1:
			return 'right';
		default:
			return 'non  ';
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationInfix = function (syntaxInfixDeclaration) {
	return $lue_bird$elm_syntax_format$Print$exactly(
		'infix ' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$infixDirection(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxInfixDeclaration.aw)) + (' ' + ($elm$core$String$fromInt(
			$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxInfixDeclaration.d9)) + (' (' + ($stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxInfixDeclaration.d7) + (') = ' + $stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxInfixDeclaration.dL))))))));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyPortSpace = $lue_bird$elm_syntax_format$Print$exactly('port ');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationPort = F2(
	function (syntaxComments, signature) {
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationSignature, syntaxComments.b, signature),
			function () {
				var _v0 = syntaxComments.bX;
				if (_v0.$ === 1) {
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyPortSpace;
				} else {
					var _v1 = _v0.a;
					var documentationRange = _v1.a;
					var documentation = _v1.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyPortSpace,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsBetweenDocumentationAndDeclaration(
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(signature.aN).b9,
										b9: documentationRange.b9
									},
									syntaxComments.b)),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$linebreak,
								$lue_bird$elm_syntax_format$Print$exactly(documentation))));
				}
			}());
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listFilledLast = F2(
	function (head, tail) {
		listFilledLast:
		while (true) {
			if (!tail.b) {
				return head;
			} else {
				var tailHead = tail.a;
				var tailTail = tail.b;
				var $temp$head = tailHead,
					$temp$tail = tailTail;
				head = $temp$head;
				tail = $temp$tail;
				continue listFilledLast;
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyTypeSpaceAlias = $lue_bird$elm_syntax_format$Print$exactly('type alias');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationTypeAlias = F2(
	function (syntaxComments, syntaxTypeAliasDeclaration) {
		var rangeBetweenParametersAndType = function () {
			var _v4 = syntaxTypeAliasDeclaration.bs;
			if (!_v4.b) {
				return {
					cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTypeAliasDeclaration.o).b9,
					b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTypeAliasDeclaration.aN).cw
				};
			} else {
				var parameter0 = _v4.a;
				var parameter1Up = _v4.b;
				return {
					cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTypeAliasDeclaration.o).b9,
					b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(
						A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listFilledLast, parameter0, parameter1Up)).cw
				};
			}
		}();
		var parameterPrintsWithCommentsBeforeReverse = A3(
			$elm$core$List$foldl,
			F2(
				function (parameterName, soFar) {
					var parameterPrintedRange = $stil4m$elm_syntax$Elm$Syntax$Node$range(parameterName);
					var parameterNamePrint = $lue_bird$elm_syntax_format$Print$exactly(
						$stil4m$elm_syntax$Elm$Syntax$Node$value(parameterName));
					return {
						cw: parameterPrintedRange.cw,
						ar: A2(
							$elm$core$List$cons,
							function () {
								var _v3 = A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{cw: parameterPrintedRange.b9, b9: soFar.cw},
									syntaxComments);
								if (!_v3.b) {
									return parameterNamePrint;
								} else {
									var comment0 = _v3.a;
									var comment1Up = _v3.b;
									var commentsCollapsible = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$collapsibleComments(
										A2($elm$core$List$cons, comment0, comment1Up));
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										parameterNamePrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(commentsCollapsible.e),
											commentsCollapsible.h));
								}
							}(),
							soFar.ar)
					};
				}),
			{
				cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTypeAliasDeclaration.aN).cw,
				ar: _List_Nil
			},
			syntaxTypeAliasDeclaration.bs).ar;
		var parametersLineSpread = A2($lue_bird$elm_syntax_format$Print$lineSpreadListMapAndCombine, $lue_bird$elm_syntax_format$Print$lineSpread, parameterPrintsWithCommentsBeforeReverse);
		var aliasedTypePrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$typeNotParenthesized, syntaxComments, syntaxTypeAliasDeclaration.o);
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						function () {
							var _v2 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, rangeBetweenParametersAndType, syntaxComments);
							if (!_v2.b) {
								return aliasedTypePrint;
							} else {
								var comment0 = _v2.a;
								var comment1Up = _v2.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									aliasedTypePrint,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$linebreakIndented,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up))));
							}
						}(),
						$lue_bird$elm_syntax_format$Print$linebreakIndented),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyEquals,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$listReverseAndMapAndFlatten,
										function (parameterPrint) {
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												parameterPrint,
												$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread));
										},
										parameterPrintsWithCommentsBeforeReverse)),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$exactly(
										$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxTypeAliasDeclaration.aN)),
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(parametersLineSpread))))))),
			function () {
				var _v0 = syntaxTypeAliasDeclaration.Q;
				if (_v0.$ === 1) {
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyTypeSpaceAlias;
				} else {
					var _v1 = _v0.a;
					var documentationRange = _v1.a;
					var documentation = _v1.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyTypeSpaceAlias,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsBetweenDocumentationAndDeclaration(
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{
										cw: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxTypeAliasDeclaration.aN).b9,
										b9: documentationRange.b9
									},
									syntaxComments)),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$linebreak,
								$lue_bird$elm_syntax_format$Print$exactly(documentation))));
				}
			}());
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declaration = F2(
	function (syntaxComments, syntaxDeclaration) {
		switch (syntaxDeclaration.$) {
			case 0:
				var syntaxExpressionDeclaration = syntaxDeclaration.a;
				return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationExpression, syntaxComments.b, syntaxExpressionDeclaration);
			case 1:
				var syntaxTypeAliasDeclaration = syntaxDeclaration.a;
				return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationTypeAlias, syntaxComments.b, syntaxTypeAliasDeclaration);
			case 2:
				var syntaxChoiceTypeDeclaration = syntaxDeclaration.a;
				return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationChoiceType, syntaxComments.b, syntaxChoiceTypeDeclaration);
			case 3:
				var signature = syntaxDeclaration.a;
				return A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationPort,
					{b: syntaxComments.b, bX: syntaxComments.a2},
					signature);
			case 4:
				var syntaxInfixDeclaration = syntaxDeclaration.a;
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationInfix(syntaxInfixDeclaration);
			default:
				var destructuringPattern = syntaxDeclaration.a;
				var destructuringExpression = syntaxDeclaration.b;
				return A3($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationDestructuring, syntaxComments.b, destructuringPattern, destructuringExpression);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$firstCommentInRange = F2(
	function (range, sortedComments) {
		firstCommentInRange:
		while (true) {
			if (!sortedComments.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var _v1 = sortedComments.a;
				var headCommentRange = _v1.a;
				var headComment = _v1.b;
				var tailComments = sortedComments.b;
				var _v2 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.b9, range.b9);
				switch (_v2) {
					case 0:
						var $temp$range = range,
							$temp$sortedComments = tailComments;
						range = $temp$range;
						sortedComments = $temp$sortedComments;
						continue firstCommentInRange;
					case 1:
						return $elm$core$Maybe$Just(
							A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, headCommentRange, headComment));
					default:
						var _v3 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$locationCompareFast, headCommentRange.cw, range.cw);
						switch (_v3) {
							case 2:
								return $elm$core$Maybe$Nothing;
							case 0:
								return $elm$core$Maybe$Just(
									A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, headCommentRange, headComment));
							default:
								return $elm$core$Maybe$Just(
									A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, headCommentRange, headComment));
						}
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$linebreaksFollowedByDeclaration = F2(
	function (syntaxComments, syntaxDeclaration) {
		switch (syntaxDeclaration.$) {
			case 0:
				var syntaxExpressionDeclaration = syntaxDeclaration.a;
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationExpression, syntaxComments.b, syntaxExpressionDeclaration),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak);
			case 1:
				var syntaxTypeAliasDeclaration = syntaxDeclaration.a;
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationTypeAlias, syntaxComments.b, syntaxTypeAliasDeclaration),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak);
			case 2:
				var syntaxChoiceTypeDeclaration = syntaxDeclaration.a;
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationChoiceType, syntaxComments.b, syntaxChoiceTypeDeclaration),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak);
			case 3:
				var signature = syntaxDeclaration.a;
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationPort,
						{b: syntaxComments.b, bX: syntaxComments.a2},
						signature),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak);
			case 4:
				var syntaxInfixDeclaration = syntaxDeclaration.a;
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationInfix(syntaxInfixDeclaration),
					$lue_bird$elm_syntax_format$Print$linebreak);
			default:
				var destructuringPattern = syntaxDeclaration.a;
				var destructuringExpression = syntaxDeclaration.b;
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A3($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarationDestructuring, syntaxComments.b, destructuringPattern, destructuringExpression),
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelCommentsBeforeDeclaration = function (syntaxComments) {
	return A2(
		$lue_bird$elm_syntax_format$Print$followedBy,
		function () {
			var _v0 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listFilledLast, syntaxComments.bf, syntaxComments.bg);
			if (_v0 === '{--}') {
				return $lue_bird$elm_syntax_format$Print$empty;
			} else {
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak;
			}
		}(),
		A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments(
				A2($elm$core$List$cons, syntaxComments.bf, syntaxComments.bg)),
			$lue_bird$elm_syntax_format$Print$linebreak));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarations = F2(
	function (context, syntaxDeclarations) {
		if (!syntaxDeclarations.b) {
			return $lue_bird$elm_syntax_format$Print$empty;
		} else {
			var _v1 = syntaxDeclarations.a;
			var declaration0Range = _v1.a;
			var declaration0 = _v1.b;
			var declarations1Up = syntaxDeclarations.b;
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				A3(
					$elm$core$List$foldl,
					F2(
						function (_v3, soFar) {
							var declarationRange = _v3.a;
							var syntaxDeclaration = _v3.b;
							var maybeDeclarationPortDocumentationComment = function () {
								switch (syntaxDeclaration.$) {
									case 3:
										return A2(
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$firstCommentInRange,
											{cw: declarationRange.b9, b9: soFar.bE.cw},
											context.ah);
									case 0:
										return $elm$core$Maybe$Nothing;
									case 1:
										return $elm$core$Maybe$Nothing;
									case 2:
										return $elm$core$Maybe$Nothing;
									case 4:
										return $elm$core$Maybe$Nothing;
									default:
										return $elm$core$Maybe$Nothing;
								}
							}();
							return {
								bE: declarationRange,
								h: A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									function () {
										var _v4 = A2(
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
											{cw: declarationRange.b9, b9: soFar.bE.cw},
											context.b);
										if (_v4.b) {
											var comment0 = _v4.a;
											var comment1Up = _v4.b;
											return A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												A2(
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declaration,
													{
														b: A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentNodesInRange, declarationRange, context.b),
														a2: maybeDeclarationPortDocumentationComment
													},
													syntaxDeclaration),
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelCommentsBeforeDeclaration(
														{bf: comment0, bg: comment1Up}),
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak));
										} else {
											return A2(
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$linebreaksFollowedByDeclaration,
												{
													b: A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentNodesInRange, declarationRange, context.b),
													a2: maybeDeclarationPortDocumentationComment
												},
												syntaxDeclaration);
										}
									}(),
									soFar.h)
							};
						}),
					{bE: declaration0Range, h: $lue_bird$elm_syntax_format$Print$empty},
					declarations1Up).h,
				A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declaration,
					{
						b: context.b,
						a2: function () {
							switch (declaration0.$) {
								case 3:
									return A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$firstCommentInRange,
										{cw: declaration0Range.b9, b9: context.aq},
										context.ah);
								case 0:
									return $elm$core$Maybe$Nothing;
								case 1:
									return $elm$core$Maybe$Nothing;
								case 2:
									return $elm$core$Maybe$Nothing;
								case 4:
									return $elm$core$Maybe$Nothing;
								default:
									return $elm$core$Maybe$Nothing;
							}
						}()
					},
					declaration0));
		}
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
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expose = function (syntaxExpose) {
	switch (syntaxExpose.$) {
		case 0:
			var operatorSymbol = syntaxExpose.a;
			return '(' + (operatorSymbol + ')');
		case 1:
			var name = syntaxExpose.a;
			return name;
		case 2:
			var name = syntaxExpose.a;
			return name;
		default:
			var syntaxExposeType = syntaxExpose.a;
			var _v1 = syntaxExposeType.d6;
			if (_v1.$ === 1) {
				return syntaxExposeType.aN;
			} else {
				return syntaxExposeType.aN + '(..)';
			}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingMulti = F2(
	function (syntaxComments, syntaxExposing) {
		var containedComments = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, syntaxExposing.c, syntaxComments);
		var lineSpread = function () {
			if (containedComments.b) {
				return 1;
			} else {
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(syntaxExposing.c);
			}
		}();
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			function () {
				if (!containedComments.b) {
					return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing;
				} else {
					var comment0 = containedComments.a;
					var comment1Up = containedComments.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
								A2($elm$core$List$cons, comment0, comment1Up))));
				}
			}(),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					A3(
						$lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten,
						function (_v1) {
							var syntaxExpose = _v1.b;
							return $lue_bird$elm_syntax_format$Print$exactly(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expose(syntaxExpose));
						},
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace,
							$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread)),
						A2($elm$core$List$cons, syntaxExposing.bp, syntaxExposing.bq)),
					function () {
						if (!lineSpread) {
							return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpening;
						} else {
							return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningSpace;
						}
					}())));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningDotDotParensClosing = $lue_bird$elm_syntax_format$Print$exactly('(..)');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importExposing = F2(
	function (syntaxComments, _v0) {
		var exposingRange = _v0.a;
		var syntaxExposing = _v0.b;
		if (!syntaxExposing.$) {
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningDotDotParensClosing;
		} else {
			var exposingSet = syntaxExposing.a;
			if (!exposingSet.b) {
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
			} else {
				var expose0 = exposingSet.a;
				var expose1Up = exposingSet.b;
				return A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingMulti,
					syntaxComments,
					{bp: expose0, bq: expose1Up, c: exposingRange});
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName = function (syntaxModuleName) {
	return A2($elm$core$String$join, '.', syntaxModuleName);
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactImport = $lue_bird$elm_syntax_format$Print$exactly('import');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyExposing = $lue_bird$elm_syntax_format$Print$exactly('exposing');
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedAs = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyAs, $lue_bird$elm_syntax_format$Print$linebreakIndented);
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedExposing = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyExposing, $lue_bird$elm_syntax_format$Print$linebreakIndented);
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$import_ = F2(
	function (syntaxComments, _v0) {
		var incorrectImportRange = _v0.a;
		var syntaxImport = _v0.b;
		var importRange = function () {
			var _v12 = syntaxImport.ax;
			if (_v12.$ === 1) {
				return incorrectImportRange;
			} else {
				var _v13 = _v12.a;
				var syntaxExposingRange = _v13.a;
				return {cw: syntaxExposingRange.cw, b9: incorrectImportRange.b9};
			}
		}();
		var _v1 = syntaxImport.T;
		var moduleNameRange = _v1.a;
		var syntaxModuleName = _v1.b;
		return A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			function () {
				var _v8 = syntaxImport.ax;
				if (_v8.$ === 1) {
					return $lue_bird$elm_syntax_format$Print$empty;
				} else {
					var syntaxExposing = _v8.a;
					var exposingPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importExposing, syntaxComments, syntaxExposing);
					var exposingPartStart = function () {
						var _v10 = syntaxImport.bz;
						if (_v10.$ === 1) {
							return moduleNameRange.cw;
						} else {
							var _v11 = _v10.a;
							var moduleAliasRange = _v11.a;
							return moduleAliasRange.cw;
						}
					}();
					var _v9 = A2(
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
						{cw: importRange.cw, b9: exposingPartStart},
						syntaxComments);
					if (!_v9.b) {
						var lineSpread = $lue_bird$elm_syntax_format$Print$lineSpread(exposingPrint);
						return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										exposingPrint,
										$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyExposing,
									$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))));
					} else {
						var exposingComment0 = _v9.a;
						var exposingComment1Up = _v9.b;
						return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										exposingPrint,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$linebreakIndented,
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
													A2($elm$core$List$cons, exposingComment0, exposingComment1Up)),
												$lue_bird$elm_syntax_format$Print$linebreakIndented)))),
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedExposing));
					}
				}
			}(),
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				function () {
					var _v2 = syntaxImport.bz;
					if (_v2.$ === 1) {
						var _v3 = A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
							{cw: moduleNameRange.b9, b9: importRange.b9},
							syntaxComments);
						if (!_v3.b) {
							return $lue_bird$elm_syntax_format$Print$exactly(
								' ' + $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(syntaxModuleName));
						} else {
							var comment0 = _v3.a;
							var comment1Up = _v3.b;
							return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$exactly(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(syntaxModuleName)),
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$linebreakIndented,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
												A2($elm$core$List$cons, comment0, comment1Up)),
											$lue_bird$elm_syntax_format$Print$linebreakIndented))));
						}
					} else {
						var _v4 = _v2.a;
						var moduleAliasRange = _v4.a;
						var moduleAlias = _v4.b;
						var _v5 = A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
							{cw: moduleAliasRange.b9, b9: moduleNameRange.cw},
							syntaxComments);
						if (!_v5.b) {
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								$lue_bird$elm_syntax_format$Print$exactly(
									' as ' + $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(moduleAlias)),
								function () {
									var _v6 = A2(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
										{cw: moduleNameRange.b9, b9: importRange.b9},
										syntaxComments);
									if (!_v6.b) {
										return $lue_bird$elm_syntax_format$Print$exactly(
											' ' + $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(syntaxModuleName));
									} else {
										var moduleNameComment0 = _v6.a;
										var moduleNameComment1Up = _v6.b;
										return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$exactly(
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(syntaxModuleName)),
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$linebreakIndented,
													A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
															A2($elm$core$List$cons, moduleNameComment0, moduleNameComment1Up)),
														$lue_bird$elm_syntax_format$Print$linebreakIndented))));
									}
								}());
						} else {
							var aliasComment0 = _v5.a;
							var aliasComment1Up = _v5.b;
							return $lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
												A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$exactly(
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(moduleAlias)),
													A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														$lue_bird$elm_syntax_format$Print$linebreakIndented,
														A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
																A2($elm$core$List$cons, aliasComment0, aliasComment1Up)),
															$lue_bird$elm_syntax_format$Print$linebreakIndented)))),
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedAs)),
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										function () {
											var _v7 = A2(
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
												{cw: moduleNameRange.b9, b9: importRange.b9},
												syntaxComments);
											if (!_v7.b) {
												return $lue_bird$elm_syntax_format$Print$exactly(
													$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(syntaxModuleName));
											} else {
												var moduleNameComment0 = _v7.a;
												var moduleNameComment1Up = _v7.b;
												return A2(
													$lue_bird$elm_syntax_format$Print$followedBy,
													$lue_bird$elm_syntax_format$Print$exactly(
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(syntaxModuleName)),
													A2(
														$lue_bird$elm_syntax_format$Print$followedBy,
														$lue_bird$elm_syntax_format$Print$linebreakIndented,
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
															A2($elm$core$List$cons, moduleNameComment0, moduleNameComment1Up))));
											}
										}(),
										$lue_bird$elm_syntax_format$Print$linebreakIndented)));
						}
					}
				}(),
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactImport));
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeCompare = F2(
	function (a, b) {
		switch (a.$) {
			case 0:
				var aOperatorSymbol = a.a;
				switch (b.$) {
					case 0:
						var bOperatorSymbol = b.a;
						return A2($elm$core$Basics$compare, aOperatorSymbol, bOperatorSymbol);
					case 1:
						return 0;
					case 2:
						return 0;
					default:
						return 0;
				}
			case 1:
				var aName = a.a;
				switch (b.$) {
					case 0:
						return 2;
					case 1:
						var bName = b.a;
						return A2($elm$core$Basics$compare, aName, bName);
					case 2:
						return 2;
					default:
						return 2;
				}
			case 2:
				var aName = a.a;
				switch (b.$) {
					case 0:
						return 2;
					case 1:
						return 0;
					case 2:
						var bName = b.a;
						return A2($elm$core$Basics$compare, aName, bName);
					default:
						var bTypeExpose = b.a;
						return A2($elm$core$Basics$compare, aName, bTypeExpose.aN);
				}
			default:
				var aTypeExpose = a.a;
				switch (b.$) {
					case 0:
						return 2;
					case 1:
						return 0;
					case 2:
						var bName = b.a;
						return A2($elm$core$Basics$compare, aTypeExpose.aN, bName);
					default:
						var bTypeExpose = b.a;
						return A2($elm$core$Basics$compare, aTypeExpose.aN, bTypeExpose.aN);
				}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeMerge = F2(
	function (a, b) {
		switch (a.$) {
			case 3:
				var aTypeExpose = a.a;
				switch (b.$) {
					case 3:
						var bTypeExpose = b.a;
						return $stil4m$elm_syntax$Elm$Syntax$Exposing$TypeExpose(
							{
								aN: aTypeExpose.aN,
								d6: function () {
									var _v2 = aTypeExpose.d6;
									if (!_v2.$) {
										var openRange = _v2.a;
										return $elm$core$Maybe$Just(openRange);
									} else {
										return bTypeExpose.d6;
									}
								}()
							});
					case 0:
						return $stil4m$elm_syntax$Elm$Syntax$Exposing$TypeExpose(aTypeExpose);
					case 1:
						return $stil4m$elm_syntax$Elm$Syntax$Exposing$TypeExpose(aTypeExpose);
					default:
						return $stil4m$elm_syntax$Elm$Syntax$Exposing$TypeExpose(aTypeExpose);
				}
			case 0:
				return b;
			case 1:
				return b;
			default:
				return b;
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposesCombine = function (syntaxExposes) {
	exposesCombine:
	while (true) {
		if (!syntaxExposes.b) {
			return _List_Nil;
		} else {
			if (!syntaxExposes.b.b) {
				var onlyExposeList = syntaxExposes;
				return onlyExposeList;
			} else {
				var expose0Node = syntaxExposes.a;
				var expose1Up = syntaxExposes.b;
				var _v1 = expose1Up.a;
				var expose1 = _v1.b;
				var expose2Up = expose1Up.b;
				var _v2 = expose0Node;
				var expose0Range = _v2.a;
				var expose0 = _v2.b;
				var _v3 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeCompare, expose0, expose1);
				switch (_v3) {
					case 1:
						var $temp$syntaxExposes = A2(
							$elm$core$List$cons,
							A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								expose0Range,
								A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeMerge, expose0, expose1)),
							expose2Up);
						syntaxExposes = $temp$syntaxExposes;
						continue exposesCombine;
					case 0:
						return A2(
							$elm$core$List$cons,
							expose0Node,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposesCombine(expose1Up));
					default:
						return A2(
							$elm$core$List$cons,
							expose0Node,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposesCombine(expose1Up));
				}
			}
		}
	}
};
var $elm$core$List$sortWith = _List_sortWith;
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeListToNormal = function (syntaxExposeList) {
	return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposesCombine(
		A2(
			$elm$core$List$sortWith,
			F2(
				function (_v0, _v1) {
					var a = _v0.b;
					var b = _v1.b;
					return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeCompare, a, b);
				}),
			syntaxExposeList));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingToNormal = function (syntaxExposing) {
	if (!syntaxExposing.$) {
		var allRange = syntaxExposing.a;
		return $stil4m$elm_syntax$Elm$Syntax$Exposing$All(allRange);
	} else {
		var exposeSet = syntaxExposing.a;
		return $stil4m$elm_syntax$Elm$Syntax$Exposing$Explicit(
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeListToNormal(exposeSet));
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importToNormal = function (syntaxImport) {
	return {
		ax: function () {
			var _v0 = syntaxImport.ax;
			if (_v0.$ === 1) {
				return $elm$core$Maybe$Nothing;
			} else {
				var _v1 = _v0.a;
				var exposingRange = _v1.a;
				var syntaxExposing = _v1.b;
				return $elm$core$Maybe$Just(
					A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						exposingRange,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingToNormal(syntaxExposing)));
			}
		}(),
		bz: syntaxImport.bz,
		T: syntaxImport.T
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingCombine = F2(
	function (a, b) {
		if (!a.$) {
			if (!a.a.b.$) {
				var _v1 = a.a;
				var exposingAllRange = _v1.a;
				var allRange = _v1.b.a;
				return $elm$core$Maybe$Just(
					A2(
						$stil4m$elm_syntax$Elm$Syntax$Node$Node,
						exposingAllRange,
						$stil4m$elm_syntax$Elm$Syntax$Exposing$All(allRange)));
			} else {
				var _v2 = a.a;
				var earlierExposingExplicitRange = _v2.a;
				var earlierExposeSet = _v2.b.a;
				return $elm$core$Maybe$Just(
					function () {
						if (!b.$) {
							if (!b.a.b.$) {
								var _v4 = b.a;
								var exposingAllRange = _v4.a;
								var allRange = _v4.b.a;
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									exposingAllRange,
									$stil4m$elm_syntax$Elm$Syntax$Exposing$All(allRange));
							} else {
								var _v5 = b.a;
								var laterExposingExplicitRange = _v5.a;
								var laterExposeSet = _v5.b.a;
								return A2(
									$stil4m$elm_syntax$Elm$Syntax$Node$Node,
									function () {
										var _v6 = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$lineSpreadInRange(earlierExposingExplicitRange);
										if (_v6 === 1) {
											return earlierExposingExplicitRange;
										} else {
											return laterExposingExplicitRange;
										}
									}(),
									$stil4m$elm_syntax$Elm$Syntax$Exposing$Explicit(
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeListToNormal(
											_Utils_ap(earlierExposeSet, laterExposeSet))));
							}
						} else {
							return A2(
								$stil4m$elm_syntax$Elm$Syntax$Node$Node,
								earlierExposingExplicitRange,
								$stil4m$elm_syntax$Elm$Syntax$Exposing$Explicit(earlierExposeSet));
						}
					}());
			}
		} else {
			return b;
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importsMerge = F2(
	function (earlier, later) {
		return {
			ax: A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingCombine, earlier.ax, later.ax),
			bz: function () {
				var _v0 = earlier.bz;
				if (!_v0.$) {
					var alias = _v0.a;
					return $elm$core$Maybe$Just(alias);
				} else {
					return later.bz;
				}
			}(),
			T: later.T
		};
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importsCombine = function (syntaxImports) {
	importsCombine:
	while (true) {
		if (!syntaxImports.b) {
			return _List_Nil;
		} else {
			if (!syntaxImports.b.b) {
				var onlyImport = syntaxImports.a;
				return _List_fromArray(
					[
						A2($stil4m$elm_syntax$Elm$Syntax$Node$map, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importToNormal, onlyImport)
					]);
			} else {
				var _v1 = syntaxImports.a;
				var import0Range = _v1.a;
				var import0 = _v1.b;
				var _v2 = syntaxImports.b;
				var _v3 = _v2.a;
				var import1Range = _v3.a;
				var import1 = _v3.b;
				var import2Up = _v2.b;
				if (_Utils_eq(
					$stil4m$elm_syntax$Elm$Syntax$Node$value(import0.T),
					$stil4m$elm_syntax$Elm$Syntax$Node$value(import1.T))) {
					var $temp$syntaxImports = A2(
						$elm$core$List$cons,
						A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							import1Range,
							A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importsMerge, import0, import1)),
						import2Up);
					syntaxImports = $temp$syntaxImports;
					continue importsCombine;
				} else {
					return A2(
						$elm$core$List$cons,
						A2(
							$stil4m$elm_syntax$Elm$Syntax$Node$Node,
							import0Range,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importToNormal(import0)),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importsCombine(
							A2(
								$elm$core$List$cons,
								A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, import1Range, import1),
								import2Up)));
				}
			}
		}
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$imports = F2(
	function (syntaxComments, syntaxImports) {
		if (!syntaxImports.b) {
			return $lue_bird$elm_syntax_format$Print$empty;
		} else {
			var _v1 = syntaxImports.a;
			var import0Range = _v1.a;
			var import0 = _v1.b;
			var imports1Up = syntaxImports.b;
			var commentsBetweenImports = A3(
				$elm$core$List$foldl,
				F2(
					function (_v5, soFar) {
						var importRange = _v5.a;
						return {
							b: _Utils_ap(
								soFar.b,
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
									{cw: importRange.b9, b9: soFar.b7.cw},
									syntaxComments)),
							b7: importRange
						};
					}),
				{b: _List_Nil, b7: import0Range},
				A2(
					$elm$core$List$cons,
					A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, import0Range, import0),
					imports1Up)).b;
			return A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				A3(
					$lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten,
					function (syntaxImport) {
						return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$import_, syntaxComments, syntaxImport);
					},
					$lue_bird$elm_syntax_format$Print$linebreak,
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$importsCombine(
						A2(
							$elm$core$List$sortWith,
							F2(
								function (_v3, _v4) {
									var a = _v3.b;
									var b = _v4.b;
									return A2(
										$elm$core$Basics$compare,
										$stil4m$elm_syntax$Elm$Syntax$Node$value(a.T),
										$stil4m$elm_syntax$Elm$Syntax$Node$value(b.T));
								}),
							A2(
								$elm$core$List$cons,
								A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, import0Range, import0),
								imports1Up)))),
				function () {
					if (!commentsBetweenImports.b) {
						return $lue_bird$elm_syntax_format$Print$empty;
					} else {
						var comment0 = commentsBetweenImports.a;
						var comment1Up = commentsBetweenImports.b;
						return A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$linebreak,
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments(
								A2($elm$core$List$cons, comment0, comment1Up)));
					}
				}());
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleDocumentationBeforeCutOffLine = F2(
	function (cutOffLine, allComments) {
		moduleDocumentationBeforeCutOffLine:
		while (true) {
			if (!allComments.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var headComment = allComments.a;
				var restOfComments = allComments.b;
				var _v1 = headComment;
				var range = _v1.a;
				var content = _v1.b;
				if (_Utils_cmp(range.b9.c9, cutOffLine) > 0) {
					return $elm$core$Maybe$Nothing;
				} else {
					if (A2($elm$core$String$startsWith, '{-|', content)) {
						return $elm$core$Maybe$Just(headComment);
					} else {
						var $temp$cutOffLine = cutOffLine,
							$temp$allComments = restOfComments;
						cutOffLine = $temp$cutOffLine;
						allComments = $temp$allComments;
						continue moduleDocumentationBeforeCutOffLine;
					}
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleDocumentation = function (ast) {
	var cutOffLine = function () {
		var _v0 = ast.dN;
		if (_v0.b) {
			var _v1 = _v0.a;
			var firstImportRange = _v1.a;
			return firstImportRange.b9.c9;
		} else {
			var _v2 = ast.bl;
			if (_v2.b) {
				var _v3 = _v2.a;
				var firstDeclarationRange = _v3.a;
				return firstDeclarationRange.b9.c9;
			} else {
				return 0;
			}
		}
	}();
	return A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleDocumentationBeforeCutOffLine, cutOffLine, ast.b);
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$rawSinceAtDocsEmptyFinishedBlocksEmpty = {aI: _List_Nil, aQ: ''};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleDocumentationParse = function (moduleDocumentationContent) {
	var parsed = A3(
		$elm$core$List$foldl,
		F2(
			function (line, soFar) {
				return A2($elm$core$String$startsWith, '@docs ', line) ? {
					aI: A2(
						$elm$core$List$cons,
						{
							ci: A2(
								$elm$core$List$map,
								$elm$core$String$trim,
								A2(
									$elm$core$String$split,
									',',
									A3(
										$elm$core$String$slice,
										6,
										$elm$core$String$length(line),
										line))),
							eb: soFar.aQ
						},
						soFar.aI),
					aQ: ''
				} : {aI: soFar.aI, aQ: soFar.aQ + '\n'};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$rawSinceAtDocsEmptyFinishedBlocksEmpty,
		$elm$core$String$lines(moduleDocumentationContent));
	return {
		ea: parsed.aQ,
		ds: $elm$core$List$reverse(parsed.aI)
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeToAtDocsString = function (syntaxExpose) {
	switch (syntaxExpose.$) {
		case 0:
			var operatorSymbol = syntaxExpose.a;
			return '(' + (operatorSymbol + ')');
		case 1:
			var name = syntaxExpose.a;
			return name;
		case 2:
			var name = syntaxExpose.a;
			return name;
		default:
			var choiceTypeExpose = syntaxExpose.a;
			return choiceTypeExpose.aN;
	}
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listFirstJustMap = F2(
	function (elementToMaybe, list) {
		listFirstJustMap:
		while (true) {
			if (!list.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var head = list.a;
				var tail = list.b;
				var _v1 = elementToMaybe(head);
				if (_v1.$ === 1) {
					var $temp$elementToMaybe = elementToMaybe,
						$temp$list = tail;
					elementToMaybe = $temp$elementToMaybe;
					list = $temp$list;
					continue listFirstJustMap;
				} else {
					var b = _v1.a;
					return $elm$core$Maybe$Just(b);
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$atDocsLineToExposesAndRemaining = F2(
	function (atDocsLine, remainingExposes) {
		return A3(
			$elm$core$List$foldr,
			F2(
				function (exposeAsAtDocsString, soFar) {
					var toExposeReferencedByAtDocsString = function (ex) {
						return _Utils_eq(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeToAtDocsString(ex),
							exposeAsAtDocsString) ? $elm$core$Maybe$Just(ex) : $elm$core$Maybe$Nothing;
					};
					var _v0 = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listFirstJustMap, toExposeReferencedByAtDocsString, soFar.ai);
					if (_v0.$ === 1) {
						return soFar;
					} else {
						var exposeReferencedByAtDocsString = _v0.a;
						return {
							br: A2($elm$core$List$cons, exposeReferencedByAtDocsString, soFar.br),
							ai: A2(
								$elm$core$List$filter,
								function (ex) {
									return !_Utils_eq(ex, exposeReferencedByAtDocsString);
								},
								soFar.ai)
						};
					}
				}),
			{br: _List_Nil, ai: remainingExposes},
			atDocsLine);
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listMapAndIntersperseAndFlattenToString = F3(
	function (elementToString, betweenElements, elements) {
		if (!elements.b) {
			return '';
		} else {
			var head = elements.a;
			var tail = elements.b;
			return A3(
				$elm$core$List$foldl,
				F2(
					function (next, soFar) {
						return soFar + (betweenElements + (elementToString(next) + ''));
					}),
				elementToString(head),
				tail);
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedCommaSpace = A2($lue_bird$elm_syntax_format$Print$followedBy, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyCommaSpace, $lue_bird$elm_syntax_format$Print$linebreakIndented);
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleExposing = F2(
	function (context, _v0) {
		var exposingRange = _v0.a;
		var syntaxExposing = _v0.b;
		if (!syntaxExposing.$) {
			return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningDotDotParensClosing;
		} else {
			var exposingSet = syntaxExposing.a;
			var _v2 = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposeListToNormal(exposingSet);
			if (!_v2.b) {
				return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningParensClosed;
			} else {
				if (!_v2.b.b) {
					var _v3 = _v2.a;
					var onlySyntaxExpose = _v3.b;
					var containedComments = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange, exposingRange, context.b);
					var lineSpread = function () {
						if (containedComments.b) {
							return 1;
						} else {
							return 0;
						}
					}();
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						function () {
							if (!containedComments.b) {
								return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing;
							} else {
								var comment0 = containedComments.a;
								var comment1Up = containedComments.b;
								return A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$comments(
											A2($elm$core$List$cons, comment0, comment1Up))));
							}
						}(),
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							$lue_bird$elm_syntax_format$Print$emptyOrLinebreakIndented(lineSpread),
							$lue_bird$elm_syntax_format$Print$exactly(
								function () {
									if (!lineSpread) {
										return '(';
									} else {
										return '( ';
									}
								}() + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expose(onlySyntaxExpose) + ''))));
				} else {
					var expose0 = _v2.a;
					var _v7 = _v2.b;
					var expose1 = _v7.a;
					var expose2Up = _v7.b;
					var _v8 = context.cj;
					if (_v8.b) {
						var atDocsLine0 = _v8.a;
						var atDocsLine1Up = _v8.b;
						var atDocsExposeLines = A3(
							$elm$core$List$foldr,
							F2(
								function (atDocsLine, soFar) {
									var atDocsExposeLine = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$atDocsLineToExposesAndRemaining, atDocsLine, soFar.ai);
									return {
										bc: A2($elm$core$List$cons, atDocsExposeLine.br, soFar.bc),
										ai: atDocsExposeLine.ai
									};
								}),
							{
								bc: _List_Nil,
								ai: A2(
									$elm$core$List$map,
									$stil4m$elm_syntax$Elm$Syntax$Node$value,
									A2(
										$elm$core$List$cons,
										expose0,
										A2($elm$core$List$cons, expose1, expose2Up)))
							},
							A2($elm$core$List$cons, atDocsLine0, atDocsLine1Up));
						var _v9 = A2(
							$elm$core$List$filter,
							function (line) {
								if (!line.b) {
									return false;
								} else {
									return true;
								}
							},
							atDocsExposeLines.bc);
						if (!_v9.b) {
							return A2(
								$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingMulti,
								context.b,
								{
									bp: expose0,
									bq: A2($elm$core$List$cons, expose1, expose2Up),
									c: exposingRange
								});
						} else {
							var atDocsExposeLine0 = _v9.a;
							var atDocsExposeLine1Up = _v9.b;
							return A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								function () {
									var _v11 = atDocsExposeLines.ai;
									if (!_v11.b) {
										return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing;
									} else {
										var remainingExpose0 = _v11.a;
										var remainingExpose1Up = _v11.b;
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensClosing,
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$linebreakIndented,
												$lue_bird$elm_syntax_format$Print$exactly(
													', ' + A3(
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listMapAndIntersperseAndFlattenToString,
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expose,
														', ',
														A2($elm$core$List$cons, remainingExpose0, remainingExpose1Up)))));
									}
								}(),
								A2(
									$lue_bird$elm_syntax_format$Print$followedBy,
									$lue_bird$elm_syntax_format$Print$linebreakIndented,
									A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										A3(
											$lue_bird$elm_syntax_format$Print$listMapAndIntersperseAndFlatten,
											function (atDocsLine) {
												return $lue_bird$elm_syntax_format$Print$exactly(
													A3($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listMapAndIntersperseAndFlattenToString, $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$expose, ', ', atDocsLine));
											},
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakIndentedCommaSpace,
											A2($elm$core$List$cons, atDocsExposeLine0, atDocsExposeLine1Up)),
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printExactlyParensOpeningSpace)));
						}
					} else {
						return A2(
							$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$exposingMulti,
							context.b,
							{
								bp: expose0,
								bq: A2($elm$core$List$cons, expose1, expose2Up),
								c: exposingRange
							});
					}
				}
			}
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleHeader = F2(
	function (context, syntaxModuleHeader) {
		switch (syntaxModuleHeader.$) {
			case 0:
				var defaultModuleData = syntaxModuleHeader.a;
				var exposingPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleExposing, context, defaultModuleData.ax);
				var lineSpread = $lue_bird$elm_syntax_format$Print$lineSpread(exposingPrint);
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							exposingPrint,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
					$lue_bird$elm_syntax_format$Print$exactly(
						'module ' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(
							$stil4m$elm_syntax$Elm$Syntax$Node$value(defaultModuleData.T)) + ' exposing')));
			case 1:
				var defaultModuleData = syntaxModuleHeader.a;
				var exposingPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleExposing, context, defaultModuleData.ax);
				var lineSpread = $lue_bird$elm_syntax_format$Print$lineSpread(exposingPrint);
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							exposingPrint,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
					$lue_bird$elm_syntax_format$Print$exactly(
						'port module ' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(
							$stil4m$elm_syntax$Elm$Syntax$Node$value(defaultModuleData.T)) + ' exposing')));
			default:
				var effectModuleData = syntaxModuleHeader.a;
				var exposingPrint = A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleExposing, context, effectModuleData.ax);
				var lineSpread = $lue_bird$elm_syntax_format$Print$lineSpread(exposingPrint);
				return A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					$lue_bird$elm_syntax_format$Print$withIndentAtNextMultipleOf4(
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							exposingPrint,
							$lue_bird$elm_syntax_format$Print$spaceOrLinebreakIndented(lineSpread))),
					$lue_bird$elm_syntax_format$Print$exactly(
						'effect module ' + ($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleName(
							$stil4m$elm_syntax$Elm$Syntax$Node$value(effectModuleData.T)) + (' where { ' + (A2(
							$elm$core$String$join,
							', ',
							A2(
								$elm$core$List$filterMap,
								$elm$core$Basics$identity,
								_List_fromArray(
									[
										function () {
										var _v1 = effectModuleData.bT;
										if (_v1.$ === 1) {
											return $elm$core$Maybe$Nothing;
										} else {
											var _v2 = _v1.a;
											var name = _v2.b;
											return $elm$core$Maybe$Just('command = ' + name);
										}
									}(),
										function () {
										var _v3 = effectModuleData.cc;
										if (_v3.$ === 1) {
											return $elm$core$Maybe$Nothing;
										} else {
											var _v4 = _v3.a;
											var name = _v4.b;
											return $elm$core$Maybe$Just('subscription = ' + name);
										}
									}()
									]))) + ' } exposing')))));
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsEmptyPortDocumentationCommentsEmpty = {b: _List_Nil, ah: _List_Nil};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$splitOffPortDocumentationComments = function (commentsAndPortDocumentationComments) {
	return A3(
		$elm$core$List$foldr,
		F2(
			function (commentOrPortDocumentationComments, soFar) {
				return A2(
					$elm$core$String$startsWith,
					'{-|',
					$stil4m$elm_syntax$Elm$Syntax$Node$value(commentOrPortDocumentationComments)) ? {
					b: soFar.b,
					ah: A2($elm$core$List$cons, commentOrPortDocumentationComments, soFar.ah)
				} : {
					b: A2($elm$core$List$cons, commentOrPortDocumentationComments, soFar.b),
					ah: soFar.ah
				};
			}),
		$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsEmptyPortDocumentationCommentsEmpty,
		commentsAndPortDocumentationComments);
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$module_ = function (syntaxModule) {
	var maybeModuleDocumentation = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleDocumentation(syntaxModule);
	var lastSyntaxLocationBeforeDeclarations = function () {
		var _v15 = syntaxModule.dN;
		if (_v15.b) {
			var _v16 = _v15.a;
			var firstImportRange = _v16.a;
			return firstImportRange.cw;
		} else {
			return $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxModule.dY).cw;
		}
	}();
	var commentsAndPortDocumentationComments = $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$splitOffPortDocumentationComments(
		function () {
			if (maybeModuleDocumentation.$ === 1) {
				return syntaxModule.b;
			} else {
				var syntaxModuleDocumentation = maybeModuleDocumentation.a;
				return A2(
					$elm$core$List$filter,
					function (c) {
						return !_Utils_eq(c, syntaxModuleDocumentation);
					},
					syntaxModule.b);
			}
		}());
	var commentsBeforeDeclarations = function () {
		var _v12 = syntaxModule.bl;
		if (!_v12.b) {
			return _List_Nil;
		} else {
			var _v13 = _v12.a;
			var declaration0Range = _v13.a;
			return A2(
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
				{cw: declaration0Range.b9, b9: lastSyntaxLocationBeforeDeclarations},
				commentsAndPortDocumentationComments.b);
		}
	}();
	var atDocsLines = function () {
		if (maybeModuleDocumentation.$ === 1) {
			return _List_Nil;
		} else {
			var _v11 = maybeModuleDocumentation.a;
			var syntaxModuleDocumentation = _v11.b;
			return A2(
				$elm$core$List$map,
				function ($) {
					return $.ci;
				},
				$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleDocumentationParse(syntaxModuleDocumentation).ds);
		}
	}();
	return A2(
		$lue_bird$elm_syntax_format$Print$followedBy,
		function () {
			var _v8 = syntaxModule.bl;
			if (!_v8.b) {
				return $lue_bird$elm_syntax_format$Print$empty;
			} else {
				var declaration0 = _v8.a;
				var declaration1Up = _v8.b;
				var _v9 = A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsAfter,
					$stil4m$elm_syntax$Elm$Syntax$Node$range(
						A2($lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$listFilledLast, declaration0, declaration1Up)).cw,
					commentsAndPortDocumentationComments.b);
				if (!_v9.b) {
					return $lue_bird$elm_syntax_format$Print$empty;
				} else {
					var comment0 = _v9.a;
					var comment1Up = _v9.b;
					return A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments(
							A2($elm$core$List$cons, comment0, comment1Up)),
						$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreakLinebreak);
				}
			}
		}(),
		A2(
			$lue_bird$elm_syntax_format$Print$followedBy,
			$lue_bird$elm_syntax_format$Print$linebreak,
			A2(
				$lue_bird$elm_syntax_format$Print$followedBy,
				A2(
					$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$declarations,
					{b: commentsAndPortDocumentationComments.b, ah: commentsAndPortDocumentationComments.ah, aq: lastSyntaxLocationBeforeDeclarations},
					syntaxModule.bl),
				A2(
					$lue_bird$elm_syntax_format$Print$followedBy,
					function () {
						if (!commentsBeforeDeclarations.b) {
							return $lue_bird$elm_syntax_format$Print$empty;
						} else {
							var comment0 = commentsBeforeDeclarations.a;
							var comment1Up = commentsBeforeDeclarations.b;
							return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelCommentsBeforeDeclaration(
								{bf: comment0, bg: comment1Up});
						}
					}(),
					A2(
						$lue_bird$elm_syntax_format$Print$followedBy,
						$lue_bird$elm_syntax_format$Print$linebreak,
						A2(
							$lue_bird$elm_syntax_format$Print$followedBy,
							function () {
								var _v2 = syntaxModule.dN;
								if (!_v2.b) {
									if (maybeModuleDocumentation.$ === 1) {
										return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak;
									} else {
										if (!commentsBeforeDeclarations.b) {
											return $lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak;
										} else {
											return $lue_bird$elm_syntax_format$Print$empty;
										}
									}
								} else {
									var _v5 = _v2.a;
									var import0Range = _v5.a;
									var import0 = _v5.b;
									var import1Up = _v2.b;
									return A2(
										$lue_bird$elm_syntax_format$Print$followedBy,
										$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak,
										A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											A2(
												$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$imports,
												commentsAndPortDocumentationComments.b,
												A2(
													$elm$core$List$cons,
													A2($stil4m$elm_syntax$Elm$Syntax$Node$Node, import0Range, import0),
													import1Up)),
											A2(
												$lue_bird$elm_syntax_format$Print$followedBy,
												$lue_bird$elm_syntax_format$Print$linebreak,
												function () {
													var _v6 = A2(
														$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$commentsInRange,
														{
															cw: import0Range.b9,
															b9: $stil4m$elm_syntax$Elm$Syntax$Node$range(syntaxModule.dY).cw
														},
														commentsAndPortDocumentationComments.b);
													if (!_v6.b) {
														return $lue_bird$elm_syntax_format$Print$linebreak;
													} else {
														var comment0 = _v6.a;
														var comment1Up = _v6.b;
														return A2(
															$lue_bird$elm_syntax_format$Print$followedBy,
															$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleLevelComments(
																A2($elm$core$List$cons, comment0, comment1Up)),
															$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak);
													}
												}())));
								}
							}(),
							A2(
								$lue_bird$elm_syntax_format$Print$followedBy,
								function () {
									if (maybeModuleDocumentation.$ === 1) {
										return $lue_bird$elm_syntax_format$Print$empty;
									} else {
										var _v1 = maybeModuleDocumentation.a;
										var moduleDocumentationAsString = _v1.b;
										return A2(
											$lue_bird$elm_syntax_format$Print$followedBy,
											$lue_bird$elm_syntax_format$Print$exactly(moduleDocumentationAsString),
											$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$printLinebreakLinebreak);
									}
								}(),
								A2(
									$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$moduleHeader,
									{cj: atDocsLines, b: commentsAndPortDocumentationComments.b},
									$stil4m$elm_syntax$Elm$Syntax$Node$value(syntaxModule.dY)))))))));
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrint$module_ = function (syntaxModule) {
	return function (state) {
		return A2(
			$lue_bird$elm_syntax_format$Print$toStringWithIndent,
			state.m,
			$lue_bird$elm_syntax_format$ElmSyntaxPrintDefunctionalized$module_(syntaxModule));
	};
};
var $lue_bird$elm_syntax_format$ElmSyntaxPrint$toString = function (print) {
	return print(
		{m: 0});
};
var $author$project$Node$Format$render = function (modul) {
	return $lue_bird$elm_syntax_format$ElmSyntaxPrint$toString(
		$lue_bird$elm_syntax_format$ElmSyntaxPrint$module_(modul));
};
var $lue_bird$elm_syntax_format$ParserFast$run = F2(
	function (_v0, src) {
		var parse = _v0;
		var _v1 = parse(
			{co: 1, m: _List_Nil, i: 0, c9: 1, g: src});
		if (!_v1.$) {
			var value = _v1.a;
			var finalState = _v1.b;
			return (!(finalState.i - $elm$core$String$length(finalState.g))) ? $elm$core$Maybe$Just(value) : $elm$core$Maybe$Nothing;
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$run = F2(
	function (syntaxParser, source) {
		return A2($lue_bird$elm_syntax_format$ParserFast$run, syntaxParser, source);
	});
var $author$project$Node$Format$run = function (inputText) {
	var _v0 = A2($lue_bird$elm_syntax_format$ElmSyntaxParserLenient$run, $lue_bird$elm_syntax_format$ElmSyntaxParserLenient$module_, inputText);
	if (!_v0.$) {
		var modu = _v0.a;
		return $elm$core$Result$Ok(
			$author$project$Node$Format$render(modu));
	} else {
		return $elm$core$Result$Err('Something went wrong...');
	}
};
var $elm$json$Json$Encode$string = _Json_wrap;
var $author$project$Node$Main$app = A2(
	$author$project$System$IO$bind,
	function (args) {
		var path = args;
		var _v1 = $author$project$Node$Format$run(path);
		if (!_v1.$) {
			var output = _v1.a;
			return $author$project$Node$Main$exitWithResponse(
				$elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2(
							'output',
							$elm$json$Json$Encode$string(output))
						])));
		} else {
			var error = _v1.a;
			return $author$project$Node$Main$exitWithResponse(
				$elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2(
							'error',
							$elm$json$Json$Encode$string(error))
						])));
		}
	},
	$author$project$Node$Main$getArgs);
var $elm$core$Platform$Sub$batch = _Platform_batch;
var $elm$core$Platform$Sub$none = $elm$core$Platform$Sub$batch(_List_Nil);
var $elm$core$Task$Perform = $elm$core$Basics$identity;
var $elm$core$Task$init = $elm$core$Task$succeed(0);
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
var $elm$core$Platform$sendToApp = _Platform_sendToApp;
var $elm$core$Task$spawnCmd = F2(
	function (router, _v0) {
		var task = _v0;
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
				return 0;
			},
			$elm$core$Task$sequence(
				A2(
					$elm$core$List$map,
					$elm$core$Task$spawnCmd(router),
					commands)));
	});
var $elm$core$Task$onSelfMsg = F3(
	function (_v0, _v1, _v2) {
		return $elm$core$Task$succeed(0);
	});
var $elm$core$Task$cmdMap = F2(
	function (tagger, _v0) {
		var task = _v0;
		return A2($elm$core$Task$map, tagger, task);
	});
_Platform_effectManagers['Task'] = _Platform_createManager($elm$core$Task$init, $elm$core$Task$onEffects, $elm$core$Task$onSelfMsg, $elm$core$Task$cmdMap);
var $elm$core$Task$command = _Platform_leaf('Task');
var $elm$core$Task$perform = F2(
	function (toMessage, task) {
		return $elm$core$Task$command(
			A2($elm$core$Task$map, toMessage, task));
	});
var $author$project$System$IO$update = F2(
	function (msg, _v0) {
		return _Utils_Tuple2(
			0,
			A2($elm$core$Task$perform, $elm$core$Task$succeed, msg));
	});
var $elm$core$Platform$worker = _Platform_worker;
var $author$project$System$IO$run = function (app) {
	return $elm$core$Platform$worker(
		{
			dP: $author$project$System$IO$update(app),
			ek: function (_v0) {
				return $elm$core$Platform$Sub$none;
			},
			ep: $author$project$System$IO$update
		});
};
var $elm$json$Json$Decode$succeed = _Json_succeed;
var $author$project$Node$Main$main = $author$project$System$IO$run($author$project$Node$Main$app);
_Platform_export({'Node':{'Main':{'init':$author$project$Node$Main$main(
	$elm$json$Json$Decode$succeed(0))(0)}}});}(this));