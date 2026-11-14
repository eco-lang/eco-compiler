module Tensor.Internal.Ops exposing
    ( add
    , and_
    , avgPool
    , bandPart
    , binary
    , broadcastAxis
    , broadcastTo
    , cast
    , concat
    , conv
    , convTranspose
    , cumsum
    , div
    , dropAxis
    , eq
    , flatten
    , fullLike
    , fullLikeValues
    , gather
    , ge
    , gt
    , inF32
    , indicator
    , insertAxis
    , layerNorm
    , le
    , leadingAxes
    , logSoftmax
    , logSumExp
    , lowest
    , lt
    , matmul
    , maxAll
    , maxPool
    , meanAll
    , minAll
    , mul
    , ne
    , neg
    , not_
    , oneHot
    , onesLike
    , or_
    , pad
    , padInt
    , pick
    , random
    , range
    , reduce
    , reduceKeep
    , reshape
    , scalarLike
    , scatterAxis
    , scatterAxisAdd
    , scatterRows
    , scatterRowsAdd
    , select
    , sign
    , slice
    , softmax
    , square
    , stopGradient
    , sub
    , sumAll
    , swapLast
    , topK
    , transpose
    , unary
    , unbroadcast
    , xent
    , zerosLike
    )

{-| The public tensor types carry a rank, axis tags and an element type, but code that rewrites
expressions, such as a rule that writes a gradient, has only `Expr`s in hand. This module is the
builders such code needs. They take and give plain `Expr`s, so what they build is an ordinary
expression, which can itself be differentiated, batched, lowered or evaluated like any other.

Most builders apply one primitive (`Tensor.Internal.Prim`) through `Tensor.Internal.Expr.prim`,
writing its params in the layout `Prim`'s docstring gives for that primitive. Making an expression
computes its key, its meta and any build error, as `prim` describes, and no element values. The
meta is the shape, the dtype and the _pending axes_. A pending axis is an axis of size 1 whose real
size is not known yet, which an element-wise operation can give its partner's size
(`Tensor.Internal.Shape` has the rule); `broadcastAxis` makes one. Apart from `padInt` and the
builders that make a constant shaped like a template, no builder records a build error itself.

Several builders return their operand itself, with no new node, on a test of their own arguments:
`cast` to its own dtype, `broadcastTo` and `reshape` to its own shape when it has no pending axes,
`transpose` when `perm` lists 0, 1, 2 … in order, `slice` when `starts` are all 0 and `sizes` is
its shape, `concat` of one tensor, `pad` with both counts 0 (and `padInt`, when its fill fits), the
whole-tensor reductions of a rank-0 tensor, and `unbroadcast` to its own shape. The result is then
the same expression as the operand, with its key. The tests of `transpose`, `slice`, `concat` and
`pad` are only those just given, so these return the operand in some cases their primitive's rule
would refuse, such as a `transpose` by a permutation shorter than the operand's rank.

Some builders apply several primitives to make an operation that has no primitive of its own, such
as `sign`, `logSumExp`, `oneHot` and `unbroadcast`.

`insertAxis`, `broadcastAxis`, `dropAxis`, `reshape` and `flatten` all make `Reshape` nodes, and the
`Reshape` rule refuses an operand with pending axes unless the result lists pending axes of its own.
The first three list the operand's remaining pending axes, so they keep them, apart from the one
case `dropAxis` describes; `reshape` and `flatten` list none, so they refuse such an operand, and
the `BroadcastTo` rule refuses one too.

The builders that make a constant shaped like a template (`fullLike`, `fullLikeValues`,
`zerosLike`, `onesLike`) take its shape, in which a pending axis is 1, so their result has a real
axis of size 1 there. They do not read the template, so a poisoned template fails their result with
its build error (`Tensor.Internal.Expr.inherit`).

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..), noParams)
import Tensor.Internal.Values as Values exposing (Values)


{-| Returns the node applying the one-operand primitive `p` to `x`, with no params.
-}
unary : Prim -> Expr -> Expr
unary p x =
    E.prim p [ x ] noParams


{-| Returns the node applying the two-operand primitive `p` to `x` and `y`, in that order, with no
params.
-}
binary : Prim -> Expr -> Expr -> Expr
binary p x y =
    E.prim p [ x, y ] noParams


{-| Returns `x + y`, element by element.
-}
add : Expr -> Expr -> Expr
add =
    binary Add


{-| Returns `x - y`, element by element.
-}
sub : Expr -> Expr -> Expr
sub =
    binary Sub


