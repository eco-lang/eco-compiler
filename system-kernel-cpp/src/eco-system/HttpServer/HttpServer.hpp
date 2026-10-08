//===- HttpServer.hpp - eco/system kernel module HttpServer (internal) ----===//
//
// plans/eco-system-library.md Appendix B.6, C.5, E.5 and
// plans/eco-system-websockets.md §3.4, Appendix B.2 (phase WS2): the binding
// bodies of Eco.Kernel.HttpServer (HttpServer.cpp), bound by
// HttpServerExports.cpp. The `Http.Server` effect manager is in
// HttpServerManager.{hpp,cpp}; the main-thread tables and events in
// HttpTables.{hpp,cpp}; the HTTP/1.1 connections (IoReactor) in
// Http1.{hpp,cpp}; listening and the wire format in
// HttpServerService.{hpp,cpp} (POD only).
//
// Templates used: T2 (createServer, createServerWith: P mode), T9-style
// async completion (respond, closeServer: completed by the HttpTables drain).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

// createServer : String -> Int -> Task ( String, String ) ( Int, Int )
// captured = ( host, port ) mask 0x4. Result ( serverId, boundPort ).
HPointer httpServerCreateServerBody(HPointer captured, HPointer resume);

// createServerWith : ( ( String, Int ), ( Bool, Int ) ) -> Maybe ( String, String )
//     -> ( ( Int, Int, Int ), ( Int, Int, Int ) ) -> Task ( String, String ) ( Int, Int )
// captured = ( target, tls, limits ) mask 0 (each argument as Elm passed it).
HPointer httpServerCreateServerWithBody(HPointer captured, HPointer resume);

// respond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
// captured = ( ( key, status ) mask 0x5, ( headers, body ) ) mask 0.
HPointer httpServerRespondBody(HPointer captured, HPointer resume);

// closeServer : Int -> Int -> Task Never ()
// captured = ( serverId, deadlineMs ) mask 0x5.
HPointer httpServerCloseServerBody(HPointer captured, HPointer resume);

// ( "ENOTSUP", "not implemented yet" ) (S mode, captured = unit).
HPointer httpServerNotImplementedBody(HPointer captured);

// takeUpgrade : Int -> Task ( String, String ) ( Int, ( String, String, String ),
//     ( List ( String, List String ), Bool, EpT ) )
// S mode (phase WS5, HttpUpgrade.cpp); captured = the boxed response key.
HPointer httpServerTakeUpgradeBody(HPointer captured);

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP
