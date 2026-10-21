/*===========================================================================
 * tb_jpeg_e2e.v —— JPEG 编码器端到端仿真
 *
 *  1. 从 jpeg_in.hex 读 YUV422, 按行扫进 jpeg_encoder_top
 *  2. 把输出的 JPEG 字节流写到 rtl.jpg
 *  3. 用 Python 与 ref.jpg 逐字节比对
 *
 *  尺寸通过参数覆盖:
 *      iverilog -Ptb_jpeg_e2e.W=128 -Ptb_jpeg_e2e.H=32 ...
 *  必须与 tools/gen_jpeg_e2e.py 的参数一致 (W%16==0, H%8==0)。
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_e2e;

    // 尺寸由 tools/gen_jpeg_e2e.py 生成的 jpeg_sim_cfg.vh 提供
    // (iverilog 在 PowerShell 下 -D/-P 参数传递不可靠, 用头文件最稳)
`include "jpeg_sim_cfg.vh"

`ifndef SIM_LL
    `define SIM_LL 1'b0
`endif

    parameter integer W = `SIM_W;
    parameter integer H = `SIM_H;

    reg         clk;
    reg         rst_n;

    reg         s_valid;
    reg  [31:0] s_data;
    wire        s_ready;

    wire        m_valid;
    wire [7:0]  m_data;
    wire        m_last;

    wire [6:0]  qt_idx_a, qt_idx_b;
    wire [7:0]  qt_a, qt_b;

    wire [23:0] st_bytes;
    wire        st_busy, st_done;
    wire [31:0] st_cnt;

    // ---- 死锁定位用 (只在无损模式下打印) ----
    integer dbg_cyc = 0;
    integer dbg_xready = 0;     // negedge 上 s_ready 为 X 的次数
    integer dbg_accept = 0;     // posedge 上 (s_valid && s_ready) 成立的次数
    integer dbg_waitcyc = 0;    // for 循环内 while(!s_ready) 自旋的拍数
    always @(posedge clk) begin
        dbg_cyc <= dbg_cyc + 1;
        if (s_valid === 1'b1 && s_ready === 1'b1) dbg_accept <= dbg_accept + 1;
        if (`SIM_LL && (dbg_cyc % 20000) == 0)
            $display("DBG t=%0d tstate=%0d llwcnt=%0d llready=%b svld=%b llstate=%0d inhv=%b xrdy=%0d acc=%0d wait=%0d",
                     $time, dut.tstate, dut.ll_wcnt, dut.ll_ready,
                     dut.s_valid, dut.u_ll.state, dut.u_ll.in_have,
                     dbg_xready, dbg_accept, dbg_waitcyc);
    end
    always @(negedge clk) if (s_ready === 1'bx) dbg_xready = dbg_xready + 1;

    // ---- 吞吐测量: 一帧从 st_busy 上升到 st_done 用了多少拍 ----
    //   1920x1080@60 的预算是 147.5e6 / ((1920/16)*(1080/8)*60) = 151.7 clk/MCU
    integer cyc_frame = 0;
    reg     busy_d = 0, done_d = 0;
    always @(posedge clk) begin
        busy_d <= st_busy;
        done_d <= st_done;
        if (st_busy && !busy_d) cyc_frame = 0;
        if (st_busy)            cyc_frame = cyc_frame + 1;
        if (st_done && !done_d)
            $display("PERF: 一帧 %0d clk, MCU=%0d, clk/MCU=%0d  (60fps 预算 151.7)",
                     cyc_frame, (W / 16) * (H / 8),
                     cyc_frame / (((W / 16) * (H / 8)) == 0 ? 1 : ((W / 16) * (H / 8))));
    end

    jpeg_encoder_top #(.W(W), .H(H)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_en         (1'b1),
        .i_soft_rst   (1'b0),
        .i_lossless   (`SIM_LL),
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
        .st_frame_bytes(st_bytes),
        .st_busy      (st_busy),
        .st_done      (st_done),
        .st_frame_cnt (st_cnt)
    );

    // 量化表 (复位即装 Annex K.1 标准表)
    jpeg_qtable_ram u_qt (        .I_clk      (clk),
        .I_rst_n    (rst_n),
        .I_wr_en    (1'b0),
        .I_wr_addr  (8'd0),
        .I_wr_data  (8'd0),
        .I_rd_idx_a (qt_idx_a),
        .O_rd_data_a(qt_a),
        .I_rd_idx_b (qt_idx_b),
        .O_rd_data_b(qt_b)
    );

    //--------------------------------------------------------------- 时钟
    initial clk = 1'b0;
    always #3.3 clk = ~clk;         // ~150MHz

    //--------------------------------------------------------------- 输入向量
    // ★ 流式读取, 不建大数组 —— 1920x1080 需要 1036800 个 word,
    //   全部读进 reg 数组会让 iverilog 慢到无法接受
    reg [31:0] vword;
    integer fin;
    integer frc;
    integer nwords;
    integer i;
    integer fd;
    integer nout;

    initial begin
        nwords = (W / 2) * H;
    end

    //--------------------------------------------------------------- 输出收集
    initial begin
        nout = 0;
        fd = $fopen("rtl.jpg", "wb");
        forever begin
            @(posedge clk);
            #1;
            if (m_valid) begin
                $fwrite(fd, "%c", m_data);
                nout = nout + 1;
            end
        end
    end

    //--------------------------------------------------------------- 主流程
    initial begin
        rst_n   = 1'b0;
        s_valid = 1'b0;
        s_data  = 32'd0;

        fin = $fopen("jpeg_in.hex", "r");
        if (fin == 0) begin
            $display("ERROR: cannot open jpeg_in.hex");
            $finish;
        end

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // 必须尊重 s_ready: 行缓冲是 8 行乒乓, 编码跟不上时上游要被反压。
        // 原来无条件每拍喂, 长图 (H>16) 时第 3 组起的数据会被静默丢弃。
        for (i = 0; i < nwords; i = i + 1) begin
            @(negedge clk);
            frc = $fscanf(fin, "%h\n", vword);
            s_valid = 1'b1;
            s_data  = vword;
            #1;
            while (!s_ready) begin
                @(negedge clk);
                #1;
            end
        end
        @(negedge clk);
        s_valid = 1'b0;
        $fclose(fin);

        wait (st_done == 1'b1);
        // st_done 与 m_last (EOI 的 D9) 同拍拉高, 再多等 1 拍让写文件块落盘即可。
        // 原来等 10 拍会把下一帧的 SOI/APP0 前 6 字节也写进文件。
        repeat (2) @(posedge clk);

        $fclose(fd);
        $display("RTL: %0d bytes, st_frame_bytes=%0d, frames=%0d",
                 nout, st_bytes, st_cnt);
        $finish;
    end

    initial begin
        // 超时按画面大小自适应: 无损 4 clk/word, 加余量取 W*H*8
        #(W * H * 8 + 200_000);
        $display("TIMEOUT: only %0d bytes", nout);
        $fclose(fd);
        $finish;
    end

    // 帧完成日志
    always @(posedge clk) begin
        if (st_done) $display("FRAME DONE t=%0t nout=%0d", $time, nout);
    end

endmodule
