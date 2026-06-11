/* C host for the PortEchoTest program compiled as a shared library.
 *
 * Exercises the Phase 3 embedding API end-to-end:
 *   - pre-start subscribe (placeholder registry entry)
 *   - eco_app_start ready handshake (init effects dispatched before return)
 *   - buffer-until-first-subscribe semantics
 *   - port introspection
 *   - eco_port_send -> decode -> tagger -> update round trip
 *   - cooperative eco_app_stop / eco_app_join
 *
 * Build:
 *   cc echo_host.c -L<dir> -l:libecho.so -o echo_host -Wl,-rpath,<dir>
 *
 * Expected output lines (asserted by the harness):
 *   HOST echoOut: 42
 *   HOST done
 *   HOST ports: echoOut=out echoIn=in
 *   HOST exit: 0
 */

#include <stdio.h>
#include <string.h>

#include "../../runtime/src/embed/eco_embed.h"

static int got_echo = 0;

static void on_echo_out(const char* json, void* user) {
    (void)user;
    printf("HOST echoOut: %s\n", json);
    fflush(stdout);
    got_echo = 1;
    /* Bounce it back into the program (the Elm side logs + finishes). */
    eco_port_send("echoIn", json);
}

int main(int argc, char** argv) {
    /* Subscribe BEFORE start: the program's init command (echoOut 42) must
     * reach us even though it fires during initialization. */
    eco_port_subscribe("echoOut", on_echo_out, NULL);

    if (eco_app_start(argc, argv, NULL) != 0) {
        fprintf(stderr, "eco_app_start failed\n");
        return 1;
    }

    /* Ready handshake guarantees registration completed. */
    int in = eco_port_is_incoming("echoIn");
    int out = eco_port_is_incoming("echoOut");
    printf("HOST ports: echoOut=%s echoIn=%s\n",
           out == 0 ? "out" : "BAD",
           in == 1 ? "in" : "BAD");
    fflush(stdout);

    if (!got_echo) {
        fprintf(stderr, "HOST error: init-time echoOut message not seen\n");
        return 1;
    }
    printf("HOST done\n");
    fflush(stdout);

    eco_app_stop();
    int code = eco_app_join();
    printf("HOST exit: %d\n", code);
    return 0;
}
