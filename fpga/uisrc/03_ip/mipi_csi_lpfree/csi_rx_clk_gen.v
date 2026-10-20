
module csi_rx_clk_gen #(
    parameter DEVICE = "EG"   ///"EF2","EF3","SF1","EG","PH1","PH1A","PH2"
    )(
    input wire   I_mipi_clk_p,
    input wire   I_rst,

    output wire  O_clk,
    output wire  O_clk_x2,
    output wire  O_clk_x4
);
    

	generate
        if(DEVICE == "SF1")
            begin
                dphy_rx_pll_sf1 u_dphy_rx_pll(
                    .refclk   ( I_mipi_clk_p ),
                    .reset    ( I_rst        ),

                    .extlock  (   ),

                    .clk0_out ( O_clk_x4     ),
                    .clk1_out ( O_clk_x2     ),
                    .clk2_out ( O_clk        )
                );
            end
        else if(DEVICE == "EF2")
            begin
                EF2_LOGIC_BUFIO #(
                    .DIV( 2 )
                )U_io_clk_div_0( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst	    ),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( O_clk_x4     ),
                    .clkdivx ( O_clk_x2     )
                );

                EF2_LOGIC_BUFIO #(
                    .DIV( 4 )
                )U_io_clk_div_1( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst		),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( ),
                    .clkdivx ( O_clk        )
                );
            end
        else if(DEVICE == "EF3")
            begin
                EF3_LOGIC_BUFIO #(
                    .DIV( 2 )
                )U_io_clk_div_0( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst	    ),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( O_clk_x4     ),
                    .clkdivx ( O_clk_x2     )
                );

                EF3_LOGIC_BUFIO #(
                    .DIV( 4 )
                )U_io_clk_div_1( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst		),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( ),
                    .clkdivx ( O_clk        )
                );
            end
        else if(DEVICE == "EF4")
            begin
                EF4_LOGIC_BUFIO #(
                    .DIV( 2 )
                )U_io_clk_div_0( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst	    ),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( O_clk_x4     ),
                    .clkdivx ( O_clk_x2     )
                );

                EF4_LOGIC_BUFIO #(
                    .DIV( 4 )
                )U_io_clk_div_1( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst		),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( ),
                    .clkdivx ( O_clk        )
                );
            end
        else if(DEVICE == "EG")
            begin
                EG_LOGIC_BUFIO #(
                    .DIV( 2 )
                )U_io_clk_div_0( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst	    ),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( O_clk_x4     ),
                    .clkdivx ( O_clk_x2     )
                );

                EG_LOGIC_BUFIO #(
                    .DIV( 4 )
                )U_io_clk_div_1( 
                    .clki	 ( I_mipi_clk_p ),
                    .rst	 ( I_rst		),
                    .coe	 ( 1'b1		    ),
                    .clko	 ( ),       
                    .clkdiv1 ( ),
                    .clkdivx ( O_clk        )
                );
            end
        else if(DEVICE == "PH1")
            begin
                PH1_PHY_LCLK#(
                    . CEMD   ( "SYNC"   ),
                    . CLKSEL ( "ORG"    ),
                    . DIV    ( 2        ),
                    . LCLK   ( "BYPASS" )
                )U_io_clk_div_0 (
                    .clkin     ( I_mipi_clk_p ),
                    .rst       ( I_rst        ),
                    .ce        ( 1'b1         ),
                    .clkout    ( O_clk_x4     ),
                    .clkdivout ( O_clk_x2     )
                );

                PH1_PHY_LCLK#(
                    . CEMD   ( "SYNC"   ),
                    . CLKSEL ( "ORG"    ),
                    . DIV    ( 4        ),
                    . LCLK   ( "BYPASS" )
                )U_io_clk_div_1 (
                    .clkin     ( I_mipi_clk_p ),
                    .rst       ( I_rst        ),
                    .ce        ( 1'b1         ),
                    .clkout    (              ),
                    .clkdivout ( O_clk        )
                );
            end
        else if(DEVICE == "PH1A")
            begin
                PH1_PHY_LCLK_V2#(
                    . CEMD   ( "SYNC"   ),
                    . CLKSEL ( "ORG"    ),
                    . DIV    ( "2"      ),
                    . LCLK   ( "BYPASS" )
                )U_io_clk_div_0 (
                    .clkin     ( I_mipi_clk_p ),
                    .rst       ( I_rst        ),
                    .ce        ( 1'b1         ),
                    .clkout    ( O_clk_x4     ),
                    .clkdivout ( O_clk_x2     )
                );

                PH1_PHY_LCLK_V2#(
                    . CEMD   ( "SYNC"   ),
                    . CLKSEL ( "ORG"    ),
                    . DIV    ( "4"      ),
                    . LCLK   ( "BYPASS" )
                )U_io_clk_div_1 (
                    .clkin     ( I_mipi_clk_p ),
                    .rst       ( I_rst        ),
                    .ce        ( 1'b1         ),
                    .clkout    (              ),
                    .clkdivout ( O_clk        )
                );
            end
        else if(DEVICE == "PH2")
            begin

            PH2_LOGIC_BUFG_CE_DIV #(
              .DIV          ( 1          ), //  1, 2, 3, 4, 5, 6, 7, 8.  Clock buffer frequency division number.  
              .CLKINV       ( "SIG"      ), //  "SIG", "INV".  Polarity inversion for clkin.  
              .CEINV        ( "SIG"      ), //  "SIG", "INV".  Polarity inversion for ce.  
              .RST_MODE     ( "SYNC"     ), //  "SYNC", "ASYNC".  Optional mode for rst.  
              .CLKOUT_MODE  ( "CLKDIV1"  )  //  "BYPASS", "DIV2TO8", "CLKDIV1".  Optional mode for clock buffer output.  
            )u_PH2_LOGIC_BUFG_CE_DIV0(
              .ce           ( 1'b1         ), //  1-Bit input. Clock buffer enable, default active high. 
              .rst          ( I_rst        ), //  1-Bit input. Clock buffer reset, default active high. 
              .clkin        ( I_mipi_clk_p      ), //  1-Bit input. Clock buffer input.            
              .clkout       ( O_clk_x4     )  //  1-Bit output. Clock buffer output.           
            );

            PH2_LOGIC_BUFG_CE_DIV #(
              .DIV          ( 2          ), //  1, 2, 3, 4, 5, 6, 7, 8.  Clock buffer frequency division number.  
              .CLKINV       ( "SIG"      ), //  "SIG", "INV".  Polarity inversion for clkin.  
              .CEINV        ( "SIG"      ), //  "SIG", "INV".  Polarity inversion for ce.  
              .RST_MODE     ( "SYNC"     ), //  "SYNC", "ASYNC".  Optional mode for rst.  
              .CLKOUT_MODE  ( "DIV2TO8"  )  //  "BYPASS", "DIV2TO8", "CLKDIV1".  Optional mode for clock buffer output.  
            )u_PH2_LOGIC_BUFG_CE_DIV1(
              .ce           ( 1'b1         ), //  1-Bit input. Clock buffer enable, default active high. 
              .rst          ( I_rst        ), //  1-Bit input. Clock buffer reset, default active high. 
              .clkin        ( I_mipi_clk_p      ), //  1-Bit input. Clock buffer input.            
              .clkout       ( O_clk_x2     )  //  1-Bit output. Clock buffer output.           
            );

            PH2_LOGIC_BUFG_CE_DIV #(
              .DIV          ( 4          ), //  1, 2, 3, 4, 5, 6, 7, 8.  Clock buffer frequency division number.  
              .CLKINV       ( "SIG"      ), //  "SIG", "INV".  Polarity inversion for clkin.  
              .CEINV        ( "SIG"      ), //  "SIG", "INV".  Polarity inversion for ce.  
              .RST_MODE     ( "SYNC"     ), //  "SYNC", "ASYNC".  Optional mode for rst.  
              .CLKOUT_MODE  ( "DIV2TO8"  )  //  "BYPASS", "DIV2TO8", "CLKDIV1".  Optional mode for clock buffer output.  
            )u_PH2_LOGIC_BUFG_CE_DIV2(
              .ce           ( 1'b1         ), //  1-Bit input. Clock buffer enable, default active high. 
              .rst          ( I_rst        ), //  1-Bit input. Clock buffer reset, default active high. 
              .clkin        ( I_mipi_clk_p      ), //  1-Bit input. Clock buffer input.            
              .clkout       ( O_clk     )  //  1-Bit output. Clock buffer output.           
            );

		end
        else if(DEVICE == "DR1")
            begin
                DR1_PHY_LCLK#(
                    . CEMD   ( "SYNC"   ),
                    . CLKSEL ( "ORG"    ),
                    . DIV    ( 2        ),
                    . LCLK   ( "BYPASS" )
                )U_io_clk_div_0 (
                    .clkin     ( I_mipi_clk_p ),
                    .rst       ( I_rst        ),
                    .ce        ( 1'b1         ),
                    .clkout    ( O_clk_x4     ),
                    .clkdivout ( O_clk_x2     )
                );

                DR1_PHY_LCLK#(
                    . CEMD   ( "SYNC"   ),
                    . CLKSEL ( "ORG"    ),
                    . DIV    ( 4        ),
                    . LCLK   ( "BYPASS" )
                )U_io_clk_div_1 (
                    .clkin     ( I_mipi_clk_p ),
                    .rst       ( I_rst        ),
                    .ce        ( 1'b1         ),
                    .clkout    (              ),
                    .clkdivout ( O_clk        )
                );
            end
    endgenerate

endmodule