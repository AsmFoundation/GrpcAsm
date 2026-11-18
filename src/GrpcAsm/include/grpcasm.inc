; =============================================================================
; grpcasm.inc — GrpcAsm's NASM API (milestone C3): a gRPC service declared in
; a few lines, with the route table, the dispatch, the health check and every
; hook the application does not write generated at assembly time.
;
;   %include "grpcasm.inc"
;
;   GA_SERVICE "helloworld.Greeter"
;       GA_UNARY "SayHello", say_hello
;   GA_SERVICE_END
;   GA_APP_END                          ; in the file that defines the handlers
;
;   say_hello:                          ; rdi Conn*, rsi Stream*, rdx message, rcx length
;       ...
;       GA_REPLY_BEGIN rdi, rsi, 64     ; rax = where the reply's message goes
;       ...                             ; write it there
;       GA_REPLY_END rbx, rbp, rcx      ; framed around it, nothing copied
;
; What the macros generate (GA_APP_END):
;   ga_app_routes          the route table (grpcasm_routes.inc): one GA_ROUTE
;                          per method, path "/<service>/<method>"
;   ga_app_unary           the dispatch to the unary handlers, specialized to
;                          their number:
;                            1      an alias of the handler: the engine calls
;                                   the handler directly, zero instructions
;                            2..4   a compare chain on the route byte, in
;                                   declaration order (declare the hottest
;                                   method first), the last without a compare
;                            5+     a jump table of 32-bit offsets
;   ga_app_stream_data,    the same for client-streaming methods (their data
;   ga_app_stream_end      and end handlers)
;   ga_app_health_service  SERVING for every declared service, NOT_FOUND for
;                          anything else
;   every other hook       the no-op the engine expects (grpcasm_hooks.inc),
;                          unless the application declares it with
;                          GA_USES_HOOK and defines it itself
;
; Handlers: a unary handler IS ga_app_unary for its route, with the hook's
; contract (grpcasm_hooks.inc): rdi Conn*, rsi Stream*, rdx the request
; message, rcx its length; eax = 0, or -1 to end the connection. It is
; reached by a direct jump, or no instruction at all, so its own prologue is
; the only stack the API costs; a leaf handler that only replies needs none
; beyond what its calls require. Client-streaming handlers are
; ga_app_stream_data / ga_app_stream_end for their route, likewise.
;
; Route numbers: assigned in declaration order from 1 unless given
; (GA_UNARY "Get", kv_get, M_GET), so code that compares Stream.method keeps
; its constants. Duplicate numbers fail the build.
;
; Footguns:
;   * GA_APP_END must be in the file that defines the handlers: a single
;     unary or streaming handler becomes the hook by an `equ` alias, which
;     needs the label in the same assembly. (A handler in another file fails
;     to assemble here; it never links wrongly.)
;   * A hook the application defines itself must be named in GA_USES_HOOK,
;     or its default is generated too: "symbol redefined" or a duplicate
;     symbol at link time, never a silent choice of the wrong one.
;   * GA_APP_END leaves the current section at .text.
; =============================================================================
%ifndef GRPCASM_INC
%define GRPCASM_INC

%include "grpcasm_sys.inc"
%include "server.inc"                   ; Conn, Stream, ST_*, grpcasm_routes.inc
%include "grpcasm_reply.inc"            ; CSTR, NV, TRAILERS_ONLY, GRPC_* codes

extern ga_h2n_reply_begin
extern ga_h2n_reply_end
extern ga_h2n_reply_abandon
extern ga_h2n_reply_parts
extern ga_grpc_refuse
extern ga_pb_field_bytes
extern ga_keyeq

; Up to this many unary (or streaming) methods dispatch through a compare
; chain; more through a jump table. A taken branch per compare against one
; indirect jump: for a handful of routes the chain is shorter, and its
; branches predict as well.
%define GA_CHAIN_MAX        4

%assign GA_NSERVICES 0
%assign GA_NMETHODS 0
%assign GA_NEXT_ROUTE 1

