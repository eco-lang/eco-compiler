module KnownCtorCaseFoldTest exposing (main)

{-| A `case` on a value built by a constructor earlier in the same function picks its branch, and
the branch reads the constructor's arguments, with the same results as building the value and
matching on it.

  - `direct`: a two-field constructor bound by a `let` and matched at once.
  - `helper`: the value is built by one small function and matched by another, both inlined.
  - `literal`: the constructor's arguments are a literal and a top-level value.
  - `loop`: a tail-recursive loop that builds and matches a step value on each of 1,000,000
    iterations.
  - `enum`: a nullary constructor of a type whose other constructors have fields.
  - `kept`: the value is matched and also used after the `case`, so it is still built.
  - `boxed`: a constructor whose one field is a `String`.

## eco

Exercises `Compiler.MonoOpt.KnownCtorCase` (plans/constructor-representation-levels.md K1,
`ECO_KNOWN_CTOR_CASE`). The CHECK-MLIR-NOT lines assert that the folded sites build no value:
each of `KcPair`, `KcRect`, `KcLit` and `KcStep` is built only where the pass folds it, so no
`eco.construct.custom` names them. `KcKeep` is still built (`kept`), which a CHECK-MLIR line
asserts, since the fold must not drop a binding that is used after the `case`.

-}

-- CHECK: direct: 34
-- CHECK: helper: 4
-- CHECK: literal: 10
-- CHECK: loop: 500000500000
-- CHECK: enum: "none"
-- CHECK: kept: 9
-- CHECK: boxed: "eco!"
-- CHECK-MLIR-NOT: constructor = "KcPair"
-- CHECK-MLIR-NOT: constructor = "KcRect"
-- CHECK-MLIR-NOT: constructor = "KcLit"
-- CHECK-MLIR-NOT: constructor = "KcStep"
-- CHECK-MLIR: constructor = "KcKeep"

import Html exposing (text)


type Pair
    = KcPair Int Int
    | KcSingle Int
    | KcNoPair


type Shape
    = KcRect Int Int
    | KcCircle Int


type Lit
    = KcLit Int Int
    | KcOther


type Step
    = KcStep Int Int
    | KcDone Int


type Opt
    = KcNone
    | KcOne Int
    | KcTwo Int Int


type Keep
    = KcKeep Int Int
    | KcLost


type Label
    = KcBox String
    | KcEmpty


offset : Int
offset =
    7


direct : Int -> Int -> Int
direct a b =
    let
        p =
            KcPair a b
    in
    case p of
        KcPair x y ->
            x * 10 + y

        KcSingle x ->
            x

        KcNoPair ->
            0


mkShape : Int -> Int -> Shape
mkShape w h =
    KcRect w h


width : Shape -> Int
width s =
    case s of
        KcRect w _ ->
            w

        KcCircle r ->
            r


helper : Int -> Int -> Int
helper w h =
    width (mkShape w h)


literal : () -> Int
literal () =
    let
        l =
            KcLit 3 offset
    in
    case l of
        KcLit a b ->
            a + b

        KcOther ->
            0


loop : Int -> Int -> Int
loop n acc =
    let
        st =
            KcStep n acc
    in
    case st of
        KcStep i a ->
            if i == 0 then
                a

            else
                loop (i - 1) (a + i)

        KcDone a ->
            a


enum : Int -> String
enum n =
    let
        o =
            KcNone
    in
    case o of
        KcNone ->
            "none"

        KcOne x ->
            String.fromInt (x + n)

        KcTwo x y ->
            String.fromInt (x + y + n)


size : Keep -> Int
size k =
    case k of
        KcKeep a b ->
            a * b

        KcLost ->
            0


kept : Int -> Int -> Int
kept a b =
    let
        k =
            KcKeep a b
    in
    (case k of
        KcKeep x _ ->
            x

        KcLost ->
            0
    )
        + size k


boxed : String -> String
boxed s =
    let
        l =
            KcBox s
    in
    case l of
        KcBox t ->
            t ++ "!"

        KcEmpty ->
            ""


main =
    let
        _ =
            Debug.log "direct" (direct 3 4)

        _ =
            Debug.log "helper" (helper 4 3)

        _ =
            Debug.log "literal" (literal ())

        _ =
            Debug.log "loop" (loop 1000000 0)

        _ =
            Debug.log "enum" (enum 1)

        _ =
            Debug.log "kept" (kept 3 2)

        _ =
            Debug.log "boxed" (boxed "eco")
    in
    text "done"
