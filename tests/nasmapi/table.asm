; =============================================================================
; table.asm — grpcasm.inc's jump-table dispatch and its other generated code,
; under test (tests/nasmapi.sh).
;
; Seven unary methods (more than GA_CHAIN_MAX: a jump table), one with an
; explicit route number; two client-streaming methods (a compare chain over
; their two end handlers, both data payloads going to one shared handler);
; two services (the health check knows both). Every handler records which one
; ran in `hit` and returns its number, so the C driver can call the generated
; hooks with a fake Stream and see where each route lands.
; =============================================================================

default rel
bits 64

%include "grpcasm.inc"

GA_SERVICE "test.Api"
    GA_UNARY         "U1", h_u1
    GA_UNARY         "U2", h_u2
    GA_UNARY         "U3", h_u3
    GA_CLIENT_STREAM "S1", h_sdata, h_s1end
    GA_UNARY         "U4", h_u4
    GA_UNARY         "U5", h_u5
    GA_CLIENT_STREAM "S2", h_sdata, h_s2end
GA_SERVICE_END
GA_SERVICE "test.Other"
    GA_UNARY         "U6", h_u6
    GA_UNARY         "U7", h_u7, 40         ; an explicit route number
GA_SERVICE_END
GA_APP_END

section .bss
global hit:data
hit:    resq 1                          ; the number of the last handler that ran

section .text

; HANDLER label, number — a handler that records its number and returns it.
%macro HANDLER 2
%1:
    mov     qword [hit], %2
    mov     eax, %2
    ret
%endmacro

HANDLER h_u1, 1
HANDLER h_u2, 2
HANDLER h_u3, 3
HANDLER h_u4, 4
HANDLER h_u5, 5
HANDLER h_u6, 6
HANDLER h_u7, 7
HANDLER h_sdata, 100
HANDLER h_s1end, 101
HANDLER h_s2end, 102

section .note.GNU-stack noalloc noexec nowrite progbits
