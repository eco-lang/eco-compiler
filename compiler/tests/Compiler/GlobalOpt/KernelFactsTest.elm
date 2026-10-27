module Compiler.GlobalOpt.KernelFactsTest exposing (suite)

{-| `Compiler.GlobalOpt.KernelFacts` is a hand-written table of facts about the
kernel functions it lists, and it is plain data: no type stops a row from
contradicting itself, and no type notices when an edit to a row changes an
answer that an optimiser reads. These tests catch a row that fails the table's
own consistency checks, and an edit that changes one of the answers pinned
below.

A _gc-leaf_ kernel is one for which `KernelFacts.gcLeafEligible` holds: its row
says it neither allocates on the Eco heap nor can call back into Elm. The
_borrow shim_ is `Compiler.GlobalOpt.Borrow.KernelSigs.lookup`, which gives the
borrow analysis its per-kernel signatures by reading the table, and which
answers nothing for a row whose `params` list is empty.

The fixture is the table itself, `KernelFacts.rows`, and three lists written out
by hand in this module: `stampable`, `legacyBorrowGolden` and
`wave3BorrowAdditions`. They are independent copies, not computed from the
table, so an edit to the table that changes one of these answers fails here
instead of moving the expectation with it.

The tests establish:

  - Test 1: `KernelFacts.validationErrors` is empty, so every row passes the
    table's own consistency checks and no key appears twice.
  - Test 2: the keys of the rows for which `gcLeafEligible` holds, sorted, equal
    `stampable`, sorted.
  - Test 3: for each key in `legacyBorrowGolden`, the shim returns exactly the
    signature written there.
  - Test 4: of the keys in the table, the ones the shim answers for are exactly
    the keys of `legacyBorrowGolden` together with `wave3BorrowAdditions`.
  - Test 5: `lookupSymbol` maps `Elm_Kernel_Utils_compare` and
    `Elm_Kernel_Utils_compare_Float` to the `( "Elm", "Utils", "compare" )` row,
    `Eco_Kernel_MVar_put_Int` to the `( "Eco", "MVar", "put" )` row, and
    `Elm_Kernel_Bytes_read_u32`, whose name itself contains an underscore, to
    the `( "Elm", "Bytes", "read_u32" )` row; it returns `Nothing` for
    `eco_gc_alloc_region_fast`, which has neither kernel prefix. The expected
    rows are looked up in the table, so the test also checks that each of them
    exists.
  - Test 6: `gcLeafEligibleFor` is True for `( "Elm", "String", "length" )` and False
    for `( "Elm", "List", "cons" )`, which is listed but allocates, and for
    `( "Elm", "Platform", "sendToApp" )`, which is not listed; `droppableFor` is False
    for `( "Elm", "Debug", "log" )` (values written out). For every row,
    `gcLeafEligibleFor` and `droppableFor` of its key agree with
    `gcLeafEligible` and `droppable` of its record, and all three key forms
    (with `hoistableFor`) are False for the unlisted `( "Elm", "Platform", "sendToApp" )`.
  - Test 7: the table has 75 rows and 75 distinct keys (57, plus the 18 audited
    `VirtualDom` rows of plans/elm-html-native-kernel.md P8).
  - Test 8: the kernel prefix is part of the key (SD-16,
    plans/kernel-table-prefix-keys.md). A row is found only under its own
    kernel's prefix, by `lookup` and by `lookupSymbol` alike: `Utils.equal` and
    `Utils.compare` only as `Elm`, `MVar.put` only as `Eco`.

Among what is not tested: `hoistableFor` on a listed key (`hoistable` is not
exposed, so it cannot be compared with a record form), `costClass` and
`devirtOf`; the `_Char` suffix in `lookupSymbol`; a key form answering True for
`droppableFor`; the signatures the shim returns for `wave3BorrowAdditions`; and
whether any row is true of the C++ kernel it describes.

-}

import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.KernelFacts as KF
import Expect
import Test exposing (Test)


