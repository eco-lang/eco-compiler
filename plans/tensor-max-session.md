---
status: done
updated: 2026-11-14
---

# eco-lab/tensor: one package, MAX host included

The package is for Modular MAX. Today an app talks to MAX through `spikes/max/bridge/Bridge.elm`
(a port module outside the package, 9 ports, request ids and byte offsets handled by each app) and
`spikes/max/mnist/host/max_bridge.cpp` (the generic C++ host every model app links). This plan folds
both into the package `spikes/max/tensor`:

- `Graph.Max` becomes `Max` (Device, `toBytecode`, `toGenericText`, `…On`), unchanged otherwise.
- The bridge becomes `Max.Session`: a typed session over two ports the app declares and passes in
  (a package cannot declare ports, and only eco native apps can declare `Bytes` ports, so only they
  can use the host backend), plus an in-Elm backend that runs the same commands with `Tensor.Eval`.
- `models/lib/src/Checkpoint/Safetensors.elm` becomes `Max.Safetensors`.
- The host moves to `tensor/host/max_host.cpp`; apps link it as the spike Makefile does now.
- `log` leaves the package (an app may declare `port logOut : String -> Cmd msg`; the host prints
  it if present). Ending the process is the host's business, so `finish` stays, as a command.

## Wire protocol (version 2)

Two ports, names fixed (the host binds them by name):

    port maxOut : Bytes -> Cmd msg              -- every request, in order
    port maxIn : (Bytes -> msg) -> Sub msg      -- every reply

Every message starts with a 16-byte header of four little-endian u32: `id`, `code`, `status`, `0`.
Tensors are padded to 16 bytes. Lengths and offsets in payloads are two u32, low then high.

Requests (`status` 0). The codes 1–9 keep today's layouts:

| code | request | payload after the header | reply |
|---|---|---|---|
| 1 | run | graph `id`; the fed inputs in graph order, each padded | `ran` |
| 2 | put | `NAME\0` bytes | none |
| 3 | get | `NAME` | `got`: the buffer's bytes (none if never set) |
| 4 | save | `NAME\0PATH` | none |
| 5 | loadInto | `NAME\0PATH` | none |
| 6 | sequence | each command as `[u32 length][command]`, run in order | per command |
| 7 | loadRangeInto | `NAME\0` offset length `PATH` | none |
| 8 | drop | `NAME` | none |
| 9 | loadRange | offset length `PATH` | `loaded`: the bytes |
| 10 | compile | graph `id`; `in …\nout …\n` spec lines as today, then MLIR (bytecode or text) | `compiled` |
| 11 | load | `PATH` | `loaded`: the whole file |
| 12 | finish | u32 exit code | none; the host stops the program and exits with it |

Compile runs on a worker thread as today. A `run` of a graph whose compile is still in flight waits
for it, so `compile` and `run` may be sent together; a `run` of a graph whose compile failed is a
host failure.

Replies carry the request's `id` and `code`. `status` 0 is success. `status` 1 is failure, with a
UTF-8 message as the payload: a failed compile (MAX's error text) and a failed `load`/`loadRange`
(cannot open, out of range). Other host failures (a missing resident, bad run inputs) stay fatal,
printed and `_Exit(1)`, as today.

## Elm API (sketch)

    Max.Session.Ports msg = { send : Bytes -> Cmd msg, receive : (Bytes -> msg) -> Sub msg }
    host : Ports msg -> (Message -> msg) -> Session msg     -- eco native
    inElm : (Message -> msg) -> Session msg                -- anywhere: Tensor.Eval
    subscriptions : Session msg -> Sub msg
    update : Message -> Session msg -> ( Session msg, Event )
    compile / compileWith { format, device } : Graph -> Session msg -> ( Session msg, Handle, Cmd msg )
    send : List Command -> Session msg -> ( Session msg, Cmd msg )
    run : Handle -> List ( String, Input ) -> Command      -- fed inputs by name; Input from Bytes or Value
    put, get, save, loadInto, loadRangeInto, drop, load, loadRange, finish
    type Event = Compiled Handle | CompileFailed Handle String | Ran Handle Outputs
               | Got String Bytes | Loaded String Bytes | Failed String
    Outputs: by name, as Values (Tensor.Eval.Value), floats, ints or raw Bytes

In-Elm backend: residents are kept in the session as bytes, decoded by the graph's slot dtypes for a
run and encoded back from its resident outputs; `save`/`loadInto` use files the session itself
saved; real files (`load`, `loadRange`, `loadRangeInto`, `loadInto` of an unsaved path) give
`Failed`; replies arrive through `Task.perform`, so app code is the same for both backends.

## Phases and gates

1. Package: `Max` rename, `Max.Session` (both backends, bytes↔values decoding for every dtype),
   `Max.Safetensors`, tests (protocol encoding and decoding, in-Elm sessions training a small model),
   docs per the commenting standard, README section. Gate: suite green, docs build, graph snapshot
   byte-identical (`make compare-graphs BASE=…`).
2. Host: `tensor/host/max_host.cpp` speaking protocol 2; spike Makefile builds every `*_bridge` from
   it. Gate: builds.
3. Apps: Mnist, CharLm, ApiCheck, GptBench and the snapshot/opcheck/tensor-e2e callers on the new
   modules; `spikes/max/bridge/` and `models/lib/src/Checkpoint/` removed. Gate (after
   `. spikes/max/env.sh`): run-mnist sgd/lora/cnn (RELOAD=true too), run-charlm, check-apicheck,
   check-ops, check-api, check-tensor-native, grad-drag tests and smoke.
