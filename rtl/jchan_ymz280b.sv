// Yamaha YMZ280B (8-voice ADPCM / PCM8 / PCM16 player), written from MAME 0.289 devices/sound/ymz280b.cpp, which is its reference: every
// register, the three decoders, the per-voice linear interpolation and the level / pan maths follow that file.  Output: one stereo sample every
// TICK_CLKS clocks (MAME's stream rate, 16 MHz / 384 * 2 = 83.33 kHz; 96 MHz / 1152), as the 27-bit sum of the voices' `interp * level / 2`
// terms (`dbg_l` / `dbg_r`, exactly what MAME's `add_int(..., 32768 * 256)` accumulates) and as saturated 16-bit samples.
//
// What is and is not modelled (jchan's board reaches only the write side of the chip: sub 68000 800001 = register select, 800003 = data):
//   modelled   voice registers 00-7f, global register ff (key-on enable, the "stop everything" side effect), key-on / key-off, looping, pitch,
//              level, pan, the ROM byte stream
//   ignored    DSP registers 80-82, the external memory / RAM write registers 84-87 and the read-back, the IRQ mask / status (no IRQ line or
//              read access exists on this board; MAME's driver leaves the IRQ handler unset and the sub map is write-only)
//
// How MAME's chunked stream is mapped onto a sample-by-sample machine (the argument is in docs/sound.md):
//   * MAME generates samples in chunks that end at every data-port write and every 1/50 s (sound manager update); a write at stream index N
//     takes effect from sample N + 1.  Here a write is queued and applied between two ticks, and every data write / 1/50 s event flags the next
//     sample as the start of a new chunk.
//   * at a chunk start MAME parks idle voices (not playing, last two samples zero) at output_pos = 1.0 and skips them; the "ramp to zero" that
//     fills the rest of a chunk after the end of a sample (t = t * 15 / 16 per decoded sample) ends at the chunk boundary, after which a stopped
//     voice decodes zeros.
//   * the interpolation position is advanced eagerly (right after an output that wrapped it) as MAME does, so a chunk always ends with
//     output_pos < 1.0.
//
// ROM: one byte read at a time (`rom_req` held until the one-clock `rom_ack` with `rom_data`), 24-bit byte address.  Each voice needs at most
// four reads per output sample.  The 8 voices are processed one after the other in the ~1100 clocks of a tick.
`default_nettype none
module jchan_ymz280b #(
    parameter TICK_CLKS  = 1152,                 // clocks per output sample (96 MHz / 83.333 kHz)
    parameter TIMER_RATE = 83333                 // the stream rate MAME uses (integer part of 16 MHz / 192); 50 Hz timer events derive from it
) (
    input  wire         clk,
    input  wire         rst,

    // CPU side: one strobe per bus write (a0 = 0: register select, 1: data)
    input  wire         wr,
    input  wire         a0,
    input  wire [7:0]   din,

    // sample ROM
    output logic        rom_req,
    output logic [23:0] rom_addr,
    input  wire         rom_ack,
    input  wire [7:0]   rom_data,

    // audio
    output logic        out_valid,               // one clock per sample
    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r,
    output logic signed [27:0] dbg_l,
    output logic signed [27:0] dbg_r,
    output logic        overrun,                 // sticky: a tick arrived while the previous sample was still being computed
    output wire         dbg_tick                 // one clock at the start of each sample period (testbench: schedules writes by period)
);
    localparam [10:0] ONE = 11'd512;

    // ---------------------------------------------------------------- CPU write queue
    logic [7:0]  cur_reg;
    logic [15:0] fifo [0:63];
    logic [6:0]  fw, fr;                         // write / read pointers (7 bits: 64 entries + wrap bit)
    logic        evt_pend;                       // a data write or the 1/50 s timer fired in the period that just ended
    logic        evt_timer;                      // one clock, at the tick that starts the period the timer event belongs to
    logic        timer_ev;                       // ... held until that tick has been taken up, then it counts for the next one
    wire         fifo_full = (fw - fr) == 7'd64;
    always_ff @(posedge clk) begin
        if (rst) begin
            cur_reg <= 8'd0;
            fw <= 7'd0;
        end else if (wr) begin
            if (!a0) cur_reg <= din;
            else if (!fifo_full) begin
                fifo[fw[5:0]] <= {cur_reg, din};
                fw <= fw + 7'd1;
            end
        end
    end

    // ---------------------------------------------------------------- tick and the 1/50 s timer
    logic [11:0] tc;
    logic        tick;
    assign dbg_tick = tick;
    logic [16:0] tacc;                           // 50 * ticks mod TIMER_RATE
    logic        first_tick;
    // MAME's sound manager updates every stream at k / 50 s (k >= 1); a stream index N = floor(k * TIMER_RATE / 50).  The event of index N
    // is flagged in the period that starts at tick N: there is a multiple of TIMER_RATE in [50 N, 50 N + 50).
    always_ff @(posedge clk) begin
        tick <= 1'b0;
        evt_timer <= 1'b0;
        if (rst) begin
            tc <= 12'd0;
            tacc <= 17'd0;
            first_tick <= 1'b1;
        end else begin
            if (tc == TICK_CLKS - 1) begin
                tc <= 12'd0;
                tick <= 1'b1;
                first_tick <= 1'b0;
                if ((tacc == 17'd0 && !first_tick) || (tacc + 17'd50 > TIMER_RATE)) evt_timer <= 1'b1;
                if (tacc + 17'd50 >= TIMER_RATE) tacc <= tacc + 17'd50 - TIMER_RATE;
                else tacc <= tacc + 17'd50;
            end else tc <= tc + 12'd1;
        end
    end

    // ---------------------------------------------------------------- voice state
    // configuration (written by the CPU through the queue)
    logic [8:0]  fnum    [0:7];
    logic        keyon   [0:7];
    logic        looping [0:7];
    logic [1:0]  mode    [0:7];
    logic [7:0]  level   [0:7];
    logic [3:0]  pan     [0:7];
    logic [24:1] a_start [0:7];
    logic [24:1] a_stop  [0:7];
    logic [24:1] a_lstart[0:7];
    logic [24:1] a_lend  [0:7];
    logic        keyon_en;
    // decoder / output state
    logic        playing [0:7];
    logic        tail_on [0:7];
    logic [24:0] position[0:7];
    logic signed [15:0] signal [0:7];
    logic [14:0] step    [0:7];
    logic signed [15:0] loop_signal [0:7];
    logic [14:0] loop_step [0:7];
    logic        loop_seen [0:7];
    logic [10:0] opos    [0:7];
    logic signed [15:0] prev [0:7];
    logic signed [15:0] curr [0:7];
    logic signed [15:0] tailv [0:7];
    logic        qo      [0:7];

    // ---------------------------------------------------------------- engine
    typedef enum logic [4:0] {
        E_IDLE, E_DRAIN, E_CHUNK, E_VLOAD, E_VBEGIN, E_EMIT0, E_EMIT1, E_EMIT2, E_EMIT3, E_VNEXT, E_OUT, E_OUT2,
        D_START, D_W0, D_RD1, D_W1, D_CALC, D_CALC2, D_CALC3, D_CALC4
    } est_t;
    est_t        st, dec_ret;
    logic [2:0]  v;
    logic [6:0]  drain_n;
    logic        chunk_now;
    logic        tick_q;                         // a tick is waiting to be processed
    logic        captured;                       // the period boundary was taken at the tick clock itself
    logic signed [27:0] acc_l, acc_r;

    // per-voice working values for the emit / decode steps
    logic signed [25:0] m1, m2;
    logic signed [16:0] interp;
    logic signed [25:0] p_l, p_r;
    logic signed [25:0] pt_l, pt_r;              // p / 2 toward zero, added to the accumulators one clock later
    logic        acc_pend;
    logic [10:0] vp;                             // level * k of the volume scaling (p <= 1785)
    logic [7:0]  vs;                             // floor(p / 7) = (p * 9363) >> 16
    logic [10:0] opos_n;
    logic [7:0]  b0, b1;                         // ROM bytes fetched by the decoder
    // decoder pipeline (D_CALC .. D_CALC4)
    logic [18:0] mag_r;
    logic [24:0] sprod_r;
    logic        nib3_r;
    logic signed [15:0] sg2, xo2, s3_sg, s3_lsg;
    logic [14:0] sp2, s3_sp, s3_lsp;
    logic [24:0] ps2, s3_ps;
    logic        s3_lseen;
    logic signed [27:0] sl_r, sr_r;

    // the voice being processed: loaded in E_VLOAD, stored back in E_VNEXT (so the long paths start at registers, not at the voice index)
    logic        w_playing, w_tail_on, w_qo, w_looping, w_keyon, w_lseen;
    logic [1:0]  w_mode;
    logic [8:0]  w_fnum;
    logic [7:0]  w_level;
    logic [3:0]  w_pan;
    logic [10:0] w_opos;
    logic signed [15:0] w_prev, w_curr, w_tailv, w_sig, w_lsig;
    logic [14:0] w_step, w_lstep;
    logic [24:0] w_pos, w_stop, w_lend, w_lst;

    // level / pan -> left and right volume (update_volumes): level * k / 7 with k in 0..7, floor.  k = pan - 1 (pan 1..7) or 15 - pan (pan 9..15).
    wire [2:0] vk = (w_pan < 4'd8) ? (w_pan[2:0] - 3'd1) : ~w_pan[2:0];
    logic [7:0]  lvol, rvol;
    always_comb begin
        if (w_pan == 4'd8)      begin lvol = w_level; rvol = w_level; end
        else if (w_pan < 4'd8)  begin lvol = w_level; rvol = (w_pan == 4'd0) ? 8'd0 : vs; end
        else                    begin lvol = vs; rvol = w_level; end
    end

    wire [14:0] ostep = {5'd0, (w_mode == 2'd1) ? {2'b00, w_fnum[7:0]} : w_fnum} + 15'd1;

    // ADPCM tables
    function automatic [9:0] idx_scale(input [2:0] n);
        case (n)
            3'd0, 3'd1, 3'd2, 3'd3: idx_scale = 10'h0e6;
            3'd4: idx_scale = 10'h133;
            3'd5: idx_scale = 10'h199;
            3'd6: idx_scale = 10'h200;
            default: idx_scale = 10'h266;
        endcase
    endfunction
    function automatic signed [15:0] decay(input signed [15:0] t);
        logic [30:0] m;
        begin
            if (t < 0) begin m = {15'd0, -t} * 31'd15; decay = -$signed({1'b0, m[19:4]}); end
            else       begin m = {15'd0,  t} * 31'd15; decay =  $signed({1'b0, m[19:4]}); end
        end
    endfunction

    // queue entry being applied
    logic [15:0] ent;
    logic [7:0]  e_reg, e_dat;
    logic [2:0]  ev;
    logic [7:0]  e_dat_eff;

    integer i;
    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        if (acc_pend) begin                      // the half-product of the last emit, one clock after it was made
            acc_l <= acc_l + pt_l;
            acc_r <= acc_r + pt_r;
            acc_pend <= 1'b0;
        end
        if (rst) begin
            acc_pend <= 1'b0;
            st <= E_IDLE;
            fr <= 7'd0;
            keyon_en <= 1'b0;
            evt_pend <= 1'b1;                    // the first sample starts a chunk (MAME's first stream update parks the idle voices)
            timer_ev <= 1'b0;
            tick_q <= 1'b0;
            captured <= 1'b0;
            overrun <= 1'b0;
            rom_req <= 1'b0;
            v <= 3'd0;
            for (i = 0; i < 8; i++) begin
                fnum[i] <= 9'd0; keyon[i] <= 1'b0; looping[i] <= 1'b0; mode[i] <= 2'd0; level[i] <= 8'd0; pan[i] <= 4'd0;
                a_start[i] <= 24'd0; a_stop[i] <= 24'd0; a_lstart[i] <= 24'd0; a_lend[i] <= 24'd0;
                playing[i] <= 1'b0; tail_on[i] <= 1'b0; position[i] <= 25'd0; signal[i] <= 16'sd0; step[i] <= 15'd0;
                loop_signal[i] <= 16'sd0; loop_step[i] <= 15'd0; loop_seen[i] <= 1'b0;
                opos[i] <= ONE; prev[i] <= 16'sd0; curr[i] <= 16'sd0; tailv[i] <= 16'sd0; qo[i] <= 1'b0;
            end
        end else begin
            if (wr && a0 && !fifo_full) evt_pend <= 1'b1;
            if (evt_timer) timer_ev <= 1'b1;
            if (tick) begin
                if (tick_q || st != E_IDLE) overrun <= 1'b1;
                tick_q <= 1'b1;
                // the period boundary is exactly this clock: what the CPU wrote before it belongs to the sample about to be made, what comes
                // after it (also in the next clocks, while the engine starts) to the next one
                if (st == E_IDLE && !tick_q) begin
                    captured <= 1'b1;
                    chunk_now <= evt_pend;
                    evt_pend <= (wr && a0 && !fifo_full) || evt_timer || timer_ev;   // evt_timer: the event of the period that starts now
                    timer_ev <= 1'b0;
                    drain_n <= fw - fr;
                end
            end

            case (st)
            // ------------------------------------------------------------ start of a sample: queue, chunk start
            E_IDLE: if (tick_q) begin
                tick_q <= 1'b0;
                if (!captured) begin                     // (the previous sample was still being made when the tick came: late)
                    chunk_now <= evt_pend;
                    evt_pend <= (wr && a0 && !fifo_full) || timer_ev;
                    timer_ev <= 1'b0;
                    drain_n <= fw - fr;
                end
                captured <= 1'b0;
                acc_l <= 28'sd0;
                acc_r <= 28'sd0;
                v <= 3'd0;
                st <= E_DRAIN;
            end

            E_DRAIN: begin
                if (drain_n != 7'd0) begin
                    // apply one queued register write (write_to_register)
                    ent = fifo[fr[5:0]];
                    e_reg = ent[15:8];
                    e_dat = ent[7:0];
                    ev = e_reg[4:2];
                    fr <= fr + 7'd1;
                    drain_n <= drain_n - 7'd1;
                    if (!e_reg[7]) begin
                        case ({e_reg[6:5], e_reg[1:0]})
                        4'b0000: fnum[ev][7:0] <= e_dat;
                        4'b0001: begin
                            fnum[ev][8] <= e_dat[0];
                            looping[ev] <= e_dat[4];
                            e_dat_eff = e_dat;
                            if (e_dat[6:5] == 2'd0) e_dat_eff[7] = 1'b0;
                            else mode[ev] <= e_dat[6:5];
                            if (!keyon[ev] && e_dat_eff[7] && keyon_en) begin
                                playing[ev] <= 1'b1;
                                position[ev] <= {a_start[ev], 1'b0};
                                signal[ev] <= 16'sd0; loop_signal[ev] <= 16'sd0;
                                step[ev] <= 15'h7f; loop_step[ev] <= 15'h7f;
                                loop_seen[ev] <= 1'b0;
                            end else if (keyon[ev] && !e_dat_eff[7]) begin
                                playing[ev] <= 1'b0;
                            end
                            keyon[ev] <= e_dat_eff[7];
                        end
                        4'b0010: level[ev] <= e_dat;
                        4'b0011: pan[ev] <= e_dat[3:0];
                        4'b0100: a_start[ev][24:17]  <= e_dat;       // 0x20: start high
                        4'b0101: a_lstart[ev][24:17] <= e_dat;       // 0x21
                        4'b0110: a_lend[ev][24:17]   <= e_dat;       // 0x22
                        4'b0111: a_stop[ev][24:17]   <= e_dat;       // 0x23
                        4'b1000: a_start[ev][16:9]   <= e_dat;       // 0x40: middle
                        4'b1001: a_lstart[ev][16:9]  <= e_dat;
                        4'b1010: a_lend[ev][16:9]    <= e_dat;
                        4'b1011: a_stop[ev][16:9]    <= e_dat;
                        4'b1100: a_start[ev][8:1]    <= e_dat;       // 0x60: low
                        4'b1101: a_lstart[ev][8:1]   <= e_dat;
                        4'b1110: a_lend[ev][8:1]     <= e_dat;
                        4'b1111: a_stop[ev][8:1]     <= e_dat;
                        default: ;
                        endcase
                    end else if (e_reg == 8'hff) begin
                        if (keyon_en && !e_dat[7]) begin
                            for (i = 0; i < 8; i++) playing[i] <= 1'b0;
                        end else if (!keyon_en && e_dat[7]) begin
                            for (i = 0; i < 8; i++) if (keyon[i] && looping[i]) playing[i] <= 1'b1;
                        end
                        keyon_en <= e_dat[7];
                    end
                end else begin
                    st <= chunk_now ? E_CHUNK : E_VLOAD;
                    v <= 3'd0;
                end
            end

            // chunk start: park idle voices, cut the ramps
            E_CHUNK: begin
                tail_on[v] <= 1'b0;
                qo[v] <= !playing[v] && curr[v] == 16'sd0 && prev[v] == 16'sd0;
                if (!playing[v] && curr[v] == 16'sd0 && prev[v] == 16'sd0) opos[v] <= ONE;
                if (v == 3'd7) begin st <= E_VLOAD; v <= 3'd0; end
                else v <= v + 3'd1;
            end

            // ------------------------------------------------------------ one voice
            E_VLOAD: begin
                w_playing <= playing[v]; w_tail_on <= tail_on[v]; w_qo <= qo[v]; w_looping <= looping[v]; w_keyon <= keyon[v];
                w_lseen <= loop_seen[v];
                w_mode <= mode[v]; w_fnum <= fnum[v]; w_level <= level[v]; w_pan <= pan[v];
                w_opos <= opos[v]; w_prev <= prev[v]; w_curr <= curr[v]; w_tailv <= tailv[v];
                w_sig <= signal[v]; w_lsig <= loop_signal[v]; w_step <= step[v]; w_lstep <= loop_step[v]; w_pos <= position[v];
                w_stop <= {a_stop[v], 1'b0}; w_lend <= {a_lend[v], 1'b0}; w_lst <= {a_lstart[v], 1'b0};
                st <= E_VBEGIN;
            end
            E_VBEGIN: begin
                if (w_qo) st <= E_VNEXT;
                else if (w_opos >= ONE) begin
                    w_opos <= w_opos - ONE;
                    w_prev <= w_curr;
                    dec_ret <= E_EMIT0;
                    st <= D_START;
                end else st <= E_EMIT0;
            end
            E_EMIT0: begin
                m1 <= w_prev * $signed({1'b0, ONE - w_opos});
                m2 <= w_curr * $signed({1'b0, w_opos});
                vp <= w_level * vk;
                st <= E_EMIT1;
            end
            E_EMIT1: begin
                interp <= (m1 + m2) >>> 9;
                begin : sc
                    logic [23:0] q;
                    q = vp * 24'd9363;           // floor(p / 7) == (p * 9363) >> 16 for p <= 1785 (checked exhaustively)
                    vs <= q[23:16];
                end
                st <= E_EMIT2;
            end
            E_EMIT2: begin
                p_l <= interp * $signed({1'b0, lvol});
                p_r <= interp * $signed({1'b0, rvol});
                opos_n <= w_opos + ostep[10:0];
                st <= E_EMIT3;
            end
            E_EMIT3: begin
                // C++ "/ 2": truncation toward zero
                pt_l <= (p_l >= 0) ? (p_l >>> 1) : -((-p_l) >>> 1);
                pt_r <= (p_r >= 0) ? (p_r >>> 1) : -((-p_r) >>> 1);
                acc_pend <= 1'b1;
                if (opos_n >= ONE) begin
                    w_opos <= opos_n - ONE;
                    w_prev <= w_curr;
                    dec_ret <= E_VNEXT;
                    st <= D_START;
                end else begin
                    w_opos <= opos_n;
                    st <= E_VNEXT;
                end
            end
            E_VNEXT: begin
                opos[v] <= w_opos; prev[v] <= w_prev; curr[v] <= w_curr; playing[v] <= w_playing; tail_on[v] <= w_tail_on; tailv[v] <= w_tailv;
                position[v] <= w_pos; signal[v] <= w_sig; step[v] <= w_step; loop_signal[v] <= w_lsig; loop_step[v] <= w_lstep;
                loop_seen[v] <= w_lseen;
                if (v == 3'd7) st <= E_OUT;
                else begin v <= v + 3'd1; st <= E_VLOAD; end
            end
            E_OUT: begin
                dbg_l <= acc_l;
                dbg_r <= acc_r;
                sl_r <= (acc_l + 28'sd128) >>> 8;
                sr_r <= (acc_r + 28'sd128) >>> 8;
                st <= E_OUT2;
            end
            E_OUT2: begin
                // (sum + 128) >> 8, saturated to 16 bits
                out_l <= (sl_r > 28'sd32767) ? 16'sh7fff : (sl_r < -28'sd32768) ? 16'sh8000 : sl_r[15:0];
                out_r <= (sr_r > 28'sd32767) ? 16'sh7fff : (sr_r < -28'sd32768) ? 16'sh8000 : sr_r[15:0];
                out_valid <= 1'b1;
                st <= E_IDLE;
            end

            // ------------------------------------------------------------ decode one input sample into w_curr
            D_START: begin
                if (w_tail_on) begin
                    w_tailv <= decay(w_tailv);
                    w_curr <= decay(w_tailv);
                    st <= dec_ret;
                end else if (w_playing && w_mode != 2'd0) begin
                    rom_addr <= w_pos[24:1];
                    rom_req <= 1'b1;
                    st <= D_W0;
                end else begin
                    w_curr <= 16'sd0;
                    st <= dec_ret;
                end
            end
            D_W0: if (rom_ack) begin
                rom_req <= 1'b0;
                b0 <= rom_data;
                if (w_mode == 2'd3) st <= D_RD1;         // PCM16: the high byte is at the next address
                else st <= D_CALC;
            end
            D_RD1: begin
                rom_addr <= w_pos[24:1] + 24'd1;
                rom_req <= 1'b1;
                st <= D_W1;
            end
            D_W1: if (rom_ack) begin
                rom_req <= 1'b0;
                b1 <= rom_data;
                st <= D_CALC;
            end
            // stage 1: the two products of the ADPCM step (the old values of the step)
            D_CALC: begin : calc1
                logic [3:0] nib;
                nib = w_pos[0] ? b0[3:0] : b0[7:4];
                mag_r   <= w_step * {nib[2:0], 1'b1};                  // step * (2 * (nib & 7) + 1)
                sprod_r <= w_step * idx_scale(nib[2:0]);               // 15 x 10 bits: needs a 25-bit context
                nib3_r  <= nib[3];
                st <= D_CALC2;
            end
            // stage 2: the new signal / step / position and the output value
            D_CALC2: begin : calc2
                logic signed [17:0] ns;
                logic signed [15:0] sg;
                logic [16:0] nsp;
                logic [14:0] spn;
                if (w_mode == 2'd1) begin
                    // ADPCM: one nibble
                    if (nib3_r) ns = {{2{w_sig[15]}}, w_sig} - $signed({2'b00, mag_r[18:3]});
                    else        ns = {{2{w_sig[15]}}, w_sig} + $signed({2'b00, mag_r[18:3]});
                    if (ns > 18'sd32767) sg = 16'sh7fff;
                    else if (ns < -18'sd32768) sg = 16'sh8000;
                    else sg = ns[15:0];
                    nsp = sprod_r[24:8];
                    if (nsp > 17'h6000) spn = 15'h6000;
                    else if (nsp < 17'h7f) spn = 15'h7f;
                    else spn = nsp[14:0];
                    sg2 <= sg; sp2 <= spn; xo2 <= sg; ps2 <= w_pos + 25'd1;
                end else if (w_mode == 2'd2) begin
                    sg2 <= w_sig; sp2 <= w_step; xo2 <= {b0, 8'h00}; ps2 <= w_pos + 25'd2;
                end else begin
                    sg2 <= w_sig; sp2 <= w_step; xo2 <= {b1, b0}; ps2 <= w_pos + 25'd4;
                end
                st <= D_CALC3;
            end
            // stage 3: the loop (the state at the loop start is remembered; at the loop end the position and the ADPCM state go back to it)
            D_CALC3: begin : calc3
                logic signed [15:0] sg, lsg;
                logic [14:0] sp, lsp;
                logic [24:0] ps;
                logic lseen;
                sg = sg2; sp = sp2; ps = ps2; lsg = w_lsig; lsp = w_lstep; lseen = w_lseen;
                if (w_mode == 2'd1) begin
                    if (w_looping) begin
                        if (ps == w_lst && !lseen) begin lsg = sg; lsp = sp; end
                        if (ps >= w_lend) begin
                            if (w_keyon) begin ps = w_lst; sg = lsg; sp = lsp; lseen = 1'b1; end
                        end
                    end
                end else begin
                    if (w_looping && ps >= w_lend && w_keyon) ps = w_lst;
                end
                s3_sg <= sg; s3_sp <= sp; s3_ps <= ps; s3_lsg <= lsg; s3_lsp <= lsp; s3_lseen <= lseen;
                st <= D_CALC4;
            end
            // stage 4: the end of the sample, then the voice's registers
            D_CALC4: begin
                w_sig <= s3_sg; w_step <= s3_sp; w_pos <= s3_ps;
                w_lsig <= s3_lsg; w_lstep <= s3_lsp; w_lseen <= s3_lseen;
                w_curr <= xo2;
                if (s3_ps >= w_stop) begin
                    w_playing <= 1'b0;
                    w_tail_on <= 1'b1;
                    w_tailv <= xo2;
                end
                st <= dec_ret;
            end

            default: st <= E_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
