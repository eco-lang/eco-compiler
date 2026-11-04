// The compiler fetches packages over HTTP, and this component is the eco kernel's HTTP client: a request that
// returns a String body (`Eco.Http.fetch`) and the download of a ZIP archive, which is unpacked in memory
// (`Eco.Http.getArchive`).
//
// Each function returns a Task binding, so the request is sent each time the Task is run, not when the function is
// called. The transfer runs on the runtime's HTTP worker thread (`Elm::Platform::HttpService`), and the thread that
// runs the Task carries on with other work meanwhile. When the response arrives, the eco thread builds the result
// (and, for an archive, computes its SHA-1 and unzips it) and resumes the Task.
//
// Neither Task fails. Each succeeds with an Elm `Result` whose `Err` describes a failed transfer, a non-2xx status
// (`fetch` only) or an unreadable archive. Killing either Task does not cancel its request.
//
// The arguments and results are Elm values as `uint64_t` words (see `ExportHelpers.hpp`). Both functions must be
// called on the eco thread, and each is a GC point.

#ifndef ECO_HTTP_HPP
#define ECO_HTTP_HPP

#include <cstdint>

namespace Eco::Kernel::Http {

/// Returns a Task that sends a request with the String `method` to the String `url`, with `headers`, a List of
/// `(name, value)` String tuples, and no body.
///
/// The Task succeeds with `Ok body`, the response body as a String, for a status from 200 to 299. Any other status
/// gives `Err (status, text)`, where `text` is the response's status text or, when that is empty, as
/// `HttpService::Result::statusText` always is, `HTTP <status>`. A transfer that got no response gives
/// `Err (0, message)`, with message `Request timed out`, `Bad URL` or `Network error`. A `POST` is sent with a
/// `Content-Length` of zero.
uint64_t fetch(uint64_t method, uint64_t url, uint64_t headers);
/// Returns a Task that downloads the ZIP archive at the String `url` with a `GET`.
///
/// The Task succeeds with `Ok (sha, entries)`, where `sha` is the lower-case hex SHA-1 of the downloaded bytes and
/// `entries` is a List of `(relativePath, content)` String tuples in archive order. An entry whose name ends in
/// `/` has empty content, and an entry that has no name or cannot be opened is left out. An entry that reads short
/// keeps its recorded size, the unread part filled with zero bytes. The HTTP status is not checked: any response
/// body is treated as the archive. The Task succeeds with `Err message` when the transfer fails (the messages are
/// those of `fetch`) or the body cannot be opened as a ZIP archive.
uint64_t getArchive(uint64_t url);

} // namespace Eco::Kernel::Http

#endif // ECO_HTTP_HPP
