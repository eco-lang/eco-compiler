//===- JsonRead.hpp - Read-only view of Json.Value heap forms ---------------===//
//
// plans/elm-html-native-kernel.md P0.3 / Appendix B.3. A Json.Value on the
// heap is either an encoder node (ENC_*, ctors 0-6, built by Json.Encode) or a
// decoded node (CTOR_JSON_*, ctors 100-107, built by the parser). This header
// classifies both without allocating on the Eco heap and without calling Elm
// (VDOM_004), so the HTML writer can read property values mid-walk.
//
// The ctor constants mirror JsonExports.cpp:49-60 (CTOR_JSON_*) and :88-94
// (ENC_*). That file is LSS_022-pinned and is not edited (D18); the mirror is
// cross-checked by test/kernel/VirtualDomKernelTest.cpp through the exported
// Json kernels.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_JSONREAD_H
#define ECO_JSONREAD_H

#include "allocator/Heap.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace Elm::Kernel::JsonRead {

// Mirrored ctor constants (see the file comment).
inline constexpr u16 ENC_NULL = 0, ENC_BOOL = 1, ENC_INT = 2, ENC_FLOAT = 3, ENC_STRING = 4,
                     ENC_ARRAY = 5, ENC_OBJECT = 6;
inline constexpr u16 CTOR_JSON_NULL = 100, CTOR_JSON_BOOL = 101, CTOR_JSON_INT = 102,
                     CTOR_JSON_FLOAT = 103, CTOR_JSON_STRING = 104, CTOR_JSON_ARRAY = 105,
                     CTOR_JSON_OBJECT = 106, CTOR_JSON_ARRAY_CHUNKED = 107;

enum class Kind { Null, Bool, Number, String, Array, Object };

struct View {
    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0.0;
    void* string = nullptr;   // resolved string object; nullptr = "" (empty constant)
    uint64_t bits = 0;        // the value word (Array: for arrayElements)
};

// Classification, mirroring elmToJson (JsonExports.cpp:1340-1436) and
// heapJsonToNlohmann (:608-670):
//  - embedded constant: Bool constant -> Bool, anything else -> Null
//  - Tag_Int / Tag_Float -> Number; a string object -> String (legacy fallthrough)
//  - Tag_Custom by ctor: 0|100 Null, 1|101 Bool, 2|102 Number (i64 -> double),
//    3|103 Number, 4|104 String, 5|105|107 Array, 6|106 Object; otherwise Null
View view(uint64_t valueBits);

// Elements of an Array view in JSON order: ENC_ARRAY lists are stored reversed
// (F2); 105 is an ElmArray; 107 is chunked (indexed as jsonArrayAt,
// JsonExports.cpp:473-480). Appends encoded element words to `out`.
void arrayElements(const View& array, std::vector<uint64_t>& out);

// JS String(value) for a String or an Array (Array.prototype.toString, plan §6).
// Returns false, leaving `out` untouched, for any other kind. Nested arrays
// deeper than 256 stringify as "".
bool jsToString(uint64_t valueBits, std::u16string& out);

} // namespace Elm::Kernel::JsonRead

#endif // ECO_JSONREAD_H
