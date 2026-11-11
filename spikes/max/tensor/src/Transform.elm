module Transform exposing
    ( grad, valueAndGrad, gradOf, valueAndGradOf, vjp, jvp, jacobian, hessianVector
    , vmap, vmap2, Batch, tensor, keep, pair, vmapWith
    , Shared, shared, call
    )

{-| Function transforms: gradients to any order, forward mode, vectorisation, shared subgraphs.

Every transform traces its function on fresh placeholders and differentiates or rewrites the trace,
so `grad (\y -> y |> T.times x) x` is x (not 2x) and transforms nest.

-}

import Signature exposing (Sig)
import Tensor as T exposing (Floating, R0, R1, R2, Tensor)
import Tensor.Internal.Batch as B
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Ops as O
import Tensor.Internal.Shared as Sh
import Tensor.Internal.Prim
import Tensor.Internal.Types as I


{-| The gradient of a scalar function.
-}
grad : (Tensor Floating d s -> Tensor Floating d R0) -> Tensor Floating d s -> Tensor Floating d s
grad f x =
    I.Tensor (Grad.grad (\v -> I.tensor (f (I.Tensor v))) (I.tensor x))


valueAndGrad : (Tensor Floating d s -> Tensor Floating d R0) -> Tensor Floating d s -> ( Tensor Floating d R0, Tensor Floating d s )
valueAndGrad f x =
    ( f x, grad f x )


{-| The gradient with respect to every tensor in a structured value (integer tensors get zeros).
-}
gradOf : Sig a -> (a -> Tensor Floating d R0) -> a -> a
gradOf s f a =
    Tuple.second (valueAndGradOf s f a)


valueAndGradOf : Sig a -> (a -> Tensor Floating d R0) -> a -> ( Tensor Floating d R0, a )
valueAndGradOf (I.SigBuilder s) f a =
    Grad.gradStructured (\es -> Tuple.first (s.build es)) s.flatten (f >> I.tensor) a
        |> Tuple.mapFirst I.Tensor


{-| The outputs of `f` at `a`, and the pullback from output cotangents to input cotangents.
-}
vjp : Sig a -> Sig b -> (a -> b) -> a -> ( b, b -> a )
vjp (I.SigBuilder sa) (I.SigBuilder sb) f a =
    let
        lifted es =
            sb.flatten (f (Tuple.first (sa.build es)))

        ( outs, pullback ) =
            Grad.vjp lifted (sa.flatten a)
    in
    ( Tuple.first (sb.build outs), \cot -> Tuple.first (sa.build (pullback (sb.flatten cot))) )


{-| The outputs of `f` at `a` and their derivative along the tangent `t` (forward mode, derived by
transposing the vjp).
-}
jvp : Sig a -> Sig b -> (a -> b) -> a -> a -> ( b, b )
jvp (I.SigBuilder sa) (I.SigBuilder sb) f a t =
    let
        lifted es =
            sb.flatten (f (Tuple.first (sa.build es)))

        ( outs, tangents ) =
            Grad.jvp lifted (sa.flatten a) (sa.flatten t)
    in
    ( Tuple.first (sb.build outs), Tuple.first (sb.build tangents) )


{-| The Jacobian of a vector function: row i is the gradient of output i, all rows at once (the
pullback `vmap`ped over the rows of the identity).
-}
jacobian : (Tensor Floating d (R1 a) -> Tensor Floating d (R1 b)) -> Tensor Floating d (R1 a) -> Tensor Floating d (R2 b a)
jacobian f x =
    let
        ( outs, pullback ) =
            Grad.vjp (\es -> List.map (\e -> I.tensor (f (I.Tensor e))) es) [ I.tensor x ]

        y =
            List.head outs |> Maybe.withDefault (I.tensor x)

        m =
            List.product (E.shape y)

        identity =
            E.const (E.dtype y) [ m, m ] (List.concatMap (\i -> List.map (\j -> if i == j then 1 else 0) (List.range 0 (m - 1))) (List.range 0 (m - 1)))

        ( _, rows ) =
            B.vmapRule [ ( identity, True ) ] (\basis -> ( (), pullback basis ))
    in
    I.Tensor (List.head rows |> Maybe.withDefault (I.tensor x))


