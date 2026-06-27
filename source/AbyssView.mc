import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.ActivityMonitor;
import Toybox.Activity;
import Toybox.Application;
import Toybox.SensorHistory;
import Toybox.Weather;
import Toybox.Position;
import Toybox.UserProfile;
import Toybox.Math;

//
// Abyss - a Subnautica-flavored dive-computer HUD watch face for the tactix 8.
//
// The face reads like an underwater PDA / dive-computer readout. Layout zones,
// all relative to dc.getWidth()/getHeight() + the screen center (no hardcoded px):
//
//   - Outer "depth ring":  descent-gauge arc (day progress, or steps - RING_MODE).
//   - Left  "BATT" tank:   device battery as a draining air supply (cyan->amber->red).
//   - Right "BODY" tank:   Body Battery as a stamina reserve (mint->amber->red).
//   - Top stack:           sunrise/sunset, date (+ notification badge), a weather
//                          line (condition / temp / hi-lo), steps/distance, and an
//                          optional compass heading (off by default).
//   - Center:              large time, then a "DEPTH" line (barometric elevation).
//   - Bottom rows:         PULSE (+resting) / CAL / FLOORS, then STRESS / ACTIVE / PRESS.
//   - Sonar ping:          a cyan ring pulse, ACTIVE state only.
//
// Two render paths share one onUpdate():
//   - Full / active:   gradients, filled gauges, all fields, sonar pulse.
//   - Always-on:       dim time + thin ring/tank outlines only, burn-in shifted.
//
// Live data is read defensively (has-checks + try/catch); any missing value shows a
// blank "--" rather than crashing. The face is otherwise fully procedural and
// compiles/renders complete with no image assets (optional art via USE_ART_* flags).
//
class AbyssView extends WatchUi.WatchFace {

    // --- Configuration knobs --------------------------------------------------
    // Outer depth ring source: 0 = day progress (midnight -> now), 1 = steps / goal.
    private const RING_MODE = 0;

    // Battery / Body-Battery % thresholds where a tank gauge warms to amber / red.
    private const WARN_PCT = 50;
    private const LOW_PCT  = 20;

    // Optional generated-art toggles (procedural fallback when false / missing).
    private const USE_ART_BG    = false;  // bg_vignette.png
    private const USE_ART_FRAME = false;  // hud_frame.png
    private const USE_ART_SONAR = false;  // sonar_ring.png

    // --- Screen geometry (resolved in onLayout) ---
    private var mWidth as Number = 0;
    private var mHeight as Number = 0;
    private var mCenterX as Number = 0;
    private var mCenterY as Number = 0;
    private var mRadius as Number = 0;
    private var mSmall as Boolean = false;  // low-res MIP panels (<= 320px): leaner layout, bitmap fonts

    // --- State ---
    private var mIsSleep as Boolean = false;
    private var mLowPower as Boolean = false;  // AMOLED Always-On (burn-in) only
    private var mFlat as Boolean = false;      // MIP: flat fills, skip soft glows
    private var mLastMin as Number = -1;

    // --- Settings ---
    private var mStepGoalOverride as Number = 0;  // 0 => device step goal
    private var mEnableCompass as Boolean = false; // magnetometer is battery-heavy

    // --- Fonts (vector, scaled to the panel, with built-in fallbacks) ---
    private var mFontTime  as Graphics.FontType or Null = null;
    private var mFontValue as Graphics.FontType or Null = null;
    private var mFontLabel as Graphics.FontType or Null = null;
    private var mFontMicro as Graphics.FontType or Null = null;

    // --- Optional cached art ---
    private var mBgArt    as WatchUi.BitmapResource or Null = null;
    private var mFrameArt as WatchUi.BitmapResource or Null = null;
    private var mSonarArt as WatchUi.BitmapResource or Null = null;

    // --- Abyss palette --------------------------------------------------------
    private const C_BG_TOP    = 0x02060E;
    private const C_BG_MID    = 0x05182C;
    private const C_BG_BOTTOM = 0x010308;
    private const BG_CLEAR    = 0x01040A;

    private const C_CYAN        = 0x33D6F0;
    private const C_CYAN_BRIGHT = 0x7CF2FF;
    private const C_BIO         = 0x40E8A8;  // mint-green for the BIO (Body Battery) tank
    private const C_AMBER       = 0xFFB020;
    private const C_RED         = 0xFF4530;
    private const C_TEXT        = 0xE6FAFF;
    private const C_TEXT_DIM    = 0x6E8A92;
    private const C_AOD         = 0x4A6E76;

    function initialize() {
        WatchFace.initialize();
        loadSettings();
    }

