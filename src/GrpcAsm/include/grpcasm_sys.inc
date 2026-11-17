; =============================================================================
; grpcasm_sys.inc — the Linux x86-64 constants of the GrpcAsm engine: system
; call numbers, errno values (raw system calls return -errno) and mmap/madvise
; flags. Split out of KvAsm's kvasm.inc (60d7e81), unchanged.
; =============================================================================
%ifndef GRPCASM_SYS_INC
%define GRPCASM_SYS_INC

; ---- Linux x86-64 syscall numbers -------------------------------------------
%define SYS_read            0
%define SYS_write           1
%define SYS_close           3
%define SYS_fstat           5
%define SYS_mmap            9
%define SYS_munmap          11
%define SYS_madvise         28
%define SYS_sendto          44
%define SYS_shutdown        48
%define SYS_exit_group      231
%define SYS_futex           202
%define SYS_getrandom       318

; ---- errno values (raw syscalls return -errno) ------------------------------
%define EINTR               4
%define E2BIG               7
%define EAGAIN              11
%define ENOMEM              12
%define EINVAL              22
%define ENOSPC              28

; ---- mmap / madvise ---------------------------------------------------------
%define PROT_READ           1
%define PROT_WRITE          2
%define MAP_PRIVATE         0x02
%define MAP_ANONYMOUS       0x20
%define MAP_NORESERVE       0x4000
%define MADV_HUGEPAGE       14
%define HUGE_PAGE           0x200000    ; x86-64 transparent huge page (2 MiB)

%endif