{-| Returns `x * y`, element by element.
-}
mul : Expr -> Expr -> Expr
mul =
    binary Mul


{-| Returns `x / y`, element by element.
-}
div : Expr -> Expr -> Expr
div =
    binary Div


{-| Returns `x` with each element negated.
-}
neg : Expr -> Expr
neg =
    unary Neg


{-| Returns `x` times itself, element by element.
-}
square : Expr -> Expr
square x =
    mul x x


{-| Returns the mask of where `x > y`.
-}
gt : Expr -> Expr -> Expr
gt =
    binary Gt


{-| Returns the mask of where `x >= y`.
-}
ge : Expr -> Expr -> Expr
ge =
    binary Ge


{-| Returns the mask of where `x < y`, built as `gt y x`, since there is no less-than primitive.
`Tensor.Internal.Eval.Prim` makes a comparison false where either element is NaN, as it takes MAX
to, so there `lt` is false where `not_ (ge x y)` would be true.
-}
lt : Expr -> Expr -> Expr
lt x y =
    binary Gt y x


{-| Returns the mask of where `x <= y`, built as `ge y x`.
-}
le : Expr -> Expr -> Expr
le x y =
    binary Ge y x


{-| Returns the mask of where `x` equals `y`.
-}
eq : Expr -> Expr -> Expr
eq =
    binary Eq


{-| Returns the mask of where `x` and `y` differ. `Tensor.Internal.Eval.Prim` makes it false where
either element is NaN, as it takes MAX to.
-}
ne : Expr -> Expr -> Expr
ne =
    binary Ne


{-| Returns the element-wise and of the masks `x` and `y`.
-}
and_ : Expr -> Expr -> Expr
and_ =
    binary And


{-| Returns the element-wise or of the masks `x` and `y`.
-}
or_ : Expr -> Expr -> Expr
or_ =
    binary Or


{-| Returns the mask `x` with each element negated.
-}
not_ : Expr -> Expr
not_ =
    unary Not


{-| Returns `x`'s element where the mask `c` is true and `y`'s where it is false.
-}
select : Expr -> Expr -> Expr -> Expr
select c x y =
    E.prim Select [ c, x, y ] noParams


{-| Returns `x` converted to the dtype `dt`, or `x` itself when it already has that dtype.
-}
cast : DT -> Expr -> Expr
cast dt x =
    if E.dtype x == dt then
        x

    else
        E.prim Cast [ x ] (P.ints [ P.dtTag dt ])


{-| Returns `x` with its values unchanged, through which no gradient is passed back.
-}
stopGradient : Expr -> Expr
stopGradient =
    unary StopGradient


{-| Returns −1, 0 or 1, in `x`'s dtype, for each element of `x` that is negative, zero or positive.
In `Tensor.Internal.Eval.Prim`, where a comparison with NaN is false, a NaN element gives 0.

It is a selection between rank-0 constants by masks of `x`'s shape, so the result keeps `x`'s
pending axes.

-}
sign : Expr -> Expr
sign x =
    let
        zero =
            scalarLike 0 x
    in
    select (gt x zero) (scalarLike 1 x) (select (lt x zero) (scalarLike -1 x) zero)


{-| Returns a rank-0 constant of `x`'s dtype holding `v`. An element-wise operation takes a rank-0
operand to the other operand's shape.

For an integer dtype or `Bool`, `v` is rounded, and nothing checks that the dtype can hold it, as
for `Tensor.Internal.Expr.scalar`.

-}
scalarLike : Float -> Expr -> Expr
scalarLike v x =
    E.scalar (E.dtype x) v


{-| Returns a constant of `x`'s dtype and shape with every element `v`, rounded as `scalarLike`
rounds it. A pending axis of `x` is a real axis of size 1 in the result. The result does not read
`x`, but a poisoned `x` fails it with `x`'s build error (`Tensor.Internal.Expr.inherit`).
-}
fullLike : Float -> Expr -> Expr
fullLike v x =
    broadcastTo (E.shape x) (scalarLike v x) |> E.inherit x


{-| Returns a constant of `x`'s dtype and shape with every element the one value in `vs`, kept
exact as `Tensor.Internal.Expr.constValues` keeps it and range-checked as it checks it. A `vs`
holding any number of values other than one is a build error. A poisoned `x` fails the result with
`x`'s build error, as for `fullLike`.
-}
fullLikeValues : Values -> Expr -> Expr
fullLikeValues vs x =
    broadcastTo (E.shape x) (E.constValues (E.dtype x) [] vs) |> E.inherit x


