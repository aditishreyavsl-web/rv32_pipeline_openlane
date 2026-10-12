// Main instruction decoder (ID stage), purely combinational.
module rv32_decode (
    input  wire [31:0] instr,
    output reg         reg_write,
    output reg         mem_read,
    output reg         mem_write,
    output reg         alu_src_a_pc,    // 1: ALU A = PC   (AUIPC)
    output reg         alu_src_b_imm,   // 1: ALU B = imm
    output reg  [3:0]  alu_op,
    output reg         branch,
    output reg         jal,
    output reg         jalr
);
    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_REG    = 7'b0110011;

    localparam ALU_ADD   = 4'd0;
    localparam ALU_SUB   = 4'd1;
    localparam ALU_SLL   = 4'd2;
    localparam ALU_SLT   = 4'd3;
    localparam ALU_SLTU  = 4'd4;
    localparam ALU_XOR   = 4'd5;
    localparam ALU_SRL   = 4'd6;
    localparam ALU_SRA   = 4'd7;
    localparam ALU_OR    = 4'd8;
    localparam ALU_AND   = 4'd9;
    localparam ALU_PASSB = 4'd10;

    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire       f7_5   = instr[30];

    // ALU op for OP_IMM / OP_REG. is_reg gates SUB (there is no SUBI).
    function [3:0] arith_op;
        input [2:0] f3;
        input       is_reg;
        input       sub_sra;
        begin
            case (f3)
                3'b000:  arith_op = (is_reg && sub_sra) ? ALU_SUB : ALU_ADD;
                3'b001:  arith_op = ALU_SLL;
                3'b010:  arith_op = ALU_SLT;
                3'b011:  arith_op = ALU_SLTU;
                3'b100:  arith_op = ALU_XOR;
                3'b101:  arith_op = sub_sra ? ALU_SRA : ALU_SRL;
                3'b110:  arith_op = ALU_OR;
                default: arith_op = ALU_AND;
            endcase
        end
    endfunction

    always @* begin
        reg_write     = 1'b0;
        mem_read      = 1'b0;
        mem_write     = 1'b0;
        alu_src_a_pc  = 1'b0;
        alu_src_b_imm = 1'b0;
        alu_op        = ALU_ADD;
        branch        = 1'b0;
        jal           = 1'b0;
        jalr          = 1'b0;

        case (opcode)
            OP_LUI: begin
                reg_write = 1'b1; alu_src_b_imm = 1'b1; alu_op = ALU_PASSB;
            end
            OP_AUIPC: begin
                reg_write = 1'b1; alu_src_a_pc = 1'b1; alu_src_b_imm = 1'b1;
            end
            OP_JAL: begin
                reg_write = 1'b1; jal = 1'b1;
            end
            OP_JALR: begin
                reg_write = 1'b1; jalr = 1'b1; alu_src_b_imm = 1'b1;
            end
            OP_BRANCH: begin
                branch = 1'b1;
            end
            OP_LOAD: begin
                reg_write = 1'b1; mem_read = 1'b1; alu_src_b_imm = 1'b1;
            end
            OP_STORE: begin
                mem_write = 1'b1; alu_src_b_imm = 1'b1;
            end
            OP_IMM: begin
                reg_write = 1'b1; alu_src_b_imm = 1'b1;
                alu_op = arith_op(funct3, 1'b0, f7_5);
            end
            OP_REG: begin
                reg_write = 1'b1;
                alu_op = arith_op(funct3, 1'b1, f7_5);
            end
            default: begin
                // unknown opcode behaves as a NOP
            end
        endcase
    end
endmodule
