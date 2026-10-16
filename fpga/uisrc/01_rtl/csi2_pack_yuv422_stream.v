/*==============================================================================
 *  csi2_pack_yuv422_stream.v  (Phase 1b)
 *  ui_dbuf.R (RGB32 AXIS @ src_clk)
 *      → async FIFO (33b, depth 4096) → YUV pipeline (5 stage)
 *      → output FIFO (34b, depth 4096) → AXIS to Layer-1 csi2_frame_tx 
 *
 *  V28 (2026-10-16): 修 4K 下 TX 完全不出帧 (死锁)
 *      原实现把输出 FIFO 流量门限写死为 1900 —— 那是按 1080p 一行 960 word
 *      (FIFO 2048 ≈ 2 行) 定的。4K 一行是 I_h_active>>1 = 1920 word, 而
 *      line_ready 要求 b_rd_data_count >= 1920。但 a_rd_en 被 b_near_full
 *      (占用 >1900) 提前掉断 ⇒ 占用永远到不了 1920 ⇒ line_ready 永远为假
 *      ⇒ line_priming 不触发 ⇒ m_tvalid 恒 0 ⇒ CIF 一帧都收不到。
 *      修法: 输出/输入 FIFO 都加深到 4096, 门限提到 3840 (留 256 余量,
 *            且 ≫ 1920, 保证 line_ready 可达)。
 *============================================================================*/
