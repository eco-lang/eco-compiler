module Tensor.Internal.Shape exposing (Meta, pendingMessage, rule, showShape)

{-| The types of a primitive's operands do not show whether their sizes fit together, so this
module holds the rules that check it when an expression that applies the primitive is made. Given a
primitive, the shapes and dtypes of its operands, and its params, `rule` gives the shape and dtype
of the result, or a message saying why the primitive cannot be applied to those operands.

The public types fix a tensor's rank, the tags of its axes and its element type, but not its sizes:
two `Dim`s with one tag may have different sizes. The rules here are therefore what checks that
operands' sizes fit together, and they check ranks and dtypes too, since a `Meta`, which holds an
operand's shape and dtype, is all they see of an operand. They never see element values, so no
index is checked against the axis it indexes. Sizes given in params are checked only where the
rules say so: `Reshape`, `BroadcastTo`, `Range` and `Random` refuse a negative size and accept 0. The
`Tensor.Internal.Support` table of dtypes refused by a probe of MAX is applied by
`Tensor.Internal.Expr`, not by these rules.

This module assumes of MAX, and of anything else that runs an element-wise operation, that it
broadcasts an axis of size 1 against a larger one, and the element-wise rules refuse that case when
the 1 is a real size, so that a size that happens to be 1 is never stretched by accident. The
operands of a two- or three-operand element-wise primitive (`Tensor.Internal.Prim`'s `Binary` and
`Ternary` families) must have one rank, apart from any of rank 0, which takes the shape of the
others, and one size on every axis, apart from a _pending axis_, which is an axis of size 1 whose
real size is not known yet. Those are the two broadcasts an element-wise operation accepts. Among
the primitives that broadcast on purpose are `BroadcastTo`, which repeats its operand along its
axes of size 1 and along axes added in front, and `MatMul`, whose batch axes broadcast as NumPy's
do.

For a pending axis, `shape` holds 1 and `pending` lists its position. A `Reshape` whose `params.b`
is not empty makes the result's axes at those positions pending. A two- or three-operand
element-wise operation gives a pending axis its partner's size there, after which it is an ordinary
axis, unless the partner is rank 0 or is pending on that axis too, in which case it stays pending.
Unary operations keep pending axes, `Transpose` moves them with their axes, `MatMul` accepts them
among its batch axes, and `Reshape` accepts them when its `params.b` is not empty. Every other
primitive refuses an operand with a pending axis, with `pendingMessage`, because what it would
compute on size 1 is not what it would compute once the axis had its size.

Most of the file is the rules for the primitives outside the element-wise families, one case each
in `other`, with the longer ones in functions of their own.

-}

import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim(..))


{-| A shape, which of its axes are pending, and a dtype: what a rule is given for each operand,
and what it gives for the result of a primitive it accepts.

`pending` lists positions in `shape`, each an axis held as size 1 whose real size is not known yet.

-}
type alias Meta =
    { shape : List Int, pending : List Int, dtype : DT }


{-| Returns a shape as messages write it, such as `[2, 3]`.
-}
showShape : List Int -> String
showShape s =
    "[" ++ String.join ", " (List.map String.fromInt s) ++ "]"


{-| The message refusing a pending axis where a size is needed.

Its advice to use `broadcastTo` means making the axis with a known size in place of a pending one.
The `BroadcastTo` primitive refuses a pending operand like any other.

-}
pendingMessage : String
pendingMessage =
    "a broadcast axis (as broadcast, rows, columns and maskBroadcast make) has no size here; only element-wise operations give it one (use broadcastTo to give it a size)"


{-| Returns the meta of the result of applying `p` to operands whose metas are `ms`, with params
`params`, or a message saying why `p` cannot be applied to them.

An element-wise primitive is first refused if it has the wrong number of operands. `Select` needs
a mask and two tensors of one dtype, matches all three shapes as the element-wise rule does, and
gives the two tensors' dtype. A primitive outside the element-wise families is refused, with
`pendingMessage`, if an operand has a pending axis, unless it is `MatMul`, `Reshape` or
`Transpose`, whose own rules say which pending axes they accept.

-}
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


{-| Returns the refusal of an element-wise primitive given a number of operands other than `n`.
-}
arity : Int -> Result String Meta
arity n =
    Err ("expects " ++ String.fromInt n ++ " operands")


