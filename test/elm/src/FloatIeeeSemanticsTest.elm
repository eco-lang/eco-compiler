module FloatIeeeSemanticsTest exposing (main)

{-| eco's Float semantics (design_docs/float-semantics.md): one IEEE-consistent model, as
WebAssembly chose, in place of Elm's JS-generator-dependent behaviour.

  - `==` `/=` `<` `<=` `>` `>=` are IEEE 754 comparisons whatever the operands are: every
    order comparison with a NaN is False, `/=` is the negation of `==`.
  - `compare` is a total order: NaN equals NaN and is greater than every number, and -0
    equals +0. `sort`, `Dict` and `Set` use it, and so do the order operators on tuples and
    lists.
  - `max` `min` `clamp` are IEEE 754-2019 maximum / minimum: a NaN argument gives NaN in
    either position, and -0 is less than +0.
  - `round` keeps Elm's ties toward +infinity.
  - `round` `floor` `ceiling` `truncate` convert to a 64-bit Int saturating, with NaN giving 0
    (`truncate` rounds toward zero, with no 32-bit wrap).

Each path is checked: the operator or function applied directly, inlined, through `case
compare`, as a function value, and inside tuples, lists, sort, Dict and Set. Values are
formatted by the helpers below, not Debug.toString.
-}

-- CHECK: lit nan < 1: "False"
-- CHECK: lit nan <= 1: "False"
-- CHECK: lit nan > 1: "False"
-- CHECK: lit nan >= 1: "False"
-- CHECK: lit 1 > nan: "False"
-- CHECK: lit nan == 1: "False"
-- CHECK: lit nan /= 1: "True"
-- CHECK: var nan < one: "False"
-- CHECK: var nan <= one: "False"
-- CHECK: var nan > one: "False"
-- CHECK: var nan >= one: "False"
-- CHECK: var one > nan: "False"
-- CHECK: var one >= nan: "False"
-- CHECK: var nan > nan: "False"
-- CHECK: var nan >= nan: "False"
-- CHECK: var nan == nan: "False"
-- CHECK: var nan /= nan: "True"
-- CHECK: compare nan 1: "GT"
-- CHECK: compare 1 nan: "LT"
-- CHECK: compare nan nan: "EQ"
-- CHECK: compare inf nan: "LT"
-- CHECK: compare nan -inf: "GT"
-- CHECK: compare -0 0: "EQ"
-- CHECK: compare 0 -0: "EQ"
-- CHECK: compare 1 2: "LT"
-- CHECK: case compare nan 1: "GT"
-- CHECK: case compare 1 nan: "LT"
-- CHECK: case compare nan nan: "EQ"
-- CHECK: case compare -0 0: "EQ"
-- CHECK: map2 compare: "GT,LT,EQ"
-- CHECK: compare tuple nan: "GT"
-- CHECK: compare tuple second nan: "GT"
-- CHECK: compare list nan: "LT"
-- CHECK: tuple nan lt: "False"
-- CHECK: list nan gt: "True"
-- CHECK: tuple nan eq: "False"
-- CHECK: sort: "1,2,3,NaN,NaN"
-- CHECK: sortBy: "1,2,3,NaN,NaN"
-- CHECK: dict size: "2"
-- CHECK: dict get nan: "b"
-- CHECK: dict zeros size: "1"
-- CHECK: set size: "2"
-- CHECK: set member nan: "True"
-- CHECK: maximum: "NaN"
-- CHECK: minimum: "NaN"
-- CHECK: max 1 nan: "NaN"
-- CHECK: max nan 1: "NaN"
-- CHECK: min 1 nan: "NaN"
-- CHECK: min nan 1: "NaN"
-- CHECK: max nan nan: "NaN"
-- CHECK: max -0 0: "+0"
-- CHECK: max 0 -0: "+0"
-- CHECK: min 0 -0: "-0"
-- CHECK: min -0 0: "-0"
-- CHECK: max 1 2: "2"
-- CHECK: min 1 2: "1"
-- CHECK: max inf 1: "Infinity"
-- CHECK: foldl max: "NaN"
-- CHECK: foldl max rev: "NaN"
-- CHECK: foldl min: "NaN"
-- CHECK: foldl min rev: "NaN"
-- CHECK: map2 max: "NaN,NaN,2"
-- CHECK: clamp nan: "NaN"
-- CHECK: clamp low nan: "NaN"
-- CHECK: clamp high nan: "NaN"
-- CHECK: clamp above: "1"
-- CHECK: clamp below: "+0"
-- CHECK: clamp inside: "0.5"
-- CHECK: round 2.5: "3"
-- CHECK: round -2.5: "-2"
-- CHECK: round -0.5: "0"
-- CHECK: round 0.5: "1"
-- CHECK: round -1.5: "-1"
-- CHECK: round nan: "0"
-- CHECK: floor nan: "0"
-- CHECK: ceiling nan: "0"
-- CHECK: truncate nan: "0"
-- CHECK: round inf: "9223372036854775807"
-- CHECK: round -inf: "-9223372036854775808"
-- CHECK: floor inf: "9223372036854775807"
-- CHECK: ceiling -inf: "-9223372036854775808"
-- CHECK: round 9.3e18: "9223372036854775807"
-- CHECK: truncate 3e10: "30000000000"
-- CHECK: truncate 1e20: "9223372036854775807"
-- CHECK: truncate -1e20: "-9223372036854775808"
-- CHECK: truncate -2.9: "-2"
-- CHECK: floor -0.5: "-1"
-- CHECK: ceiling -0.5: "0"
-- CHECK: map truncate: "0,9223372036854775807,-9223372036854775808,30000000000"
-- CHECK: map round: "0,-2,3"
-- CHECK: map floor: "0,-1"
-- CHECK: map ceiling: "0,0"

import Dict
import Html exposing (text)
import Set


nan : Float
nan =
    0 / 0


inf : Float
inf =
    1 / 0


one : Float
one =
    1


negZero : Float
negZero =
    -0


{-| A Float as text, telling the zeros apart: `+0`, `-0`, `NaN`, `Infinity`, `-Infinity`, or
String.fromFloat.
-}
f : Float -> String
f x =
    if isNaN x then
        "NaN"

    else if x == 0 then
        if 1 / x > 0 then
            "+0"

        else
            "-0"

    else if isInfinite x then
        if x > 0 then
            "Infinity"

        else
            "-Infinity"

    else
        String.fromFloat x


b : Bool -> String
b x =
    if x then
        "True"

    else
        "False"


o : Order -> String
o x =
    case x of
        LT ->
            "LT"

        EQ ->
            "EQ"

        GT ->
            "GT"


{-| A case on `compare`, which eco rewrites into direct tests (EcoCompareCaseRewrite).
-}
orderName : Float -> Float -> String
orderName x y =
    case compare x y of
        LT ->
            "LT"

        EQ ->
            "EQ"

        GT ->
            "GT"


ints : List Int -> String
ints xs =
    String.join "," (List.map String.fromInt xs)


floats : List Float -> String
floats xs =
    String.join "," (List.map f xs)


