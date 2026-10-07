# eco/system

POSIX-style system programming for Eco programs: files, processes,
streams, the terminal and HTTP servers, from Elm.

`eco/system` is the public system API for programs compiled with the Eco compiler. (Eco's own
`eco/kernel` package is the compiler's internal IO layer and is not meant for applications.) The API
is a port of [gren-lang/node](https://github.com/gren-lang/node), together with the `Stream` module
from [gren-lang/core](https://github.com/gren-lang/core), adapted to Elm: lists instead of arrays,
`()` instead of `{}`, and no permission tokens. For an HTTP client, use
[elm/http](https://package.elm-lang.org/packages/elm/http/latest/); `Http.Stream` adds streaming
request and response bodies on top of it.

> **Status: API preview.** Every function is a stub until the implementation phases land
> (see `plans/eco-system-library.md` in the Eco repository).

## Modules

| Module | Purpose |
|---|---|
| `System` | Program definitions, the environment (args, stdin/stdout/stderr, platform), exit codes and signals |
| `Stream`, `Stream.Log` | Readable and writable streams, transformations, compression, and simple logging |
| `System.File`, `System.File.Path`, `System.File.FileHandle` | Files, directories, links, metadata, file handles and paths |
| `System.Process` | Running and spawning child processes |
| `System.Terminal` | Terminal size, raw mode and resize events |
| `Http.Server`, `Http.Server.Response` | An HTTP server |
| `Http.Stream` | Streaming request and response bodies for elm/http |

## Example

```elm
module Main exposing (main)

import Stream.Log
import System


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env -> System.endSimpleProgram (Stream.Log.line env.stdout "Hello, world!"))
```

## License

BSD-3-Clause; see `LICENSE`. This package is derived from gren-lang/node and gren-lang/core
(Copyright 2022-present The Gren CONTRIBUTORS), which are themselves derived from Elm
(Copyright 2014-2022 Evan Czaplicki).
