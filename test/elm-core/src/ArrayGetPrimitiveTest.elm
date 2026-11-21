module ArrayGetPrimitiveTest exposing (main)

{-| `Array.get` and `Array.length` on arrays of `Int`, `Float`, `Char`, `String`
and functions, built by `fromList`, `initialize`, `repeat`, `push`, `set`,
`append` and `slice`, at an index in the tail (below 32), at index 35 (in a
tree leaf, past the first 32 elements) and out of range.

## eco

`Array.get` calls the `Elm.JsArray.unsafeGet` alias, which compiles to an inline
`eco.array.get` (plans/constructor-representation-followups.md F5b): a plain
load of the raw slot for a primitive element, sound because a primitive
`JsArray` is always of its primitive kind (HEAP_046). An `Array (Int -> Int)`
keeps its ordinary path (its result is a function).

-}

-- CHECK: ints: [Just 5,Just 35,Just 99,Nothing,Nothing]
-- CHECK: intLength: 100
-- CHECK: floats: [Just 2.5,Just 17.5,Nothing]
-- CHECK: chars: [Just 'b',Just 'z',Nothing]
-- CHECK: strings: [Just "s3",Just "s35",Nothing]
-- CHECK: pushed: [Just 40,Just 41]
-- CHECK: setGet: [Just 1000,Just 36,Just 2000]
-- CHECK: appended: [Just 1,Just 34,Just 104]
-- CHECK: sliced: [Just 10,Just 45,Nothing]
-- CHECK: repeated: [Just 7,Just 7]
-- CHECK: functions: [Just 6,Just 41,Nothing]

import Array exposing (Array)
import Html exposing (text)


gets : List Int -> Array a -> List (Maybe a)
gets indices arr =
    List.map (\i -> Array.get i arr) indices


main =
    let
        ints =
            Array.initialize 100 identity

        floats =
            Array.fromList (List.map (\i -> toFloat i / 2) (List.range 0 40))

        chars =
            Array.fromList (String.toList "abcdefghijklmnopqrstuvwxyzzzzzzzzzzzzzzzz")

        strings =
            Array.initialize 40 (\i -> "s" ++ String.fromInt i)

        pushed =
            List.foldl Array.push Array.empty (List.range 0 41)

        setArr =
            ints |> Array.set 0 1000 |> Array.set 99 2000

        appended =
            Array.append (Array.fromList (List.range 1 34)) (Array.initialize 80 (\i -> i + 100))

        sliced =
            Array.slice 10 50 ints

        repeated =
            Array.repeat 40 7

        functions =
            Array.initialize 40 (\i -> \x -> x + i)

        applied =
            List.map (\i -> Array.get i functions |> Maybe.map (\f -> f 5)) [ 1, 36, 40 ]

        _ =
            Debug.log "ints" (gets [ 5, 35, 99, 100, -1 ] ints)

        _ =
            Debug.log "intLength" (Array.length ints)

        _ =
            Debug.log "floats" (gets [ 5, 35, 41 ] floats)

        _ =
            Debug.log "chars" (gets [ 1, 35, 41 ] chars)

        _ =
            Debug.log "strings" (gets [ 3, 35, 40 ] strings)

        _ =
            Debug.log "pushed" (gets [ 40, 41 ] pushed)

        _ =
            Debug.log "setGet" (gets [ 0, 36, 99 ] setArr)

        _ =
            Debug.log "appended" (gets [ 0, 33, 38 ] appended)

        _ =
            Debug.log "sliced" (gets [ 0, 35, 40 ] sliced)

        _ =
            Debug.log "repeated" (gets [ 0, 35 ] repeated)

        _ =
            Debug.log "functions" applied
    in
    text "done"
