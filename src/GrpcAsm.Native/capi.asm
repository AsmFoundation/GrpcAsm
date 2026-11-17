; =============================================================================
; capi.asm — GrpcAsm's C ABI (include/grpcasm.h): the engine as a library
; that C, .NET and Python programs drive at run time.
;
; The adapter is an application of the engine like KvServer or the Greeter,
; except that what those fix at assembly time (the route table, the methods)
; arrives at run time: grpcasm_server_add_unary records a path and a handler
; in the server object, in GA_ROUTE's byte format; grpcasm_server_start
; copies them into the engine's ga_app_routes and into the handler and
; context arrays, then starts the engine (ga_server_start). From then on a
; call costs, beyond the engine: one load of the handler and one of its
; context by route byte, and one indirect call.
;
; One started server per process: the engine binds its hooks and route table
; at link time, so g_server (claimed with a lock cmpxchg) says which server
; owns them; a second start returns -EBUSY until the first one stops.
;
; Calls: ga_app_unary builds the grpcasm_call (CCall) in its own frame and
; passes its address to the handler. grpcasm_call_reply and grpcasm_call_fail
; answer through it and mark it answered there, never in the Stream, which
; the engine may free the moment the answer is complete. After the handler,
; an unanswered call gets INTERNAL instead of a stream left open forever.
;
; Exports: only grpcasm.h's functions (grpcasm.map); the engine's ga_* and
; the hooks are local to the library (-Bsymbolic, version script).
; =============================================================================

default rel
bits 64

%include "grpcasm_sys.inc"
%include "server.inc"
%include "grpcasm_reply.inc"
%include "log.inc"

%define EIO             5
%define EBUSY           16
%define EEXIST          17
%define EMSGSIZE        90
%define EADDRINUSE      98
%define EALREADY        114

%define SIGINT          2
%define SIGTERM         15
%define SIG_BLOCK       0

%define VERSION_WORD    ((0 << 16) | (1 << 8) | 0)  ; GRPCASM_VERSION_* of grpcasm.h

%define MAX_ROUTES      GA_ROUTE_MAX                ; 62 methods
%define ROUTES_BYTES    (MAX_ROUTES * 257 + 1)      ; 62 x [len][route][255 bytes] + the end
%define MSG_MAX         1024                        ; grpc-message bytes sent, at most

%define STATE_NEW       0
%define STATE_RUNNING   1
%define STATE_STOPPED   2

; grpcasm_options (grpcasm.h): u32 fields at these offsets.
%define OPT_SIZE        0
%define OPT_PORT        4
%define OPT_WORKERS     8
%define OPT_STREAMS     12
%define OPT_CONNS       16
%define OPT_IDLE        20
%define OPT_GRACE       24
%define OPT_BUFFER      28
%define OPT_MAXMSG      32

; ---- CServer: a grpcasm_server ------------------------------------------------
struc CServer
    .cfg:       resb Config_size        ; the engine's Config (valid while running)
    .state:     resq 1                  ; STATE_*
    .engine:    resq 1                  ; GaServer* while running
    .nroutes:   resq 1                  ; methods registered (route numbers 1..nroutes)
    .rbytes:    resq 1                  ; bytes of .routes in use (without the end)
    .handlers:  resq MAX_ROUTES + 1     ; by route number; [0] unused
    .contexts:  resq MAX_ROUTES + 1
    .routes:    resb ROUTES_BYTES       ; GA_ROUTE format: [len][route][path]...
endstruc

; ---- CCall: a grpcasm_call, in ga_app_unary's frame -----------------------------
struc CCall
    .conn:      resq 1
    .stream:    resq 1
    .state:     resq 1                  ; 0 unanswered, 1 answered, -1 answering failed
endstruc

extern calloc
extern free
extern memcpy
extern sigemptyset
extern sigaddset
extern pthread_sigmask
extern sigwaitinfo
extern ga_server_start
extern ga_server_stop
extern ga_port_probe
extern ga_h2n_reply_parts
extern ga_grpc_refuse
extern ga_pb_field_bytes
extern ga_keyeq
extern ga_logb_init
extern ga_logb_str
extern ga_logb_u64
extern ga_logb_emit

section .rodata
lvl_info:   db "INFO", 0
lvl_error:  db "ERROR", 0
m_shutdown: db ' msg="shutdown requested" signal='
L_shutdown  equ $ - m_shutdown
m_f_port:   db ' msg="port already in use, refusing to share it"'
L_f_port    equ $ - m_f_port
k_port:     db " port="
k_errno:    db " errno="
hexdigits:  db "0123456789ABCDEF"
; The header fields of grpcasm_call_fail's Trailers-Only answer (their values
; that vary, the status digits and the message, are built in its frame).
CSTR s_status,      ":status"
CSTR s_200,         "200"
CSTR s_ctype,       "content-type"
CSTR s_ctype_grpc,  "application/grpc"
CSTR s_gstatus,     "grpc-status"
CSTR s_gmessage,    "grpc-message"
m_noreply:  db "handler returned without a reply", 0

section .bss align=64
; The engine's route table (grpcasm_routes.inc format), filled by
; grpcasm_server_start before any worker exists, read-only while it runs.
; Zero-filled: an empty table until then.
global ga_app_routes:data
ga_app_routes:  resb ROUTES_BYTES
alignb 8
g_handlers:     resq MAX_ROUTES + 1     ; the running server's, by route number
g_contexts:     resq MAX_ROUTES + 1
g_server:       resq 1                  ; the running CServer*, or 0

section .text

global grpcasm_version:function
global grpcasm_server_new:function
global grpcasm_server_add_unary:function
global grpcasm_server_start:function
global grpcasm_server_stop:function
global grpcasm_server_run:function
global grpcasm_server_free:function
global grpcasm_call_reply:function
global grpcasm_call_fail:function
global grpcasm_pb_bytes:function
; The engine's hooks (grpcasm_hooks.inc); local to the library (grpcasm.map).
global ga_app_unary:function
global ga_app_stream_data:function
global ga_app_stream_end:function
global ga_app_stream_fill:function
global ga_app_batch_end:function
global ga_app_call_release:function
global ga_app_health_service:function
global ga_app_worker_init:function
global ga_app_worker_fini:function
global ga_app_worker_resume:function
global ga_app_worker_pause:function
global ga_app_worker_tick:function

; =============================================================================
; grpcasm_version — (major << 16) | (minor << 8) | patch.
; @returns eax = the version word.
; =============================================================================
grpcasm_version:
    mov     eax, VERSION_WORD
    ret

; -----------------------------------------------------------------------------
; OPTION offset, default, min, max — one grpcasm_options field into eax, for
; grpcasm_server_new (r12 = the options or NULL): the default when there are
; no options, when the caller's struct is too old to have the field, or when
; it is 0; otherwise the value if it lies in [min, max], else .einval.
; Clobbers eax, ecx.
; -----------------------------------------------------------------------------
%macro OPTION 4
    mov     eax, %2
    test    r12, r12
    jz      %%have
    cmp     dword [r12 + OPT_SIZE], %1 + 4
    jb      %%have                      ; the caller's struct predates this field
    mov     ecx, [r12 + %1]
    test    ecx, ecx
    jz      %%have                      ; 0: the default
    cmp     ecx, %3
    jb      .einval
    cmp     ecx, %4
    ja      .einval
    mov     eax, ecx
%%have:
%endmacro

; =============================================================================
; grpcasm_server_new — create a server from options (see grpcasm.h).
; @param  rdi  const grpcasm_options* or NULL   @param rsi  grpcasm_server** out
; @returns eax = 0, -EINVAL or -ENOMEM.
; @remarks Only the fields the caller's struct has (options->size) are read:
;          an older caller gets the defaults for fields added since. Every
;          value is range-checked here, so a server that exists is one the
;          engine can run. The Config it fills is the engine's (server.inc).
; =============================================================================
grpcasm_server_new:
    push    rbx
    push    r12
    push    r13                         ; 3 pushes: rsp 16-aligned for calls
    mov     r12, rdi                    ; options, or NULL
    mov     r13, rsi                    ; out
    test    r13, r13
    jz      .einval_early
    mov     qword [r13], 0
    test    r12, r12
    jz      .alloc
    cmp     dword [r12 + OPT_SIZE], 4
    jb      .einval_early               ; a size that does not even cover itself
.alloc:
    mov     edi, 1
    mov     esi, CServer_size
    call    calloc wrt ..plt
    test    rax, rax
    jz      .enomem
    mov     rbx, rax                    ; CServer*, every field 0 (STATE_NEW)

    OPTION  OPT_PORT, 50051, 1, 65535
    mov     [rbx + CServer.cfg + Config.port], rax
    OPTION  OPT_WORKERS, 1, 1, 256
    mov     [rbx + CServer.cfg + Config.workers], rax
    OPTION  OPT_STREAMS, 100, 1, 1000
    mov     [rbx + CServer.cfg + Config.max_streams], rax
    OPTION  OPT_CONNS, 10000, 1, 1000000
    mov     [rbx + CServer.cfg + Config.max_conns], rax
    ; idle_timeout_seconds: 0 is the default (300 s), UINT32_MAX means never
    ; (the engine's 0), anything else 1..86400 seconds.
    mov     eax, 300
    test    r12, r12
    jz      .idle_have
    cmp     dword [r12 + OPT_SIZE], OPT_IDLE + 4
    jb      .idle_have
    mov     ecx, [r12 + OPT_IDLE]
    test    ecx, ecx
    jz      .idle_have
    xor     eax, eax
    cmp     ecx, -1
    je      .idle_have                  ; never
    cmp     ecx, 86400
    ja      .einval
    mov     eax, ecx
.idle_have:
    imul    rax, rax, 1000000000
    mov     [rbx + CServer.cfg + Config.idle_timeout_ns], rax
    OPTION  OPT_GRACE, 10, 1, 3600
    imul    rax, rax, 1000000000
    mov     [rbx + CServer.cfg + Config.grace_ns], rax
    OPTION  OPT_BUFFER, 64, 1, 4096
    shl     rax, 20                     ; MiB
    mov     [rbx + CServer.cfg + Config.conn_budget], rax
    ; The largest message must fit the connection's buffer, or it could
    ; never be received: refuse the combination now.
    OPTION  OPT_MAXMSG, 4194304, 1, 0xFFFFFFFF
    cmp     rax, [rbx + CServer.cfg + Config.conn_budget]
    ja      .einval
    mov     [rbx + CServer.cfg + Config.max_request], rax

    mov     [r13], rbx
    xor     eax, eax
    jmp     .out
.einval:
    mov     rdi, rbx
    call    free wrt ..plt
.einval_early:
    mov     eax, -EINVAL
    jmp     .out
.enomem:
    mov     eax, -ENOMEM
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; grpcasm_server_add_unary — register a unary method (see grpcasm.h).
; @param  rdi  grpcasm_server*   @param rsi  path (NUL-terminated)
; @param  rdx  handler           @param rcx  context
; @returns eax = 0, -EINVAL, -EEXIST, -ENOSPC or -EBUSY.
; @remarks The path must be "/<service>/<method>": 3..255 bytes, both parts
;          non-empty, no third '/'. The route number is the registration
;          order, 1..62, stored with the path in GA_ROUTE's format; the health
;          service later derives "<service>" from these paths. Not thread-safe
;          against a concurrent start of the same server.
; =============================================================================
grpcasm_server_add_unary:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                         ; 5 pushes: rsp 16-aligned for calls
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    test    rbx, rbx
    jz      .einval
    test    r12, r12
    jz      .einval
    test    r13, r13
    jz      .einval
    cmp     qword [rbx + CServer.state], STATE_NEW
    jne     .ebusy
    ; The path's length (at most 255) and shape.
    xor     ecx, ecx
.len:
    cmp     byte [r12 + rcx], 0
    je      .len_done
    inc     ecx
    cmp     ecx, 256
    jb      .len
    jmp     .einval                     ; 256 bytes or more
.len_done:
    cmp     ecx, 3
    jb      .einval
    cmp     byte [r12], '/'
    jne     .einval
    mov     edx, 2                      ; the service has at least one byte
.slash:
    cmp     edx, ecx
    jae     .einval                     ; no second '/'
    cmp     byte [r12 + rdx], '/'
    je      .slash_found
    inc     edx
    jmp     .slash
.slash_found:
    inc     edx                         ; the method's first byte
    cmp     edx, ecx
    jae     .einval                     ; empty method
.method:
    cmp     byte [r12 + rdx], '/'
    je      .einval                     ; a third '/'
    inc     edx
    cmp     edx, ecx
    jb      .method
    mov     r15d, ecx                   ; the path's length
    cmp     qword [rbx + CServer.nroutes], MAX_ROUTES
    jae     .enospc
    ; Not registered already. r10 walks the entries, r9 is their end:
    ; ga_keyeq keeps both (it clobbers rax, rcx and r8 only).
    lea     r10, [rbx + CServer.routes]
    mov     r9, r10
    add     r9, [rbx + CServer.rbytes]
.dup:
    cmp     r10, r9
    jae     .append
    movzx   eax, byte [r10]
    cmp     eax, r15d
    jne     .dup_next
    lea     rdi, [r10 + 2]
    mov     rsi, r12
    mov     edx, r15d
    call    ga_keyeq wrt ..plt
    test    eax, eax
    jnz     .eexist
.dup_next:
    movzx   eax, byte [r10]
    lea     r10, [r10 + rax + 2]
    jmp     .dup
.append:
    mov     rax, [rbx + CServer.nroutes]
    inc     rax                         ; this method's route number
    mov     [rbx + CServer.nroutes], rax
    mov     [rbx + CServer.handlers + rax*8], r13
    mov     [rbx + CServer.contexts + rax*8], r14
    lea     rdi, [rbx + CServer.routes]
    add     rdi, [rbx + CServer.rbytes]
    mov     [rdi], r15b                 ; [length]
    mov     [rdi + 1], al               ; [route]
    add     rdi, 2
    mov     rsi, r12
    mov     edx, r15d
    call    memcpy wrt ..plt            ; [path]
    lea     rax, [r15 + 2]
    add     [rbx + CServer.rbytes], rax
    xor     eax, eax
    jmp     .out
.einval:
    mov     eax, -EINVAL
    jmp     .out
.eexist:
    mov     eax, -EEXIST
    jmp     .out
.enospc:
    mov     eax, -ENOSPC
    jmp     .out
.ebusy:
    mov     eax, -EBUSY
.out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; grpcasm_server_start — start the server (see grpcasm.h).
; @param  rdi  grpcasm_server*
; @returns eax = 0, -EINVAL (NULL), -EBUSY, -EADDRINUSE or -EIO.
; @remarks Claims the process's one server slot first (lock cmpxchg on
;          g_server), refuses a port another process holds (ga_port_probe:
;          SO_REUSEPORT would otherwise make this server silently share it),
;          publishes the routes, handlers and contexts — no worker exists
;          yet, and pthread_create orders these stores before the workers'
;          first reads — then starts the engine. Every failure releases the
;          slot again.
; =============================================================================
grpcasm_server_start:
    push    rbx
    push    r12
    sub     rsp, 8                      ; 2 pushes + 8: rsp 16-aligned for calls
    test    rdi, rdi
    jz      .einval
    mov     rbx, rdi
    cmp     qword [rbx + CServer.state], STATE_NEW
    jne     .ebusy
    xor     eax, eax
    lock cmpxchg [g_server], rbx        ; take the slot if it is free
    jne     .ebusy                      ; another server runs in this process
    mov     rdi, [rbx + CServer.cfg + Config.port]
    call    ga_port_probe wrt ..plt
    test    rax, rax
    jnz     .port_busy
    lea     rdi, [ga_app_routes]
    lea     rsi, [rbx + CServer.routes]
    mov     rdx, [rbx + CServer.rbytes]
    call    memcpy wrt ..plt
    mov     rax, [rbx + CServer.rbytes]
    lea     rcx, [ga_app_routes]
    mov     byte [rcx + rax], 0         ; the table's end
    lea     rdi, [g_handlers]
    lea     rsi, [rbx + CServer.handlers]
    mov     ecx, MAX_ROUTES + 1
    rep     movsq
    lea     rdi, [g_contexts]
    lea     rsi, [rbx + CServer.contexts]
    mov     ecx, MAX_ROUTES + 1
    rep     movsq
    lea     rdi, [rbx + CServer.cfg]
    xor     esi, esi                    ; no application context: the hooks use globals
    call    ga_server_start wrt ..plt   ; logs "listening", or the failure
    test    rax, rax
    jz      .start_failed
    mov     [rbx + CServer.engine], rax
    mov     qword [rbx + CServer.state], STATE_RUNNING
    xor     eax, eax
    jmp     .out
