; =============================================================================
; routes.asm — KvServer's routes: the engine's route table (ga_app_routes).
;
; hpack.asm looks every new :path up here (grpcasm_routes.inc: exact match,
; first entry wins) and stores the route byte in Stream.method; grpc.asm
; then compares it with the M_* numbers of kvasm.inc. Anything not listed is
; UNIMPLEMENTED, and the health check (/grpc.health.v1.Health/Check) is the
; engine's own. These are exactly the paths KvAsm's hpack.asm recognized
; through its "/kvasm.v1.KvAsm/" prefix and method names (KvAsm 60d7e81),
; so KvAsm's suite still pins them.
; =============================================================================

default rel
bits 64

%include "kvasm.inc"

section .rodata
global ga_app_routes:data
ga_app_routes:
    GA_ROUTE "/kvasm.v1.KvAsm/Get",      M_GET
    GA_ROUTE "/kvasm.v1.KvAsm/Put",      M_PUT
    GA_ROUTE "/kvasm.v1.KvAsm/Delete",   M_DELETE
    GA_ROUTE "/kvasm.v1.KvAsm/Upload",   M_UPLOAD      ; client streaming
    GA_ROUTE "/kvasm.v1.KvAsm/Download", M_DOWNLOAD    ; server streaming
    GA_ROUTES_END

section .note.GNU-stack noalloc noexec nowrite progbits