`timescale 1ns/1ps

module csi2_pack_yuv422_stream (
    input  wire        src_clk,
    input  wire        src_rst_n,
    input  wire [12:0] I_h_active,   // V21: 运行时有效像素/行
    input  wire [11:0] I_v_active,   // V21: 运行时有效行数
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire [31:0] s_tdata,
    input  wire        s_tuser_sof,
    input  wire        s_tlast,

    input  wire        dst_clk,
    input  wire        dst_rst_n,
    input  wire        enable,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire [31:0] m_tdata,
    output wire        m_tuser_sof,
    output wire        m_tlast
);

    wire [31:0] WORDS_PAYLOAD = I_h_active >> 1;   // V21: 运行时 (每行 32bit word 数)
    wire _unused_stlast = s_tlast;

    // --- Stage-A: async FIFO 33b×2048 ---
    wire        a_full, a_empty;
    wire [32:0] a_dout;
    wire        a_rst_async = ~(src_rst_n & dst_rst_n);

    reg         src_armed;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)                  src_armed <= 1'b0;
        else if (s_tvalid & s_tuser_sof) src_armed <= 1'b1;
    end
    wire        a_wr_en = s_tvalid & ~a_full & (src_armed | s_tuser_sof);
    assign      s_tready = ~a_full;
    reg         a_rd_en;

    // Stage-C output FIFO wr_data_count (forward-declared for gate)
    // V28: 计数位宽 = ADDR_WIDTH = 12 (深度 4096)
    wire [11:0] b_wr_data_count;
    // V28: 流量门限必须 > 一行 word 数(4K = 1920), 否则 line_ready 永远达不到。
    //      4096 - 256 = 3840, 既留了余量又远大于 1920。
    localparam [11:0] B_NEAR_FULL_TH = 12'd3840;
    wire        b_near_full = (b_wr_data_count > B_NEAR_FULL_TH);
    wire        a_can_read  = enable & ~a_empty & ~b_near_full;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) a_rd_en <= 1'b0;
        else            a_rd_en <= a_can_read;
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH(33),
        .ADDR_WIDTH(12)     // V28: depth 2048 -> 4096 (4K 一行 1920 word)
    ) u_async_fifo (
        .rst          (a_rst_async),
        .wr_clk       (src_clk    ),
        .rd_clk       (dst_clk    ),
        .din          ({s_tuser_sof, s_tdata}),
        .wr_en        (a_wr_en    ),
        .rd_en        (a_rd_en    ),
        .dout         (a_dout     ),
        .full         (a_full     ),
        .empty        (a_empty    ),
        .rd_data_count(           ),
        .wr_data_count(           ),
        .wr_rst_busy  (           ),
        .rd_rst_busy  (           )
    );

   
    reg        a_rd_en_d1;      // 1-cycle-later rd_en, aligned to a_dout
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) a_rd_en_d1 <= 1'b0;
        else            a_rd_en_d1 <= a_rd_en;
    end

    reg        pipe_in_valid;
    reg [31:0] pipe_in_rgb;
    reg        pipe_in_sof;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            pipe_in_valid <= 1'b0;
            pipe_in_rgb   <= 32'd0;
            pipe_in_sof   <= 1'b0;
        end else begin
            pipe_in_valid <= a_rd_en_d1;                            // aligned to a_dout
            pipe_in_rgb   <= a_dout[31:0];
            pipe_in_sof   <= a_rd_en_d1 ? a_dout[32] : 1'b0;
        end
    end

   
    reg        yuv_valid_r;
    reg [31:0] yuv_data_r;
    reg        yuv_sof_r;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            yuv_valid_r <= 1'b0;
            yuv_data_r  <= 32'd0;
            yuv_sof_r   <= 1'b0;
        end else begin
            yuv_valid_r <= pipe_in_valid;
            yuv_data_r  <= pipe_in_rgb;     // 端口名沿用 rgb 但内容已是 YUV422
            yuv_sof_r   <= pipe_in_sof & pipe_in_valid;
        end
    end
    wire        yuv_valid = yuv_valid_r;
    wire [31:0] yuv_data  = yuv_data_r;
    wire        _unused_yuv_sof_r = yuv_sof_r;


    // --- Flag regeneration at pipeline output ---
    reg        frame_start_pending;
    reg [15:0] word_col;

    // V21: 用行/列两级计数替代 V_ACTIVE*WORDS_PAYLOAD 乘法 (避免 125MHz 下的乘法器时序问题)
    reg        frame_window_open;
    reg [15:0] frame_row_cnt;

    wire yuv_valid_sig = yuv_valid;  // alias for readability
    wire yuv_sof  = yuv_valid_sig & frame_start_pending;
    wire yuv_last = yuv_valid_sig & (word_col == WORDS_PAYLOAD-1);

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            frame_start_pending <= 1'b0;
            word_col            <= 16'd0;
        end else begin
            if (pipe_in_sof & pipe_in_valid)
                frame_start_pending <= 1'b1;
            if (yuv_valid) begin
                if (frame_start_pending) frame_start_pending <= 1'b0;
            end
            // V14.2: word_col 只在 admitted yuv (frame window 内) advance,
            // 保证和 B FIFO 存储的 word 一一对应.
            if (yuv_sof) begin
                word_col <= 16'd1;   // sof 是该 line 的第 0 word, 下 cycle 算第 1
            end else if (frame_window_open & yuv_valid) begin
                word_col <= (word_col == WORDS_PAYLOAD-1) ? 16'd0 : (word_col + 1'b1);
            end
        end
    end

  
    // V21: 本行最后一个 word 且已是最后一行 -> 关闭帧窗口
    wire frame_last_word = frame_window_open & yuv_last &
                           (frame_row_cnt == (I_v_active - 12'd1));

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            frame_window_open <= 1'b0;
            frame_row_cnt     <= 16'd0;
        end else if (yuv_sof) begin
            // Force-open on every sof (resets a stuck window if any).
            frame_window_open <= 1'b1;
            frame_row_cnt     <= 16'd0;
        end else if (frame_last_word) begin
            frame_window_open <= 1'b0;
            frame_row_cnt     <= 16'd0;
        end else if (frame_window_open & yuv_valid & yuv_last) begin
            frame_row_cnt     <= frame_row_cnt + 16'd1;
        end
    end

    wire yuv_admit = yuv_valid & (frame_window_open | yuv_sof);

   
    wire        b_full, b_empty;
    wire [33:0] b_dout;
    wire [11:0] b_rd_data_count;    // V28: read-side fill (dst_clk domain), 12bit

    wire        b_wr_en = yuv_admit & ~b_full;
    reg         line_priming;        // 1-cycle prime read so dout holds word0
                                     // BEFORE m_tvalid (standard FIFO has 1-cycle
                                     // registered-dout latency). Without it the
                                     // first beat of every line is the stale
                                     // previous word -> per-row word0 / first-
                                     // column corruption.
    reg         line_active;
    reg         line_drain_done;     // accepted last word; close the line.
    reg [15:0]  drain_cnt;           // 1..WORDS_PAYLOAD = which presented word
    // V28: 门限用 12bit 切片 (4K = 1920, 1080p = 960, 都 < 4096)
    wire        line_ready = (b_rd_data_count >= WORDS_PAYLOAD[11:0]);

    // Pop the NEXT word while presenting word[drain_cnt-1]; no pop on the last
    // presented word (drain_cnt == WORDS_PAYLOAD).
    wire        active_pop = m_tready & line_active & ~line_drain_done &
                            (drain_cnt != WORDS_PAYLOAD[15:0]);
    wire        b_rd_en    = ~b_empty & (line_priming | active_pop);

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            line_priming    <= 1'b0;
            line_active     <= 1'b0;
            line_drain_done <= 1'b0;
            drain_cnt       <= 16'd0;
        end else if (!line_active && !line_priming) begin
            // Wait for a full line queued, then issue ONE prime read.
            if (line_ready) begin
                line_priming    <= 1'b1;
                line_drain_done <= 1'b0;
                drain_cnt       <= 16'd0;
            end
        end else if (line_priming) begin
            // prime read issued this cycle; word0 lands on dout next cycle.
            line_priming <= 1'b0;
            line_active  <= 1'b1;
            drain_cnt    <= 16'd1;   // word0 is the 1st presented word
        end else begin
            if (line_drain_done) begin
                line_active     <= 1'b0;
                line_drain_done <= 1'b0;
                drain_cnt       <= 16'd0;
            end else if (m_tready) begin
                // consumer accepted word[drain_cnt-1] this cycle
                if (drain_cnt == WORDS_PAYLOAD[15:0])
                    line_drain_done <= 1'b1;   // accepted the last word
                else
                    drain_cnt <= drain_cnt + 16'd1;
            end
        end
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH(34),
        .ADDR_WIDTH(12)     // V28: depth 4096 —— 4K 一行 1920 word, 必须能装 ≥ 2 行
    ) u_out_fifo (
        .rst          (~dst_rst_n),
        .wr_clk       (dst_clk   ),
        .rd_clk       (dst_clk   ),
        .din          ({yuv_sof, yuv_last, yuv_data}),
        .wr_en        (b_wr_en   ),
        .rd_en        (b_rd_en   ),
        .dout         (b_dout    ),
        .full         (b_full    ),
        .empty        (b_empty   ),
        .rd_data_count(b_rd_data_count),
        .wr_data_count(b_wr_data_count),
        .wr_rst_busy  (          ),
        .rd_rst_busy  (          )
    );

    // After the prime read, dout always holds a valid in-line word for the whole
    // line_active window (line_ready guarantees the full line is queued), so do
    // NOT gate with ~b_empty -- that could falsely drop the last word.
    assign m_tvalid    = line_active;
    assign m_tdata     = b_dout[31:0];
    assign m_tlast     = b_dout[32];
    assign m_tuser_sof = b_dout[33];

endmodule
