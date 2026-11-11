module Tensor.Internal.Shape exposing (Meta, rule, showShape, pendingMessage)

{-| The value-level shape and dtype of each primitive's result, computed from its operands'.

`pending` lists the axes of size 1 inserted by `broadcast`, `rows` or `columns` whose size is not
known yet: an element-wise operation resolves them against a sized operand; any other primitive
refuses them, because MAX would compute on size 1 there.

-}

import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim(..))


type alias Meta =
    { shape : List Int, pending : List Int, dtype : DT }


showShape : List Int -> String
showShape s =
    "[" ++ String.join ", " (List.map String.fromInt s) ++ "]"


pendingMessage : String
pendingMessage =
    "an axis made by broadcast, rows or columns has no size here; only element-wise operations give it one (use broadcastTo to give it a size)"


rule : Prim -> List Meta -> Params -> Result String Meta
rule p ms params =
    case P.family p of
        P.Unary ->
            case ms of
                [ m ] ->
                    unary p m params

                _ ->
                    arity 1

        P.Binary ->
            case ms of
                [ a, b ] ->
                    binary p a b

                _ ->
                    arity 2

        P.Ternary ->
            case ms of
                [ c, x, y ] ->
                    if c.dtype /= Bool then
                        Err "the condition must be a mask"

                    else if x.dtype /= y.dtype then
                        Err ("dtypes differ: " ++ P.dtName x.dtype ++ " and " ++ P.dtName y.dtype)

                    else
                        merge x y
                            |> Result.andThen (\xy -> merge xy c)
                            |> Result.map (\r -> { r | dtype = x.dtype })

                _ ->
                    arity 3

        P.Other ->
            if List.any (\m -> not (List.isEmpty m.pending)) ms && not (allowsPending p) then
                Err pendingMessage

            else
                other p ms params


arity : Int -> Result String Meta
arity n =
    Err ("expects " ++ String.fromInt n ++ " operands")


allowsPending : Prim -> Bool
allowsPending p =
    List.member p [ MatMul, Reshape, Transpose ]


unary : Prim -> Meta -> Params -> Result String Meta
unary p m params =
    let
        floatOnly =
            List.member p [ Exp, Log, Log1p, Sqrt, Rsqrt, Sin, Cos, Acos, Atanh, Erf, Floor, Round, Trunc, Sigmoid, Tanh, Gelu, GeluTanh, Silu, IsInf, IsNaN ]
    in
    if floatOnly && not (P.isFloat m.dtype) then
        Err ("needs a floating-point tensor, not " ++ P.dtName m.dtype)

    else
        case p of
            IsInf ->
                Ok { m | dtype = Bool }

            IsNaN ->
                Ok { m | dtype = Bool }

            Not ->
                if m.dtype == Bool then
                    Ok m

                else
                    Err "needs a mask"

            Cast ->
                Ok { m | dtype = P.dtFromTag (Maybe.withDefault 3 (List.head params.a)) }

            _ ->
                Ok m


binary : Prim -> Meta -> Meta -> Result String Meta
binary p a b =
    if a.dtype /= b.dtype then
        Err ("dtypes differ: " ++ P.dtName a.dtype ++ " and " ++ P.dtName b.dtype)

    else
        merge a b
            |> Result.andThen
                (\r ->
                    if List.member p [ Eq, Ne, Gt, Ge ] then
                        Ok { r | dtype = Bool }

                    else if List.member p [ And, Or, Xor ] then
                        if a.dtype == Bool then
                            Ok r

                        else
                            Err "needs masks"

                    else if List.member p [ Div, Pow ] && not (P.isFloat a.dtype) then
                        Err ("needs a floating-point tensor, not " ++ P.dtName a.dtype)

                    else
                        Ok r
                )


