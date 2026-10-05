#!/usr/bin/env python3
"""Generate the wide-object E2E pins of plans/wide-object-tail-kind-words-phase-0.md.

Usage: gen_wide_pins.py OUT_ELM_DIR OUT_ECO_KERNEL_DIR
Writes one <Name>.elm per pin; each file carries its own `-- CHECK:` lines,
computed here from the same formulas the program evaluates.
Deterministic: re-running produces byte-identical files.
"""
import sys, os

def kind(i):            # mixed-kind pattern: Int, Float, Char, String, Bool
    return ["Int", "Float", "Char", "String", "Bool"][i % 5]

def elm_val(i, k, base="base"):
    # source expression for field i of kind k; base is a runtime 1
    return {"Int": f"({base} + {1000 + i - 1})",
            "Float": f"(toFloat {base} + {i}.5 - 1)",
            "Char": f"(Char.fromCode ({base} + {96 + (i % 26)}))",
            "String": f"(String.fromInt ({base} + {i - 1}) ++ \"s\")",
            "Bool": f"(modBy 2 ({base} + {i - 1}) == 0)"}[k]

def py_show(i, k):      # Debug.toString of that value with base = 1
    return {"Int": str(1000 + i),
            "Float": f"{i}.5",
            "Char": "'" + chr(97 + (i % 26)) + "'",
            "String": f"\"{i}s\"",
            "Bool": "True" if i % 2 == 0 else "False"}[k]

HDR = "import Html exposing (text)\n\n"
BASE = "        base =\n            1 + List.length [ () ] - 1\n\n"

def module(name, doc, checks, body):
    s = f"module {name} exposing (main)\n\n{{-| {doc}\n-}}\n\n"
    s += "".join(f"-- CHECK: {c}\n" for c in checks) + "\n" + HDR + body
    return s

def fields_decl(n, kinds):
    return "\n    , ".join(f"f{i:04d} : {kinds[i]}" for i in range(n))

def logs(pairs):        # pairs: (label, expr)
    return "".join(f"        _ =\n            Debug.log \"{l}\" ({e})\n\n" for l, e in pairs)

out = {}

# ---- WideRecordPatternTest (E3, B3; green P1) --------------------------------
n = 28
decl = "\n    , ".join(f"f{i:02d} : Int" for i in range(n))
vals = "\n        , ".join(f"f{i:02d} = base + {1000 + i - 1}" for i in range(n))
body = f"""type alias R =
    {{ {decl}
    }}


make : Int -> R
make base =
    {{ {vals}
    }}


viaPat : R -> Int
viaPat {{ f27, f25 }} =
    f27 * 1000 + f25


upd : R -> R
upd r =
    {{ r | f27 = r.f27 + 1, f26 = 7 }}


main =
    let
{BASE}        r =
            make base

{logs([("access f27", "r.f27"), ("access f25", "r.f25"), ("pattern", "viaPat r"),
       ("update f27", "(upd r).f27"), ("update f26", "(upd r).f26"), ("update pattern", "viaPat (upd r)")])}    in
    text "done"
"""
out["WideRecordPatternTest"] = module("WideRecordPatternTest",
    "E3/B3: a 28-Int record read through a record PATTERN projects slots 26/27\n(stored boxed under the 26-slot cap) as raw i64. `.f27` and update are correct.",
    ["access f27: 1027", "access f25: 1025", "pattern: 1028025", "update f27: 1028",
     "update f26: 7", "update pattern: 1029025"], body)

# ---- WideClosurePap27bTest (E4; green P2) ------------------------------------
n = 28
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["Int"] * (n + 1))
summ = " + ".join(f"a{i} * {i + 1}" for i in range(n))
first = " ".join(f"(base + {i})" for i in range(20))
step = " ".join(f"(b + {i})" for i in range(20, 27))
exp = [sum((1 + k) * (k + 1) for k in range(20)) + sum((b + k) * (k + 1) for k in range(20, 27)) + 5 * 28
       for b in (100, 200)]
