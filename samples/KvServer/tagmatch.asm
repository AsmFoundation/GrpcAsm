; =============================================================================
; tagmatch.asm — SWAR tag matching of the KV store's buckets (KvServer).
;
; Moved unchanged from the engine's util.asm (KvAsm 60d7e81), where it sat beside
; ga_keyeq: the engine itself never uses it. cuckoo.asm inlines the same
; sequence; this exported copy exists for KvAsm's unit test.
; =============================================================================

default rel
bits 64

section .text

global kv_tag_match

; =============================================================================
; kv_tag_match — which of 8 packed one-byte tags equal `tag`?
;
; @param  rdi  uint64_t tags (byte i = tag of slot i)
; @param  rsi  tag to find (low 8 bits used; 0 finds empty slots)
; @returns rax = 0x80 in every byte whose tag equals `tag`, 0 elsewhere.
; @remarks Exact per byte (no false positives), 64-bit GPR arithmetic only:
;            x = tags ^ broadcast(tag)          ; equal bytes become 0x00
;            y = (x & 0x7F..7F) + 0x7F..7F      ; bit7 set iff low 7 bits != 0
;            r = ~(y | x | 0x7F..7F)            ; bit7 set iff byte == 0
;          The add cannot carry across bytes (max 0x7F + 0x7F = 0xFE), unlike
;          the popular (x - 0x01..) & ~x & 0x80.. form, which can also flag
;          the byte above a real match. cuckoo.asm inlines the same sequence;
;          this exported copy exists for the unit test.
; =============================================================================
kv_tag_match:
    movzx   esi, sil
    mov     rax, 0x0101010101010101
    imul    rsi, rax
    xor     rdi, rsi
    mov     rax, 0x7F7F7F7F7F7F7F7F
    mov     rcx, rdi
    and     rcx, rax
    add     rcx, rax
    or      rcx, rdi
    or      rcx, rax
    not     rcx
    mov     rax, rcx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
