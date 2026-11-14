module Tensor.Internal.Control exposing (cond, inLoops, substituteInLoops, whileLoop)

{-| Which branch of a conditional runs, and how many times a loop repeats, depend on tensor values,
and making expressions computes no values, so neither can be decided while a graph is built. This
module makes each into one expression node that holds the functions it may run: `cond` makes an
`If` and `whileLoop` a `While`. Both are multi-result nodes, whose results are read through
projections, as `Tensor.Internal.Expr` describes.

A node holds the functions it runs, the two branches or a loop's test and step, as _bodies_: each is
traced by `Tensor.Internal.Grad.trace` on _placeholders_ (`Var` leaves standing for its arguments,
as `Tensor.Internal.Grad` defines them). The functions take structured Elm values and, except a
loop's test, which returns one `Expr`, return them, and a signature
(`Tensor.Internal.Types.SigBuilder`) turns such a value into its list of tensors and builds it back
from one, so that bodies and operands are lists of expressions.

A traced function may read tensors made outside it as well as its placeholders. An expression that
a branch reads but that does not depend on the branch's placeholders is _captured_ by it when it is
one of the branch's results or is read by an expression that does depend on them (`captures` says
exactly which). `cond` _closes_ its branches: each captured tensor becomes a further operand of the
`If`, after the argument's tensors, and inside each body it is replaced by a further placeholder
with its meta, pending axes included. Both branches are closed over one list, the captures of
either, because the `If` passes both bodies the same operands. Apart from the exceptions below, a
tensor a closed branch takes from outside is therefore an operand of the node, which is what lets a
gradient reach it: `Tensor.Internal.Grad` differentiates a body only with respect to its
placeholders.

`whileLoop` does not close its bodies: its test and step read tensors from outside directly, and
only the state is an operand of the `While`. So that a loop nested in a branch is closed with the
branch, the walks here (`inLoops`) follow a loop's test and step as well as operands: a tensor
that a nested loop's test or step reads from outside the branch is captured, and a nested loop
whose test or step reads the branch's placeholders depends on them, and stays in the branch, even
when its initial state does not. `Tensor.Internal.Batch` uses the same walk.

Closing has gaps:

  - A constant leaf is not captured and stays in the body. An expression computed only from
    constants is captured like any other.
  - The bodies of nested `Call` and `If` nodes are not looked into. A nested `cond` has closed its
    own branches, so what they read from outside is already an operand of its `If`.

Each node is checked once it is made, and the first check that fails is recorded on it with
`failWith`, which _poisons_ every result in `Tensor.Internal.Expr`'s sense: each is marked as built
on a failed expression. A check on a node that is already poisoned records nothing, so the first
build error stays the only one (`Tensor.Internal.Expr.failWith`).

-}

import Dict
import Set exposing (Set)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key exposing (Key)
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


{-| Returns the expressions `e` reads: its operands and, for a `While`, the outputs of its test and
step. These are the edges `inLoops`, `captures` and `substituteInLoops` follow, because a loop's
bodies are not closed and read tensors from outside directly. The bodies of `Call` and `If` nodes
are not included.
-}
loopReads : Expr -> List Expr
loopReads e =
    E.operands e ++ List.concatMap .outputs (loopBodies e)


{-| Returns the test and step of a `While`, and nothing for any other node.
-}
loopBodies : Expr -> List E.Body
loopBodies e =
    case E.op e of
        E.While _ _ _ ->
            E.bodies e

        _ ->
            []


{-| Returns every expression reachable from `roots` through `loopReads`, each once and after all of
the expressions it reads, as `Tensor.Internal.Grad.postorder` orders them for operands. The walk
keeps its own stack, so a deep expression cannot exhaust the call stack.
-}
inLoops : List Expr -> List Expr
inLoops roots =
    let
        go stack visited acc =
            case stack of
                [] ->
                    List.reverse acc

                ( e, expanded ) :: rest ->
                    if expanded then
                        go rest visited (e :: acc)

                    else if Set.member (E.key e) visited then
                        go rest visited acc

                    else
                        let
                            kids =
                                loopReads e |> List.filter (\o -> not (Set.member (E.key o) visited)) |> List.map (\o -> ( o, False ))
                        in
                        go (kids ++ (( e, True ) :: rest)) (Set.insert (E.key e) visited) acc
    in
    go (List.map (\r -> ( r, False )) roots) Set.empty []


