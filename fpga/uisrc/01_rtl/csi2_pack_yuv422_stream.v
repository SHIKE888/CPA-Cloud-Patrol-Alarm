/*==============================================================================
 *  csi2_pack_yuv422_stream.v  (Phase 1b)
 *  ui_dbuf.R (RGB32 AXIS @ src_clk)
 *      → async FIFO (33b, depth 4096) → YUV pipeline (5 stage)
 *      → output FIFO (34b, depth 4096) → 4-deep skid queue → AXIS to csi2_frame_tx 
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

    // --- Stage-A: async FIFO 33b×4096 ---
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
    wire [11:0] b_wr_data_count;    // V42: ADDR_WIDTH=12 → 12-bit count (depth 4096)
    //
    // ★★ V28b (2026-10-16) 修 4K 下 TX 完全不出帧 —— 但【只动门限, 绝不动 DEPTH】★★
    //
    //   4K 一行 = I_h_active>>1 = 3840>>1 = 1920 word, 而 line_ready 要求
    //   b_rd_data_count >= 1920。原门限写死 1900 < 1920 ⇒ a_rd_en 在占用 >1900 时
    //   就被掐断 ⇒ 占用永远到不了 1920 ⇒ line_ready 永远为假 ⇒ line_priming 不触发
    //   ⇒ m_tvalid 恒 0 ⇒ csi2_frame_tx 收不到一个 word ⇒ CIF 一帧都抓不到。
    //
    //   修法: 门限再与"一行 + 64"取与, 即实际门限 = max(1900, 一行+64)。
    //     1080p: WORDS_PAYLOAD=960, 960+64=1024 < 1900 ⇒ 该项恒真
    //            ⇒ 逻辑上等价于原来的 count > 1900, 1080p 行为逐位不变(相位不动) ✓
    //     4K   : WORDS_PAYLOAD=1920, 1920+64=1984 > 1900 ⇒ 实际门限 1984
    //            ⇒ FIFO 可以涨到 1984, line_ready(>=1920) 可达 ✓ (深度 2048 够用)
    //
    //   ⚠⚠ 千万不要用"加深 FIFO (ADDR_WIDTH/DEPTH)"的办法 —— 那会改变 FIFO 稳态
    //       填充相位, 进而打乱 ui_dbuf 里 XDIV=2 的"一行分左右两半、各一次突发"
    //       的顺序, 画面会变成【左右半边对调】(已实测踩过这个坑, 见 V28 回退)。
    wire        b_near_full = (b_wr_data_count > 12'd1900) &&
                              (b_wr_data_count > (WORDS_PAYLOAD[11:0] + 12'd64));
    wire        a_can_read  = enable & ~a_empty & ~b_near_full;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) a_rd_en <= 1'b0;
        else            a_rd_en <= a_can_read;
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH(33),
        .ADDR_WIDTH(12)     // V42: depth 4096
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

   
    // ★ V43: a_rd_en 只是【读请求】(寄存在 dst_clk), 真正是否读到要看 FIFO 内部的
    //   do_read = rd_en & ~empty。原代码把 a_rd_en 直接当“少了一拍的有效”用,
    //   在 FIFO 已经抽空的那一拍会凭空多出一个 word(内容是 dout 旧值) —— 4K 下
    //   A-FIFO 会真的被抽空(1080p 不会), 于是每行尾部多 1~2 个重复 word。
    //   这里用 `a_rd_en & ~a_empty` 精确对齐 FIFO 的 do_read。
    reg        a_rd_en_d1;      // 1-cycle-later rd_en, aligned to a_dout
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) a_rd_en_d1 <= 1'b0;
        else            a_rd_en_d1 <= a_rd_en & ~a_empty;
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
    wire [11:0] b_rd_data_count;    // 保留端口(不再用于门限)

    wire        b_wr_en = yuv_admit & ~b_full;

    //==========================================================================
    // V43 (2026-10-18): 修【4K 每行多 2 个 word -> 斜向撕裂】
    //
    //  现象(板上实测): 4K 静态帧相邻行相位相关恒为 +2 像素(3840 幅宽),
    //                  2000 行 std=0; 用 k=+2 px/row 做软件反变换后画面完全正常。
    //                  即每行数据多/少 1 个 32bit word, 2160 行累计 4320 像素
    //                  > 一帧宽, 于是画面出现斜坡重复("扇型"/撕裂)。
    //
    //  iverilog 复现: 输出侧每行 1922 个 word, 行尾是 ...1918,1919,1919,1919。
    //  两个成因(都在本模块):
    //    (1) 写侧: a_rd_en 是【读请求】, 但 pipe_in_valid 直接拿它当"读到数据",
    //        FIFO 已空那一拍没有真读, 仍然算进一个 word(dout 旧值)。
    //        -> 已改为 a_rd_en_d1 <= a_rd_en & ~a_empty, 与 FIFO 内部 do_read 对齐。
    //    (2) 读侧: 旧实现 `m_tvalid = line_active`, 与 FIFO 里是否真有数据无关;
    //        4K 一行 1920 word 卸完刚好把 B-FIFO 抽空, drain_done 多挂一拍,
    //        再加 prime 读在空 FIFO 上不生效, 就把最后一个 word 又送 1~2 次。
    //        -> 已改为【4 深输出小队列】: m_tvalid 只在队列里真有 word 时有效。
    //
    //  为什么只有 4K 犯: 1080p 一行 960 word, B-FIFO 常驻近 1900 word, 抽不空;
    //  4K 一行 1920 word 与门限 1984 几乎相等, 每行都会短暂抽空 -> V42 单纯加深
    //  FIFO 无效(门限没变, 仍然抽空)。
    //==========================================================================
    // ★ b FIFO 的 empty 标志经过 2 拍指针同步, 实际空了之后还会晚 2 拍才置位,
    //   直接用它判空会多弹 1~2 个旧数据(实测就是这么每行多 1 word)。
    //   b FIFO 的读写都在 dst_clk, 所以自己维护一个【精确占用计数】。
    reg  [12:0] b_occ;

    // 输出小队列: FIFO 的 dout 比 rd_en 晚 1 拍, 用 4 深队列把这一拍消化掉,
    // 稳态可达 1 word/cycle (4K 需要 1920word / 2123byte_clk ≈ 0.9),
    // 又因为入队/出队都是真实寄存器, 绝不会把旧数据重复送出。
    reg  [33:0] qmem [0:3];
    reg  [1:0]  q_wp, q_rp;
    reg  [2:0]  q_cnt;          // 队列中真实 word 数 (0..4)
    reg         rd_inflight;    // 上一拍发了读, 本拍 b_dout 有效

    wire q_wr = rd_inflight;
    wire q_rd = (q_cnt != 3'd0) & m_tready;
    // ~b_empty 必须一起看: FIFO 的写指针对称化滞后 2 拍, 刚写入的 word 可能还
    // 没“看得到”, 那一拍 rd_en 会被 FIFO 忽略; 若仅按 b_occ 记账就会与真实
    // 读操作失配(启动时凭空多出 1~2 个旧 word)。
    //==========================================================================
    // ★★ V50d (2026-10-28): 恢复【整行预取】门控 —— V43 把它弄丢了 ★★
    //
    //  现场: TPG 直灌 csi2_frame_tx 时链路完全干净 (fps=50.4, CRC=0, PageFault=0);
    //        一改走本 packer 就 1.6fps + MIPI_CSI2 CRC 满屏。
    //
    //  根因: csi2_frame_tx 在 payload 期间【只要 s_tvalid 掉一拍就把 hs_en 拉低】,
    //        那等于把这个 packet 提前截断 -> 必然 CRC/ECC 错。
    //        V43 把 `m_tvalid = line_active`(带 line_priming) 换成 4 深队列时,
    //        把预取门控一起删掉了, 变成 `m_tvalid = (q_cnt != 0)` —— 队列里只要
    //        有 1 个 word 就拉高。
    //        但 TX 发一行只要 7.68us (960word@125MHz), 而 VTC 源一行是 ~18.5us,
    //        TX 比源快 2.4 倍 => 一发包就必然在中途饿死 => 每行都被截断。
    //
    //  修法: 一行开头发包前先攒满整行; 一旦开始就一直放行到本行最后一个 word。
    //        4 深队列保留不动 (它解决的是"FIFO 晚 1 拍 dout"和 4K 重复 word,
    //        那是另一个真 bug, 不能退回去)。
    //==========================================================================
    reg         line_go;        // 1 = 本行已开始发送 (不再允许中途停)
    wire        line_ready = (b_occ >= WORDS_PAYLOAD[12:0]);   // 整行已到齐
    wire        line_end   = q_rd & m_tlast;                    // 本行最后一个 word 被取走

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n)      line_go <= 1'b0;
        else if (line_ready) line_go <= 1'b1;     // 整行到齐才允许起发
        else if (line_end)   line_go <= 1'b0;     // 行尾收工, 下一行重新攒
    end

    wire do_pop = line_go && (b_occ != 13'd0) && ~b_empty &&
                  ((q_cnt + {2'd0, rd_inflight}) < 3'd4);

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            q_wp <= 2'd0;
            q_rp <= 2'd0;
            q_cnt <= 3'd0;
            rd_inflight <= 1'b0;
            b_occ <= 13'd0;
        end else begin
            rd_inflight <= do_pop;
            b_occ <= b_occ + (b_wr_en ? 13'd1 : 13'd0) - (do_pop ? 13'd1 : 13'd0);
            if (q_wr) begin
                qmem[q_wp] <= b_dout;
                q_wp <= q_wp + 2'd1;
            end
            if (q_rd) begin
                q_rp <= q_rp + 2'd1;
            end
            q_cnt <= q_cnt + (q_wr ? 3'd1 : 3'd0) - (q_rd ? 3'd1 : 3'd0);
        end
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH(34),
        .ADDR_WIDTH(12)     // V42: depth 4096, 4K 一行 1920 留出足够余量
    ) u_out_fifo (
        .rst          (~dst_rst_n),
        .wr_clk       (dst_clk   ),
        .rd_clk       (dst_clk   ),
        .din          ({yuv_sof, yuv_last, yuv_data}),
        .wr_en        (b_wr_en   ),
        .rd_en        (do_pop    ),
        .dout         (b_dout    ),
        .full         (b_full    ),
        .empty        (b_empty   ),
        .rd_data_count(b_rd_data_count),
        .wr_data_count(b_wr_data_count),
        .wr_rst_busy  (          ),
        .rd_rst_busy  (          )
    );

    // m_tvalid 只在队列里确实有真实 word 时才拉高 —— 绝不会重复也不会丢
    assign m_tvalid    = (q_cnt != 3'd0);
    assign m_tdata     = qmem[q_rp][31:0];
    assign m_tlast     = qmem[q_rp][32];
    assign m_tuser_sof = qmem[q_rp][33];

endmodule