rows : List ( String, String )
rows =
    [ ( "lit nan < 1", b (nan < 1) )
    , ( "lit nan <= 1", b (nan <= 1) )
    , ( "lit nan > 1", b (nan > 1) )
    , ( "lit nan >= 1", b (nan >= 1) )
    , ( "lit 1 > nan", b (1 > nan) )
    , ( "lit nan == 1", b (nan == 1) )
    , ( "lit nan /= 1", b (nan /= 1) )
    , ( "var nan < one", b (nan < one) )
    , ( "var nan <= one", b (nan <= one) )
    , ( "var nan > one", b (nan > one) )
    , ( "var nan >= one", b (nan >= one) )
    , ( "var one > nan", b (one > nan) )
    , ( "var one >= nan", b (one >= nan) )
    , ( "var nan > nan", b (nan > nan) )
    , ( "var nan >= nan", b (nan >= nan) )
    , ( "var nan == nan", b (nan == nan) )
    , ( "var nan /= nan", b (nan /= nan) )
    , ( "compare nan 1", o (compare nan 1) )
    , ( "compare 1 nan", o (compare 1 nan) )
    , ( "compare nan nan", o (compare nan nan) )
    , ( "compare inf nan", o (compare inf nan) )
    , ( "compare nan -inf", o (compare nan -inf) )
    , ( "compare -0 0", o (compare negZero 0) )
    , ( "compare 0 -0", o (compare 0 negZero) )
    , ( "compare 1 2", o (compare 1 2) )
    , ( "case compare nan 1", orderName nan 1 )
    , ( "case compare 1 nan", orderName 1 nan )
    , ( "case compare nan nan", orderName nan nan )
    , ( "case compare -0 0", orderName negZero 0 )
    , ( "map2 compare", String.join "," (List.map o (List.map2 compare [ nan, 1, nan ] [ 1, nan, nan ])) )
    , ( "compare tuple nan", o (compare ( nan, 1 ) ( 1, 1 )) )
    , ( "compare tuple second nan", o (compare ( 1, nan ) ( 1, 2 )) )
    , ( "compare list nan", o (compare [ 1 ] [ nan ]) )
    , ( "tuple nan lt", b (( nan, 1 ) < ( 1, 1 )) )
    , ( "list nan gt", b ([ nan ] > [ 1 ]) )
    , ( "tuple nan eq", b (( nan, 0 ) == ( nan, 0 )) )
    , ( "sort", floats (List.sort [ 3, nan, 1, nan, 2 ]) )
    , ( "sortBy", floats (List.sortBy identity [ 3, nan, 1, nan, 2 ]) )
    , ( "dict size", String.fromInt (Dict.size (Dict.fromList [ ( nan, "a" ), ( nan, "b" ), ( 1, "c" ) ])) )
    , ( "dict get nan", Maybe.withDefault "none" (Dict.get nan (Dict.fromList [ ( nan, "a" ), ( nan, "b" ), ( 1, "c" ) ])) )
    , ( "dict zeros size", String.fromInt (Dict.size (Dict.fromList [ ( 0, "a" ), ( negZero, "b" ) ])) )
    , ( "set size", String.fromInt (Set.size (Set.fromList [ nan, nan, 1 ])) )
    , ( "set member nan", b (Set.member nan (Set.fromList [ nan, 1 ])) )
    , ( "maximum", Maybe.withDefault "none" (Maybe.map f (List.maximum [ 1, nan, 3 ])) )
    , ( "minimum", Maybe.withDefault "none" (Maybe.map f (List.minimum [ 1, nan, 3 ])) )
    , ( "max 1 nan", f (max 1 nan) )
    , ( "max nan 1", f (max nan 1) )
    , ( "min 1 nan", f (min 1 nan) )
    , ( "min nan 1", f (min nan 1) )
    , ( "max nan nan", f (max nan nan) )
    , ( "max -0 0", f (max negZero 0) )
    , ( "max 0 -0", f (max 0 negZero) )
    , ( "min 0 -0", f (min 0 negZero) )
    , ( "min -0 0", f (min negZero 0) )
    , ( "max 1 2", f (max 1 2) )
    , ( "min 1 2", f (min 1 2) )
    , ( "max inf 1", f (max inf 1) )
    , ( "foldl max", f (List.foldl max nan [ 1 ]) )
    , ( "foldl max rev", f (List.foldl max 1 [ nan ]) )
    , ( "foldl min", f (List.foldl min nan [ 1 ]) )
    , ( "foldl min rev", f (List.foldl min 1 [ nan ]) )
    , ( "map2 max", floats (List.map2 max [ 1, nan, 2 ] [ nan, 1, 1 ]) )
    , ( "clamp nan", f (clamp 0 1 nan) )
    , ( "clamp low nan", f (clamp nan 1 0.5) )
    , ( "clamp high nan", f (clamp 0 nan 0.5) )
    , ( "clamp above", f (clamp 0 1 2) )
    , ( "clamp below", f (clamp 0 1 -1) )
    , ( "clamp inside", f (clamp 0 1 0.5) )
    , ( "round 2.5", String.fromInt (round 2.5) )
    , ( "round -2.5", String.fromInt (round -2.5) )
    , ( "round -0.5", String.fromInt (round -0.5) )
    , ( "round 0.5", String.fromInt (round 0.5) )
    , ( "round -1.5", String.fromInt (round -1.5) )
    , ( "round nan", String.fromInt (round nan) )
    , ( "floor nan", String.fromInt (floor nan) )
    , ( "ceiling nan", String.fromInt (ceiling nan) )
    , ( "truncate nan", String.fromInt (truncate nan) )
    , ( "round inf", String.fromInt (round inf) )
    , ( "round -inf", String.fromInt (round -inf) )
    , ( "floor inf", String.fromInt (floor inf) )
    , ( "ceiling -inf", String.fromInt (ceiling -inf) )
    , ( "round 9.3e18", String.fromInt (round 9.3e18) )
    , ( "truncate 3e10", String.fromInt (truncate 3.0e10) )
    , ( "truncate 1e20", String.fromInt (truncate 1.0e20) )
    , ( "truncate -1e20", String.fromInt (truncate -1.0e20) )
    , ( "truncate -2.9", String.fromInt (truncate -2.9) )
    , ( "floor -0.5", String.fromInt (floor -0.5) )
    , ( "ceiling -0.5", String.fromInt (ceiling -0.5) )
    , ( "map truncate", ints (List.map truncate [ nan, 1.0e20, -1.0e20, 3.0e10 ]) )
    , ( "map round", ints (List.map round [ nan, -2.5, 2.5 ]) )
    , ( "map floor", ints (List.map floor [ nan, -0.5 ]) )
    , ( "map ceiling", ints (List.map ceiling [ nan, -0.5 ]) )
    ]


main =
    let
        _ =
            List.foldl (\( label, value ) () -> always () (Debug.log label value)) () rows
    in
    text "done"