{-| Returns `roots` with every expression for which `lookup` gives a replacement replaced by it, and
every expression above a replaced one rebuilt: its operands by `Tensor.Internal.Expr.rebuild`, and,
for a `While`, its test and step by `Tensor.Internal.Expr.mapBodies`, so a loop body that reads a
replaced expression directly reads the replacement. Both keep a message that
`Tensor.Internal.Expr.failWith` recorded on the expression they rebuild. An expression none of
whose operands or loop-body outputs changed key is kept as it is. The replacements are not
themselves walked, and the bodies of `Call` and `If` nodes are not looked into.
-}
substituteInLoops : (Expr -> Maybe Expr) -> List Expr -> List Expr
substituteInLoops lookup roots =
    let
        get acc o =
            Dict.get (E.key o) acc |> Maybe.withDefault o

        changed acc l =
            List.any (\o -> E.key (get acc o) /= E.key o) l

        memo =
            List.foldl
                (\e acc ->
                    case lookup e of
                        Just r ->
                            Dict.insert (E.key e) r acc

                        Nothing ->
                            let
                                ops =
                                    E.operands e

                                rebuilt =
                                    if changed acc ops then
                                        E.rebuild e (List.map (get acc) ops)

                                    else
                                        e

                                result =
                                    if changed acc (List.concatMap .outputs (loopBodies e)) then
                                        E.mapBodies (\b -> { b | outputs = List.map (get acc) b.outputs }) rebuilt

                                    else
                                        rebuilt
                            in
                            Dict.insert (E.key e) result acc
                )
                Dict.empty
                (inLoops roots)
    in
    List.map (get memo) roots


{-| Returns the tensors captured by the body traced as `outputs` on the placeholders of `scope`,
constant leaves excepted, listed once each.

An expression is _inside_ the body when it reads one of those placeholders, or a placeholder of a
loop body nested in it, through `loopReads`, so through the test and step of nested loops as well as
through operands. The tensors captured are the expressions that are not inside but are one of
`outputs` or are read through `loopReads` by an expression that is inside: a tensor read directly by
the step of a loop nested in the body is captured like one read by an operation of the body itself,
and a loop whose test or step reads the placeholders is inside, whatever its initial state reads.

A placeholder of another scope that is not a nested loop's counts as any other tensor, so it is
captured. The bodies of nested `Call` and `If` nodes are not looked into.

-}
captures : Key -> List Expr -> List Expr
captures scope outputs =
    let
        scopesRead =
            List.foldl
                (\e acc ->
                    let
                        own =
                            case E.op e of
                                E.Var s _ ->
                                    Set.singleton s

                                _ ->
                                    Set.empty

                        read =
                            List.foldl (\o s -> Set.union (Dict.get (E.key o) acc |> Maybe.withDefault Set.empty) s) own (loopReads e)
                    in
                    Dict.insert (E.key e) (Set.diff read (Set.fromList (List.map .scope (loopBodies e)))) acc
                )
                Dict.empty
                (inLoops outputs)

        isInside open e =
            not (Set.isEmpty (Set.intersect open (Dict.get (E.key e) scopesRead |> Maybe.withDefault Set.empty)))

        isConst e =
            case E.op e of
                E.Const _ ->
                    True

                _ ->
                    False

        candidate open e =
            not (isInside open e) && not (isConst e)

        go stack visited open acc =
            case stack of
                [] ->
                    List.reverse acc

                ( e, True ) :: rest ->
                    go rest visited open (List.reverse (List.filter (candidate open) (loopReads e)) ++ acc)

                ( e, False ) :: rest ->
                    if Set.member (E.key e) visited then
                        go rest visited open acc

                    else
                        let
                            open2 =
                                Set.union open (Set.fromList (List.map .scope (loopBodies e)))

                            kids =
                                loopReads e |> List.filter (\o -> isInside open2 o && not (Set.member (E.key o) visited)) |> List.map (\o -> ( o, False ))
                        in
                        go (kids ++ (( e, True ) :: rest)) (Set.insert (E.key e) visited) open2 acc

        start =
            Set.singleton scope

        fromUsers =
            go (outputs |> List.filter (isInside start) |> List.map (\o -> ( o, False ))) Set.empty start []

        fromOutputs =
            List.filter (candidate start) outputs
    in
    dedupe (fromUsers ++ fromOutputs)


{-| Returns `l` with only the first expression of each key, in their order in `l`.
-}
dedupe : List Expr -> List Expr
dedupe l =
    List.foldl
        (\e ( seen, acc ) ->
            if Set.member (E.key e) seen then
                ( seen, acc )

            else
                ( Set.insert (E.key e) seen, e :: acc )
        )
        ( Set.empty, [] )
        l
        |> Tuple.second
        |> List.reverse


