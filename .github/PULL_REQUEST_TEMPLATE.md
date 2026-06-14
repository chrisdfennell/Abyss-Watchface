<!-- Thanks for contributing to Abyss! -->

## Description

<!-- What does this PR change and why? Link any related issue, e.g. "Closes #12". -->

## Type of change

- [ ] Bug fix
- [ ] New feature (new HUD readout, gauge behavior, sonar/ring change, etc.)
- [ ] Layout / readability improvement
- [ ] New device support
- [ ] Art assets
- [ ] Documentation
- [ ] Other:

## Devices tested

<!-- Abyss targets the tactix 8 (Fenix 8 AMOLED). Please cover both case sizes. -->

- [ ] `fenix847mm` (454×454, 51mm)
- [ ] `fenix843mm` (416×416, 47mm)

## Checklist

- [ ] `.\build.ps1 -Device <device>` compiles with no warnings
- [ ] Verified in the simulator in both active and Always-On / low-power modes
- [ ] Live fields read correctly and degrade gracefully when a value is unavailable
      (O2 gauge from battery; DEPTH / TEMP / PULSE → `--`)
- [ ] Layout holds on both 454 and 416 panels (no clipping at the round edge)
- [ ] Any new generated-art asset still has a procedural fallback (builds without it)
- [ ] Updated `CHANGELOG.md` if this is a user-facing change

## Screenshots

<!-- Before/after simulator screenshots for any visual change (see savescreenshot.ps1). -->
