module Tensor.Internal.Grad exposing
    ( postorder, gradWrt, trace, Traced, substitute, grad, vjp, jvp, gradStructured, bodyVarKeys
    )

{-| Reverse-mode differentiation over expression DAGs, the tracing of functions on placeholders,
and substitution. Every walk is iterative (an explicit stack), so deep graphs cannot overflow.

**Placeholders.** A transform traces its function on fresh placeholders and differentiates with
respect to them, never with respect to an existing node: `grad (\y -> y * x) x` must be x, not 2x.
Pure Elm has no name supply, so a placeholder's key is made from the transform kind, the keys of the
actual arguments and the key of a first *probe* trace's result; two nested transforms at one point
then get different placeholders, because the outer body contains the inner one.

-}

import Dict exposing (Dict)
import Set exposing (Set)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key as K exposing (Key)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Vjp as Vjp


{-| Every expression reachable from `roots` (through operands), each after its operands.
-}
postorder : List Expr -> List Expr
postorder roots =
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

                    else if Set.member k visited then
                        go rest visited acc

                    else
                        let
                            kids =
                                E.operands e |> List.filter (\o -> not (Set.member (E.key o) visited)) |> List.map (\o -> ( o, False ))
                        in
                        go (kids ++ (( e, True ) :: rest)) (Set.insert k visited) acc
    in
    go (List.map (\r -> ( r, False )) roots) Set.empty []


{-| The cotangents of `wrt` given seed cotangents for some expressions (`( output, cotangent )`).
Expressions `wrt` does not reach get zeros.
-}
gradWrt : List ( Expr, Expr ) -> List Expr -> List Expr
gradWrt seeds wrt =
    let
        order =
            postorder (List.map Tuple.first seeds)

        wrtKeys =
            Set.fromList (List.map E.key wrt)

        active =
            List.foldl
                (\e acc ->
                    let
                        k =
                            E.key e

                        isActive =
                            Set.member k wrtKeys
                                || (P.isFloat (E.dtype e) || not (List.isEmpty (E.node e).results))
                                && List.any (\o -> Set.member (E.key o) acc) (E.operands e)
                    in
                    if isActive then
                        Set.insert k acc

                    else
                        acc
                )
                Set.empty
                order

        addCot k c cots =
            Dict.update k
                (\old ->
                    case old of
                        Just o ->
                            Just (O.add o c)

                        Nothing ->
                            Just c
                )
                cots

        seeded =
            List.foldl (\( e, c ) acc -> addCot (E.key e) c acc) Dict.empty seeds

        give a c acc =
            if Set.member (E.key a) active then
                addCot (E.key a) (fit a c) acc

            else
                acc

        step e ( cots, multi ) =
            case Dict.get (E.key e) cots of
                Nothing ->
                    case Dict.get (E.key e) multi of
                        Just slots ->
                            ( multiVjp e slots active cots, multi )

                        Nothing ->
                            ( cots, multi )

                Just g ->
                    if Set.member (E.key e) wrtKeys && List.isEmpty (E.operands e) then
                        ( cots, multi )

                    else
                        case E.op e of
                            E.P p args params ->
                                let
                                    contributions =
                                        Vjp.rule p args params e g
                                in
                                ( List.foldl
                                    (\( a, c ) acc ->
                                        case c of
                                            Just ca ->
                                                give a ca acc

                                            Nothing ->
                                                acc
                                    )
                                    cots
                                    (List.map2 Tuple.pair args contributions)
                                , multi
                                )

                            E.Proj source i ->
                                ( cots
                                , Dict.update (E.key source)
                                    (\old -> Just (Dict.insert i g (Maybe.withDefault Dict.empty old)))
                                    multi
                                )

                            _ ->
                                ( cots, multi )

        ( final, _ ) =
            List.foldl step ( seeded, Dict.empty ) (List.reverse order)
    in
    List.map (\w -> Dict.get (E.key w) final |> Maybe.withDefault (O.zerosLike w)) wrt


{-| The vjp of a multi-result operation, given its results' cotangents (by result index; missing
ones are zero): a branch's is a branch over the branches' vjps, a shared function's a call of its
backward subgraph (both recompute the forward values they need); a loop has none.
-}
multiVjp : Expr -> Dict Int Expr -> Set ( Int, Int ) -> Dict Key Expr -> Dict Key Expr
multiVjp e slots active cots =
    let
        n =
            List.length (E.node e).results

        cotOf i =
            case Dict.get i slots of
                Just c ->
                    c

                Nothing ->
                    O.zerosLike (E.proj e i)

        cotangents =
            List.map cotOf (List.range 0 (n - 1))

        addTo a c acc =
            if Set.member (E.key a) active && P.isFloat (E.dtype a) then
                Dict.update (E.key a)
                    (\old ->
                        case old of
                            Just o ->
                                Just (O.add o (fit a c))

                            Nothing ->
                                Just (fit a c)
                    )
                    acc

            else
                acc

        spread node args acc =
            List.foldl (\( j, a ) cs -> addTo a (E.proj node j) cs) acc (List.indexedMap Tuple.pair args)
    in
    case E.op e of
        E.If pred t f args ->
            let
                node =
                    E.ifThen pred (vjpBody t args cotangents) (vjpBody f args cotangents) (args ++ cotangents)
            in
            spread node args cots

        E.Call name body args ->
            let
                node =
                    E.call (name ++ "_vjp") (vjpBody body args cotangents) (args ++ cotangents)
            in
            spread node args cots

        E.While _ _ init ->
            List.foldl
                (\a acc -> addTo a (E.failWith "whileLoop: a loop cannot be differentiated (use Control.repeat for a fixed count)" (O.zerosLike a)) acc)
                cots
                init

        _ ->
            cots


{-| A body's placeholder keys by position.
-}
bodyVarKeys : E.Body -> Dict Int Key
bodyVarKeys body =
    postorder body.outputs
        |> List.filterMap
            (\x ->
                case E.op x of
                    E.Var scope i ->
                        if scope == body.scope then
                            Just ( i, E.key x )

                        else
                            Nothing

                    _ ->
                        Nothing
            )
        |> Dict.fromList


{-| The body computing a body's vjp: its arguments are the original arguments then the outputs'
cotangents; its outputs, the arguments' cotangents (the forward values are recomputed inside).
-}
vjpBody : E.Body -> List Expr -> List Expr -> E.Body
vjpBody body args cotangents =
    let
        n =
            List.length args

        traced =
            trace "body-vjp"
                (args ++ cotangents)
                (\vs ->
                    let
                        argVars =
                            List.take n vs

                        cotVars =
                            List.drop n vs

                        mapping =
                            Dict.fromList
                                (List.filterMap
                                    (\( i, v ) -> Dict.get i (bodyVarKeys body) |> Maybe.map (\k -> ( k, v )))
                                    (List.indexedMap Tuple.pair argVars)
                                )

                        outs =
                            substitute mapping body.outputs
                    in
                    gradWrt (List.map2 Tuple.pair outs cotVars) argVars
                )
    in
    { scope = traced.scope, arity = n + List.length cotangents, outputs = traced.outputs }


{-| A cotangent summed down to its operand's shape (batch axes, pending axes, scalars).
-}
fit : Expr -> Expr -> Expr
fit operand c =
    if E.shape c == E.shape operand then
        c

    else
        O.unbroadcast (E.shape operand) c



-- TRACING


type alias Traced =
    { vars : List Expr, outputs : List Expr, scope : Key }


placeholders : Key -> List Expr -> List Expr
placeholders scope args =
    List.indexedMap (\i a -> E.var scope i (E.dtype a) (E.shape a)) args


{-| `f` applied to placeholders shaped like `args`; see the module docs for how they are keyed.
-}
trace : String -> List Expr -> (List Expr -> List Expr) -> Traced
trace kind args f =
    let
        argKey k0 =
            List.foldl (\a k -> K.mixKey (E.key a) k) (K.start kind |> K.mix (List.length args)) args |> K.mixKey k0

        probeScope =
            argKey (K.start "probe")

        probe =
            f (placeholders probeScope args)

        scope =
            List.foldl (\o k -> K.mixKey (E.key o) k) (argKey (K.start "scope")) probe

        vars =
            placeholders scope args
    in
    { vars = vars, outputs = f vars, scope = scope }


{-| `roots` with every expression keyed in `mapping` replaced, and everything above rebuilt.
-}
substitute : Dict Key Expr -> List Expr -> List Expr
substitute mapping roots =
    let
        order =
            postorder roots

        memo =
            List.foldl
                (\e acc ->
                    case Dict.get (E.key e) mapping of
                        Just r ->
                            Dict.insert (E.key e) r acc

                        Nothing ->
                            let
                                ops =
                                    E.operands e

                                newOps =
                                    List.map (\o -> Dict.get (E.key o) acc |> Maybe.withDefault o) ops
                            in
                            if List.map E.key newOps == List.map E.key ops then
                                Dict.insert (E.key e) e acc

                            else
                                Dict.insert (E.key e) (E.rebuild e newOps) acc
                )
                Dict.empty
                order
    in
    List.map (\r -> Dict.get (E.key r) memo |> Maybe.withDefault r) roots


bind : List Expr -> List Expr -> Dict Key Expr
bind vars actual =
    Dict.fromList (List.map2 (\v a -> ( E.key v, a )) vars actual)



-- TRANSFORMS


{-| The gradient of the scalar function `f` at `x`.
-}
grad : (Expr -> Expr) -> Expr -> Expr
grad f x =
    let
        t =
            trace "grad" [ x ] (\vs -> List.map f vs)
    in
    case ( t.vars, t.outputs ) of
        ( [ v ], [ y ] ) ->
            gradWrt [ ( y, O.onesLike y ) ] [ v ]
                |> substitute (bind t.vars [ x ])
                |> List.head
                |> Maybe.withDefault (O.zerosLike x)

        _ ->
            O.zerosLike x


{-| The outputs of `f` at `xs`, and the pullback: output cotangents to input cotangents.
-}
vjp : (List Expr -> List Expr) -> List Expr -> ( List Expr, List Expr -> List Expr )
vjp f xs =
    let
        t =
            trace "vjp" xs f

        pullback cs =
            gradWrt (List.map2 Tuple.pair t.outputs cs) t.vars
                |> substitute (bind t.vars xs)
    in
    ( f xs, pullback )


{-| Forward mode by transposing the vjp: the vjp is linear in the cotangent `u`, and the vjp of
`u ↦ vjp(u)` at the tangents is the jvp.
-}
jvp : (List Expr -> List Expr) -> List Expr -> List Expr -> ( List Expr, List Expr )
jvp f xs ts =
    let
        t =
            trace "jvp" xs f

        us =
            .vars (trace "jvp-cotangent" t.outputs (\us_ -> us_))

        pulled =
            gradWrt (List.map2 Tuple.pair t.outputs us) t.vars

        pushed =
            gradWrt (List.map2 Tuple.pair pulled ts) us
                |> substitute (bind t.vars xs)
                |> substitute (Dict.fromList (List.map (\u -> ( E.key u, O.zerosLike u )) us))
    in
    ( f xs, pushed )


{-| The value and gradient of a scalar function of a structured value, given how to build the value
from tensors and flatten it back.
-}
gradStructured : (List Expr -> a) -> (a -> List Expr) -> (a -> Expr) -> a -> ( Expr, a )
gradStructured build flatten loss value =
    let
        xs =
            flatten value

        t =
            trace "gradOf" xs (\vs -> [ loss (build vs) ])
    in
    case t.outputs of
        [ y ] ->
            ( loss value
            , build (gradWrt [ ( y, O.onesLike y ) ] t.vars |> substitute (bind t.vars xs))
            )

        _ ->
            ( loss value, value )
