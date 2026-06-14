import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.ActivityMonitor;
import Toybox.Activity;
import Toybox.Application;
import Toybox.Math;

//
// Abyss - a Subnautica-flavored dive-computer HUD watch face for the tactix 8.
//
// The face reads like an underwater PDA / dive-computer readout:
//
//   - Outer "depth ring":  an arc sweeping the bezel like a descent gauge,
//                          mapped to the day's progress (or steps - see RING_MODE).
//   - Left "O2 gauge":     device battery drawn as an air-supply tank that drains
//                          as the battery drops; cyan when full -> amber -> red low.
//   - Center HUD:          large time (12/24h follows the device), a "DEPTH" line
//                          driven by barometric elevation, and small TEMP / HR fields.
//   - Sonar ping:          a subtle cyan ring that pulses outward, ACTIVE state only.
//
// Everything is laid out relative to dc.getWidth()/getHeight() and the screen
// center, so it scales cleanly between the 454x454 (51mm) and 416x416 (47mm) AMOLED
// panels and the 280x280 / 260x260 MIP panels - no hardcoded pixel coordinates.
//
// Two render paths share one onUpdate():
//   - Full / active mode:        glows, filled gauges, sonar pulse (mLowPower == false)
//   - Always-on / low-power:     dim thin ring outlines + time only, burn-in shifted
//
// The face is fully PROCEDURAL: it compiles and looks complete with no image assets.
// Optional generated art (HUD frame, gauge housing, sonar rings, vignette) can be
// dropped in later - see the USE_ART_* flags and the README asset specs.
//
class AbyssView extends WatchUi.WatchFace {

    // --- Configuration knobs --------------------------------------------------
    // Outer depth ring source: 0 = day progress (midnight -> now), 1 = steps / goal.
    // Flip this single constant to switch what the bezel arc represents.
    private const RING_MODE = 0;

    // Battery % at/below which the O2 gauge starts shifting toward amber/red.
    private const O2_WARN = 50;   // begins warming below this
    private const O2_LOW  = 20;   // full red below this

    // Optional generated-art toggles. Leave false to render procedurally (the
    // default look). After dropping a real PNG into resources*/drawables/ (see
    // README asset specs), flip the matching flag to draw the bitmap instead.
    private const USE_ART_BG    = false;  // bg_vignette.png
    private const USE_ART_FRAME = false;  // hud_frame.png
    private const USE_ART_SONAR = false;  // sonar_ring.png

    // --- Screen geometry (resolved in onLayout) ---
    private var mWidth as Number = 0;
    private var mHeight as Number = 0;
    private var mCenterX as Number = 0;
    private var mCenterY as Number = 0;
    private var mRadius as Number = 0;

    // --- State ---
    private var mIsSleep as Boolean = false;
    private var mLowPower as Boolean = false;  // true only on AMOLED in Always-On (burn-in) mode
    private var mFlat as Boolean = false;      // true on MIP: flat fills, skip soft glows
    private var mLastMin as Number = -1;       // throttles low-power partial updates

    // --- Settings (see resources/settings) ---
    private var mShowSeconds as Boolean = false;
    private var mStepGoalOverride as Number = 0;  // 0 => use device step goal

    // --- Fonts (vector fonts, scaled to the panel, with safe fallbacks) ---
    private var mFontTime  as Graphics.FontType or Null = null;
    private var mFontValue as Graphics.FontType or Null = null;
    private var mFontLabel as Graphics.FontType or Null = null;

    // --- Optional cached drawables (loaded in onLayout, null if absent) ---
    private var mBgArt    as WatchUi.BitmapResource or Null = null;
    private var mFrameArt as WatchUi.BitmapResource or Null = null;
    private var mSonarArt as WatchUi.BitmapResource or Null = null;

    // --- Abyss palette (abyss-blue background, cyan/amber HUD) -----------------
    private const C_BG_TOP    = 0x02060E;  // near-black blue at the top
    private const C_BG_MID    = 0x05182C;  // faint abyss glow toward center
    private const C_BG_BOTTOM = 0x010308;  // darkest at the bottom ("the deep")
    private const BG_CLEAR    = 0x01040A;  // base clear color

