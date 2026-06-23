import Foundation

/// The MUSHclient *miniwindow* shim: the `Window*` world globals and the
/// `miniwin` constants table, mapped onto `proteles.window*`. Loaded by
/// ``LuaRuntime/loadCompatShim()`` after the core shim. See
/// `docs/plans/MINIWINDOW_FEASIBILITY.md` and `LuaRuntime+MiniWindow`.
///
/// Functions that MUSHclient defines but the spike doesn't model yet in full
/// GDI+ fidelity are present as benign partial implementations so a plugin that
/// calls them loads and runs rather than erroring on a nil global — the Phase-5
/// "fidelity tail" of the plan.
extension LuaRuntime {
    nonisolated static let miniWindowShimSource = #"""
    local proteles = proteles
    local eOK = error_code.eOK

    -- Constants plugins index (submodules/mushclient miniwindow API). --------
    miniwin = {
      -- positions
      stretch_to_view = 0, stretch_to_view_with_aspect = 1,
      stretch_to_owner = 2, stretch_to_owner_with_aspect = 3,
      pos_top_left = 4, pos_top_center = 5, pos_top_right = 6,
      pos_center_right = 7, pos_bottom_right = 8, pos_bottom_center = 9,
      pos_bottom_left = 10, pos_center_left = 11, pos_center_all = 12, pos_tile = 13,
      -- create flags
      create_underneath = 1, create_absolute_location = 2, create_transparent = 4,
      create_ignore_mouse = 8, create_keep_hotspots = 16,
      -- rect ops
      rect_frame = 1, rect_fill = 2, rect_invert = 3, rect_3d_rect = 4,
      rect_draw_edge = 5, rect_flood_fill_border = 6, rect_flood_fill_surface = 7,
      -- 3d-rect / edge sub-styles (values plugins pass as colours/flags)
      rect_edge_raised = 5, rect_edge_sunken = 10, rect_edge_etched = 6,
      rect_edge_bump = 9, rect_edge_at_all = 15, rect_option_fill_middle = 2048,
      -- circle ops
      circle_ellipse = 1, circle_rectangle = 2, circle_round_rectangle = 3,
      circle_chord = 4, circle_pie = 5,
      -- gradients
      gradient_horizontal = 1, gradient_vertical = 2, gradient_texture = 3,
      -- pen styles (+ caps/joins, OR-ed in)
      pen_solid = 0, pen_dash = 1, pen_dot = 2, pen_dash_dot = 3,
      pen_dash_dot_dot = 4, pen_null = 5, pen_inside_frame = 6,
      pen_endcap_round = 0, pen_endcap_square = 256, pen_endcap_flat = 512,
      pen_join_round = 0, pen_join_bevel = 4096, pen_join_miter = 8192,
      -- brush styles
      brush_solid = 0, brush_null = 1, brush_hatch_horizontal = 2,
      brush_hatch_vertical = 3, brush_hatch_forwards_diagonal = 4,
      brush_hatch_backwards_diagonal = 5, brush_hatch_cross = 6,
      brush_hatch_cross_diagonal = 7, brush_fine_pattern = 8,
      brush_medium_pattern = 9, brush_coarse_pattern = 10,
      brush_waves_horizontal = 11, brush_waves_vertical = 12,
      -- image draw modes / merge modes
      image_copy = 1, image_stretch = 2, image_transparent_copy = 3,
      image_fill_ellipse = 1, image_fill_rectangle = 2, image_fill_round_fill_rectangle = 3,
      merge_straight = 0, merge_transparent = 1,
      blend_normal = 1, blend_average = 2, blend_interpolate = 3, blend_dissolve = 4,
      blend_darken = 5, blend_multiply = 6, blend_colour_burn = 7, blend_linear_burn = 8,
      blend_inverse_colour_burn = 9, blend_subtract = 10, blend_lighten = 11, blend_screen = 12,
      blend_colour_dodge = 13, blend_linear_dodge = 14, blend_inverse_colour_dodge = 15,
      blend_add = 16, blend_overlay = 17, blend_soft_light = 18, blend_hard_light = 19,
      blend_vivid_light = 20, blend_linear_light = 21, blend_pin_light = 22,
      blend_hard_mix = 23, blend_difference = 24, blend_exclusion = 25,
      -- filters
      filter_noise = 1, filter_monochrome_noise = 2, filter_blur = 3,
      filter_sharpen = 4, filter_find_edges = 5, filter_emboss = 6,
      filter_brightness = 7, filter_contrast = 8, filter_gamma = 9,
      filter_red_brightness = 10, filter_red_contrast = 11, filter_red_gamma = 12,
      filter_green_brightness = 13, filter_green_contrast = 14, filter_green_gamma = 15,
      filter_blue_brightness = 16, filter_blue_contrast = 17, filter_blue_gamma = 18,
      filter_grayscale = 19, filter_normal_grayscale = 20, filter_brightness_multiply = 21,
      filter_red_brightness_multiply = 22, filter_green_brightness_multiply = 23,
      filter_blue_brightness_multiply = 24, filter_lesser_blur = 25, filter_minor_blur = 26,
      filter_average = 27,
      -- cursors
      cursor_none = -1, cursor_arrow = 0, cursor_hand = 1, cursor_ibeam = 2,
      cursor_plus = 3, cursor_wait = 4, cursor_up = 5, cursor_nw_se_arrow = 6,
      cursor_ne_sw_arrow = 7, cursor_ew_arrow = 8, cursor_ns_arrow = 9,
      cursor_both_arrow = 10, cursor_x = 11, cursor_help = 12,
      -- font charset / family / pitch
      font_charset_ansi = 0, font_charset_default = 1, font_charset_symbol = 2,
      font_family_any = 0, font_family_roman = 16, font_family_swiss = 32,
      font_family_modern = 48, font_family_script = 64, font_family_decorative = 80,
      font_pitch_default = 0, font_pitch_fixed = 1, font_pitch_variable = 2,
      -- hotspot flags + callback flag bits
      hotspot_report_all_mouseovers = 1,
      hotspot_got_shift = 1, hotspot_got_control = 2, hotspot_got_alt = 4,
      hotspot_got_lh_mouse = 16, hotspot_got_rh_mouse = 32, hotspot_got_dbl_click = 64,
      hotspot_got_not_first = 128, hotspot_got_middle_mouse = 512,
      wheel_scroll_back = 256,
    }