L_PAP27B = logs([("res", "List.map (\\g -> g 5) gs")])
body = f"""big : {sig}
big {params} =
    {summ}


step7 : (Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int) -> Int -> (Int -> Int)
step7 h b =
    h {step}


main =
    let
{BASE}        h =
            big {first}

        gs =
            List.map (step7 h) [ 100, 200 ]

{L_PAP27B}    in
    text "done"
"""
out["WideClosurePap27bTest"] = module("WideClosurePap27bTest",
    "E4: an arity-28 closure extended 20 + 7 + 1 through eco_pap_extend; the param\nkinds at slots 25/26 are truncated to boxed, so the typed consumer reads HPointers.",
    [f"res: [{exp[0]}, {exp[1]}]"], body)

# ---- WideClosureSat26Test (E5; green P2) -------------------------------------
n = 26
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["Int"] * n + ["(Int -> Int)"])
summ = " + ".join(f"a{i} * {i + 1}" for i in range(n))
args = " ".join(f"(base + {i})" for i in range(n))
exp = [x * 7 + sum((1 + i) * (i + 1) for i in range(n)) for x in (1, 2)]
body = f"""mk : {sig}
mk {params} =
    \\x -> x * 7 + {summ}


main =
    let
{BASE}        f =
            mk {args}

{logs([("res", "List.map f [ 1, 2 ]")])}    in
    text "done"
"""
out["WideClosureSat26Test"] = module("WideClosureSat26Test",
    "E5: 26 typed newargs at once to an arity-27 function (eta-flattened mk).",
    [f"res: [{exp[0]}, {exp[1]}]"], body)

# ---- WideClosureBoxed27Test (E6; green P2) -----------------------------------
n = 27
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["String"] * n + ["(Int -> Int)"])
summ = " + ".join(f"String.length a{i}" for i in range(n))
args = " ".join(f"(String.repeat (base + {i}) \"a\")" for i in range(n))
exp = [x * 7 + sum(1 + i for i in range(n)) for x in (1, 2)]
body = f"""mk : {sig}
mk {params} =
    \\x -> x * 7 + {summ}


main =
    let
{BASE}        f =
            mk {args}

{logs([("res", "List.map f [ 1, 2 ]")])}    in
    text "done"
"""
out["WideClosureBoxed27Test"] = module("WideClosureBoxed27Test",
    "E6: 27 boxed (String) newargs at once: rejected by the 25-newarg count cap.",
    [f"res: [{exp[0]}, {exp[1]}]"], body)

# ---- WideClosureCapture27Test (E7 + typed variant; green P2) -----------------
n = 27
sp = " ".join(f"a{i}" for i in range(n))
ssig = " -> ".join(["String"] * n + ["List Int", "List Int"])
ssum = " + ".join(f"String.length a{i}" for i in range(n))
sargs = " ".join(f"(String.repeat (base + {i}) \"a\")" for i in range(n))
isig = " -> ".join(["Int"] * n + ["List Int", "List Int"])
isum = " + ".join(f"a{i} * {i + 1}" for i in range(n))
iargs = " ".join(f"(base + {i})" for i in range(n))
es = [x * 1000 + sum(1 + i for i in range(n)) for x in (1, 2)]
ei = [x * 1000 + sum((1 + i) * (i + 1) for i in range(n)) for x in (1, 2)]
body = f"""mkS : {ssig}
mkS {sp} xs =
    List.map (\\x -> x * 1000 + {ssum}) xs


mkI : {isig}
mkI {sp} xs =
    List.map (\\x -> x * 1000 + {isum}) xs


main =
    let
{BASE}{logs([("strings", f"mkS {sargs} [ 1, 2 ]"), ("ints", f"mkI {iargs} [ 1, 2 ]")])}    in
    text "done"
"""
out["WideClosureCapture27Test"] = module("WideClosureCapture27Test",
    "E7: a lambda capturing 27 params (boxed and typed variants) passed to List.map:\npapCreate num_captured = 27.",
    [f"strings: [{es[0]}, {es[1]}]", f"ints: [{ei[0]}, {ei[1]}]"], body)