{-| The eight checks on the `KernelFacts` table listed in the module docstring.
-}
suite : Test
suite =
    Test.describe "GlobalOpt.KernelFacts"
        [ Test.test "1. every row satisfies the cross-field implications" <|
            \_ -> Expect.equal [] KF.validationErrors
        , Test.test "2. gcLeafEligible is exactly the audited stampable set" <|
            \_ ->
                KF.rows
                    |> List.filter (\( _, f ) -> KF.gcLeafEligible f)
                    |> List.map Tuple.first
                    |> List.sort
                    |> Expect.equal (List.sort stampable)
        , Test.test "3. the borrow shim reproduces the 34 audited borrow rows exactly" <|
            \_ ->
                legacyBorrowGolden
                    |> List.map (\( k, sig ) -> ( k, Just sig ))
                    |> Expect.equal (List.map (\( k, _ ) -> ( k, KernelSigs.lookup k )) legacyBorrowGolden)
        , Test.test "4. NO key outside the audited borrow set answers the shim" <|
            \_ ->
                KF.rows
                    |> List.filter (\( k, _ ) -> KernelSigs.lookup k /= Nothing)
                    |> List.map Tuple.first
                    |> List.sort
                    |> Expect.equal (List.sort (List.map Tuple.first legacyBorrowGolden ++ wave3BorrowAdditions))
        , Test.test "5. lookupSymbol strips the ABI prefix and _Int/_Float/_Char" <|
            \_ ->
                let
                    expectedRows =
                        [ KF.lookup ( "Elm", "Utils", "compare" )
                        , KF.lookup ( "Elm", "Utils", "compare" )
                        , KF.lookup ( "Eco", "MVar", "put" )
                        , KF.lookup ( "Elm", "Bytes", "read_u32" )
                        ]
                in
                Expect.all
                    [ \_ ->
                        -- The expected values come from the table, so a missing row
                        -- would make both sides Nothing; pin that every row exists.
                        Expect.equal [] (List.filter ((==) Nothing) expectedRows)
                    , \_ ->
                        Expect.equal
                            (expectedRows ++ [ Nothing ])
                            [ KF.lookupSymbol "Elm_Kernel_Utils_compare"
                            , KF.lookupSymbol "Elm_Kernel_Utils_compare_Float"
                            , KF.lookupSymbol "Eco_Kernel_MVar_put_Int"
                            , KF.lookupSymbol "Elm_Kernel_Bytes_read_u32"
                            , KF.lookupSymbol "eco_gc_alloc_region_fast"
                            ]
                    ]
                    ()
        , Test.test "6. the key-form derived helpers agree with the record form and default False" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Expect.equal
                            [ True, False, False, False ]
                            [ KF.gcLeafEligibleFor ( "Elm", "String", "length" )
                            , KF.gcLeafEligibleFor ( "Elm", "List", "cons" )
                            , KF.gcLeafEligibleFor ( "Elm", "Platform", "sendToApp" )
                            , KF.droppableFor ( "Elm", "Debug", "log" )
                            ]
                    , \_ ->
                        KF.rows
                            |> List.filter
                                (\( k, f ) ->
                                    (KF.gcLeafEligibleFor k /= KF.gcLeafEligible f)
                                        || (KF.droppableFor k /= KF.droppable f)
                                )
                            |> List.map Tuple.first
                            |> Expect.equal []
                    , \_ ->
                        Expect.equal ( False, False, False )
                            ( KF.gcLeafEligibleFor ( "Elm", "Platform", "sendToApp" )
                            , KF.droppableFor ( "Elm", "Platform", "sendToApp" )
                            , KF.hoistableFor ( "Elm", "Platform", "sendToApp" )
                            )
                    ]
                    ()
        , Test.test "7. the table has the expected size and no duplicate keys" <|
            \_ -> Expect.equal ( 75, 75 ) ( List.length KF.rows, List.length (uniqueKeys KF.rows) )
        , Test.test "8. the kernel prefix is part of the key (SD-16)" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        -- A row is found only under its own kernel's prefix.
                        Expect.equal
                            [ True, False, True, False ]
                            [ KF.lookup ( "Elm", "Utils", "equal" ) /= Nothing
                            , KF.lookup ( "Eco", "Utils", "equal" ) /= Nothing
                            , KF.lookup ( "Eco", "MVar", "put" ) /= Nothing
                            , KF.lookup ( "Elm", "MVar", "put" ) /= Nothing
                            ]
                    , \_ ->
                        -- lookupSymbol keeps the prefix of the emitted symbol, so a
                        -- symbol of the other kernel does not reach the row.
                        Expect.equal
                            [ True, False, True, False ]
                            [ KF.lookupSymbol "Elm_Kernel_Utils_compare_Float" /= Nothing
                            , KF.lookupSymbol "Eco_Kernel_Utils_compare_Float" /= Nothing
                            , KF.lookupSymbol "Eco_Kernel_MVar_put_Int" /= Nothing
                            , KF.lookupSymbol "Elm_Kernel_MVar_put_Int" /= Nothing
                            ]
                    ]
                    ()
        ]


