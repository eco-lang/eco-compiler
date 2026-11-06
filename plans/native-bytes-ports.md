---
status: done
updated: 2026-11-06
---

# Bytes over native ports (interim binary channel)

## Problem

Eco accepts `Bytes.Bytes` as a port payload (`Compiler.Canonicalize.Effects.checkPayload`). The JS
backend handles it with the inline `_Json_encodeBytes` / `_Json_decodeBytes` shim, which hands
JavaScript a `Uint8Array` view with no copy. The native backend emits calls to
`Elm_Kernel_Json_encodeBytes` / `Elm_Kernel_Json_decodeBytes`, which no native kernel defines, so
any program with a Bytes port fails to link:

    undefined symbol: Elm_Kernel_Json_encodeBytes

`test/eco-divergence/src/PortBytesEchoTest.elm` reproduces it under the JIT, the AOT shared-library
host and a standalone link.

Native ports carry JSON text, and Bytes must not be turned into text (no base64): the bytes cross
as a binary array with no conversion in either direction.

## Decision

A port whose whole payload is `Bytes` becomes a *bytes port*: the compiler gives it no JSON codec,
and the runtime hands the bytes to and from the host as `(pointer, length)`.

- Outgoing: zero copy. The host callback gets a pointer straight into the Bytes value, valid for the
  duration of the call.
- Incoming: one `memcpy`, into a new heap Bytes on the eco thread. The host hands over its buffer
  with a release function, so the queue holds the host's pointer rather than a second copy.
- Bytes nested inside another payload type (`List Bytes`, `Maybe Bytes`, a record field, a tuple)
  and Bytes anywhere in a program's flags are compile errors on the native target. Flags arrive as
  JSON text, which cannot carry Bytes.

This is an interim interface. A general binary port interface for native code, carrying any payload
in a binary form with Bytes as a native type, is planned for a later version and will replace it.

## Steps

### 1. Compiler

1. `Compiler.IR.Mono.PortRegistration` gains `bytes : Bool`. `Mono.portCarriesBytes incoming
   paramType` says whether a port's parameter type is a bare `Bytes`: the parameter of an outgoing
   port, or the tagger's argument of an incoming one.
2. Both monomorphizers (`Monomorphize.Subst.Specialize.specializePortNode`,
   `Monomorphize.Solver.Translate.specializePortBody`), for a bytes port:
   - outgoing: the wrapper is `\p -> Elm_Kernel_Platform_leaf "name" p`; the encoder is not
     translated.
   - incoming: no decoder spec is enqueued; `decoderSpecId = Nothing`.
3. `GenerateMlir.Functions.generateRegisterPorts` calls the new kernels
   `Elm_Kernel_Platform_registerIncomingBytesPort(name)` and
   `Elm_Kernel_Platform_registerOutgoingBytesPort(name)` for bytes ports.
4. Native-only compile errors, raised on the typed path (`compileTyped`, which only native builds
   run), as new `Compiler.LocalOpt.Error` variants with reports and serialization:
   - a port whose payload contains `Bytes` but is not exactly `Bytes`;
   - a program whose flags type contains `Bytes`.

### 2. Kernel and runtime

1. `elm-kernel-cpp/src/core/PlatformExports.cpp`: the two registration kernels; declared in
   `KernelExports.h` and `RuntimeSymbols.cpp`.
2. `PortRuntime`:
   - `PortInfo.bytes`; `registerIncomingBytes(name)` (no decoder) and `registerOutgoing(name, bytes)`.
   - An outgoing bytes port's onEffects reads each command's Bytes with `byteBufferView` and calls
     the bytes subscribers with the pointer. Nothing allocates on the eco thread between the view
     and the callbacks' return, so the pointer cannot move.
   - Bytes subscribers and buffered bytes are kept apart from JSON ones. Payloads sent before the
     first subscriber are buffered as copies, the one outgoing case that copies.
   - `sendIncomingBytes` queues the host's pointer, length, release function and context. The drain
     copies the bytes into a heap Bytes with `allocByteBuffer`, calls `release(ctx)` on the eco
     thread, and applies the taggers. A null release means the runtime copies the bytes during the
     send.
3. Host API (`eco_embed.h`, `eco_embed.cpp`, the weak copies in `PortRuntime.cpp`):

       typedef void (*eco_port_bytes_callback)(const uint8_t* data, size_t length, void* user);
       int eco_port_subscribe_bytes(const char* port, eco_port_bytes_callback cb, void* user);
       int eco_port_unsubscribe_bytes(const char* port, eco_port_bytes_callback cb, void* user);
       int eco_port_send_bytes(const char* port, const uint8_t* data, size_t length,
                               void (*release)(void* ctx), void* ctx);
       int eco_port_is_bytes(const char* port);   // 1 bytes, 0 JSON, -1 not registered

   A JSON call on a registered bytes port fails (returns 1), and so does a bytes call on a
   registered JSON port. On a failed `eco_port_send_bytes` the release function is not called and
   the caller keeps the buffer.