# ---- decoder-pattern records (E8 / E9) ----------------------------------------
def decoder(name, n, kinds, doc, show):
    decl = fields_decl(n, kinds)
    chain = "\n".join(f"        |> andMap (Just {elm_val(i, kinds[i], 'b')})" for i in range(n))
    pairs = [(f"f{i:04d}", f"Maybe.map .f{i:04d} r") for i in show]
    checks = [f"f{i:04d}: Just {py_show(i, kinds[i])}" for i in show]
    body = f"""type alias R =
    {{ {decl}
    }}


andMap : Maybe a -> Maybe (a -> b) -> Maybe b
andMap ma mf =
    case ( mf, ma ) of
        ( Just f, Just a ) ->
            Just (f a)

        _ ->
            Nothing


build : Int -> Maybe R
build b =
    Just R
{chain}


main =
    let
{BASE}        r =
            build base

{logs(pairs)}    in
    text "done"
"""
    out[name] = module(name, doc, checks, body)

decoder("WideRecordDecoder26Test", 26, ["Int"] * 26,
        "E8: a 26-Int record alias built with the decoder (andMap) pattern; the\nconstructor closure has arity 26 and loses param kind 25.",
        [0, 24, 25])
k30 = ["Int"] * 25 + ["Float", "Char", "Int", "String", "Int"]
decoder("WideRecordDecoder30Test", 30, k30,
        "E8, mixed kinds at declaration positions >= 25 (30 fields).", [0, 24, 25, 26, 27, 28, 29])
k70 = [kind(i) for i in range(70)]
decoder("WideRecordDecoder70Test", 70, k70,
        "E9: a 70-field mixed record built with andMap: papCreate arity 70 (> 63) and\nfield_count 70 (> 32).", [0, 19, 20, 24, 25, 31, 32, 33, 62, 63, 64, 69])
k300 = [kind(i) for i in range(300)]
decoder("WideRecordDecoder300Test", 300, k300,
        "A 300-field mixed record built with andMap (closure arity 300, record > 2 KiB).",
        [0, 19, 20, 31, 32, 63, 64, 95, 96, 255, 256, 299])

# ---- staged closures of arity 63 / 300 / 2047 (green P2) ---------------------
def staged(name, n, kinds, steps, doc, timing_note=""):
    params = " ".join(f"a{i}" for i in range(n))
    sig = " -> ".join(kinds + ["Int"])
    def term(i):
        k = kinds[i]
        return {"Int": f"a{i} * {i + 1}", "Float": f"round (a{i} * 10)",
                "Char": f"Char.toCode a{i}", "String": f"String.length a{i}",
                "Bool": f"(if a{i} then {i} else 0)"}[k]
    summ = "\n    + ".join(term(i) for i in range(n))
    def pval(i):
        k = kinds[i]
        return {"Int": (1 + i) * (i + 1), "Float": round((i + 0.5) * 10),
                "Char": 96 + (i % 26) + 1, "String": i + 1,
                "Bool": i if (i % 2 == 0) else 0}[k]
    # slot values: Int base+i, Float base+i-0.5 (=i+0.5), Char code base+96+i%26, String len base+i, Bool even
    def arg(i):
        k = kinds[i]
        return {"Int": f"(b + {i})", "Float": f"(toFloat b + {i}.5 - 1)",
                "Char": f"(Char.fromCode (b + {96 + (i % 26)}))",
                "String": f"(String.repeat (b + {i}) \"a\")",
                "Bool": f"(modBy 2 (b + {i - 1}) == 0)"}[k]
    fns, pos = [], 0
    pipeline = "big"
    for si, cnt in enumerate(steps):
        a = " ".join(arg(j) for j in range(pos, pos + cnt))
        fns.append(f"step{si} h b =\n    h {a}\n")
        pos += cnt
    assert pos == n
    app = "List.map (\\b -> big) [ base ]"
    expr = "big"
    lets = ""
    cur = "fs0"
    lets += f"        fs0 =\n            [ big ]\n\n"
    for si in range(len(steps)):
        lets += f"        fs{si + 1} =\n            List.map (\\h -> step{si} h base) fs{si}\n\n"
    exp = sum(pval(i) for i in range(n))
    body = f"""big : {sig}
big {params} =
    {summ}


{chr(10).join(fns)}

main =
    let
{BASE}{lets}{logs([("res", f"fs{len(steps)}")])}    in
    text "done"
"""
    out[name] = module(name, doc + timing_note, [f"res: [{exp}]"], body)

