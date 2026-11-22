module Compiler.MonoOpt.MemberArityTest exposing (suite)

{-| Tests for `Compiler.MonoOpt.MemberArity.classify` and `setArity`, which
read what the lambda set at the head of a callee's type says about the arity of
the closure it holds.

Each test builds a function type with `Mono.mFunction`, putting the annotation
under test on its head arrow, and classifies it against a hand-made table of
member arities. No graph is built, so `memberArities` itself is not tested
here; the E2E tests in test/eco-mlir (StageHintLoopTest,
StageHintOverApplyTest) cover it through the census and the emitted hint.

The tests establish:

  - ⊤, a set variable and a lower bound are not complete sets, and give no
    arity.
  - A complete set whose members all take one argument agrees on 1, whichever
    of its members' entries say so.
  - Members whose arities differ disagree, and a member with several arities
    of its own disagrees with itself.
  - A member with no entry is unresolved (`none`), and so is one with an
    `Unknown` entry, which keeps its reason.
  - A kernel member takes as many arguments as the type has once flattened:
    2 on `Int -> Int -> Int`, given as two one-parameter stages. Next to a
    member that takes 1 it disagrees.
  - An empty set is `SetEmpty`, and `setArity` gives nothing for it or for an
    agreed arity of 0.

-}

import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.MemberArity as MemberArity exposing (MemberArity(..), SetClass(..))
import Dict exposing (Dict)
import Expect
import Set
import Test exposing (Test, describe, test)


{-| `Int -> Int -> Int` as two one-parameter stages, with `anno` on the head
arrow.
-}
curried2 : Mono.LambdaSetAnno -> Mono.MonoType
curried2 anno =
    Mono.mFunction anno [ Mono.MInt ] (Mono.mFunction (Mono.LSet []) [ Mono.MInt ] Mono.MInt)


arities : Dict Int MemberArity
arities =
    Dict.fromList
        [ ( 1, Known (Set.singleton 1) )
        , ( 2, Known (Set.singleton 1) )
        , ( 3, Known (Set.singleton 2) )
        , ( 4, Known (Set.fromList [ 1, 2 ]) )
        , ( 5, KernelFlat )
        , ( 6, Unknown "define" )
        , ( 7, Known (Set.singleton 0) )
        ]


classifyAnno : Mono.LambdaSetAnno -> SetClass
classifyAnno anno =
    MemberArity.classify arities (curried2 anno)


suite : Test
suite =
    describe "MemberArity"
        [ test "a top has no complete set" <|
            \_ -> classifyAnno Mono.topLegacy |> Expect.equal (SetTop (Mono.topKindLabel 10))
        , test "a set variable has no complete set" <|
            \_ -> classifyAnno (Mono.LVar 3) |> Expect.equal SetVar
        , test "a lower bound has no complete set" <|
            \_ -> classifyAnno (Mono.LPartial [ 1 ]) |> Expect.equal SetPartial
        , test "members taking one argument agree on 1" <|
            \_ -> classifyAnno (Mono.LSet [ 1, 2 ]) |> Expect.equal (SetAgree 1)
        , test "setArity gives the agreed arity" <|
            \_ -> MemberArity.setArity arities (curried2 (Mono.LSet [ 1, 2 ])) |> Expect.equal (Just 1)
        , test "members with different arities disagree" <|
            \_ -> classifyAnno (Mono.LSet [ 1, 3 ]) |> Expect.equal SetDisagree
        , test "a member with two arities disagrees with itself" <|
            \_ -> classifyAnno (Mono.LSet [ 4 ]) |> Expect.equal SetDisagree
        , test "setArity gives nothing when members disagree" <|
            \_ -> MemberArity.setArity arities (curried2 (Mono.LSet [ 1, 3 ])) |> Expect.equal Nothing
        , test "a member with no entry is unresolved" <|
            \_ -> classifyAnno (Mono.LSet [ 1, 99 ]) |> Expect.equal (SetUnresolved "none")
        , test "an Unknown member keeps its reason" <|
            \_ -> classifyAnno (Mono.LSet [ 6, 1 ]) |> Expect.equal (SetUnresolved "define")
        , test "setArity gives nothing for an unresolved set" <|
            \_ -> MemberArity.setArity arities (curried2 (Mono.LSet [ 6 ])) |> Expect.equal Nothing
        , test "a kernel member takes the flattened type's arity" <|
            \_ -> classifyAnno (Mono.LSet [ 5 ]) |> Expect.equal (SetAgree 2)
        , test "a kernel member agrees with a member taking as many" <|
            \_ -> classifyAnno (Mono.LSet [ 5, 3 ]) |> Expect.equal (SetAgree 2)
        , test "a kernel member disagrees with a member taking fewer" <|
            \_ -> classifyAnno (Mono.LSet [ 5, 1 ]) |> Expect.equal SetDisagree
        , test "an empty set is SetEmpty" <|
            \_ -> classifyAnno (Mono.LSet []) |> Expect.equal SetEmpty
        , test "setArity gives nothing for an empty set" <|
            \_ -> MemberArity.setArity arities (curried2 (Mono.LSet [])) |> Expect.equal Nothing
        , test "setArity gives nothing for an agreed arity of 0" <|
            \_ -> MemberArity.setArity arities (curried2 (Mono.LSet [ 7 ])) |> Expect.equal Nothing
        , test "a non-function type has no complete set" <|
            \_ -> MemberArity.setArity arities Mono.MInt |> Expect.equal Nothing
        ]
