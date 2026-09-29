---------------------- MODULE TracePromoBitmapData ----------------------
(***************************************************************************)
(* The M4 trace's heap and run, read from the log (TracePromoBitmap.tla   *)
(* uses them). A module of its own that TracePromoBitmap EXTENDS before    *)
(* PromoBitmap: TLC evaluates and caches zero-arity definitions module by  *)
(* module at start-up, and PromoBitmap's own definitions (InitSwept,       *)
(* Threads, ...) reach these through the .cfg's bindings. Defined after    *)
(* PromoBitmap, each such reference re-read and re-parsed the whole log    *)
(* (start-up took over ten minutes; AUDIT.md, trace wave).                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC, TraceLog

H == TraceHdr
\* The log, read once into a definition of this module: definitions that scan
\* TraceLog at start-up re-read the file for every element (AUDIT.md).
ML == ndJsonDeserialize(TraceFile)
MLen == Len(ML) - 1
MEv(i) == ML[i + 1]

\* ---- the heap, from the header (cached zero-arity definitions; the .cfg   ----
\* ---- binds the model's constants to the TPA_ aliases, see AUDIT.md)      ----
Blk(id) == "b" \o ToString(id)
Cid(blk, bit) == blk * 10000 + bit
ByteKey(c) == "y" \o ToString(c \div 10000) \o "." \o ToString((c % 10000) \div 8)
WordKey(c) == (c \div 10000) * 100000 + (c % 10000) \div 64
Recs == {H.blocks[j] : j \in DOMAIN H.blocks}
SeqSet(sq) == {sq[k] : k \in DOMAIN sq}

\* Virgin blocks: startVirginBlockShared's fresh blocks, uniform blocks of the
\* class, in the order the log publishes them (they are not in the header).
HdrIds == {r.id : r \in Recs}
PubIdx == {i \in 1..MLen : MEv(i).ev = "m4.pub" /\ MEv(i).blk \notin HdrIds}
\* (a function constructor, not a recursive definition: TLC re-reads the log
\* inside a recursive one at start-up, AUDIT.md)
TP_VirginIds == [k \in 1..Cardinality(PubIdx) |->
                   MEv(CHOOSE j \in PubIdx : Cardinality({x \in PubIdx : x < j}) = k - 1).blk]
TP_Virgin == [k \in DOMAIN TP_VirginIds |-> Blk(TP_VirginIds[k])]
VCells(id) == {Cid(id, k * H.stride) : k \in 0..(H.cpb - 1)}
VUnits(id) == [u \in 1..((H.cpb + 63) \div 64) |->
                 {Cid(id, k * H.stride) : k \in ((u - 1) * 64)..(IF u * 64 < H.cpb THEN u * 64 - 1 ELSE H.cpb - 1)}]

TP_Threads == H.threads
TP_Workers == 1..Len(TP_Threads)
TP_MergeId == Len(TP_Threads) + 1
TP_HdrBlocks == {r.b : r \in Recs}
TP_Blocks == TP_HdrBlocks \cup {TP_Virgin[k] : k \in DOMAIN TP_Virgin}
TP_Mixed == {r.b : r \in {q \in Recs : q.mixed}}
TP_Cells == UNION {SeqSet(r.cells) : r \in Recs} \cup UNION {VCells(TP_VirginIds[k]) : k \in DOMAIN TP_VirginIds}
TP_SetCells == UNION {SeqSet(r.set) : r \in Recs}
TP_CellBlock == [c \in TP_Cells |-> "b" \o ToString(c \div 10000)]
TP_CellByte == [c \in TP_Cells |-> ByteKey(c)]
TP_Bytes == {ByteKey(c) : c \in TP_Cells}
TP_ByteWord == [y \in TP_Bytes |->
                   LET c0 == CHOOSE c \in TP_Cells : ByteKey(c) = y
                   IN {ByteKey(d) : d \in {x \in TP_Cells : WordKey(x) = WordKey(c0)}}]
RecOf(b) == CHOOSE r \in Recs : r.b = b
TP_Units == [b \in TP_Blocks |->
                IF b \in TP_HdrBlocks
                THEN LET r == RecOf(b)
                     IN [u \in DOMAIN r.units |-> {c \in TP_Cells : r.units[u][1] <= c /\ c <= r.units[u][2]}]
                ELSE VUnits(CHOOSE id \in SeqSet(TP_VirginIds) : Blk(id) = b)]
TP_PastEnd == [b \in TP_Blocks |-> {}]
TP_InitBits == [y \in TP_Bytes |-> {c \in TP_SetCells : ByteKey(c) = y}]
TP_InitFree == H.free
TP_InitQ == H.items
TP_InitShared == H.shared
TP_InitPartial == H.partial
TP_InitLive == [b \in TP_Blocks |-> IF b \in TP_HdrBlocks THEN RecOf(b).live ELSE 0]
TP_PreAlloc == SeqSet(H.prealloc)
TP_InitPhase == CASE H.phase = 0 -> "Idle" [] H.phase = 1 -> "Marking" [] OTHER -> "Sweeping"
\* Promotions each thread made: the events that end one.
IsPromo(e) == \/ e.ev \in {"m4.rph", "m4.finb", "m4.pop"}
              \/ e.ev = "m4.fin" /\ ~e.black
TP_NAllocs == [w \in TP_Workers |->
                 Cardinality({i \in 1..MLen : MEv(i).t = TP_Threads[w] /\ IsPromo(MEv(i))})]
TP_Mergers == {TP_MergeId}

\* Aliases: a constant bound by `<-` to a definition is re-evaluated at every
\* use, but the definitions it names are cached (AUDIT.md, trace wave).
TPA_Workers == TP_Workers
TPA_Mergers == TP_Mergers
TPA_NAllocs == TP_NAllocs
TPA_Cells == TP_Cells
TPA_Blocks == TP_Blocks
TPA_Bytes == TP_Bytes
TPA_CellBlock == TP_CellBlock
TPA_CellByte == TP_CellByte
TPA_ByteWord == TP_ByteWord
TPA_Mixed == TP_Mixed
TPA_Units == TP_Units
TPA_PastEnd == TP_PastEnd
TPA_InitBits == TP_InitBits
TPA_InitFree == TP_InitFree
TPA_InitQ == TP_InitQ
TPA_InitShared == TP_InitShared
TPA_InitPartial == TP_InitPartial
TPA_InitLive == TP_InitLive
TPA_PreAlloc == TP_PreAlloc
TPA_InitPhase == TP_InitPhase
TPA_Virgin == TP_Virgin

=============================================================================