.port_busy:
    neg     rax
    mov     r12, rax                    ; errno (98 = EADDRINUSE)
    mov     rdi, [rbx + CServer.cfg + Config.port]
    mov     rsi, r12
    call    log_port_busy
    mov     qword [g_server], 0
    mov     eax, -EADDRINUSE
    jmp     .out
.start_failed:
    mov     qword [g_server], 0
    mov     eax, -EIO
    jmp     .out
.einval:
    mov     eax, -EINVAL
    jmp     .out
.ebusy:
    mov     eax, -EBUSY
.out:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; =============================================================================
; grpcasm_server_stop — drain and stop a running server (see grpcasm.h).
; @param  rdi  grpcasm_server* (a server that is not running is left alone)
; @param  rsi  uint64_t totals[3] or NULL
; @returns nothing.
; @remarks Releases the process's server slot once every worker has exited,
;          so another server may start afterwards.
; =============================================================================
grpcasm_server_stop:
    test    rdi, rdi
    jz      .none
    cmp     qword [rdi + CServer.state], STATE_RUNNING
    jne     .none
    push    rbx                         ; 1 push: rsp 16-aligned for the call
    mov     rbx, rdi
    mov     rdi, [rbx + CServer.engine]
    call    ga_server_stop wrt ..plt    ; rsi = totals, as given
    mov     qword [rbx + CServer.engine], 0
    mov     qword [rbx + CServer.state], STATE_STOPPED
    mov     qword [g_server], 0         ; the slot is free again
    pop     rbx
