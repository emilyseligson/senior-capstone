`timescale 1ns / 1ps
// eis_core: datapath for the FPGA-based EIS system on the PYNQ-Z2.
//
//   - sample tick: fs = 100 MHz / TICK_DIV (500 kSPS by default)
//   - Pmod DA2:    DAC A = DDS sine, DAC B = DDS cosine, updated every tick
//   - Pmod AD1:    both channels converted every tick
//   - capture:     on start, discard settle_samples, then send n_samples
//                  sample pairs out the AXI4-Stream master to the AXI DMA
//
// Connections in the block design:
//   ctrl, n_samples, settle_samples  <- myr_regs outputs
//   status                           -> myr_regs status input
//   sample_tick                      -> DDS Compiler aclken
//   dds_data                         <- DDS Compiler m_axis_data_tdata
//                                       ([31:16] sine, [15:0] cosine)
//   m_axis                           -> AXI DMA S_AXIS_S2MM
//
// Register bits:
//   ctrl[0]    start (a 0 -> 1 change starts a capture)
//   status[0]  busy (settling or capturing)
//   status[1]  overflow (a word was overwritten before the DMA took it;
//              cleared on the next start)
//   status[2]  done (last word sent; cleared on the next start)
//
// Stream word: {4'b0, ch1[11:0], 4'b0, ch0[11:0]}, tlast on the final word.

module eis_core #(
    parameter integer TICK_DIV = 200,     // 100 MHz / 200 = 500 kSPS
    parameter integer SPI_HALF = 4        // SPI SCLK = 100 MHz / 8 = 12.5 MHz
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,

    // from / to myr_regs
    input  wire [31:0] ctrl,
    input  wire [31:0] n_samples,
    input  wire [31:0] settle_samples,
    output wire [31:0] status,

    // DDS Compiler
    output wire        sample_tick,
    input  wire [31:0] dds_data,

    // Pmod DA2
    output wire        da2_sync,
    output wire        da2_sclk,
    output wire        da2_dina,
    output wire        da2_dinb,

    // Pmod AD1
    output wire        ad1_cs,
    output wire        ad1_sclk,
    input  wire        ad1_d0,
    input  wire        ad1_d1,

    // AXI4-Stream master -> AXI DMA
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg  [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output reg         m_axis_tlast
);

    // ------------------------------------------------------------------
    // Sample tick: one-cycle pulse every TICK_DIV clocks
    // ------------------------------------------------------------------
    reg [15:0] tick_cnt;
    reg        tick;

    always @(posedge aclk) begin
        if (!aresetn) begin
            tick_cnt <= 16'd0;
            tick     <= 1'b0;
        end else begin
            tick     <= (tick_cnt == TICK_DIV - 1);
            tick_cnt <= (tick_cnt == TICK_DIV - 1) ? 16'd0 : tick_cnt + 16'd1;
        end
    end

    assign sample_tick = tick;

    // ------------------------------------------------------------------
    // DAC: DDS outputs are signed 16-bit; the DAC wants 12-bit offset binary.
    // Flipping the sign bit converts two's complement to offset binary.
    // ------------------------------------------------------------------
    wire [15:0] dds_sine   = dds_data[31:16];
    wire [15:0] dds_cosine = dds_data[15:0];
    
    // Amplitude control: output Vpp = 3.3 V * AMP / 256
    // AMP = 155  ->  3.3 * 155 / 256 = 2.00 Vpp
    localparam signed [9:0] AMP = 10'sd155;
    
    // Multiply the sine and cosine by AMP
    wire signed [25:0] sine_mult   = $signed(dds_sine)   * AMP;
    wire signed [25:0] cosine_mult = $signed(dds_cosine) * AMP;
    
    // Divide by 256 by dropping the bottom 8 bits
    wire signed [15:0] sine_small   = sine_mult[23:8];
    wire signed [15:0] cosine_small = cosine_mult[23:8];
    
    wire [11:0] dac_a = {~sine_small[15],   sine_small[14:4]};
    wire [11:0] dac_b = {~cosine_small[15], cosine_small[14:4]};

    pmod_da2_spi #(.HALF(SPI_HALF)) u_dac (
        .clk    (aclk),
        .rstn   (aresetn),
        .start  (tick),
        .data_a (dac_a),
        .data_b (dac_b),
        .sync   (da2_sync),
        .sclk   (da2_sclk),
        .dina   (da2_dina),
        .dinb   (da2_dinb),
        .busy   ()
    );

    // ------------------------------------------------------------------
    // ADC
    // ------------------------------------------------------------------
    wire [11:0] adc_ch0, adc_ch1;
    wire        adc_done;

    pmod_ad1_spi #(.HALF(SPI_HALF)) u_adc (
        .clk   (aclk),
        .rstn  (aresetn),
        .start (tick),
        .d0    (ad1_d0),
        .d1    (ad1_d1),
        .cs    (ad1_cs),
        .sclk  (ad1_sclk),
        .data0 (adc_ch0),
        .data1 (adc_ch1),
        .done  (adc_done),
        .busy  ()
    );

    // ------------------------------------------------------------------
    // Capture control and AXI4-Stream output
    // ------------------------------------------------------------------
    reg        start_d;
    reg        settling, capturing;
    reg        overflow, done_flag;
    reg [31:0] count;

    wire start_rise = ctrl[0] & ~start_d;

    always @(posedge aclk) begin
        if (!aresetn) begin
            start_d       <= 1'b0;
            settling      <= 1'b0;
            capturing     <= 1'b0;
            overflow      <= 1'b0;
            done_flag     <= 1'b0;
            count         <= 32'd0;
            m_axis_tdata  <= 32'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            start_d <= ctrl[0];

            // DMA accepted the current word
            if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
            end

            if (start_rise && !settling && !capturing && n_samples != 32'd0) begin
                overflow  <= 1'b0;
                done_flag <= 1'b0;
                count     <= 32'd0;
                if (settle_samples != 32'd0) settling  <= 1'b1;
                else                         capturing <= 1'b1;
            end else if (adc_done) begin
                if (settling) begin
                    if (count == settle_samples - 1) begin
                        settling  <= 1'b0;
                        capturing <= 1'b1;
                        count     <= 32'd0;
                    end else begin
                        count <= count + 32'd1;
                    end
                end else if (capturing) begin
                    // previous word still waiting: it gets overwritten
                    if (m_axis_tvalid && !m_axis_tready) overflow <= 1'b1;
                    m_axis_tdata  <= {4'b0000, adc_ch1, 4'b0000, adc_ch0};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= (count == n_samples - 1);
                    if (count == n_samples - 1) begin
                        capturing <= 1'b0;
                        done_flag <= 1'b1;
                    end else begin
                        count <= count + 32'd1;
                    end
                end
            end
        end
    end

    assign status = {29'd0, done_flag, overflow, settling | capturing};

endmodule