{-| Returns `traced` as a closed body: each of `captured` that is one of its outputs, or that they
read through `loopReads`, is replaced by `substituteInLoops` with a placeholder of the trace's scope
with that tensor's meta (`Tensor.Internal.Expr.varMeta`), pending axes included, numbered from `n`
in the order of `captured`, and the arity is `n` plus the number of `captured`. `n` is taken to be
the trace's own number of arguments.
-}
close : Grad.Traced -> Int -> List Expr -> E.Body
close traced n captured =
    let
        mapping =
            Dict.fromList (List.indexedMap (\j c -> ( E.key c, E.varMeta traced.scope (n + j) (E.meta c) )) captured)
    in
    { scope = traced.scope, arity = n + List.length captured, outputs = substituteInLoops (\e -> Dict.get (E.key e) mapping) traced.outputs }


{-| Returns whether `a` and `b` are equally long and agree in meta at each position: in shape, in
pending axes and in dtype.
-}
sameMetas : List Expr -> List Expr -> Bool
sameMetas a b =
    List.map E.meta a == List.map E.meta b


{-| Returns `t a` when the predicate `p` holds and `f a` otherwise, as one `If` node over the closed
branches whose results are built into a `b` by `sb`.

The `If` reads `p`, then `a`'s tensors, then the tensors either branch captures, and its results
have the metas of the closed then-branch's results, pending axes included. It fails with "cond: the
predicate must be a scalar mask" when `p` is not a rank-0 `bool` tensor, and otherwise with "cond:
the two branches' results differ in shape or dtype" when the closed branches' results differ in
number or in meta: in shape, pending axes or dtype.

-}
cond : Expr -> I.SigBuilder a a -> I.SigBuilder b b -> (a -> b) -> (a -> b) -> a -> b
cond p (I.SigBuilder sa) (I.SigBuilder sb) t f a =
    let
        xs =
            sa.flatten a

        n =
            List.length xs

        build vs =
            Tuple.first (sa.build vs)

        tt =
            Grad.trace "cond-then" xs (\vs -> sb.flatten (t (build vs)))

        ft =
            Grad.trace "cond-else" xs (\vs -> sb.flatten (f (build vs)))

        captured =
            dedupe (captures tt.scope tt.outputs ++ captures ft.scope ft.outputs)

        thenBody =
            close tt n captured

        elseBody =
            close ft n captured

        node0 =
            E.ifThen p thenBody elseBody (xs ++ captured)

        node =
            if E.shape p /= [] || E.dtype p /= Bool then
                E.failWith "cond: the predicate must be a scalar mask" node0

            else if not (sameMetas thenBody.outputs elseBody.outputs) then
                E.failWith "cond: the two branches' results differ in shape or dtype" node0

            else
                node0
    in
    Tuple.first (sb.build (List.indexedMap (\i _ -> E.proj node i) thenBody.outputs))


{-| Returns the final state of a loop that starts from `init` and, while `continue` holds for the
state, replaces it with `body` applied to it, as one `While` node whose results are built into an
`s` by `ss`.

The `While`'s operands are `init`'s tensors, and its results have their metas. It fails with
"whileLoop: the condition must be a scalar mask" when `continue`'s result is not a rank-0 `bool`
tensor, and otherwise with "whileLoop: the body must keep the state's shapes and dtypes" when
`body`'s results differ in number or in meta (shape, pending axes or dtype) from the placeholders
it was traced on, which have the metas of `init`'s tensors.

-}
whileLoop : I.SigBuilder s s -> (s -> Expr) -> (s -> s) -> s -> s
whileLoop (I.SigBuilder ss) continue body init =
    let
        xs =
            ss.flatten init

        n =
            List.length xs

        build vs =
            Tuple.first (ss.build vs)

        ct =
            Grad.trace "while-cond" xs (\vs -> [ continue (build vs) ])

        bt =
            Grad.trace "while-body" xs (\vs -> ss.flatten (body (build vs)))

        node0 =
            E.while { scope = ct.scope, arity = n, outputs = ct.outputs } { scope = bt.scope, arity = n, outputs = bt.outputs } xs

        node =
            case ct.outputs of
                [ c ] ->
                    if E.shape c /= [] || E.dtype c /= Bool then
                        E.failWith "whileLoop: the condition must be a scalar mask" node0

                    else if not (sameMetas bt.outputs bt.vars) then
                        E.failWith "whileLoop: the body must keep the state's shapes and dtypes" node0

                    else
                        node0

                -- Never taken: the test is traced as a one-element list.
                _ ->
                    node0
    in
    Tuple.first (ss.build (List.indexedMap (\i _ -> E.proj node i) xs))
