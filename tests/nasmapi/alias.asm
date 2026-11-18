; =============================================================================
; alias.asm — grpcasm.inc's zero-instruction dispatch, under test
; (tests/nasmapi.sh): one unary and one client-streaming method, so
; ga_app_unary, ga_app_stream_data and ga_app_stream_end must be the handlers
; themselves (`equ` aliases). The handlers are exported, so the C driver can
; compare addresses; GA_USES_HOOK batch_end checks that a hook the
; application writes itself is not generated as well.
; =============================================================================

default rel
bits 64

%include "grpcasm.inc"

GA_SERVICE "test.Alias"
    GA_UNARY         "One", h_one
    GA_CLIENT_STREAM "Up", h_up_data, h_up_end
GA_SERVICE_END
GA_USES_HOOK batch_end
GA_APP_END

section .bss
global hit:data
hit:    resq 1

section .text
global h_one:function
global h_up_data:function
global h_up_end:function
global ga_app_batch_end:function

%macro HANDLER 2
%1:
    mov     qword [hit], %2
    mov     eax, %2
    ret
%endmacro

HANDLER h_one, 1
HANDLER h_up_data, 100
HANDLER h_up_end, 101
; The application's own batch_end (GA_USES_HOOK): returns 77, not the default 0.
HANDLER ga_app_batch_end, 77

section .note.GNU-stack noalloc noexec nowrite progbits
