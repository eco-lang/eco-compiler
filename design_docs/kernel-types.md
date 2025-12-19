A cleaner alternative (less invasive than changing Can.Type)
Instead of inventing fake TVar names, I’d recommend making kernel symbols typed the same way “foreign/imported” symbols are typed: by attaching a known type scheme/type from the environment. That is exactly what canonicalization already does for non-kernel foreigns (Env.Foreign home annotation -> Can.VarForeign home name annotation) .

Concretely:

Introduce a place to look up kernel symbol types (like an interface/env table for kernel modules).
In typed optimization, produce TOpt.VarKernel region home name funcCanType with a real Can.Type (likely a TLambda ... chain), not a placeholder.
Then monomorphization’s kernel-call instantiation logic works as intended .
This stays within the existing “typed backends need real types” story (TypedOptimized always stores a Can.Type and encodes it using Can.typeEncoder ) without needing to extend the canonical type language.
