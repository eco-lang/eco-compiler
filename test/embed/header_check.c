/* Compiles <eco/eco_embed.h> alone, as C99 with warnings as errors, to show it is self-contained
 * (plans/native-bytes-ports-2.md §4 step 9). Built by the embed-header-c target; never linked. */
#include <eco/eco_embed.h>

int eco_header_check_c(void) {
    return ECO_PORT_IN_BYTES + ECO_EMIT_QUEUED + (int)sizeof(eco_bytes_fill);
}
