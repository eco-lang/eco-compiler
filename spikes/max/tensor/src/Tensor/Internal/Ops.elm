module Tensor.Internal.Ops exposing
    ( unary, binary, add, sub, mul, div, neg, select, cast, stopGradient
    , gt, ge, lt, le, eq, ne, and_, or_, not_, sign, square
    , scalarLike, fullLike, zerosLike, onesLike, broadcastTo, broadcastAxis, insertAxis, dropAxis
    , reduce, reduceKeep, sumAll, meanAll, maxAll, minAll, softmax, logSoftmax, logSumExp, cumsum
    , matmul, transpose, swapLast, reshape, flatten, slice, concat, pad, gather, scatterRows, scatterRowsAdd
    , bandPart, range, random, xent, layerNorm, unbroadcast, oneHot, pick, indicator
    , conv, convTranspose, maxPool, avgPool
    )

{-| Untyped builders over `Expr`: the public `Tensor` functions and the gradient rules both use
these, so a gradient is an ordinary expression that can be differentiated again.
-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..), noParams)


unary : Prim -> Expr -> Expr
unary p x =
    E.prim p [ x ] noParams


binary : Prim -> Expr -> Expr -> Expr
binary p x y =
    E.prim p [ x, y ] noParams


add : Expr -> Expr -> Expr
add =
    binary Add


sub : Expr -> Expr -> Expr
sub =
    binary Sub


mul : Expr -> Expr -> Expr
mul =
    binary Mul


div : Expr -> Expr -> Expr
div =
    binary Div


neg : Expr -> Expr
neg =
    unary Neg


square : Expr -> Expr
square x =
    mul x x


gt : Expr -> Expr -> Expr
gt =
    binary Gt


ge : Expr -> Expr -> Expr
ge =
    binary Ge


{-| x < y as y > x: IEEE semantics (false when either is NaN), unlike `not (x >= y)`.
-}
lt : Expr -> Expr -> Expr
lt x y =
    binary Gt y x


le : Expr -> Expr -> Expr
le x y =
    binary Ge y x


eq : Expr -> Expr -> Expr
eq =
    binary Eq


ne : Expr -> Expr -> Expr
ne =
    binary Ne


and_ : Expr -> Expr -> Expr
and_ =
    binary And


or_ : Expr -> Expr -> Expr
or_ =
    binary Or


not_ : Expr -> Expr
not_ =
    unary Not


select : Expr -> Expr -> Expr -> Expr
select c x y =
    E.prim Select [ c, x, y ] noParams


cast : DT -> Expr -> Expr
cast dt x =
    if E.dtype x == dt then
        x

    else
        E.prim Cast [ x ] (P.ints [ P.dtTag dt ])


stopGradient : Expr -> Expr
stopGradient =
    unary StopGradient


{-| -1, 0 or 1 by sign.
-}
sign : Expr -> Expr
sign x =
    let
        zero =
            scalarLike 0 x
    in
    select (gt x zero) (fullLike 1 x) (select (lt x zero) (fullLike -1 x) (fullLike 0 x))


{-| A rank-0 constant of `x`'s dtype; element-wise operations broadcast it.
-}
scalarLike : Float -> Expr -> Expr
scalarLike v x =
    E.scalar (E.dtype x) v


fullLike : Float -> Expr -> Expr
fullLike v x =
    broadcastTo (E.shape x) (scalarLike v x)


zerosLike : Expr -> Expr
zerosLike =
    fullLike 0


onesLike : Expr -> Expr
onesLike =
    fullLike 1


broadcastTo : List Int -> Expr -> Expr
broadcastTo s x =
    if E.shape x == s && List.isEmpty (E.pending x) then
        x

    else
        E.prim BroadcastTo [ x ] (P.ints s)


{-| Insert an axis of size 1 at `axis`; `isPending` marks it as a broadcast axis to be sized by the
next element-wise operation.
-}
insertAxisWith : Bool -> Int -> Expr -> Expr
insertAxisWith isPending axis x =
    let
        s =
            E.shape x

        newShape =
            List.take axis s ++ (1 :: List.drop axis s)

        shifted =
            List.map
                (\i ->
                    if i >= axis then
                        i + 1

                    else
                        i
                )
                (E.pending x)
    in
    E.prim Reshape
        [ x ]
        { a = newShape
        , b =
            List.sort
                (if isPending then
                    axis :: shifted

                 else
                    shifted
                )
        , f = []
        }