    private const C_CYAN       = 0x33D6F0;  // primary HUD cyan
    private const C_CYAN_BRIGHT = 0x7CF2FF; // highlight cyan
    private const C_CYAN_DIM   = 0x1A6E7E;  // dim cyan (tracks, AOD)
    private const C_AMBER      = 0xFFB020;  // warning amber
    private const C_RED        = 0xFF4530;  // low / danger red
    private const C_TEXT       = 0xE6FAFF;  // near-white HUD text
    private const C_TEXT_DIM   = 0x6E7A80;  // muted label gray-cyan
    private const C_AOD        = 0x4A6E76;  // dim cyan-gray for always-on

    function initialize() {
        WatchFace.initialize();
        loadSettings();
    }

    // Read user settings; safe to call any time (e.g. from App.onSettingsChanged).
    function loadSettings() as Void {
        try {
            if (Application has :Properties) {
                var showSec = Application.Properties.getValue("ShowSeconds");
                var stepGoal = Application.Properties.getValue("StepGoalOverride");
                if (showSec != null) { mShowSeconds = showSec; }
                if (stepGoal != null) { mStepGoalOverride = stepGoal; }
            }
        } catch (e) {
            // keep defaults
        }
        if (mStepGoalOverride < 0) { mStepGoalOverride = 0; }
    }

    function onLayout(dc as Dc) as Void {
        mWidth = dc.getWidth();
        mHeight = dc.getHeight();
        mCenterX = mWidth / 2;
        mCenterY = mHeight / 2;
        mRadius = (mWidth < mHeight ? mWidth : mHeight) / 2;
        initFonts();

        // Optional art - cached once, drawn only when the matching USE_ART_* flag
        // is on. The declared placeholder PNGs are transparent, so even with a flag
        // on nothing breaks until you drop in real art. A failed load leaves the
        // field null and the procedural fallback takes over.
        try { mBgArt    = WatchUi.loadResource(Rez.Drawables.bg_vignette) as WatchUi.BitmapResource; } catch (e) { mBgArt = null; }
        try { mFrameArt = WatchUi.loadResource(Rez.Drawables.hud_frame)   as WatchUi.BitmapResource; } catch (e) { mFrameArt = null; }
        try { mSonarArt = WatchUi.loadResource(Rez.Drawables.sonar_ring)  as WatchUi.BitmapResource; } catch (e) { mSonarArt = null; }
    }

