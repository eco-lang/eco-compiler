module TestLogic.Monomorphize.BorrowFenceTest exposing (suite)

{-| LSS_024 — the Borrow fence (the §7.2 obligation of
`plans/lss-layout-qualified-members.md`, amended BORROW_006).

`Borrow.buildLambdaSigs` may store one representative's `BorrowSig` for a
member only when the member's instances are fingerprint-unanimous; a
divergent member's stored sig is the MEET over per-instance sigs (params
any-owned-wins, result any-borrowed-wins). Driven through the exported
`Borrow.deriveFacts` on hand-built graphs holding two instances of ONE
member id with a heap-typed (String) parameter:

1.  A borrowing-only instance ALONE → its param reads back borrowed
    (establishes the discriminating signal).
2.  An owning instance + a borrowing instance under one member id — bodies
    fingerprint-DIVERGENT → the stored sig is the meet: the param is NOT
    borrowed, in BOTH instance orders (order-independence is the witness
    that the meet ran; a representative-only build would flip with the
    order).
3.  Verbatim clones → fence passes; facts equal the single-instance build
    (today's behavior preserved).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.Borrow.Facts as Facts
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Set
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "LSS_024 Borrow fence (buildLambdaSigs)"
        [ Test.test "borrowing-only instance alone: param reads back borrowed" <|
            \() ->
                Expect.equal (Set.fromList [ 0 ])
                    (borrowedOf [ mkClosure 1 borrowingBody ])
        , Test.test "owning-only instance alone: param reads back NOT borrowed" <|
            \() ->
                Expect.equal Set.empty
                    (borrowedOf [ mkClosure 1 owningBody ])
        , Test.test "divergent pair, owning FIRST: meet — param not borrowed" <|
            \() ->
                Expect.equal Set.empty
                    (borrowedOf [ mkClosure 1 owningBody, mkClosure 2 borrowingBody ])
        , Test.test "divergent pair, borrowing FIRST: meet — param STILL not borrowed (order-independent)" <|
            \() ->
                Expect.equal Set.empty
                    (borrowedOf [ mkClosure 1 borrowingBody, mkClosure 2 owningBody ])
        , Test.test "verbatim clones: fence passes, facts equal the single-instance build" <|
            \() ->
                Expect.equal
                    (borrowedOf [ mkClosure 1 borrowingBody ])
                    (borrowedOf [ mkClosure 1 borrowingBody, mkClosure 2 borrowingBody ])
        ]



-- ====== FIXTURE MACHINERY ======


member : Int
member =
    88881


home : IO.Canonical
home =
    IO.Canonical ( "author", "proj" ) "M"


{-| Returns its String param — the param escapes into the result (owned).
-}
owningBody : Mono.MonoExpr
owningBody =
    Mono.MonoVarLocal "x" Mono.MString


{-| Ignores its String param — returns a fresh literal (param borrowed).
-}
borrowingBody : Mono.MonoExpr
borrowingBody =
    Mono.MonoLiteral (Mono.LStr "k") Mono.MString


mkClosure : Int -> Mono.MonoExpr -> Mono.MonoExpr
mkClosure uid body =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home uid
        , srcLambda = Nothing
        , lssMember = Just member
        , captures = []
        , params = [ ( "x", Mono.MString ) ]
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction (Mono.LSet [ member ]) [ Mono.MString ] Mono.MString)


borrowedOf : List Mono.MonoExpr -> Set.Set Int
borrowedOf exprs =
    Facts.borrowedParamsOfLambda (Borrow.deriveFacts (graphOf exprs)) member


graphOf : List Mono.MonoExpr -> Mono.MonoGraph
graphOf exprs =
    Mono.MonoGraph
        { nodes =
            Array.fromList
                [ Just
                    (Mono.MonoDefine
                        (Mono.MonoList A.zero exprs (Mono.mList Mono.MString))
                        (Mono.mList Mono.MString)
                    )
                ]
        , main = Nothing
        , registry =
            { nextId = 0
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping = Array.empty
            , countByGlobal = Dict.empty
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 100
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        , lssBlockedMembers = Dict.empty
        }
