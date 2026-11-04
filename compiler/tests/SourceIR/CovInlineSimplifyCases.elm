module SourceIR.CovInlineSimplifyCases exposing (expectSuite)

{-| Programs written so that the post-monomorphization inliner,
`Compiler.MonoOpt.InlineSimplify`, meets the shapes its rewrites look for:
loopification of tail-recursive functions that take a function argument, the
forwarding of a `let`-bound closure to its one use, aliases of globals and
kernels, dead `let`s of several kinds, renaming inside an inlined body that
reuses a parameter name, and a function with more inlinable calls than its
inline budget allows.

These cases assert nothing themselves. Each one parses a program from source
text and hands it to the expectation function the caller supplies, so what is
checked, and at which stage, is decided by that function.

The programs are parsed as modules of elm/core (`Parse.Package Pkg.core`), so
they get no default imports and may name `Elm.Kernel.*` functions; every
import is written out in `header`. They compile against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`. Each defines `testValue`.

The cases, by label:

  - "Loopify through record, tuple and list bodies": tail-recursive functions
    taking a function parameter, each called once with a lambda that captures
    a local, whose bodies update a record, build a record, and build a tuple
    holding a list and a call of another function.
  - "Forward let-bound closures to their one use": `let`-bound lambdas, each
    used once as a callee inside an `if`, a `case` branch, a list, a record
    update, a tuple, a later `let`, a record access and, in a tail-recursive
    function, a tail call's argument.
  - "Aliases of globals and kernels": top-level values defined as another
    global or a kernel, a chain of six such aliases, and calls through them.
  - "Dead lets of every kind": unused `let`s bound to an accessor, a record
    update, a `case` with a shared branch, a `case` over three constructors, a
    kernel and a kernel call.
  - "More inlinable calls than the inline budget": a list of 1005 calls of a
    small function, beyond the 1000 inlines allowed in one function.
  - "Loopify small functions with one body form each": tail-recursive
    functions taking a function parameter whose bodies build a tuple or a list,
    `case` over a custom type or with a shared branch, bind a `let`, define a
    local tail function, build a lambda, call a second function parameter,
    return unit, or pass a different function in the recursive call; most are
    called with a lambda, one with a global.
  - "Dead lets bound to calls": unused `let`s bound to a call of a top-level
    function and of a kernel.
  - "Loopify with a closure, a local tail function, or no literal argument":
    a tail-recursive function that defines a local tail function, and calls
    that pass a parameter instead of a lambda.
  - "Forward let-bound closures into later branches and fallbacks": `let`-bound
    lambdas used once in the second branch of an `if`, the shared fallback of
    a `case` on a `Maybe Int`, the default branch of a `case` over four
    constructors, the body of a later local tail function's `let`, and one
    branch of a four-way `case`.
  - "Forward past a unit and a kernel value": `let`-bound lambdas used once in
    tuples whose first element is unit or `pi`.
  - "Inline into bodies that reuse a parameter name in a lambda or local
    function": functions whose parameter name reappears as a lambda or local
    function parameter after inlining, and a lambda applied directly whose body
    binds a `let` and matches a `Maybe Int`.
  - "Accessor of a function field passed in a tail call": the accessor `.fn`
    of a function field passed as a tail-call argument (finding F8).
  - "Loopify a function that returns a lambda": a tail-recursive function
    with a function parameter whose base case returns a lambda, loopified at
    its one call, whose evaluator return type was once peeled one stage too
    far (finding F12, fixed).

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Inline simplify coverage " followed by `condStr`,
that passes when `expectFn` passes on every case's program and otherwise fails
with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Inline simplify coverage " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of `programs`, in order.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, body ) -> { label = label, run = \_ -> runSource expectFn body })
        programs


{-| Runs `expectFn` on the module parsed from `header` followed by `body`, or
fails when that source does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn body =
    case Parse.fromByteString (Parse.Package Pkg.core) (header ++ body) of
        Ok modul ->
            expectFn modul

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ body)


{-| The module header shared by the programs: module `Test` and the imports
they use, all written out because an elm/core module gets no default imports.
-}
header : String
header =
    """module Test exposing (..)

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple

"""


{-| The programs, by label, as the source that follows `header`.
-}
programs : List ( String, String )
programs =
    [ ( "Loopify through record, tuple and list bodies"
      , """
recLoop : (Int -> Int) -> Int -> { s : Int, t : Int } -> { s : Int, t : Int }
recLoop f n r =
    if n <= 0 then
        r

    else
        recLoop f (n - 1) { r | s = f r.s }


createLoop : (Int -> Int) -> Int -> { s : Int } -> { s : Int }
createLoop f n r =
    if n <= 0 then
        r

    else
        createLoop f (n - 1) { s = f r.s }


tupLoop : (Int -> Int) -> Int -> ( Int, List Int ) -> ( Int, List Int )
tupLoop f n ( a, xs ) =
    if n <= 0 then
        ( a, xs )

    else
        tupLoop f (n - 1) ( f a, [ a, max a n ] )


testValue k =
    ( recLoop (\\x -> x + k) 3 { s = 0, t = 1 }
    , createLoop (\\x -> x * k) 3 { s = 1 }
    , tupLoop (\\x -> x - k) 3 ( 0, [] )
    )
"""
      )
    , ( "Forward let-bound closures to their one use"
      , """
loop : Int -> Int -> Int -> Int
loop n acc k =
    let
        f =
            \\x -> x + k
    in
    if n <= 0 then
        acc

    else
        loop (n - 1) (f acc) k


testValue k xs r =
    let
        f1 =
            \\x -> x + k

        f2 =
            \\x -> x * k

        f3 =
            \\x -> x - k

        f4 =
            \\x -> x + 2 * k

        f5 =
            \\x -> x + 3 * k

        f6 =
            \\x -> x + 4 * k

        f7 =
            \\x -> x + 5 * k

        y =
            List.length xs
    in
    { a =
        if y > 0 then
            f1 y

        else
            0
    , b =
        case xs of
            [] ->
                0

            h :: _ ->
                f2 h
    , c = [ 1, f3 y ]
    , d = { r | s = f4 y }
    , e = ( f5 y, y )
    , g =
        let
            z =
                y + 1
        in
        f6 z
    , h = (f7 y |> (\\v -> { s = v })).s
    , i = loop 3 0 k
    }
"""
      )
    , ( "Aliases of globals and kernels"
      , """
myAdd =
    Elm.Kernel.Basics.add


alias1 =
    myAdd


alias2 =
    alias1


alias3 =
    alias2


alias4 =
    alias3


alias5 =
    alias4


alias6 =
    alias5


double : Int -> Int
double x =
    x * 2


dbl =
    double


countDown : Int -> Int -> Int
countDown n acc =
    if n <= 0 then
        acc

    else
        countDown (n - 1) (acc + 1)


cd =
    countDown


cd2 =
    cd


testValue k =
    [ myAdd k 1, alias1 k 2, alias3 k 3, alias6 k 4, dbl k, cd k 0, cd2 k 1 ]
"""
      )
    , ( "Dead lets of every kind"
      , """
type T
    = A
    | B
    | C


testValue r m t =
    let
        a =
            .x

        b =
            { r | x = 1 }

        c =
            case m of
                Just 1 ->
                    1

                Just 2 ->
                    1

                _ ->
                    2

        d =
            case t of
                A ->
                    1

                B ->
                    2

                C ->
                    3

        e =
            Elm.Kernel.Basics.add

        g =
            Elm.Kernel.Basics.add 1 2
    in
    r.x
"""
      )
    , ( "More inlinable calls than the inline budget"
      , """
inc : Int -> Int
inc x =
    x + 1


testValue =
    [ """
            ++ String.join "\n    , " (List.map (\i -> "inc " ++ String.fromInt i) (List.range 0 1004))
            ++ """
    ]
"""
      )
    , ( "Loopify small functions with one body form each"
      , """
type T
    = A
    | B Int
    | C


tl : (Int -> Int) -> Int -> ( Int, Int ) -> ( Int, Int )
tl f n p =
    if n <= 0 then
        p

    else
        tl f (n - 1) ( f n, n )


ll : (Int -> Int) -> Int -> List Int -> List Int
ll f n xs =
    if n <= 0 then
        xs

    else
        ll f (n - 1) [ f n ]


cl : (Int -> Int) -> Int -> T -> Int
cl f n t =
    case t of
        A ->
            cl f (n - 1) (B n)

        B k ->
            f k

        C ->
            0


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


lam : (Int -> Int) -> Int -> List Int -> List Int
lam f n acc =
    if n <= 0 then
        List.map (\\x -> x + 1) acc

    else
        lam f (n - 1) (f n :: acc)


lg : (Int -> Int) -> (Int -> Int) -> Int -> Int -> Int
lg f g n acc =
    if n <= 0 then
        acc

    else
        lg f g (n - 1) (f (g acc))


ul : (Int -> Int) -> Int -> ()
ul f n =
    if f n > 0 then
        ()

    else
        ul f (n - 1)


swap : (Int -> Int) -> Int -> Int
swap f n =
    if n <= 0 then
        f 0

    else
        swap negate (n - 1)


testValue k j =
    { a = tl (\\x -> x + k) 3 ( 0, 0 )
    , b = ll (\\x -> x * k) 3 []
    , c = cl (\\x -> x - k) 3 A
    , d = jl (\\x -> x + k) 3 Nothing
    , e = lt (\\x -> x + k) 3 0
    , g = ltd (\\x -> x + k) 3 0
    , h = lam (\\x -> x + k) 3 []
    , i = lg (\\x -> x + k + j) negate 3 0
    , l = ul (\\x -> x - k) 3
    , m = swap (\\x -> x + k) 3
    , n = tl negate 3 ( 1, 1 )
    }
"""
      )
    , ( "Dead lets bound to calls"
      , """
double : Int -> Int
double x =
    if x > 100 then
        x

    else
        x * 2


testValue k =
    let
        unused =
            double k

        unusedKernel =
            Elm.Kernel.Basics.mul k 2
    in
    k + 1
"""
      )
    , ( "Loopify with a closure, a local tail function, or no literal argument"
      , """
ltd : (Int -> Int) -> Int -> Int
ltd f n =
    let
        go k =
            if k then
                0

            else
                go True
    in
    if n <= 0 then
        go False

    else
        ltd f (f n)


tl : (Int -> Int) -> Int -> Int -> Int
tl f n acc =
    if n <= 0 then
        acc

    else
        tl f (n - 1) (f acc)


two : (Int -> Int) -> (Int -> Int) -> Int -> Int -> Int
two f g n acc =
    if n <= 0 then
        acc

    else
        two f g (n - 1) (f (g acc))


testValue k j h =
    ( ltd (\\x -> x - k) 3
    , ( tl h 3 0, two (\\x -> x + k + j) h 3 0 )
    )
"""
      )
    , ( "Forward let-bound closures into later branches and fallbacks"
      , """
type T
    = A
    | B
    | C
    | D


testValue k a b m t y =
    let
        f1 =
            \\x -> x + k

        f2 =
            \\x -> x * k

        f3 =
            \\x -> x - k

        f4 =
            \\x -> x + 2 * k

        f5 =
            \\x -> x + 3 * k
    in
    { elseIf =
        if a then
            0

        else if b then
            f1 y

        else
            2
    , jump =
        case m of
            Just 1 ->
                0

            Just 2 ->
                1

            _ ->
                f2 3
    , fallback =
        case t of
            A ->
                0

            B ->
                1

            _ ->
                f3 2
    , afterTailDef =
        let
            go n =
                if n <= 0 then
                    0

                else
                    go (n - 1)
        in
        f4 (go y)
    , notFound =
        case t of
            A ->
                f5 0

            B ->
                1

            C ->
                2

            D ->
                3
    }
"""
      )
    , ( "Forward past a unit and a kernel value"
      , """
testValue k y =
    let
        f1 =
            \\x -> x + k

        f2 =
            \\x -> x * k
    in
    ( ( (), f1 y ), ( pi, f2 y ) )
"""
      )
    , ( "Inline into bodies that reuse a parameter name in a lambda or local function"
      , """
g : Int -> List Int -> List Int
g y xs =
    List.map (\\x -> x + y) xs


f : Int -> List Int -> List Int
f x xs =
    g x xs


h : Int -> Int
h y =
    let
        go x =
            if x <= 0 then
                y

            else
                go (x - 1)
    in
    go 3


f2 : Int -> Int
f2 x =
    h x + 1


testValue k xs =
    ( f k xs, f2 k, (\\t -> let z = k * 2 in case t of
                                                Just 1 -> z
                                                Just 2 -> 1
                                                _ -> z + 2) (Just k) )
"""
      )
    , accessorInTailCallProgram
    , ( "Loopify a function that returns a lambda"
      , """
lam : (Int -> Int) -> Int -> Int -> (Int -> Int)
lam f n acc =
    if n <= 0 then
        \\x -> x + acc

    else
        lam f (n - 1) (f acc)


testValue k =
    lam (\\x -> x + k) 3 0
"""
      )
    ]


{-| A program that passes the accessor `.fn`, whose field is a function, as a
tail-call argument. `Compiler.Monomorphize.ResolveAccessorValues` replaces the
accessor value by a closure typed from the parameter it is passed to; before
finding F8 was fixed it was left as it was and crashed MLIR generation.
-}
accessorInTailCallProgram : ( String, String )
accessorInTailCallProgram =
    ( "Accessor of a function field passed in a tail call"
    , """
pick : Int -> ({ fn : Int -> Int } -> (Int -> Int)) -> { fn : Int -> Int } -> Int
pick n g r =
    if n <= 0 then
        (g r) 1

    else
        pick (n - 1) .fn r


testValue k =
    pick 3 (\\r -> r.fn) { fn = \\x -> x + k }
"""
    )
