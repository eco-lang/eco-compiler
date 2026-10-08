/*

import Elm.Kernel.VirtualDom exposing (text, nodeNS, keyedNodeNS, map, lazy, custom, style, attribute, attributeNS, property, on)
import Elm.Kernel.List exposing (Nil, fromArray)
import Elm.Kernel.Json exposing (wrap)
import Elm.Kernel.Utils exposing (Tuple2)
import Maybe exposing (Just, Nothing)
import Http.Dom as Dom exposing (Text, Element, KeyedElement, Mapped, Attribute, AttributeNS, Property, Style, Event, render)

*/

// Dom: the JS twin of src/eco-system/Dom/DomExports.cpp (plans/elm-html-native-kernel.md
// section 7.2, plans/eco-system-library.md B1b). Stock VirtualDom JS objects are read through
// keys and type codes CALIBRATED from probe vnodes, so kernel field renaming and package
// versions do not matter. Never throws (D17).

var _Dom_k = null;

function _Dom_keyOf(obj, value)
{
	for (var key in obj) { if (key !== '$' && obj[key] === value) return key; }
	return undefined;
}

function _Dom_keyWhere(obj, pred)
{
	for (var key in obj) { if (key !== '$' && pred(obj[key])) return key; }
	return undefined;
}

function _Dom_calibrate()
{
	if (_Dom_k) return _Dom_k;
	var k = {};
	var id = function(x) { return x; };
	var t = __VirtualDom_text('\u0001');
	k.TEXT = t.$;
	k.text = _Dom_keyOf(t, '\u0001');
	var el = A4(__VirtualDom_nodeNS, '\u0002', '\u0003', __List_Nil, __List_Nil);
	k.NODE = el.$;
	k.namespace = _Dom_keyOf(el, '\u0002');
	k.tag = _Dom_keyOf(el, '\u0003');
	k.kids = _Dom_keyWhere(el, Array.isArray);
	k.facts = _Dom_keyWhere(el, function(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); });
	k.KEYED = A4(__VirtualDom_keyedNodeNS, '\u0002', '\u0003', __List_Nil, __List_Nil).$;
	var tagged = A2(__VirtualDom_map, id, t);
	k.TAGGER = tagged.$;
	k.tagger = _Dom_keyOf(tagged, id);
	k.taggerNode = _Dom_keyOf(tagged, t);
	var thunk = A2(__VirtualDom_lazy, id, t);
	k.THUNK = thunk.$;
	k.thunk = _Dom_keyWhere(thunk, function(v) { return typeof v === 'function'; });
	k.CUSTOM = __VirtualDom_custom(__List_Nil, 0, id, id).$;
	var sty = A2(__VirtualDom_style, '\u0004', '\u0005');
	k.STYLE = sty.$;
	k.key = _Dom_keyOf(sty, '\u0004');
	k.value = _Dom_keyOf(sty, '\u0005');
	k.ATTR = A2(__VirtualDom_attribute, 'a', 'b').$;
	k.PROP = A2(__VirtualDom_property, 'a', __Json_wrap('b')).$;
	k.EVENT = A2(__VirtualDom_on, 'a', {}).$;
	var ns = A3(__VirtualDom_attributeNS, '\u0006', 'a', '\u0007');
	k.ATTR_NS = ns.$;
	k.nsNamespace = _Dom_keyOf(ns[k.value], '\u0006');
	k.nsValue = _Dom_keyOf(ns[k.value], '\u0007');
	return _Dom_k = k;
}

function _Dom_maybe(ns) { return ns === undefined ? __Maybe_Nothing : __Maybe_Just(ns); }

// Organized facts -> List Fact, in the for..in order _VirtualDom_applyFacts uses.
function _Dom_facts(k, facts)
{
	var out = [];
	for (var key in facts)
	{
		var v = facts[key];
		if (key === k.STYLE) { for (var s in v) out.push(A2(__Dom_Style, s, v[s])); }
		else if (key === k.EVENT) { for (var e in v) out.push(A3(__Dom_Event, e, v[e], __List_Nil)); }
		else if (key === k.ATTR) { for (var a in v) out.push(A2(__Dom_Attribute, a, v[a])); }
		else if (key === k.ATTR_NS) { for (var n in v) out.push(A3(__Dom_AttributeNS, v[n][k.nsNamespace], n, v[n][k.nsValue])); }
		else { out.push(A2(__Dom_Property, key, __Json_wrap(v))); }   // organized props are unwrapped
	}
	return __List_fromArray(out);
}

function _Dom_build(k, v, built)
{
	if (v.$ === k.TEXT) return __Dom_Text(v[k.text]);
	if (v.$ === k.NODE)
		return A4(__Dom_Element, _Dom_maybe(v[k.namespace]), v[k.tag], _Dom_facts(k, v[k.facts]), __List_fromArray(built));
	if (v.$ === k.KEYED)
	{
		var pairs = [];
		for (var i = 0; i < built.length; i++) pairs.push(__Utils_Tuple2(v[k.kids][i].a, built[i]));
		return A4(__Dom_KeyedElement, _Dom_maybe(v[k.namespace]), v[k.tag], _Dom_facts(k, v[k.facts]), __List_fromArray(pairs));
	}
	if (v.$ === k.TAGGER) return A2(__Dom_Mapped, v[k.tagger], built[0]);
	// CUSTOM or unknown: what VirtualDom.server.js renders.
	return A4(__Dom_Element, __Maybe_Nothing, 'div', _Dom_facts(k, v[k.facts]), __List_Nil);
}

function _Dom_fromNode(root)
{
	var k = _Dom_calibrate();
	var stack = [{ v: root, kids: null, i: 0, built: [] }];
	var result;
	while (stack.length)
	{
		var fr = stack[stack.length - 1];
		if (fr.kids === null)
		{
			while (fr.v.$ === k.THUNK) { fr.v = fr.v[k.thunk](); }    // forced, never cached
			fr.kids =
				(fr.v.$ === k.NODE || fr.v.$ === k.KEYED) ? fr.v[k.kids]
				: fr.v.$ === k.TAGGER ? [fr.v[k.taggerNode]]
				: [];
		}
		if (fr.i < fr.kids.length)
		{
			var child = fr.kids[fr.i++];
			stack.push({ v: fr.v.$ === k.KEYED ? child.b : child, kids: null, i: 0, built: [] });
			continue;
		}
		stack.pop();
		var node = _Dom_build(k, fr.v, fr.built);
		if (stack.length) stack[stack.length - 1].built.push(node); else result = node;
	}
	return result;
}

function _Dom_fromAttribute(fact)
{
	var k = _Dom_calibrate();
	var key = fact[k.key];
	var value = fact[k.value];
	if (fact.$ === k.STYLE) return A2(__Dom_Style, key, value);
	if (fact.$ === k.ATTR) return A2(__Dom_Attribute, key, value);
	if (fact.$ === k.ATTR_NS) return A3(__Dom_AttributeNS, value[k.nsNamespace], key, value[k.nsValue]);
	if (fact.$ === k.EVENT) return A3(__Dom_Event, key, value, __List_Nil);
	return A2(__Dom_Property, key, value);                             // PROP: already a Json.Value
}

function _Dom_toString(node) { return __Dom_render(_Dom_fromNode(node)); }