{-| Element-wise operands: equal ranks (or one scalar), and per axis equal sizes, or a pending axis
that takes the other's size. A real size 1 against a larger size is refused: MAX would broadcast it.
-}
merge : Meta -> Meta -> Result String Meta
merge a b =
    if List.isEmpty a.shape then
        Ok { b | dtype = a.dtype }

    else if List.isEmpty b.shape then
        Ok a

    else if List.length a.shape /= List.length b.shape then
        Err ("ranks differ: " ++ showShape a.shape ++ " and " ++ showShape b.shape)

    else
        let
            axes =
                List.range 0 (List.length a.shape - 1)

            one i sa sb =
                let
                    pa =
                        List.member i a.pending

                    pb =
                        List.member i b.pending
                in
                if pa && pb then
                    Ok ( 1, True )

                else if pa then
                    Ok ( sb, False )

                else if pb then
                    Ok ( sa, False )

                else if sa == sb then
                    Ok ( sa, False )

                else
                    Err ("sizes differ: " ++ showShape a.shape ++ " and " ++ showShape b.shape)

            results =
                List.map3 one axes a.shape b.shape
        in
        List.foldr (Result.map2 (::)) (Ok []) results
            |> Result.map
                (\rs ->
                    { shape = List.map Tuple.first rs
                    , pending = List.filterMap identity (List.indexedMap (\i ( _, pd ) -> if pd then Just i else Nothing) rs)
                    , dtype = a.dtype
                    }
                )


inRange : Int -> List Int -> Result String Int
inRange axis shape =
    if axis >= 0 && axis < List.length shape then
        Ok axis

    else
        Err ("axis " ++ String.fromInt axis ++ " is outside " ++ showShape shape)


get : Int -> List a -> Maybe a
get i l =
    List.head (List.drop i l)


removeAt : Int -> List a -> List a
removeAt i l =
    List.take i l ++ List.drop (i + 1) l


setAt : Int -> a -> List a -> List a
setAt i x l =
    List.take i l ++ (x :: List.drop (i + 1) l)


first : List Int -> Int
first l =
    Maybe.withDefault 0 (List.head l)


