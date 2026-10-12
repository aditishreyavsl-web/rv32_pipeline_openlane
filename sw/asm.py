#!/usr/bin/env python3
"""
Minimal RV32I assembler -> $readmemh hex (one 32-bit word per line).

Usage: asm.py prog.s prog.hex

Supports: all RV32I base instructions except FENCE/ECALL/EBREAK,
labels, '#' and '//' comments, .word, and the pseudo-instructions
nop, li, mv, not, neg, j, jr, ret, beqz, bnez.
"""
import re
import sys

ABI = ("zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 "
       "s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6").split()
REGS = {f"x{i}": i for i in range(32)}
REGS.update({n: i for i, n in enumerate(ABI)})
REGS["fp"] = 8

R_TYPE = {  # name: (funct7, funct3)
    "add": (0x00, 0), "sub": (0x20, 0), "sll": (0x00, 1), "slt": (0x00, 2),
    "sltu": (0x00, 3), "xor": (0x00, 4), "srl": (0x00, 5), "sra": (0x20, 5),
    "or": (0x00, 6), "and": (0x00, 7),
}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
I_SHIFT = {"slli": (0x00, 1), "srli": (0x00, 5), "srai": (0x20, 5)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class AsmError(Exception):
    pass


def reg(s):
    s = s.strip()
    if s not in REGS:
        raise AsmError(f"bad register '{s}'")
    return REGS[s]


def num(s):
    return int(s.strip(), 0)


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def check_range(v, bits, what):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if not lo <= v <= hi:
        raise AsmError(f"{what} {v} out of range [{lo},{hi}]")


def split_args(s):
    return [a.strip() for a in s.split(",")] if s.strip() else []


def mem_operand(s):
    m = re.fullmatch(r"\s*(-?\w+)?\s*\(\s*(\w+)\s*\)\s*", s)
    if not m:
        raise AsmError(f"bad memory operand '{s}'")
    return num(m.group(1) or "0"), reg(m.group(2))


# ---- encoders ----
def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(imm, rs1, f3, rd, op):
    check_range(imm, 12, "immediate")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(imm, rs2, rs1, f3, op):
    check_range(imm, 12, "offset")
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def enc_b(imm, rs2, rs1, f3, op):
    check_range(imm, 13, "branch offset")
    if imm & 1:
        raise AsmError("branch offset must be even")
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | \
           (rs1 << 15) | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op


def enc_u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def enc_j(imm, rd, op):
    check_range(imm, 21, "jump offset")
    if imm & 1:
        raise AsmError("jump offset must be even")
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | op


def expand(mn, args):
    """Expand pseudo-instructions into real ones (fixed size per input)."""
    if mn == "nop":
        return [("addi", ["x0", "x0", "0"])]
    if mn == "mv":
        return [("addi", [args[0], args[1], "0"])]
    if mn == "not":
        return [("xori", [args[0], args[1], "-1"])]
    if mn == "neg":
        return [("sub", [args[0], "x0", args[1]])]
    if mn == "j":
        return [("jal", ["x0", args[0]])]
    if mn == "jr":
        return [("jalr", ["x0", f"0({args[0]})"])]
    if mn == "ret":
        return [("jalr", ["x0", "0(ra)"])]
    if mn == "beqz":
        return [("beq", [args[0], "x0", args[1]])]
    if mn == "bnez":
        return [("bne", [args[0], "x0", args[1]])]
    if mn == "li":
        v = num(args[1]) & 0xFFFFFFFF
        sv = sext(v, 32)
        if -2048 <= sv <= 2047:
            return [("addi", [args[0], "x0", str(sv)])]
        lo = sext(v, 12)
        hi = ((v - lo) >> 12) & 0xFFFFF
        return [("lui", [args[0], str(hi)]), ("addi", [args[0], args[0], str(lo)])]
    if mn == "jal" and len(args) == 1:
        return [("jal", ["ra", args[0]])]
    if mn == "jalr" and len(args) == 1:
        return [("jalr", ["ra", f"0({args[0]})"])]
    return [(mn, args)]


def encode(mn, a, pc, labels):
    def target(s):
        s = s.strip()
        return labels[s] - pc if s in labels else num(s)

    if mn in R_TYPE:
        f7, f3 = R_TYPE[mn]
        return enc_r(f7, reg(a[2]), reg(a[1]), f3, reg(a[0]), 0x33)
    if mn in I_ALU:
        return enc_i(num(a[2]), reg(a[1]), I_ALU[mn], reg(a[0]), 0x13)
    if mn in I_SHIFT:
        f7, f3 = I_SHIFT[mn]
        sh = num(a[2])
        if not 0 <= sh < 32:
            raise AsmError("shift amount out of range")
        return enc_r(f7, sh, reg(a[1]), f3, reg(a[0]), 0x13)
    if mn in LOADS:
        off, rs1 = mem_operand(a[1])
        return enc_i(off, rs1, LOADS[mn], reg(a[0]), 0x03)
    if mn in STORES:
        off, rs1 = mem_operand(a[1])
        return enc_s(off, reg(a[0]), rs1, STORES[mn], 0x23)
    if mn in BRANCHES:
        return enc_b(target(a[2]), reg(a[1]), reg(a[0]), BRANCHES[mn], 0x63)
    if mn == "lui":
        return enc_u(num(a[1]), reg(a[0]), 0x37)
    if mn == "auipc":
        return enc_u(num(a[1]), reg(a[0]), 0x17)
    if mn == "jal":
        return enc_j(target(a[1]), reg(a[0]), 0x6F)
    if mn == "jalr":
        off, rs1 = mem_operand(a[1])
        return enc_i(off, rs1, 0, reg(a[0]), 0x67)
    raise AsmError(f"unknown instruction '{mn}'")


def assemble(text):
    labels, items, pc = {}, [], 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = re.split(r"#|//", raw)[0].strip()
        while True:  # peel off any leading labels
            m = re.match(r"([A-Za-z_]\w*)\s*:\s*(.*)", line)
            if not m:
                break
            labels[m.group(1)] = pc
            line = m.group(2)
        if not line:
            continue
        parts = line.split(None, 1)
        mn, args = parts[0].lower(), split_args(parts[1] if len(parts) > 1 else "")
        try:
            if mn == ".word":
                items.append((lineno, ".word", args, pc)); pc += 4
            else:
                for m2, a2 in expand(mn, args):
                    items.append((lineno, m2, a2, pc)); pc += 4
        except (AsmError, ValueError, IndexError) as e:
            raise AsmError(f"line {lineno}: {e}")
    words = []
    for lineno, mn, a, ipc in items:
        try:
            words.append(num(a[0]) & 0xFFFFFFFF if mn == ".word" else encode(mn, a, ipc, labels))
        except (AsmError, ValueError, IndexError) as e:
            raise AsmError(f"line {lineno}: {e}")
    return words, labels


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: asm.py prog.s prog.hex")
    try:
        words, _ = assemble(open(sys.argv[1]).read())
    except AsmError as e:
        sys.exit(f"{sys.argv[1]}: {e}")
    with open(sys.argv[2], "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")
    print(f"{sys.argv[1]}: {len(words)} instructions -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