    // Vector fonts scale to the panel and give the clean, technical "PDA readout"
    // look this face wants. Built-ins are the last-resort fallback. (If you prefer
    // a baked bitmap font, see tools/gen_fonts.py + the README font note.)
    function initFonts() as Void {
        if (Graphics has :getVectorFont) {
            var face = ["RobotoCondensedBold", "RobotoRegular", "sans-serif"] as Array<String>;
            mFontTime  = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.215).toNumber() });
            mFontValue = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.075).toNumber() });
            mFontLabel = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.040).toNumber() });
        }
        // Built-in last resort if vector fonts are unavailable on this device.
        if (mFontTime == null)  { mFontTime  = Graphics.FONT_NUMBER_THAI_HOT; }
        if (mFontValue == null) { mFontValue = Graphics.FONT_MEDIUM; }
        if (mFontLabel == null) { mFontLabel = Graphics.FONT_XTINY; }
    }

    function onShow() as Void {
        loadSettings();
    }

    // Single render entry point for both active and low-power frames.
    function onUpdate(dc as Dc) as Void {
        var w = mWidth;
        var h = mHeight;
        var r = mRadius;

        // Burn-in-safe rendering applies ONLY to AMOLED panels in Always-On mode.
        // MIP / transflective panels (Fenix 8 Solar) have no burn-in and sit in
        // low-power most of the time while STILL showing the full face, so they
        // must always render the full layout.
        var burnIn = false;
        var dx = 0;
        var dy = 0;
        var settings = System.getDeviceSettings();
        var hasBurnIn = (settings has :requiresBurnInProtection) && settings.requiresBurnInProtection;
        if (hasBurnIn && mIsSleep) {
            burnIn = true;
            // Shift all lit pixels a few px each minute to avoid burn-in.
            var phase = System.getClockTime().min % 4;
            if (phase == 1)      { dx = 4;  dy = 2; }
            else if (phase == 2) { dx = -3; dy = 4; }
            else if (phase == 3) { dx = 3;  dy = -4; }
        }
        mLowPower = burnIn;
        mFlat = !hasBurnIn;   // MIP panels: skip soft glow rings (they band)

        var cx = mCenterX + dx;
        var cy = mCenterY + dy;

        // --- Background ---
        if (mLowPower) {
            // AOD: pitch black, minimal lit pixels.
            dc.setColor(0x000000, 0x000000);
            dc.clear();
        } else if (USE_ART_BG && mBgArt != null) {
            dc.setColor(BG_CLEAR, BG_CLEAR);
            dc.clear();
            dc.drawBitmap(0, 0, mBgArt);
        } else {
            drawAbyssBackground(dc);
        }

        // --- Outer depth ring (descent gauge) ---
        var ringFrac = (RING_MODE == 1) ? getStepFraction() : getDayFraction();
        drawDepthRing(dc, cx, cy, r, ringFrac);

        // --- O2 / air gauge (device battery) ---
        var stats = System.getSystemStats();
        var battery = (stats.battery != null) ? stats.battery.toNumber() : 0;
        drawO2Gauge(dc, cx, cy, r, battery);

        // --- Sonar ping (active only) ---
        if (!mLowPower) {
            drawSonar(dc, cx, cy, r);
        }

        // --- Optional HUD frame overlay (active only) ---
        if (!mLowPower && USE_ART_FRAME && mFrameArt != null) {
            dc.drawBitmap(0, 0, mFrameArt);
        } else if (!mLowPower) {
            drawCornerReticles(dc, cx, cy, r);
        }

        // --- Center HUD readout ---
        drawTime(dc, cx, (h * 0.40).toNumber() + dy);

        if (!burnIn) {
            // DEPTH line (barometric elevation) just under the time.
            drawDepthReadout(dc, cx, (h * 0.555).toNumber() + dy);

            // Bottom row: TEMP (left) and HR (right) flanking center.
            var fieldY = (h * 0.665).toNumber() + dy;
            drawSmallField(dc, (w * 0.34).toNumber() + dx, fieldY, "TEMP", getTempStr());
            drawSmallField(dc, (w * 0.66).toNumber() + dx, fieldY, "PULSE", getHeartStr());
        }
    }

    // Called ~once per second in always-on mode. We only show minute-resolution
    // time in AOD, so redraw only when the minute changes - keeping us well inside
    // the always-on pixel/power budget.
    function onPartialUpdate(dc as Dc) as Void {
        var min = System.getClockTime().min;
        if (min == mLastMin) { return; }
        mLastMin = min;
        onUpdate(dc);   // mIsSleep is true here -> low-power render path
    }

    // ------------------------------------------------------------------ Elements

    // Procedural abyss background: a vertical gradient from a near-black blue at the
    // top through a faint abyss glow to the darkest tone at the bottom ("the deep").
    // Monkey C has no native gradient fill, so we stack horizontal bands.
    function drawAbyssBackground(dc as Dc) as Void {
        dc.setColor(BG_CLEAR, BG_CLEAR);
        dc.clear();
        if (mFlat) {
            // MIP: a smooth band gradient just muddies; a flat clear reads cleaner.
            return;
        }
        var h = mHeight;
        var mid = h / 2;
        var step = 4;
        for (var y = 0; y < h; y += step) {
            var c;
            if (y < mid) {
                c = lerpColor(C_BG_TOP, C_BG_MID, y.toFloat() / mid);
            } else {
                c = lerpColor(C_BG_MID, C_BG_BOTTOM, (y - mid).toFloat() / mid);
            }
            dc.setColor(c, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, y, mWidth, step);
        }
    }

    // Outer descent gauge: a faint full-circle track near the bezel, a bright cyan
    // progress arc from 12 o'clock clockwise, plus tick marks. frac in [0,1].
    function drawDepthRing(dc as Dc, cx as Number, cy as Number, r as Number, frac as Float) as Void {
        if (frac < 0.0) { frac = 0.0; }
        if (frac > 1.0) { frac = 1.0; }
        var ringR = (r * 0.92).toNumber();

        if (mLowPower) {
            // AOD: a single thin dim outline, no fills.
            dc.setPenWidth(1);
            dc.setColor(C_AOD, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, ringR);
            return;
        }

        // Faint full track.
        dc.setPenWidth(3);
        dc.setColor(scaleColor(C_CYAN, 0.20), Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, ringR);

        // Progress arc. drawArc angles are CCW with 0 deg at 3 o'clock, so start at
        // 90 (12 o'clock) and sweep clockwise by frac of the full circle.
        var startDeg = 90;
        var endDeg = 90 - (frac * 360.0).toNumber();
        if (frac > 0.0) {
            if (!mFlat) {
                dc.setPenWidth(6);
                dc.setColor(scaleColor(C_CYAN, 0.35), Graphics.COLOR_TRANSPARENT);
                dc.drawArc(cx, cy, ringR, Graphics.ARC_CLOCKWISE, startDeg, endDeg);
            }
            dc.setPenWidth(4);
            dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, ringR, Graphics.ARC_CLOCKWISE, startDeg, endDeg);
        }

        // Tick marks every 30 degrees (a depth-scale feel).
        var tickInner = ringR - (r * 0.045).toNumber();
        dc.setPenWidth(2);
        for (var a = 0; a < 360; a += 30) {
            var rad = a * Math.PI / 180.0;
            var ca = Math.cos(rad);
            var sa = Math.sin(rad);
            dc.setColor(scaleColor(C_CYAN, 0.40), Graphics.COLOR_TRANSPARENT);
            dc.drawLine(cx + (ringR * ca).toNumber(), cy - (ringR * sa).toNumber(),
                        cx + (tickInner * ca).toNumber(), cy - (tickInner * sa).toNumber());
        }

        // Leading-edge marker dot at the current progress position.
        var headRad = (90 - frac * 360.0) * Math.PI / 180.0;
        var hx = cx + (ringR * Math.cos(headRad)).toNumber();
        var hy = cy - (ringR * Math.sin(headRad)).toNumber();
        dc.setColor(C_CYAN_BRIGHT, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(hx, hy, (r * 0.018).toNumber() + 2);
    }

    // O2 / air-supply gauge: a vertical segmented tank on the left, draining with
    // the device battery. Color shifts cyan -> amber -> red as it empties.
    function drawO2Gauge(dc as Dc, cx as Number, cy as Number, r as Number, level as Number) as Void {
        if (level < 0) { level = 0; }
        if (level > 100) { level = 100; }
        var frac = level / 100.0;

        var tankW = (mWidth * 0.052).toNumber();
        if (tankW < 6) { tankW = 6; }
        var tankH = (mHeight * 0.34).toNumber();
        var x = (mWidth * 0.115).toNumber();
        var top = cy - tankH / 2;
        var rad = tankW / 2;
        var color = o2Color(level);

        if (mLowPower) {
            // AOD: thin outline + a single level tick.
            dc.setPenWidth(1);
            dc.setColor(C_AOD, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x, top, tankW, tankH, rad);
            var ly = (top + tankH * (1.0 - frac)).toNumber();
            dc.drawLine(x, ly, x + tankW, ly);
            return;
        }

        // Tank housing (dark glass).
        dc.setColor(0x06121C, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, top, tankW, tankH, rad);

        // Fill from the bottom.
        if (frac > 0.0) {
            var fillH = (tankH * frac).toNumber();
            if (fillH < tankW) { fillH = tankW; }
            var fy = top + tankH - fillH;
            if (!mFlat) {
                dc.setColor(scaleColor(color, 0.35), Graphics.COLOR_TRANSPARENT);
                dc.fillRoundedRectangle(x - 1, fy - 1, tankW + 2, fillH + 2, rad + 1);
            }
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, fy, tankW, fillH, rad);
            // Bright meniscus at the surface.
            dc.setColor(lerpColor(color, 0xFFFFFF, 0.4), Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, fy, tankW, 2);
        }

        // Segment dividers every 25% (tank gauge ticks).
        dc.setPenWidth(1);
        dc.setColor(0x0A1E2A, Graphics.COLOR_TRANSPARENT);
        for (var i = 1; i < 4; i += 1) {
            var sy = (top + tankH * i / 4.0).toNumber();
            dc.drawLine(x, sy, x + tankW, sy);
        }

        // Housing outline.
        dc.setPenWidth(2);
        dc.setColor(scaleColor(color, 0.7), Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(x, top, tankW, tankH, rad);

        // "O2" label above + percentage below.
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + tankW / 2, top - (mHeight * 0.045).toNumber(), mFontLabel, "O2",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x + tankW / 2, top + tankH + (mHeight * 0.045).toNumber(), mFontLabel,
            level.format("%d") + "%",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // O2 gauge color: cyan when healthy, blending to amber then red as it drains.
    function o2Color(level as Number) as Number {
        if (level <= O2_LOW) { return C_RED; }
        if (level <= O2_WARN) {
            // O2_LOW..O2_WARN: red -> amber
            var t = (level - O2_LOW).toFloat() / (O2_WARN - O2_LOW);
            return lerpColor(C_RED, C_AMBER, t);
        }
        // O2_WARN..100: amber -> cyan
        var t2 = (level - O2_WARN).toFloat() / (100 - O2_WARN);
        return lerpColor(C_AMBER, C_CYAN, t2);
    }

    // Sonar ping: an expanding cyan ring that fades as it grows. ACTIVE state only.
    //
    // NOTE on cadence: a watch face's onUpdate normally fires only ~once a minute,
    // so true per-second animation is not available in active mode. We key the ring
    // radius to the current SECONDS value, so whenever the face does redraw (wrist
    // raise, minute tick, app event) the ping reflects "now" and reads as a live
    // sonar sweep. It is skipped entirely in always-on/low-power.
    function drawSonar(dc as Dc, cx as Number, cy as Number, r as Number) as Void {
        if (USE_ART_SONAR && mSonarArt != null) {
            dc.drawBitmap(0, 0, mSonarArt);
            return;
        }
        if (mFlat) { return; }   // skip on MIP (faint rings just band)

        var sec = System.getClockTime().sec;
        var phase = (sec % 3) / 3.0;             // 0..1 over a 3-second sweep
        var pingR = (r * 0.30 + phase * r * 0.45).toNumber();
        // Fade from cyan toward the background as it expands.
        var c = lerpColor(C_CYAN, C_BG_MID, phase);
        dc.setPenWidth(2);
        dc.setColor(c, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, pingR);
        // A fainter trailing ring for depth.
        if (phase < 0.6) {
            dc.setPenWidth(1);
            dc.setColor(lerpColor(C_CYAN, C_BG_MID, phase + 0.3), Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, pingR + (r * 0.05).toNumber());
        }
    }

    // Thin cyan corner reticles - a HUD-frame accent at the four diagonals.
    // (Replaced by hud_frame.png art when USE_ART_FRAME is enabled.)
    function drawCornerReticles(dc as Dc, cx as Number, cy as Number, r as Number) as Void {
        if (mFlat) { return; }
        var d = (r * 0.62).toNumber();
        var len = (r * 0.06).toNumber();
        dc.setPenWidth(2);
        dc.setColor(scaleColor(C_CYAN, 0.55), Graphics.COLOR_TRANSPARENT);
        var pts = [[-1, -1], [1, -1], [-1, 1], [1, 1]] as Array<Array<Number>>;
        for (var i = 0; i < 4; i += 1) {
            var sx = (cx + pts[i][0] * d * 0.707).toNumber();
            var sy = (cy + pts[i][1] * d * 0.707).toNumber();
            dc.drawLine(sx, sy, sx - pts[i][0] * len, sy);
            dc.drawLine(sx, sy, sx, sy - pts[i][1] * len);
        }
    }

    function drawTime(dc as Dc, cx as Number, cy as Number) as Void {
        var clock = System.getClockTime();
        var hour = clock.hour;
        var min = clock.min;
        var is24 = System.getDeviceSettings().is24Hour;
        if (!is24) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        var hourStr = is24 ? hour.format("%02d") : hour.format("%d");
        var timeStr = hourStr + ":" + min.format("%02d");

        dc.setColor(mLowPower ? C_AOD : C_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, mFontTime, timeStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // "DEPTH" readout driven by barometric elevation. On land this is your altitude,
    // labeled like a dive depth field. Blank ("--") if the sensor is unavailable.
    function drawDepthReadout(dc as Dc, cx as Number, y as Number) as Void {
        var depthStr = getElevationStr();
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y - (mHeight * 0.040).toNumber(), mFontLabel, "DEPTH",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_CYAN_BRIGHT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y + (mHeight * 0.012).toNumber(), mFontValue, depthStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // A small labeled HUD field: dim label above, cyan value below.
    function drawSmallField(dc as Dc, x as Number, y as Number, label as String, value as String) as Void {
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y - (mHeight * 0.028).toNumber(), mFontLabel, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + (mHeight * 0.012).toNumber(), mFontValue, value,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ------------------------------------------------------------------- Data

    // Fraction of the day elapsed (midnight -> now), 0.0 .. 1.0.
    function getDayFraction() as Float {
        var c = System.getClockTime();
        var secs = c.hour * 3600 + c.min * 60 + c.sec;
        return secs.toFloat() / 86400.0;
    }

    // Today's steps as a fraction of the step goal (0.0 .. 1.0).
    function getStepFraction() as Float {
        var info = ActivityMonitor.getInfo();
        if (info == null || info.steps == null) { return 0.0; }
        var goal = mStepGoalOverride;
        if (goal <= 0) {
            if (info.stepGoal != null && info.stepGoal > 0) {
                goal = info.stepGoal;
            } else {
                goal = 10000;   // sane fallback
            }
        }
        if (goal <= 0) { return 0.0; }
        var f = info.steps.toFloat() / goal.toFloat();
        if (f > 1.0) { f = 1.0; }
        return f;
    }

    // Barometric elevation in meters, formatted with an "M" suffix. "--" if absent.
    // Uses Activity.getActivityInfo().altitude (barometric on the tactix 8); the
    // value can be null when no fix/sensor data is available, so we fail gracefully.
    // TWEAK: change the unit/label here if you want feet, or to flip the sign for a
    // true "depth below surface" feel.
    function getElevationStr() as String {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && info.altitude != null) {
                return info.altitude.toNumber().format("%d") + "M";
            }
        } catch (e) {
            // fall through
        }
        return "--";
    }

    // Temperature from weather (falls back to "--"). Weather temperature is Celsius.
    function getTempStr() as String {
        try {
            if (Toybox has :Weather) {
                var cond = Weather.getCurrentConditions();
                if (cond != null && cond.temperature != null) {
                    return cond.temperature.format("%d") + "°";
                }
            }
        } catch (e) {
            // fall through
        }
        return "--°";
    }

    // Current heart rate via Activity info; "--" when not being read.
    function getHeartStr() as String {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && info.currentHeartRate != null) {
                return info.currentHeartRate.format("%d");
            }
        } catch (e) {
            // fall through
        }
        return "--";
    }

    // ------------------------------------------------------------ Color helpers

    // Linear interpolate between two 0xRRGGBB colors. t in [0,1].
    function lerpColor(c1 as Number, c2 as Number, t as Float) as Number {
        if (t < 0.0) { t = 0.0; }
        if (t > 1.0) { t = 1.0; }
        var r1 = (c1 >> 16) & 0xFF;
        var g1 = (c1 >> 8) & 0xFF;
        var b1 = c1 & 0xFF;
        var r2 = (c2 >> 16) & 0xFF;
        var g2 = (c2 >> 8) & 0xFF;
        var b2 = c2 & 0xFF;
        var r = (r1 + ((r2 - r1) * t)).toNumber();
        var g = (g1 + ((g2 - g1) * t)).toNumber();
        var b = (b1 + ((b2 - b1) * t)).toNumber();
        return (r << 16) | (g << 8) | b;
    }

    // Scale a color's brightness toward black. f in [0,1].
    function scaleColor(c as Number, f as Float) as Number {
        return lerpColor(0x000000, c, f);
    }

    // ----------------------------------------------------------- Lifecycle

    function onHide() as Void {}

    function onExitSleep() as Void {
        mIsSleep = false;
        WatchUi.requestUpdate();
    }

    function onEnterSleep() as Void {
        mIsSleep = true;
        mLastMin = -1;
        WatchUi.requestUpdate();
    }
}
