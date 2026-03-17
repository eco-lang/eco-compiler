module CharCasePredicateTest exposing (main)

{-| FAILING TEST: arith.cmpi missing predicate attribute for i16 (Char) comparisons.

Bug: When the pattern compiler generates equality tests for Char patterns (IsChr),
it calls Ops.ecoBinaryOp which only sets _operand_types but NOT the required
predicate attribute. The correct function to use is Ops.arithCmpI which sets both.

i32 comparisons (Int) work correctly because they use eco.int.eq (an eco dialect op).
i16 comparisons (Char) incorrectly use raw arith.cmpi without the predicate attribute.

NOTE: This bug only manifests in Stage 6 (eco-boot-native MLIR parsing/verification).
The JIT test infrastructure may not catch it because it handles the missing predicate
differently. The elm-test CmpiPredicateAttrTest catches it at the MLIR generation level.

See: compiler/src/Compiler/Generate/MLIR/Patterns.elm line 205
-}

-- CHECK: result: "comma"

import Html exposing (text)


classify : Char -> String
classify c =
    case c of
        ',' ->
            "comma"

        '{' ->
            "open brace"

        '\\' ->
            "backslash"

        _ ->
            "other"


main =
    let
        result = classify ','
        _ = Debug.log "result" result
    in
    text result
