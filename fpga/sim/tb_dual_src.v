//=============================================================================
// tb_dual_src.v —— 双路 CSI 源选择 + 裁剪模块 的独立验证
//
// 目的（对应"每一路都要能单独测试"这条需求）：
//   1. 只接 cam0（sel=0）时，下游看到的组数/行数/像素值与单路版本一致；
//   2. 只接 cam1（sel=1）时，同样正确；
//   3. 两路同时在跑时，**未选中的那一路绝不允许漏进下游**（这是 0x4511
//      出现"鬼影 + 0xD4/D5 从 610 涨到 738"的最可能原因：当时两路输出
//      在总线上被混在一起了）；
//   4. 运行中切换源，经过复位窗之后必须重新对齐。
//
// 被测逻辑 = system_top 里新增的那几行：
//     sel -> 2 级同步 -> sel_rx -> AXIS 二选一 -> ui_image_correction
//   以及"换源复位窗"。
//
// 说明：这里不复现 mipi_csi_rx 本体（IDDR/IDELAY 原语在 iverilog 里没有模型），
//   而是用行为模型产生与真实 RX 相同**时序形状**的 AXIS：
//     - tuser 与帧首组同拍
//     - 行间 valid 拉低 ROW_GAP 拍（>10，正好喂饱 ui_image_correction 的
//       cnt==10 行分隔判据）
//     - 每行 GRP_ROW 组，其中只有前 W_PIX/4 组是有效像素，其余是 FS/FE 填充
//=============================================================================
`timescale 1ns/1ps

module tb_dual_src;

    //-------------------------------------------------------------------------
    // 参数（与真实 1080p 的形状同构，只是缩小）
    //-------------------------------------------------------------------------
    localparam integer W_PIX   = 32;   // 图像宽像素 -> 8 组/行
    localparam integer H_PIX   = 8;    // 图像高
    localparam integer V_START = 1;    // 垂直裁剪起点

    localparam integer GRP_ROW = 16;   // 每行总组数（8 有效 + 8 填充）
    localparam integer ROW_GAP = 16;   // 行间 valid 低电平拍数（必须 > 10）
    localparam integer NROW    = 12;   // 每帧行数（要 >= v_start + H_PIX + 1）
    localparam integer FGAP    = 40;   // 帧间空隙
    localparam integer RST_WIN = 64;   // 换源复位窗（真实是 120ms，这里缩短）

    localparam [39:0] PAT0 = 40'h11_1111_1111;   // cam0 的数据指纹
    localparam [39:0] PAT1 = 40'h22_2222_2222;   // cam1 的数据指纹

    localparam integer FRAME_CYC = NROW * (GRP_ROW + ROW_GAP) + FGAP;

    //-------------------------------------------------------------------------
    // 时钟 / 复位
    //-------------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;          // 100MHz，代表 RX 的 byte clock
    reg rstn = 0;

    //-------------------------------------------------------------------------
    // 两个行为化的 AXIS 源（模拟 mipi_csi_rx 的 m_axis_video_*）
    //-------------------------------------------------------------------------
    reg        run0 = 0, run1 = 0;
    reg [39:0] d0, d1;
    reg        v0, u0, v1, u1;

    reg [15:0] r0_row, r0_col, r0_gap;
    reg [15:0] r1_row, r1_col, r1_gap;

    always @(posedge clk) begin
        if (!rstn || !run0) begin
            u0 <= 1'b0; v0 <= 1'b0;
            r0_row <= 0; r0_col <= 0; r0_gap <= 0;
        end else if (r0_gap != 0) begin
            r0_gap <= r0_gap - 1; v0 <= 1'b0; u0 <= 1'b0;
        end else if (r0_col == 0) begin
            if (r0_row >= NROW) begin
                r0_row <= 0; r0_gap <= FGAP - 1; v0 <= 1'b0; u0 <= 1'b0;
            end else begin
                d0 <= PAT0; v0 <= 1'b1; u0 <= (r0_row == 0);
                r0_col <= 1;
            end
        end else if (r0_col < GRP_ROW) begin
            d0 <= PAT0; v0 <= 1'b1; u0 <= 1'b0;
            r0_col <= r0_col + 1;
        end else begin
            r0_col <= 0; r0_row <= r0_row + 1;
            r0_gap <= ROW_GAP - 1; v0 <= 1'b0; u0 <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rstn || !run1) begin
            u1 <= 1'b0; v1 <= 1'b0;
            r1_row <= 0; r1_col <= 0; r1_gap <= 0;
        end else if (r1_gap != 0) begin
            r1_gap <= r1_gap - 1; v1 <= 1'b0; u1 <= 1'b0;
        end else if (r1_col == 0) begin
            if (r1_row >= NROW) begin
                r1_row <= 0; r1_gap <= FGAP - 1; v1 <= 1'b0; u1 <= 1'b0;
            end else begin
                d1 <= PAT1; v1 <= 1'b1; u1 <= (r1_row == 0);
                r1_col <= 1;
            end
        end else if (r1_col < GRP_ROW) begin
            d1 <= PAT1; v1 <= 1'b1; u1 <= 1'b0;
            r1_col <= r1_col + 1;
        end else begin
            r1_col <= 0; r1_row <= r1_row + 1;
            r1_gap <= ROW_GAP - 1; v1 <= 1'b0; u1 <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // DUT 前置：选源同步 + AXIS 二选一（与 system_top 完全一致的写法）
    //-------------------------------------------------------------------------
    reg        sel = 1'b0;
    reg  [1:0] sel_rx_s;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) sel_rx_s <= 2'b00;
        else       sel_rx_s <= {sel_rx_s[0], sel};
    end
    wire sel_rx = sel_rx_s[1];

    wire [39:0] m_tdata  = sel_rx ? d1 : d0;
    wire        m_tvalid = sel_rx ? v1 : v0;
    wire        m_tuser  = sel_rx ? u1 : u0;

    //-------------------------------------------------------------------------
    // 换源复位窗（真实是 120ms @25MHz，这里缩成 RST_WIN 拍）
    //-------------------------------------------------------------------------
    reg        sel_d;
    reg [15:0] win;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            sel_d <= 1'b0; win <= 16'd0;
        end else begin
            sel_d <= sel;
            if (sel != sel_d)      win <= RST_WIN;
            else if (win != 0)     win <= win - 1;
        end
    end
    wire dst_rstn = rstn & (win == 16'd0);

    //-------------------------------------------------------------------------
    // 被测：ui_image_correction
    //-------------------------------------------------------------------------
    wire [39:0] o_tdata;
    wire        o_tvalid, o_tlast, o_tuser;
    wire [15:0] o_groups;

    ui_image_correction #(
        .DATA_WIDTH  (40),
        .TDEST_WIDTH (10)
    ) u_corr (
        .I_clk            (clk),
        .I_rst_n          (dst_rstn),
        .I_img_width      (W_PIX[12:0]),
        .I_img_height     (H_PIX[12:0]),
        .I_v_start        (V_START[12:0]),
        .I_grp_per_line   (13'd0),          // 0 = 用行间空闲分行(原行为)
        .I_raw_data       (m_tdata),
        .I_raw_valid      (m_tvalid),
        .I_raw_frame_start(m_tvalid & m_tuser),
        .I_raw_frame_end  (1'b0),
        .O_line_groups    (o_groups),
        .O_raw_tdata      (o_tdata),
        .O_raw_tlast      (o_tlast),
        .O_raw_tvalid     (o_tvalid),
        .O_raw_tuser      (o_tuser),
        .O_raw_tready     (1'b1)
    );

    //-------------------------------------------------------------------------
    // 统计
    //-------------------------------------------------------------------------
    integer n_out, n_last, n_user, n_pat0, n_pat1, n_other;
    integer err_cnt;

    always @(posedge clk) begin
        if (rstn && o_tvalid) begin
            n_out = n_out + 1;
            if (o_tdata === PAT0)      n_pat0  = n_pat0  + 1;
            else if (o_tdata === PAT1) n_pat1  = n_pat1  + 1;
            else                       n_other = n_other + 1;
        end
        if (rstn && o_tlast) n_last = n_last + 1;
        if (rstn && o_tuser) n_user = n_user + 1;
    end

    task clr_stats;
        begin
            n_out = 0; n_last = 0; n_user = 0;
            n_pat0 = 0; n_pat1 = 0; n_other = 0;
        end
    endtask

    task chk(input [255:0] name,
             input integer exp_out, input integer exp_last, input integer exp_user,
             input integer exp_pat0, input integer exp_pat1);
        begin
            $display("---------------------------------------------------------------");
            $display("[%0s] sel=%0d run0=%0d run1=%0d", name, sel, run0, run1);
            $display("  out  = %0d (exp %0d)", n_out,  exp_out);
            $display("  last = %0d (exp %0d)", n_last, exp_last);
            $display("  user = %0d (exp %0d)", n_user, exp_user);
            $display("  pat0 = %0d (exp %0d)", n_pat0, exp_pat0);
            $display("  pat1 = %0d (exp %0d)", n_pat1, exp_pat1);
            $display("  other= %0d, o_line_groups = %0d (exp %0d)", n_other, o_groups, GRP_ROW);
            if (n_out !== exp_out || n_last !== exp_last || n_user !== exp_user ||
                n_pat0 !== exp_pat0 || n_pat1 !== exp_pat1 ||
                n_other !== 0 || o_groups !== GRP_ROW) begin
                $display("  >>> FAIL");
                err_cnt = err_cnt + 1;
            end else begin
                $display("  >>> OK");
            end
        end
    endtask

    // 每帧下游应放出的拍数：图像高 H_PIX × 每行有效组数 (W_PIX/4)
    localparam integer OUT_PER_FRAME  = H_PIX * (W_PIX/4);
    localparam integer LAST_PER_FRAME = H_PIX;
    localparam integer USER_PER_FRAME = 1;
    localparam integer NFRAME         = 3;

    integer k;
    initial begin
        err_cnt = 0;
        clr_stats;
        run0 = 0; run1 = 0; sel = 0;

        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        //--------------------------------------------------------------
        // A: 只接 cam0 (sel=0, 只有 src0 在跑)
        //--------------------------------------------------------------
        clr_stats;
        run0 = 1; run1 = 0; sel = 0;
        repeat (NFRAME * FRAME_CYC) @(posedge clk);
        chk("A cam0 only", NFRAME*OUT_PER_FRAME, NFRAME*LAST_PER_FRAME, NFRAME*USER_PER_FRAME,
                        NFRAME*OUT_PER_FRAME, 0);

        //--------------------------------------------------------------
        // B: sel=0，但两路都在跑 —— cam1 的数据绝不允许漏进来
        //--------------------------------------------------------------
        run1 = 1;
        repeat (2 * FRAME_CYC) @(posedge clk);       // 等两路相位错开
        clr_stats;
        repeat (NFRAME * FRAME_CYC) @(posedge clk);
        chk("B both run, sel=0", NFRAME*OUT_PER_FRAME, NFRAME*LAST_PER_FRAME, NFRAME*USER_PER_FRAME,
                              NFRAME*OUT_PER_FRAME, 0);

        //--------------------------------------------------------------
        // C: 只接 cam1 (sel=1, 只有 src1 在跑)
        //--------------------------------------------------------------
        run0 = 0; sel = 1;
        repeat (2 * FRAME_CYC) @(posedge clk);       // 等复位窗 + 重新对齐
        clr_stats;
        repeat (NFRAME * FRAME_CYC) @(posedge clk);
        chk("C cam1 only", NFRAME*OUT_PER_FRAME, NFRAME*LAST_PER_FRAME, NFRAME*USER_PER_FRAME,
                        0, NFRAME*OUT_PER_FRAME);

        //--------------------------------------------------------------
        // D: sel=1，两路都在跑 —— cam0 的数据绝不允许漏进来
        //--------------------------------------------------------------
        run0 = 1;
        repeat (2 * FRAME_CYC) @(posedge clk);
        clr_stats;
        repeat (NFRAME * FRAME_CYC) @(posedge clk);
        chk("D both run, sel=1", NFRAME*OUT_PER_FRAME, NFRAME*LAST_PER_FRAME, NFRAME*USER_PER_FRAME,
                              0, NFRAME*OUT_PER_FRAME);

        //--------------------------------------------------------------
        // E: 运行中从 cam1 切回 cam0（模拟板上写 0xDB=0）
        //    切换后必须靠复位窗重新对齐，不能出现半帧混合
        //--------------------------------------------------------------
        sel = 0;
        repeat (2 * FRAME_CYC) @(posedge clk);
        clr_stats;
        repeat (NFRAME * FRAME_CYC) @(posedge clk);
        chk("E switch back to cam0", NFRAME*OUT_PER_FRAME, NFRAME*LAST_PER_FRAME, NFRAME*USER_PER_FRAME,
                             NFRAME*OUT_PER_FRAME, 0);

        //--------------------------------------------------------------
        $display("===============================================================");
        if (err_cnt == 0) $display("PASS: dual-source select + per-channel isolation OK");
        else              $display("FAIL: %0d check(s) failed", err_cnt);
        $display("===============================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
