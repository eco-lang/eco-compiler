//===- JsonRead.hpp - Read-only view of Json.Value heap forms ---------------===//
//
// Code that must read a `Json.Value` while it holds raw addresses into the heap needs a way to do so
// that cannot move those objects, and this component is that way: it classifies a JSON value and reads
// its contents without allocating on the Elm heap and without calling Elm code.
//
// A `Json.Value` on the heap has one of two families of form. The *encoder family* is what Json.Encode
// builds: values tagged with the `ENC_*` ctors 0-6, whose arrays and objects are Elm lists held in the
// reverse of the order their entries were added. The *decoder family* is what the JSON parser builds:
// values tagged with the `CTOR_JSON_*` ctors 100-107, whose arrays are ElmArrays, split over several
// ElmArrays (*chunked*, ctor 107) when long. In both families JSON null is an embedded constant that
// carries the null ctor and is never a heap object.
//
// `view` reduces either family to a `View`: one of the six JSON kinds plus the scalar or String it
// holds. `arrayElements` lists an array's elements in order, whichever form it has, and `jsToString`
// renders a String or an Array as JavaScript's `String(value)` would.
//
// Allocation may move heap objects, as `elm-kernel-cpp/ExportHelpers` states. Nothing here allocates
// on the Elm heap, so a raw address read here stays valid through the walk that reads it, but every
// address and word handed back is valid only until the caller next allocates or calls Elm. The C++
// heap is used (the element vector and the `std::u16string` results).
//
// The ctor numbers are copies. The originals are `static` constants inside `JsonExports.cpp`, which
// declares them in no header, and nothing at compile time checks that the two sets agree.
// `test/kernel/VirtualDomKernelTest.cpp` builds values through the Json kernel exports and checks the
// kinds `view` gives them, which catches a disagreement for the forms it builds.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_JSONREAD_H
#define ECO_JSONREAD_H

#include "allocator/Heap.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace Elm::Kernel::JsonRead {

// The ctors of the encoder family of `Json.Value`: null, Bool, Int, Float, String, array and object.
// Copies of the values in `JsonExports.cpp`.
inline constexpr u16 ENC_NULL = 0, ENC_BOOL = 1, ENC_INT = 2, ENC_FLOAT = 3, ENC_STRING = 4,
                     ENC_ARRAY = 5, ENC_OBJECT = 6;
// The ctors of the decoder family of `Json.Value`, in the same order as the encoder family, plus
// `CTOR_JSON_ARRAY_CHUNKED`, a long array split over several ElmArrays. Copies of the values in
// `JsonExports.cpp`.
inline constexpr u16 CTOR_JSON_NULL = 100, CTOR_JSON_BOOL = 101, CTOR_JSON_INT = 102,
                     CTOR_JSON_FLOAT = 103, CTOR_JSON_STRING = 104, CTOR_JSON_ARRAY = 105,
                     CTOR_JSON_OBJECT = 106, CTOR_JSON_ARRAY_CHUNKED = 107;

/// The kind of a JSON value, as JavaScript would see it once parsed.
///
/// `Number` covers both Int and Float values. An unrecognised value is classified `Null`.
enum class Kind { Null, Bool, Number, String, Array, Object };

/// What `view` found in one JSON value: its kind, and the scalar or String it holds.
///
/// `boolean` is meaningful only for `Kind::Bool`, `number` only for `Kind::Number`, and `string` only
/// for `Kind::String`; the others keep their defaults. An Int is held as a `double`, so one larger in
/// magnitude than 2^53 may lose precision.
struct View {
    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0.0;
    /// The address of the String object, or null when a String Custom holds the empty String, an embedded
    /// constant.
    /// Valid only until the next allocation on the Elm heap.
    void* string = nullptr;
    /// The word `view` was given, for whatever kind; `arrayElements` reads it. Valid only until the next
    /// allocation on the Elm heap.
    uint64_t bits = 0;
};

/// Returns the kind of the value word `valueBits` and the scalar or String it holds.
///
/// The True and False constants are Bools, and every other embedded constant, JSON null among them,
/// is `Null`. A boxed Int or Float heap object is a `Number` and a String heap object is a `String`.
/// A Custom is classified by its ctor, an encoder-family ctor and its decoder-family counterpart
/// alike: null, Bool, Int and Float, String, array (chunked or not) and object. A Bool Custom whose
/// field is not the True or False constant reads as false. Anything else, an unknown ctor, another
/// heap tag or a word for which `Export::toPtr` returns null, is `Null`.
View view(uint64_t valueBits);

/// Appends to `out` the value words of the elements of the array `array` describes, in order.
///
/// For an encoder-family array the order is the order the elements were added; the stored list is
/// reversed back. Nothing is appended unless `array.kind` is `Kind::Array`. `array` is read through
/// its `bits` word, which must still refer to the array, so there must have been no allocation since
/// `view` produced it. The words appended are not rooted and are stale after the next allocation.
void arrayElements(const View& array, std::vector<uint64_t>& out);

/// Sets `out` to what JavaScript's `String(value)` gives for the String or array `valueBits`, and
/// returns true; returns false, leaving `out` untouched, for a value of any other kind, a number
/// included.
///
/// An array renders as `Array.prototype.join` with commas does: null as the empty string, a Bool as
/// `true` or `false`, a number as JavaScript prints it, a String as itself, an object as
/// `[object Object]`, and a nested array recursively. An array nested more than 256 deep, counting
/// `valueBits` itself as depth 1, renders as the empty string.
bool jsToString(uint64_t valueBits, std::u16string& out);

} // namespace Elm::Kernel::JsonRead

#endif // ECO_JSONREAD_H
