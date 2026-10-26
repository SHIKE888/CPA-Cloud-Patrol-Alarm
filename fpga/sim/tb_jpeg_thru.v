/*===========================================================================
 * tb_jpeg_thru.v —— 测 jpeg_encoder_top 的**真实** clk/MCU 与像素吞吐
 *
 *  为什么要测: 文件头写的"312 拍/MCU -> 29fps @147.5MHz"是**串行版**的账,
 *  但 FSM 里其实已经有块级流水 (pend / qzz 双缓冲 / 熵编码后台调度)。
 *  到底现在是多少, 只能实测 —— 这个数直接决定要不要 300MHz、要不要重做流水。
 *
 *  输入: 合成斜坡 (不读 hex, 一张 1920x1080 也不占内存)
 *  输出: 一帧 clk 数、clk/MCU, 以及各候选时钟下的 Mpx/s 与等效帧率
 *
 *  编译运行: fpga/sim/run_jpeg_thru.ps1
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_thru;

    parameter integer W = 320;              // 小尺寸即可: clk/MCU 与分辨率无关
    parameter integer H = 256;               // MCU=20x32=640, 把帧头/drain 开销摊薄
    parameter integer LL = 0;                // 0=有损(DCT) 1=无损(DPCM)

    reg clk = 1'b0;
    always #3.3 clk = ~clk;                    // ~151.5MHz

    reg rst_n = 1'b0;

    // 源: 连续流 (s_valid 恒 1), 只在握手成立时推进数据 —— 与真实相机一致
    reg  [31:0] s_data = 32'd0;
    wire        s_ready;
    reg         s_valid = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) s_data <= 32'd0;
        else if (s_valid && s_ready) s_data <= s_data + 32'd1;
    end

    wire        m_valid;
    wire [7:0]  m_data;
    wire        m_last;
    wire [6:0]  qt_idx_a, qt_idx_b;
    wire [7:0]  qt_a, qt_b;
    wire [23:0] st_bytes;
    wire        st_busy, st_done;
    wire [31:0] st_cnt;

    jpeg_encoder_top #(.W(W), .H(H)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_en         (1'b1),
        .i_soft_rst   (1'b0),
        .i_lossless   (LL[0]),
        .i_width      (W[11:0]),
        .i_height     (H[11:0]),
        .o_qt_idx_a   (qt_idx_a),
        .i_qt_data_a  (qt_a),
        .o_qt_idx_b   (qt_idx_b),
        .i_qt_data_b  (qt_b),
        .s_valid      (s_valid),
        .s_data       (s_data),
        .s_ready      (s_ready),
        .m_valid      (m_valid),
        .m_data       (m_data),
        .m_last       (m_last),
        .m_ready      (1'b1),                  // 下游永远接得住 (只测编码器)
        .st_frame_bytes(st_bytes),
        .st_busy      (st_busy),
        .st_done      (st_done),
        .st_frame_cnt (st_cnt)
    );

    jpeg_qtable_ram u_qt (
        .I_clk      (clk),
        .I_rst_n    (rst_n),
        .I_wr_en    (1'b0),
        .I_wr_addr  (8'd0),
        .I_wr_data  (8'd0),
        .I_rd_idx_a (qt_idx_a),
        .O_rd_data_a(qt_a),
        .I_rd_idx_b (qt_idx_b),
        .O_rd_data_b(qt_b)
    );

    // ---------------- 统计 ----------------
    localparam integer NMCU     = (W/16) * (H/8);

    integer nframe = 0;
    integer cyc    = 0;
    reg     busy_d = 1'b0, done_d = 1'b0;
    integer t_busy_start = 0;
    integer t_done       = 0;

    // 与分辨率无关的换算
    //   吞吐(Mpx/s) = 128 px/MCU / (clk/MCU) * f_clk
    //   1080p60 需 124.4 Mpx/s; 双路1080p60 与 4K30 都需 248.8 Mpx/s
    real cpm;
    real mpx_at_300;
    real need_mhz;

    always @(posedge clk) begin
        busy_d <= st_busy;
        done_d <= st_done;
        if (st_busy && !busy_d) begin
            cyc = 0;
            t_busy_start = $time;
        end
        if (st_busy) cyc = cyc + 1;
        if (st_done && !done_d) begin
            t_done = $time;
            nframe = nframe + 1;
            cpm       = cyc * 1.0 / NMCU;
            mpx_at_300= 128.0 / cpm * 300.0;
            need_mhz  = 248.8 * cpm / 128.0;
            $display("FRAME %0d: clk=%0d  clk/MCU=%0.1f  MCU=%0d  bytes=%0d  LL=%0d",
                     nframe, cyc, cpm, NMCU, st_bytes, LL);
            $display("   @300MHz -> %0.1f Mpx/s   (1080p %0.1f fps / 4K %0.1f fps)",
                     mpx_at_300, mpx_at_300/2.0736, mpx_at_300/8.2944);
            $display("   need clock >= %0.0f MHz for 248.8 Mpx/s (dual 1080p60 = 4K30)", need_mhz);
            if (nframe >= 2) begin
                if (need_mhz <= 300.0)
                    $display("VERDICT: 300MHz is ENOUGH for 248.8 Mpx/s (no extra pipelining needed)");
                else
                    $display("VERDICT: 300MHz NOT enough, must pipeline to clk/MCU <= %0.1f",
                             128.0*300.0/248.8);
                $finish;
            end
        end
    end

    initial begin
        // 不开 VCD: 一颗 1080p 帧 = 3M+ 拍, dump 整个 DUT 会慢到无法接受且文件巨大
        #100;
        rst_n  = 1'b1;
        s_valid= 1'b1;
    end

    initial begin
        #2_000_000;                  // 2ms 模拟时间 (小尺寸两帧绰绰有余)
        $display("TIMEOUT: nframe=%0d cyc=%0d", nframe, cyc);
        $finish;
    end

endmodule
