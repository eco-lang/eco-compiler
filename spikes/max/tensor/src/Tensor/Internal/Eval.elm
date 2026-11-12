module Tensor.Internal.Eval exposing (Ctx, V(..), evalRoots, postorderPruned)

{-| The evaluator's engine: expressions evaluated in post-order, each once per frame.

A traced body's nodes have the same keys every time it is evaluated (a `Var`'s key is made from its
scope and position only), so one memo for the whole graph would make a loop repeat its first
iteration. As lowering does, every evaluation of a body (a `Call`, the chosen branch of an `If`,
each test and each step of a `While`) gets a fresh frame, binding the body's `Var`s to its
arguments; lookups fall through to the outer frames (bodies may read outer expressions).

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Set exposing (Set)
import Tensor.Internal.Eval.Core as C exposing (T)
import Tensor.Internal.Eval.Prim as EvalPrim
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key exposing (Key)


{-| One result, or the results of a `Call`, `If` or `While`.
-}
type V
    = One T
    | Many (List T)


type alias Frame =
    { memo : Dict Key V, binds : Dict ( Key, Int ) T }


{-| The graph's inputs by position, and the `While` guard.
-}
type alias Ctx =
    { inputs : Array T, maxIterations : Int }


emptyFrame : Frame
emptyFrame =
    { memo = Dict.empty, binds = Dict.empty }


bindFrame : Key -> List T -> Frame
bindFrame scope values =
    { memo = Dict.empty, binds = Dict.fromList (List.indexedMap (\i v -> ( ( scope, i ), v )) values) }


known : List Frame -> Key -> Bool
known frames k =
    List.any (\f -> Dict.member k f.memo) frames


lookup : List Frame -> Key -> Maybe V
lookup frames k =
    case frames of
        [] ->
            Nothing

        f :: rest ->
            case Dict.get k f.memo of
                Just v ->
                    Just v

                Nothing ->
                    lookup rest k


lookupVar : List Frame -> ( Key, Int ) -> Maybe T
lookupVar frames k =
    case frames of
        [] ->
            Nothing

        f :: rest ->
            case Dict.get k f.binds of
                Just v ->
                    Just v

                Nothing ->
                    lookupVar rest k


{-| `Grad.postorder`, not descending into what `isKnown` finds already evaluated.
-}
postorderPruned : (Key -> Bool) -> List Expr -> List Expr
postorderPruned isKnown roots =
    let
        go stack visited acc =
            case stack of
                [] ->
                    List.reverse acc

                ( e, expanded ) :: rest ->
                    let
                        k =
                            E.key e
                    in
                    if expanded then
                        go rest visited (e :: acc)

                    else if Set.member k visited || isKnown k then
                        go rest visited acc

                    else
                        let
                            kids =
                                E.operands e
                                    |> List.filter (\o -> not (Set.member (E.key o) visited) && not (isKnown (E.key o)))
                                    |> List.map (\o -> ( o, False ))
                        in
                        go (kids ++ (( e, True ) :: rest)) (Set.insert k visited) acc
    in
    go (List.map (\r -> ( r, False )) roots) Set.empty []


{-| Evaluate `roots` in a new top frame over `outer`: their values, in order.
-}
evalRoots : Ctx -> List Frame -> Frame -> List Expr -> Result String (List V)
evalRoots ctx outer top roots =
    evalOrder ctx outer top (postorderPruned (known outer) roots) roots


evalOrder : Ctx -> List Frame -> Frame -> List Expr -> List Expr -> Result String (List V)
evalOrder ctx outer top order roots =
    let
        step es frame =
            case es of
                [] ->
                    Ok frame

                e :: rest ->
                    let
                        k =
                            E.key e
                    in
                    if Dict.member k frame.memo then
                        step rest frame

                    else
                        case evalNode ctx (frame :: outer) e of
                            Ok v ->
                                step rest { frame | memo = Dict.insert k v frame.memo }

                            Err msg ->
                                Err msg
    in
    step order top
        |> Result.andThen
            (\frame ->
                List.foldr
                    (\r acc ->
                        case lookup (frame :: outer) (E.key r) of
                            Just v ->
                                Result.map ((::) v) acc

                            Nothing ->
                                Err "internal: a root was not evaluated"
                    )
                    (Ok [])
                    roots
            )