{-| Returns whether a primitive outside the element-wise families may be given an operand with a
pending axis. `MatMul` then refuses pending axes among its last two axes, and `Reshape` refuses
them when its `params.b` is empty; `Transpose` accepts them on any axis.
-}
allowsPending : Prim -> Bool
allowsPending p =
    List.member p [ MatMul, Reshape, Transpose ]


{-| Returns the meta of a one-operand element-wise primitive: the operand's, pending axes included,
with the dtype changed to `Bool` for `IsInf` and `IsNaN` and to the target dtype for `Cast`.

Every unary primitive except `Abs`, `Neg`, `Relu`, `Not`, `Cast` and `StopGradient` needs a
floating-point operand. `Not` needs a mask, and the other five accept any dtype. `Cast` reads the
target's `dtTag` from `params.a`; an empty `a`, or a number that is no dtype's tag, gives `F32`.

-}
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


{-| Returns the meta of a two-operand element-wise primitive applied to `a` and `b`.

The operands must have one dtype, and their shapes are matched by `merge`. The comparisons `Eq`,
`Ne`, `Gt` and `Ge` give a mask. `And`, `Or` and `Xor` need masks, and `Div` and `Pow` need
floating-point operands. The rest accept any dtype, masks included, and give the operands' dtype.

-}
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


{-| Returns the meta of an element-wise result over operands `a` and `b`. It has `a`'s dtype; the
dtypes are not compared.

With a rank-0 operand, the result has the other's shape and pending axes. Otherwise the ranks
must be equal, and on each axis the sizes must be equal or one of the two must be pending. A
pending axis takes the other operand's size and is no longer pending, unless the other is pending
there too, when the result keeps a pending axis of size 1. A size 1 that is not pending, against a
larger size, is refused like any other difference.

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
                    , pending =
                        List.filterMap identity
                            (List.indexedMap
                                (\i ( _, pd ) ->
                                    if pd then
                                        Just i

                                    else
                                        Nothing
                                )
                                rs
                            )
                    , dtype = a.dtype
                    }
                )


{-| Returns `axis` if it is one of the axes of `shape`, or a message saying it is outside them.
-}
inRange : Int -> List Int -> Result String Int
inRange axis shape =
    if axis >= 0 && axis < List.length shape then
        Ok axis

    else
        Err ("axis " ++ String.fromInt axis ++ " is outside " ++ showShape shape)


{-| Returns the refusal of a shape holding a negative size.
-}
negativeSize : List Int -> String
negativeSize s =
    "negative size in " ++ showShape s


{-| Returns the element at index `i`, or `Nothing` past the end. A negative `i` reads as 0, not as
an index outside the list.
-}
get : Int -> List a -> Maybe a
get i l =
    List.head (List.drop i l)


{-| Returns the list without its element at index `i`.
-}
removeAt : Int -> List a -> List a
removeAt i l =
    List.take i l ++ List.drop (i + 1) l


{-| Returns the list with its element at index `i` replaced by `x`. An `i` outside the list adds
`x` instead: at the end for an `i` past it, at the front for a negative `i`.
-}
setAt : Int -> a -> List a -> List a
setAt i x l =
    List.take i l ++ (x :: List.drop (i + 1) l)


{-| Returns the first entry of a params list, or 0 when it is empty, so a missing axis reads as
axis 0.
-}
first : List Int -> Int
first l =
    Maybe.withDefault 0 (List.head l)


