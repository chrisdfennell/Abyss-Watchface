# Changelog

All notable changes to Abyss are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-06-26

### Added
- **BODY reserve tank**: Body Battery drawn as a second side gauge mirroring the air
  tank (mint → amber → red), read defensively from `SensorHistory`.
- **Top weather line**: short condition word, current temperature, and today's
  forecast high/low from `Weather.getCurrentConditions()`.
- **Sunrise / sunset times**: surface-light readout in the top stack, computed from
  the last-known position with a NOAA-style equation (no live GPS).
- **More data fields**: resting heart rate (as a sub-value under PULSE), calories,
  floors climbed, intensity/active minutes, and stress — each degrading to `--` when
  unavailable.
- **Optional compass HEADING field** (off by default) behind a new
  *Show Compass Heading* setting; the magnetometer is battery-heavy.
- **Responsive MIP layout**: low-resolution Solar panels (280×280 / 260×260) now use
  the device's bold bitmap fonts and a leaner, well-spaced field set so every value
  stays legible, while the AMOLED panels keep the dense vector-font HUD.

### Changed
- **Self-describing gauge labels**: the air/battery tank is now **BATT** (was *O2*)
  and the stamina tank is **BODY**, so the readouts no longer need guessing.
- Declared the `SensorHistory`, `Positioning`, and `UserProfile` permissions required
  by the new data sources.

### Removed
- The reserved **Show Seconds** setting, replaced by the compass toggle.

## [1.0.0]

### Added
- Initial Subnautica-flavored dive-computer HUD watch face for the Garmin tactix 8
  (Fenix 8 AMOLED), supporting both case sizes — 454×454 (51mm) and 416×416 (47mm) —
  plus the Fenix 8 Solar MIP panels (280×280 / 260×260).
- **Outer depth ring**: a descent-gauge arc sweeping the bezel, mapped to the day's
  progress (midnight → now), with tick marks and a leading-edge marker. Switchable to
  a steps-vs-goal source with the `RING_MODE` constant.
- **O2 / air gauge**: the device battery drawn as a draining air-supply tank that
  shifts cyan → amber → red as it empties (thresholds tunable via `O2_WARN` / `O2_LOW`).
- **Center HUD readout**: large 12/24h time (follows the device setting), a **DEPTH**
  line driven by the barometric altimeter, and small **TEMP** (weather) and **PULSE**
  (heart rate) fields, each degrading gracefully to `--` when unavailable.
- **Sonar ping**: a subtle cyan ring that pulses outward in active state, keyed to the
  seconds value and skipped entirely in always-on.
- Procedural abyss-blue gradient background, cyan corner reticles, and an abyss/dive
  themed launcher icon — all drawn in code, scaling to every panel size.
- Always-On / low-power render path: dimmed time, thin depth-ring + O2 outlines, no
  large bright fills and no sonar, with a per-minute burn-in pixel shift (AMOLED only;
  MIP panels always render the full face).
- Optional generated-art pipeline: declared, placeholdered drawables
  (`bg_vignette`, `hud_frame`, `o2_gauge_housing`, `depth_ring`, `sonar_ring`) wired
  behind `USE_ART_*` flags with procedural fallbacks, so the project builds with zero
  art and accepts drop-in PNGs.
- User settings: **Step Goal Override** and a reserved **Show Seconds** toggle.
- Tooling carried over from the build pipeline: `build.ps1`, `run_simulator.bat`, and
  `savescreenshot.ps1` (auto-framed simulator capture for any panel size).
