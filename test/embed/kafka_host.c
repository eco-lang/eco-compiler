/* C host for the elm-actor-kafka worker example — the native equivalent of
 * its Node index.ts:
 *   - logPort messages -> stdout
 *   - notifyP2PSend -> bounced back into onP2PSend (port-bounce delivery)
 *   - runs ~3 seconds, then stops
 *
 * Build:
 *   cc kafka_host.c -L<dir> -l:libkafka.so -o kafka_host -Wl,-rpath,<dir>
 */

#include <stdio.h>
#include <unistd.h>

#include "../../runtime/src/embed/eco_embed.h"

static void on_log(const char* json, void* user) {
    (void)user;
    printf("LOG %s\n", json);
    fflush(stdout);
}

static void on_notify(const char* json, void* user) {
    (void)user;
    /* Echo notifyP2PSend back through onP2PSend (port-bounce). */
    eco_port_send("onP2PSend", json);
}

int main(int argc, char** argv) {
    eco_port_subscribe("logPort", on_log, NULL);
    eco_port_subscribe("notifyP2PSend", on_notify, NULL);

    if (eco_app_start(argc, argv, NULL) != 0) {
        fprintf(stderr, "eco_app_start failed\n");
        return 1;
    }

    printf("HOST started; %d ports registered\n", eco_port_count());
    fflush(stdout);

    sleep(3);

    printf("HOST stopping\n");
    fflush(stdout);
    eco_app_stop();
    return eco_app_join() == 0 ? 0 : 1;
}
