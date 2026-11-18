; =============================================================================
; pb.asm — protobuf helpers of the engine that any program may use: the
; server's health check, the C ABI (grpcasm_pb_bytes), applications, and
; programs that only use the client.
;
;   ga_pb_field_bytes   find a length-delimited field of a protobuf message,
;                       zero-copy, after checking the whole message
;
; Why a file of its own: until milestone D this code sat in grpc.asm, the
; server's call layer. A program that linked it for the decoder alone then
; pulled in grpc.o and, through it, every server hook (ga_app_unary and the
; rest): a client-only program could not link. Moved here unchanged; grpc.asm
; calls it as an external function, which a static link binds directly.
;
; Threading: none needed; pure functions of their arguments.
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"

global ga_pb_field_bytes:function

section .text

; =============================================================================
; ga_pb_field_bytes — the last occurrence of a length-delimited field (bytes,
; string, an embedded message) of a protobuf message, once the whole message
; has been checked.
; @param  rdi  the message (may be anything when the length is 0)
; @param  rsi  its length
; @param  edx  the field number (1 .. 2^29 - 1)
; @returns rax = 0 with rdx = the field's bytes and rcx = their length (both 0
;          when the field is absent), or rax = -EINVAL for a malformed
;          message. Clobbers rsi, rdi, r8-r11; preserves rbx.
; @remarks The rules of KvServer's kv_pb_decode_kv field loop, so the health
;          check accepts and refuses exactly what KvAsm's did: unknown fields
;          of wire types 0, 1, 2 and 5 are skipped; groups (3, 4), the
;          undefined types (6, 7), field number 0, tags above 2^32 - 1, and
;          any varint or length that runs past the end are malformed; the
;          field with another wire type counts as an unknown field; a repeated
;          field replaces the earlier one (protobuf's last-wins). Every length
;          is checked against the bytes left before a pointer is formed from
;          it. Zero-copy: the result points into the message. One pass, no
;          allocation; no stack alignment needed (it calls only a leaf).
; =============================================================================
ga_pb_field_bytes:
    push    rbx
    mov     ebx, edx                    ; the wanted field, kept across pb_read_varint
    lea     rdx, [rdi + rsi]            ; end
    mov     rsi, rdi                    ; cursor
    xor     r10d, r10d                  ; the field's bytes (0 = absent)
    xor     edi, edi                    ; the field's length
.field:
    cmp     rsi, rdx
    jae     .ok                         ; clean end of message
    call    pb_read_varint              ; tag
    jc      .bad
    mov     r11, rax
    shr     r11, 3                      ; field number
    jz      .bad                        ; field 0 is invalid
    mov     rcx, 0xFFFFFFFF
    cmp     rax, rcx
    ja      .bad                        ; field numbers are < 2^29
    and     eax, 7                      ; wire type
    cmp     eax, 2
    je      .length_delimited
    test    eax, eax
    je      .skip_varint
    cmp     eax, 1
    je      .skip_fixed64
    cmp     eax, 5
    je      .skip_fixed32
    jmp     .bad                        ; 3/4 (groups), 6/7 (undefined)
.skip_varint:
    call    pb_read_varint
    jc      .bad
    jmp     .field
.skip_fixed64:
    mov     rcx, rdx
    sub     rcx, rsi
    cmp     rcx, 8
    jb      .bad
    add     rsi, 8
    jmp     .field
.skip_fixed32:
    mov     rcx, rdx
    sub     rcx, rsi
    cmp     rcx, 4
    jb      .bad
    add     rsi, 4
    jmp     .field
.length_delimited:
    call    pb_read_varint              ; payload length
    jc      .bad
    mov     rcx, rdx
    sub     rcx, rsi                    ; bytes remaining
    cmp     rax, rcx
    ja      .bad                        ; checked before rsi + rax is ever formed
    cmp     r11, rbx
    jne     .skip_bytes
    mov     r10, rsi                    ; the wanted field: remember it (last wins)
    mov     rdi, rax
.skip_bytes:
    add     rsi, rax
    jmp     .field
.ok:
    mov     rdx, r10
    mov     rcx, rdi
    xor     eax, eax
    pop     rbx
    ret
.bad:
    mov     rax, -EINVAL
    pop     rbx
    ret

; =============================================================================
; pb_read_varint — read one base-128 varint. Internal, leaf.
; @param  rsi  cursor (advanced past the varint on success)
; @param  rdx  end of the message
; @returns rax = value, CF = 0 on success; CF = 1 if the varint is truncated,
;          longer than 10 bytes, or does not fit in 64 bits.
; @remarks Clobbers rax, rcx, r8, r9 only (ga_pb_field_bytes keeps its state
;          in rbx, rdi, r10 and r11). The same code as KvServer's proto.asm.
; =============================================================================
pb_read_varint:
    xor     eax, eax
    xor     ecx, ecx                    ; shift
.byte:
    cmp     rsi, rdx
    jae     .err                        ; truncated
    movzx   r8d, byte [rsi]
    inc     rsi
    mov     r9d, r8d
    and     r9d, 0x7F
    cmp     ecx, 63
    jne     .fits
    cmp     r9d, 1                      ; the 10th byte may only carry bit 63
    ja      .err
.fits:
    shl     r9, cl
    or      rax, r9
    test    r8b, 0x80
    jz      .done
    add     ecx, 7
    cmp     ecx, 63
    ja      .err                        ; an 11th byte would be needed
    jmp     .byte
.done:
    clc
    ret
.err:
    stc
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
