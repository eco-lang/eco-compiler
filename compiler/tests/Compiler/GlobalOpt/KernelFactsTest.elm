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
    `Elm_Kernel_Utils_compare_Float` to the `( "Utils", "compare" )` row,
    `Eco_Kernel_MVar_put_Int` to the `( "MVar", "put" )` row, and
    `Elm_Kernel_Bytes_read_u32`, whose name itself contains an underscore, to
    the `( "Bytes", "read_u32" )` row; it returns `Nothing` for
    `eco_gc_alloc_region_fast`, which has neither kernel prefix.
  - Test 6: `gcLeafEligibleFor` is True for `( "String", "length" )` and False
    for `( "List", "cons" )`, which is listed but allocates, and for
    `( "Platform", "sendToApp" )`, which is not listed; `droppableFor` is False
    for `( "Debug", "log" )`. The expected values are written out, not computed
    from the record forms.
  - Test 7: the table has 57 rows and 57 distinct keys.

Among what is not tested: `hoistable`, `hoistableFor`, `costClass` and
`devirtOf`; the `_Char` suffix in `lookupSymbol`; a key form answering True for
`droppableFor`; the signatures the shim returns for `wave3BorrowAdditions`; and
whether any row is true of the C++ kernel it describes.

-}

import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.KernelFacts as KF
import Expect
import Test exposing (Test)


{-| The seven checks on the `KernelFacts` table listed in the module docstring.
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
                Expect.equal
                    [ KF.lookup ( "Utils", "compare" ), KF.lookup ( "Utils", "compare" ), KF.lookup ( "MVar", "put" ), KF.lookup ( "Bytes", "read_u32" ), Nothing ]
                    [ KF.lookupSymbol "Elm_Kernel_Utils_compare"
                    , KF.lookupSymbol "Elm_Kernel_Utils_compare_Float"
                    , KF.lookupSymbol "Eco_Kernel_MVar_put_Int"
                    , KF.lookupSymbol "Elm_Kernel_Bytes_read_u32"
                    , KF.lookupSymbol "eco_gc_alloc_region_fast"
                    ]
        , Test.test "6. the key-form derived helpers agree with the record form and default False" <|
            \_ ->
                Expect.equal
                    [ True, False, False, False ]
                    [ KF.gcLeafEligibleFor ( "String", "length" )
                    , KF.gcLeafEligibleFor ( "List", "cons" )
                    , KF.gcLeafEligibleFor ( "Platform", "sendToApp" )
                    , KF.droppableFor ( "Debug", "log" )
                    ]
        , Test.test "7. the table has the expected size and no duplicate keys" <|
            \_ -> Expect.equal ( 57, 57 ) ( List.length KF.rows, List.length (uniqueKeys KF.rows) )
        ]


{-| Returns the distinct keys of a list of keyed entries, in ascending order.
-}
uniqueKeys : List ( ( String, String ), a ) -> List ( String, String )
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


{-| The 16 kernel keys whose rows are expected to be gc-leaf, written out by
hand rather than computed from the table.

It includes `( "Basics", "not" )` and `( "Basics", "round" )`. Their rows record
that `not` returns one of the embedded `True` and `False` constants and that
`round`'s only export takes and returns unboxed numbers, so neither allocates.

-}
stampable : List ( String, String )
stampable =
    [ ( "Basics", "not" )
    , ( "Basics", "round" )
    , ( "Utils", "equal" )
    , ( "Utils", "notEqual" )
    , ( "Utils", "compare" )
    , ( "Utils", "lt" )
    , ( "Utils", "le" )
    , ( "Utils", "gt" )
    , ( "Utils", "ge" )
    , ( "String", "length" )
    , ( "String", "startsWith" )
    , ( "String", "endsWith" )
    , ( "String", "contains" )
    , ( "Bytes", "getStringWidth" )
    , ( "Bytes", "width" )
    , ( "Bytes", "decodeFailure" )
    ]


{-| The keys the borrow shim answers for beyond those in `legacyBorrowGolden`.

Each of these rows carries a devirtualization registration, which lets a call
site call the kernel directly rather than through a closure, and a filled-in
`params` list. The shim answers for any row whose `params` is non-empty, so
these kernels are among its answers. Test 4 checks only that the shim answers
for them; test 3 does not check their signatures.

-}
wave3BorrowAdditions : List ( String, String )
wave3BorrowAdditions =
    [ ( "Basics", "not" )
    , ( "Basics", "add" )
    , ( "Basics", "round" )
    , ( "String", "fromList" )
    , ( "Json", "wrap" )
    ]


{-| The borrow signatures the shim must return, one for each of 34 kernel keys,
written out by hand.

In a signature, `resultAliases` lists the 0-based indices of the parameters the
result may share. Every parameter here is borrowed except the two of
`( "Utils", "append" )`, which are owned.

This list must stay an independent copy, built neither from `KernelFacts` nor
by the shim, so that test 3 compares two separate statements of the same
signatures.

-}
legacyBorrowGolden : List ( ( String, String ), KernelSigs.KernelSig )
legacyBorrowGolden =
    [ ( ( "Utils", "compare" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "equal" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "notEqual" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "lt" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "le" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "gt" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "ge" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "length" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "startsWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "endsWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "contains" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "JsArray", "length" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "JsArray", "unsafeGet" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Debug", "log" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Debug", "toString" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "getStringWidth" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "width" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "encode" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "decode" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 0, 1 ] } )
    , ( ( "Crash", "crash" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "JsArray", "foldl" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "JsArray", "foldr" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "JsArray", "map" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "List", "map2" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "List", "sortBy" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "List", "sortWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "String", "slice" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 2 ] } )
    , ( ( "String", "uncons" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "String", "words" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "String", "trim" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "String", "toLower" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "toUpper" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "all" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "append" ), { params = [ KernelSigs.POwned, KernelSigs.POwned ], resultAliases = [ 0, 1 ] } )
    ]
