# Embedding a program in a C or C++ host

An Eco program can be built as a library and run inside another application, the *host*. The host
starts the program, and the two talk through the program's Elm ports. This page covers the headers,
the threading rules, and the C and C++ APIs for ports, Bytes ports in particular.

`examples/cpp-ports` in the distribution is a complete, small example: a C++ program that feeds its
standard input to an Elm program and writes out what comes back, using each kind of port described
here.

## Building

Give `eco make` an output ending in `.so` (or `.node` for a Node.js addon):

    eco make src/Main.elm --output=build/libmain.so

The headers are installed with Eco, in `include/eco/` next to the `bin/` that holds `eco`
(`/usr/local/include/eco/` for the `.deb`):

| header | for |
|---|---|
| `<eco/eco_embed.h>` | C (C99), and the ABI everything else is built on |
| `<eco/eco_embed.hpp>` | C++20: typed port handles, RAII subscriptions, spans and lambdas |

    c++ -std=c++20 host.cpp -I<eco>/include build/libmain.so -lm -o host

The library leaves the math library to the host, so link `-lm`.

## The model

The program runs on its own thread, the *eco thread*, which `eco_app_start` creates. Only the eco
thread runs Elm code or touches Elm values. Hosts call in from any thread:

- **Outgoing ports** (`port out : T -> Cmd msg`) call the host's subscribers on the eco thread, while
  the program waits at the port. A callback should return promptly.
- **Incoming ports** (`port in : (T -> msg) -> Sub msg`) take a payload from any host thread. It is
  queued, and the eco thread delivers it once the current work has finished.
- **No garbage collection runs during a callback.** Anything a callback is given stays where it is
  for the whole call.

A port whose whole payload is `Bytes` is a *bytes port* and carries raw bytes. Every other port
carries JSON text, checked against the port's type where the host sends it.

## Port handles

Resolve a port's name once, then use the handle. A handle is valid for the life of the process and
may be made before the program has started:

```c
eco_port* frames = eco_port_get("frameOut");
int kind = eco_port_kind(frames);   // ECO_PORT_OUT_BYTES once the program has registered it
```

In C++ the kind is part of the type, checked when the handle is made:

```cpp
const eco::BytesOutPort frameOut{"frameOut"};
const eco::BytesInPort  frameIn{"frameIn"};
const eco::JsonOutPort  logOut{"logOut"};
const eco::JsonInPort   commands{"commands"};
```

## Bytes out: borrowed, and retained

A bytes subscriber gets the bytes of the Elm value itself, at no copy. They are valid until the
callback returns. To keep them longer, retain them: that makes a refcounted copy, which may be kept
anywhere and released on any thread.

```cpp
std::vector<eco::OwnedBytes> pending;

auto sub = frameOut.subscribe([&](const eco::BorrowedBytes& bytes) {
    process(bytes.view());                  // zero copy, valid during the call
    pending.push_back(bytes.retain());      // a copy that outlives the call
});
// `sub` unsubscribes when it is destroyed; the lambda is deleted once no call can reach it.
```

Don't keep the pointer or span you are given. Keep an `OwnedBytes`.

## Bytes in: emit, or send a buffer

An **emit** calls your fill function to write the payload. Made inside an outgoing callback, it
writes straight into a new Bytes value in the program's heap: zero copy.

```cpp
auto sub = frameOut.subscribe([&](const eco::BorrowedBytes& in) {
    frameIn.emit(in.size(), [&](std::span<std::byte> out) {
        transform(in.view(), out);          // reads the Elm heap, writes the new value in place
        return out.size();                  // how many bytes were written
    });
});
```

Made from any other thread, an emit fills a buffer that the eco thread copies in, once:

```cpp
std::thread reader([&] {
    while (running) {
        frameIn.emit(65536, [&](std::span<std::byte> out) -> std::optional<std::size_t> {
            ssize_t n = ::recv(sock, out.data(), out.size(), 0);
            if (n <= 0) return std::nullopt;   // nothing is sent
            return static_cast<std::size_t>(n);
        });
    }
});
```

For a buffer that something else fills later, such as an asynchronous read, **send** it when it is
ready. Ownership passes to Eco:

```cpp
auto buffer = std::make_shared<eco::Buffer>(65536);
socket.asyncRead(buffer->writable(), [buffer](std::size_t n) {
    buffer->setSize(n);
    frameIn.send(std::move(*buffer));
});
```

The C forms are `eco_port_emit(port, capacity, fill, user)` and
`eco_port_send_buffer(port, data, length, release, ctx)`. The C header documents each result code.

## JSON ports

```cpp
auto sub = logOut.subscribe([](std::string_view json) { std::puts(std::string(json).c_str()); });
if (commands.send(R"({"op":"start"})") == eco::SendResult::Rejected) std::puts(eco_last_error());
```

## Rules to remember

- A callback runs on the eco thread and the program waits for it. Do slow work elsewhere.
- Borrowed bytes are valid only during the callback. Use `retain()` to keep them.
- An exception must not leave a C++ callback. If one does, the process stops with a message.
- The scheduler's idle hook (`eco_set_idle_hook`) must not send, emit or stop the program.
- Call `eco_app_join` from a host thread, never from a callback.
