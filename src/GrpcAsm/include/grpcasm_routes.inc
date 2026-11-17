; =============================================================================
; grpcasm_routes.inc — routes: how a request's :path becomes Stream.method.
;
; The application lists its methods in one table, ga_app_routes, built with
; GA_ROUTE and GA_ROUTES_END in its own .rodata (KvServer: routes.asm). For
; every :path it sees, hpack.asm looks the path up there and keeps the
; result as the field's meaning. The HPACK meaning cache and h2n's
; header-block cache then reuse it, so the scan runs once per distinct :path
; field of a connection, not once per request.
;
; The table holds no pointers: each entry is [path length][route][path
; bytes], and a zero length ends the table. It therefore needs no relocation
; and fits in .rodata, as one contiguous run of bytes. Matches are exact and
; the first matching entry wins. A path that matches no entry gets
; GA_ROUTE_UNKNOWN, which the engine answers UNIMPLEMENTED at END_STREAM.
;
; The route byte is what Stream.method holds:
;   1..62 (GA_ROUTE_MAX)       an application method: the application's own
;                              numbering, compared by its code
;   | GA_ROUTE_CLIENT_STREAM   the request body goes to ga_app_stream_data
;                              as it arrives, and its end to ga_app_stream_end
;                              (never buffered); without it the request is one
;                              message, buffered or borrowed, and goes to
;                              ga_app_unary
;   GA_ROUTE_UNKNOWN (0)       no route: UNIMPLEMENTED
;   GA_ROUTE_HEALTH (63)       /grpc.health.v1.Health/Check, built into the
;                              engine and checked before the table
; Why 62 and bit 6: the route travels in the 8-bit value class of an HPACK
; meaning (hpack.inc), whose bit 7 already means "empty value" (VC_EMPTY). A
; server that needs more methods widens that field; the table format already
; has room for 255-byte paths and any route byte.
; =============================================================================

%ifndef GRPCASM_ROUTES_INC
%define GRPCASM_ROUTES_INC

%define GA_ROUTE_UNKNOWN        0
%define GA_ROUTE_MAX            0x3E
%define GA_ROUTE_HEALTH         0x3F
%define GA_ROUTE_CLIENT_STREAM  0x40

; GA_ROUTE "path", route — one table entry. The path is a string literal of
; 1 to 255 bytes (the exact :path, e.g. "/helloworld.Greeter/SayHello"). The
; route is 1..GA_ROUTE_MAX, optionally or'd with GA_ROUTE_CLIENT_STREAM.
; Both are checked at assembly time: a bad entry fails the build instead of
; turning into a wrong route at run time.
%macro GA_ROUTE 2
    %strlen GA_ROUTE_PATH_LEN %1
    %if GA_ROUTE_PATH_LEN < 1 || GA_ROUTE_PATH_LEN > 255
        %error "GA_ROUTE: a path is 1 to 255 bytes"
    %endif
    %if ((%2) & GA_ROUTE_HEALTH) < 1 || ((%2) & GA_ROUTE_HEALTH) > GA_ROUTE_MAX
        %error "GA_ROUTE: the route number must be 1..GA_ROUTE_MAX"
    %endif
    %if ((%2) & ~(GA_ROUTE_HEALTH | GA_ROUTE_CLIENT_STREAM)) != 0
        %error "GA_ROUTE: only GA_ROUTE_CLIENT_STREAM may be or'd into a route"
    %endif
    db      GA_ROUTE_PATH_LEN, %2, %1
%endmacro

; GA_ROUTES_END — the end of the table (a zero path length).
%macro GA_ROUTES_END 0
    db      0
%endmacro

%endif
