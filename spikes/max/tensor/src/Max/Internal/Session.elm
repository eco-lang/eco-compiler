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

{-| `Max.Session` runs graphs and keeps resident buffers either through the MAX host or in Elm, and
this module holds what it is made of: its opaque types, which `Max.Session` names as aliases, and
the work each backend does that needs no `Cmd`, so that tests can check it directly.

A session has a _queue_ of replies it made itself, as opposed to replies from the host: everything
the in-Elm backend answers, and, on either backend, a command refused before it was sent. Each one
is handed out by one `Next` message, oldest first, so replies reach the program in the order they
were made whatever order the runtime delivers `Next` messages in.

Every graph compiled in a session has an id the session chose, its `Handle`. Requests whose replies
must be matched to what was asked (`get`, `load`, `loadRange`) are given ids from the same counter,
and the session remembers what each one asked for until its reply arrives.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict exposing (Dict)
import Graph
import Max.Internal.Elements as Elements
import Max.Internal.Protocol as Protocol exposing (Request)
import Tensor.Eval as Eval exposing (Value)


{-| A graph compiled in a session, identified by the id the session gave it.
-}
type Handle
    = Handle Int


{-| The value of a fed input given to a run.

`InBytes` is the input's bytes in the package encoding. `InValue` is a whole value. `InFloats` and
`InInts` are elements only, the dtype and shape being the input's own.

-}
type Input
    = InBytes Bytes
    | InValue Value
    | InFloats (List Float)
    | InInts (List Int)


{-| One thing a session is asked to do, before ids are given to it.

`LoadRangeInto` carries the buffer's name, the path, the offset and the length. `LoadRange` carries
the path, the offset and the length. `Save` and `LoadInto` carry the buffer's name, then the path.

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


{-| One fed output of a run: the bytes the host sent with the output's spec, or the value
`Tensor.Eval` computed.
-}
type Out
    = Raw Graph.Spec Bytes
    | Computed Value


{-| The fed outputs of one run, by their spec's names. Of two outputs with one name, the last is
kept.
-}
type Outputs
    = Outputs (Dict String Out)


{-| A message for a session: a reply from the host, or the signal to hand out the oldest reply in
the queue.
-}
type Message
    = Reply Bytes
    | Next


{-| A reply to a program, as `Max.Session.Event` gives it to the program, constructor for
constructor.
-}
type Ev
    = ECompiled Handle
    | ECompileFailed Handle String
    | ERan Handle Outputs
    | EGot String Bytes
    | ELoaded String Bytes
    | EFailed String
    | EFinished Int


{-| What runs a session's commands: the host, over two ports, or Elm, holding its buffers in a
`Store`.
-}
type Backend msg
    = Host { send : Bytes -> Cmd msg, receive : (Bytes -> msg) -> Sub msg }
    | InElm Store


{-| The buffers of an in-Elm session: its resident buffers by name, and the files it saved, by
path, each as bytes in the package encoding. `finished` is `True` once a `finish` has been run.
-}
type alias Store =
    { residents : Dict String Bytes, files : Dict String Bytes, finished : Bool }


{-| What a session knows of a compiled graph. `prepared` is the graph compiled for `Tensor.Eval`,
and is `Nothing` on the host backend.
-}
type alias GraphInfo =
    { name : String, inputs : List Graph.Spec, outputs : List Graph.Spec, prepared : Maybe Eval.Prepared }


{-| What a request waiting for its reply asked for: a resident buffer, by name, or a file, by path.
-}
type Pending
    = ForGet String
    | ForLoad String


{-| A session: its backend, how its messages reach the program, its compiled graphs by id, the
requests waiting for replies by id, and its queue, oldest first. `nextId` is the next id to give;
ids start at 1, since 0 marks a request that expects no reply.
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


{-| Creates a session with no graphs, no buffers and an empty queue.
-}
new : Backend msg -> (Message -> msg) -> Session msg
new backend toMsg =
    Session { toMsg = toMsg, backend = backend, nextId = 1, graphs = Dict.empty, pending = Dict.empty, queue = [] }


{-| Gives a graph a new id, and remembers it under that id unless `Nothing` is given.
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


{-| Forgets a graph, so that a run of it is refused.
-}
dropGraph : Handle -> Session msg -> Session msg
dropGraph (Handle id) (Session s) =
    Session { s | graphs = Dict.remove id s.graphs }


{-| Adds a reply to the end of the queue.
-}
enqueue : Ev -> Session msg -> Session msg
enqueue ev (Session s) =
    Session { s | queue = s.queue ++ [ ev ] }


{-| Returns the number of replies in the queue.
-}
queued : Session msg -> Int
queued (Session s) =
    List.length s.queue


{-| Takes the oldest reply off the queue. With nothing queued, the reply is an `EFailed` saying so.
-}
pop : Session msg -> ( Session msg, Ev )
pop (Session s) =
    case s.queue of
        ev :: rest ->
            ( Session { s | queue = rest }, ev )

        [] ->
            ( Session s, EFailed "Max.Session: no reply is waiting" )


{-| Returns the empty `Bytes`.
-}
empty : Bytes
empty =
    Bytes.Encode.encode (Bytes.Encode.sequence [])


{-| Returns the output named `name`, if there is one.
-}
lookup : String -> Outputs -> Maybe Out
lookup name (Outputs d) =
    Dict.get name d


{-| Returns the graph a handle names, or why a run of it is refused: the session does not hold it,
or, on the in-Elm backend, holds it without its `Tensor.Eval` form.
-}
graphFor : Handle -> Dict Int GraphInfo -> Result String GraphInfo
graphFor (Handle id) graphs =
    case Dict.get id graphs of
        Just g ->
            Ok g

        Nothing ->
            Err ("run: graph " ++ String.fromInt id ++ " is not compiled in this session")


{-| Returns the value given under `spec`'s name in `inputs` (the first one, if there are several),
or a message, starting with the graph's name, saying that none was given.
-}
givenInput : String -> Graph.Spec -> List ( String, Input ) -> Result String Input
givenInput graphName spec inputs =
    case List.filter (\( n, _ ) -> n == spec.name) inputs of
        ( _, i ) :: _ ->
            Ok i

        [] ->
            Err (graphName ++ ": missing input " ++ spec.name)


{-| Returns the value an input stands for, of the spec's dtype and shape, or why it does not fit,
in a message starting with the graph's name and the input's. `InBytes` is decoded by the spec, and
the others are checked against it as `Max.Internal.Elements.check` checks a value.
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


{-| Returns the bytes of a fed input for the host, or why it does not fit, as `fedValue` words it:
`InBytes` as given, if it is as wide as the spec says, and the others encoded once `fedValue` has
checked them.
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


{-| Returns the requests that carry `commands` to the host, in order, with ids given to those that
expect a reply and the session remembering what each of those asked for; or the first reason a
command cannot be sent, with the session unchanged.

A run is refused when its graph is not compiled in this session, when a fed input is missing, and
when one does not fit its spec (see `fedBytes`).

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


{-| Reads a reply from the host and returns what it answers, with the session no longer waiting for
it. A reply the session cannot match to a request, or whose payload does not fit what was asked,
gives an `EFailed` saying so.

A failed compile is answered with `ECompileFailed`, and the graph is forgotten. A failed `load` or
`loadRange` gives an `EFailed` with the host's message.

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


{-| Runs `commands` in order on an in-Elm session and adds their replies to its queue.

A command that fails adds an `EFailed`. After a failed `load` or `loadRange` the next commands still
run; after any other failure the rest of `commands` is skipped. Once a `finish` has run, it adds
`EFinished` and every later command is ignored, in this call and in later ones. On the host backend
this does nothing.

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


{-| Runs one command on an in-Elm session's buffers, giving the buffers after it and its replies,
or the message of a failure that stops the commands after it.
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


{-| Runs a graph with `Tensor.Eval`: its fed inputs from `inputs`, its resident inputs decoded from
their buffers by the graph's specs. Its resident outputs are encoded back into their buffers, and
its fed outputs are the reply.
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
