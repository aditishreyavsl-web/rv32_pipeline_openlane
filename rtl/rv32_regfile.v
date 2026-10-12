// 31 x 32-bit flip-flop register file (x0 hardwired to zero),
// 2 async read ports, 1 sync write port, async active-low reset.
// Write-through bypass: a value being written this cycle is visible on the
// read ports (covers the WB -> ID, 3-instructions-apart RAW hazard).
//
// Built from individual registers (not a memory array) so that synthesis
// maps it straight to flip-flops with async reset.
module rv32_regfile (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          we,
    input  wire [4:0]    waddr,
    input  wire [31:0]   wdata,
    input  wire [4:0]    raddr1,
    input  wire [4:0]    raddr2,
    output wire [31:0]   rdata1,
    output wire [31:0]   rdata2,
    output wire [1023:0] rf_flat      // all 32 registers, for the testbench
);
    genvar g;
    assign rf_flat[31:0] = 32'd0;     // x0

    generate
        for (g = 1; g < 32; g = g + 1) begin : gen_reg
            reg [31:0] r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)                       r <= 32'd0;
                else if (we && (waddr == g))      r <= wdata;
            end
            assign rf_flat[g*32 +: 32] = r;
        end
    endgenerate

    wire [31:0] rd1_raw = rf_flat[raddr1*32 +: 32];
    wire [31:0] rd2_raw = rf_flat[raddr2*32 +: 32];

    assign rdata1 = (raddr1 == 5'd0)           ? 32'd0 :
                    (we && waddr == raddr1)    ? wdata : rd1_raw;
    assign rdata2 = (raddr2 == 5'd0)           ? 32'd0 :
                    (we && waddr == raddr2)    ? wdata : rd2_raw;
endmodule