{-| Returns a constant of `x`'s dtype and shape with every element 0, failed as `fullLike` says
when `x` is poisoned.
-}
zerosLike : Expr -> Expr
zerosLike =
    fullLike 0


{-| Returns a constant of `x`'s dtype and shape with every element 1, failed as `fullLike` says
when `x` is poisoned.
-}
onesLike : Expr -> Expr
onesLike =
    fullLike 1


{-| Returns `x` repeated to the shape `s`, along its axes of size 1 and along axes added in front,
or `x` itself when it already has shape `s` and no pending axes. An `x` with a pending axis is
refused by the `BroadcastTo` rule, even when its shape is `s`.
-}
broadcastTo : List Int -> Expr -> Expr
broadcastTo s x =
    if E.shape x == s && List.isEmpty (E.pending x) then
        x

    else
        E.prim BroadcastTo [ x ] (P.ints s)


{-| Returns `x` with a new axis of size 1 at position `axis`, pending when `isPending`, and with
`x`'s own pending axes kept, those at or after `axis` moved up by one.
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


{-| Returns `x` with a new pending axis at position `axis`. `x`'s own pending axes are kept.
-}
broadcastAxis : Int -> Expr -> Expr
broadcastAxis =
    insertAxisWith True


{-| Returns `x` with a new axis of size 1, not pending, at position `axis`. `x`'s own pending axes
are kept.
-}
insertAxis : Int -> Expr -> Expr
insertAxis =
    insertAxisWith False


{-| Returns `x` without the axis at position `axis`, which is meant to have size 1: the `Reshape`
rule refuses a result with a different number of elements.

`x`'s other pending axes are kept. A pending axis at `axis` is refused, like a `reshape` of a
pending operand, whatever other pending axes `x` has.

-}
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
            if List.member axis (E.pending x) then
                []

            else
                List.map
                    (\i ->
                        if i > axis then
                            i - 1

                        else
                            i
                    )
                    (E.pending x)
        , f = []
        }


{-| Returns `x`'s elements, in row-major order, in the shape `s`, or `x` itself when it already has
shape `s` and no pending axes. An `x` with a pending axis is refused by the `Reshape` rule, even
when its shape is `s`.
-}
reshape : List Int -> Expr -> Expr
reshape s x =
    if E.shape x == s && List.isEmpty (E.pending x) then
        x

    else
        E.prim Reshape [ x ] { a = s, b = [], f = [] }


{-| Returns `x`'s elements, in row-major order, as a vector. A rank-0 `x` gives a vector of one
element; an `x` with a pending axis is refused, as by `reshape`.
-}
flatten : Expr -> Expr
flatten x =
    reshape [ List.product (E.shape x) ] x


{-| Returns the reduction `p` (`ReduceSum`, `ArgMax` and the like) of `x` along `axis`, with that
axis removed.
-}
reduce : Prim -> Int -> Expr -> Expr
reduce p axis x =
    E.prim p [ x ] (P.ints [ axis, 0 ])


{-| Returns the reduction `p` of `x` along `axis`, with that axis kept in place with size 1.
-}
reduceKeep : Prim -> Int -> Expr -> Expr
reduceKeep p axis x =
    E.prim p [ x ] (P.ints [ axis, 1 ])


{-| Returns the reduction `p` over every element of `x`, as a rank-0 expression, or `x` itself when
it is rank 0.
-}
all : Prim -> Expr -> Expr
all p x =
    if E.rank x == 0 then
        x

    else
        reduce p 0 (flatten x)


{-| Returns the sum of every element of `x`, rank 0, or `x` itself when it is rank 0.
-}
sumAll : Expr -> Expr
sumAll =
    all ReduceSum


{-| Returns the mean of every element of `x`, rank 0, or `x` itself when it is rank 0.
-}
meanAll : Expr -> Expr
meanAll =
    all ReduceMean


{-| Returns the largest element of `x`, rank 0, or `x` itself when it is rank 0.
-}
maxAll : Expr -> Expr
maxAll =
    all ReduceMax


{-| Returns the smallest element of `x`, rank 0, or `x` itself when it is rank 0.
-}
minAll : Expr -> Expr
minAll =
    all ReduceMin


{-| Returns the softmax of `x` along `axis`.
-}
softmax : Int -> Expr -> Expr
softmax axis x =
    E.prim Softmax [ x ] (P.ints [ axis ])


