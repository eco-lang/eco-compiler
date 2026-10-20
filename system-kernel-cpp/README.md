# eco/system

POSIX-style system programming for Eco programs: files, processes,
streams, the terminal, HTTP servers, sockets and WebSockets, from Elm.

`eco/system` is the public system API for programs compiled with the Eco compiler. (Eco's own
`eco/kernel` package is the compiler's internal IO layer and is not meant for applications.) For
an HTTP client, use [elm/http](https://package.elm-lang.org/packages/elm/http/latest/);
`Http.Stream` adds streaming request and response bodies on top of it.

> **Status:** every module is implemented for Eco's native backend and tested on Linux. The macOS
> code paths are written but not yet tested. Windows is not supported yet: the package is meant to
> build there (untested), with most IO functions reporting `ENOTSUP` or stopping with a "not
> supported on Windows yet" message. On the JS target (Node), every module works and passes the
> same tests as the native backend, with small documented differences (for example, error
> descriptions use Node's wording). See `plans/eco-system-library.md` in the Eco repository for the design and the
> remaining follow-ups.

## Modules

- `System`: the program environment (args, start time, stdin/stdout/stderr, platform), simple
  programs, exit codes and signals. A program is a `Platform.Program System.Environment model
  msg`: `System.program` for a program with a model, `System.simpleProgram` for one task.
- `Stream`: readable and writable streams, reading lines, piping, and best-effort logging.
- `Stream.Transformation`: building transformations, text encoding and compression.
- `FileSystem`, `FileSystem.Handle`, `Path`: files, directories, links, metadata, durable and
  exclusive writes, file handles for random access, and paths.
- `ChildProcess`: running and spawning child processes.
- `Terminal`: terminal size, raw mode, the window title and resize events.
- `Http.Server`: an HTTP server (HTTP/1.1 with keep-alive, request limits and timeouts, HTTPS,
  HTTP/2 over TLS, and WebSocket upgrades) and its responses. `setBodyAsHtml` answers with a page
  built with elm/html, serialized straight into the response.
- `Html.Dom`: a transparent view of `Html`/`Svg` values and their HTML serialization.
- `Http.Stream`: streaming request and response bodies for elm/http (Node and native only; it does
  not run in the browser).
- `Socket`, `Socket.Address`, `Socket.Tcp`, `Socket.Unix`, `Socket.Udp`, `Socket.Tls`: TCP, Unix
  domain and TLS connections (TLS on OpenSSL 3 natively), UDP datagrams, IPv4/IPv6 addresses and
  name lookup. Native socket IO runs non-blocking on one shared event loop (epoll on Linux, kqueue
  on macOS).
- `WebSocket`: WebSocket clients (`ws://`, `wss://`, optionally over HTTP/2) and servers (RFC 6455)
  on accepted `Socket` connections and on `Http.Server` (`Http.Server.upgradeRequest` over HTTP/1.1,
  plain or TLS, and over HTTP/2: RFC 8441), with whole or streamed messages, a ping/pong heartbeat,
  and permessage-deflate compression (RFC 7692; on by default, without context takeover). Checked
  locally against the Autobahn|Testsuite (`test/conformance/` in the Eco repository).

## Example

```elm
module Main exposing (main)

import Stream
import System


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env -> Stream.logLine "Hello, world!" env.stdout)
```

## License

BSD-3-Clause; see `LICENSE`. This package is derived from gren-lang/node and gren-lang/core
(Copyright 2022-present The Gren CONTRIBUTORS), which are themselves derived from Elm
(Copyright 2014-2022 Evan Czaplicki).

### Bundled third-party code

The native (C++) implementation compiles these libraries into its archives (they are downloaded
at build time, pinned by SHA-256, and are not part of this repository):

- **llhttp** 9.2.1 (`Http.Server`, HTTP/1.1 parsing), MIT License,
  Copyright Fedor Indutny, 2018. <https://github.com/nodejs/llhttp>
- **nghttp2** 1.70.0 (`Http.Server`, HTTP/2, and the `WebSocket` client over HTTP/2; the library
  sources only), MIT License,
  Copyright (c) 2012, 2014, 2015, 2016 Tatsuhiro Tsujikawa and
  Copyright (c) 2012, 2014, 2015, 2016 nghttp2 contributors. <https://nghttp2.org>

Both are distributed under the MIT License:

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software
    and associated documentation files (the "Software"), to deal in the Software without
    restriction, including without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or
    substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
    BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
    DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
