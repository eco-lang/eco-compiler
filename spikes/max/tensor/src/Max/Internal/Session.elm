module Max.Internal.Session exposing
    ( Backend(..)
    , Command(..)
    , Ev(..)
    , GraphInfo
    , Handle(..)
    , Input(..)
    , Message(..)
    , Out(..)
    , Outputs(..)
    , Pending(..)
    , Session(..)
    , Store
    , addGraph
    , dropGraph
    , enqueue
    , hostReply
    , hostRequests
    , lookup
    , new
    , pop
    , queued
    , runInElm
    )

{-| `Max.Session`'s `compile`, `compileWith` and `send` end in a `Cmd`, which a test cannot look
inside, so a session's types are kept here, with steps of its work that need no `Cmd`, where tests
can call them: giving out ids, queueing replies, turning commands into requests for the host,
matching the host's replies, and running commands in Elm. `Max.Session` names the types with
aliases (`Session`, `Handle`, `Command`, `Input`, `Outputs`, `Message`) and gives `Ev` to the
program as its `Event`; what each command and event means to a program is stated there.

A session has one of two _backends_, which run its commands. On the host backend the commands go
as requests to a separate host program, laid out as `Max.Internal.Protocol` describes, and the
host's replies come back as messages that have to be matched to what was asked. On the in-Elm
backend the session runs the commands itself with `Tensor.Eval`, keeping its buffers in a `Store`,
and makes their replies at once.

Each input and output of a graph has a `Graph.Role`. A _fed_ input is given with the run, and a fed
output comes back in its reply; a _resident_ input is read from, and a resident output written to,
the named buffer the backend keeps between runs. Tensors cross as bytes in the _package encoding_
that `Train` states, which `Max.Internal.Elements` writes and reads.

Replies the session makes itself, rather than reads from the host, wait in its _queue_: the
replies of `runInElm`, and any other that `enqueue` adds. A `Next` message takes the oldest one
off. A `Next` carries nothing else, so whatever order `Next` messages arrive in, queued replies come
out in the order they were queued. Nothing here orders them against the host's replies.

Replies from the host are matched by ids. A session has one counter of ids, starting at 1. Each
graph added to the session takes the next id, which is its `Handle`; a run request carries it, and
so do the host's replies about that graph. When `hostRequests` turns commands into requests for the
host, each `get`, `load` and `loadRange` also takes the next id, and the session records what it
asked for, its `Pending`, until a reply with that id and the request's code arrives. `runInElm`
gives commands no ids, since it answers them at once.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict exposing (Dict)
import Graph
import Max.Internal.Elements as Elements
import Max.Internal.Protocol as Protocol exposing (Request)
import Tensor.Eval as Eval exposing (Value)


{-| A session's name for a graph.

`Handle` carries the id the session gave the graph from its counter. Every session counts from 1
on its own, so two sessions can give equal handles to different graphs, and a session takes a
handle from another session as whichever of its own graphs has that id.

-}
type Handle
    = Handle Int


{-| The value given for one fed input of a run.

`InBytes` carries the input as bytes. `InValue` carries a whole `Tensor.Eval` value. `InFloats`
and `InInts` carry the elements only, and take the dtype and shape from the input's spec.

Before a run, each must fit the input's spec. Bytes must be exactly as wide as the spec takes: on
the host backend that is all that is checked, and nothing looks at their contents, while in Elm
they are decoded by the spec. The others are checked as `Max.Internal.Elements.check` checks a
value.

-}
type Input
    = InBytes Bytes
    | InValue Value
    | InFloats (List Float)
    | InInts (List Int)


{-| One thing a session is asked to do, before any id is given to it. Each constructor is made by
the `Max.Session` function of the same name (`Run` by `run`, and so on), which says what it does;
here is only what each carries.

`Run` carries the graph's handle and the inputs given for it, each under a name. `Put` carries a
buffer's name and the bytes to store in it. `Get` and `Drop` carry a buffer's name. `Save` and
`LoadInto` carry the buffer's name, then the path. `LoadRangeInto` carries the buffer's name, the
path, the offset and the length, and `LoadRange` the path, the offset and the length, both counted
in bytes. `Load` carries the path. `Finish` carries the exit code.

-}
type Command
    = Run Handle (List ( String, Input ))
    | Put String Bytes
    | Get String
    | Save String String
    | LoadInto String String
    | LoadRangeInto String String Int Int
    | Drop String
    | Load String
    | LoadRange String Int Int
    | Finish Int


{-| One fed output of a run, in the form the backend that ran it gives it.

`Raw` carries the output's spec and the bytes the host sent for it, without their padding.
`Computed` carries the value `Tensor.Eval` computed, which has not been encoded in the output's
dtype.

-}
type Out
    = Raw Graph.Spec Bytes
    | Computed Value


{-| The fed outputs of one run, each under its spec's name; the resident outputs are not among them.
`lookup` reads one.
-}
type Outputs
    = Outputs (Dict String Out)


{-| A message for a session to read.

`Reply` carries the bytes of one reply from the host, header included. `Next` asks for the oldest
reply in the queue; it names no session, so whichever session reads it hands out its own oldest
reply, or, with nothing queued, an `EFailed`.

-}
type Message
    = Reply Bytes
    | Next


{-| What a session answers. Each constructor is the `Max.Session.Event` constructor with the same
name less its `E`, which says what it means to a program.

`ECompiled` carries the graph's handle, and `ECompileFailed` the handle and the reason. `ERan`
carries the graph's handle and the run's fed outputs. `EGot` carries a buffer's name and its bytes,
and `ELoaded` a path and bytes of that file. `EFailed` carries a message, and `EFinished` the exit
code of a `finish`.

-}
type Ev
    = ECompiled Handle
    | ECompileFailed Handle String
    | ERan Handle Outputs
    | EGot String Bytes
    | ELoaded String Bytes
    | EFailed String
    | EFinished Int


{-| What runs a session's commands.

`Host` carries the two ports to a host program: `send` takes the bytes of requests out, and
`receive` subscribes to the bytes of each reply. `InElm` carries the `Store` in which the session
keeps its buffers while it runs the commands itself.

-}
type Backend msg
    = Host { send : Bytes -> Cmd msg, receive : (Bytes -> msg) -> Sub msg }
    | InElm Store


{-| The buffers and files of an in-Elm session.

`files` holds, by path, what each `save` stored: the bytes the buffer held, which reach no real
file. `finished` is `True` once a `finish` has run, and from then on `runInElm` ignores every
command.

-}
type alias Store =
    { residents : Dict String Bytes, files : Dict String Bytes, finished : Bool }


{-| What a session knows of a graph it holds.

The order of `inputs` and `outputs` is the order in which a run's fed tensors are sent to the host
and read from its reply. An in-Elm run of a graph whose `prepared` is `Nothing` is refused.

-}
type alias GraphInfo =
    { name : String, inputs : List Graph.Spec, outputs : List Graph.Spec, prepared : Maybe Eval.Prepared }


{-| What a request waiting for its reply asked for.

`ForGet` carries the name of the buffer a `get` asked for. `ForLoad` carries the path a `load` or a
`loadRange` asked for, and a reply with the code of either answers it.

-}
type Pending
    = ForGet String
    | ForLoad String


{-| A session's whole state. `toMsg` makes the program's message from a `Message`, and `graphs`
and `pending` are keyed by id.

`nextId` is the id the next graph or request will take. A graph added without its `GraphInfo`, or
forgotten by `dropGraph`, is not in `graphs`, though its id stays used. `queue` is oldest first.

-}
type Session msg
    = Session
        { toMsg : Message -> msg
        , backend : Backend msg
        , nextId : Int
        , graphs : Dict Int GraphInfo
        , pending : Dict Int Pending
        , queue : List Ev
        }


{-| Creates a session on `backend` with no graphs, no pending requests and an empty queue, whose
first id will be 1.
-}
new : Backend msg -> (Message -> msg) -> Session msg
new backend toMsg =
    Session { toMsg = toMsg, backend = backend, nextId = 1, graphs = Dict.empty, pending = Dict.empty, queue = [] }


{-| Gives a graph the next id and returns its handle, holding `info` under that id. With `Nothing`
the id is used up but no graph is held, so a run of the handle is refused.
-}
addGraph : Maybe GraphInfo -> Session msg -> ( Session msg, Handle )
addGraph info (Session s) =
    ( Session
        { s
            | nextId = s.nextId + 1
            , graphs =
                case info of
                    Just i ->
                        Dict.insert s.nextId i s.graphs

                    Nothing ->
                        s.graphs
        }
    , Handle s.nextId
    )


{-| Forgets the graph a handle names, so that a later run of it is refused. Its id is not given out
again.
-}
dropGraph : Handle -> Session msg -> Session msg
dropGraph (Handle id) (Session s) =
    Session { s | graphs = Dict.remove id s.graphs }


{-| Adds a reply to the end of the queue, to be handed out after every reply already in it.
-}
enqueue : Ev -> Session msg -> Session msg
enqueue ev (Session s) =
    Session { s | queue = s.queue ++ [ ev ] }


{-| Returns the number of replies in the queue.
-}
queued : Session msg -> Int
queued (Session s) =
    List.length s.queue


{-| Takes the oldest reply off the queue and returns it. With nothing queued, the session is
returned as it was, with `EFailed "Max.Session: no reply is waiting"`.
-}
pop : Session msg -> ( Session msg, Ev )
pop (Session s) =
    case s.queue of
        ev :: rest ->
            ( Session { s | queue = rest }, ev )

        [] ->
            ( Session s, EFailed "Max.Session: no reply is waiting" )


{-| The `Bytes` of width 0, with which an in-Elm session answers a `get` of a buffer it does not
have.
-}
empty : Bytes
empty =
    Bytes.Encode.encode (Bytes.Encode.sequence [])


{-| Returns the fed output whose spec is named `name`, or `Nothing` if the run has none by that
name.
-}
lookup : String -> Outputs -> Maybe Out
lookup name (Outputs d) =
    Dict.get name d


{-| Returns the graph a handle names in `graphs`, or, when there is none, the message
`"run: graph n is not compiled in this session"`.
-}
graphFor : Handle -> Dict Int GraphInfo -> Result String GraphInfo
graphFor (Handle id) graphs =
    case Dict.get id graphs of
        Just g ->
            Ok g

        Nothing ->
            Err ("run: graph " ++ String.fromInt id ++ " is not compiled in this session")


{-| Returns the input given under `spec`'s name in `inputs`, the first if there are several, or,
when there is none, the message `"<graphName>: missing input <name>"`.
-}
givenInput : String -> Graph.Spec -> List ( String, Input ) -> Result String Input
givenInput graphName spec inputs =
    case List.filter (\( n, _ ) -> n == spec.name) inputs of
        ( _, i ) :: _ ->
            Ok i

        [] ->
            Err (graphName ++ ": missing input " ++ spec.name)


{-| Returns the value an input stands for, of the spec's dtype and shape, or why it does not fit,
in a message starting `"<graphName>: input <name>: "`.

`InBytes` is decoded by the spec with `Max.Internal.Elements.decode`, which refuses a width other
than the spec's. `InValue` is checked as it is, and `InFloats` and `InInts` are first given the
spec's dtype and shape; the check is `Max.Internal.Elements.check`.

-}
fedValue : String -> Graph.Spec -> Input -> Result String Value
fedValue graphName spec input =
    let
        checked v =
            Elements.check spec v |> Result.map (\_ -> v)
    in
    Result.mapError (\m -> graphName ++ ": input " ++ spec.name ++ ": " ++ m) <|
        case input of
            InBytes b ->
                Elements.decode spec b

            InValue v ->
                checked v

            InFloats l ->
                checked { dtype = spec.dtype, shape = spec.shape, data = Eval.Floats l }

            InInts l ->
                checked { dtype = spec.dtype, shape = spec.shape, data = Eval.Ints l }


{-| Returns the bytes to send the host for a fed input, or why it does not fit, worded as `fedValue`
words it.

`InBytes` exactly as wide as the spec takes is returned as it is, with nothing about its contents
checked, so a `bool` byte of 2 goes through; at any other width it is refused. The others are
checked as `fedValue` checks them, then encoded in the package encoding.

-}
fedBytes : String -> Graph.Spec -> Input -> Result String Bytes
fedBytes graphName spec input =
    case input of
        InBytes b ->
            if Just (Bytes.width b) == Elements.byteSize spec then
                Ok b

            else
                fedValue graphName spec input |> Result.map (\_ -> b)

        _ ->
            fedValue graphName spec input
                |> Result.andThen (Elements.encode >> Result.mapError (\m -> graphName ++ ": input " ++ spec.name ++ ": " ++ m))


{-| Returns the requests that carry `commands` to the host, in the same order, and the session
waiting for their replies; or, if any command cannot be sent, the reason the first one cannot.

Each `get`, `load` and `loadRange` takes the session's next id, and the session records what it
asked for until `hostReply` reads its reply. A run request carries its graph's id. The other
requests carry no id.

Only a run can be refused. It is refused when its handle names no graph the session holds. It is
also refused when one of the graph's fed inputs, taken in the order of its inputs, is missing from
those given or does not fit its spec; that message names the graph and the input. Each input is
looked up by its spec's name, the first given under that name, and any other name is ignored. Bytes
are refused unless they are exactly as wide as the spec takes, and are then sent as they are, with
nothing about their contents checked. A value, floats or ints are checked as
`Max.Internal.Elements.check` checks a value, then encoded in the package encoding.

-}
hostRequests : List Command -> Session msg -> Result String ( Session msg, List Request )
hostRequests commands (Session s0) =
    let
        ask pending s =
            ( { s | nextId = s.nextId + 1, pending = Dict.insert s.nextId pending s.pending }, s.nextId )

        one command s =
            case command of
                Run ((Handle id) as h) inputs ->
                    graphFor h s.graphs
                        |> Result.andThen
                            (\g ->
                                List.filter (\spec -> spec.role == Graph.Fed) g.inputs
                                    |> List.foldr
                                        (\spec acc ->
                                            Result.map2 (::) (givenInput g.name spec inputs |> Result.andThen (fedBytes g.name spec)) acc
                                        )
                                        (Ok [])
                                    |> Result.map (\tensors -> ( s, Protocol.Run id tensors ))
                            )

                Put name b ->
                    Ok ( s, Protocol.Put name b )

                Get name ->
                    let
                        ( s2, id ) =
                            ask (ForGet name) s
                    in
                    Ok ( s2, Protocol.Get id name )

                Save name path ->
                    Ok ( s, Protocol.Save name path )

                LoadInto name path ->
                    Ok ( s, Protocol.LoadInto name path )

                LoadRangeInto name path offset length ->
                    Ok ( s, Protocol.LoadRangeInto name path offset length )

                Drop name ->
                    Ok ( s, Protocol.Drop name )

                Load path ->
                    let
                        ( s2, id ) =
                            ask (ForLoad path) s
                    in
                    Ok ( s2, Protocol.Load id path )

                LoadRange path offset length ->
                    let
                        ( s2, id ) =
                            ask (ForLoad path) s
                    in
                    Ok ( s2, Protocol.LoadRange id path offset length )

                Finish code ->
                    Ok ( s, Protocol.Finish code )
    in
    List.foldl
        (\command acc ->
            Result.andThen (\( s, reqs ) -> one command s |> Result.map (\( s2, r ) -> ( s2, r :: reqs ))) acc
        )
        (Ok ( s0, [] ))
        commands
        |> Result.map (\( s, reqs ) -> ( Session s, List.reverse reqs ))


{-| Reads one reply from the host and returns what it answers, with the session after it.

A reply is matched by its code and id. A run reply (code 1) is matched to the graph the session
holds under its id, whatever is pending, and its payload is split into that graph's fed outputs in
the order of its outputs, each padded as `Max.Internal.Protocol` describes; it gives `ERan` with
each output `Raw` under its spec's name. A `get` reply (code 3) is matched to a pending `get` with
its id and gives `EGot` with the buffer's name and the payload. A compile reply (code 10) is
accepted for any id, held or not: status 0 gives `ECompiled`, and any other status gives
`ECompileFailed` with the payload read by `Max.Internal.Protocol.text`, and forgets the graph. A
reply of code 9 or 11 is matched to a pending `load` or `loadRange` with its id, whichever of the
two was asked: status 0 gives `ELoaded` with the path and the payload, and any other status gives
`EFailed` with the payload read as text, which is the host's message. A `get`, `load` or
`loadRange` that has been answered is no longer pending.

The status of a run or `get` reply is not read; the host sends neither with a failure status.

Anything else gives an `EFailed` starting `"Max.Session: "` and leaves the session as it was: a
message shorter than a header, a run reply for a graph the session does not hold or whose payload
cannot be split into that graph's fed outputs, a pending `load` or `loadRange` answered with
another code, and a reply whose code and id match nothing above.

-}
hostReply : Bytes -> Session msg -> ( Session msg, Ev )
hostReply bytes (Session s) =
    let
        unexpected why =
            ( Session s, EFailed ("Max.Session: " ++ why) )

        answered id =
            Session { s | pending = Dict.remove id s.pending }
    in
    case Protocol.decodeReply bytes of
        Nothing ->
            unexpected ("a reply of " ++ String.fromInt (Bytes.width bytes) ++ " bytes, shorter than a header")

        Just r ->
            case ( r.code, Dict.get r.id s.pending ) of
                ( 1, _ ) ->
                    case Dict.get r.id s.graphs of
                        Nothing ->
                            unexpected ("a run reply for graph " ++ String.fromInt r.id ++ ", which is not compiled in this session")

                        Just g ->
                            let
                                fed =
                                    List.filter (\spec -> spec.role == Graph.Fed) g.outputs

                                widths =
                                    List.map (Elements.byteSize >> Maybe.withDefault -1) fed
                            in
                            case Protocol.splitPadded widths r.payload of
                                Just tensors ->
                                    ( Session s
                                    , ERan (Handle r.id)
                                        (Outputs (Dict.fromList (List.map2 (\spec t -> ( spec.name, Raw spec t )) fed tensors)))
                                    )

                                Nothing ->
                                    unexpected (g.name ++ ": a run reply of " ++ String.fromInt (Bytes.width r.payload) ++ " bytes, which is not the graph's fed outputs")

                ( 3, Just (ForGet name) ) ->
                    ( answered r.id, EGot name r.payload )

                ( 10, _ ) ->
                    if r.status == 0 then
                        ( Session s, ECompiled (Handle r.id) )

                    else
                        ( dropGraph (Handle r.id) (Session s), ECompileFailed (Handle r.id) (Protocol.text r.payload) )

                ( code, Just (ForLoad path) ) ->
                    if code /= 9 && code /= 11 then
                        unexpected ("a reply with code " ++ String.fromInt code ++ " to a load")

                    else if r.status == 0 then
                        ( answered r.id, ELoaded path r.payload )

                    else
                        ( answered r.id, EFailed (Protocol.text r.payload) )

                ( code, _ ) ->
                    unexpected ("a reply with code " ++ String.fromInt code ++ " and id " ++ String.fromInt r.id ++ ", which matches no request")


{-| Runs `commands` in order on an in-Elm session and adds their replies, in order, to the end of
its queue. A host-backend session is returned as it was.

Each command runs at once on the buffers and files in the session's `Store`, and none is given an
id. `put` stores any bytes. A `get` of a buffer the session does not have answers with no bytes.
`save` copies a buffer's bytes into the store under the path, and `loadInto` copies them back.

A command that fails adds an `EFailed` with the reason. A run fails when the session does not hold
its graph, or holds it without its `Tensor.Eval` form; when a fed input is missing or does not fit
its spec (bytes must be exactly as wide as the spec takes, and are decoded by it; other inputs are
checked as `Max.Internal.Elements.check` checks a value); when a resident buffer it reads is missing
or cannot be decoded by the input's spec; and when `Tensor.Eval` reports an error or an output
cannot be stored. A `save` or `drop` of a buffer the session does not have fails, as does a
`loadInto` of a path it has not saved, and every `loadRangeInto`, `load` and `loadRange`, since no
file is read. After a failed `load` or `loadRange` the next commands still run; after any other
failure the rest of `commands` is skipped.

Once a `finish` has run, it adds `EFinished` with its exit code, and every later command is ignored
with no reply, in this call and in later ones.

A run's resident outputs replace their buffers only when the whole run succeeds. They are encoded
in the package encoding, so their floats are rounded to their dtype before the next run reads
them, while the fed outputs are the values `Tensor.Eval` computed.

-}
runInElm : List Command -> Session msg -> Session msg
runInElm commands (Session s) =
    case s.backend of
        Host _ ->
            Session s

        InElm store0 ->
            let
                step command ( store, evs, stopped ) =
                    if stopped || store.finished then
                        ( store, evs, True )

                    else
                        case inElm s.graphs command store of
                            Ok ( store2, new_ ) ->
                                ( store2, List.reverse new_ ++ evs, False )

                            Err msg ->
                                ( store, EFailed msg :: evs, True )

                ( storeN, evsN, _ ) =
                    List.foldl step ( store0, [], False ) commands
            in
            Session { s | backend = InElm storeN, queue = s.queue ++ List.reverse evsN }


{-| Runs one command on an in-Elm session's store, given the graphs it holds, and returns the store
after it with the command's replies, or the reason it failed, which stops the commands after it.

A `load` or `loadRange` returns its `EFailed` as a reply instead, so the commands after it still
run.

-}
inElm : Dict Int GraphInfo -> Command -> Store -> Result String ( Store, List Ev )
inElm graphs command store =
    let
        noFiles what path =
            Ok ( store, [ EFailed (what ++ ": cannot open " ++ path ++ " (an in-Elm session reads no files)") ] )
    in
    case command of
        Run h inputs ->
            graphFor h graphs |> Result.andThen (\g -> runGraph h g inputs store)

        Put name b ->
            Ok ( { store | residents = Dict.insert name b store.residents }, [] )

        Get name ->
            Ok ( store, [ EGot name (Dict.get name store.residents |> Maybe.withDefault empty) ] )

        Save name path ->
            case Dict.get name store.residents of
                Just b ->
                    Ok ( { store | files = Dict.insert path b store.files }, [] )

                Nothing ->
                    Err ("save: no resident buffer " ++ name)

        LoadInto name path ->
            case Dict.get path store.files of
                Just b ->
                    Ok ( { store | residents = Dict.insert name b store.residents }, [] )

                Nothing ->
                    Err ("loadInto: cannot open " ++ path ++ " (an in-Elm session reads only files it saved)")

        LoadRangeInto _ path _ _ ->
            Err ("loadRangeInto: cannot open " ++ path ++ " (an in-Elm session reads no files)")

        Drop name ->
            if Dict.member name store.residents then
                Ok ( { store | residents = Dict.remove name store.residents }, [] )

            else
                Err ("drop: no resident buffer " ++ name)

        Load path ->
            noFiles "load" path

        LoadRange path _ _ ->
            noFiles "loadRange" path

        Finish code ->
            Ok ( { store | finished = True }, [ EFinished code ] )


{-| Runs the graph `g` with `Tensor.Eval` on the store's buffers and the fed `inputs`, and returns
the store after the run with its `ERan` reply, or why it fails.

Each fed input is taken from `inputs` as `givenInput` and `fedValue` take it, and each resident
input is its buffer decoded by the input's spec. `Tensor.Eval` is given them keyed as it requires,
by spec name and by resident name. A missing buffer, or one the spec cannot decode, fails the run,
as do an error from `Tensor.Eval`, whose messages are joined with `"; "`, and an output it does not
return or that cannot be encoded. A graph held without its `Tensor.Eval` form is refused.

Each resident output is encoded in the package encoding into its buffer, and each fed output is
put in the reply as the value `Tensor.Eval` computed. The buffers change only when the whole run
succeeds.

-}
runGraph : Handle -> GraphInfo -> List ( String, Input ) -> Store -> Result String ( Store, List Ev )
runGraph h g inputs store =
    let
        one spec acc =
            Result.map2 (::)
                (case spec.role of
                    Graph.Fed ->
                        givenInput g.name spec inputs
                            |> Result.andThen (fedValue g.name spec)
                            |> Result.map (\v -> ( spec.name, v ))

                    Graph.Resident n ->
                        case Dict.get n store.residents of
                            Nothing ->
                                Err (g.name ++ ": no resident buffer " ++ n)

                            Just b ->
                                Elements.decode spec b
                                    |> Result.map (\v -> ( n, v ))
                                    |> Result.mapError (\m -> g.name ++ ": resident buffer " ++ n ++ ": " ++ m)
                )
                acc

        written outs spec acc =
            case spec.role of
                Graph.Resident n ->
                    Result.map2 (\b ( rs, fed ) -> ( Dict.insert n b rs, fed ))
                        (Dict.get n outs
                            |> Result.fromMaybe (g.name ++ ": no output " ++ n)
                            |> Result.andThen Elements.encode
                        )
                        acc

                Graph.Fed ->
                    Result.map2 (\v ( rs, fed ) -> ( rs, Dict.insert spec.name (Computed v) fed ))
                        (Dict.get spec.name outs |> Result.fromMaybe (g.name ++ ": no output " ++ spec.name))
                        acc
    in
    case g.prepared of
        Nothing ->
            Err (g.name ++ ": not compiled for Tensor.Eval")

        Just prepared ->
            List.foldr one (Ok []) g.inputs
                |> Result.andThen (Dict.fromList >> Eval.runPrepared prepared >> Result.mapError (String.join "; "))
                |> Result.andThen (\outs -> List.foldl (written outs) (Ok ( store.residents, Dict.empty )) g.outputs)
                |> Result.map (\( rs, fed ) -> ( { store | residents = rs }, [ ERan h (Outputs fed) ] ))
