module InlineVarCollisionTest exposing (main)

{-| Test for variable name shadowing after MonoInlineSimplify inlines a function
whose internal destructured variable name matches a variable in the enclosing scope.

This mirrors the bug in Compiler_Monomorphize_Specialize_specializePath:
  TOpt.Index index hint subPath ->
    let resultType = computeIndexProjectionType ... (Index.toMachine index) ...
    in  Mono.MonoIndex (Index.toMachine index) ...

Index.toMachine is: toMachine (ZeroBased index) = index
After inlining the first call, the destructured name "index" overwrites the
outer "index" variable mapping. When the second call tries to pass "index"
as its argument, it gets the i64 result instead of the !eco.value wrapper.
-}

-- CHECK: result: 84

import Html exposing (text)


type Wrapped
    = Wrapped Int


{-| Simple destructuring function whose internal binding name matches the
parameter name of the enclosing call site's variable. The destructured
name "n" will shadow the outer "n" after inlining.
-}
extract : Wrapped -> Int
extract (Wrapped n) =
    n


{-| Helper that takes an Int argument to force the first extract to be evaluated. -}
helper : Int -> Int -> Int
helper a b =
    a + b


{-| This function has a parameter named `n` and calls extract(n) twice.
After inlining extract, the internal destructured binding "n" (from
`Wrapped n`) overwrites the outer "n" mapping in varMappings.

Flow:
  1. `n` (outer, type Wrapped) → mapped to %X (!eco.value)
  2. First `extract n` inlines: destructures `n` → overrides mapping to %Y (i64)
  3. `helper (extract n) 0` evaluates fine with %Y
  4. Second `extract n`: argument `n` resolves to %Y (i64, WRONG!)
     Should resolve to %X (!eco.value)
-}
useTwice : Wrapped -> Int
useTwice n =
    helper (extract n) (extract n)


main =
    let
        w =
            Wrapped 42

        _ =
            Debug.log "result" (useTwice w)
    in
    text "done"
