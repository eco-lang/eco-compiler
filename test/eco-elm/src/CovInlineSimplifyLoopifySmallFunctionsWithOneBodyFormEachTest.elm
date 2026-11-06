module CovInlineSimplifyLoopifySmallFunctionsWithOneBodyFormEachTest exposing (..)

{-| Small self tail-recursive functions, each taking a function argument and each with a different
body form: a tuple, list, mapped list or unit result; a `case` on a custom type or on a `Maybe`
with literal patterns; a `let` before the recursive call; a local loop called in the base case;
two composed function arguments; and `negate` passed in place of the function argument.

`testValue` takes arguments and is never applied, so the program logs it as `<function>`; the
test checks that these definitions compile and the program runs.

## eco

Taken from the program "Loopify small functions with one body form each" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


type T
    = A
    | B Int
    | C


testValue k j =
    { a = tl (\x -> x + k) 3 ( 0, 0 )
    , b = ll (\x -> x * k) 3 []
    , c = cl (\x -> x - k) 3 A
    , d = jl (\x -> x + k) 3 Nothing
    , e = lt (\x -> x + k) 3 0
    , g = ltd (\x -> x + k) 3 0
    , h = lam (\x -> x + k) 3 []
    , i = lg (\x -> x + k + j) negate 3 0
    , l = ul (\x -> x - k) 3
    , m = swap (\x -> x + k) 3
    , n = tl negate 3 ( 1, 1 )
    }


swap : (Int -> Int) -> Int -> Int
swap f n =
    if n <= 0 then
        f 0

    else
        swap negate (n - 1)


ul : (Int -> Int) -> Int -> ()
ul f n =
    if f n > 0 then
        ()

    else
        ul f (n - 1)


lg : (Int -> Int) -> (Int -> Int) -> Int -> Int -> Int
lg f g n acc =
    if n <= 0 then
        acc

    else
        lg f g (n - 1) (f (g acc))


lam : (Int -> Int) -> Int -> List Int -> List Int
lam f n acc =
    if n <= 0 then
        List.map (\x -> x + 1) acc

    else
        lam f (n - 1) (f n :: acc)


ltd : (Int -> Int) -> Int -> Int -> Int
ltd f n acc =
    let
        go k =
            if k <= 0 then
                acc

            else
                go (k - 1)
    in
    if n <= 0 then
        go 2

    else
        ltd f (n - 1) (f acc)


lt : (Int -> Int) -> Int -> Int -> Int
lt f n acc =
    if n <= 0 then
        acc

    else
        let
            y =
                f n
        in
        lt f (n - 1) (y * y + acc)


jl : (Int -> Int) -> Int -> Maybe Int -> Int
jl f n m =
    case m of
        Just 1 ->
            5

        Just 2 ->
            5

        Just 3 ->
            f n

        _ ->
            jl f (n - 1) (Just 3)


cl : (Int -> Int) -> Int -> T -> Int
cl f n t =
    case t of
        A ->
            cl f (n - 1) (B n)

        B k ->
            f k

        C ->
            0


ll : (Int -> Int) -> Int -> List Int -> List Int
ll f n xs =
    if n <= 0 then
        xs

    else
        ll f (n - 1) [ f n ]


tl : (Int -> Int) -> Int -> ( Int, Int ) -> ( Int, Int )
tl f n p =
    if n <= 0 then
        p

    else
        tl f (n - 1) ( f n, n )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