.none:
    ret

; grpcasm_server_run's frame
%define R_SET       0               ; sigset_t (128 bytes)
%define R_INFO      128             ; siginfo_t (128 bytes)
%define R_LOG       256             ; LogBuf, LOGBUF_BYTES long
%define R_FRAME     (R_LOG + LOGBUF_BYTES)
%if (R_FRAME % 16) != 0 || (LOGBUF_BYTES % 16) != 0
    %error "capi.asm frames: R_FRAME and LOGBUF_BYTES must be multiples of 16"
%endif

; =============================================================================
; grpcasm_server_run — start, serve until SIGTERM or SIGINT, stop (see
; grpcasm.h).
; @param  rdi  grpcasm_server*   @param rsi  uint64_t totals[3] or NULL
; @returns eax = 0 after a clean shutdown, or grpcasm_server_start's error.
; @remarks Blocks SIGTERM and SIGINT in the calling thread before starting, so
;          the workers inherit the mask and only this function's sigwaitinfo
;          consumes them (EINTR keeps waiting). Logs "shutdown requested
;          signal=N" as the engine's own ga_server_run does.
; =============================================================================
grpcasm_server_run:
    push    rbx
    push    rbp
    push    r12
    push    r13                         ; 4 pushes + frame + 8: 16-aligned
    sub     rsp, R_FRAME + 8
    mov     rbx, rdi
    mov     rbp, rsi                    ; totals, or NULL
    lea     rdi, [rsp + R_SET]
    call    sigemptyset wrt ..plt
    lea     rdi, [rsp + R_SET]
    mov     esi, SIGTERM
    call    sigaddset wrt ..plt
    lea     rdi, [rsp + R_SET]
    mov     esi, SIGINT
    call    sigaddset wrt ..plt
    mov     edi, SIG_BLOCK
    lea     rsi, [rsp + R_SET]
    xor     edx, edx
    call    pthread_sigmask wrt ..plt
    mov     rdi, rbx
    call    grpcasm_server_start
    test    eax, eax
    js      .out                        ; the start's error, as is
.wait:
    lea     rdi, [rsp + R_SET]
    lea     rsi, [rsp + R_INFO]
    call    sigwaitinfo wrt ..plt
    test    eax, eax
    js      .wait                       ; EINTR: keep waiting
    mov     r12d, eax
    lea     rdi, [rsp + R_LOG]
    lea     rsi, [lvl_info]
    call    ga_logb_init wrt ..plt
    lea     rdi, [rsp + R_LOG]
    lea     rsi, [m_shutdown]
    mov     edx, L_shutdown
    call    ga_logb_str wrt ..plt
    lea     rdi, [rsp + R_LOG]
    mov     rsi, r12
    call    ga_logb_u64 wrt ..plt
    lea     rdi, [rsp + R_LOG]
    call    ga_logb_emit wrt ..plt
    mov     rdi, rbx
    mov     rsi, rbp
    call    grpcasm_server_stop
    xor     eax, eax
.out:
    add     rsp, R_FRAME + 8
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; =============================================================================
; grpcasm_server_free — free a server, stopping it first if it runs.
; @param  rdi  grpcasm_server* or NULL
; @returns nothing.
; =============================================================================
grpcasm_server_free:
    test    rdi, rdi
    jz      .none
    push    rbx                         ; 1 push: rsp 16-aligned for calls
    mov     rbx, rdi
    xor     esi, esi
    call    grpcasm_server_stop         ; no-op unless it runs
    mov     rdi, rbx
    call    free wrt ..plt
    pop     rbx
.none:
    ret

; =============================================================================
; grpcasm_call_reply — answer a call with one message and OK (see grpcasm.h).
; @param  rdi  grpcasm_call*   @param rsi  message   @param rdx  length
; @returns eax = 0, -EALREADY, -EMSGSIZE or -1 (out of memory).
; @remarks The 5-byte gRPC prefix is built in this frame and sent as the
;          head of ga_h2n_reply_parts, the message as its body: h2n copies
;          both into DATA frames (or its own buffer when the windows are
;          short) before returning, so the caller's buffer is free afterwards.
;          The call is marked answered in its CCall, never in the Stream,
;          which the engine may already have freed.
; =============================================================================
grpcasm_call_reply:
    cmp     qword [rdi + CCall.state], 0
    jne     .already
    mov     rax, rdx
    shr     rax, 32
    jnz     .msgsize                    ; gRPC lengths are 32-bit
    push    rbx
    sub     rsp, 16                     ; [0..5) the prefix; 1 push + 16: aligned
    mov     rbx, rdi
    mov     byte [rsp], 0               ; not compressed
    mov     eax, edx
    bswap   eax
    mov     [rsp + 1], eax              ; big-endian length
    mov     r8, rsi                     ; body: the message
    mov     r9, rdx
    mov     rdi, [rbx + CCall.conn]
    mov     rsi, [rbx + CCall.stream]
    mov     rdx, rsp                    ; head: the prefix
    mov     ecx, GRPC_PREFIX
    call    ga_h2n_reply_parts wrt ..plt
    mov     ecx, 1
    test    eax, eax
    jz      .mark
    mov     rcx, -1                     ; out of memory: the connection must end
    mov     eax, -1