; -----------------------------------------------------------------------------
; GA_SERVICE "package.Service" — begin a service's methods.
; -----------------------------------------------------------------------------
%macro GA_SERVICE 1
    %ifdef GA_IN_SERVICE
        %error "GA_SERVICE: the previous service has no GA_SERVICE_END"
    %endif
    %define GA_IN_SERVICE
    %assign GA_NSERVICES GA_NSERVICES + 1
    %xdefine GA_SVC_%[GA_NSERVICES] %1
    %xdefine GA_CUR_SERVICE %1
%endmacro

; -----------------------------------------------------------------------------
; GA_SERVICE_END — end the current service.
; -----------------------------------------------------------------------------
%macro GA_SERVICE_END 0
    %ifndef GA_IN_SERVICE
        %error "GA_SERVICE_END without GA_SERVICE"
    %endif
    %undef GA_IN_SERVICE
%endmacro

; -----------------------------------------------------------------------------
; GA_UNARY "Method", handler [, route] — a unary method.
; -----------------------------------------------------------------------------
%macro GA_UNARY 2-3 0
    GA_METHOD_ 0, %1, %2, %2, %3
%endmacro

; -----------------------------------------------------------------------------
; GA_CLIENT_STREAM "Method", data_handler, end_handler [, route] — a
; client-streaming method: data_handler gets each DATA payload as it arrives
; (ga_app_stream_data's contract), end_handler the end (ga_app_stream_end's).
; -----------------------------------------------------------------------------
%macro GA_CLIENT_STREAM 3-4 0
    GA_METHOD_ GA_ROUTE_CLIENT_STREAM, %1, %2, %3, %4
%endmacro

