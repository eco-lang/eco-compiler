//===- HttpRequestLayout.hpp - Slots of elm/http's Request record ----------===//
//
// The slot indexes of the fields of the Request record that elm/http 2.0.0
// hands its kernel (`Http.toTask`) and its effect manager (inside a `Request`
// command):
//
//   { allowCookiesFromOtherDomains : Bool, body : Body, expect : Expect msg,
//     headers : List Header, method : String, timeout : Maybe Float,
//     tracker : Maybe String, url : String }
//
// A record stores its unboxed fields first and then its boxed ones, each group
// in name order (`Types.computeRecordLayout`). Only Int, Float and Char are
// unboxed in a heap object (REP_HEAP_001); the `Bool` is boxed like the rest,
// so every field here is boxed and the slots follow the alphabetical order
// above. `http/HttpExports.cpp` and
// `http/HttpEffectManager.cpp` both read the record through these constants.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_HTTP_REQUEST_LAYOUT_HPP
#define ELM_KERNEL_HTTP_REQUEST_LAYOUT_HPP

namespace Elm::Kernel::HttpRequestLayout {

/// The slot of `allowCookiesFromOtherDomains`.
inline constexpr int REQ_ALLOW_COOKIES = 0;
/// The slot of `body`.
inline constexpr int REQ_BODY    = 1;
/// The slot of `expect`.
inline constexpr int REQ_EXPECT  = 2;
/// The slot of `headers`.
inline constexpr int REQ_HEADERS = 3;
/// The slot of `method`.
inline constexpr int REQ_METHOD  = 4;
/// The slot of `timeout`.
inline constexpr int REQ_TIMEOUT = 5;
/// The slot of `tracker`.
inline constexpr int REQ_TRACKER = 6;
/// The slot of `url`.
inline constexpr int REQ_URL     = 7;
/// The number of fields of the record.
inline constexpr int REQ_FIELD_COUNT = 8;

// A tripwire: these are the alphabetical positions above. Changing one means
// the record's field set or layout rule changed, and every reader must be
// checked against it.
static_assert(REQ_EXPECT == 2 && REQ_TRACKER == 6 && REQ_URL == 7 &&
              REQ_FIELD_COUNT == 8,
              "elm/http Request record slots are its fields in name order");

} // namespace Elm::Kernel::HttpRequestLayout

#endif // ELM_KERNEL_HTTP_REQUEST_LAYOUT_HPP