    -- Lifecycle --------------------------------------------------------------
    function WindowCreate(...) proteles.windowCreate(...); return eOK end
    function WindowDelete(...) proteles.windowDelete(...); return eOK end
    function WindowResize(...) proteles.windowResize(...); return eOK end
    function WindowPosition(...) proteles.windowPosition(...); return eOK end
    function WindowShow(name, show)
      proteles.windowShow(name, not (show == false or show == nil or show == 0))
      return eOK
    end

    -- Drawing ----------------------------------------------------------------
    function WindowRectOp(...) proteles.windowRectOp(...); return eOK end
    function WindowCircleOp(...) proteles.windowCircleOp(...); return eOK end
    function WindowLine(...) proteles.windowLine(...); return eOK end
    function WindowSetPixel(...) proteles.windowSetPixel(...); return eOK end
    function WindowGradient(...) proteles.windowGradient(...); return eOK end
    function WindowPolygon(...) proteles.windowPolygon(...); return eOK end
    function WindowArc(...) proteles.windowArc(...); return eOK end
    function WindowBezier(...) proteles.windowBezier(...); return eOK end

    -- Text + fonts (return a value) -----------------------------------------
    function WindowFont(...) proteles.windowFont(...); return eOK end
    function WindowText(...) return proteles.windowText(...) end
    function WindowTextWidth(...) return proteles.windowTextWidth(...) end
    function WindowFontInfo(...) return proteles.windowFontInfo(...) end
    function WindowInfo(...) return proteles.windowInfo(...) end

    -- Hotspots ---------------------------------------------------------------
    function WindowAddHotspot(...) proteles.windowAddHotspot(...); return eOK end
    function WindowDeleteHotspot(...) proteles.windowDeleteHotspot(...); return eOK end
    function WindowDeleteAllHotspots(...) proteles.windowDeleteAllHotspots(...); return eOK end
    function WindowMoveHotspot(...) proteles.windowMoveHotspot(...); return eOK end
    function WindowDragHandler(...) proteles.windowDragHandler(...); return eOK end
    function WindowScrollwheelHandler(...) proteles.windowScrollwheelHandler(...); return eOK end
    function WindowHotspotInfo(...) return proteles.windowHotspotInfo(...) end
    function WindowHotspotTooltip(name, id, text) return eOK end
    function WindowMenu(...) return proteles.windowMenu(...) end

    -- Images -----------------------------------------------------------------
    -- WindowLoadImage(name, id, filename): load from a (sandboxed) file path.
    function WindowLoadImage(name, id, filename)
      proteles.windowLoadImage(name, id, tostring(filename or ""), false); return eOK
    end
    -- WindowLoadImageMemory(name, id, buffer, ...): load from an in-memory
    -- buffer. Pass it through as the memory source — base64 survives Lua-string
    -- marshalling (raw binary with NULs does not), so base64-encode large images.
    function WindowLoadImageMemory(name, id, buffer)
      proteles.windowLoadImage(name, id, tostring(buffer or ""), true); return eOK
    end
    function WindowDrawImage(...) proteles.windowDrawImage(...); return eOK end
    function WindowDrawImageAlpha(name, id, l, t, r, b, opacity, sl, st)
      proteles.windowDrawImage(name, id, l, t, r, b, miniwin.image_copy, sl, st, 0, 0, opacity); return eOK
    end
    function WindowBlendImage(name, id, l, t, r, b, mode, opacity, sl, st, sr, sb)
      proteles.windowDrawImage(name, id, l, t, r, b, mode, sl, st, sr, sb, opacity); return eOK
    end
    function WindowImageInfo(...) return proteles.windowImageInfo(...) end

    -- Phase-5 tail (benign stubs so callers don't hit a nil global) ----------
    function WindowSetZOrder(name, z) proteles.windowSetZOrder(name, z); return eOK end
    function WindowFilter(...) proteles.windowFilter(...); return eOK end
    function WindowMergeImageAlpha(...) proteles.windowMergeImageAlpha(...); return eOK end
    function WindowTransformImage(...) proteles.windowTransformImage(...); return eOK end
    function WindowImageFromWindow(...) return proteles.windowImageFromWindow(...) end
    function WindowImageOp(...) proteles.windowImageOp(...); return eOK end
    function WindowGetImageAlpha(...) return eOK end
    function WindowCreateImage(...) return eOK end
    function WindowWrite(...) return proteles.windowWrite(...) end
    function WindowGetPixel(...) return proteles.windowGetPixel(...) end
    function WindowList() return proteles.windowList() end
    function WindowInfoList(...) return proteles.windowInfoList(...) end
    function WindowFontList(...) return proteles.windowFontList(...) end
    function WindowImageList(...) return proteles.windowImageList(...) end
    function WindowHotspotList(...) return proteles.windowHotspotList(...) end
    """#
}
