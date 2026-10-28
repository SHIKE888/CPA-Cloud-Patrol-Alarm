/*===========================================================================
 * tb_jpeg_ddr4.v —— DDR 读侧 + 4 引擎 全链路仿真 (V49)
 *
 *  验证 JPEG 源从 dbuf 写侧改到读侧之后, 整条链路仍然逐字节正确:
 *
 *    [32b = 2px @105MHz]  dbuf 读侧
 *      -> yuv32_to_quad        (凑成 64b = 4px, 早像素在低半)
 *      -> 行内 1/4 分组         (gcnt/gvld; 每行 128 个 64b word, 每段 32 个)
 *      -> 4x jpeg_enc_if        (跨时钟 FIFO, 64b -> 2x 32b)
 *      -> 4x jpeg_encoder_top   (各 128 宽 / 8 MCU 一段 / RST 0,1,2,3 交错)
 *      -> jpeg_seg_merge4       (1/4 行段合并)
 *
 *  判据:
 *    A) 自检: 像素通路零错误 (拼装/行尾/帧首) + 每引擎每行恰好 32 word
 *    B) 外部: ddr4.jpg 与 tb_jpeg_merge4 的 merged4.jpg 逐字节相同
 *       (merged4.jpg 已验证 == 单引擎 512 宽参考 ref4.jpg)
 *
 *  结束条件: 合并段数到达 4*H (=128) 后排空; 另有拍数兜底。
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_ddr4;

    localparam integer W1   = 512;
    localparam integer W4   = 128;
    localparam integer H    = 32;
    localparam integer RSTI = 8;
    localparam integer QW   = W1/4/4;
    localparam integer NSEG = 4*H;
    // 1 = 旁路合并器 (每个引擎 m_ready 恒 1) —— 先验证输入通路与引擎自身
    localparam integer BYP_MRG = 0;
    // enc_if 起送门限: 行缓冲 8 行必须被一次性喂满, 否则引擎会在填行缓冲途中断粮卡死
    //   (tb_eng_eif 实测边界: 7 行 OK / 6 行 FAIL)
    localparam integer SLVL = 16*QW;   // = 256

    reg r_clk, c_clk, rst_n;
    initial begin r_clk = 1'b0; c_clk = 1'b0; rst_n = 1'b0; end
    always #4.752 r_clk = ~r_clk;    // 9.504 ns -> 105.2 MHz (读侧)
    always #5.000 c_clk = ~c_clk;    // 10.00 ns -> 100.0 MHz (编码器)

    //------------------------------------------------------------------ 图案
    function [7:0] pY;  input integer x, y; begin pY  = (x*3  + y*7 ) & 8'hFF; end endfunction
    function [7:0] pCb; input integer x, y; begin pCb = (x*5  + y*13) & 8'hFF; end endfunction
    function [7:0] pCr; input integer x, y; begin pCr = (x*11 + y*3 ) & 8'hFF; end endfunction

    // 与 tb_jpeg_merge4 完全相同的像素打包 -> 可直接与 merged4.jpg 逐字节比对
    function [31:0] mkword; input integer x0, y; begin
        mkword = { pCr(x0,y), pY(x0+1,y), pCb(x0,y), pY(x0,y) };
    end endfunction

    //-------------------------------------------------------- 源 (dbuf 读侧)
    reg         r_v;
    reg  [31:0] r_d;
    reg         r_sof, r_last;
    wire        r_rdy;

    wire        c_v, c_sof, c_last;
    wire [63:0] c_d;
    reg         c_rdy;
    initial c_rdy = 1'b0;

    yuv32_to_quad u_conv (
        .r_clk(r_clk), .r_rst_n(rst_n),
        .r_valid(r_v), .r_data(r_d), .r_sof(r_sof), .r_last(r_last),
        .r_ready(r_rdy),
        .c_clk(c_clk), .c_rst_n(rst_n),
        .c_valid(c_v), .c_data(c_d), .c_sof(c_sof), .c_last(c_last),
        .c_ready(c_rdy)
    );

    //------------------------------------------------------ 行内 1/4 分组
    reg  [9:0] gcnt;
    wire [3:0] gvld = { (gcnt >= 3*QW),
                        (gcnt >= 2*QW) && (gcnt < 3*QW),
                        (gcnt >= 1*QW) && (gcnt < 2*QW),
                        (gcnt <  1*QW) };

    // 必须用 c_v & c_rdy 计数: gate=0 时 c_valid 会常高, 只用 c_v 会把分组冲飞
    always @(posedge c_clk or negedge rst_n) begin
        if (!rst_n)            gcnt <= 10'd0;
        else if (c_v && c_rdy) gcnt <= c_last ? 10'd0 : (gcnt + 10'd1);
    end

    //------------------------------------------------------ 4x jpeg_enc_if
    wire [3:0]  x_ev, x_erd;
    wire [31:0] x_ed [0:3];
    wire [15:0] x_wl [0:3];
    wire [15:0] x_ovf[0:3];

    genvar gi;
    generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_if
        jpeg_enc_if #(.AW(11), .START_LEVEL(SLVL)) u_enc_if (
            .s_clk      (c_clk          ),
            .s_rst_n    (rst_n          ),
            // ★ 必须带 c_rdy: yuv32_to_quad 在 c_ready=0 时会保持 c_valid 不变,
            //   若只用 c_v, 同一个字会被重复写进 FIFO (本次仿真已复现)
            .s_valid    (c_v & c_rdy & gvld[gi]),
            .s_data     (c_d            ),
            .s_sof      (c_sof          ),
            .e_clk      (c_clk          ),
            .e_rst_n    (rst_n          ),
            .i_flush    (1'b0           ),
            .e_valid    (x_ev[gi]       ),
            .e_data     (x_ed[gi]       ),
            .e_ready    (x_erd[gi]      ),
            .st_ovf     (x_ovf[gi]      ),
            .st_word_lo (x_wl[gi]       ),
            .st_sof     (               ),
            .o_level    (               )
        );
    end
    endgenerate

    //------------------------------------------------------ 4 引擎 + 量化表
    wire [3:0]  e_rdy, e_mv, e_ml, e_seg, e_bs, e_bd;
    wire [3:0]  e_mrdy = BYP_MRG ? 4'b1111 : e_rdy;
    wire [7:0]  e_md [0:3];
    wire [23:0] e_by [0:3];
    wire [31:0] e_bc [0:3];
    wire [6:0]  e_qa [0:3], e_qb [0:3];
    wire [7:0]  e_qta[0:3], e_qtb[0:3];

    genvar gq;
    generate
    for (gq = 0; gq < 4; gq = gq + 1) begin : g_qt
        jpeg_qtable_ram u_qt (.I_clk(c_clk), .I_rst_n(rst_n), .I_wr_en(1'b0),
            .I_wr_addr(8'd0), .I_wr_data(8'd0),
            .I_rd_idx_a(e_qa[gq]), .O_rd_data_a(), .O_rd_data_a_asyn(e_qta[gq]),
            .I_rd_idx_b(e_qb[gq]), .O_rd_data_b(e_qtb[gq]));
    end
    endgenerate

    genvar ge;
    generate
    for (ge = 0; ge < 4; ge = ge + 1) begin : g_enc
        jpeg_encoder_top #(.W(W4), .H(H),
                           .HDR_EN(ge == 0 ? 1 : 0),
                           .EOI_EN(ge == 3 ? 1 : 0),
                           .RST_INIT(ge),
                           .RST_STEP(4),
                           .LAST_RST_EN(ge == 3 ? 0 : 1)) u_e (
            .clk(c_clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(1'b0),
            .i_lossless(1'b0),
            .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
            .o_qt_idx_a(e_qa[ge]), .i_qt_data_a(e_qta[ge]),
            .o_qt_idx_b(e_qb[ge]), .i_qt_data_b(e_qtb[ge]),
            .s_valid(x_ev[ge]), .s_data(x_ed[ge]), .s_ready(x_erd[ge]),
            .m_valid(e_mv[ge]), .m_data(e_md[ge]), .m_last(e_ml[ge]),
            .m_ready(e_mrdy[ge]),
            .st_frame_bytes(e_by[ge]), .st_busy(e_bs[ge]), .st_done(e_bd[ge]),
            .st_frame_cnt(e_bc[ge]), .o_seg_done(e_seg[ge]));
    end
    endgenerate

    //------------------------------------------------------ 合并器 (4:1)
    wire        m_v, m_l;
    wire [7:0]  m_d;
    wire [9:0]  m_segc;
    reg         m_start;

    wire [31:0] e_d_pack = { e_md[3], e_md[2], e_md[1], e_md[0] };

    jpeg_seg_merge4 u_mrg (
        .clk(c_clk), .rst_n(rst_n), .i_start(m_start),
        .i_valid(e_mv), .i_data(e_d_pack), .i_last(e_ml),
        .o_ready(e_rdy), .i_seg_done(e_seg),
        .o_valid(m_v), .o_data(m_d), .o_last(m_l), .o_ready_down(1'b1),
        .o_seg_cnt(m_segc));

    //------------------------------------------------------ 自检
    integer err_px = 0, err_last = 0, err_sof = 0, err_grp = 0;
    integer n_sof = 0, n_last = 0, n_word = 0;
    integer exp_px, exp_y;
    integer n_in [0:3];
    integer n_rd32[0:3];

    initial begin exp_px = 0; exp_y = 0; end

    always @(posedge c_clk) begin
        if (rst_n && c_v && c_rdy) begin
            n_word = n_word + 1;
            if (c_sof)  n_sof  = n_sof + 1;
            if (c_last) n_last = n_last + 1;
            if (c_d[31:0] !== mkword(exp_px, exp_y)) begin
                if (err_px < 6)
                    $display("[ERR-PX] w#%0d y=%0d x=%0d lo=%h exp=%h",
                             n_word, exp_y, exp_px, c_d[31:0], mkword(exp_px, exp_y));
                err_px = err_px + 1;
            end
            if (c_d[63:32] !== mkword(exp_px+2, exp_y)) begin
                if (err_px < 6)
                    $display("[ERR-PX] w#%0d y=%0d x=%0d hi=%h exp=%h",
                             n_word, exp_y, exp_px+2, c_d[63:32], mkword(exp_px+2, exp_y));
                err_px = err_px + 1;
            end
            if (c_last !== ((exp_px == W1-4) ? 1'b1 : 1'b0)) begin
                if (err_last < 6)
                    $display("[ERR-LAST] w#%0d y=%0d x=%0d last=%b", n_word, exp_y, exp_px, c_last);
                err_last = err_last + 1;
            end
            if (c_sof !== ((exp_px == 0 && exp_y == 0) ? 1'b1 : 1'b0)) begin
                if (err_sof < 6)
                    $display("[ERR-SOF] w#%0d y=%0d x=%0d sof=%b", n_word, exp_y, exp_px, c_sof);
                err_sof = err_sof + 1;
            end
            if (c_last) begin exp_px = 0; exp_y = (exp_y + 1) % H; end
            else        begin exp_px = exp_px + 4; end
        end
    end

    genvar gk;
    generate
    for (gk = 0; gk < 4; gk = gk + 1) begin : g_chk
        integer cnt, line, bad, bad32;
        integer wl;                      // 本引擎已收 32b word 序号
        integer cw;                      // 本引擎累计被写入的 64b word 数
        initial begin cnt = 0; line = 0; bad = 0; bad32 = 0; wl = 0; cw = 0;
                      n_in[gk] = 0; n_rd32[gk] = 0; end
        always @(posedge c_clk) begin
            if (rst_n && c_v && c_rdy && gvld[gk]) begin cnt = cnt + 1; cw = cw + 1; end
            if (rst_n && c_v && c_rdy && c_last) begin
                if (cnt != QW) begin
                    if (bad < 4)
                        $display("[ERR-GRP] eng%0d line%0d got %0d word, exp %0d",
                                 gk, line, cnt, QW);
                    bad = bad + 1; err_grp = err_grp + 1;
                end
                cnt = 0; line = line + 1;
            end
            if (rst_n && x_ev[gk]) n_in[gk] = n_in[gk] + 1;
            // ★ 引擎实际收到的 32b 序列逐字比对
            //   期望: 第 n 个 word = 行 (n/(W4/2)), 行内第 (n%(W4/2)) 个 -> x0 = gk*W4 + 2k
            if (rst_n && x_ev[gk] && x_erd[gk]) begin
                if (x_ed[gk] !== mkword(gk*W4 + 2*(wl % (W4/2)),
                                        (wl / (W4/2)) % H)) begin
                    if (bad32 < 4)
                        $display("[ERR-E32] eng%0d word#%0d got=%h exp=%h",
                                 gk, wl, x_ed[gk],
                                 mkword(gk*W4 + 2*(wl % (W4/2)), (wl / (W4/2)) % H));
                    bad32 = bad32 + 1;
                end
                wl = wl + 1;
                n_rd32[gk] = n_rd32[gk] + 1;
            end
        end
    end
    endgenerate

    //------------------------------------------------------ 源激励
    initial begin : SRC
        integer y, k;
        r_v = 1'b0; r_d = 32'd0; r_sof = 1'b0; r_last = 1'b0;
        @(posedge rst_n);
        repeat (8) @(negedge r_clk);
        for (y = 0; y < H; y = y + 1) begin
            for (k = 0; k < W1/2; k = k + 1) begin
                @(negedge r_clk);
                r_v    = 1'b1;
                r_sof  = (y == 0 && k == 0);
                r_last = (k == W1/2 - 1);
                r_d    = mkword(2*k, y);
                @(posedge r_clk);
                while (!r_rdy) @(posedge r_clk);
            end
        end
        @(negedge r_clk); r_v = 1'b0; r_sof = 1'b0; r_last = 1'b0;
        $display("[TB] source done at %0t", $time);
    end

    //------------------------------------------------------ 输出到文件
    integer fdm, nm;
    initial begin fdm = $fopen("ddr4.jpg", "wb"); nm = 0; end
    always @(posedge c_clk) if (m_v === 1'b1) begin $fwrite(fdm, "%c", m_d); nm = nm + 1; end

    //------------------------------------------------------ 复位 / 门控 / 启动
    initial begin
        m_start = 1'b0;
        repeat (10) @(negedge c_clk);
        rst_n = 1'b1;
        $display("[TB] reset released at %0t", $time);
        repeat (4) @(negedge c_clk);
        m_start = 1'b1;
        @(negedge c_clk); m_start = 1'b0;
        repeat (30) @(negedge c_clk);
        c_rdy = 1'b1;
        $display("[TB] gate open at %0t", $time);
    end

    //------------------------------------------------------ 收尾
    integer cyc = 0;
    always @(posedge c_clk) cyc = cyc + 1;

    // 输出停滞检测: nm 连续 30000 拍不变化 = 帧已吐完
    integer nm_d = 0, stall = 0;
    always @(posedge c_clk) begin
        if (nm != nm_d) begin nm_d = nm; stall = 0; end
        else                stall = stall + 1;
    end

    initial begin
        // 四个引擎都把本帧 1024 个 64b word 吃完 -> 再等输出完全吐干净
        wait ((x_wl[0] == W1*H/4/4) && (x_wl[1] == W1*H/4/4) &&
              (x_wl[2] == W1*H/4/4) && (x_wl[3] == W1*H/4/4));
        wait (stall > 30000);
        $fclose(fdm);
        $display("--------------------------------------------------");
        $display("WORDS   : %0d  (exp %0d)", n_word, W1*H/4);
        $display("SOF     : %0d  (exp 1)", n_sof);
        $display("LAST    : %0d  (exp %0d)", n_last, H);
        $display("ERR  px=%0d last=%0d sof=%0d grp=%0d", err_px, err_last, err_sof, err_grp);
        $display("MERGED  : %0d bytes  segcnt=%0d  cyc=%0d", nm, m_segc, cyc);
        $display("ENG in  : %0d/%0d/%0d/%0d   rd32=%0d/%0d/%0d/%0d",
                 n_in[0], n_in[1], n_in[2], n_in[3],
                 n_rd32[0], n_rd32[1], n_rd32[2], n_rd32[3]);
        $display("ENG by  : %0d/%0d/%0d/%0d  wl=%0d/%0d/%0d/%0d  ovf=%b",
                 e_by[0], e_by[1], e_by[2], e_by[3],
                 x_wl[0], x_wl[1], x_wl[2], x_wl[3],
                 (|x_ovf[0]) | (|x_ovf[1]) | (|x_ovf[2]) | (|x_ovf[3]));
        if (err_px == 0 && err_last == 0 && err_sof == 0 && err_grp == 0)
            $display("PIXEL PATH  OK");
        else
            $display("PIXEL PATH  FAIL");
        $finish;
    end

    initial begin
        wait (cyc >= 250000);
        $display("TIMEOUT cyc=%0d merged=%0d segcnt=%0d words=%0d", cyc, nm, m_segc, n_word);
        $display("ENG in  : %0d/%0d/%0d/%0d   rd32=%0d/%0d/%0d/%0d",
                 n_in[0], n_in[1], n_in[2], n_in[3],
                 n_rd32[0], n_rd32[1], n_rd32[2], n_rd32[3]);
        $display("ENG by  : %0d/%0d/%0d/%0d  wl=%0d/%0d/%0d/%0d  ovf=%b",
                 e_by[0], e_by[1], e_by[2], e_by[3],
                 x_wl[0], x_wl[1], x_wl[2], x_wl[3],
                 (|x_ovf[0]) | (|x_ovf[1]) | (|x_ovf[2]) | (|x_ovf[3]));
        $display("ENG wr  : %0d/%0d/%0d/%0d  (每引擎应 %0d)",
                 g_chk[0].cw, g_chk[1].cw, g_chk[2].cw, g_chk[3].cw, W1*H/4/4);
        $display("ENG busy=%b done=%b srdy=%b mrdy=%b mv=%b seg=%b",
                 e_bs, e_bd, x_erd, e_rdy, e_mv, e_seg);
        $display("FIFO rem : %0d/%0d/%0d/%0d   (enc_if 里剩余 64b word)",
                 g_if[0].u_enc_if.f_rcnt, g_if[1].u_enc_if.f_rcnt,
                 g_if[2].u_enc_if.f_rcnt, g_if[3].u_enc_if.f_rcnt);
        $display("ENG srdy : %b  mv=%b  by=%0d/%0d",
                 x_erd, e_mv, e_by[0], e_by[2]);
        $fclose(fdm);
        $finish;
    end

endmodule
