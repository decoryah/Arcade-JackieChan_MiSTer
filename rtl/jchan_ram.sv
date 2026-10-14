// Small RAM building blocks (inferred block RAM, synchronous read, byte enables on the CPU port).
//
//   jchan_spram   one port (the work RAMs, mcuram)
//   jchan_tdpram  two independent read / write ports on one clock (shared RAM; tile RAM, palette, the sprite list banks and the sprite rings use
//                 port B read-only or read + clear)
//
// Reads return the data one clock after the address (read-first: a read in the clock of a write to the same address sees the old word).
// The arrays are named `mem` so a testbench can dump them by hierarchical reference.
`default_nettype none
module jchan_spram #(
    parameter AW = 15
) (
    input  wire          clk,
    input  wire          we,
    input  wire [1:0]    be,
    input  wire [AW-1:0] addr,
    input  wire [15:0]   wdata,
    output logic [15:0]  rdata
);
`ifdef ALTERA_RESERVED_QIS
    // two byte arrays: Quartus does not infer a byte-enabled RAM from partial writes to a 16-bit word array (the RAM became 500 K registers)
    logic [7:0] mem_h [0:(1 << AW) - 1];
    logic [7:0] mem_l [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we && be[1]) mem_h[addr] <= wdata[15:8];
        if (we && be[0]) mem_l[addr] <= wdata[7:0];
        rdata <= {mem_h[addr], mem_l[addr]};
    end
`else
    logic [15:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) begin
            if (be[1]) mem[addr][15:8] <= wdata[15:8];
            if (be[0]) mem[addr][7:0]  <= wdata[7:0];
        end
        rdata <= mem[addr];
    end
`endif
endmodule

module jchan_tdpram #(
    parameter AW = 13,
    parameter DEPTH = (1 << AW)
) (
    input  wire          clk,
    input  wire          a_we,
    input  wire [1:0]    a_be,
    input  wire [AW-1:0] a_addr,
    input  wire [15:0]   a_wdata,
    output logic [15:0]  a_rdata,
    input  wire          b_we,
    input  wire [1:0]    b_be,
    input  wire [AW-1:0] b_addr,
    input  wire [15:0]   b_wdata,
    output logic [15:0]  b_rdata
);
`ifdef ALTERA_RESERVED_QIS
    // Quartus does not infer a true dual-port RAM with this read-first behaviour from the behavioural description below ("unsupported
    // read-during-write behavior": the RAM became 100 K registers and the synthesis ran out of memory); the same RAM as an explicit megafunction.
    // Across the ports a read in the clock of a write to the same address returns the old word (as below); on the same port the data of a read
    // in a write clock is "don't care" (M10K true dual-port has no old-data mode there; nothing reads a port's own write clock).
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .width_a(16), .widthad_a(AW), .numwords_a(DEPTH),
        .width_b(16), .widthad_b(AW), .numwords_b(DEPTH),
        .width_byteena_a(2), .width_byteena_b(2), .byte_size(8),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"), .byteena_reg_b("CLOCK0"),
        .read_during_write_mode_port_a("DONT_CARE"), .read_during_write_mode_port_b("DONT_CARE"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .intended_device_family("Cyclone V"), .ram_block_type("M10K"), .power_up_uninitialized("FALSE"), .lpm_type("altsyncram")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .address_a(a_addr), .data_a(a_wdata), .wren_a(a_we), .byteena_a(a_be), .q_a(a_rdata),
        .address_b(b_addr), .data_b(b_wdata), .wren_b(b_we), .byteena_b(b_be), .q_b(b_rdata),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus());
`else
    logic [15:0] mem [0:DEPTH - 1];
    // one clocked block for both ports
    always_ff @(posedge clk) begin
        if (a_we) begin
            if (a_be[1]) mem[a_addr][15:8] <= a_wdata[15:8];
            if (a_be[0]) mem[a_addr][7:0]  <= a_wdata[7:0];
        end
        a_rdata <= mem[a_addr];
        if (b_we) begin
            if (b_be[1]) mem[b_addr][15:8] <= b_wdata[15:8];
            if (b_be[0]) mem[b_addr][7:0]  <= b_wdata[7:0];
        end
        b_rdata <= mem[b_addr];
    end
`endif
endmodule
`default_nettype wire
