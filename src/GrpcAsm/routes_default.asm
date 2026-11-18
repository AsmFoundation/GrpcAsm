; =============================================================================
; routes_default.asm — an empty route table, for programs that link the
; engine without serving.
;
; Why it exists: hpack.asm classifies every :path it decodes against the
; application's ga_app_routes (grpcasm_routes.inc), so any program that links
; the HPACK decoder needs that symbol. A server defines its table. A program
; that only uses the client (client.asm decodes response headers with the same
; decoder) has no routes to declare. It would fail to link with "undefined
; symbol: ga_app_routes" unless it wrote an empty table for nothing.
;
; How it stays out of servers' way: this object is a member of libgrpcasm.a
; and defines nothing else. A static archive's member is linked only to
; resolve a symbol that is still undefined. A server's own ga_app_routes is
; therefore always the one used, and this member is never pulled in. A
; client-only program pulls it in automatically.
;
; Footgun: do not add other symbols here. Anything that pulls this member in
; for another reason would make it clash with a server's own ga_app_routes
; ("duplicate symbol").
; =============================================================================

default rel
bits 64

%include "grpcasm_routes.inc"

global ga_app_routes

section .rodata
; No entries: every :path is GA_ROUTE_UNKNOWN (a client never sees one; a
; server built without routes answers UNIMPLEMENTED to everything but the
; health check).
ga_app_routes:
    GA_ROUTES_END

section .note.GNU-stack noalloc noexec nowrite progbits
