`timescale 1ns / 1ps
// pmod_ad1_spi: reads the Digilent Pmod AD1 (2x AD7476A, 12-bit, up to 1 MSPS).
//
// One conversion per 'start' pulse. Both ADCs share CS and SCLK, so the two
// channels are sampled at the same instant (CS falling edge).
//
// Each ADC shifts out 16 bits: 4 leading zeros then data[11:0], MSB first.
// The first bit appears when CS falls and each SCLK falling edge shifts out
// the next one, so we capture DOUT at the moment we drive SCLK low
// (the bit has been stable for a full SCLK period by then).
// SCLK idles high. SCLK frequency = clk / (2*HALF), must be <= 20 MHz.

module pmod_ad1_spi #(
    parameter integer HALF = 4            // 100 MHz / (2*4) = 12.5 MHz SCLK
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,             // 1-cycle pulse: start a conversion
    input  wire        d0,                // DOUT of ADC 0
    input  wire        d1,                // DOUT of ADC 1
    output reg         cs,
    output reg         sclk,
    output reg  [11:0] data0,
    output reg  [11:0] data1,
    output reg         done,              // 1-cycle pulse when data0/data1 are new
    output wire        busy
);

    reg        active;
    reg [7:0]  divcnt;
    reg [4:0]  bitcnt;
    reg [15:0] sh0, sh1;

    assign busy = active;

    always @(posedge clk) begin
        if (!rstn) begin
            cs     <= 1'b1;
            sclk   <= 1'b1;
            active <= 1'b0;
            done   <= 1'b0;
            divcnt <= 8'd0;
            bitcnt <= 5'd0;
            sh0    <= 16'd0;
            sh1    <= 16'd0;
            data0  <= 12'd0;
            data1  <= 12'd0;
        end else begin
            done <= 1'b0;
            if (!active) begin
                if (start) begin
                    active <= 1'b1;
                    cs     <= 1'b0;             // starts the conversion
                    divcnt <= 8'd0;
                    bitcnt <= 5'd0;
                end
            end else if (divcnt == HALF - 1) begin
                divcnt <= 8'd0;
                if (sclk) begin
                    sclk <= 1'b0;               // capture current bit, ADC shifts next
                    sh0  <= {sh0[14:0], d0};
                    sh1  <= {sh1[14:0], d1};
                end else begin
                    sclk <= 1'b1;
                    if (bitcnt == 5'd15) begin  // all 16 bits captured
                        active <= 1'b0;
                        cs     <= 1'b1;
                        done   <= 1'b1;
                        data0  <= sh0[11:0];
                        data1  <= sh1[11:0];
                    end else begin
                        bitcnt <= bitcnt + 5'd1;
                    end
                end
            end else begin
                divcnt <= divcnt + 8'd1;
            end
        end
    end

endmodule
