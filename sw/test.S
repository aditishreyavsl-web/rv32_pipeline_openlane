# ===================================================================
# test.S - self-checking program for the 5-stage RV32I core.
#
#  1. ALU->ALU forwarding (EX/MEM, MEM/WB, regfile write-through)
#  2. Load-use stall, byte/half loads & stores, store-data forwarding
#  3. Branch loops, taken-branch flush, signed/unsigned compares
#  4. JAL / JALR
#  5. LUI / AUIPC / shifts / SLT / logic ops
#  6. x0 stays zero
#  7. Fibonacci kernel (load -> add -> store loop)
#  8. Bubble sort (dense load-use + data-dependent branches)
#
# x29 counts completed sections, so skipping code can never pass.
# Success: store 1 to TOHOST (0xFFC); failure: store 2.
# ===================================================================
    li   x29, 0              # progress counter

# ---- 1. ALU->ALU forwarding (EX/MEM and MEM/WB paths) ----
    li   x1, 5
    li   x2, 7
    add  x3, x1, x2          # 12
    add  x4, x3, x1          # 17  (EX/MEM -> EX forward on x3)
    add  x5, x4, x3          # 29  (EX/MEM on x4, MEM/WB on x3)
    sub  x6, x5, x1          # 24
    nop
    nop
    add  x8, x6, x1          # 29  (3 apart: regfile write-through)
    li   x7, 12
    bne  x3, x7, fail
    li   x7, 17
    bne  x4, x7, fail
    li   x7, 29
    bne  x5, x7, fail
    li   x7, 24
    bne  x6, x7, fail
    li   x7, 29
    bne  x8, x7, fail

    addi x29, x29, 1         # section done

# ---- 2. Load-use hazard + sub-word loads/stores ----
    li   x10, 0x100
    li   x11, 0xdeadbeef
    sw   x11, 0(x10)
    lw   x12, 0(x10)
    add  x13, x12, x0        # load-use: needs 1 stall cycle
    bne  x13, x11, fail

    lb   x14, 0(x10)         # 0xef -> sign-extended
    li   x15, -17
    bne  x14, x15, fail
    lbu  x16, 1(x10)         # 0xbe
    li   x17, 0xbe
    bne  x16, x17, fail
    lh   x18, 2(x10)         # 0xdead -> sign-extended
    li   x19, 0xffffdead
    bne  x18, x19, fail
    lhu  x20, 2(x10)         # 0xdead
    li   x7, 0xdead
    bne  x20, x7, fail

    sb   x0, 0(x10)          # -> 0xdeadbe00
    lw   x12, 0(x10)
    li   x7, 0xdeadbe00
    bne  x12, x7, fail
    sh   x0, 2(x10)          # -> 0x0000be00
    lw   x12, 0(x10)
    li   x7, 0xbe00
    bne  x12, x7, fail

    # store-data forwarding: sw uses a value produced by the previous op
    li   x1, 0x1234
    addi x2, x1, 1           # 0x1235
    sw   x2, 8(x10)          # rs2 comes from EX/MEM forward
    lw   x3, 8(x10)
    bne  x3, x2, fail

    addi x29, x29, 1         # section done

# ---- 3. Branch loop + taken-branch flush ----
    li   x21, 0
    li   x22, 3
loop:
    addi x21, x21, 1
    bne  x21, x22, loop      # taken twice, then falls through
    bne  x21, x22, fail

    li   x23, 0
    beq  x0, x0, skip        # taken: following 2 instrs must be flushed
    addi x23, x23, 1
    addi x23, x23, 1
skip:
    bne  x23, x0, fail

    # signed vs unsigned compares
    li   x1, -1
    li   x2, 1
    blt  x1, x2, ok_blt      # signed: -1 < 1  -> taken
    j    fail
ok_blt:
    bltu x1, x2, fail        # unsigned: 0xffffffff < 1 -> not taken
    bge  x2, x1, ok_bge      # signed: 1 >= -1 -> taken
    j    fail
ok_bge:
    bgeu x2, x1, fail        # unsigned: 1 >= 0xffffffff -> not taken

    addi x29, x29, 1         # section done

# ---- 4. JAL / JALR ----
    li   x24, 0
    jal  x1, sub1            # link in x1
    addi x24, x24, 100       # executed after return
    li   x7, 142
    bne  x24, x7, fail
    j    after_sub
sub1:
    addi x24, x24, 42
    jalr x0, 0(x1)           # return; x1 forwarded from EX/MEM or MEM/WB