; GA_METHOD_ kind, "Method", handler1, handler2, route — internal. Route 0
; (GA_ROUTE_UNKNOWN, never a method's) means "the next free number": the
; optional argument's default, since NASM drops an empty trailing argument.
%macro GA_METHOD_ 5
    %ifndef GA_IN_SERVICE
        %error "GA_UNARY / GA_CLIENT_STREAM outside GA_SERVICE ... GA_SERVICE_END"
    %endif
    %assign GA_NMETHODS GA_NMETHODS + 1
    %if %5 == 0
        %assign GA_R_ GA_NEXT_ROUTE
    %else
        %assign GA_R_ %5
    %endif
    ; The next automatic number follows the highest one used, counted
    ; without the client-streaming bit (an explicit M_UPLOAD = 5 | 0x40 is
    ; number 5).
    %if (GA_R_ & GA_ROUTE_HEALTH) >= GA_NEXT_ROUTE
        %assign GA_NEXT_ROUTE (GA_R_ & GA_ROUTE_HEALTH) + 1
    %endif
    %strcat GA_PATH_ "/", GA_CUR_SERVICE, "/", %2
    %xdefine GA_M_PATH_%[GA_NMETHODS] GA_PATH_
    %assign GA_M_ROUTE_%[GA_NMETHODS] GA_R_ | %1
    %assign GA_M_KIND_%[GA_NMETHODS] %1
    %xdefine GA_M_H1_%[GA_NMETHODS] %3
    %xdefine GA_M_H2_%[GA_NMETHODS] %4
%endmacro

; -----------------------------------------------------------------------------
; GA_USES_HOOK name, ... — hooks the application defines itself (as
; ga_app_<name>): worker_init, worker_fini, worker_resume, worker_pause,
; worker_tick, batch_end, call_release, stream_fill, health_service,
; unary, stream_data, stream_end. GA_APP_END generates no default for them.
; -----------------------------------------------------------------------------
%macro GA_USES_HOOK 1-*
    %rep %0
        %define GA_USES_%1
        %rotate 1
    %endrep
%endmacro

; -----------------------------------------------------------------------------
; GA_DISPATCH_ hook, kind, which — internal: one dispatch hook over the
; methods of a kind (0 unary, GA_ROUTE_CLIENT_STREAM streaming), jumping to
; handler 1 (which = 1) or handler 2 (which = 2).
; -----------------------------------------------------------------------------
%macro GA_DISPATCH_ 3
    %assign GA_N_ 0
    %assign GA_LAST_ 0
    %assign GA_I_ 1
    %rep GA_NMETHODS
        %if GA_M_KIND_%[GA_I_] == %2
            %assign GA_N_ GA_N_ + 1
            %assign GA_LAST_ GA_I_
        %endif
        %assign GA_I_ GA_I_ + 1
    %endrep
    global %1:function
    %if GA_N_ == 0
        ; No method of this kind: the engine never routes here. If it ever
        ; did, ending the connection is the safe answer.
%1:
        mov     eax, -1
        ret
    %elif GA_N_ == 1
        ; One handler: it is the hook. The engine's call reaches it directly.
%1      equ GA_M_H%[%3]_%[GA_LAST_]
    %elif GA_N_ <= GA_CHAIN_MAX
        ; A compare chain on the route byte, the last handler without one.
%1:
        movzx   eax, byte [rsi + Stream.method]
        %assign GA_I_ 1
        %rep GA_NMETHODS
            %if GA_M_KIND_%[GA_I_] == %2
                %if GA_I_ == GA_LAST_
        jmp     GA_M_H%[%3]_%[GA_I_]
                %else
        cmp     eax, GA_M_ROUTE_%[GA_I_]
        je      GA_M_H%[%3]_%[GA_I_]
                %endif
            %endif
            %assign GA_I_ GA_I_ + 1
        %endrep
    %else
        ; A jump table indexed by the route number (the low six bits), of
        ; offsets from the table, in .text beside the code: no relocation.
%1:
        movzx   eax, byte [rsi + Stream.method]
        and     eax, GA_ROUTE_HEALTH
        lea     r10, [%%table]
        movsxd  r11, dword [r10 + rax*4]
        add     r11, r10
        jmp     r11
%%trap:
        mov     eax, -1                 ; a route of another kind: end the connection
        ret
        align   4
%%table:
        %assign GA_RN_ 0
        %rep GA_ROUTE_HEALTH + 1
            %assign GA_HIT_ 0
            %assign GA_I_ 1
            %rep GA_NMETHODS
                %if GA_M_KIND_%[GA_I_] == %2 && (GA_M_ROUTE_%[GA_I_] & GA_ROUTE_HEALTH) == GA_RN_
                    %assign GA_HIT_ GA_I_
                %endif
                %assign GA_I_ GA_I_ + 1
            %endrep
            %if GA_HIT_
        dd      GA_M_H%[%3]_%[GA_HIT_] - %%table
            %else
        dd      %%trap - %%table
            %endif
            %assign GA_RN_ GA_RN_ + 1
        %endrep
    %endif
%endmacro

; -----------------------------------------------------------------------------
; GA_DEFAULT_HOOK_ name, body... — internal: the no-op version of a hook,
; unless the application declared it with GA_USES_HOOK.
; -----------------------------------------------------------------------------
%macro GA_DEFAULT_HOOK_ 2+
    %ifndef GA_USES_%1
        global ga_app_%1:function
ga_app_%1:
        %2
    %endif
%endmacro

; -----------------------------------------------------------------------------
; GA_APP_END — generate the route table, the dispatch, the health check and
; the default hooks. Once, after every service, in the handlers' file.
; -----------------------------------------------------------------------------
%macro GA_APP_END 0
    %ifdef GA_IN_SERVICE
        %error "GA_APP_END inside a service: GA_SERVICE_END first"
    %endif
    %if GA_NMETHODS == 0
        %error "GA_APP_END: no method declared"
    %endif
    ; ---- every route number once ----
    %assign GA_I_ 1
    %rep GA_NMETHODS
        %assign GA_J_ GA_I_ + 1
        %rep GA_NMETHODS - GA_I_
            %if (GA_M_ROUTE_%[GA_I_] & GA_ROUTE_HEALTH) == (GA_M_ROUTE_%[GA_J_] & GA_ROUTE_HEALTH)
                %error "GA_APP_END: two methods have the same route number"
            %endif
            %assign GA_J_ GA_J_ + 1
        %endrep
        %assign GA_I_ GA_I_ + 1
    %endrep

    ; ---- the route table and the service names ----
    section .rodata
    global ga_app_routes:data
ga_app_routes:
    %assign GA_I_ 1
    %rep GA_NMETHODS
        GA_ROUTE GA_M_PATH_%[GA_I_], GA_M_ROUTE_%[GA_I_]
        %assign GA_I_ GA_I_ + 1
    %endrep
    GA_ROUTES_END
    %assign GA_I_ 1
    %rep GA_NSERVICES
ga_svc_name_%[GA_I_]:   db GA_SVC_%[GA_I_]
ga_svc_len_%[GA_I_]     equ $ - ga_svc_name_%[GA_I_]
        %assign GA_I_ GA_I_ + 1
    %endrep

    section .text
    ; ---- the dispatch ----
    %ifndef GA_USES_unary
        GA_DISPATCH_ ga_app_unary, 0, 1
    %endif
    %ifndef GA_USES_stream_data
        GA_DISPATCH_ ga_app_stream_data, GA_ROUTE_CLIENT_STREAM, 1
    %endif
    %ifndef GA_USES_stream_end
        GA_DISPATCH_ ga_app_stream_end, GA_ROUTE_CLIENT_STREAM, 2
    %endif

    ; ---- the health check: rdi name, rsi its length (> 0) -> eax 1 / 0 ----
    %ifndef GA_USES_health_service
    global ga_app_health_service:function
ga_app_health_service:
    sub     rsp, 8                      ; aligned for ga_keyeq
    mov     rdx, rsi                    ; ga_keyeq keeps rdi and rdx
        %assign GA_I_ 1
        %rep GA_NSERVICES
    cmp     rdx, ga_svc_len_%[GA_I_]
    jne     %%next%[GA_I_]
    lea     rsi, [ga_svc_name_%[GA_I_]]
    call    ga_keyeq wrt ..plt
    test    eax, eax
    jnz     %%serving
%%next%[GA_I_]:
            %assign GA_I_ GA_I_ + 1
        %endrep
    xor     eax, eax                    ; NOT_FOUND
    add     rsp, 8
    ret
%%serving:
    mov     eax, 1
    add     rsp, 8
    ret
    %endif

    ; ---- every other hook: the engine's no-op ----
    GA_DEFAULT_HOOK_ worker_init, xor eax, eax
    %ifndef GA_USES_worker_init
        ret
    %endif
    GA_DEFAULT_HOOK_ batch_end, xor eax, eax
    %ifndef GA_USES_batch_end
        ret
    %endif
    GA_DEFAULT_HOOK_ worker_fini, ret
    GA_DEFAULT_HOOK_ worker_resume, ret
    GA_DEFAULT_HOOK_ worker_pause, ret
    GA_DEFAULT_HOOK_ worker_tick, ret
    GA_DEFAULT_HOOK_ call_release, ret
    ; No generated body: a call would be an engine bug (ST_GEN is the
    ; application's own flag), and ud2 makes it loud.
    GA_DEFAULT_HOOK_ stream_fill, ud2
%endmacro

; -----------------------------------------------------------------------------
; GA_MOVE_ dst, src — internal: mov unless they are the same register.
; -----------------------------------------------------------------------------
%macro GA_MOVE_ 2
    %ifnidni %1, %2
        mov     %1, %2
    %endif
%endmacro

; -----------------------------------------------------------------------------
; GA_REPLY_BEGIN conn, stream, max — start a reply written in place
; (ga_h2n_reply_begin): rax = where the message goes (at most max bytes), or
; 0 (out of memory). Clobbers what a call clobbers.
; GA_REPLY_END conn, stream, length — finish it: eax = 0, or -1 (end the
; connection). The handler usually returns that eax as it is.
; GA_REPLY_ABANDON conn, stream — undo a begin, to answer another way.
; Between begin and end, write nothing else to the connection's output.
; -----------------------------------------------------------------------------
%macro GA_REPLY_BEGIN 3
    GA_MOVE_ rdi, %1
    GA_MOVE_ rsi, %2
    GA_MOVE_ rdx, %3
    call    ga_h2n_reply_begin wrt ..plt
%endmacro

%macro GA_REPLY_END 3
    GA_MOVE_ rdi, %1
    GA_MOVE_ rsi, %2
    GA_MOVE_ rdx, %3
    call    ga_h2n_reply_end wrt ..plt
%endmacro

%macro GA_REPLY_ABANDON 2
    GA_MOVE_ rdi, %1
    GA_MOVE_ rsi, %2
    call    ga_h2n_reply_abandon wrt ..plt
%endmacro

%endif
