`timescale 1ns / 1ps
// Testbench for eis_core.
//   - fake DDS output that changes every sample tick
//   - DAC model: receives each SPI frame and checks it against the DDS value
//   - ADC model: returns a counter on ch0 and its complement on ch1
//   - stream checker: checks word format, ch0/ch1 values, and tlast
// Prints PASS or FAIL at the end. In Vivado, use "Run All".

module tb_eis_core;

    reg clk = 1'b0;
    always #5 clk = ~clk;                    // 100 MHz

    reg         aresetn        = 1'b0;
    reg  [31:0] ctrl           = 32'd0;
    reg  [31:0] n_samples      = 32'd8;
    reg  [31:0] settle_samples = 32'd2;
    wire [31:0] status;
    wire        sample_tick;
    reg  [31:0] dds_data       = 32'h4000_0000;

    wire da2_sync, da2_sclk, da2_dina, da2_dinb;
    wire ad1_cs, ad1_sclk, ad1_d0, ad1_d1;

    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid, m_axis_tlast;
    reg         m_axis_tready = 1'b1;

    eis_core uut (
        .aclk           (clk),
        .aresetn        (aresetn),
        .ctrl           (ctrl),
        .n_samples      (n_samples),
        .settle_samples (settle_samples),
        .status         (status),
        .sample_tick    (sample_tick),
        .dds_data       (dds_data),
        .da2_sync       (da2_sync),
        .da2_sclk       (da2_sclk),
        .da2_dina       (da2_dina),
        .da2_dinb       (da2_dinb),
        .ad1_cs         (ad1_cs),
        .ad1_sclk       (ad1_sclk),
        .ad1_d0         (ad1_d0),
        .ad1_d1         (ad1_d1),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast)
    );

    // ---------------- fake DDS ----------------
    always @(posedge clk)
        if (sample_tick) dds_data <= dds_data + 32'h0123_0457;

    // ---------------- DAC model ----------------
    reg [11:0] exp_a, exp_b;
    reg [15:0] rx_a, rx_b;
    integer dac_bits = 0, dac_frames = 0, dac_errors = 0;

    // value the DAC driver latches on this tick
    always @(posedge clk)
        if (sample_tick) begin
            exp_a <= {~dds_data[31], dds_data[30:20]};
            exp_b <= {~dds_data[15], dds_data[14:4]};
        end

    always @(negedge da2_sync) dac_bits = 0;

    always @(negedge da2_sclk)
        if (da2_sync == 1'b0) begin
            rx_a     = {rx_a[14:0], da2_dina};
            rx_b     = {rx_b[14:0], da2_dinb};
            dac_bits = dac_bits + 1;
        end

    always @(posedge da2_sync)
        if (dac_bits == 16) begin
            dac_frames = dac_frames + 1;
            if (rx_a !== {4'b0000, exp_a} || rx_b !== {4'b0000, exp_b}) begin
                dac_errors = dac_errors + 1;
                $display("DAC ERROR: got A=%h B=%h, expected A=%h B=%h",
                         rx_a, rx_b, {4'b0000, exp_a}, {4'b0000, exp_b});
            end
        end

    // ---------------- ADC model (AD7476A behavior) ----------------
    reg [11:0] conv_n  = 12'h100;
    reg [15:0] adc_sh0 = 16'd0, adc_sh1 = 16'd0;
    assign ad1_d0 = adc_sh0[15];
    assign ad1_d1 = adc_sh1[15];

    // CS falling: first leading zero appears on DOUT
    always @(negedge ad1_cs) begin
        adc_sh0 <= #2 {4'b0000, conv_n};
        adc_sh1 <= #2 {4'b0000, ~conv_n};
    end
    // each SCLK falling edge shifts out the next bit (after a delay)
    always @(negedge ad1_sclk)
        if (ad1_cs == 1'b0) begin
            adc_sh0 <= #8 {adc_sh0[14:0], 1'b0};
            adc_sh1 <= #8 {adc_sh1[14:0], 1'b0};
        end
    always @(posedge ad1_cs) conv_n <= conv_n + 12'd1;

    // ---------------- stream checker ----------------
    integer words = 0, stream_errors = 0;
    reg [11:0] ch0, ch1, prev_ch0;

    always @(posedge clk)
        if (m_axis_tvalid && m_axis_tready) begin
            ch0 = m_axis_tdata[11:0];
            ch1 = m_axis_tdata[27:16];
            $display("%t  word %0d: ch0=%h ch1=%h tlast=%b",
                     $time, words, ch0, ch1, m_axis_tlast);
            if (m_axis_tdata[15:12] !== 4'd0 || m_axis_tdata[31:28] !== 4'd0) begin
                stream_errors = stream_errors + 1;
                $display("  ERROR: padding bits not zero");
            end
            if (ch1 !== ~ch0) begin
                stream_errors = stream_errors + 1;
                $display("  ERROR: ch1 should be the complement of ch0");
            end
            if (words > 0 && ch0 !== prev_ch0 + 12'd1) begin
                stream_errors = stream_errors + 1;
                $display("  ERROR: ch0 should increase by 1 each sample");
            end
            if (m_axis_tlast !== (words == n_samples - 1)) begin
                stream_errors = stream_errors + 1;
                $display("  ERROR: tlast wrong");
            end
            prev_ch0 = ch0;
            words    = words + 1;
        end

    // ---------------- test sequence ----------------
    initial begin
        $display("eis_core testbench: n_samples=%0d settle_samples=%0d",
                 n_samples, settle_samples);
        #200 aresetn = 1'b1;
        #5000;                               // let the DAC/ADC run a few ticks

        @(posedge clk) ctrl <= 32'd1;        // start (0 -> 1)
        @(posedge clk) ctrl <= 32'd0;
        @(posedge clk);
        if (status[0] !== 1'b1) begin
            stream_errors = stream_errors + 1;
            $display("ERROR: busy did not go high after start");
        end

        wait (status[2] == 1'b1);            // done
        #1000;

        if (status[0] !== 1'b0) begin
            stream_errors = stream_errors + 1;
            $display("ERROR: busy still high after done");
        end
        if (status[1] !== 1'b0) begin
            stream_errors = stream_errors + 1;
            $display("ERROR: overflow flag set");
        end
        if (words != n_samples) begin
            stream_errors = stream_errors + 1;
            $display("ERROR: got %0d words, expected %0d", words, n_samples);
        end
        if (dac_frames == 0) begin
            dac_errors = dac_errors + 1;
            $display("ERROR: no DAC frames seen");
        end

        if (dac_errors == 0 && stream_errors == 0)
            $display("PASS: %0d stream words and %0d DAC frames checked", words, dac_frames);
        else
            $display("FAIL: %0d DAC errors, %0d stream errors", dac_errors, stream_errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: TIMEOUT (done never went high)");
        $finish;
    end

endmodule
