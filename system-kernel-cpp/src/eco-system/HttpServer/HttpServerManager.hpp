//===- HttpServerManager.hpp - The C++ effect manager of Http.Server ------===//
//
// An Elm program serves HTTP through the `Http.Server` module, whose commands and subscriptions are handled by an
// effect manager. On the native backend that manager is written in C++, here, and registered under the module name
// "Http.Server" in place of the Elm functions in `src/Http/Server.elm`.
//
// An effect manager is a set of five closures (`init`, `onEffects`, `onSelfMsg`, `cmdMap`, `subMap`) that the
// platform runtime calls with the program's current commands and subscriptions. The *router* is the runtime value a
// manager passes to `sendToApp` to deliver a message to the program. A *tagger* is the Elm function a subscription
// carries, which turns an event into the program's message.
//
// The manager has one command and one subscription:
//   * `Respond task` carries the kernel task that writes one response. `onEffects` spawns each such task.
//   * `OnRequest serverId tagger` asks for the requests of one server. The manager keeps the taggers of every server,
//     and `HttpTables`, which owns servers, connections and requests, asks it through `HttpManagerHooks` whether a
//     server has a subscriber and hands it each request to deliver. A request is delivered by calling every tagger
//     of its server on one Elm value, the *tagger argument*, and sending each result to the program.
//
// The tagger argument is `( ( method, absoluteUrl ), ( headers, body ), ( responseKey, flags, upgradeToken ) )`.
// `headers` holds one `( name, [ value ] )` entry per header occurrence, in arrival order; `body` is a `Bytes`;
// `flags` and `upgradeToken` are as `HttpSrv::RequestData` defines them.
//
// The constants below describe the heap layouts of these Elm values, which the C++ code reads and builds directly.
// A constructor tag is the zero-based index of the constructor in its Elm type declaration, so the tags must be
// kept in step with `src/Http/Server.elm`. Masks give each slot's kind in 2 bits, 0 for boxed and 1 for an unboxed
// Int, as `alloc::custom` and `alloc::tuple3` read them.
//
// On Windows an `OnRequest` subscription is a fatal error.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace HttpServerManager {

/// The constructor tag of `Respond`, the only constructor of `MyCmd`.
constexpr uint16_t CTOR_RESPOND = 0;
/// The field of `Respond` that holds its task, boxed.
constexpr int RESPOND_TASK_FIELD = 0;

/// The constructor tag of `OnRequest`, the only constructor of `MySub`.
constexpr uint16_t CTOR_ON_REQUEST = 0;
/// The field of `OnRequest` that holds the server id, an unboxed Int.
constexpr int ON_REQUEST_SERVER_FIELD = 0;
/// The field of `OnRequest` that holds the tagger, boxed.
constexpr int ON_REQUEST_TAGGER_FIELD = 1;
/// The slot kinds of an `OnRequest` value: field 0 an unboxed Int, field 1 boxed.
constexpr uint64_t ON_REQUEST_MASK = 0x1;

/// The slot kinds of the outer triple of the tagger argument: all three boxed.
constexpr uint32_t TAGGER_ARG_MASK = 0;
/// The slot kinds of the `( responseKey, flags, upgradeToken )` triple: slots 0 and 1 unboxed Ints, slot 2 boxed.
constexpr uint32_t TAGGER_KEY_MASK = 0x5;

/// The bits of `flags` that hold the HTTP version: 0 for HTTP/1.0, 1 for HTTP/1.1, 2 for HTTP/2.
constexpr int64_t FLAG_VERSION_MASK = 0x3;
/// The bit of `flags` that is set when the request came over TLS.
constexpr int64_t FLAG_TLS = 0x4;

} // namespace HttpServerManager

} // namespace Eco::System

extern "C" {
/// Registers the manager's closures under "Http.Server" with the platform runtime, replacing any manager registered
/// under that name, and installs its `HttpManagerHooks` in `HttpTables`. Returns the encoded unit value.
uint64_t Eco_System_registerManager_Http_Server();
}

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP
