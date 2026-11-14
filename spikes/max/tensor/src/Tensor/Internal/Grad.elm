module Tensor.Internal.Grad exposing
    ( Traced
    , grad
    , gradStructured
    , gradWrt
    , jvp
    , postorder
    , substitute
    , trace
    , vjp
    )

{-| Differentiating a function of tensors needs the function as an expression, and this module
turns a function into one and differentiates it in reverse mode.

A function can only be applied, not inspected. To _trace_ it is to apply it to _placeholders_
(`Var` leaves standing for its arguments) and keep the expressions it returns, which are written
in terms of them. Differentiating with respect to a placeholder, never an existing expression, is
what keeps a tensor the function closes over a constant: `grad (\y -> y * x) x` is `x`, not `2x`,
because the `y` being differentiated is a placeholder and the `x` is not. When the work on the
trace is done, `substitute` puts the actual arguments back in place of the placeholders.

A placeholder has its argument's dtype, shape and pending axes (axes whose size is not yet known,
as `Tensor.Internal.Shape` defines them), so inside a traced function an argument's pending axis
stays pending.

The placeholders of one trace share a _scope_, a key that each mixes into its own, so that
placeholders of different scopes are different expressions. Elm has no supply of fresh names, so
the scope is computed from what is traced: a string naming the kind of trace, the number and keys
of the arguments, and the keys of what the function returns on a first _probe_ trace, made on
placeholders of another scope. Two traces of one kind on the same arguments, such as a transform
applied inside another to the same tensors, therefore get different scopes unless their functions
return the same expressions on the probe. `trace` applies the function twice, and `vjp` and `jvp`
apply it once more, to the actual arguments, for its value.

A _cotangent_ of an expression is the gradient, with respect to that expression, of what is being
differentiated. `gradWrt` starts from _seeds_, expressions paired with their cotangents, and visits
every expression the seeds read, each after every expression that reads it, so that its cotangent
is complete when it is visited. It passes that cotangent on to the operands: a primitive by its
rule in `Tensor.Internal.Vjp`, a projection to the node it is a result of. The cotangents that
primitives and multi-result nodes pass to one operand are summed, each first summed down to the
operand's shape, because a rule may give one in its reader's shape.

Cotangents are passed only to _active_ expressions: the float expressions in `wrt`, float
expressions and multi-result nodes (`Call`, `If`, `While`) that read an active one, and multi-result
nodes whose bodies read a float `wrt` expression, directly or through expressions computed from it,
at any depth. An integer expression is not active, so no cotangent passes through it unless it is a
seed, and an integer expression of `wrt` gets zeros whatever the seeds are, even when it is a seed
itself: integer tensors have no derivatives.

A multi-result node is given its results' cotangents through its projections, and passes them on
when it is visited, counting a result with none as zero. An `If` and a `Call` do so through a
_vjp body_: a traced function that takes placeholders for the node's arguments followed by
placeholders for its results' cotangents, recomputes the forward values it needs, and returns the
arguments' cotangents. An `If` passes them on through a new `If` on the same predicate whose
branches are the vjp bodies of its own; a `Call` of a function named `name` through a call of a
function named `name ++ "_vjp"` whose body is the vjp body of its own. Only active float arguments
get a cotangent, and an `If`'s predicate gets none. A vjp body differentiates only with respect to
the body's placeholders. A float `wrt` expression that a body of the node reads directly, rather
than through the node's arguments, is checked instead: when a cotangent of the node's results
reaches it inside that body, it gets a cotangent failed with the build error "a shared function or
cond branch reads a tensor being differentiated that is not one of its arguments, so its gradient
cannot be found (pass it in the signature)". One that no cotangent reaches there, such as one read
only through `stopGradient`, gets nothing through the node.

A `While` is not differentiated. When a cotangent reaches one of its results, each of its active
float initial state values gets a cotangent that has failed with the build error "whileLoop: a loop
cannot be differentiated (use Control.repeat for a fixed count)". So does each float `wrt`
expression that its step body reads other than through the state: directly, through expressions
computed from it outside the loop, or from inside a body nested in the step body, a nested loop's
condition included. A `wrt` expression that only the loop's own condition
reads gets no cotangent through the loop, and no error.

`postorder` follows operands only. `substitute` also looks into the bodies of `Call`, `If` and
`While` nodes, so a loop or branch that reads a trace's placeholder directly reads the actual
argument once the placeholders are replaced.

-}

import Dict exposing (Dict)
import Set exposing (Set)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key as K exposing (Key)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Vjp as Vjp


{-| Returns every expression reachable from `roots` through operands, each once and after all of
its operands. Expressions are told apart by key, and the bodies of `Call`, `If` and `While` nodes
are not looked into. The first root and what it reads come before anything only a later root reads.

The walk keeps its own stack rather than recursing, so a deep expression cannot exhaust the call
stack.

-}
postorder : List Expr -> List Expr
postorder =
    walk E.operands


{-| Returns every expression reachable from `roots` through operands and through the outputs of the
bodies of `Call`, `If` and `While` nodes, nested bodies included, each once and after all of its
operands and of its bodies' outputs, in the order `postorder` gives.
-}
deepPostorder : List Expr -> List Expr
deepPostorder =
    walk (\e -> E.operands e ++ List.concatMap .outputs (E.bodies e))


{-| Returns every expression reachable from `roots` through `children`, each once and after all of
its children, the first root and what it reaches first. The walk keeps its own stack rather than
recursing.
-}
walk : (Expr -> List Expr) -> List Expr -> List Expr
walk children roots =
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
                                children e |> List.filter (\o -> not (Set.member (E.key o) visited)) |> List.map (\o -> ( o, False ))
                        in
                        go (kids ++ (( e, True ) :: rest)) (Set.insert k visited) acc
    in
    go (List.map (\r -> ( r, False )) roots) Set.empty []


{-| Returns the cotangent of each expression in `wrt`, accumulated from `seeds`, each an expression
paired with its cotangent, as the module docstring describes.

A float `wrt` expression that no cotangent reaches, and every integer one, gets zeros of its dtype
and shape.
Seed cotangents are used as given, while a cotangent that a primitive or a multi-result node
passes to an operand is first summed down to the operand's shape.

-}
gradWrt : List ( Expr, Expr ) -> List Expr -> List Expr
gradWrt seeds wrt =
    let
        final =
            cotangentMap seeds wrt
    in
    List.map
        (\w ->
            if P.isFloat (E.dtype w) then
                Dict.get (E.key w) final |> Maybe.withDefault (O.zerosLike w)

            else
                O.zerosLike w
        )
        wrt


