# Installation

On Debian based systems you can install the .deb release.
This will install eco to /usr/local/bin:

    sudo dpkg --install eco_0.1.0-RC2_amd64.deb

On other systems or if you want a local install, you can unpack the .zip or .tar.gz relase.
Unpack it into `/usr/local/` or some other place. For the purposes of this guide, we will assume
you unpacked into `/usr/local/` so adjust paths as necessary.

# Run an example

In the distribution there is a `/share/eco/examples` folder. 

Copy that folder to your home dir so you have write access and can build there. Lets build 
and run the hello world example:

    cp -R /usr/local/share/eco/examples ~/
    cd ~/examples/hello
    eco make src/Hello.elm --output=hello

Run it:

    ./hello

# System programs

Eco ships `eco/system`, a package for writing command-line and server programs in Elm: files and
directories, child processes, stdin/stdout/stderr as streams, the terminal, an HTTP server, and
streaming HTTP bodies on top of `elm/http`. Its documentation is in
`/usr/local/share/eco/system/system-kernel-cpp/docs.json`, and it is browsable with
`elm-doc-preview` from a checkout of the Eco repository (`cd system-kernel-cpp && pnpm run docs`).

A program declares `eco/system` as a dependency in its `elm.json` and defines `main` with
`System.defineSimpleProgram` (one-shot programs) or `System.defineProgram` (long-running programs
with a model, `update` and subscriptions):

```elm
module Main exposing (main)

import Stream.Log
import System


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env -> System.endSimpleProgram (Stream.Log.line env.stdout "Hello, world!"))
```

`env` gives the program its arguments (`env.args`, the full argv with the program name first),
its stdin, stdout and stderr as streams, the platform and CPU architecture, and the path of the
executable.

The `examples/system` folder of the distribution holds small complete programs:

    cp -R /usr/local/share/eco/examples/system ~/eco-system-examples
    cd ~/eco-system-examples
    eco make src/Cat.elm --output=cat
    ./cat elm.json
    eco make src/Ls.elm --output=ls
    ./ls src
    eco make src/HttpEcho.elm --output=http-echo
    ./http-echo 8080 &
    curl -d hello http://127.0.0.1:8080/some/path

Notes:

- `eco/system` is resolved from the distribution automatically, like `eco/kernel`; `eco install
  eco/system` adds it to an `elm.json`.
- Use `elm/http` for HTTP requests. `Http.Stream` adds request and response bodies as streams for
  when the data is too large, or arrives too slowly, to hold in memory at once.
- The API is a port of [gren-lang/node](https://github.com/gren-lang/node) and gren-lang/core's
  `Stream`, so its documentation and examples largely carry over (with lists for arrays and `()`
  for `{}`, and no permission values).