{-| Returns the distinct keys of a list of keyed entries, in ascending order.
-}
uniqueKeys : List ( ( String, String, String ), a ) -> List ( String, String, String )
uniqueKeys =
    List.map Tuple.first >> List.sort >> dedupeSorted


{-| Returns `xs` with each run of equal adjacent elements cut down to one, so a
sorted list comes back with every value once.
-}
dedupeSorted : List a -> List a
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs


{-| The 18 kernel keys whose rows are expected to be gc-leaf, written out by
hand rather than computed from the table.

It includes `( "Elm", "Basics", "not" )` and `( "Elm", "Basics", "round" )`. Their rows record
that `not` returns one of the embedded `True` and `False` constants and that
`round`'s only export takes and returns unboxed numbers, so neither allocates.
The two `VirtualDom` URI filters return their argument or the embedded empty
string, copying it only into C++ memory, so they do not allocate either.

-}
stampable : List ( String, String, String )
stampable =
    [ ( "Elm", "Basics", "not" )
    , ( "Elm", "Basics", "round" )
    , ( "Elm", "Utils", "equal" )
    , ( "Elm", "Utils", "notEqual" )
    , ( "Elm", "Utils", "compare" )
    , ( "Elm", "Utils", "lt" )
    , ( "Elm", "Utils", "le" )
    , ( "Elm", "Utils", "gt" )
    , ( "Elm", "Utils", "ge" )
    , ( "Elm", "String", "length" )
    , ( "Elm", "String", "startsWith" )
    , ( "Elm", "String", "endsWith" )
    , ( "Elm", "String", "contains" )
    , ( "Elm", "Bytes", "getStringWidth" )
    , ( "Elm", "Bytes", "width" )
    , ( "Elm", "Bytes", "decodeFailure" )
    , ( "Elm", "VirtualDom", "noJavaScriptUri" )
    , ( "Elm", "VirtualDom", "noJavaScriptOrHtmlUri" )
    ]


{-| The keys the borrow shim answers for beyond those in `legacyBorrowGolden`.

Each of these rows carries a devirtualization registration, which lets a call
site call the kernel directly rather than through a closure, and a filled-in
`params` list. The shim answers for any row whose `params` is non-empty, so
these kernels are among its answers. Test 4 checks only that the shim answers
for them; test 3 does not check their signatures.

-}
wave3BorrowAdditions : List ( String, String, String )
wave3BorrowAdditions =
    [ ( "Elm", "Basics", "not" )
    , ( "Elm", "Basics", "add" )
    , ( "Elm", "Basics", "round" )
    , ( "Elm", "String", "fromList" )
    , ( "Elm", "Json", "wrap" )
    ]


{-| The borrow signatures the shim must return, one for each of 34 kernel keys,
written out by hand.

In a signature, `resultAliases` lists the 0-based indices of the parameters the
result may share. Every parameter here is borrowed except the two of
`( "Elm", "Utils", "append" )`, which are owned.

This list must stay an independent copy, built neither from `KernelFacts` nor
by the shim, so that test 3 compares two separate statements of the same
signatures.

-}
legacyBorrowGolden : List ( ( String, String, String ), KernelSigs.KernelSig )
legacyBorrowGolden =
    [ ( ( "Elm", "Utils", "compare" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "equal" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "notEqual" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "lt" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "le" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "gt" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "ge" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "String", "length" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "String", "startsWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "String", "endsWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "String", "contains" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "JsArray", "length" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "JsArray", "unsafeGet" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Elm", "Debug", "log" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Elm", "Debug", "toString" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Bytes", "getStringWidth" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Bytes", "width" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Bytes", "encode" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Bytes", "decode" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 0, 1 ] } )
    , ( ( "Eco", "Crash", "crash" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "JsArray", "foldl" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "Elm", "JsArray", "foldr" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "Elm", "JsArray", "map" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Elm", "List", "map2" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "Elm", "List", "sortBy" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Elm", "List", "sortWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Elm", "String", "slice" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 2 ] } )
    , ( ( "Elm", "String", "uncons" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "Elm", "String", "words" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "Elm", "String", "trim" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "Elm", "String", "toLower" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "String", "toUpper" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "String", "all" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Elm", "Utils", "append" ), { params = [ KernelSigs.POwned, KernelSigs.POwned ], resultAliases = [ 0, 1 ] } )
    ]
