//===- HttpServer.hpp - eco/system kernel module HttpServer (internal) ----===//
//
// plans/eco-system-library.md Appendix B.6, C.5, E.5 and Phase 7 step 7.2:
// the binding bodies of Eco.Kernel.HttpServer (HttpServer.cpp), bound by
// HttpServerExports.cpp. The `Http.Server` effect manager (onRequest) and
// the module's drain are in HttpServerManager.{hpp,cpp}; sockets, threads
// and llhttp in HttpServerService.{hpp,cpp} (POD only).
//
// Templates used: T2 (createServer, P mode), T9-style async completion
// (respond, completed by the drain after the connection thread wrote it).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

// createServer : String -> Int -> Task ( String, String ) Int
// captured = ( host, port ) mask 0x4.
HPointer httpServerCreateServerBody(HPointer captured, HPointer resume);

// respond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
// captured = ( ( key, status ) mask 0x5, ( headers, body ) ) mask 0.
HPointer httpServerRespondBody(HPointer captured, HPointer resume);

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP
