module TypeVarNameCollisionTest exposing (main)

{-| Guard for a fixed type-variable name collision in the solver's node types.

`Compiler.Type.Type.toCanTypeBatch` used to name node-type variables without
counting the names `toAnnotation` had already given the variables of the
top-level annotations, so in `pair x = let h y = y in ...` both `x`'s type and
the let-polymorphic `h`'s own type variable came out named `a`, and
monomorphization, which identifies type variables by name within a
definition, could take one for the other. The elm-test
`TestLogic.Type.NodeTypeVarNamesDistinctTest` pins the naming and its effect
on each engine.

Each function below instantiates the outer variable at one type and uses the
let-polymorphic helper at another, with a different runtime representation.
The program printed the right values with either engine even before the fix
(the inliners and the build's scheme roots kept the collision from reaching
the generated code); it stays as a guard.

-}

-- CHECK: floatInt: (2.5, 1)
-- CHECK: stringInt: ("s", 7)
-- CHECK: listChar: ([1.5], ['c'])
-- CHECK: twice: (3.5, (10, 10))
-- CHECK: numPair: (5, 6)
-- CHECK: capture: (("s", 1), ("s", 2.5))
-- CHECK: maxPair: (3.5, 9)
-- CHECK: showBoth: ("x!", "7")
-- CHECK: captureUse: ("s!", 2)
-- CHECK: captureFirst: "s?"
-- CHECK: captureMap: [("s", 1), ("s", 2)]
-- CHECK: captureMapUse: ["s1", "s2"]
-- CHECK: wrapInt: (2.5, 0)
-- CHECK: captureMapFirst: "ss"
-- CHECK: captureMapSecond: 3
-- CHECK: applyRun: ("s", 3)

import Html exposing (text)


pair x =
    let
        h y =
            y
    in
    ( h x, h 1 )


pairSeven x =
    let
        h y =
            y
    in
    ( h x, h 7 )


wrapBoth x =
    let
        wrap y =
            [ y ]
    in
    ( wrap x, wrap 'c' )


twice x =
    let
        dup y =
            ( y, y )
    in
    ( x, dup 10 |> Tuple.mapFirst identity )


numPair x =
    let
        h y =
            y * 2
    in
    ( h x, h 3 )


capture x =
    let
        h y =
            ( x, y )
    in
    ( h 1, h 2.5 )


maxPair x =
    let
        biggest y z =
            max y z
    in
    ( biggest x 1.5, biggest 9 4 )


showBoth x =
    let
        render y =
            Debug.toString y
    in
    ( x ++ "!", render 7 )


captureUse x =
    let
        h y =
            ( x, y )

        ( p, q ) =
            h 1
    in
    ( p ++ "!", q + 1 )


captureFirst x =
    let
        h y =
            ( x, y )
    in
    Tuple.first (h 1) ++ "?"


captureMap x =
    let
        h y =
            ( x, y )
    in
    List.map h [ 1, 2 ]


captureMapUse x =
    let
        h y =
            ( x, y )
    in
    List.map h [ 1, 2 ]
        |> List.map (\( p, q ) -> p ++ String.fromInt q)


captureMapFirst x =
    let
        h y =
            ( x, y )
    in
    List.map h [ 1, 2 ] |> List.map Tuple.first |> String.concat


captureMapSecond x =
    let
        h y =
            ( x, y )
    in
    List.map h [ 1, 2 ] |> List.map Tuple.second |> List.sum


applyRun x =
    let
        h y =
            ( x, y )

        run f =
            f 3
    in
    run h


{-| `h`'s own variable and `x`'s are both `number`s, which the collision gave
the same name `number`. `x` is a Float and `h` is used at Int, where
2^32 * 2^32 = 2^64 wraps to 0; computed as a Float it would be
1.8446744073709552e19. (A chain such as `y * 2147483648 * 2147483648` is not
used: with `ECO_MONO_ENGINE=subst` and alias forwarding on, an unannotated
`number` definition with a chained literal multiplication crashes the
compiler for a reason unrelated to the collision.)
-}
wrapInt x =
    let
        h y =
            y * y
    in
    ( x * 1, h 4294967296 )


main =
    let
        _ =
            Debug.log "floatInt" (pair 2.5)

        _ =
            Debug.log "stringInt" (pairSeven "s")

        _ =
            Debug.log "listChar" (wrapBoth 1.5)

        _ =
            Debug.log "twice" (twice 3.5)

        _ =
            Debug.log "numPair" (numPair 2.5)

        _ =
            Debug.log "capture" (capture "s")

        _ =
            Debug.log "maxPair" (maxPair 3.5)

        _ =
            Debug.log "showBoth" (showBoth "x")

        _ =
            Debug.log "captureUse" (captureUse "s")

        _ =
            Debug.log "captureFirst" (captureFirst "s")

        _ =
            Debug.log "captureMap" (captureMap "s")

        _ =
            Debug.log "captureMapUse" (captureMapUse "s")

        _ =
            Debug.log "wrapInt" (wrapInt 2.5)

        _ =
            Debug.log "captureMapFirst" (captureMapFirst "s")

        _ =
            Debug.log "captureMapSecond" (captureMapSecond "s")

        _ =
            Debug.log "applyRun" (applyRun "s")
    in
    text "done"