{-| Returns the log of the softmax of `x` along `axis`.
-}
logSoftmax : Int -> Expr -> Expr
logSoftmax axis x =
    E.prim LogSoftmax [ x ] (P.ints [ axis ])


{-| Returns the log of the sum of the exponentials of `x` along `axis`, with that axis removed.

To keep the exponentials in range, the maximum `m` of the elements along `axis`, taken at each
index of the other axes, is subtracted before them and added back after the log, behind
`stopGradient`, which leaves the gradient unchanged since `m` cancels out. Where `m` is ±∞ the
result is NaN, because `m - m` is then NaN.

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


{-| Returns the running sum of `x` along `axis`. With `exclusive`, each element leaves itself out
of its sum; with `reverse`, the sums run from the end of the axis.
-}
cumsum : Int -> Bool -> Bool -> Expr -> Expr
cumsum axis exclusive reverse x =
    E.prim CumSum [ x ] (P.ints [ axis, boolInt exclusive, boolInt reverse ])


{-| Returns 1 for `True` and 0 for `False`, the form a flag takes in params.
-}
boolInt : Bool -> Int
boolInt b =
    if b then
        1

    else
        0


{-| Returns the matrix product of `x` and `w`, with `x` on the left.
-}
matmul : Expr -> Expr -> Expr
matmul x w =
    E.prim MatMul [ x, w ] noParams


{-| Returns `x` with its axes permuted, axis `j` of the result being axis `perm[j]` of `x`, or `x`
itself when `perm` lists 0, 1, 2 … in order.
-}
transpose : List Int -> Expr -> Expr
transpose perm x =
    if perm == List.range 0 (List.length perm - 1) then
        x

    else
        E.prim Transpose [ x ] (P.ints perm)


{-| Returns `x` with its last two axes swapped. For an `x` of rank below 2 the permutation is
refused by the `Transpose` rule.
-}
swapLast : Expr -> Expr
swapLast x =
    let
        r =
            E.rank x
    in
    transpose (List.range 0 (r - 3) ++ [ r - 1, r - 2 ]) x


{-| Returns the block of `x` that starts at `starts` and has the sizes `sizes`, one entry per axis,
or `x` itself when the block is the whole of `x`.
-}
slice : List Int -> List Int -> Expr -> Expr
slice starts sizes x =
    if List.all ((==) 0) starts && sizes == E.shape x then
        x

    else
        E.prim Slice [ x ] { a = starts, b = sizes, f = [] }


{-| Returns `xs` joined in order along `axis`, or the one expression itself when `xs` holds one.
-}
concat : Int -> List Expr -> Expr
concat axis xs =
    case xs of
        [ x ] ->
            x

        _ ->
            E.prim Concat xs (P.ints [ axis ])


{-| Returns `x` with `before` elements added before it and `after` after it along `axis`, each
`value`, or `x` itself when both counts are 0.
-}
pad : Int -> Int -> Int -> Float -> Expr -> Expr
pad axis before after value x =
    if before == 0 && after == 0 then
        x

    else
        E.prim Pad [ x ] { a = [ axis, before, after ], b = [], f = [ value ] }


{-| Returns what `pad` returns, with the fill `value` given as an exact `Int`. For a fill that fits
`x`'s dtype, the node's params carry it in `b` as well as in `f`, as `Tensor.Internal.Prim` lays
out `Pad`.

A `value` that `Tensor.Internal.Values.fitsDtype` finds out of range for `x`'s dtype is a build
error, recorded with `Tensor.Internal.Expr.failWith`. When both counts are 0 the result is then
`x` failed with that error. When `x` is already poisoned, the result keeps `x`'s build error in its
place, as `failWith` does.

-}
padInt : Int -> Int -> Int -> Int -> Expr -> Expr
padInt axis before after value x =
    case Values.fitsDtype (E.dtype x) (Values.IntValues [ value ]) of
        Just msg ->
            E.failWith msg (pad axis before after (toFloat value) x)

        Nothing ->
            if before == 0 && after == 0 then
                x

            else
                E.prim Pad [ x ] { a = [ axis, before, after ], b = [ value ], f = [ toFloat value ] }


{-| Returns the slices of `x` along `axis` at the integer indices `idx`. The result has `idx`'s
whole shape in place of that axis.
-}
gather : Int -> Expr -> Expr -> Expr
gather axis x idx =
    E.prim Gather [ x, idx ] (P.ints [ axis ])


{-| Returns `x` with its row `idx[i]` replaced by row `i` of `upd`, a row being a slice along the
first axis. `idx` may have any shape: its elements are taken in row-major order, as the `n × 1`
indices the primitive needs.
-}
scatterRows : Expr -> Expr -> Expr -> Expr
scatterRows x upd idx =
    E.prim ScatterRows [ x, upd, reshape [ List.product (E.shape idx), 1 ] idx ] noParams


{-| Returns `x` with row `i` of `upd` added to its row `idx[i]`. `idx` may have any shape, as for
`scatterRows`.
-}
scatterRowsAdd : Expr -> Expr -> Expr -> Expr
scatterRowsAdd x upd idx =
    E.prim ScatterRowsAdd [ x, upd, reshape [ List.product (E.shape idx), 1 ] idx ] noParams


{-| Returns `x` with every element of its last two axes outside a band around the diagonal set to
zero. The band reaches `lower` rows below the diagonal and `upper` columns above it, and −1 means
no bound on that side.
-}
bandPart : Int -> Int -> Expr -> Expr
bandPart lower upper x =
    E.prim BandPart [ x ] (P.ints [ lower, upper ])


{-| Returns the `si64` vector of the `n` values `start`, `start + step`, and so on.
-}
range : Int -> Int -> Int -> Expr
range start step n =
    E.prim Range [] (P.ints [ start, step, n ])


{-| Returns a draw of dtype `dt` and shape `s`, seeded by `seed`. With `kind` 0 it is uniform
between `a` and `b`; with `kind` 1 it is normal with mean `a` and standard deviation `b`.

Every argument goes into the draw's key, so two calls with equal arguments are one expression and
give the same values.

-}
random : Int -> DT -> List Int -> Float -> Float -> Expr -> Expr
random kind dt s a b seed =
    E.prim Random [ seed ] { a = kind :: P.dtTag dt :: s, b = [], f = [ a, b ] }


{-| Returns the cross-entropy of the `n × c` `logits` against `target`, averaged over the `n` rows.
`target` may be any distribution over the `c` classes, not only a one-hot one.
-}
xent : Expr -> Expr -> Expr
xent logits target =
    E.prim XentLogits [ logits, target ] noParams


{-| Returns `x` normalised over its last axis, with `eps` added to the variance, scaled by the gain
`g` and shifted by the bias `b`.
-}
layerNorm : Float -> Expr -> Expr -> Expr -> Expr
layerNorm eps x g b =
    E.prim LayerNorm [ x, g, b ] (P.floats [ eps ])


{-| Returns the 2-D convolution of the NHWC (batch, height, width, channels) input `x` with the
filter `f`, configured by the strides, paddings and optional dilations `a`, laid out as
`Tensor.Internal.Prim` gives for `Conv`.
-}
conv : List Int -> Expr -> Expr -> Expr
conv a x f =
    E.prim Conv [ x, f ] (P.ints a)


{-| Returns the transposed convolution of `x` with `f`: the transpose of the `conv` with the same
`a` and filter.
-}
convTranspose : List Int -> Expr -> Expr -> Expr
convTranspose a x f =
    E.prim ConvTranspose [ x, f ] (P.ints a)


{-| Returns the maximum of each `k × k` window of the NHWC input `x`, with stride `k`.
-}
maxPool : Int -> Expr -> Expr
maxPool k x =
    E.prim MaxPool [ x ] (P.ints [ k ])


{-| Returns the mean of each `k × k` window of the NHWC input `x`, with stride `k`.
-}
avgPool : Int -> Expr -> Expr
avgPool k x =
    E.prim AvgPool [ x ] (P.ints [ k ])


{-| Returns the one-hot rows of `labels` as an `n × classes` tensor of dtype `dt`, `n` being the
number of elements of `labels`: row `i` is 1 in column `labels[i]` and 0 elsewhere.

`labels` may have any shape: its `n` elements are taken in row-major order, after a cast to `si64`.
A label outside 0 … `classes` − 1 gives a row of zeros, with no error.

-}
oneHot : DT -> Int -> Expr -> Expr
oneHot dt classes labels =
    indicator dt (oneHotMask classes labels)


{-| Returns the `n × classes` mask that is true at column `labels[i]` of row `i`, read as `oneHot`
reads `labels`.
-}
oneHotMask : Int -> Expr -> Expr
oneHotMask classes labels =
    let
        n =
            List.product (E.shape labels)

        col =
            reshape [ n, 1 ] (cast SI64 labels)

        iota =
            reshape [ 1, classes ] (range 0 1 classes)
    in
    eq (broadcastTo [ n, classes ] col) (broadcastTo [ n, classes ] iota)


{-| Returns `m` cast to `dt`: for a mask, 1 where it is true and 0 where it is false.
-}
indicator : DT -> Expr -> Expr
indicator dt m =
    cast dt m


{-| Returns the vector whose element `i` is `x[i, idx[i]]`, for an `n × c` matrix `x` and `n`
indices `idx`, of any shape, read as `oneHot` reads labels.

It selects, in each row, `x` at the picked column and 0 elsewhere (`oneHotMask` of `idx`), and sums
each row, so a gradient reaches `x` at the picked element only, and the other elements of a row,
NaN and ±∞ included, do not change the result. An index outside 0 … `c` − 1 gives 0, with no error.

-}
pick : Expr -> Expr -> Expr
pick idx x =
    let
        classes =
            List.drop 1 (E.shape x) |> List.head |> Maybe.withDefault 1
    in
    reduce ReduceSum 1 (select (oneHotMask classes idx) x (zerosLike x))


{-| Returns `g` summed down to the shape `target`: over the leading axes of `g` that `target` lacks,
then over each axis where `target` has size 1 and `g` does not. With `g` the gradient of a tensor
of shape `target` broadcast to `g`'s shape, this is the gradient of the tensor before the
broadcast. `g` itself is returned when it already has shape `target`.

A `target` read from an expression's shape holds 1 for a pending axis, so the sum also runs over
that axis. Where `g` and `target` differ in some other way, the final reshape to `target` is
refused when the number of elements differs.

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


{-| Returns `x` with its slices along `axis` at the indices `idx` replaced by the slices of `upd`,
in order. Unlike `scatterRows`, `idx` is not reshaped: the `ScatterAxis` rule needs an integer
vector.
-}
scatterAxis : Int -> Expr -> Expr -> Expr -> Expr
scatterAxis axis x upd idx =
    E.prim ScatterAxis [ x, upd, idx ] (P.ints [ axis ])


{-| Returns `x` with each slice of `upd` along `axis` added to the slice of `x` at the matching
index of the integer vector `idx`.
-}
scatterAxisAdd : Int -> Expr -> Expr -> Expr -> Expr
scatterAxisAdd axis x upd idx =
    E.prim ScatterAxisAdd [ x, upd, idx ] (P.ints [ axis ])


{-| Returns the `k` largest elements of `x` along `axis`, in descending order, and their positions
along that axis as `si64`; with `largest` false, the `k` smallest, in ascending order.
-}
topK : Bool -> Int -> Int -> Expr -> ( Expr, Expr )
topK largest axis k x =
    let
        params =
            P.ints
                [ axis
                , k
                , if largest then
                    1

                  else
                    0
                ]
    in
    ( E.prim TopKValues [ x ] params, E.prim TopKIndices [ x ] params )


{-| Returns `f x`, except that for an `x` of dtype `f16` or `bf16`, `f` is applied to `x` cast to
`f32`, and its result is cast back to `x`'s dtype, whatever dtype `f` gives.
-}
inF32 : (Expr -> Expr) -> Expr -> Expr
inF32 f x =
    let
        dt =
            E.dtype x
    in
    if dt == F16 || dt == BF16 then
        cast dt (f (cast F32 x))

    else
        f x


{-| Returns the lowest value of `dt`: the lowest finite value of a floating-point dtype, the
lowest integer of a signed integer dtype, and 0 for an unsigned integer dtype and for `bool`.
-}
lowest : DT -> Float
lowest dt =
    case dt of
        F16 ->
            -65504

        BF16 ->
            -3.3895313892515355e38

        F32 ->
            -3.4028234663852886e38

        F64 ->
            -1.7976931348623157e308

        SI8 ->
            -128

        SI32 ->
            -2147483648

        SI64 ->
            -9.223372036854776e18

        UI8 ->
            0

        UI64 ->
            0

        Bool ->
            0


{-| Returns `e` with `k` pending axes added in front of its own, which an element-wise operation
with a tensor of `k` more axes, whose last axes match `e`'s, can give that tensor's sizes.
-}
leadingAxes : Int -> Expr -> Expr
leadingAxes k e =
    List.foldl (\_ acc -> broadcastAxis 0 acc) e (List.range 1 k)