4. Node addon (`eco_node_addon.cpp`): a bytes port's subscribers receive a `Uint8Array` (one copy
   outgoing, since the pointer is valid only during the callback; the copy becomes the
   `ArrayBuffer`'s backing store). `send` on a bytes port takes a `Uint8Array` or `ArrayBuffer`. It
   is copied once into a malloc'd buffer released with `free`: a JavaScript buffer can be moved,
   collected or written to before the eco thread reads it, so it cannot be lent.

### 3. Tests

- `PortBytesEchoTest` (eco-divergence) passes under the JIT and AOT hosts, which echo bytes ports
  through `eco_port_subscribe_bytes` / `eco_port_send_bytes`.
- A test for the empty Bytes and a large buffer (the pinned large-object path) round trip.
- Compile-error tests in eco-divergence for nested Bytes in a port and Bytes in flags.
- The Node addon test script runs `test/embed/embed_host.js`, a parity host, against the JS
  backend build and the addon build of three fixtures (`test/embed/*Service.elm`), and requires
  identical transcripts: rich record flags, JSON flags of every shape, the ways to give a `()`
  program flags, a round trip of every JSON payload type, every Bytes form out and every value
  `send` takes back in, rejected sends, unsubscribe, a leak soak (negative controls: leaking either
  direction's copy adds the full 600 MiB and fails it), and `app.stop()`.
- The JSON port echo tests stay green.

### 4. Documents

- `design_docs/theory/runtime/scheduler-and-services.md` ("Ports and embedding") records the bytes
  channel and that it is interim.
- `design_docs/invariants.csv`: amend PORT_002, PORT_003, PORT_004, PORT_006 and PORT_007, and add
  PORT_008 for the bytes channel.

## Parity findings (2026-11-06)

Running the same host against the JS backend and the Node addon found two addon bugs, both fixed:

- **Lost deliveries.** Node could exit with a value the program had already sent to a subscriber
  still undelivered: an idle report could release the addon's keepalive before the queued delivery
  ran, or a stale idle report could undo a `send`'s reference. The JS backend never loses one. The
  addon now holds the loop while a delivery is queued or the program has busy holds, read at once
  through the new `eco_app_is_busy`. The older hosts pinned Node's loop themselves, which hid it.
- **Typed arrays.** The addon's bytes `send` took any typed array; the JS backend takes only a
  `Uint8Array`, an `ArrayBuffer` or a `DataView`. The addon now refuses the rest, as JS does.

And four divergences; D1 to D3 are now fixed, and D4 is left as it is (the aim is to move hosts off Node); `embed_host.js` asserts each mode's side, so a fix fails the
check until it is updated:

- **D1, batched commands (fixed 2026-11-06).** Elm 0.19.1 hands each effect manager a `Cmd.batch`'s
  commands last first (it conses them); the native Task, port and Http managers handled them first
  first. They now handle their commands (and the ports and Http their subscriptions) last first,
  at no cost: they gather the list into rooted slots and walk it backwards. A global reversal in
  `dispatchEffects` was tried first and backed out: the Time and eco/system managers, written in
  C++ against the gather-order lists, already matched Elm and broke. PORT_005 records the rule.
- **D2, bad flags (fixed 2026-11-06).** JS `init` throws a catchable `Error`; the addon aborted the
  whole process. Now `eco_app_start` checks the flags against a descriptor of the flags type
  before it starts anything and returns `ECO_APP_ERR_BAD_FLAGS`; the addon throws the JS message,
  and `init` may be retried (PORT_009).
- **D3, a send that does not decode (fixed 2026-11-06).** JS `send` throws at once; the addon's
  `send` returned, and the process aborted when the eco thread decoded the value. Now
  `eco_port_send` checks the JSON against the port's payload descriptor on the sending thread and
  returns 2; the addon throws (PORT_009). The checker (`eco_json_check_payload`) uses the decoders'
  own parser and rules; the eco thread's abort stays as a backstop.
- **D4, Bytes sent in.** On JS the program's `Bytes` alias the sender's buffer, so a write to it
  after the send shows through to Elm; the addon copies at the send, keeping Elm values immutable.

Also found and fixed: native `Platform.sendToApp` and `sendToSelf` sent their message when the kernel
was called, not when the returned Task ran (KERNEL_TASK_IO_001). They now return binding Tasks, as
elm/core's do; pinned by the `platform-services/PS13` and `PS14` unit tests.