broadcastAxis : Int -> Expr -> Expr
broadcastAxis =
    insertAxisWith True


insertAxis : Int -> Expr -> Expr
insertAxis =
    insertAxisWith False


dropAxis : Int -> Expr -> Expr
dropAxis axis x =
    let
        s =
            E.shape x
    in
    E.prim Reshape
        [ x ]
        { a = List.take axis s ++ List.drop (axis + 1) s
        , b =
            List.filterMap
                (\i ->
                    if i == axis then
                        Nothing

                    else if i > axis then
                        Just (i - 1)

                    else
                        Just i
                )
                (E.pending x)
        , f = []
        }


reshape : List Int -> Expr -> Expr
reshape s x =
    if E.shape x == s && List.isEmpty (E.pending x) then
        x

    else
        E.prim Reshape [ x ] { a = s, b = [], f = [] }


flatten : Expr -> Expr
flatten x =
    reshape [ List.product (E.shape x) ] x


reduce : Prim -> Int -> Expr -> Expr
reduce p axis x =
    E.prim p [ x ] (P.ints [ axis, 0 ])


reduceKeep : Prim -> Int -> Expr -> Expr
reduceKeep p axis x =
    E.prim p [ x ] (P.ints [ axis, 1 ])


all : Prim -> Expr -> Expr
all p x =
    if E.rank x == 0 then
        x

    else
        reduce p 0 (flatten x)


sumAll : Expr -> Expr
sumAll =
    all ReduceSum


meanAll : Expr -> Expr
meanAll =
    all ReduceMean


maxAll : Expr -> Expr
maxAll =
    all ReduceMax


minAll : Expr -> Expr
minAll =
    all ReduceMin


softmax : Int -> Expr -> Expr
softmax axis x =
    E.prim Softmax [ x ] (P.ints [ axis ])


logSoftmax : Int -> Expr -> Expr
logSoftmax axis x =
    E.prim LogSoftmax [ x ] (P.ints [ axis ])


{-| log (sum (exp x)) along `axis`, stable: the maximum is taken out first.
-}
logSumExp : Int -> Expr -> Expr
logSumExp axis x =
    let
        m =
            stopGradient (reduceKeep ReduceMax axis x)

        shifted =
            sub x (broadcastTo (E.shape x) m)
    in
    add (reduce ReduceSum axis (unary Exp shifted) |> unary Log) (dropAxis axis m)


cumsum : Int -> Bool -> Bool -> Expr -> Expr
cumsum axis exclusive reverse x =
    E.prim CumSum [ x ] (P.ints [ axis, boolInt exclusive, boolInt reverse ])


boolInt : Bool -> Int
boolInt b =
    if b then
        1

    else
        0


{-| x @ w.
-}
matmul : Expr -> Expr -> Expr
matmul x w =
    E.prim MatMul [ x, w ] noParams


transpose : List Int -> Expr -> Expr
transpose perm x =
    if perm == List.range 0 (List.length perm - 1) then
        x

    else
        E.prim Transpose [ x ] (P.ints perm)


{-| Swap the last two axes.
-}
swapLast : Expr -> Expr
swapLast x =
    let
        r =
            E.rank x
    in
    transpose (List.range 0 (r - 3) ++ [ r - 1, r - 2 ]) x


slice : List Int -> List Int -> Expr -> Expr
slice starts sizes x =
    if List.all ((==) 0) starts && sizes == E.shape x then
        x

    else
        E.prim Slice [ x ] { a = starts, b = sizes, f = [] }


concat : Int -> List Expr -> Expr
concat axis xs =
    case xs of
        [ x ] ->
            x

        _ ->
            E.prim Concat xs (P.ints [ axis ])


