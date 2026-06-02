/* Shim helpers used by Akamata's Zig sqlite bindings. SQLITE_TRANSIENT is the
 * sentinel `((sqlite3_destructor_type)-1)`; constructing it directly in Zig
 * trips 0.16's strict alignment checks for function pointers, so we expose a
 * tiny C helper instead. */

#include "sqlite3.h"

sqlite3_destructor_type akamata_sqlite_transient(void) {
    return SQLITE_TRANSIENT;
}
