; =============================================================================
; chain.asm — grpcasm.inc's compare-chain dispatch, under test
; (tests/nasmapi.sh): three unary methods (at most GA_CHAIN_MAX), no
; client-streaming method (the streaming hooks are the -1 stubs). Handlers
; record their number in `hit`, as in table.asm.
; =============================================================================

default rel
bits 64

%include "grpcasm.inc"

GA_SERVICE "test.Chain"
    GA_UNARY "A", h_a, 7
    GA_UNARY "B", h_b
    GA_UNARY "C", h_c
GA_SERVICE_END
GA_APP_END

section .bss
global hit:data
hit:    resq 1

section .text

%macro HANDLER 2
%1:
    mov     qword [hit], %2
    mov     eax, %2
    ret
%endmacro

HANDLER h_a, 1
HANDLER h_b, 2
HANDLER h_c, 3

section .note.GNU-stack noalloc noexec nowrite progbits
