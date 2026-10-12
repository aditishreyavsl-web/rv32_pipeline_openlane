`timescale 1ns/1ps

// Self-checking testbench for rv32_core with behavioural memories.
//
// The test program ends by storing to TOHOST (0xFFC):
//     1 = PASS, anything else = FAIL.
//
//   vvp sim/tb.vvp [+hex=sw/test.hex] [+trace]
//   (compile with -DVCD to dump sim/tb_rv32_core.vcd)
module tb_rv32_core;
    localparam [31:0] TOHOST    = 32'h0000_0FFC;
    localparam        MAXCYCLES = 200000;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_re;
    wire [31:0] imem_rdata, dmem_rdata;

    rv32_core dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_re    (dmem_re),
        .dmem_rdata (dmem_rdata)
    );

    // ---------------- behavioural memories (4 KB each) ----------------
    reg [31:0] imem [0:1023];
    reg [31:0] dmem [0:1023];
    reg [1023:0] hexfile;
    integer k;

    initial begin
        for (k = 0; k < 1024; k = k + 1) begin
            imem[k] = 32'h00000013;   // NOP
            dmem[k] = 32'd0;
        end
        if (!$value$plusargs("hex=%s", hexfile)) hexfile = "sw/test.hex";
        $readmemh(hexfile, imem);
    end

    assign imem_rdata = imem[imem_addr[11:2]];     // combinational read
    assign dmem_rdata = dmem[dmem_addr[11:2]];     // combinational read

    // byte-strobe write (read-modify-write on a temp)
    reg [31:0] wtmp;
    always @(posedge clk) begin
        if (|dmem_wstrb) begin
            wtmp = dmem[dmem_addr[11:2]];
            if (dmem_wstrb[0]) wtmp[7:0]   = dmem_wdata[7:0];
            if (dmem_wstrb[1]) wtmp[15:8]  = dmem_wdata[15:8];
            if (dmem_wstrb[2]) wtmp[23:16] = dmem_wdata[23:16];
            if (dmem_wstrb[3]) wtmp[31:24] = dmem_wdata[31:24];
            dmem[dmem_addr[11:2]] <= wtmp;
        end
    end

    // ---------------- reset / waveform ----------------
    initial begin
`ifdef VCD
        $dumpfile("sim/tb_rv32_core.vcd");
        $dumpvars(0, tb_rv32_core);
`endif
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
    end

    // ---------------- checker ----------------
    integer cycles = 0;
    integer i;

    task dump_regs;
        begin
            for (i = 0; i < 32; i = i + 4)
                $display("  x%0d=%08h  x%0d=%08h  x%0d=%08h  x%0d=%08h",
                         i,   dut.rf_flat[i*32     +: 32],
                         i+1, dut.rf_flat[(i+1)*32 +: 32],
                         i+2, dut.rf_flat[(i+2)*32 +: 32],
                         i+3, dut.rf_flat[(i+3)*32 +: 32]);
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;

            if ($test$plusargs("trace"))
                $display("[%0d] pc=%08h instr=%08h stall=%b taken=%b fwdA=%b fwdB=%b | WB we=%b rd=x%0d data=%08h",
                         cycles, imem_addr, imem_rdata, dut.stall, dut.ex_taken,
                         dut.fwd_a, dut.fwd_b, dut.wb_we, dut.wb_rd, dut.wb_data);

            if (dmem_wstrb == 4'hF && dmem_addr == TOHOST) begin
                if (dmem_wdata == 32'd1) begin
                    $display("[TB] PASS after %0d cycles", cycles);
                end else begin
                    $display("[TB] FAIL (tohost=%0d) after %0d cycles", dmem_wdata, cycles);
                    dump_regs;
                end
                $finish;
            end

            if (cycles >= MAXCYCLES) begin
                $display("[TB] TIMEOUT after %0d cycles", cycles);
                dump_regs;
                $finish;
            end
        end
    end
endmodule
