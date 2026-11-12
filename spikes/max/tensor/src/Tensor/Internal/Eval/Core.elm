module Tensor.Internal.Eval.Core exposing
    ( Data(..)
    , T
    , broadcastShapes
    , dataLength
    , floatsOf
    , fromValues
    , getF
    , getI
    , intsOf
    , isUnsigned64
    , lanes
    , pick
    , size
    , split
    , strided
    , strides
    , toFloatsU
    , withLanes
    , wrapInt
    , zeros
    )

{-| The evaluator's values: a dtype, a shape and the elements in row-major order, `Float`s for
floating dtypes and `Int`s for integer dtypes and Bool (0 or 1). Floating values are held as f64
(rounding to the dtype is a later phase); integers wrap to their dtype after every operation.
-}

import Array exposing (Array)
import Tensor.Internal.Eval.U64 as U64
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Values exposing (Values(..))


type Data
    = F (Array Float)
    | I (Array Int)


type alias T =
    { dt : DT, shape : List Int, data : Data }


size : List Int -> Int
size =
    List.product


{-| Row-major strides: `[d1·…·dn, …, dn, 1]`.
-}
strides : List Int -> List Int
strides shape =
    List.foldr (\d ( acc, s ) -> ( s :: acc, s * d )) ( [], 1 ) shape |> Tuple.first


dataLength : Data -> Int
dataLength d =
    case d of
        F a ->
            Array.length a

        I a ->
            Array.length a


{-| An `Int` wrapped to its dtype: two's complement for the signed ones, 0/1 for Bool. i64 and u64
are `Int` itself (eco's wraps).
-}
wrapInt : DT -> Int -> Int
wrapInt dt n =
    case dt of
        SI8 ->
            modBy 256 (n + 128) - 128

        UI8 ->
            modBy 256 n

        SI32 ->
            modBy 4294967296 (n + 2147483648) - 2147483648

        Bool ->
            if n /= 0 then
                1

            else
                0

        _ ->
            n


isUnsigned64 : DT -> Bool
isUnsigned64 dt =
    dt == UI64


fromValues : DT -> List Int -> Values -> T
fromValues dt shape vs =
    case vs of
        FloatValues l ->
            if P.isFloat dt then
                { dt = dt, shape = shape, data = F (Array.fromList l) }

            else
                { dt = dt, shape = shape, data = I (Array.fromList (List.map (round >> wrapInt dt) l)) }

        IntValues l ->
            if P.isFloat dt then
                { dt = dt, shape = shape, data = F (Array.fromList (List.map toFloat l)) }

            else
                { dt = dt, shape = shape, data = I (Array.fromList (List.map (wrapInt dt) l)) }


zeros : DT -> List Int -> T
zeros dt shape =
    { dt = dt
    , shape = shape
    , data =
        if P.isFloat dt then
            F (Array.repeat (size shape) 0)

        else
            I (Array.repeat (size shape) 0)
    }


getF : Array Float -> Int -> Float
getF a i =
    Maybe.withDefault 0 (Array.get i a)


getI : Array Int -> Int -> Int
getI a i =
    Maybe.withDefault 0 (Array.get i a)


{-| The elements as floats (u64 by their unsigned value).
-}
floatsOf : T -> Array Float
floatsOf t =
    case t.data of
        F a ->
            a

        I a ->
            if t.dt == UI64 then
                Array.map U64.toFloatU a

            else
                Array.map toFloat a


toFloatsU : T -> List Float
toFloatsU t =
    Array.toList (floatsOf t)


intsOf : T -> Array Int
intsOf t =
    case t.data of
        I a ->
            a

        F a ->
            Array.map round a



-- INDEX MAPS


{-| A strided view: for each output axis its size and the input stride (0 to repeat), plus a base
offset. Gives the input's flat index of each output flat index.
-}
strided : Int -> List ( Int, Int ) -> Int -> Int
strided base axes k0 =
    List.foldr
        (\( d, st ) ( k, acc ) ->
            if d <= 1 then
                ( k, acc )

            else
                ( k // d, acc + modBy d k * st )
        )
        ( k0, base )
        axes
        |> Tuple.second


{-| NumPy broadcasting: right-aligned, equal sizes or 1.
-}
broadcastShapes : List Int -> List Int -> List Int
broadcastShapes a b =
    let
        n =
            max (List.length a) (List.length b)

        pad l =
            List.repeat (n - List.length l) 1 ++ l
    in
    List.map2
        (\x y ->
            if x == 1 then
                y

            else
                x
        )
        (pad a)
        (pad b)


{-| The input flat index of each output flat index when `inShape` is broadcast (right-aligned) to
`outShape`.
-}
split : List Int -> List Int -> (Int -> Int)
split outShape inShape =
    if outShape == inShape then
        identity

    else
        let
            off =
                List.length outShape - List.length inShape

            inPadded =
                List.repeat off 1 ++ inShape

            st =
                List.repeat off 0 ++ strides inShape

            axes =
                List.map3
                    (\od idim s ->
                        if idim == 1 then
                            ( od, 0 )

                        else
                            ( od, s )
                    )
                    outShape
                    inPadded
                    st
        in
        strided 0 axes


{-| A new tensor from source flat indices (−1: the fill value).
-}
pick : DT -> List Int -> List Int -> ( Float, Int ) -> Data -> T
pick dt shape indices ( fillF, fillI ) d =
    { dt = dt
    , shape = shape
    , data =
        case d of
            F a ->
                F
                    (Array.fromList
                        (List.map
                            (\i ->
                                if i < 0 then
                                    fillF

                                else
                                    getF a i
                            )
                            indices
                        )
                    )

            I a ->
                I
                    (Array.fromList
                        (List.map
                            (\i ->
                                if i < 0 then
                                    fillI

                                else
                                    getI a i
                            )
                            indices
                        )
                    )
    }



-- LANES


{-| The flat indices of every lane along `axis`, in output order (outer-major, inner-minor).
-}
lanes : List Int -> Int -> List (List Int)
lanes shape axis =
    let
        outer =
            size (List.take axis shape)

        n =
            Maybe.withDefault 1 (List.head (List.drop axis shape))

        inner =
            size (List.drop (axis + 1) shape)
    in
    List.concatMap
        (\o -> List.map (\i -> List.map (\k -> (o * n + k) * inner + i) (List.range 0 (n - 1))) (List.range 0 (inner - 1)))
        (List.range 0 (outer - 1))


{-| Lanes of length m (in `lanes` order) laid back out with size m on `axis`.
-}
withLanes : List Int -> Int -> Int -> List (List a) -> List a
withLanes shape axis m ls =
    let
        outer =
            size (List.take axis shape)

        inner =
            size (List.drop (axis + 1) shape)

        rows =
            Array.fromList (List.map Array.fromList ls)
    in
    List.concatMap
        (\o ->
            List.concatMap
                (\j ->
                    List.filterMap
                        (\i -> Array.get (o * inner + i) rows |> Maybe.andThen (Array.get j))
                        (List.range 0 (inner - 1))
                )
                (List.range 0 (m - 1))
        )
        (List.range 0 (outer - 1))
