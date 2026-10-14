// SDRAM controller of the jchan core: one 16-bit SDR SDRAM (the MiSTer 64 MB module: 4 banks x 8192 rows x 1024 columns, 32 M words), CL2, BL1,
// close page (every access is ACT, tRCD, READ / WRITE commands one per clock with auto precharge on the last, so all banks are precharged between
// grants and the refresh can slot in whenever the controller is idle).  The physical layer (command encoding, mode register, init sequence,
// tRC >= 7 / tRP / tRFC guards, read capture P_RET) is the one of metro-mister's `metro_sdram.sv`, which runs on hardware at 96 MHz; the client side
// is new: NP generic burst ports in a fixed priority order (port 0 first).  Timing at 96 MHz (first whole-project fit: the arbitration, the
// address mux and the pin registers in one clock were -9 ns): the winner is chosen one clock ahead and registered (a request that arrives at an
// idle controller waits one clock more), and the pins' registers are a stage behind the FSM (read data comes back P_RET = 4 clocks after the
// FSM's READ, one more than metro-mister's controller: the chip sees the same command sequence, one clock later).
//
//   read port p   req[p] (held until ack[p]), addr[p] = word address (25 bit), len[p] = 1 .. 64 words
//                 -> ack[p] pulse when the request is taken, then len[p] words come back in order on rdata with rvalid[p] pulses
//                 (rlast[p] with the last one), 4 .. 6 clocks per word of ACT / data latency after the grant
//   write port p  same request; the controller pulls the words: wpop[p] (combinational, one per consumed word) with wdata[p] presented while
//                 wavail[p] is high.  A WRITE is only issued when wavail is high (the row stays open meanwhile).  All writes are full words:
//                 the MiSTer module's DQM pins can not be relied on.
//
// A burst that reaches the end of a row (column 1023) is continued in the next row (re-ACT); a grant is never interrupted otherwise.  Keep
// bursts short for clients that must not wait (the CPUs' line fills are 8 words, the bulk streams 16 - 32).
//
// Address bits of the word address: {BA[1:0], row[12:0], col[9:0]}.  Banks are 16 MB of byte address each (see docs/memory.md for the map).
`default_nettype none
module jchan_sdram #(
    parameter NP = 8,
    parameter [NP-1:0] IS_WR = '0,
    parameter SHORT_INIT = 0,          // simulation: skip most of the 100 us power-up wait
    parameter P_RET = 4,                 // clocks from the READ's FSM edge to the clock that registers its data (3 + the output stage)
    parameter REFRESH_PERIOD = 750     // 7.8125 us at 96 MHz
) (
    input  wire              clk,
    input  wire              rst,
    output logic             ready,
    input  wire              i_rd_late,        // 1: capture read data one clock later (a board's pin timing)

    input  wire  [NP-1:0]    req,
    input  wire  [NP*25-1:0] addr,
    input  wire  [NP*7-1:0]  len,
    output logic [NP-1:0]    ack,
    output logic [NP-1:0]    rvalid,
    output logic [NP-1:0]    rlast,
    output logic [15:0]      rdata,
    input  wire  [NP-1:0]    wavail,
    input  wire  [NP*16-1:0] wdata,
    output logic [NP-1:0]    wpop,

    output logic [12:0]      SDRAM_A,
    output logic [1:0]       SDRAM_BA,
    inout  wire  [15:0]      SDRAM_DQ,
    output logic             SDRAM_DQML,
    output logic             SDRAM_DQMH,
    output logic             SDRAM_nCS,
    output logic             SDRAM_nRAS,
    output logic             SDRAM_nCAS,
    output logic             SDRAM_nWE,
    output logic             SDRAM_CKE,

    // statistics (free-running 32-bit counters)
    output logic [31:0]      stat_busy,        // clocks with a grant in progress
    output logic [31:0]      stat_words        // words transferred
);
    localparam [3:0] CMD_NOP  = 4'b0111;
    localparam [3:0] CMD_ACT  = 4'b0011;
    localparam [3:0] CMD_READ = 4'b0101;
    localparam [3:0] CMD_WRIT = 4'b0100;
    localparam [3:0] CMD_PALL = 4'b0010;
    localparam [3:0] CMD_REF  = 4'b0001;
    localparam [3:0] CMD_MODE = 4'b0000;
    localparam [12:0] MODE_REG = 13'h020;                   // BL1, sequential, CL2
    localparam INIT_WAIT = SHORT_INIT ? 32 : 9600;          // 100 us at 96 MHz

    // The FSM below drives the *_f signals; the pins' registers (the command, address, bank, data and output-enable registers, packed into the
    // IO cells) are one more stage behind them, so that the logic in front of the pins ends at a register next to it and the long route to the
    // IO cell has a whole clock to itself.  Every output is delayed alike, so the chip sees the same sequence one clock later and the read
    // data comes back one clock later (P_RET = 4).
    /* verilator lint_off PROCASSINIT */
    logic [3:0] cmd = CMD_NOP;
    /* verilator lint_on PROCASSINIT */
    assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
    assign SDRAM_CKE = 1'b1;
    assign SDRAM_DQML = 1'b0;
    assign SDRAM_DQMH = 1'b0;

    logic [3:0]  cmd_f = CMD_NOP;
    logic [12:0] a_f;
    logic [1:0]  ba_f;
    logic [15:0] dq_f;
    logic        oe_f;
    logic [15:0] dq_out;
    logic        dq_oe;
    always_ff @(posedge clk) begin
        cmd <= cmd_f; SDRAM_A <= a_f; SDRAM_BA <= ba_f; dq_out <= dq_f; dq_oe <= oe_f;
    end
    assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

    logic [15:0] dq_in0, dq_in1;
    always_ff @(posedge clk) begin dq_in0 <= SDRAM_DQ; dq_in1 <= dq_in0; end
    wire  [15:0] dq_in = i_rd_late ? dq_in1 : dq_in0;

    // read-return tag pipeline: {valid, port, last}, written at the READ command's edge, lands with dq_in P_RET clocks later
    localparam PW = $clog2(NP);
    logic [PW+1:0] rtag [0:P_RET+1];
    always_ff @(posedge clk) for (int i = P_RET + 1; i > 0; i--) rtag[i] <= rtag[i-1];
    wire  [PW+1:0] land = i_rd_late ? rtag[P_RET+1] : rtag[P_RET];
    wire           land_v    = land[PW+1];
    wire  [PW-1:0] land_port = land[PW:1];
    wire           land_last = land[0];
    always_comb begin
        rvalid = '0; rlast = '0;
        for (int p = 0; p < NP; p++)
            if (land_v && land_port == PW'(p)) begin rvalid[p] = 1'b1; rlast[p] = land_last; end
    end
    assign rdata = dq_in;

    typedef enum logic [3:0] { S_INIT_WAIT, S_PALL, S_REF1, S_REF2, S_MODE, S_IDLE, S_RCD, S_XFER, S_WAITB } st_e;
    st_e st;
    logic [13:0] init_cnt;
    logic [3:0]  bank_t [0:3];          // clocks until an ACT to the bank is legal (tRC / tRP / tWR)
    logic [3:0]  gap_t;                 // clocks until any ACT is legal (tRFC, tMRD)
    logic [PW-1:0] owner;
    logic [24:0] cur_word;
    logic [6:0]  left;
    logic [9:0]  ref_cnt;
    logic        ref_due;
    logic        owner_wr;
    logic [3:0]  init_wait;

    wire all_ok = (bank_t[0] == 4'd0) && (bank_t[1] == 4'd0) && (bank_t[2] == 4'd0) && (bank_t[3] == 4'd0);

    wire        cur_last_in_row = (cur_word[9:0] == 10'h3ff);
    wire        cur_last        = (left == 7'd1);
    wire [1:0]  cur_bank        = cur_word[24:23];

    // the winner of the arbitration: the lowest port with a request whose bank is ready.  Chosen one clock ahead and registered (the 11-port
    // priority, the address / length selection and the SDRAM command are too long for one 96 MHz clock): the choice for the clock after this edge
    // is made from the requests and from the bank timers as they will be after this edge (bank_n: the countdown and every event of this
    // edge), so it is exact when the controller comes back to S_IDLE; a request that arrives at an idle controller waits one clock more.
    logic [3:0] bank_n [0:3];
    always_comb begin
        for (int b = 0; b < 4; b++) bank_n[b] = (bank_t[b] != 4'd0) ? bank_t[b] - 4'd1 : 4'd0;
        case (st)
            S_IDLE:  if (gap_t == 4'd0 && !ref_due && sel_v_q) bank_n[sel_addr[24:23]] = 4'd6;
            S_XFER:  if ((cur_last || cur_last_in_row) && (!owner_wr || wavail[owner])) begin
                         if (!owner_wr) begin if (bank_t[cur_bank] < 4'd3) bank_n[cur_bank] = 4'd2; end
                         else           begin if (bank_t[cur_bank] < 4'd5) bank_n[cur_bank] = 4'd4; end
                     end
            S_WAITB: if (bank_t[cur_bank] == 4'd0 && gap_t == 4'd0) bank_n[cur_bank] = 4'd6;
            default: ;
        endcase
    end
    logic          selc_v;
    logic [PW-1:0] selc;
    always_comb begin
        selc_v = 1'b0; selc = '0;
        for (int p = NP - 1; p >= 0; p--)
            if (req[p] && bank_n[addr[25*p + 23 +: 2]] == 4'd0) begin selc_v = 1'b1; selc = PW'(p); end
    end
    logic          sel_v_q;
    logic [PW-1:0] sel_q;
    always_ff @(posedge clk) begin
        sel_v_q <= selc_v && !rst;
        sel_q   <= selc;
    end
    logic [24:0] sel_addr;
    logic [6:0]  sel_len;
    always_comb begin
        sel_addr = '0; sel_len = '0;
        for (int p = 0; p < NP; p++)
            if (sel_q == PW'(p)) begin sel_addr = addr[25*p +: 25]; sel_len = len[7*p +: 7]; end
    end

    always_comb begin
        wpop = '0;
        if (st == S_XFER && owner_wr && wavail[owner]) wpop[owner] = 1'b1;
    end

    always_ff @(posedge clk) begin
        cmd_f    <= CMD_NOP;
        a_f      <= 13'd0;
        ba_f     <= cur_word[24:23];
        oe_f     <= 1'b0;
        ack      <= '0;
        rtag[0]  <= '0;
        for (int b = 0; b < 4; b++) if (bank_t[b] != 4'd0) bank_t[b] <= bank_t[b] - 4'd1;
        if (gap_t != 4'd0) gap_t <= gap_t - 4'd1;

        if (rst) begin
            st <= S_INIT_WAIT;
            ready <= 1'b0;
            init_cnt <= '0;
            ref_cnt <= '0; ref_due <= 1'b0;
            gap_t <= 4'd0;
            for (int b = 0; b < 4; b++) bank_t[b] <= 4'd0;
            cur_word <= '0; left <= '0; owner <= '0; owner_wr <= 1'b0;
            stat_busy <= '0; stat_words <= '0;
            init_wait <= '0;
        end else begin
            // refresh bookkeeping
            if (32'(ref_cnt) == REFRESH_PERIOD - 1) begin ref_cnt <= '0; ref_due <= 1'b1; end
            else ref_cnt <= ref_cnt + 10'd1;
            if (st != S_IDLE && st != S_INIT_WAIT) stat_busy <= stat_busy + 32'd1;

            case (st)
                S_INIT_WAIT: begin
                    init_cnt <= init_cnt + 14'd1;
                    if (32'(init_cnt) == INIT_WAIT) st <= S_PALL;
                end
                S_PALL: begin
                    cmd_f <= CMD_PALL; a_f <= 13'h400;
                    init_wait <= 4'd2; st <= S_REF1;
                end
                S_REF1: begin
                    if (init_wait != 4'd0) init_wait <= init_wait - 4'd1;
                    else begin cmd_f <= CMD_REF; init_wait <= 4'd8; st <= S_REF2; end
                end
                S_REF2: begin
                    if (init_wait != 4'd0) init_wait <= init_wait - 4'd1;
                    else begin cmd_f <= CMD_REF; init_wait <= 4'd8; st <= S_MODE; end
                end
                S_MODE: begin
                    if (init_wait != 4'd0) init_wait <= init_wait - 4'd1;
                    else begin
                        cmd_f <= CMD_MODE; a_f <= MODE_REG; ba_f <= 2'b00;
                        gap_t <= 4'd3;
                        ready <= 1'b1; st <= S_IDLE;
                        ref_due <= 1'b0; ref_cnt <= '0;
                    end
                end

                S_IDLE: begin
                    if (gap_t == 4'd0) begin
                        if (ref_due && all_ok) begin
                            cmd_f <= CMD_REF;
                            ref_due <= 1'b0;
                            gap_t <= 4'd7;                          // the next ACT 8 clocks after the REF (tRFC)
                        end else if (sel_v_q && !ref_due) begin
                            owner    <= sel_q;
                            owner_wr <= IS_WR[sel_q];
                            cur_word <= sel_addr;
                            left     <= sel_len;
                            ack[sel_q] <= 1'b1;
                            cmd_f <= CMD_ACT;
                            a_f <= sel_addr[22:10];
                            ba_f <= sel_addr[24:23];
                            bank_t[sel_addr[24:23]] <= 4'd6;        // ACT to ACT of one bank: 7 clocks
                            st       <= S_RCD;
                        end
                    end
                end

                S_RCD: st <= S_XFER;

                S_XFER: begin
                    if (!owner_wr) begin
                        cmd_f <= CMD_READ;
                        a_f <= {2'b00, (cur_last || cur_last_in_row), cur_word[9:0]};
                        rtag[0]  <= {1'b1, owner, cur_last};
                        cur_word <= cur_word + 25'd1;
                        left     <= left - 7'd1;
                        stat_words <= stat_words + 32'd1;
                        if (cur_last || cur_last_in_row) begin
                            if (bank_t[cur_bank] < 4'd3) bank_t[cur_bank] <= 4'd2;   // READ + auto precharge: ACT 3 clocks after the READ (the count decrements at this edge too)
                            st <= cur_last ? S_IDLE : S_WAITB;
                        end
                    end else if (wavail[owner]) begin
                        cmd_f <= CMD_WRIT;
                        a_f <= {2'b00, (cur_last || cur_last_in_row), cur_word[9:0]};
                        oe_f <= 1'b1;
                        dq_f <= wdata[16*owner +: 16];
                        cur_word <= cur_word + 25'd1;
                        left     <= left - 7'd1;
                        stat_words <= stat_words + 32'd1;
                        if (cur_last || cur_last_in_row) begin
                            if (bank_t[cur_bank] < 4'd5) bank_t[cur_bank] <= 4'd4;   // WRITE + auto precharge: tWR + tRP, ACT 5 clocks after
                            st <= cur_last ? S_IDLE : S_WAITB;
                        end
                    end
                end

                S_WAITB: begin
                    // the burst continues in the next row: re-activate when the bank has precharged
                    if (bank_t[cur_bank] == 4'd0 && gap_t == 4'd0) begin
                        cmd_f <= CMD_ACT;
                        a_f <= cur_word[22:10];
                        ba_f <= cur_bank;
                        bank_t[cur_bank] <= 4'd6;
                        st       <= S_RCD;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