{-| Returns the meta of a primitive outside the element-wise families, one case per primitive. An
operand with a pending axis has already been refused unless the primitive is `MatMul`, `Reshape`
or `Transpose`. A primitive given a number of operands its case does not match is refused.

`Reshape` refuses a negative size in `params.a`, compares element counts, and refuses an operand
with a pending axis unless `params.b` is not empty. The result's shape is `params.a` and its pending
axes are `params.b`, checked no further.

`Transpose` moves each pending axis to wherever the permutation puts it.

`BroadcastTo` refuses a negative size in the target, aligns the operand's axes with the last axes
of the target, and each must be 1 or equal to the target's size there.

`Concat` needs its operands to share one dtype as well as their sizes off the axis, and accepts a
single operand.

`Pad` reads only `params.a`, so its fill is not checked.

`LayerNorm` needs a floating-point tensor and a gain and bias shaped like its last axis, but does
not check the gain's or the bias's dtype.

`Range` and `Random` refuse a negative size. `Random` gives the dtype whose `dtTag` is the second
entry of `params.a`, and `F32` for a number that is no dtype's tag.

-}
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
                    List.product
                        (List.indexedMap
                            (\i d ->
                                if List.member i pend then
                                    1

                                else
                                    d
                            )
                            s
                        )
            in
            if List.any (\d -> d < 0) params.a then
                Err (negativeSize params.a)

            else if real m.shape m.pending /= List.product params.a then
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
                        List.filterMap identity
                            (List.indexedMap
                                (\j i ->
                                    if List.member i m.pending then
                                        Just j

                                    else
                                        Nothing
                                )
                                params.a
                            )
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
            if List.any (\d -> d < 0) target then
                Err (negativeSize target)

            else if offset < 0 || not (List.all identity (List.indexedMap fits m.shape)) then
                Err ("cannot broadcast " ++ showShape m.shape ++ " to " ++ showShape target)

            else
                Ok { shape = target, pending = [], dtype = m.dtype }

        ( Slice, [ m ] ) ->
            let
                ok =
                    List.length params.a
                        == List.length m.shape
                        && List.length params.b
                        == List.length m.shape
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
                    if n < 0 then
                        Err (negativeSize [ n ])

                    else
                        Ok { shape = [ n ], pending = [], dtype = SI64 }

                _ ->
                    Err "bad parameters"

        ( Random, [ seed ] ) ->
            case params.a of
                _ :: dt :: shape ->
                    if seed.dtype /= UI64 || seed.shape /= [ 1 ] then
                        Err "the seed must be a ui64 [1] tensor"

                    else if List.any (\d -> d < 0) shape then
                        Err (negativeSize shape)

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


{-| Returns the meta of reducing one axis of `m` to a result of dtype `dt`, with
`params.a = [axis, keep]`. With `keep` equal to 1 the axis stays with size 1; any other value
removes it. The operand's dtype is not checked.
-}
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


{-| Returns `m` unchanged if it is floating-point and the first entry of `params.a`, or axis 0
when `params.a` is empty, is one of its axes, as `Softmax` and `LogSoftmax` need.
-}
floatSame : Meta -> Params -> Result String Meta
floatSame m params =
    if not (P.isFloat m.dtype) then
        Err ("needs a floating-point tensor, not " ++ P.dtName m.dtype)

    else
        inRange (first params.a) m.shape |> Result.map (\_ -> m)


{-| Returns the meta of the matrix product of `a` and `b`, by NumPy's rules.

Both operands need one dtype and at least one axis. The last axis of `a` is contracted with the
second-to-last of `b`, or with its only axis when `b` is a vector, and the two must have one size.
A vector operand contributes no row or column axis to the result. The axes before an operand's last
two are its batch axes; the two operands' batch axes are aligned from the right, and on each the
sizes must be equal or one of them 1. A size 1 is stretched to the other size here even when it is
not pending.

A pending axis is refused in either operand's last two axes, before the inner sizes are compared.
A pending batch axis takes the other operand's size there and stays pending only if the other is
pending too. Where the other operand has fewer batch axes and so none at that position, the pending
axis stays pending.

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

    else if pendingIn a [ ra - 1, ra - 2 ] || pendingIn b [ rb - 1, rb - 2 ] then
        Err pendingMessage

    else if k1 /= k2 then
        Err ("inner sizes differ: " ++ showShape a.shape ++ " @ " ++ showShape b.shape)

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

            absent l i =
                i < n - List.length l

            batch =
                List.map3
                    (\i x y ->
                        if List.member i pa then
                            if absent batchB i then
                                Ok ( x, True )

                            else
                                Ok ( y, List.member i pb )

                        else if List.member i pb then
                            if absent batchA i then
                                Ok ( y, True )

                            else
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
                    , pending =
                        List.filterMap identity
                            (List.indexedMap
                                (\i ( _, pd ) ->
                                    if pd then
                                        Just i

                                    else
                                        Nothing
                                )
                                bs
                            )
                    , dtype = a.dtype
                    }
                )


{-| Returns `x`'s meta if updates `upd` and indices `idx` fit it as `ScatterRows` and
`ScatterRowsAdd` need: `idx` an integer `n × 1` tensor, and `upd` of `x`'s dtype and made of `n`
rows each shaped like a row of `x`.
-}
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


