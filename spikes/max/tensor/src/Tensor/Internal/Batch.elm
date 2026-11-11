module Tensor.Internal.Batch exposing (vmapRule, stack, unstack, unstack1)

{-| Vectorisation over a leading batch axis by batching rules.

`vmapRule leaves f` traces `f` once on per-example placeholders for the batched leaves, then
rewrites the trace: every expression that depends on a placeholder becomes its batched version (a
leading batch axis), by a rule per primitive — shifted axes for reductions, a broadcast axis for
an unbatched operand of an element-wise operation, aligned ranks for `matmul`. Random draws are
always batched, so each example gets its own values. Primitives without a rule here (convolution,
scatter, gathers with batched indices, branches, calls) are unrolled: applied per example and
stacked, which is exact.

-}

import Dict exposing (Dict)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key exposing (Key)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (Prim(..))


{-| Each example along axis 0.
-}
unstack : Expr -> List Expr
unstack x =
    let
        s =
            E.shape x

        n =
            List.head s |> Maybe.withDefault 0
    in
    List.map (example x) (List.range 0 (n - 1))


example : Expr -> Int -> Expr
example x k =
    let
        s =
            E.shape x
    in
    O.dropAxis 0 (O.slice (k :: List.map (\_ -> 0) (List.drop 1 s)) (1 :: List.drop 1 s) x)


{-| The first example and the rest (an empty batch gives a refused slice).
-}
unstack1 : Expr -> ( Expr, List Expr )
unstack1 x =
    case unstack x of
        a :: rest ->
            ( a, rest )

        [] ->
            ( example x 0, [] )


stack : List Expr -> Expr
stack xs =
    O.concat 0 (List.map (O.insertAxis 0) xs)


{-| `f` vectorised over the leaves marked batched (all with one leading batch size). `f` receives
per-example placeholders for those, in order, and returns a structured result with its leaf
tensors; the result comes back with the batched leaves.
-}
vmapRule : List ( Expr, Bool ) -> (List Expr -> ( r, List Expr )) -> ( r, List Expr )
vmapRule leaves f =
    let
        batched =
            List.filterMap
                (\( e, isBatched ) ->
                    if isBatched then
                        Just e

                    else
                        Nothing
                )
                leaves

        n =
            batched |> List.head |> Maybe.andThen (E.shape >> List.head) |> Maybe.withDefault 1

        perExample =
            List.map (\b -> O.slice (List.map (\_ -> 0) (E.shape b)) (1 :: List.drop 1 (E.shape b)) b |> O.dropAxis 0) batched

        traced =
            Grad.trace "vmap" perExample (\vs -> Tuple.second (f vs))

        ( result, _ ) =
            f traced.vars

        start =
            { batched = Dict.fromList (List.map2 (\v b -> ( E.key v, b )) traced.vars batched)
            , multi = Dict.empty
            }

        final =
            List.foldl (rewrite n) start (Grad.postorder traced.outputs)

        out e =
            case Dict.get (E.key e) final.batched of
                Just b ->
                    b

                Nothing ->
                    -- does not depend on the batch: the same value for every example
                    O.broadcastTo (n :: E.shape e) (O.insertAxis 0 e)
    in
    ( result, List.map out traced.outputs )


type alias State =
    { batched : Dict Key Expr, multi : Dict Key (List Expr) }


rewrite : Int -> Expr -> State -> State
rewrite n e st =
    if Dict.member (E.key e) st.batched then
        st

    else
        let
            ops =
                E.operands e

            anyBatched =
                List.any (\o -> Dict.member (E.key o) st.batched || Dict.member (E.key o) st.multi) ops

            isRandom =
                case E.op e of
                    E.P Random _ _ ->
                        True

                    _ ->
                        False
        in
        if not anyBatched && not isRandom then
            st

        else
            case E.op e of
                E.P p args params ->
                    case rule n p args params e st of
                        Just b ->
                            { st | batched = Dict.insert (E.key e) b st.batched }

                        Nothing ->
                            unroll n e st

                E.Proj source i ->
                    case Dict.get (E.key source) st.multi of
                        Just perEx ->
                            { st | batched = Dict.insert (E.key e) (stack (List.map (\pe -> E.proj pe i) perEx)) st.batched }

                        Nothing ->
                            st

                _ ->
                    unroll n e st


{-| Applied per example and stacked: exact, for primitives without a rule.
-}
unroll : Int -> Expr -> State -> State
unroll n e st =
    let
        ops =
            E.operands e

        operandAt k o =
            case Dict.get (E.key o) st.batched of
                Just b ->
                    example b k

                Nothing ->
                    o

        perExample =
            List.map (\k -> E.rebuild e (List.map (operandAt k) ops)) (List.range 0 (n - 1))
    in
    if List.isEmpty (E.node e).results then
        { st | batched = Dict.insert (E.key e) (stack perExample) st.batched }

    else
        { st | multi = Dict.insert (E.key e) perExample st.multi }


type Operand
    = Batched Expr
    | Plain Expr


