//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock.
//   cen_16m : 96 / 6    68EC020 (32 MHz / 2)
//   cen_8m  : 96 / 12   Z80, and the pixel clock
//   cen_pix : 96 / 12   8 MHz pixel clock (a guess: 24 MHz video crystal / 3 gives
//                        512 clocks per 64 us line, the 512-wide raster MAME declares)
//   cen_48k : 96 / 2000 K054539 sample rate (18.432 MHz / 384)
// The DSP56156 is paced by its own token bucket from cen_dsp (96 / 2.4 is not an
// integer: cen_dsp is 40 pulses every 96 clocks, spread by a fractional accumulator).
//------------------------------------------------------------------------------
`default_nettype none

module pn_clk (
    input  logic clk,
    input  logic reset,
    output logic cen_16m,
    output logic cen_8m,
    output logic cen_pix,
    output logic cen_48k,
    output logic cen_dsp            // 40 MHz average
);
    logic [3:0]  div;
    logic [10:0] sdiv;
    logic [7:0]  dacc;              // 0..95; 8 bits so that dacc + 40 (up to 135) does not wrap
    always_ff @(posedge clk) begin
        if (reset) begin
            div <= '0; sdiv <= '0; dacc <= '0;
            cen_16m <= 1'b0; cen_8m <= 1'b0; cen_pix <= 1'b0; cen_48k <= 1'b0; cen_dsp <= 1'b0;
        end else begin
            sdiv    <= (sdiv == 11'd1999) ? 11'd0 : sdiv + 11'd1;
            cen_48k <= (sdiv == 11'd1999);
            div     <= (div == 4'd11) ? 4'd0 : div + 4'd1;
            cen_16m <= (div == 4'd11) || (div == 4'd5);
            cen_8m  <= (div == 4'd11);
            cen_pix <= (div == 4'd5);
            // 40/96: add 40, emit when crossing 96 (5 pulses every 12 clocks). dacc needs 8 bits: with 7,
            // dacc + 40 would wrap at 128 and give 2 pulses every 8 clocks, a 24 MHz DSP.
            if (dacc + 8'd40 >= 8'd96) begin dacc <= dacc + 8'd40 - 8'd96; cen_dsp <= 1'b1; end
            else begin dacc <= dacc + 8'd40; cen_dsp <= 1'b0; end
        end
    end
endmodule
