module Max.Session exposing
    ( Session, Ports, host, inElm
    , Message, subscriptions, update, Event(..)
    , Handle, compile, Format(..), compileWith
    , Command, send
    , run, Input, fromBytes, fromValue, fromFloats, fromInts
    , put, get, save, loadInto, loadRangeInto, drop
    , load, loadRange
    , finish
    , Outputs, value, floats, ints, bytes
    )

{-| A program that trains or runs a model needs something to compile its graphs, run them over and
over, and keep data such as the model's parameters from one run to the next. A session is that,
seen from Elm: the program compiles graphs into it and sends it commands, and it answers with
events.

A session has one of two _backends_, and the program's code is the same for both:

  - **The host** (`host`): MAX compiles and runs the graphs, in the C++ host program that comes
    with this package, which the compiled Elm program is linked with. The two talk over two ports
    carrying `Bytes`, which the program declares and hands to the session (`Ports`). Only an eco
    native program can declare ports that carry `Bytes`, so only such a program, linked with the
    host, can use this backend.
  - **Elm** (`inElm`): `Tensor.Eval` runs the graphs. This works wherever Elm runs, in tests or a
    browser; it reads and writes no files, and it is as slow as `Tensor.Eval`.

The backends differ most in how a failure shows. On the in-Elm backend every command that fails
is answered with a `Failed` event. The host itself answers a failure only of a compile, a `load` or
a `loadRange`; any other failure it detects, such as a run whose resident buffer is missing, ends
the program with no event, as `Event` describes.

A _resident buffer_ is a named buffer of bytes that the backend keeps from one run to the next,
such as a model's parameters: a graph's input whose role is `Graph.Resident n` reads the buffer
`n`, and an output with that role replaces it after the run. Every other input and output is
_fed_: a run is given only the graph's fed inputs, and hands back only its fed outputs. `put` fills
a buffer from Elm, `get` reads one back, `save` writes one to a file, and `loadInto` and
`loadRangeInto` fill one from a file without the bytes passing through Elm.

A run reads a buffer as a tensor in the package encoding that `Train` states, the encoding of
`Train.initial` and `Param.initial`, so their first contents can be put as they come. Nothing
checks a buffer's bytes against a dtype: a buffer holds whatever bytes it was given, and a run
checks only that it holds as many bytes as the input's dtype and shape take.

    ( session1, step, compileCmd ) =
        Session.compile stepGraph session0

    ( session2, putCmd ) =
        Session.send
            (List.map (\( n, b ) -> Session.put n b) (Train.initial params optimizer 1))
            session1

Commands given to one `send` are run in the order listed. The answers come back as `Message`s:
pass every `Message` to `update`, and act on the `Event` it returns.

    case Session.update message model.session of
        ( session, Session.Ran _ outputs ) ->
            -- the loss of a Train.step graph
            ( { model | session = session, loss = Session.floats "loss" outputs }, Cmd.none )

        ( session, _ ) ->
            ( { model | session = session }, Cmd.none )

On the host backend the host's replies arrive through `subscriptions`. The answers a session makes
itself are queued: the `Cmd` that `compile`, `compileWith` or `send` returns hands out as many of
the oldest queued answers as that call queued, so they reach `update` only as those `Cmd`s are
performed, and always in the order they were made. On the in-Elm backend every answer is made so;
on the host backend, the answer to a compile that `Max` refuses and to a `send` refused before
anything is sent.

A session is a value in the program's model, and every function that compiles or sends returns the
session to keep in its place.


# Sessions

@docs Session, Ports, host, inElm


# Replies

@docs Message, subscriptions, update, Event


# Graphs

@docs Handle, compile, Format, compileWith


# Commands

@docs Command, send


## Running a graph

@docs run, Input, fromBytes, fromValue, fromFloats, fromInts


## Resident buffers

@docs put, get, save, loadInto, loadRangeInto, drop


## Files

@docs load, loadRange


## Ending the program

@docs finish


# Outputs

@docs Outputs, value, floats, ints, bytes

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict
import Graph exposing (Graph)
import Max
import Max.Internal.Elements as Elements
import Max.Internal.Protocol as Protocol
import Max.Internal.Session as S
import Task
import Tensor.Eval as Eval exposing (Data(..), Value)


{-| A session: the graphs compiled in it and the requests it is waiting on, with the backend that
runs them and keeps its resident buffers. `msg` is the program's message type, in which the
session's answers reach the program.

Make one with `host` or `inElm`. It is a value: keep the one each function returns. An older one
knows nothing of the graphs compiled and the requests sent since, and on the in-Elm backend it holds
the resident buffers and saved files as they were, so a command sent with it runs on those.

-}
type alias Session msg =
    S.Session msg


{-| The two ports a program declares for the host backend, with these names, which the host looks
for:

    port maxOut : Bytes -> Cmd msg

    port maxIn : (Bytes -> msg) -> Sub msg

and hands to `host` as `{ send = maxOut, receive = maxIn }`. `send` carries every request to the
host, and `receive` every reply from it. A program that does not declare `maxIn` is ended by the
host when it has its first reply to give.

-}
type alias Ports msg =
    { send : Bytes -> Cmd msg, receive : (Bytes -> msg) -> Sub msg }


{-| Creates a session on the host backend, over the program's two ports, whose answers reach the
program as `toMsg` of a `Message`. It needs an eco native program linked with the host that comes
with this package.

Two host sessions over one host are not kept apart. Each one whose `subscriptions` the program
uses receives every reply. Each numbers its
graphs from 1, and the host knows a graph only by its number, so a compile from one replaces the
other's graph with the same number.

Names and paths go to the host as they are, with nothing escaped. A buffer name holding a zero
byte is cut short at it by `put`, `save`, `loadInto` and `loadRangeInto`, but not by `get` or
`drop`, and the rest of the name is read as the start of what follows it: the bytes `put` stores,
the path, or the offset and length of `loadRangeInto`. An input's or output's name, or a resident
name, holding ASCII whitespace or a colon does not reach the host as written, and the host answers
its compile with `CompileFailed`; the one exception is a resident name whose part after the
whitespace reads as a spec of its own, which the host takes for one more input or output.

-}
host : Ports msg -> (Message -> msg) -> Session msg
host ports toMsg =
    S.new (S.Host ports) toMsg


{-| Creates a session on the in-Elm backend, whose answers reach the program as `toMsg` of a
`Message`. It starts with no resident buffers and no saved files.

The backend runs every graph with `Tensor.Eval` (see there for how its results can differ from
MAX's). A run decodes each resident input from its buffer by the input's dtype and shape, and
encodes each resident output back into its buffer in the package encoding. A resident output of
dtype `f32` is therefore rounded to `f32` between runs, as MAX's would be. Fed
outputs are not rounded, as `value` describes.

`save` and `loadInto` work over files the session itself saved, kept in the session by path; no
file is read or written. `load`, `loadRange`, `loadRangeInto`, and `loadInto` of a path the session
did not save, give `Failed`.

-}
inElm : (Message -> msg) -> Session msg
inElm toMsg =
    S.new (S.InElm { residents = Dict.empty, files = Dict.empty, finished = False }) toMsg


{-| A message for a session: a reply from the host, or the signal to hand out the oldest answer the
session made itself. A program does nothing with it but pass it to `update`, with the session it
came from.
-}
type alias Message =
    S.Message


{-| Creates the subscription to the host's replies: on the host backend, every message on the
`receive` port, as a `Message`. The in-Elm backend has nothing to subscribe to, and gives
`Sub.none`.
-}
subscriptions : Session msg -> Sub msg
subscriptions (S.Session s) =
    case s.backend of
        S.Host ports ->
            ports.receive (S.Reply >> s.toMsg)

        S.InElm _ ->
            Sub.none


{-| Reads a `Message` and returns the session after it and the `Event` it stands for.

Each `Message` gives exactly one `Event`. The answers a session makes itself come out in the order
it made them. On the host backend, those answers and the host's replies come in no defined order
relative to each other.

A `Message` does not say which session it is for, so it must be passed to the session it came from.
Passed to another session, it is read as that session's own: a reply from the host is taken to be
about that session's graph or request with the same number, since those are numbered from 1 too,
and the signal to hand out an answer takes that session's oldest. A reply that matches no graph the
session holds and no request it is waiting on gives `Failed`, except a compile reply, which is not
checked: it gives `Compiled` or `CompileFailed` for the handle with its number.

-}
update : Message -> Session msg -> ( Session msg, Event )
update message session =
    Tuple.mapSecond event <|
        case message of
            S.Reply b ->
                S.hostReply b session

            S.Next ->
                S.pop session


{-| What a session answers, one for each `Message`.

`Compiled` says that the graph is compiled and can be run. On the in-Elm backend it answers every
compile `Max` does not refuse for the device, since `Tensor.Eval` finds a graph's problems only
when it runs it. On the host a compile reply is not matched against the session's graphs: one with
a number the session never gave a graph, or meant for another session on the same host (see
`host`), still gives `Compiled` or `CompileFailed` for the handle with that number.

`CompileFailed` says that the graph cannot be compiled: on the host, with MAX's message, or the
host's when it cannot read a name in the graph or write the graph's file; on either
backend, before anything is sent, with the reasons `Max` gives for not writing the graph for its
device, one per line. A run of a graph `Max` refused gives `Failed`. A run of a graph MAX failed to
compile gives `Failed` once its `CompileFailed` has been passed to `update`; sent before that, it
reaches the host, which ends the program.

`Ran` carries the fed outputs of one run of a graph. The resident outputs are in their buffers.

`Got` carries the bytes of a resident buffer, under the name `get` asked for. When no buffer has
that name, because it was never set or was dropped, it carries no bytes, as for an empty buffer.

`Loaded` carries bytes of a file, under the path `load` or `loadRange` asked for. Only the host
backend gives it.

`Failed` carries a message. It answers a `load` or `loadRange` that fails for a reason those
commands give, with a message naming the command and the path, such as
`"load: cannot open data/x.bin"`. It also answers a `send` refused on the host before anything was
sent (see `send`), and any command the in-Elm backend could not run. A reply from the host that
the session cannot match to a graph it holds or a request it is waiting on gives `Failed` too, with
a message starting `"Max.Session: "`, unless it is a compile reply; so does the signal to hand out
an answer when the session has none waiting.

On the host backend every other failure the host detects ends the program with no event: the host
prints a line starting `HOST` and exits with code 1. These failures include a run of a graph whose
compile failed or whose compile the host has not received; a run whose resident input's buffer is
missing or does not hold exactly as many bytes as the input's dtype and shape take; a run MAX
cannot execute; a `run` or `get` whose reply would be 4 GiB or more; a `save` or `drop` of a
buffer that does not exist; a `save` to a file that cannot be written; a `loadInto` of a file that
cannot be opened or read; and a `loadRangeInto` of a file that cannot be opened or read, or of a
range past its end.

On the host a compile finishes on a thread of its own: its `Compiled` comes before any `Ran` of
that graph, and may come before or after any other reply. Runs are answered in the order they were
sent, on both backends, and that order is the only thing that tells two `Ran`s of one graph apart.

`Finished` carries the exit code of a `finish` run by the in-Elm backend, which cannot stop the
program. On the host, `finish` stops the program and nothing answers it. On both backends nothing
after a `finish` is answered.

-}
type Event
    = Compiled Handle
    | CompileFailed Handle String
    | Ran Handle Outputs
    | Got String Bytes
    | Loaded String Bytes
    | Failed String
    | Finished Int


{-| Returns the `Event` an internal reply stands for, constructor for constructor.
-}
event : S.Ev -> Event
event ev =
    case ev of
        S.ECompiled h ->
            Compiled h

        S.ECompileFailed h m ->
            CompileFailed h m

        S.ERan h o ->
            Ran h o

        S.EGot n b ->
            Got n b

        S.ELoaded p b ->
            Loaded p b

        S.EFailed m ->
            Failed m

        S.EFinished c ->
            Finished c


{-| A session's name for a graph given to `compile` or `compileWith`, which `run` takes and
`Compiled`, `CompileFailed` and `Ran` carry to say which graph they are about. Each call of
`compile` or `compileWith` on the session the previous call returned gives a new handle, even for
a graph compiled before.

Each session numbers its handles on its own, from 1, so a handle from another session can equal
one of this session's, and then names this session's graph with that number, if it holds one.

-}
type alias Handle =
    S.Handle


{-| How the host backend sends a graph's MLIR: as MLIR bytecode, or as MLIR's generic op text (see
`Max`). The in-Elm backend sends nothing and ignores it.
-}
type Format
    = Bytecode
    | GenericText


{-| Compiles a graph for the CPU, and returns the session, the graph's handle and the `Cmd` for the
program to perform; on the host backend the graph is sent as MLIR bytecode. `Compiled` or
`CompileFailed` answers it; for the CPU, `Max` refuses no graph, so only the host can: MAX, or the
host itself for a name it cannot read (see `host`).

The session accepts a run of the handle as soon as `compile` returns. On the in-Elm backend that
run can be sent at once. On the host backend the host waits for a compile it has received, but a
run whose request reaches the host before the compile's, or a run of a graph whose compile failed
sent before its `CompileFailed` has been passed to `update`, ends the program. Sending runs only
once `Compiled` has arrived avoids both.

-}
compile : Graph -> Session msg -> ( Session msg, Handle, Cmd msg )
compile =
    compileWith { format = Bytecode, device = Max.Cpu }


{-| Compiles a graph as `compile` does, written in the given format for the given device.

When `Max` refuses to write the graph for the device (see `Max.toBytecodeOn`), nothing is sent, and
`CompileFailed` gives `Max`'s messages, one per line.

On the host backend the graph is otherwise sent as written for the device. The host that comes with
this package creates only a CPU device, and gives every input that device.

On the in-Elm backend the format is ignored, and the device only decides whether `Max` refuses the
graph: a graph it does not refuse is `Compiled` at once and run with `Tensor.Eval`, whatever the
device. A compile is answered there even after a `finish`, while the host handles none.

-}
compileWith : { format : Format, device : Max.Device } -> Graph -> Session msg -> ( Session msg, Handle, Cmd msg )
compileWith opts graph ((S.Session s) as session) =
    let
        info prepared =
            { name = Graph.name graph, inputs = Graph.inputs graph, outputs = Graph.outputs graph, prepared = prepared }

        refused messages =
            let
                ( s2, h ) =
                    S.addGraph Nothing session
            in
            ( S.enqueue (S.ECompileFailed h (String.join "\n" messages)) s2, h, next s.toMsg )
    in
    case s.backend of
        S.Host ports ->
            let
                mlir =
                    case opts.format of
                        Bytecode ->
                            Max.toBytecodeOn opts.device graph

                        GenericText ->
                            Max.toGenericTextOn opts.device graph |> Result.map (Bytes.Encode.string >> Bytes.Encode.encode)
            in
            case mlir of
                Ok m ->
                    let
                        ( s2, (S.Handle id) as h ) =
                            S.addGraph (Just (info Nothing)) session
                    in
                    ( s2, h, ports.send (Protocol.encode (Protocol.Compile id (Graph.inputs graph) (Graph.outputs graph) m)) )

                Err messages ->
                    refused messages

        S.InElm _ ->
            case opts.device of
                Max.Cpu ->
                    compiledInElm (info (Just (Eval.prepare graph))) session

                Max.Gpu _ ->
                    case Max.toBytecodeOn opts.device graph of
                        Ok _ ->
                            compiledInElm (info (Just (Eval.prepare graph))) session

                        Err messages ->
                            refused messages


{-| Adds the graph `info` describes to an in-Elm session, and returns the session with the graph's
`Compiled` queued, its handle, and the command that hands one queued answer to the program.
-}
compiledInElm : S.GraphInfo -> Session msg -> ( Session msg, Handle, Cmd msg )
compiledInElm info ((S.Session s) as session) =
    let
        ( s2, h ) =
            S.addGraph (Just info) session
    in
    ( S.enqueue (S.ECompiled h) s2, h, next s.toMsg )


{-| Produces the command that hands one queued reply to the program.
-}
next : (S.Message -> msg) -> Cmd msg
next toMsg =
    Task.perform (\_ -> toMsg S.Next) (Task.succeed ())


{-| Something for a session to do: a run, something done to a resident buffer, a file read, or the
end of the program. Commands do nothing until `send` sends them. Compiling is not a command:
`compile` and `compileWith` do not go through `send`.

When it runs and succeeds, a `run`, `get`, `load` or `loadRange` is answered with an event, and no
other command is, except a `finish` on the in-Elm backend (`Finished`). How a failure is
answered differs between the backends, as `Event` describes.

-}
type alias Command =
    S.Command


{-| Sends commands, which are run in the order listed, and returns the session with the `Cmd` for
the program to perform.

On the host backend, `send` first checks every run in the list: its graph must be one the session
holds, compiled in it, not refused by `Max`, and not known to have failed to compile (its
`CompileFailed` passed to `update`), and its fed inputs must be given and fit their specs, as `run`
describes. If a run does not pass, nothing in the list is sent, and the one answer is `Failed` with
the reason the first such run does not pass. Otherwise the commands go to the host as one message,
or as none for an empty list, and the host runs them in order. After a failed `load` or `loadRange`
the commands after it still run; any other failure the host detects ends the program (see `Event`).

On the in-Elm backend the commands run at once, and their answers come through the returned
command. A command that fails gives `Failed`. After a failed `load` or `loadRange` the commands
after it still run; after any other failure the rest of the list is skipped, while the commands
before it have run. Once a `finish` has run, every later command, in this list or a later `send`,
is ignored with no answer.

-}
send : List Command -> Session msg -> ( Session msg, Cmd msg )
send commands ((S.Session s) as session) =
    case s.backend of
        S.Host ports ->
            case S.hostRequests commands session of
                Ok ( s2, [] ) ->
                    ( s2, Cmd.none )

                Ok ( s2, requests ) ->
                    ( s2, ports.send (Protocol.encodeAll requests) )

                Err message ->
                    ( S.enqueue (S.EFailed message) session, next s.toMsg )

        S.InElm _ ->
            let
                after =
                    S.runInElm commands session
            in
            ( after, Cmd.batch (List.repeat (S.queued after - S.queued session) (next s.toMsg)) )


{-| Creates the command that runs a compiled graph once, on its resident buffers and on the fed
inputs given by name: the name of each input's spec in `Graph.inputs`. `Ran` answers it with the fed
outputs, and the resident outputs replace their buffers once the whole run has succeeded.

Every fed input must be given. An input given twice is taken from its first entry, and names the
graph has no fed input for are ignored. Each input must fit its spec:

  - Bytes (`fromBytes`) must be exactly as many as the dtype and shape take. On the host nothing
    else is checked, and they are sent as they are; on the in-Elm backend they are decoded by the
    spec, and a `bool` byte other than 0 is `True`.
  - A value, floats or ints (`fromValue`, `fromFloats`, `fromInts`) must fit as `Tensor.Eval.run`
    requires of an input value: the spec's dtype and exactly its shape; `Floats` for a
    floating-point dtype, `Ints` for an integer one and `Bools` for `bool`, as many as the shape
    holds; and, for `si8`, `ui8` or `si32`, `Ints` the dtype can hold. On the host the value is
    then encoded in its dtype, which rounds its floats for `f32`, `f16` and `bf16`; on the in-Elm
    backend `Tensor.Eval` is given it as it is.

A missing input, or one that does not fit, is refused with `Failed` and a message naming the graph
and the input: on the host by `send`, before anything is sent, and on the in-Elm backend when the
run comes.

Every resident input's buffer must exist and hold exactly as many bytes as the input's dtype and
shape take. Nothing else about the bytes is checked, so bytes of another dtype of the same width
are read as the input's. A buffer that does not pass gives `Failed` on the in-Elm backend and ends
the program on the host.

A run that fails while it runs, one `Tensor.Eval` or MAX cannot execute, gives `Failed` on the
in-Elm backend and ends the program on the host, as `Event` describes. On the host, a run whose
fed outputs, padded, come to more than 2³² − 17 bytes ends the program before it runs.

-}
run : Handle -> List ( String, Input ) -> Command
run =
    S.Run


{-| The value of a fed input, from bytes, from a `Tensor.Eval` value, or from its elements; `run`
says what each must fit. No constructor takes a mask's elements: give a `bool` input with
`fromValue` and `Bools`, or with `fromBytes`.
-}
type alias Input =
    S.Input


{-| Creates an input from its bytes in the package encoding that `Train` states, such as a slice of
a data file. On the host they are sent as they are, with only their number checked.
-}
fromBytes : Bytes -> Input
fromBytes =
    S.InBytes


{-| Creates an input from a `Tensor.Eval` value, whose dtype, shape and elements must fit the input
as `run` describes.
-}
fromValue : Value -> Input
fromValue =
    S.InValue


{-| Creates an input of a floating-point dtype from its elements in row-major order, the dtype and
shape being the input's. For an input of an integer dtype or `bool` it is refused.
-}
fromFloats : List Float -> Input
fromFloats =
    S.InFloats


{-| Creates an input of an integer dtype from its elements in row-major order, the dtype and shape
being the input's. A `ui64` element is the `Int` with the same 64 bits. For an input of a
floating-point dtype or `bool` it is refused, and for `si8`, `ui8` or `si32` an element the dtype
cannot hold is refused, not wrapped.
-}
fromInts : List Int -> Input
fromInts =
    S.InInts


{-| Creates the command that sets the resident buffer `name` to `bytes`, replacing what it held.
Any bytes are stored, unchecked, and nothing answers the command.
-}
put : String -> Bytes -> Command
put =
    S.Put


{-| Creates the command that reads the resident buffer `name`. `Got` answers it with the buffer's
bytes, or with none when no buffer has that name. On the host, a buffer of more than 2³² − 17
bytes, more than one reply carries, ends the program.
-}
get : String -> Command
get =
    S.Get


{-| Creates the command that writes the resident buffer `name` to the file at `path`, as its bytes
and nothing else. Nothing answers it when it succeeds.

On the host a buffer that does not exist, or a file that cannot be written, ends the program. On
the in-Elm backend no file is written: the bytes are kept
in the session under `path`, for `loadInto` to read, and a buffer that does not exist gives
`Failed`.

-}
save : String -> String -> Command
save name path =
    S.Save name path


{-| Creates the command that sets the resident buffer `name` to the whole contents of the file at
`path`, whatever they are. Nothing answers it when it succeeds. On the host, a file that cannot be
opened or read ends the program; on the in-Elm backend, a path the session did not save gives
`Failed`.
-}
loadInto : String -> String -> Command
loadInto name path =
    S.LoadInto name path


{-| Creates the command that sets the resident buffer `name` to `length` bytes of the file at
`path`, starting at byte `offset`, such as one tensor of a checkpoint, without the bytes passing
through Elm. Nothing answers it when it succeeds.

On the host, a file that cannot be opened or read, or a range that runs past its end, ends the
program. The in-Elm backend reads no files, and gives `Failed` each time it runs one. `offset` and
`length` must not be negative: nothing refuses a negative one, and the host reads it as another
number.

-}
loadRangeInto : String -> String -> Int -> Int -> Command
loadRangeInto name path offset length =
    S.LoadRangeInto name path offset length


{-| Creates the command that frees the resident buffer `name`. Nothing answers it when it succeeds.
A buffer that does not exist ends the program on the host, and gives `Failed` on the in-Elm
backend.
-}
drop : String -> Command
drop =
    S.Drop


{-| Creates the command that reads the file at `path`. On the host `Loaded` answers it with the
whole file, or `Failed` with why it cannot be read: the file cannot be opened or read, or holds
more than 2³² − 17 bytes, which is more than one reply carries. A reply that cannot be allocated
ends the program instead, with no event. The in-Elm backend reads no files, and answers `Failed`
each time it runs one.
-}
load : String -> Command
load =
    S.Load


{-| Creates the command that reads `length` bytes of the file at `path`, starting at byte `offset`,
such as a checkpoint's header. On the host `Loaded` answers it with those bytes, or `Failed` with
why they cannot be read: the file cannot be opened or read, the range runs past its end, or
`length` is more than 2³² − 17. A reply that cannot be allocated ends the program instead, with no
event. The in-Elm backend reads no files, and answers `Failed` each time it runs one.

`offset` and `length` must not be negative: nothing refuses a negative one, and the host reads it
as another number.

-}
loadRange : String -> Int -> Int -> Command
loadRange path offset length =
    S.LoadRange path offset length


{-| Creates the command that asks the backend to end the program with an exit code.

On the host nothing answers it: the host stops the program and exits with the code. The process's
exit status keeps only the code's low 8 bits, as on any POSIX system, so only a code from 0 to 255
comes out as given; -1 comes out as 255. The host handles nothing sent after a `finish`: not the
commands after it in the same `send`, nor a later `send` or `compile`.

The in-Elm backend cannot stop the program: it answers `Finished` with the code as given, and
ignores every later command, in this `send` and in later ones, with no answer. A later `compile` is
still answered.

-}
finish : Int -> Command
finish =
    S.Finish


{-| The fed outputs of one run, each under the name of its spec in `Graph.outputs`; the resident
outputs are in their buffers instead. From an in-Elm run, `value` and `floats` give floating-point
elements not rounded to the output's dtype.
-}
type alias Outputs =
    S.Outputs


{-| Returns the output named `name` as a `Tensor.Eval` value, with its spec's dtype and shape, or
`Nothing` if the run has no fed output of that name.

From the host the value is decoded from the bytes MAX wrote, so its floats are numbers of the
output's dtype. From the in-Elm backend it is the value `Tensor.Eval` computed, whose floats are
not rounded to the dtype. So `value` and `floats` can differ between the backends by that
rounding, besides any difference between `Tensor.Eval`'s results and MAX's.

-}
value : String -> Outputs -> Maybe Value
value name outputs =
    case S.lookup name outputs of
        Just (S.Raw spec b) ->
            Elements.decode spec b |> Result.toMaybe

        Just (S.Computed v) ->
            Just v

        Nothing ->
            Nothing


{-| Returns the elements of the floating-point output named `name`, in row-major order, or
`Nothing` if the run has no such output or its dtype is not floating-point. From the in-Elm backend
they are not rounded to the dtype, as `value` describes.
-}
floats : String -> Outputs -> Maybe (List Float)
floats name outputs =
    case Maybe.map .data (value name outputs) of
        Just (Floats l) ->
            Just l

        _ ->
            Nothing


{-| Returns the elements of the integer output named `name`, in row-major order, or `Nothing` if
the run has no such output or its dtype is not an integer one (`bool` is not). A `ui64` element is
the `Int` with the same 64 bits.
-}
ints : String -> Outputs -> Maybe (List Int)
ints name outputs =
    case Maybe.map .data (value name outputs) of
        Just (Ints l) ->
            Just l

        _ ->
            Nothing


{-| Returns the bytes of the output named `name` in the package encoding, or `Nothing` if the run
has no fed output of that name. From the host they are the bytes MAX wrote; from the in-Elm
backend, the computed value encoded in its dtype, so floating-point elements are rounded to it.
-}
bytes : String -> Outputs -> Maybe Bytes
bytes name outputs =
    case S.lookup name outputs of
        Just (S.Raw _ b) ->
            Just b

        Just (S.Computed v) ->
            Elements.encode v |> Result.toMaybe

        Nothing ->
            Nothing