{-| The batching rule of a primitive, given its operands (batched ones with a leading batch axis);
`Nothing` when it has none here (the caller unrolls).
-}
rule : Int -> Prim -> List Expr -> P.Params -> Expr -> State -> Maybe Expr
rule n p args params e st =
    let
        operands =
            List.map
                (\a ->
                    case Dict.get (E.key a) st.batched of
                        Just b ->
                            Batched b

                        Nothing ->
                            Plain a
                )
                args

        allBatched =
            List.all
                (\o ->
                    case o of
                        Batched _ ->
                            True

                        Plain _ ->
                            False
                )
                operands

        -- an unbatched operand of an element-wise operation: a broadcast axis in front (scalars
        -- broadcast as they are)
        elementwise o =
            case o of
                Batched b ->
                    b

                Plain x ->
                    if E.rank x == 0 then
                        x

                    else
                        O.broadcastAxis 0 x

        -- an unbatched operand materialised with the batch axis
        full o =
            case o of
                Batched b ->
                    b

                Plain x ->
                    O.broadcastTo (n :: E.shape x) (O.insertAxis 0 x)

        shifted f =
            case params.a of
                axis :: rest ->
                    Just { params | a = f axis :: rest }

                [] ->
                    Nothing

        single build =
            case operands of
                [ Batched b ] ->
                    Just (build b)

                _ ->
                    Nothing
    in
    case P.family p of
        P.Unary ->
            single (\b -> E.prim p [ b ] params)

        P.Binary ->
            Just (E.prim p (List.map elementwise operands) params)

        P.Ternary ->
            Just (E.prim p (List.map elementwise operands) params)

        P.Other ->
            case p of
                ReduceSum ->
                    axisRule shifted operands p

                ReduceMean ->
                    axisRule shifted operands p

                ReduceMax ->
                    axisRule shifted operands p

                ReduceMin ->
                    axisRule shifted operands p

                ArgMax ->
                    axisRule shifted operands p

                ArgMin ->
                    axisRule shifted operands p

                Softmax ->
                    axisRule shifted operands p

                LogSoftmax ->
                    axisRule shifted operands p

                CumSum ->
                    axisRule shifted operands p

                Pad ->
                    axisRule shifted operands p

                Reshape ->
                    single (\b -> E.prim Reshape [ b ] { params | a = n :: params.a, b = List.map ((+) 1) params.b })

                Transpose ->
                    single (\b -> E.prim Transpose [ b ] { params | a = 0 :: List.map ((+) 1) params.a })

                BroadcastTo ->
                    single
                        (\b ->
                            let
                                missing =
                                    List.length params.a - (E.rank b - 1)
                            in
                            E.prim BroadcastTo [ List.foldl (\_ acc -> O.insertAxis 1 acc) b (List.range 1 missing) ] { params | a = n :: params.a }
                        )

                Slice ->
                    single (\b -> E.prim Slice [ b ] { params | a = 0 :: params.a, b = n :: params.b })

                Concat ->
                    shifted ((+) 1) |> Maybe.map (\pa -> E.prim Concat (List.map full operands) pa)

                Gather ->
                    case operands of
                        [ Batched x, Plain idx ] ->
                            shifted ((+) 1) |> Maybe.map (\pa -> E.prim Gather [ x, idx ] pa)

                        _ ->
                            Nothing

                BandPart ->
                    single (\b -> E.prim BandPart [ b ] params)

                LayerNorm ->
                    case operands of
                        [ Batched x, Plain g, Plain bias ] ->
                            Just (E.prim LayerNorm [ x, g, bias ] params)

                        _ ->
                            Nothing

                Random ->
                    case params.a of
                        kind :: dt :: s ->
                            Just (E.prim Random args { params | a = kind :: dt :: n :: s })

                        _ ->
                            Nothing

                MatMul ->
                    matmulRule n operands e

                _ ->
                    if allBatched && List.isEmpty operands then
                        Nothing

                    else
                        Nothing


axisRule : ((Int -> Int) -> Maybe P.Params) -> List Operand -> Prim -> Maybe Expr
axisRule shifted operands p =
    case operands of
        [ Batched b ] ->
            shifted ((+) 1) |> Maybe.map (\pa -> E.prim p [ b ] pa)

        _ ->
            Nothing


{-| x @ w per example: both operands given a batch axis (an unbatched one as a broadcast axis),
vectors as matrices, ranks aligned with size-1 axes after the batch axis; the result reshaped to
the batch of the per-example result.
-}
matmulRule : Int -> List Operand -> Expr -> Maybe Expr
matmulRule n operands e =
    case operands of
        [ x, w ] ->
            let
                withBatch o =
                    case o of
                        Batched b ->
                            ( b, E.rank b - 1 )

                        Plain a ->
                            ( O.broadcastAxis 0 a, E.rank a )

                ( xb, rx ) =
                    withBatch x

                ( wb, rw ) =
                    withBatch w

                x2 =
                    if rx == 1 then
                        O.insertAxis 1 xb

                    else
                        xb

                w2 =
                    if rw == 1 then
                        O.insertAxis 2 wb

                    else
                        wb

                pad t toRank =
                    List.foldl (\_ acc -> O.insertAxis 1 acc) t (List.range 1 (toRank - E.rank t))

                r =
                    max (E.rank x2) (E.rank w2)
            in
            Just (O.reshape (n :: E.shape e) (O.matmul (pad x2 r) (pad w2 r)))

        _ ->
            Nothing