other : Prim -> List Meta -> Params -> Result String Meta
other p ms params =
    case ( p, ms ) of
        ( ReduceSum, [ m ] ) ->
            reduce m params m.dtype

        ( ReduceMean, [ m ] ) ->
            reduce m params m.dtype

        ( ReduceMax, [ m ] ) ->
            reduce m params m.dtype

        ( ReduceMin, [ m ] ) ->
            reduce m params m.dtype

        ( ArgMax, [ m ] ) ->
            reduce m params SI64

        ( ArgMin, [ m ] ) ->
            reduce m params SI64

        ( Softmax, [ m ] ) ->
            floatSame m params

        ( LogSoftmax, [ m ] ) ->
            floatSame m params

        ( CumSum, [ m ] ) ->
            inRange (first params.a) m.shape |> Result.map (\_ -> m)

        ( MatMul, [ a, b ] ) ->
            matmul a b

        ( Reshape, [ m ] ) ->
            let
                real s pend =
                    List.product (List.indexedMap (\i d -> if List.member i pend then 1 else d) s)
            in
            if real m.shape m.pending /= List.product params.a then
                Err ("cannot reshape " ++ showShape m.shape ++ " (" ++ String.fromInt (List.product m.shape) ++ " elements) to " ++ showShape params.a)

            else if not (List.isEmpty m.pending) && List.isEmpty params.b then
                Err pendingMessage

            else
                Ok { shape = params.a, pending = params.b, dtype = m.dtype }

        ( Transpose, [ m ] ) ->
            if List.sort params.a /= List.range 0 (List.length m.shape - 1) then
                Err ("not a permutation of " ++ showShape m.shape)

            else
                let
                    at i =
                        Maybe.withDefault 0 (get i m.shape)

                    newPending =
                        List.filterMap identity (List.indexedMap (\j i -> if List.member i m.pending then Just j else Nothing) params.a)
                in
                Ok { shape = List.map at params.a, pending = newPending, dtype = m.dtype }

        ( BroadcastTo, [ m ] ) ->
            let
                target =
                    params.a

                offset =
                    List.length target - List.length m.shape

                fits i d =
                    d == 1 || Just d == get (i + offset) target
            in
            if offset < 0 || not (List.all identity (List.indexedMap fits m.shape)) then
                Err ("cannot broadcast " ++ showShape m.shape ++ " to " ++ showShape target)

            else
                Ok { shape = target, pending = [], dtype = m.dtype }

        ( Slice, [ m ] ) ->
            let
                ok =
                    List.length params.a == List.length m.shape
                        && List.length params.b == List.length m.shape
                        && List.all identity (List.map3 (\st sz d -> st >= 0 && sz >= 0 && st + sz <= d) params.a params.b m.shape)
            in
            if ok then
                Ok { m | shape = params.b }

            else
                Err ("slice from " ++ showShape params.a ++ " of size " ++ showShape params.b ++ " is outside " ++ showShape m.shape)

        ( Concat, x :: rest ) ->
            let
                axis =
                    first params.a

                same y =
                    List.length y.shape == List.length x.shape && removeAt axis y.shape == removeAt axis x.shape && y.dtype == x.dtype
            in
            inRange axis x.shape
                |> Result.andThen
                    (\_ ->
                        if List.all same rest then
                            Ok { x | shape = setAt axis (List.sum (List.map (\y -> Maybe.withDefault 0 (get axis y.shape)) ms)) x.shape }

                        else
                            Err ("cannot concatenate " ++ String.join ", " (List.map (.shape >> showShape) ms) ++ " along axis " ++ String.fromInt axis)
                    )

        ( Pad, [ m ] ) ->
            case params.a of
                [ axis, before, after ] ->
                    inRange axis m.shape
                        |> Result.andThen
                            (\_ ->
                                if before < 0 || after < 0 then
                                    Err "negative padding"

                                else
                                    Ok { m | shape = setAt axis (Maybe.withDefault 0 (get axis m.shape) + before + after) m.shape }
                            )

                _ ->
                    Err "bad parameters"

        ( Gather, [ x, idx ] ) ->
            let
                axis =
                    first params.a
            in
            if not (P.isInt idx.dtype) then
                Err "indices must be integers"

            else
                inRange axis x.shape
                    |> Result.map (\_ -> { x | shape = List.take axis x.shape ++ idx.shape ++ List.drop (axis + 1) x.shape })

        ( ScatterRows, [ x, upd, idx ] ) ->
            scatter x upd idx

        ( ScatterAxis, [ x, upd, idx ] ) ->
            scatterAxis (first params.a) x upd idx

        ( ScatterAxisAdd, [ x, upd, idx ] ) ->
            scatterAxis (first params.a) x upd idx

        ( TopKValues, [ m ] ) ->
            topK params m m.dtype

        ( TopKIndices, [ m ] ) ->
            topK params m SI64

        ( ScatterRowsAdd, [ x, upd, idx ] ) ->
            scatter x upd idx

        ( BandPart, [ m ] ) ->
            if List.length m.shape < 2 then
                Err "needs a matrix"

            else
                Ok m

        ( Range, [] ) ->
            case params.a of
                [ _, _, n ] ->
                    Ok { shape = [ n ], pending = [], dtype = SI64 }

                _ ->
                    Err "bad parameters"

        ( Random, [ seed ] ) ->
            case params.a of
                _ :: dt :: shape ->
                    if seed.dtype /= UI64 || seed.shape /= [ 1 ] then
                        Err "the seed must be a ui64 [1] tensor"

                    else
                        Ok { shape = shape, pending = [], dtype = P.dtFromTag dt }

                _ ->
                    Err "bad parameters"

        ( XentLogits, [ logits, target ] ) ->
            if logits.shape /= target.shape || List.length logits.shape /= 2 then
                Err ("logits " ++ showShape logits.shape ++ " and targets " ++ showShape target.shape ++ " differ")

            else if logits.dtype /= target.dtype || not (P.isFloat logits.dtype) then
                Err "logits and targets must have one floating-point dtype"

            else
                Ok { logits | shape = [] }

        ( LayerNorm, [ x, g, b ] ) ->
            let
                last =
                    List.drop (List.length x.shape - 1) x.shape
            in
            if g.shape /= last || b.shape /= last then
                Err ("gain " ++ showShape g.shape ++ " and bias " ++ showShape b.shape ++ " must match the last axis of " ++ showShape x.shape)

            else if not (P.isFloat x.dtype) then
                Err "needs floating point"

            else
                Ok x

        ( Conv, [ x, f ] ) ->
            conv False x f params

        ( ConvTranspose, [ x, f ] ) ->
            conv True x f params

        ( MaxPool, [ x ] ) ->
            pool x params

        ( AvgPool, [ x ] ) ->
            pool x params

        _ ->
            Err "wrong number of operands"