after_sub:

    addi x29, x29, 1         # section done

# ---- 5. LUI / AUIPC / shifts / SLT ----
    lui  x25, 0x12345
    li   x7, 0x12345000
    bne  x25, x7, fail
    auipc x26, 0
    auipc x27, 0
    sub  x28, x27, x26       # consecutive AUIPCs differ by 4
    li   x7, 4
    bne  x28, x7, fail

    li   x1, -8
    srai x2, x1, 1           # -4
    srli x3, x1, 28          # 0xf
    slli x4, x1, 2           # -32
    slt  x5, x1, x0          # 1
    sltu x6, x1, x0          # 0
    li   x7, -4
    bne  x2, x7, fail
    li   x7, 15
    bne  x3, x7, fail
    li   x7, -32
    bne  x4, x7, fail
    li   x7, 1
    bne  x5, x7, fail
    bne  x6, x0, fail

    li   x1, 0xf0f0
    li   x2, 0x0ff0
    and  x3, x1, x2          # 0x00f0
    or   x4, x1, x2          # 0xfff0
    xor  x5, x1, x2          # 0xff00
    li   x7, 0x00f0
    bne  x3, x7, fail
    li   x7, 0xfff0
    bne  x4, x7, fail
    li   x7, 0xff00
    bne  x5, x7, fail

    addi x29, x29, 1         # section done

# ---- 6. x0 must stay zero ----
    addi x0, x0, 55
    bne  x0, x0, fail
    li   x1, 3
    add  x2, x0, x1          # x0 is read as 0 even right after a write attempt
    bne  x2, x1, fail

    addi x29, x29, 1         # section done

# ---- 7. Fibonacci kernel ----
    li   x10, 0x200          # array base
    li   x1, 0
    li   x2, 1
    sw   x1, 0(x10)
    sw   x2, 4(x10)
    addi x11, x10, 8         # write pointer
    li   x5, 2               # i
    li   x6, 12              # n
fib_loop:
    lw   x3, -8(x11)
    lw   x4, -4(x11)
    add  x3, x3, x4          # load-use on x4
    sw   x3, 0(x11)
    addi x11, x11, 4
    addi x5, x5, 1
    bne  x5, x6, fib_loop

    lw   x7, -4(x11)         # fib(11)
    li   x8, 89
    bne  x7, x8, fail
    lw   x7, 20(x10)         # fib(5) = 5
    li   x8, 5
    bne  x7, x8, fail

    addi x29, x29, 1         # section done

# ---- 8. Bubble sort ----
    li   x10, 0x300          # base of array
    li   x1, 42
    sw   x1, 0(x10)
    li   x1, -7
    sw   x1, 4(x10)
    li   x1, 19
    sw   x1, 8(x10)
    li   x1, 0
    sw   x1, 12(x10)
    li   x1, 100
    sw   x1, 16(x10)
    li   x1, -50
    sw   x1, 20(x10)
    li   x1, 3
    sw   x1, 24(x10)
    li   x1, 19
    sw   x1, 28(x10)

    li   x5, 8               # n
outer:
    addi x5, x5, -1          # passes remaining
    beqz x5, check
    li   x6, 0               # j
    mv   x11, x10            # pointer
inner:
    lw   x7, 0(x11)
    lw   x8, 4(x11)
    bge  x8, x7, noswap      # signed compare; load-use on x8
    sw   x8, 0(x11)
    sw   x7, 4(x11)
noswap:
    addi x11, x11, 4
    addi x6, x6, 1
    bne  x6, x5, inner
    j    outer

check:
    li   x6, 7               # 7 adjacent pairs
    mv   x11, x10
chk_loop:
    lw   x7, 0(x11)
    lw   x8, 4(x11)
    blt  x8, x7, fail        # must be non-decreasing
    addi x11, x11, 4
    addi x6, x6, -1
    bnez x6, chk_loop
    lw   x7, 0(x10)          # smallest = -50
    li   x8, -50
    bne  x7, x8, fail
    lw   x7, 28(x10)         # largest = 100
    li   x8, 100
    bne  x7, x8, fail

    addi x29, x29, 1         # section done

    li   x7, 8
    bne  x29, x7, fail       # all 8 sections must have run

pass:
    li   x30, 0xffc
    li   x31, 1
    sw   x31, 0(x30)
done_p:
    j    done_p

fail:
    li   x30, 0xffc
    li   x31, 2
    sw   x31, 0(x30)
done_f:
    j    done_f