{-| Returns the cotangents that `gradWrt` accumulates from `seeds`, by key: an expression that no
cotangent reaches has no entry, which is how `gradWrt` tells it apart from one whose cotangent is
zero.
-}
cotangentMap : List ( Expr, Expr ) -> List Expr -> Dict Key Expr
cotangentMap seeds wrt =
    let
        order =
            postorder (List.map Tuple.first seeds)

        wrtKeys =
            Set.fromList (List.map E.key (List.filter (\w -> P.isFloat (E.dtype w)) wrt))

        active =
            List.foldl
                (\e acc ->
                    let
                        k =
                            E.key e

                        isMulti =
                            not (List.isEmpty (E.node e).results)

                        isActive =
                            Set.member k wrtKeys
                                || (P.isFloat (E.dtype e) || isMulti)
                                && List.any (\o -> Set.member (E.key o) acc) (E.operands e)
                                || isMulti
                                && List.any (\x -> Set.member (E.key x) wrtKeys) (reach (List.concatMap .outputs (E.bodies e)))
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
                            ( multiVjp e slots active wrt cots, multi )

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
    in
    List.foldl step ( seeded, Dict.empty ) (List.reverse order) |> Tuple.first


{-| Returns `cots` with the cotangents that the multi-result node `e` passes to its operands added,
given its results' cotangents by result index in `slots`, where a missing one counts as zero.

An `If` passes them through an `If` on the same predicate over the vjp bodies of its branches, and
a `Call` of `name` through a call of `name ++ "_vjp"` on the vjp body of its body, to its operands
in `active` with a float dtype. Each float expression of `wrt` that `reach` finds from the outputs
of its bodies, and that `cotangentMap` finds a cotangent for inside one of them, gets a zero
cotangent failed with `capturedMessage`.

A `While` gives a zero cotangent failed with `loopMessage` to each of its initial state values in
`active` with a float dtype, and to each float expression of `wrt` that `reach` finds from the
outputs of its step body. Any other expression passes none.

-}
multiVjp : Expr -> Dict Int Expr -> Set ( Int, Int ) -> List Expr -> Dict Key Expr -> Dict Key Expr
multiVjp e slots active wrt cots =
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

        addCot a c acc =
            Dict.update (E.key a)
                (\old ->
                    case old of
                        Just o ->
                            Just (O.add o (fit a c))

                        Nothing ->
                            Just (fit a c)
                )
                acc

        addTo a c acc =
            if Set.member (E.key a) active && P.isFloat (E.dtype a) then
                addCot a c acc

            else
                acc

        spread node args acc =
            List.foldl (\( j, a ) cs -> addTo a (E.proj node j) cs) acc (List.indexedMap Tuple.pair args)

        failAll msg ws acc =
            List.foldl (\w acc2 -> addCot w (E.failWith msg (O.zerosLike w)) acc2) acc ws

        -- A wrt tensor that a body reads directly, rather than through the node's operands, is
        -- found by walking the body.
        readIn bodies =
            let
                reachedKeys =
                    Set.fromList (List.map E.key (reach (List.concatMap .outputs bodies)))
            in
            List.filter (\w -> Set.member (E.key w) reachedKeys) wrt

        -- Of the float wrt tensors that `bodies` read directly, those a cotangent of the node's
        -- results reaches inside one of them.
        capturedBy bodies =
            case List.filter (\w -> P.isFloat (E.dtype w)) (readIn bodies) of
                [] ->
                    []

                candidates ->
                    let
                        reached =
                            List.foldl (\b acc -> Dict.union (cotangentMap (List.map2 Tuple.pair b.outputs cotangents) candidates) acc) Dict.empty bodies
                    in
                    List.filter (\w -> Dict.member (E.key w) reached) candidates
    in
    case E.op e of
        E.If pred t f args ->
            let
                node =
                    E.ifThen pred (vjpBody t args cotangents) (vjpBody f args cotangents) (args ++ cotangents)
            in
            spread node args cots
                |> failAll capturedMessage (capturedBy [ t, f ])

        E.Call name body args ->
            let
                node =
                    E.call (name ++ "_vjp") (vjpBody body args cotangents) (args ++ cotangents)
            in
            spread node args cots
                |> failAll capturedMessage (capturedBy [ body ])

        E.While _ body init ->
            let
                isFloat a =
                    P.isFloat (E.dtype a)

                failed =
                    List.filter (\a -> Set.member (E.key a) active && isFloat a) init
                        ++ List.filter isFloat (readIn [ body ])
            in
            failAll loopMessage failed cots

        _ ->
            cots


{-| The build error on the cotangents that pass through a `While`.
-}
loopMessage : String
loopMessage =
    "whileLoop: a loop cannot be differentiated (use Control.repeat for a fixed count)"


{-| The build error on the cotangent of a tensor being differentiated that the body of a `Call` or
of an `If` branch reads directly, rather than through the node's arguments, when a cotangent
reaches it inside that body.
-}
capturedMessage : String
capturedMessage =
    "a shared function or cond branch reads a tensor being differentiated that is not one of its arguments, so its gradient cannot be found (pass it in the signature)"


{-| Returns every expression reachable from `roots`, each once and in no particular order, through
operands and through the outputs of the bodies of `Call`, `If` and `While` nodes, nested bodies
included.

The walk keeps its own stack rather than recursing, so a deep expression cannot exhaust the call
stack.

-}
reach : List Expr -> List Expr
reach roots =
    let
        bodyOutputs x =
            case E.op x of
                E.Call _ b _ ->
                    b.outputs

                E.If _ t f _ ->
                    t.outputs ++ f.outputs

                E.While c b _ ->
                    c.outputs ++ b.outputs

                _ ->
                    []

        go stack visited acc =
            case stack of
                [] ->
                    acc

                x :: rest ->
                    if Set.member (E.key x) visited then
                        go rest visited acc

                    else
                        go (E.operands x ++ bodyOutputs x ++ rest) (Set.insert (E.key x) visited) (x :: acc)
    in
    go roots Set.empty []


{-| Returns the keys of the placeholders of `body`'s own scope that its outputs read, by argument
position, as `reach` finds them: through operands and inside the bodies of nested `Call`, `If` and
`While` nodes. An argument the outputs never read has no entry.
-}
bodyVarKeys : E.Body -> Dict Int Key
bodyVarKeys body =
    reach body.outputs
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


{-| Returns the vjp body of `body` applied to `args`, with `cotangents` for its outputs: a traced
function whose arguments are placeholders for `args` followed by placeholders for `cotangents`, and
whose outputs are the cotangents of the placeholders for `args`, zeros where none arrives.

Its outputs recompute the forward values of `body` that they need, from its own placeholders.
`args` and `cotangents` serve only to give those placeholders their dtypes and shapes and the trace
its scope. Only `body`'s own placeholders are replaced, wherever the body reads them, nested bodies
included, so anything else the body reads is a constant of the result.

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


{-| Returns the cotangent `c` summed down to the shape of `operand` by
`Tensor.Internal.Ops.unbroadcast`, which gives `c` itself when the shapes already agree. A pending
axis of `operand` counts as size 1, so `c` is summed over it.
-}
fit : Expr -> Expr -> Expr
fit operand c =
    O.unbroadcast (E.shape operand) c



-- TRACING


{-| A traced function: the placeholders it was applied to, one per argument and in order
(`vars`), the outputs it gave on them, and `scope`, the key those placeholders share.
-}
type alias Traced =
    { vars : List Expr, outputs : List Expr, scope : Key }


{-| Returns one placeholder of scope `scope` for each of `args`, numbered by position, with that
argument's dtype, shape and pending axes.
-}
placeholders : Key -> List Expr -> List Expr
placeholders scope args =
    List.indexedMap (\i a -> E.varMeta scope i (E.meta a)) args


{-| Returns `f` traced on placeholders for `args`, whose scope is made from `kind`, the number and
keys of `args`, and the keys of `f`'s outputs on a probe trace, as the module docstring describes.
`f` is applied twice: to the probe's placeholders, and to the returned `vars`.
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


{-| Returns `roots` with every expression whose key is in `mapping` replaced by its value there,
and every expression above a replaced one rebuilt: on its new operands by
`Tensor.Internal.Expr.rebuild`, and, for a `Call`, `If` or `While` node whose bodies' outputs read
a replaced expression, with those outputs replaced in the same way, at any depth, by
`Tensor.Internal.Expr.mapBodies`. An expression none of whose operands or bodies' outputs changed
key is kept as it is.

The replacements are not themselves walked. A rebuilt expression keeps a build error that
`Tensor.Internal.Expr.failWith` recorded on the original.

-}
substitute : Dict Key Expr -> List Expr -> List Expr
substitute mapping roots =
    let
        lookup acc o =
            Dict.get (E.key o) acc |> Maybe.withDefault o

        changed acc xs =
            List.any (\o -> E.key (lookup acc o) /= E.key o) xs

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

                                rebuilt =
                                    if changed acc ops then
                                        E.rebuild e (List.map (lookup acc) ops)

                                    else
                                        e

                                remade =
                                    if changed acc (List.concatMap .outputs (E.bodies e)) then
                                        E.mapBodies (\b -> { b | outputs = List.map (lookup acc) b.outputs }) rebuilt

                                    else
                                        rebuilt
                            in
                            Dict.insert (E.key e) remade acc
                )
                Dict.empty
                (deepPostorder roots)
    in
    List.map (lookup memo) roots


{-| Returns the mapping for `substitute` that replaces each of `vars` by the expression at the same
position in `actual`.
-}
bind : List Expr -> List Expr -> Dict Key Expr
bind vars actual =
    Dict.fromList (List.map2 (\v a -> ( E.key v, a )) vars actual)



-- TRANSFORMS


{-| Returns, for a float `x` and a float result of `f`, the gradient at `x` of the sum of the
elements of that result, which for a scalar `f` is its gradient. Nothing here checks that `f` gives
a scalar.
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


{-| Returns `f`'s outputs at `xs`, and the pullback: a function from cotangents of those outputs,
in order, to the cotangents of `xs`, in order.

The cotangents are used as given, not summed down to their outputs' shapes. A list shorter than
the outputs leaves the remaining outputs with a zero cotangent.

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


{-| Returns `f`'s outputs at `xs`, and their tangents given the tangents `ts` of `xs`: the
Jacobian-vector product, computed in reverse mode.

`f`'s pullback is applied to placeholders for the outputs' cotangents, which gives the cotangents
of `xs` as expressions linear in those placeholders, and these are differentiated in turn with
respect to the placeholders, with `ts` as their cotangents. The pullback of a linear function is its
transpose, so this gives the Jacobian of `f` applied to `ts`. Any cotangent placeholder the result
still reads is then replaced by zeros.

The pullback's own expressions are differentiated by the rules of `Tensor.Internal.Vjp`, and where
a rule gives no gradient, that part of the tangent is left out without an error. A rule that gives
a cotangent failed with a build error, such as that of the dilated convolution that is a strided
convolution's filter pullback, gives a tangent carrying that error.

A cotangent of `xs` that has failed with a build error, as through a `whileLoop` or `topK`'s values,
reads no cotangent placeholder, so differentiating the pullback leaves it out. Instead, when the
pullback carries a build error, on its expressions or inside the bodies of nodes they read, the
pullback of each output is made alone, and the tangent of each output whose own pullback carries
one is failed with one of those errors. The other tangents are kept.

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

        -- A failed cotangent reads no cotangent placeholder, so differentiating `pulled` with
        -- respect to `us` drops it, and its build error with it. The tangent of each output whose
        -- own pullback has failed is failed with that error instead.
        failedFor out u =
            anyProblem (gradWrt [ ( out, u ) ] t.vars)

        checked =
            if anyProblem pulled == Nothing then
                pushed

            else
                List.map3
                    (\out u tangent ->
                        case failedFor out u of
                            Just msg ->
                                E.failWith msg tangent

                            Nothing ->
                                tangent
                    )
                    t.outputs
                    us
                    pushed
    in
    ( f xs, checked )


{-| Returns one of the build errors recorded on the expressions that `reach` finds from `roots`, or
`Nothing` when there is none. Unlike a poisoned expression, which only operands make, this finds an
error inside the body of a `Call`, `If` or `While` node.
-}
anyProblem : List Expr -> Maybe String
anyProblem roots =
    List.filterMap E.problem (reach roots) |> List.head


{-| Returns `loss value`, and, for a float loss, its gradient with respect to the float tensors of
`value` as a value of the same structure: `flatten` lists a value's tensors, and the gradient is
`build` applied to one cotangent per tensor of `flatten value`.

What is differentiated is `\xs -> loss (build xs)` at `flatten value`, which is `loss` at `value`
when `build` undoes `flatten`; nothing checks that it does. As in `grad`, the gradient is that of
the sum of the loss's elements, and nothing checks that the loss is a scalar.

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
