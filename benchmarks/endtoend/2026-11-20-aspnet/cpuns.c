/*
 * cpuns.c — prints another process's CPU time in nanoseconds: every thread of it, user and
 * system, the kernel's own sum (clock_getcpuclockid + clock_gettime).
 *
 * Why not /proc: /proc/PID/stat counts in clock ticks (10 ms here), and this VM's kernel
 * reports zeros in /proc/PID/schedstat and sum_exec_runtime (no schedstats). The process CPU
 * clock is exact and needs no privilege. bench.sh reads it around each measured run, so a
 * .NET server's GC and JIT threads are counted with its worker.
 *
 * Usage: cpuns PID   (exit 1: no such process; 2: the clock cannot be read)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/**
 * Prints PID's CPU time in ns on one line.
 * @param argc  2
 * @param argv  argv[1] = the process id
 * @return 0, 1 (no such process / bad argument) or 2 (clock_gettime failed).
 */
int main(int argc, char **argv) {
  if (argc != 2) return 1;
  clockid_t clock;
  if (clock_getcpuclockid((pid_t)atoi(argv[1]), &clock) != 0) return 1;
  struct timespec t;
  if (clock_gettime(clock, &t) != 0) return 2;
  printf("%lld\n", (long long)t.tv_sec * 1000000000LL + t.tv_nsec);
  return 0;
}