reduce : Meta -> Params -> DT -> Result String Meta
reduce m params dt =
    case params.a of
        [ axis, keep ] ->
            inRange axis m.shape
                |> Result.map
                    (\_ ->
                        { shape =
                            if keep == 1 then
                                setAt axis 1 m.shape

                            else
                                removeAt axis m.shape
                        , pending = []
                        , dtype = dt
                        }
                    )

        _ ->
            Err "bad parameters"


floatSame : Meta -> Params -> Result String Meta
floatSame m params =
    if not (P.isFloat m.dtype) then
        Err ("needs a floating-point tensor, not " ++ P.dtName m.dtype)

    else
        inRange (first params.a) m.shape |> Result.map (\_ -> m)


{-| numpy rules: x @ w with batch prefixes broadcast, 1-D operands promoted and their axis dropped.
Pending axes are allowed in batch prefixes only.
-}
matmul : Meta -> Meta -> Result String Meta
matmul a b =
    let
        ra =
            List.length a.shape

        rb =
            List.length b.shape

        contractA =
            ra - 1

        contractB =
            if rb == 1 then
                0

            else
                rb - 2

        k1 =
            get contractA a.shape

        k2 =
            get contractB b.shape

        pendingIn m axes =
            List.any (\i -> List.member i m.pending) axes
    in
    if a.dtype /= b.dtype then
        Err ("dtypes differ: " ++ P.dtName a.dtype ++ " and " ++ P.dtName b.dtype)

    else if ra == 0 || rb == 0 then
        Err "matmul needs at least vectors"

    else if k1 /= k2 then
        Err ("inner sizes differ: " ++ showShape a.shape ++ " @ " ++ showShape b.shape)

    else if pendingIn a [ ra - 1, ra - 2 ] || pendingIn b [ rb - 1, rb - 2 ] then
        Err pendingMessage

    else
        let
            batchA =
                List.take (max 0 (ra - 2)) a.shape

            batchB =
                List.take (max 0 (rb - 2)) b.shape

            n =
                max (List.length batchA) (List.length batchB)

            padL l =
                List.repeat (n - List.length l) 1 ++ l

            padP m l =
                let
                    off =
                        n - List.length l
                in
                List.map (\i -> i + off) (List.filter (\i -> i < List.length l) m.pending)

            pa =
                padP a batchA

            pb =
                padP b batchB

            batch =
                List.map3
                    (\i x y ->
                        if List.member i pa then
                            Ok ( y, List.member i pb )

                        else if List.member i pb then
                            Ok ( x, False )

                        else if x == y || y == 1 then
                            Ok ( x, False )

                        else if x == 1 then
                            Ok ( y, False )

                        else
                            Err ("batch sizes differ: " ++ showShape a.shape ++ " @ " ++ showShape b.shape)
                    )
                    (List.range 0 (n - 1))
                    (padL batchA)
                    (padL batchB)
                    |> List.foldr (Result.map2 (::)) (Ok [])

            rows =
                if ra == 1 then
                    []

                else
                    List.take 1 (List.drop (ra - 2) a.shape)

            cols =
                if rb == 1 then
                    []

                else
                    List.drop (rb - 1) b.shape
        in
        batch
            |> Result.map
                (\bs ->
                    { shape = List.map Tuple.first bs ++ rows ++ cols
                    , pending = List.filterMap identity (List.indexedMap (\i ( _, pd ) -> if pd then Just i else Nothing) bs)
                    , dtype = a.dtype
                    }
                )


scatter : Meta -> Meta -> Meta -> Result String Meta
scatter x upd idx =
    if not (P.isInt idx.dtype) || List.length idx.shape /= 2 || List.drop 1 idx.shape /= [ 1 ] then
        Err "indices must be an integer n × 1 tensor"

    else if List.take 1 upd.shape /= List.take 1 idx.shape || List.drop 1 upd.shape /= List.drop 1 x.shape then
        Err ("updates " ++ showShape upd.shape ++ " do not fit " ++ showShape x.shape)

    else if upd.dtype /= x.dtype then
        Err "updates and tensor dtypes differ"

    else
        Ok x