{-| Returns `x`'s meta if updates `upd` and indices `idx` fit it for a scatter along `axis`: `idx`
an integer vector, and `upd` of `x`'s dtype and shaped like `x` except that its size at `axis` is
`idx`'s length.
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


{-| Returns the meta of selecting `k` elements along an axis, with `params.a = [axis, k, largest]`:
the operand's shape with size `k` at that axis, and dtype `dt`. `k` must be from 1 to the axis's
size, and an axis outside the operand's axes, negative included, is refused.
-}
topK : Params -> Meta -> DT -> Result String Meta
topK params m dt =
    case params.a of
        [ axis, k, _ ] ->
            case inRange axis m.shape |> Result.toMaybe |> Maybe.andThen (\_ -> get axis m.shape) of
                Just size ->
                    if k < 1 || k > size then
                        Err ("k = " ++ String.fromInt k ++ " but axis " ++ String.fromInt axis ++ " has size " ++ String.fromInt size)

                    else
                        Ok { m | shape = setAt axis k m.shape, dtype = dt }

                Nothing ->
                    Err ("axis " ++ String.fromInt axis ++ " is outside " ++ showShape m.shape)

        _ ->
            Err "bad parameters"


{-| Returns the meta of a 2-D convolution of the NHWC input `x` by the filter `f`, or of the
transposed convolution when `transposed`.

`params.a` holds the strides and paddings `[sh, sw, pt, pb, pl, pr]`, optionally followed by a
dilation `[dh, dw]`; without one the dilation is 1. Any other number of entries is refused. A kernel
of size `k` and dilation `d` spans `(k - 1) * d + 1` elements, its extent.

Both refuse an input and a filter of different dtypes, a stride of zero or less and a dilation of
zero or less.

A convolution needs `f`'s third axis to be `x`'s channels, gives `f`'s fourth as the result's
channels, and gives `(h + pt + pb - extent) // sh + 1` rows, and likewise columns. A kernel extent
larger than the padded input (`h + pt + pb`, or `w + pl + pr`) is refused, so the result has at
least one row and one column.

A transposed convolution needs `f`'s fourth axis to be `x`'s channels, gives `f`'s third as the
result's channels, and gives `(h - 1) * sh + extent - pt - pb` rows, and likewise columns. A result
with fewer than one row or column is refused.

-}
conv : Bool -> Meta -> Meta -> Params -> Result String Meta
conv transposed x f params =
    let
        dilation =
            case List.drop 6 params.a of
                [] ->
                    Just ( 1, 1 )

                [ a, b ] ->
                    Just ( a, b )

                _ ->
                    Nothing
    in
    case ( List.take 6 params.a, dilation ) of
        ( [ sh, sw, pt, pb, pl, pr ], Just ( dh, dw ) ) ->
            case ( x.shape, f.shape ) of
                ( [ n, h, w, c ], [ kh, kw, fc, fo ] ) ->
                    let
                        ekh =
                            (kh - 1) * dh + 1

                        ekw =
                            (kw - 1) * dw + 1
                    in
                    if x.dtype /= f.dtype then
                        Err ("the input is " ++ P.dtName x.dtype ++ " but the filter is " ++ P.dtName f.dtype)

                    else if sh <= 0 || sw <= 0 then
                        Err ("the strides must be positive, not " ++ showShape [ sh, sw ])

                    else if dh <= 0 || dw <= 0 then
                        Err ("the dilations must be positive, not " ++ showShape [ dh, dw ])

                    else if transposed then
                        let
                            oh =
                                (h - 1) * sh + ekh - pt - pb

                            ow =
                                (w - 1) * sw + ekw - pl - pr
                        in
                        if fo /= c then
                            Err ("input channels " ++ String.fromInt c ++ " do not match the filter " ++ showShape f.shape)

                        else if oh <= 0 || ow <= 0 then
                            Err ("the result would be " ++ String.fromInt oh ++ " × " ++ String.fromInt ow ++ ": the paddings remove every row or column")

                        else
                            Ok { x | shape = [ n, oh, ow, fc ] }

                    else if fc /= c then
                        Err ("input channels " ++ String.fromInt c ++ " do not match the filter " ++ showShape f.shape)

                    else if h + pt + pb - ekh < 0 || w + pl + pr - ekw < 0 then
                        Err "the kernel is larger than the padded input"

                    else
                        Ok { x | shape = [ n, (h + pt + pb - ekh) // sh + 1, (w + pl + pr - ekw) // sw + 1, fo ] }

                _ ->
                    Err "needs an NHWC input and a 4-D filter"

        _ ->
            Err ("needs 6 geometry parameters (strides and paddings), optionally followed by 2 dilations, not " ++ String.fromInt (List.length params.a))


{-| Returns the meta of pooling the NHWC input `x` over `k × k` windows with stride `k`, with
`params.a = [k]`. `k` must be positive and divide the height and the width, and the result's height
and width are theirs divided by `k`.
-}
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
