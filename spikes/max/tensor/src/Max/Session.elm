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
over, and keep their resident buffers between runs. A session is that, seen from Elm: the program
compiles graphs into it and sends it commands, and it answers with events.

A session has one of two backends, and the program's code is the same for both:

  - **The host** (`host`): MAX compiles and runs the graphs, in a C++ host program the Elm program
    is linked with, `host/max_host.cpp`, which comes with this package. The two talk over two
    ports carrying `Bytes`, which the program declares and hands to the session (`Ports`). Only an
    eco native program can declare ports that carry `Bytes`, so only such a program, linked with
    the host, can use this backend.
  - **Elm** (`inElm`): `Tensor.Eval` runs the graphs, and the session keeps the resident buffers
    itself. This works wherever Elm runs, in tests or a browser; it reads no files, and it is as
    slow as `Tensor.Eval`.

A _resident buffer_ is a named buffer that the session keeps from one run to the next, such as a
model's parameters: a graph's input whose role is `Graph.Resident n` reads the buffer `n`, and an
output with that role replaces it after the run. So a run is given only the graph's fed inputs, and
hands back only its fed outputs. `put` fills a buffer from Elm, `get` reads one back, `save` writes
one to a file, and `loadInto` and `loadRangeInto` fill one from a file without the bytes passing
through Elm.

Buffers hold bytes in the package encoding `Train` describes, the encoding of `Train.initial` and
`Param.initial`, so their first contents can be put as they come:

    ( session1, step, compileCmd ) =
        Session.compile stepGraph session0

    ( session2, putCmd ) =
        Session.send (List.map (\( n, b ) -> Session.put n b) (Train.initial params optimizer 1)) session1

Commands given to one `send` are run in the order listed. The replies come back as `Event`s through
the program's `update`: pass every `Message` to `update` and act on the `Event` it returns.

    case Session.update message model.session of
        ( session, Session.Ran _ outputs ) ->
            -- the loss of a Train.step graph
            ( { model | session = session, loss = Session.floats "loss" outputs }, Cmd.none )

        ( session, _ ) ->
            ( { model | session = session }, Cmd.none )

A session is a value in the program's model, and every function that sends something returns the
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


{-| A session: the graphs compiled in it, its resident buffers (kept by the host, or by the
session on the in-Elm backend), and the requests it is waiting for replies to. `msg` is the
program's message type, which the session's replies are wrapped in.

Make one with `host` or `inElm`. It is a value: keep the one each function returns.

-}
type alias Session msg =
    S.Session msg


{-| The two ports a program declares for the host backend, with these names, which the host looks
for:

    port maxOut : Bytes -> Cmd msg

    port maxIn : (Bytes -> msg) -> Sub msg

and hands to `host` as `{ send = maxOut, receive = maxIn }`. `send` carries every request to the
host, and `receive` every reply from it.

-}
type alias Ports msg =
    { send : Bytes -> Cmd msg, receive : (Bytes -> msg) -> Sub msg }


{-| Creates a session on the host backend, over the program's two ports, whose replies reach the
program as `toMsg` of a `Message`. It needs an eco native program linked with the MAX host.
-}
host : Ports msg -> (Message -> msg) -> Session msg
host ports toMsg =
    S.new (S.Host ports) toMsg


