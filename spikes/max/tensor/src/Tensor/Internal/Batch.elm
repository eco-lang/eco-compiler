module Tensor.Internal.Batch exposing (stack, unstack, vmapRule)

{-| A function meant for one example can be written once and applied to a whole batch of them,
and this module is what makes that work: it implements `vmap`.

A _batch_ is a tensor whose leading axis, the _batch axis_, holds `n` _examples_: example `k` is
the slice at position `k` along that axis, without the axis. `vmapRule` _traces_ the per-example
function with `Tensor.Internal.Grad.trace`, rather than applying it to each example: it applies
the function to _placeholders_, expressions standing for its arguments, and keeps the expressions
it returns. It then rewrites the trace into expressions over the whole batch, visiting each traced
expression after its operands.

During the rewrite a traced expression is _batched_ when it reads a placeholder, directly or
through its operands, or is a `While` whose test or step reads one, through operands and the bodies
of loops nested in them (`Tensor.Internal.Control.inLoops`); it is _plain_ otherwise. A plain
expression is the same for every example and is kept as it is. A batched one is replaced by its
_batched version_: an expression with the batch axis in front, whose example `k` is what the traced
expression computes for example `k`. An unrolled `Call`, `If` or `While` node is an exception to
this, as `unroll` describes. A placeholder's batched version is the batched argument it stands for.
The bodies of `Call` and `If` nodes are not looked into: a `cond` has closed its branches over what
they read from outside, so that is among the `If`'s operands.

A random draw that the rewrite reaches is batched even when it reads no placeholder. When its seed
does not depend on the batch, it becomes one draw whose shape has `n` in front, so each example
reads its own slice of that draw, whether the draw was made in the function or made before
`vmapRule` was applied and only read by the function. Applying the function to each example
separately would instead give every example the same values. A draw whose seed does depend on the
batch is unrolled, each example drawing on its own seed. A draw inside the body of a `Call`, `If` or
`While` node is not reached by the rewrite, so one whose seed does not depend on the batch is the
same for every example.

A _batching rule_ builds a primitive's batched version directly from its operands' batched
versions, mostly by adjusting its _params_, the numbers it is configured by beside its operands
(`Tensor.Internal.Prim.Params`): an axis moves up by one, and a shape, or the start and size of
the block a `Slice` takes, gains an entry for the batch axis in front. An element-wise primitive's
plain operand of rank 1 or more is given a pending leading axis (an axis whose size is not yet
known, as `Tensor.Internal.Shape` defines it), which then takes its size from a batched operand of
the same rank when there is one; a rank-0 plain operand is left as it is, and a batched operand
that is rank 0 for each example is given pending axes behind its batch axis. A message that `Tensor.Internal.Expr.failWith`
recorded on the traced expression is recorded on its batched version too
(`Tensor.Internal.Expr.keepCheck`).

Where there is no rule, the expression is _unrolled_: rebuilt once per example on that example of
each batched operand, and the `n` results stacked along a new batch axis. A batched `Call`, `If` or
`While` node is always unrolled. Among primitives, `Conv`, `ConvTranspose`, `MaxPool`, `AvgPool`,
`ScatterRows`, `ScatterRowsAdd` and `XentLogits` have no rule, and `Gather`, `ScatterAxis`,
`ScatterAxisAdd`, `LayerNorm` and `Random` have one only when their indices, their gain and bias, or
their seed are plain.

-}

import Dict exposing (Dict)
import Tensor.Internal.Control as C
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key exposing (Key)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..))


