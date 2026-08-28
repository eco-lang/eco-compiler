module LssGapCtorScale exposing (main)
{-| Scaling test for the constructor hypothesis: FOUR declared types with
constructors of increasing arity. If provenance loss scales with constructor
count/arity, synthesized constructor functions are the cause. -}
-- CHECK: ctorScale: 10
import Html exposing (text)
type A = A Int
type B = B Int Int
type C = C Int Int Int
type D = D Int Int Int Int
unA : A -> Int
unA (A x) = x
unB : B -> Int
unB (B x y) = x + y
unC : C -> Int
unC (C x y z) = x + y + z
unD : D -> Int
unD (D w x y z) = w + x + y + z
main =
    let _ = Debug.log "ctorScale" (unA (A 1) + unB (B 1 1) + unC (C 1 1 1) + unD (D 1 1 1 1))
    in text "hello"
