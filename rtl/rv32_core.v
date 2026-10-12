// =====================================================================
//  rv32_core : 5-stage pipelined RV32I core  (IF -> ID -> EX -> MEM -> WB)
//
//  * Memories are OUTSIDE the core (separate instruction / data ports,
//    combinational read, byte-strobe write), so no SRAM macro is needed.
//  * Async active-low reset.
//
//  Hazards
//    - RAW data    : forwarding EX/MEM->EX and MEM/WB->EX, plus regfile
//                    write-through (WB->ID)
//    - Load-use    : 1-cycle stall (freeze PC + IF/ID, bubble into ID/EX)
//    - Control     : predict not-taken; branch/jump resolves in EX; a taken
//                    one flushes IF/ID and ID/EX (2-cycle penalty)
// =====================================================================
module rv32_core (
    input  wire        clk,
    input  wire        rst_n,

    // instruction port
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // data port
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_re,
    input  wire [31:0] dmem_rdata
);
    localparam [31:0] NOP = 32'h00000013;   // addi x0, x0, 0

    // ------------------------------------------------------------------
    // Cross-stage signals
    // ------------------------------------------------------------------
    wire        stall;            // load-use stall
    wire        ex_taken;         // branch / jump taken in EX
    wire [31:0] ex_target;        // its target
    wire [31:0] wb_data;
    wire        wb_we;
    wire [4:0]  wb_rd;

    // ==================================================================
    // IF
    // ==================================================================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] pc_next  = ex_taken ? ex_target :
                           stall    ? pc        : pc_plus4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc <= 32'd0;
        else        pc <= pc_next;
    end

    assign imem_addr = pc;

    // ---- IF/ID ----
    reg [31:0] ifid_pc;
    reg [31:0] ifid_instr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifid_pc    <= 32'd0;
            ifid_instr <= NOP;
        end else if (ex_taken) begin           // flush -> NOP
            ifid_pc    <= 32'd0;
            ifid_instr <= NOP;
        end else if (!stall) begin             // (stall -> hold)
            ifid_pc    <= pc;
            ifid_instr <= imem_rdata;
        end
    end

    // ==================================================================
    // ID
    // ==================================================================
    wire [4:0] id_rs1    = ifid_instr[19:15];
    wire [4:0] id_rs2    = ifid_instr[24:20];
    wire [4:0] id_rd     = ifid_instr[11:7];
    wire [2:0] id_funct3 = ifid_instr[14:12];

    wire        id_reg_write, id_mem_read, id_mem_write;
    wire        id_alu_src_a_pc, id_alu_src_b_imm;
    wire [3:0]  id_alu_op;
    wire        id_branch, id_jal, id_jalr;
    wire [31:0] id_imm;
    wire [31:0] id_rdata1, id_rdata2;
    wire [1023:0] rf_flat;

    rv32_decode u_dec (
        .instr         (ifid_instr),
        .reg_write     (id_reg_write),
        .mem_read      (id_mem_read),
        .mem_write     (id_mem_write),
        .alu_src_a_pc  (id_alu_src_a_pc),
        .alu_src_b_imm (id_alu_src_b_imm),
        .alu_op        (id_alu_op),
        .branch        (id_branch),
        .jal           (id_jal),
        .jalr          (id_jalr)
    );

    rv32_imm_gen u_imm (.instr(ifid_instr), .imm(id_imm));

    rv32_regfile u_rf (
        .clk    (clk),
        .rst_n  (rst_n),
        .we     (wb_we),
        .waddr  (wb_rd),
        .wdata  (wb_data),
        .raddr1 (id_rs1),
        .raddr2 (id_rs2),
        .rdata1 (id_rdata1),
        .rdata2 (id_rdata2),
        .rf_flat(rf_flat)
    );

    // ---- ID/EX ----
    reg [31:0] idex_pc, idex_rdata1, idex_rdata2, idex_imm;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd;
    reg [2:0]  idex_funct3;
    reg [3:0]  idex_alu_op;
    reg        idex_alu_src_a_pc, idex_alu_src_b_imm;
    reg        idex_reg_write, idex_mem_read, idex_mem_write;
    reg        idex_branch, idex_jal, idex_jalr;

    // Load-use hazard: instruction in EX is a load whose rd is needed in ID
    assign stall = idex_mem_read && (idex_rd != 5'd0) &&
                   (idex_rd == id_rs1 || idex_rd == id_rs2);

    // Bubble: squash the control bits (data fields may hold anything)
    wire idex_bubble = ex_taken | stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idex_pc            <= 32'd0;
            idex_rdata1        <= 32'd0;
            idex_rdata2        <= 32'd0;
            idex_imm           <= 32'd0;
            idex_rs1           <= 5'd0;
            idex_rs2           <= 5'd0;
            idex_rd            <= 5'd0;
            idex_funct3        <= 3'd0;
            idex_alu_op        <= 4'd0;
            idex_alu_src_a_pc  <= 1'b0;
            idex_alu_src_b_imm <= 1'b0;
            idex_reg_write     <= 1'b0;
            idex_mem_read      <= 1'b0;
            idex_mem_write     <= 1'b0;
            idex_branch        <= 1'b0;
            idex_jal           <= 1'b0;
            idex_jalr          <= 1'b0;
        end else begin
            idex_pc            <= ifid_pc;
            idex_rdata1        <= id_rdata1;
            idex_rdata2        <= id_rdata2;
            idex_imm           <= id_imm;
            idex_rs1           <= id_rs1;
            idex_rs2           <= id_rs2;
            idex_rd            <= id_rd;
            idex_funct3        <= id_funct3;
            idex_alu_op        <= id_alu_op;
            idex_alu_src_a_pc  <= id_alu_src_a_pc;
            idex_alu_src_b_imm <= id_alu_src_b_imm;
            idex_reg_write     <= idex_bubble ? 1'b0 : id_reg_write;
            idex_mem_read      <= idex_bubble ? 1'b0 : id_mem_read;
            idex_mem_write     <= idex_bubble ? 1'b0 : id_mem_write;
            idex_branch        <= idex_bubble ? 1'b0 : id_branch;
            idex_jal           <= idex_bubble ? 1'b0 : id_jal;
            idex_jalr          <= idex_bubble ? 1'b0 : id_jalr;
        end
    end

    // ==================================================================
    // EX
    // ==================================================================
    reg [31:0] exmem_result, exmem_wdata;
    reg [4:0]  exmem_rd;
    reg [2:0]  exmem_funct3;
    reg        exmem_reg_write, exmem_mem_read, exmem_mem_write;

    // ---- forwarding (EX/MEM has priority: it is the more recent value) ----
    reg [1:0] fwd_a, fwd_b;
    always @* begin
        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs1)
            fwd_a = 2'b10;
        else if (wb_we && wb_rd != 5'd0 && wb_rd == idex_rs1)
            fwd_a = 2'b01;
        else
            fwd_a = 2'b00;

        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs2)
            fwd_b = 2'b10;
        else if (wb_we && wb_rd != 5'd0 && wb_rd == idex_rs2)
            fwd_b = 2'b01;
        else
            fwd_b = 2'b00;
    end

    wire [31:0] ex_rs1 = (fwd_a == 2'b10) ? exmem_result :
                         (fwd_a == 2'b01) ? wb_data      : idex_rdata1;
    wire [31:0] ex_rs2 = (fwd_b == 2'b10) ? exmem_result :
                         (fwd_b == 2'b01) ? wb_data      : idex_rdata2;

    wire [31:0] alu_a = idex_alu_src_a_pc  ? idex_pc  : ex_rs1;
    wire [31:0] alu_b = idex_alu_src_b_imm ? idex_imm : ex_rs2;
    wire [31:0] alu_y;

    rv32_alu u_alu (.a(alu_a), .b(alu_b), .op(idex_alu_op), .y(alu_y));

    // ---- branch condition ----
    reg br_cond;
    always @* begin
        case (idex_funct3)
            3'b000:  br_cond = (ex_rs1 == ex_rs2);                    // BEQ
            3'b001:  br_cond = (ex_rs1 != ex_rs2);                    // BNE
            3'b100:  br_cond = ($signed(ex_rs1) <  $signed(ex_rs2));  // BLT
            3'b101:  br_cond = ($signed(ex_rs1) >= $signed(ex_rs2));  // BGE
            3'b110:  br_cond = (ex_rs1 <  ex_rs2);                    // BLTU
            3'b111:  br_cond = (ex_rs1 >= ex_rs2);                    // BGEU
            default: br_cond = 1'b0;
        endcase
    end

    assign ex_taken  = idex_jal | idex_jalr | (idex_branch & br_cond);
    assign ex_target = idex_jalr ? ((ex_rs1 + idex_imm) & 32'hFFFFFFFE)
                                 : (idex_pc + idex_imm);

    // JAL/JALR write PC+4 to rd (also makes the link value forwardable)
    wire [31:0] ex_result = (idex_jal | idex_jalr) ? (idex_pc + 32'd4) : alu_y;

    // ---- EX/MEM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_result    <= 32'd0;
            exmem_wdata     <= 32'd0;
            exmem_rd        <= 5'd0;
            exmem_funct3    <= 3'd0;
            exmem_reg_write <= 1'b0;
            exmem_mem_read  <= 1'b0;
            exmem_mem_write <= 1'b0;
        end else begin
            exmem_result    <= ex_result;
            exmem_wdata     <= ex_rs2;         // store data (forwarded)
            exmem_rd        <= idex_rd;
            exmem_funct3    <= idex_funct3;
            exmem_reg_write <= idex_reg_write;
            exmem_mem_read  <= idex_mem_read;
            exmem_mem_write <= idex_mem_write;
        end
    end

    // ==================================================================
    // MEM : drive the data port, align stores / extend loads
    // ==================================================================
    wire [1:0] m_off = exmem_result[1:0];

    // ---- store: byte strobes + data replication ----
    reg [3:0]  m_strb;
    reg [31:0] m_sdata;
    always @* begin
        m_strb  = 4'b0000;
        m_sdata = exmem_wdata;
        if (exmem_mem_write) begin
            case (exmem_funct3[1:0])
                2'b00: begin                                   // SB
                    m_strb  = 4'b0001 << m_off;
                    m_sdata = {4{exmem_wdata[7:0]}};
                end
                2'b01: begin                                   // SH
                    m_strb  = m_off[1] ? 4'b1100 : 4'b0011;
                    m_sdata = {2{exmem_wdata[15:0]}};
                end
                default: begin                                 // SW
                    m_strb  = 4'b1111;
                    m_sdata = exmem_wdata;
                end
            endcase
        end
    end

    assign dmem_addr  = exmem_result;
    assign dmem_wdata = m_sdata;
    assign dmem_wstrb = m_strb;
    assign dmem_re    = exmem_mem_read;

    // ---- load: shift to the addressed byte, then sign/zero extend ----
    wire [31:0] m_shifted = dmem_rdata >> {m_off, 3'b000};
    reg  [31:0] m_load;
    always @* begin
        case (exmem_funct3)
            3'b000:  m_load = {{24{m_shifted[7]}},  m_shifted[7:0]};    // LB
            3'b001:  m_load = {{16{m_shifted[15]}}, m_shifted[15:0]};   // LH
            3'b100:  m_load = {24'd0, m_shifted[7:0]};                  // LBU
            3'b101:  m_load = {16'd0, m_shifted[15:0]};                 // LHU
            default: m_load = dmem_rdata;                               // LW
        endcase
    end

    // ---- MEM/WB ----
    reg [31:0] memwb_result, memwb_rdata;
    reg [4:0]  memwb_rd;
    reg        memwb_reg_write, memwb_mem_read;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memwb_result    <= 32'd0;
            memwb_rdata     <= 32'd0;
            memwb_rd        <= 5'd0;
            memwb_reg_write <= 1'b0;
            memwb_mem_read  <= 1'b0;
        end else begin
            memwb_result    <= exmem_result;
            memwb_rdata     <= m_load;
            memwb_rd        <= exmem_rd;
            memwb_reg_write <= exmem_reg_write;
            memwb_mem_read  <= exmem_mem_read;
        end
    end

    // ==================================================================
    // WB
    // ==================================================================
    assign wb_data = memwb_mem_read ? memwb_rdata : memwb_result;
    assign wb_we   = memwb_reg_write;
    assign wb_rd   = memwb_rd;

endmodule
