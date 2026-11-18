//------------------------------------------------------------------------------
// Diagnostic overlay (METHODOLOGY section 4): when enabled, the bottom 24
// visible lines show six rows of 32 squares (9 px wide, the last a gap, so
// all 32 fit the 288-px line; 4 px tall). Bit set = green, clear = dark grey, so a hang can
// be read off the panel without a debugger. The rows' meaning is the
// platform's (Polygonet.sv); the bottom three are the original 12-line overlay.
//------------------------------------------------------------------------------
`default_nettype none

module dbg_overlay #(
    parameter int SQW = 9              // pixels a square, the last of them the gap (32 x SQW = the line)
) (
    input  logic        clk,
    input  logic        cen_pix,
    input  logic        enable,
    input  logic        de, vsync,
    input  logic [7:0]  r_in, g_in, b_in,
    input  logic [191:0] status,       // [191:160] the top row ... [31:0] the bottom row (bit 31 leftmost)
    output logic [7:0]  r_out, g_out, b_out
);
    logic [3:0] sq;                   // pixel within the square, 0..SQW-1
    logic [5:0] col;                  // square within the line
    logic [8:0] y;
    logic       de_d, vs_d;
    logic [8:0] height;               // visible lines counted in the previous frame

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            de_d <= de; vs_d <= vsync;
            if (vsync && !vs_d) begin height <= y; y <= 9'd0; end
            else if (de && !de_d) begin sq <= 4'd0; col <= 6'd0; end
            else if (de) begin
                if (sq == 4'(SQW - 1)) begin sq <= 4'd0; col <= col + 6'd1; end else sq <= sq + 4'd1;
            end
            if (!de && de_d) y <= y + 9'd1;            // end of a visible line
        end
    end

    // per-line terms, registered (y only changes in blanking, many clocks before they are used)
    logic [8:0]  y_from_bottom;                          // 1 = last visible line
    logic        band_y, gap_y;
    logic [31:0] word;
    always_ff @(posedge clk) begin
        y_from_bottom <= height - y;
        band_y <= (y_from_bottom <= 9'd24) && (y_from_bottom >= 9'd1);
        gap_y  <= (y_from_bottom[1:0] == 2'd0);                 // the top line of each 4-line row
        // row r (0 = bottom) covers lines 4r+1 .. 4r+4 from the bottom
        case (3'((y_from_bottom - 9'd1) >> 2))
            3'd0:    word <= status[31:0];
            3'd1:    word <= status[63:32];
            3'd2:    word <= status[95:64];
            3'd3:    word <= status[127:96];
            3'd4:    word <= status[159:128];
            3'd5:    word <= status[191:160];
            default: word <= '0;
        endcase
    end
    wire        in_band = enable && de && band_y;
    wire        bitv = word[5'd31 - col[4:0]];
    wire        gap  = (sq == 4'(SQW - 1)) || gap_y;

    always_comb begin
        if (in_band && col < 6'd32) begin
            if (gap)      {r_out, g_out, b_out} = 24'h000000;
            else if (bitv){r_out, g_out, b_out} = 24'h20e020;
            else          {r_out, g_out, b_out} = 24'h303030;
        end else begin
            {r_out, g_out, b_out} = {r_in, g_in, b_in};
        end
    end
endmodule
