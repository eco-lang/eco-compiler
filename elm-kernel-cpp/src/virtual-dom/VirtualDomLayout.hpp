//===- VirtualDomLayout.hpp - Heap layout of native VirtualDom values -------===//
//
// Native C++ code reads and builds VirtualDom values (`Html msg`, `Svg msg`) as
// heap objects, and Elm code in eco/system reads the same objects as the
// transparent types `Html.Dom.Node` and `Html.Dom.Fact`
// (system-kernel-cpp/src/Html/Dom.elm). Both views agree only if the C++ code
// uses exactly the layout the Elm compiler gives those types. This header holds
// that layout, and is the only C++ source of it (invariant VDOM_001).
//
// A native VirtualDom value is an ordinary `Tag_Custom` object. Its constructor
// tag is the zero-based index of its constructor in the Elm declaration, and its
// fields follow the constructor's arguments in order. Every field is boxed: the
// object's unboxed bitmap is zero, so each field is read as a pointer. The
// constants here must change together with Dom.elm; the Elm test
// DomLayoutTest.elm checks that they match.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_VIRTUALDOMLAYOUT_H
#define ECO_VIRTUALDOMLAYOUT_H

#include "allocator/Heap.hpp"

namespace Elm::Kernel::VirtualDom {

// Constructor tags of `Html.Dom.Node`, one per constructor, in declaration order.
inline constexpr u16 NODE_TEXT          = 0;  ///< The tag of a text node, `Text String`.
inline constexpr u16 NODE_ELEMENT       = 1;  ///< The tag of `Element (Maybe String) String (List Fact) (List Node)`.
inline constexpr u16 NODE_KEYED_ELEMENT = 2;  ///< The tag of `KeyedElement`, whose children are `(key, Node)` pairs.
inline constexpr u16 NODE_MAPPED        = 3;  ///< The tag of `Mapped Tagger Node`, a node under an `Html.map`.

// Constructor tags of `Html.Dom.Fact`, one per constructor, in declaration order. A `Fact` is one
// attribute, property, style or event handler of an element.
inline constexpr u16 FACT_ATTRIBUTE    = 0;   ///< The tag of `Attribute key value`.
inline constexpr u16 FACT_ATTRIBUTE_NS = 1;   ///< The tag of `AttributeNS namespace key value`.
inline constexpr u16 FACT_PROPERTY     = 2;   ///< The tag of `Property key value`, where value is a JSON value.
inline constexpr u16 FACT_STYLE        = 3;   ///< The tag of `Style key value`.
inline constexpr u16 FACT_EVENT        = 4;   ///< The tag of `Event name Handler taggers`; taggers run outermost first.

// Field indices within each constructor, grouped by the constructors that share them.
// `Element` and `KeyedElement` fields.
inline constexpr u32 EL_NS = 0, EL_TAG = 1, EL_FACTS = 2, EL_KIDS = 3;
// `Mapped` fields.
inline constexpr u32 MAPPED_TAGGER = 0, MAPPED_NODE = 1;
// The `Text` field.
inline constexpr u32 TEXT_STRING = 0;
// `Attribute`, `Property`, `Style` fields.
inline constexpr u32 FACT_KEY = 0, FACT_VALUE = 1;
// `AttributeNS` fields.
inline constexpr u32 NS_NAMESPACE = 0, NS_KEY = 1, NS_VALUE = 2;
// `Event` fields.
inline constexpr u32 EV_NAME = 0, EV_HANDLER = 1, EV_TAGGERS = 2;

} // namespace Elm::Kernel::VirtualDom

#endif // ECO_VIRTUALDOMLAYOUT_H
