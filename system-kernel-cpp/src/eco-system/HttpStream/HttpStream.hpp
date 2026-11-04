//===- HttpStream.hpp - eco/system kernel module HttpStream ---------------===//
//
// Elm's `Http.Stream.send` makes an HTTP request whose body may be a stream
// and answers with the response head while the response body is still
// arriving, as a stream. This component is the Elm-facing half of that: it
// turns the Elm request into an `HttpRequestSpec`, starts a transfer on
// `HttpStreamService` (HttpTransfer.hpp, which runs the transfer itself), and
// turns the transfer's one answering `HttpEvent` back into an Elm value.
//
// A request body is one of three kinds: none (0), Bytes (1), or a stream
// (2), given as the id of a Readable in the stream table. A stream body is
// piped into the transfer's upload side. A response body is handed to Elm as
// a new Readable over the transfer's download side.
//
// The task never fails. Every outcome, a transport failure included, is a
// success value whose first field is the `HttpOutcome` number.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_STREAM_HTTP_STREAM_HPP
#define ECO_SYSTEM_HTTP_STREAM_HTTP_STREAM_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

/// Runs `Http.Stream.send` as the body of a `makeAsyncBinding`: starts the
/// request described by `captured`, and later resumes `resume` with the
/// result.
///
/// `captured` is `( ( request, headers ), ( body, discardNon2xx ) )`, all
/// three tuples with every slot boxed. `request` is
/// `( method, url, timeoutMs )`, `headers` a list of elm/http `Header`
/// values, `body` is `( bodyKind, contentType, ( bytes, streamId ) )`, and
/// `discardNon2xx` a Bool. The Int slots may be boxed or unboxed. A
/// negative timeout is taken as 0, meaning none.
///
/// The task succeeds with `( kind, badUrl, ( ( status, statusText, url ),
/// headers, bodyStreamId ) )`, where `kind` is the `HttpOutcome` number,
/// `badUrl` the request's URL for BadUrl and otherwise empty, and
/// `headers` the response's fields as `( name, value )` pairs in arrival
/// order, names lower-cased. For BadStatus and GoodStatus `bodyStreamId` is a
/// new Readable over the response body; for the other kinds it is -1 and the
/// head fields are empty or 0. A stream body whose Readable is already being
/// read (a parked read, a pipe or a subscription reader) resumes the task at
/// once with NetworkError and sends nothing. A stream id that names no
/// stream is not rejected: the request is sent with an empty body.
///
/// Returns the kill handle, which aborts the transfer, or `unit` when the
/// task was resumed at once. Must be called on the eco thread.
HPointer httpStreamSendBody(HPointer captured, HPointer resume);

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_STREAM_HTTP_STREAM_HPP
