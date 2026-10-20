//=============================================================================
//  tb_dual_chain.v —— cam1 整条裁剪+调度通路的端到端仿真
//
//  目的：在编译前就确认「cam1 的 tuser 到底会不会正常产生」。
//
//  链路:  (本 tb 造的行/帧结构)
//            -> ui_image_correction (cam0 / cam1 各一份, 同域)
//            -> dual_frame_sched   (单目 sel=1 直通)
//            -> 检查 O_v / O_u / O_l
//
//  为什么这么测: dbuf 写状态机必须收到 tuser(w_fs) 才会轮转三帧缓存,
//  没有 tuser 就画面冻结 —— 而这个信号在真实硬件上根本观测不到,
//  只能在仿真里把它抓住。
//
//  检查项:
//    [A] cam1 裁剪后 tuser 每帧恰好 1 次
//    [B] dual_frame_sched 在 sel=1/dual=0 时把 tuser 原样透传(每帧 1 次)
//    [C] O_v 有效拍数 == 帧数 * 有效行数 * 每行组数  (一拍不丢)
//    [D] O_l 每行 1 次
//    [E] sel=0 时同样成立(反向选源)
//=============================================================================
`timescale 1ns/1ps

module tb_dual_chain;

    reg clk = 0;
    reg rst_n = 0;
    always #4 clk = ~clk;               // ~125MHz

    localparam integer IMG_W   = 1920;
    localparam integer IMG_H   = 30;
    localparam integer V_START = 3;
    localparam integer GRP_DRIVE = 486;   // 实际每行组数 (0xD4/D5 实测 486)
    localparam integer GRP_OUT   = 480;   // 模块裁后输出组数 = 1920/4
    localparam integer GAP     = 20;    // 行间空闲 (>10 才产生 last)
    localparam integer FGAP    = 60;    // 帧间空闲
    localparam integer ROWS    = 40;    // 每帧喂多少行 (覆盖 v_cnt 0..33)

    //---------------- 激励 ----------------
    reg [39:0] d0 = 0, d1 = 0;
    reg v0 = 0, u0 = 0, l0 = 0;
    reg v1 = 0, u1 = 0, l1 = 0;

    wire fs0 = v0 & u0;                 // I_raw_frame_start
    wire fs1 = v1 & u1;
    wire v1_1 = v1;
    wire fs1_1 = fs1;

    //---------------- 被测: 两个裁剪模块 ----------------
    wire [39:0] c0_d, c1_d;
    wire c0_v, c0_u, c0_l;
    wire c1_v, c1_u, c1_l;
    wire [15:0] lg0, lg1;

    ui_image_correction #(.DATA_WIDTH(40), .TDEST_WIDTH(10)) u_crop0 (
        .O_line_groups    (lg0),
        .I_clk            (clk),
        .I_rst_n          (rst_n),
        .I_img_width      (IMG_W[12:0]),
        .I_img_height     (IMG_H[12:0]),
        .I_v_start        (V_START[12:0]),
        .I_grp_per_line   (13'd486),
        .I_raw_data       (d0),
        .I_raw_valid      (v0),
        .I_raw_frame_start(fs0),
        .I_raw_frame_end  (1'b0),
        .O_raw_tdata      (c0_d),
        .O_raw_tlast      (c0_l),
        .O_raw_tvalid     (c0_v),
        .O_raw_tuser      (c0_u)
    );

    ui_image_correction #(.DATA_WIDTH(40), .TDEST_WIDTH(10)) u_crop1 (
        .O_line_groups    (lg1),
        .I_clk            (clk),
        .I_rst_n          (rst_n),
        .I_img_width      (IMG_W[12:0]),
        .I_img_height     (IMG_H[12:0]),
        .I_v_start        (V_START[12:0]),
        .I_grp_per_line   (13'd486),
        .I_raw_data       (d1),
        .I_raw_valid      (v1),
        .I_raw_frame_start(fs1),
        .I_raw_frame_end  (1'b0),
        .O_raw_tdata      (c1_d),
        .O_raw_tlast      (c1_l),
        .O_raw_tvalid     (c1_v),
        .O_raw_tuser      (c1_u)
    );

    //---------------- 被测: 帧调度器 ----------------
    reg  sel = 1;                       // 1 = cam1
    reg  dual_en = 0;
    wire [39:0] o_d;
    wire o_v, o_u, o_l, o_src, o_lost, o_par;

    dual_frame_sched #(.DATA_WIDTH(40), .LINE_GRP(480)) u_sched (
        .I_clk      (clk),
        .I_clk1     (clk),
        .I_rst_n    (rst_n),
        .I_dual_en  (dual_en),
        .I_sel      (sel),
        .I_d0       (c0_d),
        .I_v0       (c0_v),
        .I_u0       (c0_u),
        .I_l0       (c0_l),
        .I_d1       (c1_d),
        .I_v1       (c1_v),
        .I_u1       (c1_u),
        .I_l1       (c1_l),
        .O_d        (o_d),
        .O_v        (o_v),
        .O_u        (o_u),
        .O_l        (o_l),
        .O_src      (o_src),
        .O_ch1_lost (o_lost),
        .O_parity   (o_par)
    );

    //---------------- 统计 ----------------
    integer cnt_v = 0, cnt_u = 0, cnt_l = 0;
    always @(posedge clk) begin
        if (o_v) cnt_v = cnt_v + 1;
        if (o_v && o_u) cnt_u = cnt_u + 1;
        if (o_v && o_l) cnt_l = cnt_l + 1;
    end

    integer c1u = 0, c0u = 0, c1v = 0, c1l = 0;
    always @(posedge clk) begin
        if (c1_u) c1u = c1u + 1;
        if (c0_u) c0u = c0u + 1;
        if (c1_v) c1v = c1v + 1;
        if (c1_l) c1l = c1l + 1;
    end

    //---------------- 造流 ----------------
    task automatic drive(input integer which, input integer nframe,
                         input integer phase);
        integer f, r, k;
        begin
            repeat (phase) @(posedge clk);
            for (f = 0; f < nframe; f = f + 1) begin
                for (r = 0; r < ROWS; r = r + 1) begin
                    for (k = 0; k < GRP_DRIVE; k = k + 1) begin
                        @(posedge clk); #1;
                        if (which == 0) begin
                            v0 = 1; u0 = (r == 0 && k == 0);
                            l0 = (k == GRP_DRIVE - 1);
                            d0 = {16'h0, r[11:0], k[11:0]};
                        end else begin
                            v1 = 1; u1 = (r == 0 && k == 0);
                            l1 = (k == GRP_DRIVE - 1);
                            d1 = {16'h0, r[11:0], k[11:0]};
                        end
                    end
                    @(posedge clk); #1;
                    if (which == 0) begin v0 = 0; u0 = 0; l0 = 0; end
                    else            begin v1 = 0; u1 = 0; l1 = 0; end
                    repeat (GAP) @(posedge clk);
                end
                repeat (FGAP) @(posedge clk);
            end
        end
    endtask

    integer errors = 0;
    integer ntest  = 0;

    task chk(input [255:0] name, input integer got, input integer want);
        begin
            ntest = ntest + 1;
            if (got !== want) begin
                $display("  FAIL %0s: got=%0d want=%0d", name, got, want);
                errors = errors + 1;
            end else
                $display("  ok   %0s = %0d", name, got);
        end
    endtask

    localparam integer NFRAME   = 3;
    localparam integer EXP_V    = NFRAME * IMG_H * GRP_OUT;

    initial begin
        #30 rst_n = 1;
        @(posedge clk);

        $display("[A] sel=1 (cam1 单目直通)");
        sel = 1; dual_en = 0;
        fork
            drive(0, NFRAME, 0);
            drive(1, NFRAME, 7);            // cam1 相位错开 7 拍
        join

        $display("     统计: cam1 tuser=%0d, O_v=%0d, O_u=%0d, O_l=%0d",
                 c1u, cnt_v, cnt_u, cnt_l);
        chk("cam1 裁剪后 tuser 次数", c1u, NFRAME);
        chk("调度器透传 tuser 次数", cnt_u, NFRAME);
        chk("O_v 有效拍数", cnt_v, EXP_V);
        chk("O_l 行尾次数", cnt_l, NFRAME * IMG_H);
        chk("cam1 行组数(首行)", lg1, GRP_DRIVE - 1);

        // 反向选源
        c0u = 0; c1u = 0; cnt_v = 0; cnt_u = 0; cnt_l = 0;
        $display("[B] sel=0 (cam0 单目直通)");
        sel = 0; dual_en = 0;
        fork
            drive(0, NFRAME, 0);
            drive(1, NFRAME, 7);
        join
        $display("     统计: cam0 tuser=%0d, O_v=%0d, O_u=%0d, O_l=%0d",
                 c0u, cnt_v, cnt_u, cnt_l);
        chk("cam0 裁剪后 tuser 次数", c0u, NFRAME);
        chk("调度器透传 tuser 次数", cnt_u, NFRAME);
        chk("O_v 有效拍数", cnt_v, EXP_V);
        chk("O_l 行尾次数", cnt_l, NFRAME * IMG_H);

        $display("");
        if (errors == 0) begin
            $display("==================================================");
            $display("PASS: cam1/cam0 通路 tuser/valid/tlast 全部正常 (%0d 项)", ntest);
            $display("==================================================");
        end else begin
            $display("==================================================");
            $display("FAIL: %0d / %0d 项", errors, ntest);
            $display("==================================================");
        end
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT (仿真跑太久)");
        $finish;
    end

endmodule