{-| Creates a session on the in-Elm backend, whose replies reach the program as `toMsg` of a
`Message`. It has no resident buffers and no saved files.

The backend runs every graph with `Tensor.Eval` (see there for how its results can differ from
MAX's), decoding each resident input from its buffer by the input's dtype and shape, and encoding
each resident output back into its buffer. A floating-point output written to an `f32` buffer is
therefore rounded to `f32` between runs, as MAX's would be.

`save` and `loadInto` work over files the session itself saved, kept in the session by path; no
file is read or written. `load`, `loadRange`, `loadRangeInto`, and `loadInto` of a path the session
did not save, give `Failed`.

-}
inElm : (Message -> msg) -> Session msg
inElm toMsg =
    S.new (S.InElm { residents = Dict.empty, files = Dict.empty, finished = False }) toMsg


{-| A message for a session, carrying a reply to something it was asked. A program does nothing with
it but hand it to `update`.
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


{-| Reads a `Message` and returns the session, no longer waiting for that reply, and what the reply
says.

Each `Message` gives exactly one `Event`. A message the session cannot match to anything it asked,
such as a `Message` handed to another session, gives `Failed`.

-}
update : Message -> Session msg -> ( Session msg, Event )
update message session =
    Tuple.mapSecond event <|
        case message of
            S.Reply b ->
                S.hostReply b session

            S.Next ->
                S.pop session


{-| What a session answers.

`Compiled` says that the graph is compiled and can be run. `CompileFailed` says that it cannot be:
on the host, MAX's message; before anything is sent, on either backend, the reasons `Max` gives for
not writing the graph for its device, one per line. A failed graph cannot be run.

`Ran` carries the fed outputs of one run of a graph. The resident outputs are in their buffers.

`Got` carries the bytes of a resident buffer, under the name `get` asked for. A name that was
never set gives no bytes, as an empty buffer does.

`Loaded` carries bytes of a file, under the path `load` or `loadRange` asked for.

`Failed` carries a message. It answers a `load` or `loadRange` that failed, with a message naming
the command and the path, such as `"load: cannot open data/x.bin"`. It also answers a `send` refused
before anything was sent (see `send`), a command the in-Elm backend could not run, and a reply the
session could not match. Other failures on the host, such as a run whose resident buffer is
missing or a `loadInto` of a file that cannot be opened, are not answered: the host prints them and
stops the program.

On the host a compile finishes on a thread of its own: its `Compiled` comes before any `Ran` of
that graph, and may come before or after any other reply. Two runs of one graph are told apart only
by the order of their `Ran`s, which is the order the runs were sent in.

`Finished` carries the exit code of a `finish` run by the in-Elm backend, which cannot stop the
program. On the host, `finish` stops the program and nothing answers it.

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


{-| A graph compiled in one session, by which `run` names it and `Compiled`, `CompileFailed` and
`Ran` say which graph they are about. Two handles from one session are equal only when they come
from one call of `compile`; a handle from another session means nothing to this one.
-}
type alias Handle =
    S.Handle


{-| How the host backend sends a graph's MLIR: as MLIR bytecode, or as MLIR's generic op text (see
`Max`). The in-Elm backend sends nothing and ignores it.
-}
type Format
    = Bytecode
    | GenericText


{-| Compiles a graph for the CPU, sending it as MLIR bytecode, and returns the session, the graph's
handle and the command that starts it. `Compiled` or `CompileFailed` answers it.

A run may be sent before `Compiled` arrives: the host waits for the compile, and the in-Elm
backend compiles at once.

-}
compile : Graph -> Session msg -> ( Session msg, Handle, Cmd msg )
compile =
    compileWith { format = Bytecode, device = Max.Cpu }


{-| Compiles a graph as `compile` does, written in the given format for the given device.

When `Max` refuses to write the graph for the device, nothing is sent, and `CompileFailed` gives
`Max`'s messages, one per line; this is so on the in-Elm backend too, though it runs the graph
with `Tensor.Eval` whatever the device.

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


{-| Adds a graph to an in-Elm session and queues its `Compiled`.
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
end of the program. Commands do nothing until `send` sends them.
-}
type alias Command =
    S.Command


{-| Sends commands, which are run in the order listed, and returns the session and the command that
sends them. On the host they go as one message.

On the host backend, `send` first checks every run: its graph must have been compiled in this
session, and not have failed to compile as far as the session knows (once its `CompileFailed` has
been handed to `update`), and each fed input must be given and fit its spec, as `run` describes. If
one does not, nothing is sent, and the one reply is `Failed` with the reason.

On the in-Elm backend, the commands run at once, and their replies are queued. A command that fails
gives `Failed`. After a failed `load` or `loadRange` the commands after it still run, as they do on
the host; after any other failure the rest of the list is skipped. Once a `finish` has run, every
later command is ignored.

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
outputs.

Every fed input must be given. An input given twice is taken from its first entry, and names the
graph has no fed input for are ignored. Each value must fit its input's spec: bytes must be exactly
as many as the dtype and shape take, and the other kinds of `Input` must have the spec's dtype and
shape, as `Tensor.Eval.run` requires of its values. Every resident input's buffer must be set.

-}
run : Handle -> List ( String, Input ) -> Command
run =
    S.Run


{-| The value of a fed input, from bytes or from elements.
-}
type alias Input =
    S.Input


{-| Creates an input from its bytes in the package encoding (see `Train`), such as a slice of a data
file. On the host they are sent as they are.
-}
fromBytes : Bytes -> Input
fromBytes =
    S.InBytes


{-| Creates an input from a `Tensor.Eval` value, whose dtype and shape must be the input's.
-}
fromValue : Value -> Input
fromValue =
    S.InValue


{-| Creates an input of a floating-point dtype from its elements in row-major order, the dtype and
shape being the input's.
-}
fromFloats : List Float -> Input
fromFloats =
    S.InFloats


{-| Creates an input of an integer dtype from its elements in row-major order, the dtype and shape
being the input's. A `ui64` element is the `Int` with the same 64 bits.
-}
fromInts : List Int -> Input
fromInts =
    S.InInts


{-| Creates the command that sets the resident buffer `name` to `bytes`, replacing what it held.
-}
put : String -> Bytes -> Command
put =
    S.Put


{-| Creates the command that reads the resident buffer `name`. `Got` answers it with the buffer's
bytes, or with none if it was never set.
-}
get : String -> Command
get =
    S.Get


{-| Creates the command that writes the resident buffer `name` to the file at `path`, as its bytes
and nothing else.
-}
save : String -> String -> Command
save name path =
    S.Save name path


{-| Creates the command that sets the resident buffer `name` to the whole contents of the file at
`path`. On the host, a file that cannot be opened stops the program; on the in-Elm backend, a path
the session did not save gives `Failed`.
-}
loadInto : String -> String -> Command
loadInto name path =
    S.LoadInto name path


{-| Creates the command that sets the resident buffer `name` to `length` bytes of the file at
`path`, starting at byte `offset`: one tensor of a checkpoint, without its bytes passing through
Elm.
-}
loadRangeInto : String -> String -> Int -> Int -> Command
loadRangeInto name path offset length =
    S.LoadRangeInto name path offset length


{-| Creates the command that frees the resident buffer `name`.
-}
drop : String -> Command
drop =
    S.Drop


{-| Creates the command that reads the file at `path`. `Loaded` answers it with the whole file, or
`Failed` with why it cannot be read.
-}
load : String -> Command
load =
    S.Load


{-| Creates the command that reads `length` bytes of the file at `path`, starting at byte `offset`,
such as a checkpoint's header. `Loaded` answers it with those bytes, or `Failed` with why they
cannot be read.
-}
loadRange : String -> Int -> Int -> Command
loadRange path offset length =
    S.LoadRange path offset length


{-| Creates the command that ends the program with an exit code. The host runs the commands sent
before it, then stops the program and exits with the code; nothing answers it. The in-Elm backend
cannot stop the program: it answers `Finished` with the code and ignores every later command.
-}
finish : Int -> Command
finish =
    S.Finish


{-| The fed outputs of one run, by the names of their specs in `Graph.outputs`. Of two outputs with
one name, the last is kept.
-}
type alias Outputs =
    S.Outputs


{-| Returns the output named `name` as a `Tensor.Eval` value, with its spec's dtype and shape, or
`Nothing` if the run has no fed output of that name.
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
`Nothing` if the run has no such output or its dtype is not floating-point.
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
has no fed output of that name. From the host they are the bytes it sent; from the in-Elm backend,
the computed value encoded, so floating-point elements are rounded to their dtype.
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
