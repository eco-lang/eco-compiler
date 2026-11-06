# Elm inside a C++ program, through ports

`src/Upcase.elm` is an Elm program built as a shared library. `host.cpp` is a C++ program that
loads it, feeds it its standard input and writes what comes back to its standard output, upper
cased. It is small, but it uses each way a C++ host and an Elm program pass data:

| port | direction | what it shows |
|---|---|---|
| `input` | C++ → Elm, Bytes | **asynchronous:** a reader thread emits each chunk as it is read |
| `upcase` → `upcased` | Elm → C++ → Elm, Bytes | **synchronous:** the host answers from inside the call, writing straight into the Elm heap |
| `output` | Elm → C++, Bytes | zero copy: the host writes the Elm value's own bytes to stdout |
| `inputEnded` | C++ → Elm, JSON | a plain `Int`, sent as JSON text |
| `summary` | Elm → C++, JSON | a record, received as JSON text |

## Build and run

Linux, with `eco` and a C++20 compiler on the `PATH`:

    make
    ./upcase < README.md
    ./upcase < README.md > /dev/null      # just the summary, on stderr

`make` runs two commands, which can be run by hand:

    eco make src/Upcase.elm --output=build/libupcase.so
    c++ -std=c++20 -I<eco>/include host.cpp -Lbuild -l:libupcase.so -lm \
        -Wl,-rpath,'$ORIGIN/build' -o upcase

`<eco>` is the directory above the `bin/` that holds `eco`; the headers are in its `include/eco/`.

## How it fits together

The Elm program runs on its own thread, the *eco thread*, which `eco_app_start` creates. Only that
thread touches Elm values. `host.cpp`:

1. **Resolves each port once**, by name, into a typed handle (`eco::BytesInPort input{"input"}`).
   Nothing is looked up by name after that.
2. **Subscribes** to the outgoing ports. A subscriber runs on the eco thread while the program waits,
   and is given the Elm value's bytes in place, valid until it returns. `bytes.retain()` would make a
   copy to keep.
3. **Starts the program**, then starts a reader thread. Each `input.emit(capacity, fill)` there calls
   `fill` to read into a buffer, which the eco thread copies into the Elm heap once. Returning
   `std::nullopt` from `fill` sends nothing, which is how the end of the input is handled.
4. **Answers `upcase` from inside the call.** An emit made in a subscriber writes into a new Bytes
   value in the Elm heap itself, so the chunk is read in place and the answer written in place.
5. **Waits for `summary`**, then stops the program and joins it. Once `eco_app_join` returns, every
   subscriber call has returned too.

Everything sent in is queued and delivered in order, after whatever the program is doing has
finished. So `inputEnded` reaches the program after the last chunk, but can overtake answers to
`upcase` that the program has not yet asked for; `Upcase.elm` counts what is still out for that
reason.

[docs/embedding.md](https://github.com/eco-lang/eco-compiler/blob/main/docs/embedding.md) has the full rules,
and `<eco/eco_embed.h>` documents every function and result code.
