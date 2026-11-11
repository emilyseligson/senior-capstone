`timescale 1ns / 1ps
// pmod_da2_spi: drives the Digilent Pmod DA2 (2x DAC121S101).
//
// One write per 'start' pulse. Both DACs are written at the same time
// (shared SYNC and SCLK, separate DINA / DINB lines).
//
// Frame (16 bits, MSB first): {2'b00 don't care, 2'b00 normal mode, data[11:0]}
// The DAC samples DIN on SCLK falling edges, so DIN changes on rising edges.
// SCLK idles high. SCLK frequency = clk / (2*HALF).

module pmod_da2_spi #(
    parameter integer HALF = 4            // 100 MHz / (2*4) = 12.5 MHz SCLK
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,             // 1-cycle pulse: latch data and send
    input  wire [11:0] data_a,            // offset binary, 0..4095
    input  wire [11:0] data_b,
    output reg         sync,
    output reg         sclk,
    output wire        dina,
    output wire        dinb,
    output wire        busy
);

    reg        active;
    reg [7:0]  divcnt;
    reg [4:0]  bitcnt;
    reg [15:0] sha, shb;

    assign dina = sha[15];
    assign dinb = shb[15];
    assign busy = active;

    always @(posedge clk) begin
        if (!rstn) begin
            sync   <= 1'b1;
            sclk   <= 1'b1;
            active <= 1'b0;
            divcnt <= 8'd0;
            bitcnt <= 5'd0;
            sha    <= 16'd0;
            shb    <= 16'd0;
        end else if (!active) begin
            if (start) begin
                active <= 1'b1;
                sync   <= 1'b0;                 // start frame, MSB already on DIN
                sha    <= {4'b0000, data_a};
                shb    <= {4'b0000, data_b};
                divcnt <= 8'd0;
                bitcnt <= 5'd0;
            end
        end else if (divcnt == HALF - 1) begin
            divcnt <= 8'd0;
            if (sclk) begin
                sclk <= 1'b0;                   // falling edge: DAC samples DIN
            end else begin
                sclk <= 1'b1;                   // rising edge: present next bit
                if (bitcnt == 5'd15) begin
                    active <= 1'b0;             // 16 bits sent, DAC output updates
                    sync   <= 1'b1;
                end else begin
                    bitcnt <= bitcnt + 5'd1;
                    sha    <= {sha[14:0], 1'b0};
                    shb    <= {shb[14:0], 1'b0};
                end
            end
        end else begin
            divcnt <= divcnt + 8'd1;
        end
    end

endmodule