{-| Returns the examples of `x` along its leading axis, in order, each without that axis. A rank-0
`x`, or one whose leading axis has size 0, gives an empty list.
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


{-| Returns example `k` of `x`: its slice at position `k` along the leading axis, without that axis.
A `k` outside the axis gives a slice that the `Slice` rule refuses, and so can an `x` with a pending
axis.
-}
example : Expr -> Int -> Expr
example x k =
    let
        s =
            E.shape x
    in
    O.dropAxis 0 (O.slice (k :: List.map (\_ -> 0) (List.drop 1 s)) (1 :: List.drop 1 s) x)


{-| Returns `xs` as the examples of one batch, in order, each given a new leading axis and the
results joined along it. The expressions must share a dtype and a shape, which the `Concat` rule
checks, and an empty list is refused by that rule too.
-}
stack : List Expr -> Expr
stack xs =
    O.concat 0 (List.map (O.insertAxis 0) xs)


{-| Returns the outputs of the per-example function `f` on the batched tensors in `leaves`, as
batches. Example `k` of an output is what `f` gives on example `k`, with exceptions that include a
random draw on a seed that does not depend on the batch (redrawn for each example, as the module
docstring describes), the body of a `Call` that reads a placeholder, and an unrolled expression with
a batched operand that has a pending axis, which `example` cannot slice.

`leaves` pairs tensors with whether each is batched. `f` is given one placeholder for each batched
tensor, in order, with the dtype and shape of that tensor's example 0; a tensor marked unbatched is
not passed to `f` at all. `f` returns a structured value together with its output tensors. The
result pairs that structured value, exactly as `f` returned it on the placeholders, with the
outputs' batched versions, in order. A tensor inside the structured value that depends on the
arguments reads the placeholders.

The batch size `n` is the leading size of the first batched tensor of rank 1 or more, or 1 when
there is none. A batched tensor of rank 0, one with a pending axis, one with a leading size of 0
and one whose leading size is not `n` are each refused: every output is failed with a message
starting "vmap:" that says which (`Tensor.Internal.Expr.inherit` of the first such tensor, failed
with its message unless it had already failed).

An output that is not batched is the same for every example, and comes back repeated `n` times
along a new batch axis by `repeated`, its pending axes kept.

`f` is applied three times: twice by `Tensor.Internal.Grad.trace`, and once more for the
structured value.

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
            batched |> List.filter (\b -> E.rank b > 0) |> List.head |> Maybe.andThen (E.shape >> List.head) |> Maybe.withDefault 1

        leafProblem b =
            case E.shape b of
                [] ->
                    Just "vmap: a batched argument has no axes, so it has no batch axis"

                m :: _ ->
                    if not (List.isEmpty (E.pending b)) then
                        Just "vmap: a batched argument has a broadcast axis (as broadcast, rows, columns and maskBroadcast make); give it a size with broadcastTo first"

                    else if m == 0 then
                        Just "vmap: a batched argument has no examples (its leading size is 0)"

                    else if m /= n then
                        Just ("vmap: batched arguments have leading sizes " ++ String.fromInt n ++ " and " ++ String.fromInt m)

                    else
                        Nothing

        checked =
            List.map (\b -> leafProblem b |> Maybe.map (\msg -> E.failWith msg b) |> Maybe.withDefault b) batched

        failed =
            List.filterMap (\b -> leafProblem b |> Maybe.map (\msg -> E.failWith msg b)) batched

        perExample =
            List.map (\b -> O.slice (List.map (\_ -> 0) (E.shape b)) (1 :: List.drop 1 (E.shape b)) b |> O.dropAxis 0) batched

        traced =
            Grad.trace "vmap" perExample (\vs -> Tuple.second (f vs))

        ( result, _ ) =
            f traced.vars

        start =
            { batched = Dict.fromList (List.map2 (\v b -> ( E.key v, b )) traced.vars checked)
            , multi = Dict.empty
            }

        final =
            List.foldl (rewrite n) start (Grad.postorder traced.outputs)

        out e =
            case Dict.get (E.key e) final.batched of
                Just b ->
                    b

                Nothing ->
                    repeated n e
    in
    ( result, List.map (\e -> List.foldl E.inherit (out e) failed) traced.outputs )


{-| Returns `n` copies of `e` stacked along a new leading axis, keeping `e`'s pending axes pending
behind it. Without pending axes this is a `BroadcastTo`. With them, which `BroadcastTo` refuses,
it is a `Select` whose mask is `n` `True`s with a pending axis for each axis of `e`, and whose two
tensors are both `e` with a pending axis in front: the element-wise rule gives that axis the
mask's size `n`, and keeps each pending axis of `e` pending.
-}
repeated : Int -> Expr -> Expr
repeated n e =
    if List.isEmpty (E.pending e) then
        O.broadcastTo (n :: E.shape e) (O.insertAxis 0 e)

    else
        let
            mask =
                List.foldl (\_ m -> O.broadcastAxis 1 m) (O.broadcastTo [ n ] (E.scalar Bool 1)) (E.shape e)

            front =
                O.broadcastAxis 0 e
        in
        O.select mask front front


{-| What the rewrite has found so far, by the key of the traced expression it concerns.

`batched` holds the batched version of each batched expression visited that is not in `multi`,
the placeholders included. `multi` holds, for each unrolled `Call`, `If` or `While` node, its
per-example copies in order of example, from which its projections are stacked. An expression in
neither is plain.

-}
type alias State =
    { batched : Dict Key Expr, multi : Dict Key (List Expr) }


{-| Returns `st` with the traced expression `e` recorded as batched, when it is, given that every
operand of `e` has already been visited.

`e` is batched when an operand is batched or is an unrolled multi-result node, when `e` is a
`While` whose test or step reads one (`loopReadsAny`), and when `e` is a random draw. A primitive goes through its batching rule
(`rule`), its result given `e`'s `failWith` message by `Tensor.Internal.Expr.keepCheck`, and is
unrolled when the rule gives `Nothing`; a projection of an unrolled node stacks the same projection
of each per-example copy; a `Call`, `If` or `While` node is unrolled. A plain `e` leaves `st`
unchanged.

-}
rewrite : Int -> Expr -> State -> State
rewrite n e st =
    if Dict.member (E.key e) st.batched then
        st

    else
        let
            ops =
                E.operands e

            isBatched o =
                Dict.member (E.key o) st.batched || Dict.member (E.key o) st.multi

            isRandom =
                case E.op e of
                    E.P Random _ _ ->
                        True

                    _ ->
                        False
        in
        if not (isRandom || List.any isBatched ops || loopReadsAny isBatched e) then
            st

        else
            case E.op e of
                E.P p args params ->
                    case rule n p args params e st of
                        Just b ->
                            { st | batched = Dict.insert (E.key e) (E.keepCheck e b) st.batched }

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


{-| Returns whether `e` is a `While` whose test or step reads, through operands and the bodies of
loops nested in them (`Tensor.Internal.Control.inLoops`), an expression for which `test` holds.
-}
loopReadsAny : (Expr -> Bool) -> Expr -> Bool
loopReadsAny test e =
    case E.op e of
        E.While _ _ _ ->
            List.any test (C.inLoops (List.concatMap .outputs (E.bodies e)))

        _ ->
            False


{-| Returns `st` with `e` unrolled: `e` rebuilt for each of the first `n` examples, on that example
of each batched operand and on its plain operands as they are.

A node with one result is recorded in `batched` as the per-example copies stacked into a batch. A
multi-result node is recorded in `multi` as the list of copies, since it is read only through its
projections. The bodies of a `Call` or `If` node are copied unchanged. In each copy of a `While`,
its test and step are rewritten by `Tensor.Internal.Control.substituteInLoops` (through
`Tensor.Internal.Expr.mapBodies`), each batched expression they read replaced by that example of
its batched version, and each unrolled node they read by that example's copy.

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

        inBodyAt k x =
            case Dict.get (E.key x) st.batched of
                Just b ->
                    Just (example b k)

                Nothing ->
                    Dict.get (E.key x) st.multi |> Maybe.andThen (List.drop k >> List.head)

        copy k =
            let
                rebuilt =
                    E.rebuild e (List.map (operandAt k) ops)
            in
            case E.op e of
                E.While _ _ _ ->
                    E.mapBodies (\b -> { b | outputs = C.substituteInLoops (inBodyAt k) b.outputs }) rebuilt

                _ ->
                    rebuilt

        perExample =
            List.map copy (List.range 0 (n - 1))
    in
    if List.isEmpty (E.node e).results then
        { st | batched = Dict.insert (E.key e) (stack perExample) st.batched }

    else
        { st | multi = Dict.insert (E.key e) perExample st.multi }


{-| An operand of a primitive being batched, as its batching rule sees it.

`Batched` carries the operand's batched version, with the batch axis in front. `Plain` carries the
operand as traced, which is the same for every example and has no batch axis.

-}
type Operand
    = Batched Expr
    | Plain Expr


{-| Returns the batched version of `e`, the traced node applying `p` to `args` with `params`, by
`p`'s batching rule, or `Nothing` when `p` has no rule for these operands.

An operand is batched when `st` holds its batched version. To _materialise_ a plain operand is to
repeat it `n` times along a new batch axis, for a primitive that needs every operand batched.

  - An element-wise primitive is applied to the batched operands, with each plain operand of rank
    1 or more given a pending leading axis and a rank-0 one left as it is. A batched operand that
    is rank 0 for each example is given pending axes just behind its batch axis, as many as the
    largest rank any operand has for each example, so that the element-wise rule spreads it as it
    spreads a rank-0 operand of one example.
  - A primitive along one axis (the reductions, `ArgMax`, `ArgMin`, `Softmax`, `LogSoftmax`,
    `CumSum`, `TopKValues`, `TopKIndices`, `Pad`) has the axis in `params.a` moved up by one.
  - `Reshape`, `Transpose` and `Slice` get the batch axis in front of their target shape,
    permutation or block. `BroadcastTo` does too, after first giving the operand, just behind its
    batch axis, the size-1 axes that it would add in front. `Reshape` also has the pending-axis
    positions in `params.b` moved up by one, and `Transpose` the entries of its permutation.
  - `Concat` materialises its plain operands and moves its axis up by one.
  - `Gather` moves its axis up by one, and has a rule only when its tensor is batched and its
    indices plain. `ScatterAxis` and `ScatterAxisAdd` have one only when their indices are plain
    (`scatterAxisRule`), and `LayerNorm` only when its gain and bias are plain.
  - `BandPart` keeps its params, since it works on the last two axes.
  - `MatMul` is batched by `matmulRule`.
  - `Random` with a plain seed gets `n` in front of the shape it draws and keeps that seed, so it
    is one draw of which each example reads its own slice. With a batched seed it has no rule.

Every other primitive has no rule.

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

        widest =
            operands
                |> List.map
                    (\o ->
                        case o of
                            Batched b ->
                                E.rank b - 1

                            Plain x ->
                                E.rank x
                    )
                |> List.maximum
                |> Maybe.withDefault 0

        elementwise o =
            case o of
                Batched b ->
                    if E.rank b == 1 then
                        List.foldl (\_ acc -> O.broadcastAxis 1 acc) b (List.range 1 widest)

                    else
                        b

                Plain x ->
                    if E.rank x == 0 then
                        x

                    else
                        O.broadcastAxis 0 x

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

                TopKValues ->
                    axisRule shifted operands p

                TopKIndices ->
                    axisRule shifted operands p

                ScatterAxis ->
                    scatterAxisRule shifted full operands p

                ScatterAxisAdd ->
                    scatterAxisRule shifted full operands p

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

                MatMul ->
                    matmulRule n operands e

                Random ->
                    case ( operands, params.a ) of
                        ( [ Plain _ ], kind :: dt :: s ) ->
                            Just (E.prim Random args { params | a = kind :: dt :: n :: s })

                        _ ->
                            Nothing

                _ ->
                    Nothing


{-| Returns the batched version of a `ScatterAxis` or `ScatterAxisAdd` (`p`) whose indices are
plain: the tensor and the updates, materialised by `full` where plain, scattered into with the
same indices for every example, along the axis moved up by one. Batched indices, or params with
no axis, give `Nothing`.
-}
scatterAxisRule : ((Int -> Int) -> Maybe P.Params) -> (Operand -> Expr) -> List Operand -> Prim -> Maybe Expr
scatterAxisRule shifted full operands p =
    case operands of
        [ x, upd, Plain idx ] ->
            shifted ((+) 1) |> Maybe.map (\pa -> E.prim p [ full x, full upd, idx ] pa)

        _ ->
            Nothing


{-| Returns `p` applied to its one batched operand with the axis at the head of its params moved up
by one, past the batch axis. Any other operands, or params with no axis, give `Nothing`.
-}
axisRule : ((Int -> Int) -> Maybe P.Params) -> List Operand -> Prim -> Maybe Expr
axisRule shifted operands p =
    case operands of
        [ Batched b ] ->
            shifted ((+) 1) |> Maybe.map (\pa -> E.prim p [ b ] pa)

        _ ->
            Nothing


{-| Returns the batched version of the traced product `e` of `x` and `w`, the two operands in that
order, as one matrix product over the batch.

A plain operand is given a pending leading axis, which the `MatMul` rule sizes from the batched
operand's. A per-example vector becomes a matrix: a row when it is `x`, a column when it is `w`.
The operand of lower rank then gets size-1 axes just behind its batch axis until the ranks agree,
and the `MatMul` rule repeats it along them, as it does a size-1 batch axis against a larger one.
When `e` has pending axes, those added axes are pending, so that a pending batch axis of the other
operand stays pending as it does in `e`. The product is reshaped to `n` in front of `e`'s shape,
which removes the axis a vector gained; when `e` has pending axes the product's are kept pending,
and a product that already has that shape is returned as it is. Any number of operands other than
two gives `Nothing`.

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

                keepPending =
                    not (List.isEmpty (E.pending e))

                pad t toRank =
                    List.foldl
                        (\_ acc ->
                            if keepPending then
                                O.broadcastAxis 1 acc

                            else
                                O.insertAxis 1 acc
                        )
                        t
                        (List.range 1 (toRank - E.rank t))

                r =
                    max (E.rank x2) (E.rank w2)

                product =
                    O.matmul (pad x2 r) (pad w2 r)

                target =
                    n :: E.shape e
            in
            if keepPending && E.shape product /= target then
                Just (E.prim Reshape [ product ] { a = target, b = E.pending product, f = [] })

            else if keepPending then
                Just product

            else
                Just (O.reshape target product)

        _ ->
            Nothing
