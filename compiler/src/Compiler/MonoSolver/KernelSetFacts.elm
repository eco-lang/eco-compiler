module Compiler.MonoSolver.KernelSetFacts exposing
    ( ParamSetFlow(..)
    , KernelPlan
    , planFor
    , rowFor
    )

{-| LSS_021 — per-kernel per-parameter SET-FLOW facts (GAP-4,
`plans/lss-fidelity-3-signature-flow-completion.md` Phase F): which
functional params a kernel merely APPLIES (never stores/returns — their
arrow slots need no LSS_004 poison; the set stays whatever the caller knows,
the kernel adds no inhabitants), which TUNNEL to the result, and which stay
OPAQUE (poison — today's behavior, and the default for every kernel without
a row and every arity-mismatched boundary).

Deliberately parallel to `Compiler.GlobalOpt.KernelFacts` (same audit
discipline: `( Name, Name )` keys, MANDATORY C++ evidence anchors,
unknown ⇒ consumer keeps its own default) but a SEPARATE table — each audit
stands alone; this one is the set-flow axis, that one the borrow axis.

Both consumers — `LssInfer.kernelCallBoundary` (inference side) and
`Translate.poisonKernelArrowsThen` (translation side) — consult THIS module
(`planFor` at call sites, `rowFor` at scheme loads): the LSS_006-style
two-sided discipline; the sides must never disagree about which arrows
poison.

**Soundness rule (LSS_021):** a wrong `PSFApplies` row that lets a STORED
callback keep a narrow set is a miscompile vector. Every row cites the
audited C++ body; when in doubt a kernel keeps LSS_004 poison.

REJECTED rows (callback STORED into the returned heap object — never add
`PSFApplies` for these): `Scheduler.andThen` / `onError` / `binding` /
`receive` — the callback lands in the returned Task object
(`runtime/src/platform/Scheduler.cpp:144-162`, `allocTask(..., callback,
...)`). The storage-rejection precedents in `KernelFacts.elm` (Console.write,
File.fileExists/dirExists, Env.lookup, Scheduler.spawn) apply equally.

Audited-eligible NEXT candidates (apply-only per the 2026-08-20 C++ audit;
add per the `kernelMissHist` heat list, one kernel per commit, evidence
mandatory): `String.map/filter/any/all/foldl/foldr`
(StringExports.cpp:263-366), `JsArray.map` (JsArrayExports.cpp:463+).

-}

import Compiler.Data.Name exposing (Name)
import Dict


type ParamSetFlow
    = PSFOpaque
    | PSFApplies
    | PSFTunnels


type alias KernelPlan =
    { params : List ParamSetFlow

    -- The RESULT row: PSFOpaque = poison the result's arrows (today);
    -- PSFApplies = leave them unconstrained (the consumer then treats the
    -- result value as untracked — sound, empty-slot reads default to ⊤).
    , result : ParamSetFlow
    , evidence : String
    }


{-| The plan for a kernel CALL boundary at an exact arity. `Nothing` (no
row, or arity mismatch = partial/over application) ⇒ the consumer keeps
LSS_004 full poison.
-}
planFor : Name -> Name -> Int -> Maybe KernelPlan
planFor home name arity =
    case rowFor home name of
        Just plan ->
            if List.length plan.params == arity then
                Just plan

            else
                Nothing

        Nothing ->
            Nothing


{-| The raw row (translation side: the loaded SCHEME's spine is descended
exactly `List.length plan.params` arrows; an early spine end there falls
back to full poison — the arity check in structural form).
-}
rowFor : Name -> Name -> Maybe KernelPlan
rowFor home name =
    Dict.get ( home, name ) facts


{-| v1 rows (2026-08-20 C++ audit). Shared driver for map2-5 is
`kernelListMapN` (ListExports.cpp:432-590): the callback is rooted and
APPLIED via `eco_apply_closure_eval` (:567-569); the result list is built
from the callback's RETURNS only. map2-5 result rows ship `PSFOpaque`: when
the Elm `result` tvar instantiates to a function, a stored return can be a
PAP OF THE CALLBACK (`eco_apply_closure_eval` PAP chaining,
RuntimeExports.cpp:1987-2145) — result-element arrows are the callback's
inner arrows, not expressible as a v1 fact. sortBy/sortWith list-param →
result is a permutation (`listFromPermutation`) — `PSFTunnels` is the
recorded refinement; opaque is sound and ships first.
-}
facts : Dict.Dict ( Name, Name ) KernelPlan
facts =
    Dict.fromList
        [ ( ( "List", "map2" )
          , { params = [ PSFApplies, PSFOpaque, PSFOpaque ]
            , result = PSFOpaque
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:Elm_Kernel_List_map2:592-600 -> kernelListMapN:432-590 (apply :567-569)"
            }
          )
        , ( ( "List", "map3" )
          , { params = [ PSFApplies, PSFOpaque, PSFOpaque, PSFOpaque ]
            , result = PSFOpaque
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:Elm_Kernel_List_map3:602-611 -> kernelListMapN:432-590"
            }
          )
        , ( ( "List", "map4" )
          , { params = [ PSFApplies, PSFOpaque, PSFOpaque, PSFOpaque, PSFOpaque ]
            , result = PSFOpaque
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:Elm_Kernel_List_map4:613-623 -> kernelListMapN:432-590"
            }
          )
        , ( ( "List", "map5" )
          , { params = [ PSFApplies, PSFOpaque, PSFOpaque, PSFOpaque, PSFOpaque, PSFOpaque ]
            , result = PSFOpaque
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:Elm_Kernel_List_map5:625-639 -> kernelListMapN:432-590"
            }
          )
        , ( ( "List", "sortBy" )
          , { params = [ PSFApplies, PSFOpaque ]
            , result = PSFOpaque
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:Elm_Kernel_List_sortBy:759-831 (callUnaryClosure :787; keys feed stable_sort only :805-825)"
            }
          )
        , ( ( "List", "sortWith" )
          , { params = [ PSFApplies, PSFOpaque ]
            , result = PSFOpaque
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:Elm_Kernel_List_sortWith:832-895 (callBinaryClosure :873; result via listFromPermutation :885)"
            }
          )
        ]
