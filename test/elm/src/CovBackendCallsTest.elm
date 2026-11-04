module CovBackendCallsTest exposing (main)

{-| Coverage (backend, round 4): call forms and constant thunks that the
mock-interface SourceIR cases cannot express.

  - curried and partially applied local and global functions, called with
    more and fewer arguments than one stage takes;
  - functions read from records and lists and applied (generic dispatch);
  - kernel functions and operators passed as values;
  - top-level constants that alias a user enum or a nullary constructor
    (`ConstThunks.verdictOf` refuses them as `notThunk`), refer to themselves
    under a lambda (`cycle`), or are Char comparisons and conversions.

-}

-- CHECK: curried: 10
-- CHECK: partial: [6,7,8]
-- CHECK: stages: 60
-- CHECK: recfn: 9
-- CHECK: listfns: [2,2,9]
-- CHECK: kernelvals: [True,False]
-- CHECK: maxes: [3,3,5]
-- CHECK: repeats: ["aa","bb"]
-- CHECK: favorite: Green
-- CHECK: dot: Dot
-- CHECK: selfref: 2
-- CHECK: charcode: 97
-- CHECK: charlt: True
-- CHECK: charmix: 195

import Html exposing (text)


type Color
    = Red
    | Green


type Shape
    = Dot
    | Circle Float


favorite : Color
favorite =
    Green


dotShape : Shape
dotShape =
    Dot


selfRef : Int
selfRef =
    List.length [ \() -> selfRef, \() -> 1 ]


charCode : Int
charCode =
    Char.toCode 'a'


charLt : Bool
charLt =
    'a' < 'b'


charMix : Int
charMix =
    if 'x' > 'c' then
        Char.toCode 'a' + Char.toCode 'b'

    else
        0


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


curried : Int -> Int -> Int
curried n =
    \m -> n + m


stages : Int -> Int -> Int -> Int
stages a =
    \b ->
        \c -> a * 10 + b * 10 + c * 10


type alias Ops =
    { fn : Int -> Int, k : Int }


applyRec : Ops -> Int
applyRec ops =
    ops.fn ops.k


main =
    let
        _ =
            Debug.log "curried" (curried 3 7)

        inc5 =
            add3 2 3

        _ =
            Debug.log "partial" (List.map inc5 [ 1, 2, 3 ])

        _ =
            Debug.log "stages" (stages 1 2 3)

        _ =
            Debug.log "recfn" (applyRec { fn = \x -> x * 3, k = 3 })

        _ =
            Debug.log "listfns" (List.map (\f -> f 1) [ (+) 1, \x -> x * 2, curried 8 ])

        _ =
            Debug.log "kernelvals" (List.map2 (&&) [ True, True ] [ True, False ])

        _ =
            Debug.log "maxes" (List.map (max 3) [ 1, 2, 5 ])

        _ =
            Debug.log "repeats" (List.map (String.repeat 2) [ "a", "b" ])

        _ =
            Debug.log "favorite" favorite

        _ =
            Debug.log "dot" dotShape

        _ =
            Debug.log "selfref" selfRef

        _ =
            Debug.log "charcode" charCode

        _ =
            Debug.log "charlt" charLt

        _ =
            Debug.log "charmix" charMix
    in
    text "done"
