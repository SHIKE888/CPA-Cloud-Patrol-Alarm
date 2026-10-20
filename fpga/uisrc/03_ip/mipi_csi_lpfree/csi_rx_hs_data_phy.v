`timescale 1 ps / 1 ps

///  DEVICE: "EF2","EF3","SF1","EG","PH1","PH1A","PH2"
module csi_rx_hs_data_phy #(
    parameter DEVICE = "PH2"
)(
    input  wire               I_rxclk,
    input  wire               I_rxclk_div_x2,
    input  wire               I_rxclk_div_x4,
    input  wire               I_reset_n,
    input  wire               I_hs_data_p,
    input  wire [5:0]         I_delay_value,
    input  wire 	          I_delay_vaild,
    output wire [7:0]         O_rx_data,   
    output wire 		      O_delay_data_val 
	);

    wire        w_hs_data_dalay;
    wire        w_delay_data_val;

   assign     O_delay_data_val = w_delay_data_val;

// ==========================================================
// PH1A (HR bank): PH1_LOGIC_DYNAMIC_IDELAY + PH1_LOGIC_IDDRx2
// HR bank does not support HP_ISERDES or HP_IDELAY
// ==========================================================
generate if (DEVICE == "PH1A") begin : gen_ph1a

    wire [3:0] w_rx_data_iddr;
    reg  [3:0] r_rx_data_iddr;
    reg  [7:0] r_rx_data_byte;

    PH1_LOGIC_DYNAMIC_IDELAY #(
      .WIDTH ( 5 )
    ) u_idelay (
      .i        ( I_hs_data_p           ),
      .indly_en ( I_delay_vaild         ),
      .in_dly   ( I_delay_value[4:0]    ),
      .o        ( w_hs_data_dalay       )
    );

    PH1_LOGIC_IDDRx2 #(
      .ASYNCRST ( "ENABLE" )
    ) u_iddrx2 (
      .q3   ( w_rx_data_iddr[3] ),
      .q2   ( w_rx_data_iddr[2] ),
      .q1   ( w_rx_data_iddr[1] ),
      .q0   ( w_rx_data_iddr[0] ),
      .pclk ( I_rxclk_div_x2   ),
      .sclk ( I_rxclk_div_x4   ),
      .d    ( w_hs_data_dalay   ),
      .rst  ( ~I_reset_n        )   // active HIGH reset
    );

    // Combine two 4-bit nibbles into 8-bit byte at byte clock
    always @(posedge I_rxclk_div_x2)
        r_rx_data_iddr <= w_rx_data_iddr;

    always @(posedge I_rxclk)
        r_rx_data_byte <= {w_rx_data_iddr, r_rx_data_iddr};

    assign O_rx_data       = r_rx_data_byte;
    assign w_delay_data_val = 1'b1;

end
// ==========================================================
// PH2 (default): PH2_LOGIC_HP_ISERDES with built-in delay
// ==========================================================
else begin : gen_ph2

    PH2_LOGIC_HP_ISERDES #(
      .MODE         ( "DDR18"    ),
      .DLY_MODE     ( "ENABLE"  )
    ) u_PH2_LOGIC_HP_ISERDES (
      .pclk         ( I_rxclk           ),
      .sclk         ( I_rxclk_div_x4    ),
      .rst_n        ( I_reset_n         ),
      .idata        ( I_hs_data_p       ),
      .odata_vld    ( w_delay_data_val  ),
      .odata        ( O_rx_data         ),
      .dl_en_n      ( ~I_delay_vaild    ),
      .dl_type      ( 2'b10             ),
      .dl_code      ( I_delay_value     )
    );

end endgenerate

endmodule