    function loadSettings() as Void {
        try {
            if (Application has :Properties) {
                var stepGoal = Application.Properties.getValue("StepGoalOverride");
                var compass  = Application.Properties.getValue("EnableCompass");
                if (stepGoal != null) { mStepGoalOverride = stepGoal; }
                if (compass != null)  { mEnableCompass = compass; }
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
        mSmall = (mWidth <= 320);
        initFonts();

        try { mBgArt    = WatchUi.loadResource(Rez.Drawables.bg_vignette) as WatchUi.BitmapResource; } catch (e) { mBgArt = null; }
        try { mFrameArt = WatchUi.loadResource(Rez.Drawables.hud_frame)   as WatchUi.BitmapResource; } catch (e) { mFrameArt = null; }
        try { mSonarArt = WatchUi.loadResource(Rez.Drawables.sonar_ring)  as WatchUi.BitmapResource; } catch (e) { mSonarArt = null; }
    }

    function initFonts() as Void {
        // Large AMOLED panels: crisp scalable vector fonts, sized to the screen.
        if (!mSmall && (Graphics has :getVectorFont)) {
            var face = ["RobotoCondensedBold", "RobotoRegular", "sans-serif"] as Array<String>;
            mFontTime  = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.200).toNumber() });
            mFontValue = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.066).toNumber() });
            mFontLabel = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.038).toNumber() });
            mFontMicro = Graphics.getVectorFont({ :face => face, :size => (mWidth * 0.030).toNumber() });
        }
        // Small MIP panels (and any vector-font fallback): the device's own bitmap
        // fonts are hinted for the panel and read far better than hairline vector
        // text at low resolution.
        if (mFontTime == null)  { mFontTime  = mSmall ? Graphics.FONT_NUMBER_MEDIUM : Graphics.FONT_NUMBER_THAI_HOT; }
        if (mFontValue == null) { mFontValue = mSmall ? Graphics.FONT_TINY  : Graphics.FONT_SMALL; }
        if (mFontLabel == null) { mFontLabel = Graphics.FONT_XTINY; }
        if (mFontMicro == null) { mFontMicro = Graphics.FONT_XTINY; }
    }

    function onShow() as Void {
        loadSettings();
    }

    // Single render entry point for active and low-power frames.
    function onUpdate(dc as Dc) as Void {
        var w = mWidth;
        var h = mHeight;
        var r = mRadius;

        var burnIn = false;
        var dx = 0;
        var dy = 0;
        var settings = System.getDeviceSettings();
        var hasBurnIn = (settings has :requiresBurnInProtection) && settings.requiresBurnInProtection;
        if (hasBurnIn && mIsSleep) {
            burnIn = true;
            var phase = System.getClockTime().min % 4;
            if (phase == 1)      { dx = 4;  dy = 2; }
            else if (phase == 2) { dx = -3; dy = 4; }
            else if (phase == 3) { dx = 3;  dy = -4; }
        }
        mLowPower = burnIn;
        mFlat = !hasBurnIn;

        var cx = mCenterX + dx;
        var cy = mCenterY + dy;

        // --- Background ---
        if (mLowPower) {
            dc.setColor(0x000000, 0x000000);
            dc.clear();
        } else if (USE_ART_BG && mBgArt != null) {
            dc.setColor(BG_CLEAR, BG_CLEAR);
            dc.clear();
            dc.drawBitmap(0, 0, mBgArt);
        } else {
            drawAbyssBackground(dc);
        }

        // --- Outer depth ring ---
        var ringFrac = (RING_MODE == 1) ? getStepFraction() : getDayFraction();
        drawDepthRing(dc, cx, cy, r, ringFrac);

        // --- Side tanks: BATT (device battery, left) and BODY (Body Battery, right) ---
        var stats = System.getSystemStats();
        var battery = (stats.battery != null) ? stats.battery.toNumber() : 0;
        var tankW = (w * 0.050).toNumber();
        if (tankW < 6) { tankW = 6; }
        var leftX  = (w * 0.110).toNumber() + dx;
        var rightX = w - (w * 0.110).toNumber() - tankW + dx;
        drawTank(dc, leftX, cy, tankW, "BATT", battery, true, C_CYAN);

        var bio = getBodyBattery();
        drawTank(dc, rightX, cy, tankW, "BODY", (bio != null) ? bio : 0, (bio != null), C_BIO);

        // --- Sonar ping (active only) ---
        if (!mLowPower) {
            drawSonar(dc, cx, cy, r);
        }

        // --- Optional HUD frame overlay / procedural reticles (active only) ---
        if (!mLowPower && USE_ART_FRAME && mFrameArt != null) {
            dc.drawBitmap(0, 0, mFrameArt);
        } else if (!mLowPower) {
            drawCornerReticles(dc, cx, cy, r);
        }

        // --- Center time (always shown) ---
        drawTime(dc, cx, (h * 0.400).toNumber() + dy);

        // Everything else is hidden in burn-in/AOD to minimize lit pixels.
        if (burnIn) { return; }

        if (mSmall) {
            drawSmallLayout(dc, cx, h, w, settings.notificationCount);
        } else {
            drawRichLayout(dc, cx, h, w, settings.notificationCount);
        }
    }

    // Full AMOLED layout: rich top stack + two dense bottom rows.
    function drawRichLayout(dc as Dc, cx as Number, h as Number, w as Number, notif as Number) as Void {
        // --- Top instrument stack ---
        drawSunLine(dc, cx, (h * 0.110).toNumber());
        drawDateLine(dc, cx, (h * 0.155).toNumber(), notif);
        drawWeatherLine(dc, cx, (h * 0.200).toNumber());
        drawActivityLine(dc, cx, (h * 0.245).toNumber());
        if (mEnableCompass) {
            drawCenteredField(dc, cx, (h * 0.300).toNumber(), "HDG", getHeadingStr());
        }

        // --- DEPTH (barometric elevation) under the time ---
        drawDepthReadout(dc, cx, (h * 0.525).toNumber());

        // --- Bottom field rows ---
        var lx = (w * 0.300).toNumber();
        var mxx = (w * 0.500).toNumber();
        var rx = (w * 0.700).toNumber();
        var row1 = (h * 0.635).toNumber();
        var row2 = (h * 0.745).toNumber();
        // Row 1: PULSE (with resting HR sub) / CAL / FLOORS.
        drawField(dc, lx,  row1, "PULSE",  getHeartStr(),    getRestingHrStr());
        drawField(dc, mxx, row1, "KCAL",   getCaloriesStr(), null);
        drawField(dc, rx,  row1, "FLOORS", getFloorsStr(),   null);
        // Row 2: STRESS / ACTIVE min / PRESS.
        drawField(dc, lx,  row2, "STRESS", getStressStr(),   null);
        drawField(dc, mxx, row2, "ACTIVE", getActiveMinStr(), null);
        drawField(dc, rx,  row2, "PRESS",  getPressureStr(), null);
    }

    // Lean layout for low-res MIP panels: fewer fields, bigger bitmap fonts so every
    // value stays legible. Sun/weather lines and the resting-HR sub are dropped; the
    // most useful fields ride in two roomy rows.
    function drawSmallLayout(dc as Dc, cx as Number, h as Number, w as Number, notif as Number) as Void {
        drawDateLine(dc, cx, (h * 0.150).toNumber(), notif);
        drawActivityLine(dc, cx, (h * 0.225).toNumber());
        if (mEnableCompass) {
            drawCenteredField(dc, cx, (h * 0.300).toNumber(), "HDG", getHeadingStr());
        }

        drawDepthReadout(dc, cx, (h * 0.555).toNumber());

        // Wide column spread (clear of the tank % readouts) with short labels so
        // three fields fit per row without crowding on a 280/260px panel.
        var lx = (w * 0.265).toNumber();
        var mxx = (w * 0.500).toNumber();
        var rx = (w * 0.735).toNumber();
        var row1 = (h * 0.690).toNumber();
        var row2 = (h * 0.820).toNumber();
        // Row 1: HR / TEMP / pressure.
        drawField(dc, lx,  row1, "HR",  getHeartStr(),     null);
        drawField(dc, mxx, row1, "TMP", getTempStr(),      null);
        drawField(dc, rx,  row1, "BAR", getPressureStr(),  null);
        // Row 2: stress / calories / floors.
        drawField(dc, lx,  row2, "STR", getStressStr(),    null);
        drawField(dc, mxx, row2, "CAL", getCaloriesStr(),  null);
        drawField(dc, rx,  row2, "FLR", getFloorsStr(),    null);
    }

    function onPartialUpdate(dc as Dc) as Void {
        var min = System.getClockTime().min;
        if (min == mLastMin) { return; }
        mLastMin = min;
        onUpdate(dc);
    }

    // ------------------------------------------------------------------ Elements

    function drawAbyssBackground(dc as Dc) as Void {
        dc.setColor(BG_CLEAR, BG_CLEAR);
        dc.clear();
        if (mFlat) { return; }
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

    function drawDepthRing(dc as Dc, cx as Number, cy as Number, r as Number, frac as Float) as Void {
        if (frac < 0.0) { frac = 0.0; }
        if (frac > 1.0) { frac = 1.0; }
        var ringR = (r * 0.92).toNumber();

        if (mLowPower) {
            dc.setPenWidth(1);
            dc.setColor(C_AOD, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, ringR);
            return;
        }

        dc.setPenWidth(3);
        dc.setColor(scaleColor(C_CYAN, 0.20), Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, ringR);

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

        var tickInner = ringR - (r * 0.045).toNumber();
        dc.setPenWidth(2);
        dc.setColor(scaleColor(C_CYAN, 0.40), Graphics.COLOR_TRANSPARENT);
        for (var a = 0; a < 360; a += 30) {
            var rad = a * Math.PI / 180.0;
            var ca = Math.cos(rad);
            var sa = Math.sin(rad);
            dc.drawLine(cx + (ringR * ca).toNumber(), cy - (ringR * sa).toNumber(),
                        cx + (tickInner * ca).toNumber(), cy - (tickInner * sa).toNumber());
        }

        var headRad = (90 - frac * 360.0) * Math.PI / 180.0;
        dc.setColor(C_CYAN_BRIGHT, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx + (ringR * Math.cos(headRad)).toNumber(),
                      cy - (ringR * Math.sin(headRad)).toNumber(), (r * 0.018).toNumber() + 2);
    }

    // A vertical segmented tank gauge that fills from the bottom. `high` is the
    // healthy-end color; it warms to amber then red as the level drops.
    function drawTank(dc as Dc, x as Number, cy as Number, tankW as Number,
                      label as String, level as Number, available as Boolean, high as Number) as Void {
        if (level < 0) { level = 0; }
        if (level > 100) { level = 100; }
        var frac = level / 100.0;
        var tankH = (mHeight * 0.34).toNumber();
        var top = cy - tankH / 2;
        var rad = tankW / 2;
        var color = available ? tankColor(level, high) : C_AOD;

        if (mLowPower) {
            dc.setPenWidth(1);
            dc.setColor(C_AOD, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x, top, tankW, tankH, rad);
            if (available) {
                var ly = (top + tankH * (1.0 - frac)).toNumber();
                dc.drawLine(x, ly, x + tankW, ly);
            }
            return;
        }

        dc.setColor(0x06121C, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, top, tankW, tankH, rad);

        if (available && frac > 0.0) {
            var fillH = (tankH * frac).toNumber();
            if (fillH < tankW) { fillH = tankW; }
            var fy = top + tankH - fillH;
            if (!mFlat) {
                dc.setColor(scaleColor(color, 0.35), Graphics.COLOR_TRANSPARENT);
                dc.fillRoundedRectangle(x - 1, fy - 1, tankW + 2, fillH + 2, rad + 1);
            }
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, fy, tankW, fillH, rad);
            dc.setColor(lerpColor(color, 0xFFFFFF, 0.4), Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, fy, tankW, 2);
        }

        dc.setPenWidth(1);
        dc.setColor(0x0A1E2A, Graphics.COLOR_TRANSPARENT);
        for (var i = 1; i < 4; i += 1) {
            var sy = (top + tankH * i / 4.0).toNumber();
            dc.drawLine(x, sy, x + tankW, sy);
        }

        dc.setPenWidth(2);
        dc.setColor(scaleColor(color, 0.7), Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(x, top, tankW, tankH, rad);

        var cxT = x + tankW / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxT, top - (mHeight * 0.042).toNumber(), mFontLabel, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cxT, top + tankH + (mHeight * 0.042).toNumber(), mFontLabel,
            available ? (level.format("%d") + "%") : "--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function tankColor(level as Number, high as Number) as Number {
        if (level <= LOW_PCT) { return C_RED; }
        if (level <= WARN_PCT) {
            return lerpColor(C_RED, C_AMBER, (level - LOW_PCT).toFloat() / (WARN_PCT - LOW_PCT));
        }
        return lerpColor(C_AMBER, high, (level - WARN_PCT).toFloat() / (100 - WARN_PCT));
    }

    function drawSonar(dc as Dc, cx as Number, cy as Number, r as Number) as Void {
        if (USE_ART_SONAR && mSonarArt != null) {
            dc.drawBitmap(0, 0, mSonarArt);
            return;
        }
        if (mFlat) { return; }
        var sec = System.getClockTime().sec;
        var phase = (sec % 3) / 3.0;
        var pingR = (r * 0.30 + phase * r * 0.45).toNumber();
        dc.setPenWidth(2);
        dc.setColor(lerpColor(C_CYAN, C_BG_MID, phase), Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, pingR);
        if (phase < 0.6) {
            dc.setPenWidth(1);
            dc.setColor(lerpColor(C_CYAN, C_BG_MID, phase + 0.3), Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, pingR + (r * 0.05).toNumber());
        }
    }

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
        var is24 = System.getDeviceSettings().is24Hour;
        if (!is24) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        var hourStr = is24 ? hour.format("%02d") : hour.format("%d");
        var timeStr = hourStr + ":" + clock.min.format("%02d");
        dc.setColor(mLowPower ? C_AOD : C_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, mFontTime, timeStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Top line: sunrise / sunset surface-light times, flanking a small sun marker.
    function drawSunLine(dc as Dc, cx as Number, y as Number) as Void {
        var t = getSunTimes();   // [riseStr, setStr]
        var gap = (mWidth * 0.085).toNumber();
        // Sun marker.
        if (!mFlat) {
            dc.setColor(scaleColor(C_AMBER, 0.8), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cx, y, (mWidth * 0.012).toNumber() + 1);
        }
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - gap, y, mFontMicro, t[0],
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cx + gap, y, mFontMicro, t[1],
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Date "dive-log" line, with a small notification badge appended when unread > 0.
    function drawDateLine(dc as Dc, cx as Number, y as Number, notif as Number) as Void {
        var info = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var dateStr = info.day_of_week.toUpper() + "  " + info.month.toUpper() + " " + info.day.format("%d");
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, mFontLabel, dateStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        if (notif != null && notif > 0) {
            var halfW = dc.getTextWidthInPixels(dateStr, mFontLabel) / 2;
            var bx = cx + halfW + (mWidth * 0.050).toNumber();
            var br = (mWidth * 0.026).toNumber() + 1;
            dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(bx, y, br);
            dc.setColor(C_BG_TOP, Graphics.COLOR_TRANSPARENT);
            dc.drawText(bx, y, mFontMicro, (notif > 9) ? "9+" : notif.format("%d"),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // Steps + distance on one compact line ("8.4K   6.2KM").
    function drawActivityLine(dc as Dc, cx as Number, y as Number) as Void {
        var gap = (mWidth * 0.075).toNumber();
        dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - gap, y, mFontLabel, getStepsStr(),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cx + gap, y, mFontLabel, getDistanceStr(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        // Tiny center divider tick.
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, mFontMicro, "/",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawDepthReadout(dc as Dc, cx as Number, y as Number) as Void {
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y - (mHeight * 0.040).toNumber(), mFontLabel, "DEPTH",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_CYAN_BRIGHT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y + (mHeight * 0.012).toNumber(), mFontValue, getElevationStr(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // A small labeled HUD field: dim label above, cyan value below, and an optional
    // dim sub-value (e.g. resting HR under the live pulse) beneath that.
    function drawField(dc as Dc, x as Number, y as Number, label as String,
                       value as String, sub as String or Null) as Void {
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y - (mHeight * 0.026).toNumber(), mFontMicro, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + (mHeight * 0.014).toNumber(), mFontValue, value,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        if (sub != null) {
            dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y + (mHeight * 0.052).toNumber(), mFontMicro, sub,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // Weather line: condition word (left), current temp (center), hi/lo (right).
    function drawWeatherLine(dc as Dc, cx as Number, y as Number) as Void {
        var gap = (mWidth * 0.150).toNumber();
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - gap, y, mFontMicro, getWeatherCondStr(),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, mFontLabel, getTempStr(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx + gap, y, mFontMicro, getWeatherHiLoStr(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Like drawField but single-line label + value (used for the optional heading).
    function drawCenteredField(dc as Dc, cx as Number, y as Number, label as String, value as String) as Void {
        var gap = (mWidth * 0.010).toNumber();
        dc.setColor(C_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - gap, y, mFontLabel, label + " ",
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(C_CYAN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx + gap, y, mFontLabel, value,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ------------------------------------------------------------------- Data

    function getDayFraction() as Float {
        var c = System.getClockTime();
        return (c.hour * 3600 + c.min * 60 + c.sec).toFloat() / 86400.0;
    }

    function getStepFraction() as Float {
        var info = ActivityMonitor.getInfo();
        if (info == null || info.steps == null) { return 0.0; }
        var goal = mStepGoalOverride;
        if (goal <= 0) {
            goal = (info.stepGoal != null && info.stepGoal > 0) ? info.stepGoal : 10000;
        }
        if (goal <= 0) { return 0.0; }
        var f = info.steps.toFloat() / goal.toFloat();
        return (f > 1.0) ? 1.0 : f;
    }

    // Body Battery (0-100) via SensorHistory, or null if unavailable.
    function getBodyBattery() as Number or Null {
        try {
            if ((Toybox has :SensorHistory) && (SensorHistory has :getBodyBatteryHistory)) {
                var iter = SensorHistory.getBodyBatteryHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST });
                if (iter != null) {
                    var sample = iter.next();
                    if (sample != null && sample.data != null) {
                        var v = sample.data.toNumber();
                        if (v < 0) { v = 0; }
                        if (v > 100) { v = 100; }
                        return v;
                    }
                }
            }
        } catch (e) {
        }
        return null;
    }

    // Barometric elevation in meters ("--" if absent). Tweak unit/label here for feet.
    function getElevationStr() as String {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && info.altitude != null) {
                return info.altitude.toNumber().format("%d") + "M";
            }
        } catch (e) {
        }
        return "--";
    }

    function getTempStr() as String {
        try {
            if (Toybox has :Weather) {
                var cond = Weather.getCurrentConditions();
                if (cond != null && cond.temperature != null) {
                    return cond.temperature.format("%d") + "°";
                }
            }
        } catch (e) {
        }
        return "--°";
    }

    // Ambient barometric pressure in millibars / hPa ("--" if absent).
    function getPressureStr() as String {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && (info has :ambientPressure) && info.ambientPressure != null) {
                return (info.ambientPressure / 100.0).toNumber().format("%d");
            }
        } catch (e) {
        }
        return "--";
    }

    function getHeartStr() as String {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && info.currentHeartRate != null) {
                return info.currentHeartRate.format("%d");
            }
        } catch (e) {
        }
        return "--";
    }

    // Resting heart rate from the user profile, shown as "R##" ("--" if absent).
    function getRestingHrStr() as String {
        try {
            if (Toybox has :UserProfile) {
                var p = UserProfile.getProfile();
                if (p != null && (p has :restingHeartRate) && p.restingHeartRate != null) {
                    return "R" + p.restingHeartRate.format("%d");
                }
            }
        } catch (e) {
        }
        return "--";
    }

    // Calories burned today ("--" if absent).
    function getCaloriesStr() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && (info has :calories) && info.calories != null) {
            return info.calories.format("%d");
        }
        return "--";
    }

    // Floors climbed today ("--" if absent).
    function getFloorsStr() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && (info has :floorsClimbed) && info.floorsClimbed != null) {
            return info.floorsClimbed.format("%d");
        }
        return "--";
    }

    // Today's intensity/active minutes (day total) ("--" if absent).
    function getActiveMinStr() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && (info has :activeMinutesDay) && info.activeMinutesDay != null) {
            var am = info.activeMinutesDay;
            if (am.total != null) { return am.total.format("%d"); }
        }
        return "--";
    }

    // Current stress score 0-100 ("--" if absent / not yet measured).
    function getStressStr() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && (info has :stressScore) && info.stressScore != null) {
            return info.stressScore.format("%d");
        }
        return "--";
    }

    // Short condition word ("CLEAR", "RAIN", ...) for the current weather, or "--".
    function getWeatherCondStr() as String {
        try {
            if (Toybox has :Weather) {
                var c = Weather.getCurrentConditions();
                if (c != null && c.condition != null) {
                    return condName(c.condition);
                }
            }
        } catch (e) {
        }
        return "--";
    }

    // Today's forecast high/low, formatted "H24 L11" ("" if absent).
    function getWeatherHiLoStr() as String {
        try {
            if (Toybox has :Weather) {
                var c = Weather.getCurrentConditions();
                if (c != null) {
                    var hi = (c has :highTemperature) ? c.highTemperature : null;
                    var lo = (c has :lowTemperature)  ? c.lowTemperature  : null;
                    if (hi != null && lo != null) {
                        return "H" + hi.format("%d") + " L" + lo.format("%d");
                    }
                }
            }
        } catch (e) {
        }
        return "";
    }

    // Bucket the (large) Weather.CONDITION_* enum into a few compact words.
    function condName(c as Number) as String {
        if (c == Weather.CONDITION_CLEAR || c == Weather.CONDITION_MOSTLY_CLEAR ||
            c == Weather.CONDITION_PARTLY_CLEAR) { return "CLEAR"; }
        if (c == Weather.CONDITION_FAIR) { return "FAIR"; }
        if (c == Weather.CONDITION_PARTLY_CLOUDY || c == Weather.CONDITION_THIN_CLOUDS) {
            return "PT CLD";
        }
        if (c == Weather.CONDITION_CLOUDY || c == Weather.CONDITION_MOSTLY_CLOUDY) {
            return "CLOUDY";
        }
        if (c == Weather.CONDITION_WINDY) { return "WIND"; }
        if (c == Weather.CONDITION_FOG || c == Weather.CONDITION_MIST ||
            c == Weather.CONDITION_HAZE || c == Weather.CONDITION_HAZY) { return "FOG"; }
        if (c == Weather.CONDITION_THUNDERSTORMS || c == Weather.CONDITION_SCATTERED_THUNDERSTORMS ||
            c == Weather.CONDITION_CHANCE_OF_THUNDERSTORMS || c == Weather.CONDITION_SQUALL ||
            c == Weather.CONDITION_HURRICANE || c == Weather.CONDITION_TROPICAL_STORM ||
            c == Weather.CONDITION_TORNADO) { return "STORM"; }
        if (c == Weather.CONDITION_RAIN_SNOW || c == Weather.CONDITION_CHANCE_OF_RAIN_SNOW ||
            c == Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN_SNOW || c == Weather.CONDITION_LIGHT_RAIN_SNOW ||
            c == Weather.CONDITION_HEAVY_RAIN_SNOW || c == Weather.CONDITION_WINTRY_MIX ||
            c == Weather.CONDITION_SLEET || c == Weather.CONDITION_FREEZING_RAIN) { return "MIX"; }
        if (c == Weather.CONDITION_SNOW || c == Weather.CONDITION_LIGHT_SNOW ||
            c == Weather.CONDITION_HEAVY_SNOW || c == Weather.CONDITION_FLURRIES ||
            c == Weather.CONDITION_CHANCE_OF_SNOW || c == Weather.CONDITION_CLOUDY_CHANCE_OF_SNOW ||
            c == Weather.CONDITION_ICE || c == Weather.CONDITION_ICE_SNOW ||
            c == Weather.CONDITION_HAIL) { return "SNOW"; }
        if (c == Weather.CONDITION_RAIN || c == Weather.CONDITION_LIGHT_RAIN ||
            c == Weather.CONDITION_HEAVY_RAIN || c == Weather.CONDITION_DRIZZLE ||
            c == Weather.CONDITION_SHOWERS || c == Weather.CONDITION_LIGHT_SHOWERS ||
            c == Weather.CONDITION_HEAVY_SHOWERS || c == Weather.CONDITION_SCATTERED_SHOWERS ||
            c == Weather.CONDITION_CHANCE_OF_SHOWERS || c == Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN) {
            return "RAIN";
        }
        if (c == Weather.CONDITION_DUST || c == Weather.CONDITION_SAND ||
            c == Weather.CONDITION_SANDSTORM || c == Weather.CONDITION_SMOKE ||
            c == Weather.CONDITION_VOLCANIC_ASH) { return "DUST"; }
        return "--";
    }

    // Today's steps, compact ("8.4K" above 1000).
    function getStepsStr() as String {
        var info = ActivityMonitor.getInfo();
        if (info == null || info.steps == null) { return "--"; }
        var s = info.steps;
        if (s >= 1000) { return (s / 1000.0).format("%.1f") + "K"; }
        return s.format("%d");
    }

    // Today's distance, in km or mi per the device unit setting.
    function getDistanceStr() as String {
        var info = ActivityMonitor.getInfo();
        if (info == null || info.distance == null) { return "--"; }
        var cm = info.distance.toFloat();   // centimeters
        var statute = false;
        try {
            var ds = System.getDeviceSettings();
            statute = (ds has :distanceUnits) && (ds.distanceUnits == System.UNIT_STATUTE);
        } catch (e) {
        }
        if (statute) { return (cm / 160934.0).format("%.1f") + "MI"; }
        return (cm / 100000.0).format("%.1f") + "KM";
    }

    // Heading in degrees, from the last-known position's course-over-ground (uses the
    // Positioning permission we already hold - no extra Sensor permission). Best
    // effort: reads "--" without a recent fix. Off by default (EnableCompass).
    function getHeadingStr() as String {
        try {
            if (Toybox has :Position) {
                var pi = Position.getInfo();
                if (pi != null && (pi has :heading) && pi.heading != null) {
                    var deg = (pi.heading * 180.0 / Math.PI).toNumber();
                    deg = ((deg % 360) + 360) % 360;
                    return deg.format("%d") + "°";
                }
            }
        } catch (e) {
        }
        return "--";
    }

    // ------------------------------------------------------------ Sun times

    // Returns [sunriseStr, sunsetStr] as "HH:MM" (24h), or ["--","--"] with no fix.
    // Uses the last-known position (no live GPS) and a standard sunrise equation.
    function getSunTimes() as Array<String> {
        var loc = getLocationDeg();
        if (loc == null) { return ["--", "--"]; }
        try {
            var g = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
            var tz = System.getClockTime().timeZoneOffset / 3600.0;
            var rise = computeSun(true,  loc[0], loc[1], g.year, g.month, g.day, tz);
            var set  = computeSun(false, loc[0], loc[1], g.year, g.month, g.day, tz);
            return [hhmm(rise), hhmm(set)];
        } catch (e) {
            return ["--", "--"];
        }
    }

    function getLocationDeg() as Array<Double> or Null {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && (info has :currentLocation) && info.currentLocation != null) {
                return info.currentLocation.toDegrees();
            }
        } catch (e) {
        }
        try {
            if (Toybox has :Position) {
                var pi = Position.getInfo();
                if (pi != null && pi.position != null) {
                    return pi.position.toDegrees();
                }
            }
        } catch (e) {
        }
        return null;
    }

    function hhmm(t as Array or Null) as String {
        if (t == null) { return "--"; }
        return t[0].format("%02d") + ":" + t[1].format("%02d");
    }

    // Standard sunrise/sunset equation (NOAA-style), accurate to ~1 minute.
    function computeSun(isRise as Boolean, latD as Double, lonD as Double,
                        year as Number, month as Number, day as Number, tzHours as Float) as Array or Null {
        var lat = latD.toFloat();
        var lon = lonD.toFloat();
        var N = dayOfYear(year, month, day);
        var lngHour = lon / 15.0;
        var t = isRise ? (N + ((6.0 - lngHour) / 24.0)) : (N + ((18.0 - lngHour) / 24.0));
        var M = (0.9856 * t) - 3.289;
        var L = norm360(M + (1.916 * sinD(M)) + (0.020 * sinD(2.0 * M)) + 282.634);
        var RA = norm360(atanD(0.91764 * tanD(L)));
        // Put RA in the same quadrant as L.
        var Lq = (Math.floor(L / 90.0)) * 90.0;
        var RAq = (Math.floor(RA / 90.0)) * 90.0;
        RA = (RA + (Lq - RAq)) / 15.0;
        var sinDec = 0.39782 * sinD(L);
        var cosDec = cosD(asinD(sinDec));
        var zenith = 90.833;
        var cosH = (cosD(zenith) - (sinDec * sinD(lat))) / (cosDec * cosD(lat));
        if (cosH > 1.0 || cosH < -1.0) { return null; }   // no rise/set today
        var H = (isRise ? (360.0 - acosD(cosH)) : acosD(cosH)) / 15.0;
        var T = H + RA - (0.06571 * t) - 6.622;
        var localT = norm24(norm24(T - lngHour) + tzHours);
        var hh = Math.floor(localT).toNumber();
        var mm = Math.round((localT - hh) * 60.0).toNumber();
        if (mm >= 60) { mm -= 60; hh += 1; }
        hh = ((hh % 24) + 24) % 24;
        return [hh, mm];
    }

    function dayOfYear(year as Number, month as Number, day as Number) as Number {
        var cum = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
        var n = cum[month - 1] + day;
        var leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        if (leap && month > 2) { n += 1; }
        return n;
    }

    // Degree-based trig helpers (Math works in radians).
    function sinD(d as Float) as Float { return Math.sin(d * Math.PI / 180.0); }
    function cosD(d as Float) as Float { return Math.cos(d * Math.PI / 180.0); }
    function tanD(d as Float) as Float { return Math.tan(d * Math.PI / 180.0); }
    function asinD(x as Float) as Float { return Math.asin(x) * 180.0 / Math.PI; }
    function acosD(x as Float) as Float { return Math.acos(x) * 180.0 / Math.PI; }
    function atanD(x as Float) as Float { return Math.atan(x) * 180.0 / Math.PI; }
    function norm360(d as Float) as Float { var v = d; while (v < 0.0) { v += 360.0; } while (v >= 360.0) { v -= 360.0; } return v; }
    function norm24(d as Float) as Float { var v = d; while (v < 0.0) { v += 24.0; } while (v >= 24.0) { v -= 24.0; } return v; }

    // ------------------------------------------------------------ Color helpers

    function lerpColor(c1 as Number, c2 as Number, t as Float) as Number {
        if (t < 0.0) { t = 0.0; }
        if (t > 1.0) { t = 1.0; }
        var r1 = (c1 >> 16) & 0xFF; var g1 = (c1 >> 8) & 0xFF; var b1 = c1 & 0xFF;
        var r2 = (c2 >> 16) & 0xFF; var g2 = (c2 >> 8) & 0xFF; var b2 = c2 & 0xFF;
        var r = (r1 + ((r2 - r1) * t)).toNumber();
        var g = (g1 + ((g2 - g1) * t)).toNumber();
        var b = (b1 + ((b2 - b1) * t)).toNumber();
        return (r << 16) | (g << 8) | b;
    }

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
