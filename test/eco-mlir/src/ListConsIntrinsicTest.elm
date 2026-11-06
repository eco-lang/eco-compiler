module ListConsIntrinsicTest exposing (main)

{-| The cons operator `::` builds lists of String, Int, Float and Char heads, and
works inside a `List.foldl` accumulator and when passed as a function value to
`List.foldr`.

  - `boxed`, `ints`, `floats`, `chars`: lists written as `x :: y :: [ z ]`,
    logged directly or through `List.sum` and `String.fromList`.
  - `viaFoldl`: `List.foldl (\x acc -> x :: acc) []` reverses `List.range 1 10`; the sum
    is 55.
  - `devirt`: `List.foldr (::) []` copies `List.range 1 5`; the sum is 15.
  - `mixedTail`: a cons onto the result of `List.filter` has length 3.

## eco

Exercises the cons intrinsic (plans/kernel-opt-01-list-cons-construct-list.md):
a saturated `x :: xs` lowers to `eco.construct.list` when
`ECO_LIST_CONS_INTRINSIC` is set (compiler/src/Builder/Eco/Config.elm), and to
an `Elm_Kernel_List_cons*` kernel call otherwise; behaviour must be identical
either way. The CHECK-MLIR line holds in both modes, since list literals
already emit `eco.construct.list`, so head-kind encoding is checked by
compiler/tests/Compiler/IR/Kernel/IntrinsicsListConsTest.elm rather than here.

The shapes cover each head kind (boxed String, Int, Float, Char), the
`foldl` accumulator loop that runtime/src/codegen/Passes/EcoListTemplate.cpp
rewrites to scratch chunks, and `(::)` passed as a function value, which
lambda-set specialization devirtualizes to a saturated kernel call that must
then become the intrinsic too.

-}

-- CHECK: boxed: ["a","b","c"]
-- CHECK: ints: 6
-- CHECK: floats: 6.5
-- CHECK: chars: "abc"
-- CHECK: viaFoldl: 55
-- CHECK: devirt: 15
-- CHECK: mixedTail: 3
-- CHECK-MLIR: eco.construct.list

import Html exposing (text)


{-| A list of String heads built with `::`.
-}
boxedHeads : List String
boxedHeads =
    "a" :: "b" :: [ "c" ]


{-| A list of Int heads built with `::`.
-}
intHeads : List Int
intHeads =
    1 :: 2 :: [ 3 ]


{-| A list of Float heads built with `::`.
-}
floatHeads : List Float
floatHeads =
    1.5 :: 2.0 :: [ 3.0 ]


{-| A list of Char heads built with `::`.
-}
charHeads : List Char
charHeads =
    'a' :: 'b' :: [ 'c' ]


{-| Reverses a list by consing each element onto a `List.foldl` accumulator.
-}
reverseViaFoldl : List Int -> List Int
reverseViaFoldl xs =
    List.foldl (\x acc -> x :: acc) [] xs


{-| Copies a list by passing `(::)` as a function value to `List.foldr`.
-}
viaDevirt : List Int -> List Int
viaDevirt xs =
    List.foldr (::) [] xs


{-| A cons whose tail is produced by a call rather than a literal.
-}
mixedTail : Int -> List Int
mixedTail n =
    n :: List.filter (\x -> x > 0) [ 1, 2 ]


main : Html.Html msg
main =
    let
        _ =
            Debug.log "boxed" boxedHeads

        _ =
            Debug.log "ints" (List.sum intHeads)

        _ =
            Debug.log "floats" (List.sum floatHeads)

        _ =
            Debug.log "chars" (String.fromList charHeads)

        _ =
            Debug.log "viaFoldl" (List.sum (reverseViaFoldl (List.range 1 10)))

        _ =
            Debug.log "devirt" (List.sum (viaDevirt (List.range 1 5)))

        _ =
            Debug.log "mixedTail" (List.length (mixedTail 7))
    in
    text "done"
