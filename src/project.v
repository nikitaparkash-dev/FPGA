/*
 * Copyright (c) 2024 Nikita
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_nikita_face_detect (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire [7:0] px_val       = ui_in;
    wire [1:0] ch_sel       = uio_in[1:0];
    wire       pixel_valid  = uio_in[2];
    wire       frame_done   = uio_in[3];
    wire [1:0] row_zone     = uio_in[5:4];
    wire [1:0] col_zone     = uio_in[7:6];

    reg [7:0] r_reg, g_reg, b_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_reg <= 8'b0; g_reg <= 8'b0; b_reg <= 8'b0;
        end else if (pixel_valid) begin
            case (ch_sel)
                2'b00: r_reg <= px_val;
                2'b01: g_reg <= px_val;
                2'b10: b_reg <= px_val;
                default: ;
            endcase
        end
    end

    // BUGFIX (stale blue): the accumulators sample the classifier on the same clock
    // edge the B channel is being latched, so b_reg would still hold the PREVIOUS
    // pixel's blue. Bypass the live blue value into classification. R and G were
    // latched on the two earlier sub-cycles of this pixel, so they are already current.
    wire [7:0] b_now = (pixel_valid && ch_sel == 2'b10) ? px_val : b_reg;

    wire skin_px = (
        (r_reg > 8'd95)  && (g_reg > 8'd40)  && (b_now > 8'd20)  &&
        (r_reg > g_reg)  && (r_reg > b_now)  &&
        ((r_reg - g_reg) > 8'd15) &&
        ((r_reg - b_now) > 8'd20) &&
        (r_reg < 8'd240) && (g_reg < 8'd200) && (b_now < 8'd170)
    );

    wire [9:0] brightness = {2'b0, r_reg} + {2'b0, g_reg} + {2'b0, b_now};
    wire dark_eye  = (brightness < 10'd150);
    wire dark_feat = (brightness < 10'd200);

    wire px_complete = pixel_valid && (ch_sel == 2'b10);

    // BUGFIX (per-frame reset + edge-detected frame_done): detect the rising edge of
    // frame_done so the result latch and the accumulator clear each fire exactly once
    // per pulse, regardless of how long the host holds frame_done high.
    reg  frame_done_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_done_d <= 1'b0;
        else        frame_done_d <= frame_done;
    end
    wire frame_done_pulse = frame_done && !frame_done_d;

    reg [19:0] skin_count;
    reg [19:0] total_count;
    reg [17:0] left_eye_dark;
    reg [17:0] right_eye_dark;
    reg [17:0] nose_dark;
    reg [17:0] mouth_dark;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skin_count     <= 20'b0;
            total_count    <= 20'b0;
            left_eye_dark  <= 18'b0;
            right_eye_dark <= 18'b0;
            nose_dark      <= 18'b0;
            mouth_dark     <= 18'b0;
        end else if (frame_done_pulse) begin
            // BUGFIX (per-frame reset): clear the accumulators at the frame boundary
            // so every frame starts fresh. Previously they were cleared only on rst_n,
            // so frame 2 onward accumulated on top of frame 1 and produced false
            // positives. The result latch below reads the pre-clear values on this
            // same edge (non-blocking), so the finished frame is still reported
            // correctly while the counters reset for the next frame.
            skin_count     <= 20'b0;
            total_count    <= 20'b0;
            left_eye_dark  <= 18'b0;
            right_eye_dark <= 18'b0;
            nose_dark      <= 18'b0;
            mouth_dark     <= 18'b0;
        end else if (px_complete) begin
            // BUGFIX (overflow safety): saturate instead of wrapping. An over-long
            // frame or an over-full zone now holds at its maximum rather than rolling
            // over to a small value, which could otherwise slip back under an
            // upper-bound guard and cause a false accept.
            if (!(&total_count))           total_count    <= total_count    + 1'b1;
            if (skin_px && !(&skin_count)) skin_count     <= skin_count     + 1'b1;
            if (row_zone == 2'b00 && dark_eye) begin
                if      (col_zone == 2'b00 && !(&left_eye_dark))  left_eye_dark  <= left_eye_dark  + 1'b1;
                else if (col_zone == 2'b01 && !(&right_eye_dark)) right_eye_dark <= right_eye_dark + 1'b1;
            end
            if (row_zone == 2'b01 && col_zone == 2'b10 && dark_feat && !(&nose_dark))
                nose_dark  <= nose_dark  + 1'b1;
            if (row_zone == 2'b10 && col_zone == 2'b10 && dark_feat && !(&mouth_dark))
                mouth_dark <= mouth_dark + 1'b1;
        end
    end

    // BUGFIX (ratio overflow): 20*skin_count via shift-add (16x + 4x), widened to 25
    // bits so the carry is never dropped. The old 24-bit form wrapped once skin_count
    // exceeded ~838,861 and misclassified very skin-heavy frames as not-skin.
    wire [24:0] twenty_skin = {1'b0, skin_count, 4'b0} + {3'b0, skin_count, 2'b0};
    wire skin_ratio_ok = twenty_skin > {5'b0, total_count};

    wire eyes_ok = (left_eye_dark  > 18'd50)    &&
                   (right_eye_dark > 18'd50)    &&
                   (left_eye_dark  < 18'd50000) &&
                   (right_eye_dark < 18'd50000) &&
                   (left_eye_dark  > (right_eye_dark >> 2)) &&
                   (right_eye_dark > (left_eye_dark  >> 2));

    wire nose_ok  = (nose_dark  > 18'd50) && (nose_dark  < 18'd100000);

    wire mouth_ok = (mouth_dark > 18'd50)     &&
                    (mouth_dark < 18'd100000) &&
                    (mouth_dark > nose_dark);

    reg face_det, skin_det, eyes_det, nose_det, mouth_det;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            face_det  <= 1'b0; skin_det  <= 1'b0;
            eyes_det  <= 1'b0; nose_det  <= 1'b0;
            mouth_det <= 1'b0;
        end else if (frame_done_pulse) begin
            skin_det  <= skin_ratio_ok;
            eyes_det  <= eyes_ok;
            nose_det  <= nose_ok;
            mouth_det <= mouth_ok;
            face_det  <= skin_ratio_ok && eyes_ok && nose_ok && mouth_ok;
        end
    end

    assign uo_out[0] = face_det;
    assign uo_out[1] = skin_det;
    assign uo_out[2] = eyes_det;
    assign uo_out[3] = nose_det;
    assign uo_out[4] = mouth_det;
    assign uo_out[7:5] = 3'b0;

    // Suppress unused input warning
    wire _unused = &{ena, 1'b0};

endmodule