def ckind(i, special):
    return special.get(i, "Int")

sp63 = {19: "Float", 20: "Char", 24: "Float", 25: "Char", 51: "Float", 52: "Char", 62: "Float", 33: "String", 40: "Bool"}
staged("WideClosureArity63Test", 63, [ckind(i, sp63) for i in range(63)], [1, 7, 20, 20, 15],
       "Arity-63 closure extended 1 + 7 + 20 + 20 + 15 through eco_pap_extend, with\nFloat/Char params on both sides of slots 20, 25 and 52.")
sp300 = {i: k for i, k in zip(range(300), [kind(i) for i in range(300)])}
staged("WideClosureArity300Test", 300, [kind(i) for i in range(300)], [1, 7, 20, 63, 64, 65, 80],
       "Arity-300 mixed closure extended in steps 1/7/20/63/64/65/80 (root chunks over 64).")
staged("WideClosureArity2047Test", 2047, [kind(i) for i in range(2047)], [1, 7, 20, 63, 64, 65, 300, 1527],
       "Arity-2047 mixed closure (the stage-arity limit), extended in steps up to 1527.")

# ---- saturated wide records / ctors (green P3D) ------------------------------
def wide_record(name, n, kinds, show, doc, full=False):
    decl = fields_decl(n, kinds)
    vals = "\n        , ".join(f"f{i:04d} = {elm_val(i, kinds[i])}" for i in range(n))
    pairs = [(f"f{i:04d}", f"r.f{i:04d}") for i in show]
    checks = [f"f{i:04d}: {py_show(i, kinds[i])}" for i in show]
    last = n - 1
    pairs += [("pattern", f"viaPat r"), ("update", f"(upd r).f{last:04d}"),
              ("eq self", "r == make base"), ("eq updated", "r == upd r")]
    lk = kinds[last]
    upd_val = {"Int": "r.f%04d + 1" % last, "Float": "r.f%04d + 1" % last,
               "Char": "'!'", "String": "\"u\"", "Bool": "not r.f%04d" % last}[lk]
    upd_show = {"Int": str(1000 + last + 1), "Float": f"{last + 1}.5", "Char": "'!'",
                "String": "\"u\"", "Bool": "False" if last % 2 == 0 else "True"}[lk]
    checks += [f"pattern: ({py_show(0, kinds[0])}, {py_show(last, lk)})", f"update: {upd_show}",
               "eq self: True", "eq updated: False"]
    if full:
        pairs.append(("show", "r"))
        checks.append("show: { " + ", ".join(f"f{i:04d} = {py_show(i, kinds[i])}" for i in range(n)) + " }")
    body = f"""type alias R =
    {{ {decl}
    }}


make : Int -> R
make base =
    {{ {vals}
    }}


viaPat : R -> ( {kinds[0]}, {kinds[last]} )
viaPat {{ f0000, f{last:04d} }} =
    ( f0000, f{last:04d} )


upd : R -> R
upd r =
    {{ r | f{last:04d} = {upd_val} }}


main =
    let
{BASE}        r =
            make base

{logs(pairs)}    in
    text "done"
"""
    out[name] = module(name, doc, checks, body)

wide_record("WideRecord33Test", 33, [kind(i) for i in range(33)], [0, 31, 32],
            "33-field mixed record: access, pattern, update, ==, Debug.toString.", full=True)
wide_record("WideRecord40Test", 40, [kind(i) for i in range(40)], [0, 31, 32, 39],
            "40-field mixed record (second ext word boundary not reached; header + 1 ext word).", full=True)
wide_record("WideRecord600Test", 600, [kind(i) for i in range(600)], [0, 31, 32, 63, 64, 599],
            "600-field mixed record: inline-alloc bound (4096 B) exceeded -> eco_alloc_record call path.")
wide_record("WideRecord1100Test", 1100, [kind(i) for i in range(1100)], [0, 31, 32, 1023, 1024, 1099],
            "1100-field mixed record: > 8 KiB large object (nursery-large / YLOS).")

