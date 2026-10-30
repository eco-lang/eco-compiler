# Unicode Character Database files

Vendored data from the Unicode Character Database, used only by
`compiler/scripts/gen-casemap-tables.mjs` to generate `runtime/src/allocator/CaseMapTables.hpp`
(the Unicode simple case mapping, plans/char-simple-case-mapping.md,
design_docs/char-case-mapping.md). Nothing here is compiled, installed or bundled.

| File | Version | Source | sha256 | Fetched |
|---|---|---|---|---|
| `17.0.0/UnicodeData.txt` | 17.0.0 | https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt | `2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c` | 2026-10-30 |

`LICENSE.TXT` is the Unicode License v3 (https://www.unicode.org/license.txt), which covers these
data files.

To add a version: `runtime/third_party/unicode/update.sh <version>` downloads `UnicodeData.txt`
into `<version>/` and prints its sha256. Then follow design_docs/char-case-mapping.md, "Updating to
a new Unicode version".