.mark:
    mov     [rbx + CCall.state], rcx
    add     rsp, 16
    pop     rbx
    ret
.already:
    mov     eax, -EALREADY
    ret
.msgsize:
    mov     eax, -EMSGSIZE
    ret

; grpcasm_call_fail's frame: 4 HdrFields, the status digits, the message.
%define X_FIELDS    0                       ; HdrField[4]
%define X_DIGITS    (X_FIELDS + 4 * HdrField_size)
%define X_MSG       (X_DIGITS + 16)
%define X_FRAME     ((X_MSG + MSG_MAX + 15) & ~15)

; =============================================================================
; grpcasm_call_fail — answer a call with an error status (see grpcasm.h).
; @param  rdi  grpcasm_call*   @param esi  status (1..16)   @param rdx  message
; @returns eax = 0, -EALREADY, -EINVAL or -1 (out of memory).
; @remarks A Trailers-Only answer through ga_grpc_refuse (which counts the
;          error), with its four fields built in this frame: :status 200,
;          content-type, grpc-status and grpc-message. The message is
;          percent-encoded as the gRPC protocol asks (bytes outside 0x20..0x7E,
;          and '%' itself, become %XX), and cut at MSG_MAX bytes, never inside
;          an escape. h2n encodes the fields before returning, so the frame's
;          strings only need to live for the call.
; =============================================================================
grpcasm_call_fail:
    cmp     qword [rdi + CCall.state], 0
    jne     .already
    cmp     esi, 1
    jl      .einval
    cmp     esi, 16
    jg      .einval
    push    rbx
    push    r12
    push    r13                         ; 3 pushes + X_FRAME: 16-aligned
    sub     rsp, X_FRAME
    mov     rbx, rdi                    ; CCall*
    mov     r12d, esi                   ; status
    mov     r13, rdx                    ; message, or NULL
    ; The status as decimal digits (1..16).
    cmp     r12d, 10
    jb      .one_digit
    mov     byte [rsp + X_DIGITS], '1'
    lea     eax, [r12 - 10 + '0']
    mov     [rsp + X_DIGITS + 1], al
    mov     r11d, 2
    jmp     .digits_done
.one_digit:
    lea     eax, [r12 + '0']
    mov     [rsp + X_DIGITS], al
    mov     r11d, 1
.digits_done:
    ; The message, percent-encoded: r9 = bytes written, r10 = hex digits.
    xor     r9d, r9d
    lea     r10, [hexdigits]
    test    r13, r13
    jz      .encoded
.enc:
    movzx   eax, byte [r13]
    test    eax, eax
    jz      .encoded
    cmp     eax, 0x20
    jb      .escape
    cmp     eax, 0x7E
    ja      .escape
    cmp     eax, '%'
    je      .escape
    cmp     r9d, MSG_MAX
    jae     .encoded                    ; full: cut here
    mov     [rsp + X_MSG + r9], al
    inc     r9d
    inc     r13
    jmp     .enc
.escape:
    lea     ecx, [r9 + 3]
    cmp     ecx, MSG_MAX
    ja      .encoded                    ; no room for the whole escape: cut here
    mov     byte [rsp + X_MSG + r9], '%'
    mov     ecx, eax
    shr     ecx, 4
    movzx   ecx, byte [r10 + rcx]
    mov     [rsp + X_MSG + r9 + 1], cl
    and     eax, 15
    movzx   eax, byte [r10 + rax]
    mov     [rsp + X_MSG + r9 + 2], al
    add     r9d, 3
    inc     r13
    jmp     .enc