{-| H v, the Hessian of `f` at `x` times `v`, by differentiating the gradient's projection on `v`
(`v` may depend on `x`: it is held constant).
-}
hessianVector : (Tensor Floating d s -> Tensor Floating d R0) -> Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d s
hessianVector f x v =
    grad (\y -> grad f y |> T.times v |> T.sumAll) x


{-| `f` applied to every example along a leading batch axis.
-}
vmap : I.Lift n s t -> I.Lift n u v -> (Tensor k d s -> Tensor k2 d2 u) -> Tensor k d t -> Tensor k2 d2 v
vmap ls lu f x =
    vmapWith (tensor ls) (tensor lu) f x


vmap2 : I.Lift n s t -> I.Lift n s2 t2 -> I.Lift n u v -> (Tensor k d s -> Tensor k1 d1 s2 -> Tensor k2 d2 u) -> Tensor k d t -> Tensor k1 d1 t2 -> Tensor k2 d2 v
vmap2 la lb lu f x y =
    vmapWith (pair (tensor la) (tensor lb)) (tensor lu) (\( a, c ) -> f a c) ( x, y )


{-| How a per-example value becomes a batched one.
-}
type alias Batch a b =
    I.Batch a b


{-| A tensor gains a leading batch axis.
-}
tensor : I.Lift n s t -> Batch (Tensor k d s) (Tensor k d t)
tensor _ =
    I.Batch
        { leaves = \b -> [ ( I.tensor b, True ) ]
        , perExample =
            \_ es ->
                case es of
                    e :: rest ->
                        ( I.Tensor e, rest )

                    [] ->
                        ( I.Tensor (E.scalar Tensor.Internal.Prim.F32 0), [] )
        , flatten = \a -> [ I.tensor a ]
        , build =
            \_ es ->
                case es of
                    e :: rest ->
                        ( I.Tensor e, rest )

                    [] ->
                        ( I.Tensor (E.scalar Tensor.Internal.Prim.F32 0), [] )
        }


{-| A value passed to every example unchanged (Nabla's `in_axes=None`); as an output, a value that
does not depend on the batch.
-}
keep : Batch a a
keep =
    I.Batch
        { leaves = \_ -> []
        , perExample = \b es -> ( b, es )
        , flatten = \_ -> []
        , build = \a es -> ( a, es )
        }


pair : Batch a b -> Batch c e -> Batch ( a, c ) ( b, e )
pair (I.Batch x) (I.Batch y) =
    I.Batch
        { leaves = \( b, e ) -> x.leaves b ++ y.leaves e
        , perExample =
            \( b, e ) es ->
                let
                    ( a, r1 ) =
                        x.perExample b es

                    ( c, r2 ) =
                        y.perExample e r1
                in
                ( ( a, c ), r2 )
        , flatten = \( a, c ) -> x.flatten a ++ y.flatten c
        , build =
            \( a, c ) es ->
                let
                    ( b, r1 ) =
                        x.build a es

                    ( e, r2 ) =
                        y.build c r1
                in
                ( ( b, e ), r2 )
        }


{-| `f` applied to every example of a structured batched value: traced once and batched by rules
per operation.
-}
vmapWith : Batch a ba -> Batch b bb -> (a -> b) -> ba -> bb
vmapWith (I.Batch bi) (I.Batch bo) f x =
    let
        ( perExampleOut, batchedLeaves ) =
            B.vmapRule (bi.leaves x)
                (\vs ->
                    let
                        y =
                            f (Tuple.first (bi.perExample x vs))
                    in
                    ( y, bo.flatten y )
                )
    in
    Tuple.first (bo.build perExampleOut batchedLeaves)


{-| A function traced once (when this value is built) and emitted as one MAX subgraph.
-}
type alias Shared a b =
    I.Shared a b


shared : String -> Sig a -> Sig b -> (a -> b) -> Shared a b
shared name sa sb f =
    Sh.shared name sa sb f


call : Shared a b -> a -> b
call (I.Shared s) =
    s.apply