one : List Frame -> Expr -> Result String T
one frames e =
    case lookup frames (E.key e) of
        Just (One t) ->
            Ok t

        Just (Many _) ->
            Err "internal: a multi-result operation used as a tensor"

        Nothing ->
            Err "internal: an operand was not evaluated"


ones : List Frame -> List Expr -> Result String (List T)
ones frames es =
    List.foldr (\e acc -> Result.map2 (::) (one frames e) acc) (Ok []) es


tensors : List V -> Result String (List T)
tensors vs =
    List.foldr
        (\v acc ->
            case v of
                One t ->
                    Result.map ((::) t) acc

                Many _ ->
                    Err "internal: a body output is not a tensor"
        )
        (Ok [])
        vs


body : Ctx -> List Frame -> E.Body -> List T -> Result String (List T)
body ctx frames b args =
    evalRoots ctx frames (bindFrame b.scope args) b.outputs |> Result.andThen tensors


evalNode : Ctx -> List Frame -> Expr -> Result String V
evalNode ctx frames e =
    case E.op e of
        E.Input _ i ->
            case Array.get i ctx.inputs of
                Just t ->
                    Ok (One t)

                Nothing ->
                    Err ("input " ++ String.fromInt i ++ " was not given")

        E.Var scope i ->
            case lookupVar frames ( scope, i ) of
                Just t ->
                    Ok (One t)

                Nothing ->
                    Err "internal: a function argument read outside its function"

        E.Const vs ->
            Ok (One (C.fromValues (E.dtype e) (E.shape e) vs))

        E.P p args params ->
            ones frames args
                |> Result.andThen (\ts -> EvalPrim.apply p ts params (E.meta e))
                |> Result.map One

        E.Proj src i ->
            case lookup frames (E.key src) of
                Just (Many ts) ->
                    case List.drop i ts of
                        t :: _ ->
                            Ok (One t)

                        [] ->
                            Err "internal: result index out of range"

                _ ->
                    Err "internal: a projection of a single result"

        E.Call _ b args ->
            ones frames args |> Result.andThen (body ctx frames b) |> Result.map Many

        E.If pred t f args ->
            Result.map2 Tuple.pair (one frames pred) (ones frames args)
                |> Result.andThen
                    (\( p, vs ) ->
                        let
                            chosen =
                                if C.getI (C.intsOf p) 0 /= 0 then
                                    t

                                else
                                    f
                        in
                        body ctx frames chosen vs |> Result.map Many
                    )

        E.While c b init ->
            ones frames init |> Result.andThen (loop ctx frames c b) |> Result.map Many


{-| Test, then step, until the test is false or the guard is passed. Each body's post-order is
computed once: the outer frames do not change during the loop.
-}
loop : Ctx -> List Frame -> E.Body -> E.Body -> List T -> Result String (List T)
loop ctx frames c b init =
    let
        cOrder =
            postorderPruned (known frames) c.outputs

        bOrder =
            postorderPruned (known frames) b.outputs

        go n state =
            if n > ctx.maxIterations then
                Err ("While: more than " ++ String.fromInt ctx.maxIterations ++ " iterations")

            else
                case evalOrder ctx frames (bindFrame c.scope state) cOrder c.outputs |> Result.andThen tensors of
                    Ok [ t ] ->
                        if C.getI (C.intsOf t) 0 /= 0 then
                            case evalOrder ctx frames (bindFrame b.scope state) bOrder b.outputs |> Result.andThen tensors of
                                Ok next ->
                                    go (n + 1) next

                                Err msg ->
                                    Err msg

                        else
                            Ok state

                    Ok _ ->
                        Err "While: the test must return one mask"

                    Err msg ->
                        Err msg
    in
    go 0 init
