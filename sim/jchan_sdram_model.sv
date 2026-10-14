// Behavioural SDRAM for Verilator: 32 M words x 16 bit = 64 MB (4 banks x 8192 rows x 1024 columns), the MiSTer 64 MB module.
// Derived from metro-mister's sim/sdram_model.sv (itself from Arcade-HyperDuel_MiSTer, GPL-3.0-or-later): CL2 read latency, BL1, per-bank open
// rows, auto precharge (A10), protocol errors flagged with $error, and the timing checks of the 96 MHz machine clock (tRCD 2, tRP 2, tRAS 5,
// tRC 6 / 7, tRRD 2, tWR 2, tRFC 7, average refresh interval).  Differences: 10 column bits, a 64 MB byte array, DQM is ignored (the MiSTer
// module leaves it low: the controller never relies on a byte mask).
//
// Word address = {BA[1:0], row[12:0], col[9:0]}; byte address = word << 1; even byte = DQ[15:8] (the project's lane convention).
//
// The testbench fills `mem_b` hierarchically (u_sdram.mem_b) or through $fread of the image.
//
// Timing alignment (matches jchan_sdram P_RET = 3): a READ is sampled at posedge E1 (command registered by the controller at E0), the data
// is fetched at E2 and driven during E2 -> E3: CAS latency 2.
module jchan_sdram_model (
    input  logic        clk,
    input  logic [12:0] A,
    input  logic [1:0]  BA,
    inout  wire  [15:0] DQ,
    input  logic        DQML,
    input  logic        DQMH,
    input  logic        nCS,
    input  logic        nRAS,
    input  logic        nCAS,
    input  logic        nWE,
    input  logic        CKE
);
  logic [7:0] mem_b [0:67108863];   // 64 MB

  wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;

  logic        row_open [4];
  logic [12:0] open_row [4];
  int          act_time [4];
  int          now = 0;

  int          chk_print = 0;
  initial void'($value$plusargs("SDRCHK=%d", chk_print));
  bit          act_valid [4];
  int          pre_ready [4];
  int          last_act_any = -1000;
  int          act_block_until = 0;
  int          last_ref = 0, max_ref_gap = 0, ref_cnt = 0;
  int          v_rc6 = 0, v_rc7 = 0, v_rrd = 0, v_rp = 0, v_rfc = 0, v_ras = 0, n_act = 0, n_rd = 0, n_wr = 0;
  int          v_bus = 0;
  function automatic int imax(input int a, input int b); return a > b ? a : b; endfunction
  final $display("SDRCHK summary: ACT %0d READ %0d WRITE %0d | violations: tRC6 %0d tRC7 %0d tRRD %0d tRP %0d tRFC %0d tRAS %0d bus %0d | refreshes %0d, longest gap between two %0d cycles",
                 n_act, n_rd, n_wr, v_rc6, v_rc7, v_rrd, v_rp, v_rfc, v_ras, v_bus, ref_cnt, max_ref_gap);

  int  init_refs = 0;
  bit  saw_pall = 0, mode_set = 0;

  logic        rd_pend = 1'b0;
  logic [24:0] rd_word;
  logic        drv_en = 1'b0;
  logic [15:0] drv_data;
  assign DQ = drv_en ? drv_data : 16'hzzzz;

  int trace = 0;
  initial void'($value$plusargs("SDRTRACE=%d", trace));
  always @(posedge clk)
    if (trace != 0 && CKE && cmd != CMD_NOP && cmd[3] == 1'b0)
      $display("SDR t=%0d cmd=%b A=%h BA=%b", now, cmd, A, BA);

  always_ff @(posedge clk) begin
    logic [24:0] w;
    now <= now + 1;

    drv_en <= rd_pend;
    if (rd_pend)
      drv_data <= {mem_b[{rd_word, 1'b0}], mem_b[{rd_word, 1'b1}]};
    rd_pend <= 1'b0;

    if (CKE) begin
      case (cmd)
        CMD_MODE: begin
          if (A[6:4] != 3'b010)
            $error("sdram_model: mode register CL=%0d, expected CL2", A[6:4]);
          if (A[2:0] != 3'b000)
            $error("sdram_model: mode register BL!=1 (A=%h)", A);
          mode_set <= 1'b1;
        end

        CMD_PALL: begin
          if (A[10]) begin
            for (int b = 0; b < 4; b++) begin
              if (row_open[b] && now - act_time[b] < 5) begin v_ras <= v_ras + 1; if (chk_print != 0) $display("SDRCHK t=%0d PALL violates tRAS on bank %0d", now, b); end
              pre_ready[b] <= imax(now, act_time[b] + 5) + 2;
              row_open[b] <= 1'b0;
            end
            saw_pall <= 1'b1;
          end
        end

        CMD_REF: begin
          for (int b = 0; b < 4; b++)
            if (row_open[b])
              $error("sdram_model: AUTO REFRESH with bank %0d row open", b);
          if (!saw_pall)
            $error("sdram_model: AUTO REFRESH before PRECHARGE ALL");
          init_refs <= init_refs + 1;
          for (int b = 0; b < 4; b++)
            if (now < pre_ready[b]) begin v_rp <= v_rp + 1; if (chk_print != 0) $display("SDRCHK t=%0d REF violates tRP on bank %0d", now, b); end
          if (ref_cnt != 0 && now - last_ref > max_ref_gap) max_ref_gap <= now - last_ref;
          ref_cnt <= ref_cnt + 1;
          last_ref <= now;
          act_block_until <= now + 7;
        end

        CMD_ACT: begin
          if (row_open[BA])
            $error("sdram_model: ACT on bank %0d with row already open", BA);
          if (init_refs < 2 || !mode_set)
            $error("sdram_model: ACT before init complete (refs=%0d mode=%0d)", init_refs, mode_set);
          n_act <= n_act + 1;
          if (act_valid[BA] && now - act_time[BA] < 6) begin v_rc6 <= v_rc6 + 1; if (chk_print != 0) $display("SDRCHK t=%0d ACT violates tRC(6) on bank %0d (%0d cycles)", now, BA, now - act_time[BA]); end
          if (act_valid[BA] && now - act_time[BA] < 7) v_rc7 <= v_rc7 + 1;
          if (now - last_act_any < 2) begin v_rrd <= v_rrd + 1; if (chk_print != 0) $display("SDRCHK t=%0d ACT violates tRRD (%0d cycles)", now, now - last_act_any); end
          if (now < pre_ready[BA]) begin v_rp <= v_rp + 1; if (chk_print != 0) $display("SDRCHK t=%0d ACT violates tRP on bank %0d (%0d cycles early)", now, BA, pre_ready[BA] - now); end
          if (now < act_block_until) begin v_rfc <= v_rfc + 1; if (chk_print != 0) $display("SDRCHK t=%0d ACT violates tRFC", now); end
          last_act_any <= now;
          act_valid[BA] <= 1'b1;
          row_open[BA] <= 1'b1;
          open_row[BA] <= A;
          act_time[BA] <= now;
        end

        CMD_READ: begin
          if (!row_open[BA])
            $error("sdram_model: READ on bank %0d with no open row", BA);
          if (now - act_time[BA] < 2)
            $error("sdram_model: READ violates tRCD on bank %0d", BA);
          rd_pend <= 1'b1;
          rd_word <= {BA, open_row[BA], A[9:0]};
          n_rd <= n_rd + 1;
          if (A[10]) begin
            row_open[BA] <= 1'b0;
            pre_ready[BA] <= imax(now + 1, act_time[BA] + 5) + 2;
          end
        end

        CMD_WRIT: begin
          if (!row_open[BA])
            $error("sdram_model: WRITE on bank %0d with no open row", BA);
          if (now - act_time[BA] < 2)
            $error("sdram_model: WRITE violates tRCD on bank %0d", BA);
          if (drv_en) begin v_bus <= v_bus + 1; if (chk_print != 0) $display("SDRCHK t=%0d WRITE while read data is on the bus", now); end
          w = {BA, open_row[BA], A[9:0]};
          mem_b[{w, 1'b0}] <= DQ[15:8];
          mem_b[{w, 1'b1}] <= DQ[7:0];
          n_wr <= n_wr + 1;
          if (A[10]) begin
            row_open[BA] <= 1'b0;
            pre_ready[BA] <= imax(now + 1 + 2, act_time[BA] + 5) + 2;
          end
        end

        default: ;
      endcase
    end
  end

endmodule