{-| x with the slices at `idx` (an integer vector) along `axis` replaced by `upd`: `upd` is x with
the indices' length at that axis.
-}
scatterAxis : Int -> Meta -> Meta -> Meta -> Result String Meta
scatterAxis axis x upd idx =
    if not (P.isInt idx.dtype) || List.length idx.shape /= 1 then
        Err "indices must be an integer vector"

    else if List.length upd.shape /= List.length x.shape || axis < 0 || axis >= List.length x.shape then
        Err ("updates " ++ showShape upd.shape ++ " do not fit " ++ showShape x.shape ++ " at axis " ++ String.fromInt axis)

    else if setAt axis 0 upd.shape /= setAt axis 0 x.shape || get axis upd.shape /= List.head idx.shape then
        Err ("updates " ++ showShape upd.shape ++ " do not fit " ++ showShape x.shape ++ " with " ++ showShape idx.shape ++ " indices at axis " ++ String.fromInt axis)

    else if upd.dtype /= x.dtype then
        Err "updates and tensor dtypes differ"

    else
        Ok x


{-| The k largest (or smallest) along an axis: x with size k there.
-}
topK : Params -> Meta -> DT -> Result String Meta
topK params m dt =
    case params.a of
        [ axis, k, _ ] ->
            case get axis m.shape of
                Just size ->
                    if k < 1 || k > size then
                        Err ("k = " ++ String.fromInt k ++ " but axis " ++ String.fromInt axis ++ " has size " ++ String.fromInt size)

                    else
                        Ok { m | shape = setAt axis k m.shape, dtype = dt }

                Nothing ->
                    Err ("axis " ++ String.fromInt axis ++ " is outside " ++ showShape m.shape)

        _ ->
            Err "bad parameters"


{-| NHWC input, RSCF filter (kernel h, kernel w, in, out); a: strides then four paddings.
-}
conv : Bool -> Meta -> Meta -> Params -> Result String Meta
conv transposed x f params =
    let
        ( geometry, dilation ) =
            ( List.take 6 params.a, List.drop 6 params.a )

        ( dh, dw ) =
            case dilation of
                [ a, b ] ->
                    ( a, b )

                _ ->
                    ( 1, 1 )
    in
    case ( x.shape, f.shape, geometry ) of
        ( [ n, h, w, c ], [ kh, kw, fc, fo ], [ sh, sw, pt, pb, pl, pr ] ) ->
            let
                ekh =
                    (kh - 1) * dh + 1

                ekw =
                    (kw - 1) * dw + 1
            in
            if transposed then
                -- filter (kh, kw, out, in)
                if fo /= c then
                    Err ("input channels " ++ String.fromInt c ++ " do not match the filter " ++ showShape f.shape)

                else
                    Ok { x | shape = [ n, (h - 1) * sh + ekh - pt - pb, (w - 1) * sw + ekw - pl - pr, fc ] }

            else if fc /= c then
                Err ("input channels " ++ String.fromInt c ++ " do not match the filter " ++ showShape f.shape)

            else
                let
                    oh =
                        (h + pt + pb - ekh) // sh + 1

                    ow =
                        (w + pl + pr - ekw) // sw + 1
                in
                if oh <= 0 || ow <= 0 then
                    Err "the kernel is larger than the padded input"

                else
                    Ok { x | shape = [ n, oh, ow, fo ] }

        _ ->
            Err "needs an NHWC input and a 4-D filter"


pool : Meta -> Params -> Result String Meta
pool x params =
    case ( x.shape, params.a ) of
        ( [ n, h, w, c ], [ k ] ) ->
            if k <= 0 || modBy k h /= 0 || modBy k w /= 0 then
                Err ("the window " ++ String.fromInt k ++ " must divide " ++ showShape [ h, w ])

            else
                Ok { x | shape = [ n, h // k, w // k, c ] }

        _ ->
            Err "needs an NHWC input"