def wide_ctor(name, n, kinds, show, doc):
    tys = " ".join(kinds[i] if kinds[i] in ("Int", "Float", "Char", "String", "Bool") else kinds[i] for i in range(n))
    vals = " ".join(elm_val(i, kinds[i]) for i in range(n))
    pat = " ".join(f"x{i}" for i in range(n))
    fns = ""
    pairs, checks = [], []
    for i in show:
        fns += f"get{i} : W -> {kinds[i]}\nget{i} w =\n    case w of\n        W {pat} ->\n            x{i}\n\n\n"
        pairs.append((f"field{i}", f"get{i} w"))
        checks.append(f"field{i}: {py_show(i, kinds[i])}")
    pairs += [("eq self", "w == make base"), ("eq other", "w == make (base + 1)")]
    checks += ["eq self: True", "eq other: False"]
    if n <= 60:
        pairs.append(("show", "w"))
        checks.append("show: W " + " ".join(py_show(i, kinds[i]) for i in range(n)))
    body = f"""type W
    = W {tys}


make : Int -> W
make base =
    W {vals}


{fns}main =
    let
{BASE}        w =
            make base

{logs(pairs)}    in
    text "done"
"""
    out[name] = module(name, doc, checks, body)

wide_ctor("WideCtorMixedTest", 60, [kind(i) for i in range(60)], [23, 24, 55, 59],
          "60-field mixed constructor: case match on fields 23/24/55/59, ==, Debug.toString.")
wide_ctor("WideCtor1100Test", 1100, [kind(i) for i in range(1100)], [0, 23, 24, 56, 1099],
          "1100-field mixed constructor: large object.")


# ---- WideClosureGroupTest (B15; green P1) -------------------------------------
n, per = 66, 22
ps = " ".join(f"s{i}" for i in range(n))
sig = " -> ".join(["String"] * n + ["Int", "Int"])
def lens(j): return " + ".join(f"String.length s{i}" for i in range(per * j, per * j + per))
args = " ".join(f"(String.repeat (base + {i}) \"a\")" for i in range(n))
L1 = sum(1 + i for i in range(per, 2 * per))
body = f"""run : {sig}
run {ps} k =
    let
        f0 n =
            if n <= 0 then
                {lens(0)}

            else
                f1 (n - 1) + 1

        f1 n =
            if n <= 0 then
                {lens(1)}

            else
                f2 (n - 1) + 10

        f2 n =
            if n <= 0 then
                {lens(2)}

            else
                f0 (n - 1) + 100
    in
    f0 k


main =
    let
{BASE}{logs([("group", f"run {args} 4")])}    in
    text "done"
"""
out["WideClosureGroupTest"] = module("WideClosureGroupTest",
    "B15: three mutually recursive let-bound closures (one papCreateGroup), each\ncapturing 22 boxed Strings: 66 flat captures, more than one 64-slot root range.",
    [f"group: {L1 + 112}"], body)

elm_dir = sys.argv[1]
os.makedirs(elm_dir, exist_ok=True)
for name, src in out.items():
    with open(os.path.join(elm_dir, name + ".elm"), "w") as f:
        f.write(src)
print("\n".join(sorted(out)))

# ---- GC-stress pins for test/eco-kernel/src (Eco.GC.minorGC / majorGC) ------
def gc_pin(name, doc, decls, build_expr, read_expr, expected, green):
    body = f"""import Eco.GC as GC
import Platform
import Task


{decls}

type Msg
    = Done Int Int Int


churn : Int -> Int
churn k =
    List.range 1 (20000 + k) |> List.map String.fromInt |> List.length


init : () -> ( (), Cmd Msg )
init _ =
    let
        base =
            1 + List.length [ () ] - 1

        objs =
            {build_expr}

        task =
            GC.minorGC
                |> Task.andThen (\\mi -> GC.majorGC |> Task.map (\\ma -> ( mi.collected, ma.collected )))
                |> Task.map (\\( mi, ma ) -> Done mi ma (churn mi + {read_expr}))
    in
    ( (), Task.perform identity task )


update : Msg -> () -> ( (), Cmd Msg )
update msg _ =
    case msg of
        Done mi ma v ->
            let
                _ =
                    Debug.log "{name} minor" mi

                _ =
                    Debug.log "{name} major" ma

                _ =
                    Debug.log "{name} value" v
            in
            ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker {{ init = init, update = update, subscriptions = \\_ -> Sub.none }}
"""
    s = f"module {name} exposing (main)\n\n{{-| {doc} Green at {green}.\n-}}\n\n"
    s += f"-- CHECK: {name} minor: 1\n-- CHECK: {name} major: 1\n-- CHECK: {name} value: {expected}\n\n" + body
    gc_out[name] = s

