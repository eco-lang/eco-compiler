//===- VirtualDomLayout.hpp - Heap layout of native VirtualDom values -------===//
//
// plans/elm-html-native-kernel.md §3 (D3) and VDOM_001. Native VirtualDom
// values are ordinary Tag_Custom objects whose constructor and field layout is
// that of the transparent Elm types eco/system `Http.Dom.Node` / `Http.Dom.Fact`
// (system-kernel-cpp/src/Http/Dom.elm). Constructor tag = zero-based
// declaration index; every field is boxed. This header is the only C++ source
// of those constants: change it and Dom.elm together. DomLayoutTest.elm pins
// the match.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_VIRTUALDOMLAYOUT_H
#define ECO_VIRTUALDOMLAYOUT_H

#include "allocator/Heap.hpp"

namespace Elm::Kernel::VirtualDom {

// type Node
inline constexpr u16 NODE_TEXT          = 0;  // Text String
inline constexpr u16 NODE_ELEMENT       = 1;  // Element (Maybe String) String (List Fact) (List Node)
inline constexpr u16 NODE_KEYED_ELEMENT = 2;  // KeyedElement (Maybe String) String (List Fact) (List (String, Node))
inline constexpr u16 NODE_MAPPED        = 3;  // Mapped Tagger Node

// type Fact
inline constexpr u16 FACT_ATTRIBUTE    = 0;   // Attribute key value
inline constexpr u16 FACT_ATTRIBUTE_NS = 1;   // AttributeNS namespace key value
inline constexpr u16 FACT_PROPERTY     = 2;   // Property key Json.Value
inline constexpr u16 FACT_STYLE        = 3;   // Style key value
inline constexpr u16 FACT_EVENT        = 4;   // Event name Handler (List Tagger), outermost tagger first

// Field indices.
inline constexpr u32 EL_NS = 0, EL_TAG = 1, EL_FACTS = 2, EL_KIDS = 3;   // Element / KeyedElement
inline constexpr u32 MAPPED_TAGGER = 0, MAPPED_NODE = 1;
inline constexpr u32 TEXT_STRING = 0;
inline constexpr u32 FACT_KEY = 0, FACT_VALUE = 1;                       // Attribute / Property / Style
inline constexpr u32 NS_NAMESPACE = 0, NS_KEY = 1, NS_VALUE = 2;         // AttributeNS
inline constexpr u32 EV_NAME = 0, EV_HANDLER = 1, EV_TAGGERS = 2;        // Event

} // namespace Elm::Kernel::VirtualDom

#endif // ECO_VIRTUALDOMLAYOUT_H
