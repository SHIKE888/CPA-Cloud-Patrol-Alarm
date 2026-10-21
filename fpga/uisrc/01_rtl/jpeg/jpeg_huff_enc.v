/*===========================================================================
 * Filename     : jpeg_huff_enc.v
 * Description  : baseline JPEG 熵编码 (DC 差分 + AC 游程 + 霍夫曼)
 *
 *  参考实现 (jpeg_ref.py code_block):
 *      DC:  diff = zz[0] - pred[comp];  pred[comp] = zz[0]
 *           s = magnitude_category(diff);  put(DC_huff[s]);  put(amp_bits(diff,s), s)
 *      AC:  k=1..63 累加 run; 遇非零:
 *             每 16 个零先吐一个 ZRL(0xF0)
 *             sym = (run<<4)|s;  put(AC_huff[sym]);  put(amp_bits(v,s), s)
 *           结束若 run>0 吐 EOB(0x00)
 *      amp_bits(v,s) = v >= 0 ? v : v + 2^s - 1      (负数用 ones' complement)
 *
 *  ★ 吞吐: 每个符号【一拍】输出, 码字与附加位在这里合并成一个 32 位 code。
 *    若分两次 put (码字一拍、附加位一拍), 1080p 每 MCU 约 150 符号 ->
 *    300 拍, 60fps 的 152 拍预算根本不够。合并后 1 拍/符号。
 *
 *  ★ DC 预测器: 每个分量独立 (Y / Cb / Cr 各一个), 与 jpeg_ref.py 的
 *    pred = {0:0, 1:0, 2:0} 一致。帧首必须清 (i_rst_pred)。
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_huff_enc (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_blk_start,     // 脉冲: 开始编码一个块
    input  wire [1:0]  i_comp,          // 0=Y 1=Cb 2=Cr (选 DC 预测器)
    input  wire        i_chroma_tbl,    // 1 = 用色度霍夫曼表

    output wire [5:0]  o_rd_idx,        // 送 jpeg_quant_zz 的 zigzag 读地址
    input  wire [15:0] i_rd_data,       // 量化系数 (zigzag 序)

    output reg         o_valid,         // 一拍一个符号
    output reg  [31:0] o_code,
    output reg  [5:0]  o_len,
    input  wire        i_ready,         // 下游位打包器能接收 (放不下时会拉低)

    output reg         o_blk_done,      // 块结束脉冲

    input  wire        i_rst_pred       // 帧首 / 域切换: 清所有预测器
);

    `undef JPEG_DEFS_VH
    `include "jpeg_defs.vh"

    //=============================================================== 状态
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_DC   = 3'd1;
    localparam [2:0] S_AC   = 3'd2;
    localparam [2:0] S_END  = 3'd3;
    localparam [2:0] S_DONE = 3'd4;

    reg [2:0] state;
    reg [5:0] kk;
    reg [5:0] run;

    //=============================================================== DC 预测器
    reg signed [15:0] pred_y, pred_cb, pred_cr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pred_y  <= 16'sd0;
            pred_cb <= 16'sd0;
            pred_cr <= 16'sd0;
        end else if (i_rst_pred) begin
            pred_y  <= 16'sd0;
            pred_cb <= 16'sd0;
            pred_cr <= 16'sd0;
        end else if (state == S_DC) begin
            case (i_comp)
            2'd0:    pred_y  <= $signed(i_rd_data);
            2'd1:    pred_cb <= $signed(i_rd_data);
            default: pred_cr <= $signed(i_rd_data);
            endcase
        end
    end

    reg signed [15:0] pred_cur;
    always @(*) begin
        case (i_comp)
        2'd0:    pred_cur = pred_y;
        2'd1:    pred_cur = pred_cb;
        default: pred_cur = pred_cr;
        endcase
    end

    assign o_rd_idx = (state == S_DC) ? 6'd0 : kk;

    //=============================================================== DC 组合计算
    wire signed [15:0] dc_v    = $signed(i_rd_data);
    wire signed [15:0] dc_diff = dc_v - pred_cur;
    wire        [15:0] dc_mag  = dc_diff[15] ? (-dc_diff) : dc_diff;
    wire        [3:0]  dc_s    = jpeg_ssss(dc_mag);
    wire        [20:0] dc_tab  = i_chroma_tbl ? jpeg_huff_dc_chr(dc_s)
                                              : jpeg_huff_dc_lum(dc_s);
    wire signed [15:0] dc_amp  = (dc_diff >= 0) ? dc_diff
                                               : (dc_diff + (16'sd1 << dc_s) - 16'sd1);
    wire        [15:0] dc_mask = (16'd1 << dc_s) - 16'd1;
    wire        [31:0] dc_code = ({16'd0, dc_tab[15:0]} << dc_s)
                               | {16'd0, dc_amp & $signed(dc_mask)};
    wire        [5:0]  dc_len  = dc_tab[20:16] + {2'd0, dc_s};

    //=============================================================== AC 组合计算
    wire signed [15:0] ac_v   = $signed(i_rd_data);
    wire        [15:0] ac_mag = ac_v[15] ? (-ac_v) : ac_v;
    wire        [3:0]  ac_s   = jpeg_ssss(ac_mag);
    wire        [7:0]  ac_sym = {run[3:0], ac_s};

    wire        [20:0] ac_tab = i_chroma_tbl ? jpeg_huff_ac_chr(ac_sym)
                                             : jpeg_huff_ac_lum(ac_sym);
    wire signed [15:0] ac_amp = (ac_v >= 0) ? ac_v
                                            : (ac_v + (16'sd1 << ac_s) - 16'sd1);
    wire        [15:0] ac_mask = (16'd1 << ac_s) - 16'd1;
    wire        [31:0] ac_code = ({16'd0, ac_tab[15:0]} << ac_s)
                               | {16'd0, ac_amp & $signed(ac_mask)};
    wire        [5:0]  ac_len  = ac_tab[20:16] + {2'd0, ac_s};

    // ZRL: 0xF0
    wire        [20:0] zrl_tab = i_chroma_tbl ? jpeg_huff_ac_chr(8'hF0)
                                              : jpeg_huff_ac_lum(8'hF0);
    // EOB: 0x00
    wire        [20:0] eob_tab = i_chroma_tbl ? jpeg_huff_ac_chr(8'h00)
                                              : jpeg_huff_ac_lum(8'h00);

    //=============================================================== 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            kk         <= 6'd1;
            run        <= 6'd0;
            o_valid    <= 1'b0;
            o_code     <= 32'd0;
            o_len      <= 6'd0;
            o_blk_done <= 1'b0;
        end else begin
            o_valid    <= 1'b0;
            o_blk_done <= 1'b0;

            case (state)
            S_IDLE: begin
                kk  <= 6'd1;
                run <= 6'd0;
                if (i_blk_start) state <= S_DC;
            end

            //--------------------------------------------- DC: 1 拍
            S_DC: begin
                if (i_ready) begin
                    o_valid <= 1'b1;
                    o_code  <= dc_code;
                    o_len   <= dc_len;
                    kk      <= 6'd1;
                    run     <= 6'd0;
                    state   <= S_AC;
                end
            end

            //--------------------------------------------- AC: 1 拍/符号
            // !i_ready 时保持 state/kk/run 不变, 下一拍重试同一个符号
            S_AC: begin
                if (ac_v == 16'sd0) begin
                    run <= run + 6'd1;
                    kk  <= kk + 6'd1;
                    if (kk == 6'd63) state <= S_END;
                end else if (run > 6'd15) begin
                    // 连续 16 个零 -> ZRL, run 减 16, k 不变
                    if (i_ready) begin
                        o_valid <= 1'b1;
                        o_code  <= {16'd0, zrl_tab[15:0]};
                        o_len   <= {2'd0, zrl_tab[20:16]};
                        run     <= run - 6'd16;
                    end
                end else begin
                    if (i_ready) begin
                        o_valid <= 1'b1;
                        o_code  <= ac_code;
                        o_len   <= ac_len;
                        run     <= 6'd0;
                        kk      <= kk + 6'd1;
                        if (kk == 6'd63) state <= S_END;
                    end
                end
            end

            //--------------------------------------------- 末尾 EOB
            S_END: begin
                if (run != 6'd0) begin
                    if (i_ready) begin
                        o_valid <= 1'b1;
                        o_code  <= {16'd0, eob_tab[15:0]};
                        o_len   <= {2'd0, eob_tab[20:16]};
                        run     <= 6'd0;
                        state   <= S_DONE;
                    end
                end else begin
                    state <= S_DONE;
                end
            end

            S_DONE: begin
                o_blk_done <= 1'b1;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
