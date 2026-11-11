module Tensor.Internal.Control exposing (cond, whileLoop)

{-| Branches and loops as single operations MAX runs: `mo.if` and `mo.while`.

Both trace their functions on placeholders. A branch's body is then *closed*: every tensor it reads
from outside (a captured value) becomes an extra operand of the `If`, so the branch is a function of
its operands only, and its gradient (another `If`) gives the captured values their cotangents.

-}

import Dict
import Set exposing (Set)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key exposing (Key)
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


{-| Tensors a traced body reads but does not compute from its placeholders: the largest such
expressions (constants excepted: they are written inside the branch).
-}
captures : Key -> List Expr -> List Expr
captures scope outputs =
    let
        order =
            Grad.postorder outputs

        depends =
            List.foldl
                (\e acc ->
                    let
                        isOwnVar =
                            case E.op e of
                                E.Var s _ ->
                                    s == scope

                                _ ->
                                    False
                    in
                    if isOwnVar || List.any (\o -> Set.member (E.key o) acc) (E.operands e) then
                        Set.insert (E.key e) acc

                    else
                        acc
                )
                Set.empty
                order

        isConst e =
            case E.op e of
                E.Const _ ->
                    True

                _ ->
                    False

        candidate e =
            not (Set.member (E.key e) depends) && not (isConst e)

        fromUsers =
            List.concatMap
                (\e ->
                    if Set.member (E.key e) depends then
                        List.filter candidate (E.operands e)

                    else
                        []
                )
                order

        fromOutputs =
            List.filter candidate outputs
    in
    dedupe (fromUsers ++ fromOutputs)


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


{-| The traced body with the captured tensors replaced by placeholders after its own.
-}
close : Grad.Traced -> Int -> List Expr -> E.Body
close traced n captured =
    let
        mapping =
            Dict.fromList (List.indexedMap (\j c -> ( E.key c, E.var traced.scope (n + j) (E.dtype c) (E.shape c) )) captured)
    in
    { scope = traced.scope, arity = n + List.length captured, outputs = Grad.substitute mapping traced.outputs }


sameMetas : List Expr -> List Expr -> Bool
sameMetas a b =
    List.map (\e -> ( E.shape e, E.dtype e )) a == List.map (\e -> ( E.shape e, E.dtype e )) b


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

        node0 =
            E.ifThen p (close tt n captured) (close ft n captured) (xs ++ captured)

        node =
            if E.shape p /= [] || E.dtype p /= Bool then
                E.failWith "cond: the predicate must be a scalar mask" node0

            else if not (sameMetas tt.outputs ft.outputs) then
                E.failWith "cond: the two branches' results differ in shape or dtype" node0

            else
                node0
    in
    Tuple.first (sb.build (List.indexedMap (\i _ -> E.proj node i) tt.outputs))


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

                    else if not (sameMetas bt.outputs xs) then
                        E.failWith "whileLoop: the body must keep the state's shapes and dtypes" node0

                    else
                        node0

                _ ->
                    node0
    in
    Tuple.first (ss.build (List.indexedMap (\i _ -> E.proj node i) xs))
