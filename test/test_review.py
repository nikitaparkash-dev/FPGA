# SPDX-License-Identifier: Apache-2.0
# Directed regression tests written during code review to PROVE specific defects
# in src/project.v. These assert CORRECT behavior, so they are expected to FAIL
# on the current RTL — each failure is the proof of the corresponding finding.
#
# Run:  make -B COCOTB_TEST_MODULES=test_review
#
# Findings proven here:
#   F1 (CRITICAL) - accumulators never cleared between frames -> false positive on frame 2
#   A1 (HIGH)     - stale blue channel -> a genuine skin pixel after a different-blue pixel is not counted

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

ROW_EYE, ROW_NOSE, ROW_MOUTH = 0b00, 0b01, 0b10
COL_LEFT, COL_RIGHT, COL_CENTRE = 0b00, 0b01, 0b10


async def send_pixel(dut, r, g, b, row_zone=0, col_zone=0):
    for ch, val in enumerate([r, g, b]):
        dut.ui_in.value = val
        dut.uio_in.value = (col_zone << 6) | (row_zone << 4) | (1 << 2) | ch
        await RisingEdge(dut.clk)
    dut.uio_in.value = 0


async def end_frame(dut):
    dut.uio_in.value = (1 << 3)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)


async def reset(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut.rst_n.value = 0
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await Timer(30, unit="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_detecting_face(dut):
    """Same stimulus as the shipped test_face_detected: produces face_detected=1."""
    for _ in range(100):
        await send_pixel(dut, 200, 150, 100)            # skin
    for _ in range(100):
        await send_pixel(dut, 50, 50, 200)              # background
    for _ in range(200):
        await send_pixel(dut, 30, 30, 30, ROW_EYE, COL_LEFT)
    for _ in range(200):
        await send_pixel(dut, 30, 30, 30, ROW_EYE, COL_RIGHT)
    for _ in range(300):
        await send_pixel(dut, 50, 50, 50, ROW_NOSE, COL_CENTRE)
    for _ in range(400):
        await send_pixel(dut, 50, 50, 50, ROW_MOUTH, COL_CENTRE)


@cocotb.test()
async def test_multiframe_carryover(dut):
    """F1: a clean SECOND frame must report no face. Fails on current RTL because
    the accumulators are only cleared on reset, never on frame_done."""
    await reset(dut)

    # Frame 1: a real face -> face_detected should be 1
    await drive_detecting_face(dut)
    await end_frame(dut)
    frame1 = int(dut.uo_out.value)
    dut._log.info(f"Frame 1 uo_out = {frame1:#07b} (face bit = {frame1 & 1})")
    assert frame1 & 1 == 1, "sanity: frame 1 should detect a face"

    # Frame 2: ONLY benign background, NO reset between frames (the documented
    # 'streaming' use case). A correct detector must report face_detected = 0.
    for _ in range(500):
        await send_pixel(dut, 50, 100, 180)             # not skin, not dark
    await end_frame(dut)
    frame2 = int(dut.uo_out.value)
    dut._log.info(f"Frame 2 uo_out = {frame2:#07b} (face bit = {frame2 & 1})")

    assert frame2 & 1 == 0, (
        f"F1 PROVEN: second clean frame falsely reports face_detected=1 "
        f"(uo_out={frame2:#07b}); accumulators carried over from frame 1 "
        f"because they are never cleared at the frame boundary."
    )


@cocotb.test()
async def test_stale_blue_channel(dut):
    """A1: a genuine skin pixel immediately after a pixel with different blue is
    misclassified, because the classifier samples b_reg on the same edge B is
    latched and therefore sees the PREVIOUS pixel's blue."""
    await reset(dut)

    # Pixel 1: background with high blue (B=200). Not skin (R=50).
    await send_pixel(dut, 50, 50, 200)
    # Pixel 2: a genuine skin pixel (R=200,G=150,B=100). B=100 < 170 => should be skin.
    await send_pixel(dut, 200, 150, 100)
    await RisingEdge(dut.clk)

    skin_count = int(dut.user_project.skin_count.value)
    b_reg = int(dut.user_project.b_reg.value)
    dut._log.info(f"skin_count = {skin_count}, b_reg = {b_reg} (last latched blue)")

    assert skin_count == 1, (
        f"A1 PROVEN: the genuine skin pixel (200,150,100) was NOT counted "
        f"(skin_count={skin_count}, expected 1). Its skin test used the PREVIOUS "
        f"pixel's blue (200), which fails the b_reg<170 skin condition."
    )