pad : Int -> Int -> Int -> Float -> Expr -> Expr
pad axis before after value x =
    if before == 0 && after == 0 then
        x

    else
        E.prim Pad [ x ] { a = [ axis, before, after ], b = [], f = [ value ] }


gather : Int -> Expr -> Expr -> Expr
gather axis x idx =
    E.prim Gather [ x, idx ] (P.ints [ axis ])


{-| x with the rows at `idx` (any integer vector) replaced by `upd`.
-}
scatterRows : Expr -> Expr -> Expr -> Expr
scatterRows x upd idx =
    E.prim ScatterRows [ x, upd, reshape [ List.product (E.shape idx), 1 ] idx ] noParams


scatterRowsAdd : Expr -> Expr -> Expr -> Expr
scatterRowsAdd x upd idx =
    E.prim ScatterRowsAdd [ x, upd, reshape [ List.product (E.shape idx), 1 ] idx ] noParams


bandPart : Int -> Int -> Expr -> Expr
bandPart lower upper x =
    E.prim BandPart [ x ] (P.ints [ lower, upper ])


range : Int -> Int -> Int -> Expr
range start step n =
    E.prim Range [] (P.ints [ start, step, n ])


{-| kind 0: uniform in [a, b); kind 1: normal with mean a and standard deviation b.
-}
random : Int -> DT -> List Int -> Float -> Float -> Expr -> Expr
random kind dt s a b seed =
    E.prim Random [ seed ] { a = kind :: P.dtTag dt :: s, b = [], f = [ a, b ] }


xent : Expr -> Expr -> Expr
xent logits target =
    E.prim XentLogits [ logits, target ] noParams


layerNorm : Float -> Expr -> Expr -> Expr -> Expr
layerNorm eps x g b =
    E.prim LayerNorm [ x, g, b ] (P.floats [ eps ])


conv : List Int -> Expr -> Expr -> Expr
conv a x f =
    E.prim Conv [ x, f ] (P.ints a)


convTranspose : List Int -> Expr -> Expr -> Expr
convTranspose a x f =
    E.prim ConvTranspose [ x, f ] (P.ints a)


maxPool : Int -> Expr -> Expr
maxPool k x =
    E.prim MaxPool [ x ] (P.ints [ k ])


avgPool : Int -> Expr -> Expr
avgPool k x =
    E.prim AvgPool [ x ] (P.ints [ k ])


{-| Integer labels (n) as one-hot rows (n × classes) of dtype `dt`.
-}
oneHot : DT -> Int -> Expr -> Expr
oneHot dt classes labels =
    let
        n =
            List.product (E.shape labels)

        col =
            reshape [ n, 1 ] (cast SI64 labels)

        iota =
            reshape [ 1, classes ] (range 0 1 classes)
    in
    indicator dt (eq (broadcastTo [ n, classes ] col) (broadcastTo [ n, classes ] iota))


indicator : DT -> Expr -> Expr
indicator dt m =
    cast dt m


{-| x[i, idx[i]] for each row i, written with a one-hot mask (so it differentiates like `times`).
-}
pick : Expr -> Expr -> Expr
pick idx x =
    let
        classes =
            List.drop 1 (E.shape x) |> List.head |> Maybe.withDefault 1
    in
    reduce ReduceSum 1 (mul x (oneHot (E.dtype x) classes idx))


{-| Sum `g` down to `target`'s shape: over leading axes `target` lacks and over axes where
`target` has size 1 (pending broadcasts, rank-0 scalars).
-}
unbroadcast : List Int -> Expr -> Expr
unbroadcast target g =
    let
        gs =
            E.shape g

        extra =
            List.length gs - List.length target

        leading =
            List.foldl (\_ acc -> reduce ReduceSum 0 acc) g (List.range 1 extra)

        padded =
            E.shape leading

        ones =
            List.filterMap identity
                (List.map3
                    (\i t s ->
                        if t == 1 && s /= 1 then
                            Just i

                        else
                            Nothing
                    )
                    (List.range 0 (List.length target - 1))
                    target
                    padded
                )

        summed =
            List.foldl (\axis acc -> reduceKeep ReduceSum axis acc) leading ones
    in
    if gs == target then
        g

    else
        reshape target summed
