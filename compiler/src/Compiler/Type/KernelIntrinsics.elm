module Compiler.Type.KernelIntrinsics exposing (Row, lookup, rows, auditedFiles)

{-| Gives a few kernel functions a type, so that each use of one is checked
against a type, instead of being bounded only by its context.

A kernel function is one implemented by the runtime rather than in Elm, and a
module refers to it as `Elm.Kernel.Home.name` or `Eco.Kernel.Home.name`. Such a
reference resolves only in a module of a kernel package, one authored by `elm`,
`elm-explorations` or `eco`. It carries no type, so the constraint generator in
`Compiler.Type.Constrain.Typed.Expression` gives it no constraint of its own,
and its type is bounded only by its context. A kernel applied in place, as in
`Elm.Kernel.List.fromArray (Elm.Kernel.String.split sep string)`, is then typed
as a function whose argument and result are never related to each other.

An intrinsic annotation is a type this module supplies for one kernel, in a row
of its table. For a kernel with a row, the constraint generator emits a
`CForeign` constraint named `Prefix.Kernel.Home.name`, as it does for a
reference to a value of another module: the annotation is instantiated afresh
at each occurrence and unified with what the context expects. A kernel with no
row keeps no constraint of its own, so the table is opt-in, one kernel at a
time.


## An annotation is a claim about representation

The types the solver finds for a kernel's uses are carried into the later
stages of the typed pipeline, by the rules `Compiler.Type.PostSolve` describes,
and those stages take them to say what values the kernel receives and returns.
An annotation must therefore follow what eco's C++ implementation of the
kernel does, even where that differs from the kernel's type in the JavaScript
runtime.

`List.fromArray` is the example. In JavaScript it turns an array into a list,
with type `Array a -> List a`. In eco's C++ runtime it returns a list argument
unchanged, and its one use, in elm/core's `String.split`, is applied to the
list that `Elm.Kernel.String.split` returns. The JavaScript type would say that
value is an `Array` when at run time it is a list, so the row for `fromArray`,
like the row for `toArray`, is `List a -> List a`.

So each row's `evidence` cites the C++ that shows what values the kernel takes
and returns, and its `files` names the C++ source files that evidence rests on.
The repository's `test/scripts/check-kernel-license-manifest.sh`, outside this
source tree, reads `files` from this module and pins each named file by its
sha256 in `src/Compiler/MonoSolver/kernel-license-manifest.txt`.


## A wrong annotation is a type error

A use of a kernel that is not an instance of its annotation is reported as a
type error against `Prefix.Kernel.Home.name`, and the module containing it does
not compile. Every definition in a module is type checked, whether or not
anything uses it, so a single such use in any module a package builds is
enough to break that package.

A row therefore lists in `useSites` every occurrence of the kernel in every
installed package, each checked to be an instance of the annotation. Kernel
references resolve only in kernel packages, so that set is small and a program
outside them cannot add to it.


## Variable names that mean constraints

`Compiler.Type.Solve.srcTypeToVariable` turns an annotation's variables into
solver variables by name: one whose name starts with `number`, `comparable`,
`appendable` or `compappend` becomes a constrained variable, as
`Compiler.Data.Name.isNumberType` and its siblings describe. This makes a type
such as `number -> String` expressible, and also makes an ordinary variable
given such a name by accident a constrained one. The rows name their variables
`a`.


## Keyed by prefix

The table is keyed by (prefix, home, name), where the prefix is `Elm` or `Eco`,
because one home and name can be two different kernels. `Elm.Kernel.File.size`
returns a file's size as an `Int`, while `Eco.Kernel.File.size` returns a task;
one annotation cannot fit both. `Compiler.MonoSolver.KernelSetFacts` and
`Compiler.Type.KernelTypes` key their tables by (home, name) only.


## Kernels not to annotate

  - The `Bytes.write_*` family. elm/bytes contains an unexposed `write` function
    that calls them with a buffer, an offset, a value and, for the wider
    widths, an endianness flag, and uses the result as an `Int`, while eco's
    C++ kernels take only the value and, for the wider widths, the endianness.
    An annotation that fits the C++ makes that function a type error, and
    elm/bytes stops compiling.
  - The `Debug.*` kernels. The C++ `Debug.toString` takes an extra type id
    argument that the compiler supplies, so its real arity differs from the one
    Elm code sees, and `Debug` kernels are handled specially elsewhere, for
    example in `Compiler.Monomorphize.KernelAbi`.
  - Any kernel whose C++ body has not been read. Leaving a kernel out never
    causes a type error.

@docs Row, lookup, rows, auditedFiles

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict exposing (Dict)


{-| One row of the table: the annotation given to a kernel, with the record of
the checks that justify it.

`useSites` and `evidence` are prose kept as data, not comments on the code.
`useSites` lists every occurrence of the kernel in the installed packages and
why each is an instance of `annotation`. `evidence` cites the C++ lines that
show what values the kernel takes and returns, and the date of that reading.
`files` are paths relative to the repository root, which holds this compiler's
directory and the C++ runtime beside it, not relative to the compiler.

-}
type alias Row =
    { annotation : Can.Annotation Name
    , useSites : String
    , evidence : String
    , files : List String
    }


{-| Returns the row for the kernel `prefix.Kernel.home.name`, where `prefix`
is `Elm` or `Eco`, or `Nothing` when the kernel has no annotation and so gets no
constraint of its own.
-}
lookup : Name -> Name -> Name -> Maybe Row
lookup prefix home name =
    Dict.get ( prefix, home, name ) intrinsics


{-| Every row of the table with its (prefix, home, name) key, in key order.
-}
rows : List ( ( Name, Name, Name ), Row )
rows =
    Dict.toList intrinsics


{-| Every path named in any row's `files`, sorted and without duplicates.
-}
auditedFiles : List String
auditedFiles =
    intrinsics
        |> Dict.values
        |> List.concatMap .files
        |> List.sort
        |> dedupeSorted


{-| Removes each element equal to the one before it, so a sorted list comes back
without duplicates.
-}
dedupeSorted : List String -> List String
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs



-- ====== THE TABLE ======


{-| The table of intrinsic annotations, keyed by (prefix, home, name).
-}
intrinsics : Dict ( Name, Name, Name ) Row
intrinsics =
    Dict.fromList
        [ ( ( "Elm", "Json", "addEntry" )
          , { annotation =
                -- (a -> Value) -> a -> Value -> Value
                forall [ "a" ]
                    (Can.tLambda (Can.tLambda (tVar "a") tValue)
                        (Can.tLambda (tVar "a") (Can.tLambda tValue tValue))
                    )
            , useSites = "elm/json 1.1.3+1.1.4 Json/Encode.elm:162 (list), :170 (array), :178 (set) -- all `List/Array/Set.foldl (addEntry func) (emptyArray ()) entries` with func : a -> Value from the enclosing annotation; b unifies to Value, which emptyArray/wrap absorb (both CTrue). No other reference in any installed package."
            , evidence = "JsonExports.cpp:Elm_Kernel_Json_addEntry:1761-1793 applies func to entry via eco_apply_closure :1772 and conses the RETURN onto the accumulator's list :1782, rebuilding an ENC_ARRAY Custom :1786-1791; the accumulator IS the Value representation (emptyArray :1745-1754 allocates ctor=ENC_ARRAY). audited: 2026-08-20 | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged"
            , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
            }
          )
        , ( ( "Elm", "Json", "addField" )
          , { annotation =
                -- String -> Value -> Value -> Value
                forall []
                    (Can.tLambda tString
                        (Can.tLambda tValue (Can.tLambda tValue tValue))
                    )
            , useSites = "elm/json 1.1.3+1.1.4 Json/Encode.elm:202 (object), :224 (dict) -- both `foldl (\\k v obj -> addField k v obj) (emptyObject ()) ...` where k is String (object destructures List (String, Value); dict applies toKey : k -> String) and v is Value (the pair's second, or toValue : v -> Value). The accumulator unifies to Value, which emptyObject/wrap absorb (both CTrue). No other reference in any installed package."
            , evidence = "JsonExports.cpp:Elm_Kernel_Json_addField:1795-1840 builds a (key, value) Tuple2 :1810-1819 and conses it onto the object's field list, rebuilding an ENC_OBJECT Custom; key is a String, value is an already-encoded Value, and the accumulator/result are the ENC_OBJECT representation of Value (emptyObject :1735-1744 allocates ctor=ENC_OBJECT). audited: 2026-08-20 | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged"
            , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
            }
          )
        , ( ( "Elm", "List", "fromArray" )
          , { annotation =
                -- List a -> List a, not the JavaScript kernel's Array a -> List a
                forall [ "a" ] (Can.tLambda (tList (tVar "a")) (tList (tVar "a")))
            , useSites = "elm/core 1.0.5 String.elm:191 (split) only -- `fromArray (Elm.Kernel.String.split sep string)` at a = String. No other reference in any installed package."
            , evidence = "ListExports.cpp:Elm_Kernel_List_fromArray:306-354 is a PASS-THROUGH in eco: embedded constants :309-313 and Tag_Cons/Tag_ConsChunk :326-330 return the ARGUMENT by identity, and its own comment :321-325 records that Elm_Kernel_String_split already returns a proper list -- StringOps::split builds alloc::cons chains (StringOps.cpp:839-853). The JS type Array a -> List a would be a layout lie here. audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
            , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
            }
          )
        , ( ( "Elm", "List", "toArray" )
          , { annotation =
                -- List a -> List a, not the JavaScript kernel's List a -> Array a
                forall [ "a" ] (Can.tLambda (tList (tVar "a")) (tList (tVar "a")))
            , useSites = "elm/core 1.0.5 String.elm:202 (join) only -- `Elm.Kernel.String.join sep (toArray chunks)` at a = String. No other reference in any installed package."
            , evidence = "ListExports.cpp:Elm_Kernel_List_toArray:356-392 is a PASS-THROUGH in eco: embedded constants :362-366 and Tag_Cons/Tag_ConsChunk :369-374 return the ARGUMENT by identity, and the consumer StringOps::join takes a cons list (StringOps.cpp:659). audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
            , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
            }
          )
        ]



-- ====== TYPE BUILDERS ======


{-| Builds an annotation of `tipe` that is polymorphic in the type variables
named in `vars`.
-}
forall : List Name -> Can.Type Name -> Can.Annotation Name
forall vars tipe =
    Can.Forall (Dict.fromList (List.map (\v -> ( v, () )) vars)) tipe


{-| Builds the type variable with the given name.
-}
tVar : Name -> Can.Type Name
tVar =
    Can.TVar


{-| Builds the type of an elm/core `List` of `el`.
-}
tList : Can.Type Name -> Can.Type Name
tList el =
    Can.TType ModuleName.list "List" [ el ]


{-| The type of an elm/core `String`.
-}
tString : Can.Type Name
tString =
    Can.TType ModuleName.string "String" []


{-| The type of an elm/json encoded `Value`, from `Json.Encode`.
-}
tValue : Can.Type Name
tValue =
    Can.TType ModuleName.jsonEncode "Value" []
