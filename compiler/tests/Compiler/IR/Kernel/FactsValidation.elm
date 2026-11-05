module Compiler.IR.Kernel.FactsValidation exposing (validationErrors, gcLeafEligibleFor)

{-| The table check of `Compiler.IR.Kernel.Facts`: the rules every row of the
kernel facts table must obey, which `Compiler.IR.Kernel.FactsTest` requires to
hold. The compiler itself never evaluates them.

`gcLeafEligibleFor` is the key form of `Facts.gcLeafEligible`, with the
whitelist default folded in, which the tests compare with the record form.

-}

import Compiler.Core.Name exposing (Name)
import Compiler.IR.Kernel.Facts
    exposing
        ( CallTimeEffect(..)
        , DevirtPolicy(..)
        , GcAlloc(..)
        , HofAxis(..)
        , KernelFacts
        , ShapeGuard(..)
        , Totality(..)
        , gcLeafEligible
        , lookup
        , rows
        )
import Set


{-| Returns `gcLeafEligible` of the key's row, or `False` for an unlisted key.
-}
gcLeafEligibleFor : ( Name, Name, Name ) -> Bool
gcLeafEligibleFor key =
    lookup key |> Maybe.map gcLeafEligible |> Maybe.withDefault False


{-| Messages for the ways the table breaks its own rules; an empty list means
the table is consistent.

Repeated keys give a single message stating how many rows repeat an earlier
key.

Each row must obey these rules, and a row that breaks one gets a message naming
it. Evidence must contain `.cpp:` or `.hpp:`. A `cseSafe` row must have no
call-time effect, an audited `HofNo`, and a totality other than
`MayDiverge`. An `EffNoreturn` row must not be `Total`. `GcFixed` must be
positive. A `HofYes` row must be `GcUnbounded` and not `Total`. A `Throws` row
must carry a divergence note. Every `resultAliases` index must point into
`params`. The key must look like a Mono key: home and name non-empty, a home
not starting with `Elm_Kernel_` or `Eco_Kernel_`, and a name not ending in
`_Int`, `_Float` or `_Char`.

A row registered with `DevirtAt arity guard` must also have a non-negative
`arity`, equal to the length of `params` when `params` is not empty, carry
evidence, and give guard positions that are `-1` or an argument index from 0 to
`arity - 1`.

-}
validationErrors : List String
validationErrors =
    dupKeyErrors
        ++ List.concatMap rowErrors rows
        ++ List.concatMap (\( key, facts ) -> devirtErrors key facts) rows


{-| Returns a message for each way a row's devirtualization registration is
wrong, or nothing for a row that is not registered. A registration must have a
non-negative arity, evidence, and guard positions that are `-1` or a valid
argument index for that arity.

A row can state its arity twice, in `DevirtAt` and as the length of `params`,
and the two must agree. Since `params = []` means the borrow axis was not
audited rather than that the kernel takes no arguments, they are compared only
when `params` is not empty; that is why `DevirtAt` carries its own arity.

-}
devirtErrors : ( Name, Name, Name ) -> KernelFacts -> List String
devirtErrors ( prefix, home, name ) facts =
    let
        key =
            prefix ++ ".Kernel." ++ home ++ "." ++ name
    in
    case facts.devirt of
        DevirtNo ->
            []

        DevirtAt arity guard ->
            (if arity < 0 then
                [ key ++ ": DevirtAt arity is negative" ]

             else
                []
            )
                ++ (if not (List.isEmpty facts.params) && List.length facts.params /= arity then
                        [ key
                            ++ ": DevirtAt "
                            ++ String.fromInt arity
                            ++ " disagrees with params ("
                            ++ String.fromInt (List.length facts.params)
                            ++ ")"
                        ]

                    else
                        []
                   )
                ++ (if String.isEmpty facts.evidence then
                        [ key ++ ": DevirtAt row carries no evidence" ]

                    else
                        []
                   )
                ++ (case guard of
                        ShapeAny ->
                            []

                        ShapeNoUnboxedScalarAt positions ->
                            if List.all (\pos -> pos == -1 || (pos >= 0 && pos < arity)) positions then
                                []

                            else
                                [ key ++ ": ShapeNoUnboxedScalarAt position out of range for arity " ++ String.fromInt arity ]
                   )


{-| A message giving how many rows repeat an earlier row's key, or nothing
when every key is distinct. `lookup` would find only the last such row, with no
other sign of the others.
-}
dupKeyErrors : List String
dupKeyErrors =
    let
        distinctKeys =
            Set.size (Set.fromList (List.map Tuple.first rows))
    in
    if List.length rows == distinctKeys then
        []

    else
        [ "duplicate key(s): " ++ String.fromInt (List.length rows - distinctKeys) ]


{-| Returns a message, naming the row, for each rule the row breaks. Evidence
must contain `.cpp:` or `.hpp:`. A `cseSafe` row must have no
call-time effect, an audited `HofNo`, and a totality other than `MayDiverge`.
An `EffNoreturn` row must not be `Total`. `GcFixed` must be positive. A `HofYes`
row must be `GcUnbounded` and not `Total`. A `Throws` row must carry a
divergence note. Every `resultAliases` index must point into `params`. The key
must look like a Mono key: home and name non-empty, a home not starting with
`Elm_Kernel_` or `Eco_Kernel_`, and a name not ending in `_Int`, `_Float` or
`_Char`.
-}
rowErrors : ( ( Name, Name, Name ), KernelFacts ) -> List String
rowErrors ( ( prefix, home, name ), f ) =
    let
        tag msg =
            prefix ++ ".Kernel." ++ home ++ "." ++ name ++ ": " ++ msg

        check cond msg =
            if cond then
                []

            else
                [ tag msg ]
    in
    List.concat
        [ check (String.contains ".cpp:" f.evidence || String.contains ".hpp:" f.evidence)
            "evidence must carry at least one <file>.cpp:<line> / .hpp:<line> anchor"
        , check (not f.cseSafe || (f.callTimeEffect == EffNone && f.callsBack == HofNo && f.totality /= MayDiverge))
            "cseSafe requires EffNone AND callsBack == HofNo AND totality /= MayDiverge"
        , check (f.callTimeEffect /= EffNoreturn || f.totality /= Total)
            "EffNoreturn requires totality /= Total"
        , check (gcBudgetOk f.gcAlloc)
            "GcFixed n requires n > 0 (use GcNone for zero)"
        , -- Elm code run by a call can allocate any amount, and need not return.
          check (f.callsBack /= HofYes || (f.gcAlloc == GcUnbounded && f.totality /= Total))
            "callsBack == HofYes requires GcUnbounded AND totality /= Total"
        , check (f.totality /= Throws || f.divergence /= Nothing)
            "totality = Throws requires a divergence note"
        , -- So a row with no borrow modes cannot list aliases either.
          check (List.all (\i -> i >= 0 && i < List.length f.params) f.resultAliases)
            "resultAliases index out of range for params"
        , check (home /= "" && name /= "")
            "empty home/name"
        , check (not (String.startsWith "Elm_Kernel_" home || String.startsWith "Eco_Kernel_" home))
            "home must be the Mono home, not the C symbol prefix"
        , check (not (List.any (\s -> String.endsWith s name) [ "_Int", "_Float", "_Char" ]))
            "name must be the base Mono name, not an ABI-suffixed symbol"
        ]


{-| Returns whether an allocation bound is acceptable: `GcFixed` must be
positive, and the other values always are.
-}
gcBudgetOk : GcAlloc -> Bool
gcBudgetOk ga =
    case ga of
        GcFixed n ->
            n > 0

        _ ->
            True
