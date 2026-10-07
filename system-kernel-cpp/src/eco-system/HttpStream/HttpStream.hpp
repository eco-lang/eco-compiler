//===- HttpStream.hpp - eco/system kernel module HttpStream ---------------===//
//
// plans/eco-system-library.md Appendix B.7 and Phase 8 step 8.2: the `send`
// binding body (bound by HttpStreamExports.cpp). The transfer machinery is
// in HttpTransfer.hpp.
//
// Templates used: T2 shape (async binding on HttpStreamService), T7.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_STREAM_HTTP_STREAM_HPP
#define ECO_SYSTEM_HTTP_STREAM_HTTP_STREAM_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

// send (B.7) — the makeAsyncBinding body. Payload:
//   tuple2( boxed tuple2( (method, url, timeoutMs), headers ),
//           boxed tuple2( (bodyKind, contentType, (bytes, streamId)), discardNon2xx ) ),
// every slot boxed (mask 0).
HPointer httpStreamSendBody(HPointer captured, HPointer resume);

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_STREAM_HTTP_STREAM_HPP