.encoded:
    ; The four fields.
    lea     rax, [s_status]
    mov     [rsp + X_FIELDS + 0 * HdrField_size + HdrField.name], rax
    lea     rax, [s_200]
    mov     [rsp + X_FIELDS + 0 * HdrField_size + HdrField.value], rax
    mov     qword [rsp + X_FIELDS + 0 * HdrField_size + HdrField.namelen], s_status_len
    mov     qword [rsp + X_FIELDS + 0 * HdrField_size + HdrField.valuelen], s_200_len
    lea     rax, [s_ctype]
    mov     [rsp + X_FIELDS + 1 * HdrField_size + HdrField.name], rax
    lea     rax, [s_ctype_grpc]
    mov     [rsp + X_FIELDS + 1 * HdrField_size + HdrField.value], rax
    mov     qword [rsp + X_FIELDS + 1 * HdrField_size + HdrField.namelen], s_ctype_len
    mov     qword [rsp + X_FIELDS + 1 * HdrField_size + HdrField.valuelen], s_ctype_grpc_len
    lea     rax, [s_gstatus]
    mov     [rsp + X_FIELDS + 2 * HdrField_size + HdrField.name], rax
    lea     rax, [rsp + X_DIGITS]
    mov     [rsp + X_FIELDS + 2 * HdrField_size + HdrField.value], rax
    mov     qword [rsp + X_FIELDS + 2 * HdrField_size + HdrField.namelen], s_gstatus_len
    mov     [rsp + X_FIELDS + 2 * HdrField_size + HdrField.valuelen], r11
    lea     rax, [s_gmessage]
    mov     [rsp + X_FIELDS + 3 * HdrField_size + HdrField.name], rax
    lea     rax, [rsp + X_MSG]
    mov     [rsp + X_FIELDS + 3 * HdrField_size + HdrField.value], rax
    mov     qword [rsp + X_FIELDS + 3 * HdrField_size + HdrField.namelen], s_gmessage_len
    mov     [rsp + X_FIELDS + 3 * HdrField_size + HdrField.valuelen], r9
    mov     rdi, [rbx + CCall.conn]
    mov     rsi, [rbx + CCall.stream]
    lea     rdx, [rsp + X_FIELDS]
    mov     ecx, 4
    call    ga_grpc_refuse wrt ..plt
    mov     ecx, 1
    test    eax, eax
    jz      .mark
    mov     rcx, -1                     ; out of memory: the connection must end
    mov     eax, -1
.mark:
    mov     [rbx + CCall.state], rcx
    add     rsp, X_FRAME
    pop     r13
    pop     r12
    pop     rbx
    ret
.already:
    mov     eax, -EALREADY
    ret
.einval:
    mov     eax, -EINVAL
    ret

; =============================================================================
; grpcasm_pb_bytes — find a length-delimited protobuf field (see grpcasm.h).
; @param  rdi  message   @param rsi  length   @param edx  field
; @param  rcx  const uint8_t** value   @param r8  size_t* value_length
; @returns eax = 1 (present), 0 (absent) or -EINVAL.
; @remarks The engine's ga_pb_field_bytes (KvAsm's decoder rules), with the
;          out pointers kept in callee-saved registers across it.
; =============================================================================
grpcasm_pb_bytes:
    test    rcx, rcx
    jz      .einval_early
    test    r8, r8
    jz      .einval_early
    test    edx, edx
    jz      .einval_early               ; field 0 does not exist
    push    rbx
    push    r12
    push    r13
    mov     r12, rcx
    mov     r13, r8
    call    ga_pb_field_bytes wrt ..plt ; rax = 0 / -EINVAL; rdx, rcx = the field
    test    rax, rax
    jnz     .malformed
    mov     [r12], rdx
    mov     [r13], rcx
    xor     eax, eax
    test    rdx, rdx
    setnz   al                          ; a present field points into the message
    jmp     .out
.malformed:
    mov     qword [r12], 0
    mov     qword [r13], 0
    mov     eax, -EINVAL
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret
.einval_early:
    mov     eax, -EINVAL
    ret

; =============================================================================
; ga_app_unary — the engine's hook for a validated unary call: the
; registered handler, then INTERNAL if it did not answer.
; @param  rdi  Conn*   @param rsi  Stream*   @param rdx  message   @param rcx  length
; @returns eax = 0, or -1 to end the connection (the handler asked for it, or
;          an answer could not be queued).
; @remarks Route byte -> handler and context from the arrays published at
;          start: two loads and an indirect call. The CCall lives in this
;          frame for the handler's duration.
; =============================================================================
ga_app_unary:
    push    rbx
    sub     rsp, 32                     ; [0..24) the CCall; 1 push + 32: aligned
    mov     [rsp + CCall.conn], rdi
    mov     [rsp + CCall.stream], rsi
    mov     qword [rsp + CCall.state], 0
    movzx   eax, byte [rsi + Stream.method]
    lea     r8, [g_handlers]
    mov     r9, [r8 + rax*8]
    lea     r8, [g_contexts]
    mov     rdi, [r8 + rax*8]           ; context
    mov     rsi, rsp                    ; grpcasm_call*
    ; rdx, rcx: the message and its length, as received
    call    r9
    mov     rbx, [rsp + CCall.state]
    test    eax, eax
    js      .fatal                      ; the handler asks to end the connection
    test    rbx, rbx
    js      .fatal                      ; its answer could not be queued
    jnz     .done                       ; answered
    mov     rdi, rsp
    mov     esi, GRPC_INTERNAL
    lea     rdx, [m_noreply]
    call    grpcasm_call_fail
    test    eax, eax
    js      .fatal
