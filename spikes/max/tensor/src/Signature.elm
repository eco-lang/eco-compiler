module Signature exposing
    ( Sig, Builder
    , tensor, f32, bf16, i64, u8, mask, anyTensor
    , unit, pair, triple, list
    , record, field
    , map, label
    )

{-| Two-way descriptions of structured values of tensors: they build a value from tensors (a
graph's inputs, a traced function's parameters) and flatten one back (a graph's outputs, a call's
operands, a loop's state).

    Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch))

Records are described like `elm/json` decoders; a graph checks every record and `map` by a round
trip when it is built (an accessor in the wrong position is an error, not a silent swap).


# Signatures

@docs Sig, Builder


# Tensors

@docs tensor, f32, bf16, i64, u8, mask, anyTensor


# Structures

@docs unit, pair, triple, list


# Records

@docs record, field


# Changing a signature

@docs map, label

-}

import Tensor exposing (BF16, DType, F32, I64, Mask, Shape, Tensor, U8)
import Tensor.Internal.Expr exposing (Expr)
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


{-| A signature under construction, as an `elm/json` decoder pipeline is: it flattens an `r`
and builds an `f` (`record`, then one `field` per argument).
-}
type alias Builder r f =
    I.SigBuilder r f


{-| A signature of `a`: builds an `a` from tensors and flattens one back.
-}
type alias Sig a =
    Builder a a


one : Maybe DT -> Maybe (List Int) -> (Expr -> a) -> (a -> Expr) -> Sig a
one dt s wrap unwrap =
    I.SigBuilder
        { slots = [ { label = "arg", dtype = dt, shape = s, role = I.Fed } ]
        , build =
            \es ->
                case es of
                    e :: rest ->
                        ( wrap e, rest )

                    [] ->
                        ( wrap (Tensor.Internal.Expr.scalar F32 0), [] )
        , flatten = \a -> [ unwrap a ]
        }


{-| One tensor of the given dtype and shape.
-}
tensor : DType k d -> Shape s -> Sig (Tensor k d s)
tensor (I.DType dt _) (I.Shape s) =
    one (Just dt) (Just s) I.Tensor I.tensor


{-| `tensor` of dtype f32.
-}
f32 : Shape s -> Sig (Tensor Float F32 s)
f32 =
    tensor Tensor.float32


{-| `tensor` of dtype bf16.
-}
bf16 : Shape s -> Sig (Tensor Float BF16 s)
bf16 =
    tensor Tensor.bfloat16


{-| `tensor` of dtype i64.
-}
i64 : Shape s -> Sig (Tensor Int I64 s)
i64 =
    tensor Tensor.int64


{-| `tensor` of dtype u8.
-}
u8 : Shape s -> Sig (Tensor Int U8 s)
u8 =
    tensor Tensor.uint8


{-| A boolean mask of the given shape.
-}
mask : Shape s -> Sig (Mask s)
mask (I.Shape s) =
    one (Just Bool) (Just s) I.Mask I.mask


{-| A tensor whose dtype and shape come from the value it describes; not allowed for graph inputs.
-}
anyTensor : Sig (Tensor k d s)
anyTensor =
    one Nothing Nothing I.Tensor I.tensor


{-| No tensors.
-}
unit : Sig ()
unit =
    I.SigBuilder { slots = [], build = \es -> ( (), es ), flatten = \_ -> [] }


{-| Two values: the first's tensors, then the second's.
-}
pair : Sig a -> Sig b -> Sig ( a, b )
pair (I.SigBuilder a) (I.SigBuilder b) =
    I.SigBuilder
        { slots = a.slots ++ b.slots
        , build =
            \es ->
                let
                    ( x, r1 ) =
                        a.build es

                    ( y, r2 ) =
                        b.build r1
                in
                ( ( x, y ), r2 )
        , flatten = \( x, y ) -> a.flatten x ++ b.flatten y
        }


{-| Three values, in order.
-}
triple : Sig a -> Sig b -> Sig c -> Sig ( a, b, c )
triple sa sb sc =
    map (\( a, ( b, c ) ) -> ( a, b, c )) (\( a, b, c ) -> ( a, ( b, c ) )) (pair sa (pair sb sc))


{-| `n` values of one signature.
-}
list : Int -> Sig a -> Sig (List a)
list n (I.SigBuilder s) =
    I.SigBuilder
        { slots = List.concat (List.repeat n s.slots)
        , build =
            \es ->
                List.foldl
                    (\_ ( acc, rest ) ->
                        let
                            ( x, r ) =
                                s.build rest
                        in
                        ( x :: acc, r )
                    )
                    ( [], es )
                    (List.range 1 n)
                    |> Tuple.mapFirst List.reverse
        , flatten = List.concatMap s.flatten
        }


{-| A record from its constructor; `field` adds the fields in the constructor's argument order.

    Sig.record Batch
        |> Sig.field .images (Sig.u8 (T.r2 batch pixels))
        |> Sig.field .labels (Sig.u8 (T.r1 batch))

-}
record : f -> Builder r f
record constructor =
    I.SigBuilder { slots = [], build = \es -> ( constructor, es ), flatten = \_ -> [] }


{-| The next field: its accessor and its signature. A graph refuses a record whose accessors
are not in the constructor's order.
-}
field : (r -> a) -> Sig a -> Builder r (a -> f) -> Builder r f
field getter (I.SigBuilder s) (I.SigBuilder b) =
    I.SigBuilder
        { slots = b.slots ++ s.slots
        , build =
            \es ->
                let
                    ( f, r1 ) =
                        b.build es

                    ( x, r2 ) =
                        s.build r1
                in
                ( f x, r2 )
        , flatten = \r -> b.flatten r ++ s.flatten (getter r)
        }


{-| A signature through an isomorphism (`to` and `from` must be inverses: checked when used).
-}
map : (a -> b) -> (b -> a) -> Sig a -> Sig b
map to from (I.SigBuilder s) =
    I.SigBuilder
        { slots = s.slots
        , build = \es -> Tuple.mapFirst to (s.build es)
        , flatten = from >> s.flatten
        }


{-| Names the inputs or outputs `l`, or `l0`, `l1` .. when there are several.
-}
label : String -> Sig a -> Sig a
label l (I.SigBuilder s) =
    I.SigBuilder { s | slots = List.map (\sl -> { sl | label = l }) s.slots }
