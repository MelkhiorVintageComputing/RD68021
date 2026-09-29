| RD68021 -- copy-on-write, from both sides of a user/supervisor boundary.
|
| A kernel enters user mode through RTE. The user program then writes, in every
| shape a copy-on-write fault arrives in, to pages the system has shared
| read-only -- sim/tb/core_cow_tb.sv is the MMU, and answers a user-data write
| to a protected page with a bus error that leaves memory untouched. The
| kernel's bus error handler does what an operating system does: saves the
| user's registers, logs the frame, copies the page, updates the page table
| through a subroutine that does unrelated work on the way, restores the
| registers and returns with DF set, so the processor reruns the write itself
| (UM 6.2.3). One page the kernel completes the write for instead, clearing DF
| (UM 6.2.2). And the page table the handler reads is not mapped the first time,
| so the first fault's handler takes a fault of its own -- a supervisor read,
| handled by the same code two frames deep, and returned from into the handler.
|
| Everything the handler does -- MOVEM, DBF, a bit field, a multiply, a
| subroutine -- overwrites some of the processor's internal state, and RTE has to
| put back what the faulted instruction was in the middle of. The testbench then
| checks memory, the user's registers, the condition codes each shape left, the
| stack pointer, the frames the kernel logged, and that the program is still in
| user mode at the end: its last instruction is privileged, and has to trap.
|
| Not built with crt0.S: this program owns its vector table and its modes.

        .equ    ISP0,    0x3000         | the supervisor stack, growing down
        .equ    KVARS,   0x2000         | +0 faults, +4 log pointer, +8 done, +C SR
        .equ    KLOG,    0x2010         | per fault: address, SSW, stacked SR
        .equ    SHADOW,  0x2400         | the copy's other half
        .equ    PAGER,   0x27F0         | a page address written here maps it
        .equ    RESULTS, 0x6000         | what the user program records
        .equ    USTACK,  0x6000         | the user stack, growing down
        .equ    EMUL,    0x4C00         | the page whose writes the kernel does
        .equ    PTABLE,  0x2600         | the kernel's page table, itself paged

        .section .vectors, "a"
        .long   ISP0                    | 0: the initial interrupt stack pointer
        .long   _start                  | 1: the initial program counter
        .long   buserr                  | 2: bus error
        .rept   5
        .long   unexpected              | 3-7
        .endr
        .long   priv                    | 8: privilege violation
        .rept   247
        .long   unexpected              | 9-255
        .endr

        .text
        .globl  _start
| ---------------------------------------------------------------------------
| The kernel
| ---------------------------------------------------------------------------
_start:
        move.l  #ISP0, %sp
        moveq   #1, %d0
        movec   %d0, %cacr

        lea     KVARS, %a0
        clr.l   (%a0)+                  | no faults yet
        move.l  #KLOG, (%a0)+
        clr.l   (%a0)+                  | not done
        clr.l   (%a0)+

        | The user's pages, written by the kernel before it shares them. The
        | protection is on user writes only, so these go through.
        lea     0x4000, %a0
        move.w  #2047, %d0
1:      clr.l   (%a0)+
        dbf     %d0, 1b
        move.l  #10, 0x4410             | ADDQ's operand
        move.b  #0x01, 0x4510           | BSET's
        move.l  #0x12345678, 0x4610     | BFINS's
        move.l  #0xCAFEBABE, 0x4710     | CAS's, equal to the compare operand
        move.l  #0x5EED5EED, 0x6080     | the memory-to-memory move's source

        | Into user mode the way an operating system starts a process: a format
        | $0 frame naming the program with S clear, and RTE.
        lea     USTACK, %a0
        move.l  %a0, %usp
        move.w  #0x0000, -(%sp)         | format $0, vector offset 0
        pea     user
        move.w  #0x0000, -(%sp)         | the user's status register
        rte

| The bus error handler. The frame is the long one, 46 words, and after the
| MOVEM it starts 60 bytes up the stack.
buserr:
        movem.l %d0-%d7/%a0-%a6, -(%sp)
        lea     KVARS, %a5
        addq.l  #1, (%a5)
        move.l  4(%a5), %a4
        move.l  60+0x10(%sp), %d0       | the data cycle fault address
        move.l  %d0, (%a4)+
        move.w  60+0x0A(%sp), (%a4)+    | the special status word
        move.w  60+0x00(%sp), (%a4)+    | the status register it stacked
        move.l  %a4, 4(%a5)

        move.l  %d0, %d1
        andi.l  #0xFFFFFF00, %d1
        cmpi.l  #PTABLE, %d1
        bne.s   1f
        | The kernel's own page: map it, and let the read be rerun.
        move.l  %d1, PAGER
        bra.s   9f