.done:
    xor     eax, eax
    jmp     .out
.fatal:
    mov     eax, -1
.out:
    add     rsp, 32
    pop     rbx
    ret

; =============================================================================
; ga_app_health_service — whether a service name has a registered method.
; @param  rdi  the name   @param rsi  its length (> 0)
; @returns eax = 1 when some path "/<name>/<method>" is registered, else 0.
; @remarks Walks the running server's route table; the service of each path
;          is the bytes between its first and second '/'. Rare (health checks
;          with a service name), so a scan is fine.
; =============================================================================
ga_app_health_service:
    push    rbx
    push    r12
    push    r13                         ; (ga_keyeq needs no alignment)
    mov     r12, rdi                    ; the name
    mov     r13, rsi                    ; its length
    lea     rbx, [ga_app_routes]
.next:
    movzx   eax, byte [rbx]             ; the entry's path length; 0 ends the table
    test    eax, eax
    jz      .no
    lea     rdx, [rbx + 2]              ; the path
    mov     ecx, 1
.find:
    cmp     ecx, eax
    jae     .skip
    cmp     byte [rdx + rcx], '/'
    je      .found
    inc     ecx
    jmp     .find
.found:
    lea     r8, [rcx - 1]               ; the service's length
    cmp     r8, r13
    jne     .skip
    mov     rdi, r12
    lea     rsi, [rdx + 1]
    mov     rdx, r13
    call    ga_keyeq wrt ..plt
    test    eax, eax
    jnz     .yes
.skip:
    movzx   eax, byte [rbx]
    lea     rbx, [rbx + rax + 2]
    jmp     .next
.yes:
    mov     eax, 1
    jmp     .out
.no:
    xor     eax, eax
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; ga_app_stream_data, ga_app_stream_end — never called: the C ABI registers
; unary methods only (no route carries GA_ROUTE_CLIENT_STREAM).
; @returns eax = -1: if the engine ever routed a stream here, ending the
;          connection is the safe answer to a call this library cannot have.
; =============================================================================
ga_app_stream_data:
ga_app_stream_end:
    mov     eax, -1
    ret

; =============================================================================
; ga_app_stream_fill — never called: no answer here generates a body.
; @returns does not return (ud2: a call would be an engine bug, made loud).
; =============================================================================
ga_app_stream_fill:
    ud2

; =============================================================================
; ga_app_batch_end — nothing is deferred. @returns eax = 0.
; ga_app_worker_init — no per-worker state. @returns rax = 0.
; =============================================================================
ga_app_batch_end:
ga_app_worker_init:
    xor     eax, eax
    ret

; =============================================================================
; ga_app_call_release, ga_app_worker_fini, _resume, _pause, _tick — nothing
; to release, nothing around a sleep, nothing periodic. @returns nothing.
; =============================================================================
ga_app_call_release:
ga_app_worker_fini:
ga_app_worker_resume:
ga_app_worker_pause:
ga_app_worker_tick:
    ret

; =============================================================================
; log_port_busy — 'msg="port already in use, refusing to share it" port=N
; errno=E', the line KvServer and the Greeter log for the same refusal.
; Internal.
; @param  rdi  port   @param rsi  errno
; @returns nothing.
; =============================================================================
log_port_busy:
    push    rbx
    push    r12
    sub     rsp, LOGBUF_BYTES + 8       ; 2 pushes + LOGBUF_BYTES + 8: aligned
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, rsp
    lea     rsi, [lvl_error]
    call    ga_logb_init wrt ..plt
    mov     rdi, rsp
    lea     rsi, [m_f_port]
    mov     edx, L_f_port
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    lea     rsi, [k_port]
    mov     edx, 6
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    mov     rsi, rbx
    call    ga_logb_u64 wrt ..plt
    mov     rdi, rsp
    lea     rsi, [k_errno]
    mov     edx, 7
    call    ga_logb_str wrt ..plt
    mov     rdi, rsp
    mov     rsi, r12
    call    ga_logb_u64 wrt ..plt
    mov     rdi, rsp
    call    ga_logb_emit wrt ..plt
    add     rsp, LOGBUF_BYTES + 8
    pop     r12
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
