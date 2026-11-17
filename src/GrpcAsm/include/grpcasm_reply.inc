; =============================================================================
; grpcasm_reply.inc — static reply tables, for the engine and its
; applications.
;
; A reply that never changes (a gRPC error, a plain HTTP 405) is a HdrField
; array (server.inc) built at assembly time and handed to ga_grpc_refuse,
; ga_h2n_reply_headers or ga_h2n_reply_static, which HPACK-encode it
; straight from these strings: nothing is formatted or allocated per call.
;
; TRAILERS_ONLY expects the including module to define, with CSTR, the six
; strings it names (s_status, s_200, s_ctype, s_ctype_grpc, s_gstatus,
; s_gmessage). Each module's tables then point at its own .rodata, so no
; table relocates against another module's data.
;
; Placement: CSTR strings go in .rodata. NV tables hold absolute string
; pointers, which a position-independent executable can only hold through
; load-time relocations, so they go in .data.rel.ro: relocated at load, then
; read-only through RELRO. In .rodata they would need a text relocation
; (rejected by -z text); in .data they would stay writable for the process's
; lifetime.
; =============================================================================

%ifndef GRPCASM_REPLY_INC
%define GRPCASM_REPLY_INC

; gRPC status codes (grpc/doc/statuscodes.md) that the engine and KvServer
; answer with.
%define GRPC_OK                 0
%define GRPC_INVALID_ARGUMENT   3
%define GRPC_NOT_FOUND          5
%define GRPC_RESOURCE_EXHAUSTED 8
%define GRPC_UNIMPLEMENTED      12
%define GRPC_INTERNAL           13

; CSTR label, bytes... — a string constant, and label_len for its length (an
; assembly-time constant, not a symbol: tables in other modules cannot use it).
%macro CSTR 2+
%1: db %2
%{1}_len equ $ - %1
%endmacro

; NV name, value — one HdrField referring to two CSTR labels of this module.
; Built with istruc, so a change of HdrField's layout in server.inc cannot
; leave a table out of step with it.
%macro NV 2
    istruc HdrField
        at HdrField.name,     dq %1
        at HdrField.value,    dq %2
        at HdrField.namelen,  dq %{1}_len
        at HdrField.valuelen, dq %{2}_len
    iend
%endmacro

; TRAILERS_ONLY label, code, message — the four fields of a Trailers-Only
; gRPC error (:status 200, content-type, grpc-status, grpc-message), to be
; answered with a field count of 4. NV lines written directly after it extend
; the same array, and must be counted in (KvServer's compression error adds
; grpc-accept-encoding and is answered with 5).
%macro TRAILERS_ONLY 3
%1:                 NV s_status, s_200
                    NV s_ctype, s_ctype_grpc
                    NV s_gstatus, %2
                    NV s_gmessage, %3
%endmacro

%endif
