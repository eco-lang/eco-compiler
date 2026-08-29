module LssGapKernelPipeline exposing (main)

{-| Lever-4 P0 probe (plans/lss-coverage-four-levers.md §7.5): WHERE does the
payload-arrow transport chain die for kernel-backed combinators?

Three rungs, each one hop further from the callback:

  (A) `direct`  — Json.Decode.map applied HERE with a known ctor callback;
      the licensed call-site transport (type-sharing through `value`) should
      cover the local demand's payload arrow.
  (B) `viaDef`  — `decodePair : Decoder (Int -> Pair)` — a def whose
      ANNOTATION carries a syntactic payload arrow and whose BODY computes the
      member via the kernel combinator. Its signature ordinal EXISTS
      (loadTypeC slots nested arrows); the question is whether the body walk's
      member reaches the scratch slot (the recorded "A.1 inference-side arg
      leak" says translation-side transport does not feed signatures).
  (C) `consumer` — another def consuming decodePair's payload one hop away;
      covered iff (B)'s signature published the fact.

Read with ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1, grep '^pos|'.
-}

-- CHECK: kernelPipeline: 9

import Html exposing (text)
import Json.Decode as D


type Pair
    = Pair Int Int


pairValue : Pair -> Int
pairValue (Pair a b) =
    a + b


decodePair : D.Decoder (Int -> Pair)
decodePair =
    D.map Pair (D.field "a" D.int)


consume : D.Decoder (Int -> Pair) -> String -> Int
consume dec _ =
    case D.decodeString (D.map (\f -> pairValue (f 2)) dec) "{\"a\":7}" of
        Ok n ->
            n

        Err _ ->
            0


main =
    let
        _ =
            Debug.log "kernelPipeline" (consume decodePair "unused")
    in
    text "hello"