1:      cmpi.l  #EMUL, %d1
        bne.s   2f
        | This page's writes the kernel completes itself: the data output buffer
        | where the fault says, and DF cleared so that RTE does not rerun it. The
        | only write to this page is an aligned long word.
        move.l  %d0, %a0
        move.l  60+0x18(%sp), (%a0)
        andi.w  #0xFEFF, 60+0x0A(%sp)
        bra.s   9f

2:      | Look the page up. The first time, this read faults.
        move.l  PTABLE, %d5
        | Copy on write: the shared page is copied, the copy mapped writable.
        | There is no address translation here, so the copy comes back to the
        | same page -- what matters is the work, not where it lands.
        move.l  %d1, %a0
        lea     SHADOW, %a1
        moveq   #63, %d2
3:      move.l  (%a0)+, (%a1)+
        dbf     %d2, 3b
        bsr.s   remap
        move.l  %d1, %a0
        lea     SHADOW, %a1
        moveq   #63, %d2
4:      move.l  (%a1)+, (%a0)+
        dbf     %d2, 4b

9:      movem.l (%sp)+, %d0-%d7/%a0-%a6
        rte

| The page table update, and unrelated work on the way that uses the bit-field
| unit, the multiplier and the extension-word latch.
remap:
        move.l  %d1, PAGER
        bfextu  %d1{#16:#8}, %d3
        mulu.l  %d3, %d4
        rts

| The user program's last instruction is privileged. It must trap here.
priv:
        move.w  (%sp), KVARS+0xC        | the status register it stacked
        move.l  #0x600D, KVARS+8
done:   bra.s   done

unexpected:
        move.l  #0x0BAD, KVARS+8
bad:    bra.s   bad

| ---------------------------------------------------------------------------
| The user program. Each shape writes to a page nothing has written yet, so each
| takes its own fault; the kernel's log records them in order.
| ---------------------------------------------------------------------------
user:
        lea     RESULTS, %a5
        move.l  #0x11111111, %d1
        move.l  #0x000000AB, %d2
        move.l  #0xCAFEBABE, %d3
        move.l  #0xFEEDF00D, %d4
        moveq   #0, %d7

        | A plain write.
        lea     0x4010, %a0
        move.l  %d1, (%a0)
        | Postincrement: the register steps once, however many times the write
        | is attempted.
        lea     0x4110, %a0
        move.l  %d1, (%a0)+
        move.l  %a0, (%a5)+             | +$00: $4114
        | Predecrement, word.
        lea     0x4220, %a0
        move.w  %d1, -(%a0)
        move.l  %a0, (%a5)+             | +$04: $421E
        | Memory to memory: the read succeeds, the write faults.
        lea     0x6080, %a1
        lea     0x4330, %a0
        move.l  (%a1), 8(%a0)
        | Read-modify-write.
        lea     0x4410, %a0
        addq.l  #3, (%a0)
        move.w  %ccr, (%a5)+            | +$08: all clear
        lea     0x4510, %a0
        bset    #5, (%a0)
        move.w  %ccr, (%a5)+            | +$0A: Z, the bit was clear
        lea     0x4610, %a0
        bfins   %d2, (%a0){#4:#8}
        lea     0x4710, %a0
        cas.l   %d3, %d4, (%a0)
        move.w  %ccr, (%a5)+            | +$0C: Z, the compare was equal
        | Misaligned, with part of it already written when the fault comes:
        | two bytes on a writable page, the next two on a protected one...
        move.l  %d1, 0x47FE
        | ... one byte, then three ...
        move.l  %d1, 0x48FF
        | ... and across two protected pages, which faults twice.
        move.l  %d1, 0x4AFE
        | The page the kernel writes for.
        lea     EMUL+0x40, %a0
        move.l  %d4, (%a0)

        | The stack, where most copy-on-write faults really come from.
        move.l  #0x5F00, %sp
        jsr     sub                     | the return address faults
        move.l  #0x5E00, %sp
        move.l  #0xA6A6A6A6, %a6
        link    %a6, #-8                | the saved frame pointer faults
        move.l  %a6, (%a5)+             | +$0E: $5DFC
        unlk    %a6
        move.l  %sp, (%a5)+             | +$12: $5E00
        move.l  %a6, (%a5)+             | +$16: $A6A6A6A6
        move.l  #0x5D08, %sp
        movem.l %d1-%d4, -(%sp)         | two registers in, then a fault
        move.l  %sp, (%a5)+             | +$1A: $5CF8
        move.l  #0x5B00, %sp
        lea     0x1234, %a0
        pea     (%a0)
        move.l  %sp, (%a5)+             | +$1E: $5AFC
        move.l  #0x5A00, %sp
        move.b  %d1, -(%sp)             | A7 steps by two
        move.l  %sp, (%a5)+             | +$22: $59FE

        | Still a user: this has to trap.
        move.w  #0x2700, %sr
never:  bra.s   never

sub:    addq.l  #1, %d7
        rts