gc_out = {}
# 200 arity-28 closures, each extended 20 then 7 (live across both GCs), then saturated.
n = 28
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["Int"] * (n + 1))
summ = " + ".join(f"a{i} * {i + 1}" for i in range(n))
first = " ".join(f"(k + {i})" for i in range(20))
step = " ".join(f"(k + {i})" for i in range(20, 27))
decls = f"""big : {sig}
big {params} =
    {summ}


mk : Int -> (Int -> Int)
mk k =
    let
        h =
            big {first}
    in
    h {step}
"""
def bigval(k, last): return sum((k + i) * (i + 1) for i in range(27)) + last * 28
exp = sum(bigval(k, 5) for k in range(1, 201)) + 20001
gc_pin("WideClosureGcTest", "200 arity-28 closures (typed kinds at slots 20..27) live across a minor and a\nmajor GC, then saturated.", decls,
       "List.map mk (List.range base 200)", "List.sum (List.map (\\g -> g 5) objs)", exp, "P2")

# 200 40-field mixed records + 200 60-field mixed ctors across GCs (green P3D).
kr = [kind(i) for i in range(40)]
kc = [kind(i) for i in range(60)]
def num(i, k, var):    # an Int contribution of field i read from var
    return {"Int": f"{var}", "Float": f"round ({var} * 2)", "Char": f"Char.toCode {var}",
            "String": f"String.length {var}", "Bool": f"(if {var} then 1 else 0)"}[k]
def pnum(i, k, b):
    return {"Int": b + 999 + i, "Float": round((b - 1 + i + 0.5) * 2), "Char": b + 96 + (i % 26),
            "String": len(f"{b - 1 + i}s"), "Bool": 1 if (b + i - 1) % 2 == 0 else 0}[k]
rdecl = fields_decl(40, kr)
rvals = "\n        , ".join(f"f{i:04d} = {elm_val(i, kr[i])}" for i in range(40))
rsum = "\n        + ".join(num(i, kr[i], f"r.f{i:04d}") for i in (0, 31, 32, 33, 38, 39))
ctys = " ".join(kc)
cvals = " ".join(elm_val(i, kc[i]) for i in range(60))
cpat = " ".join(f"x{i}" for i in range(60))
csum = "\n                + ".join(num(i, kc[i], f"x{i}") for i in (0, 23, 24, 25, 56, 59))
decls = f"""type alias R =
    {{ {rdecl}
    }}


type W
    = W {ctys}


mkR : Int -> R
mkR base =
    {{ {rvals}
    }}


mkW : Int -> W
mkW base =
    W {cvals}


readR : R -> Int
readR r =
    {rsum}


readW : W -> Int
readW w =
    case w of
        W {cpat} ->
            {csum}
"""
exp = sum(sum(pnum(i, kr[i], b) for i in (0, 31, 32, 33, 38, 39)) +
          sum(pnum(i, kc[i], b) for i in (0, 23, 24, 25, 56, 59)) for b in range(1, 201)) + 20001
gc_pin("WideHeapGcTest", "200 40-field records and 200 60-field constructors (mixed kinds) live across a\nminor and a major GC.", decls,
       "List.map (\\b -> ( mkR b, mkW b )) (List.range base 200)",
       "List.sum (List.map (\\( r, w ) -> readR r + readW w) objs)", exp, "P3D")

kdir = sys.argv[2] if len(sys.argv) > 2 else None
if kdir:
    os.makedirs(kdir, exist_ok=True)
    for name, src in gc_out.items():
        with open(os.path.join(kdir, name + ".elm"), "w") as f:
            f.write(src)
    print("\n".join(sorted(gc_out)))
