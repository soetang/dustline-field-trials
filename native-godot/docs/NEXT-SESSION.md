# End-of-day checkpoint — 5 September 2026

Stopped at the user's request. Do not treat this checkpoint as a released 0.4.

## Playable version

Native 0.3 remains the verified local release. `Play Windows.cmd` selects
`builds/releases/native-ImDCWR/windows/DustlineNative.exe`; the portable ZIP is
`builds/DustlineNative-0.3-Windows.zip`. The pointer has not been changed by 0.4
work. The browser version is untouched.

## Saved work

- `tools/make_operators.py`: original MIT Blender mesh generator for distinct
  CT/T operators; no downloaded characters, textures, or motion capture.
- New foot-origin models, separate hip/knee, upper body, head and weapon pivots.
- `scripts/operator_rig.gd`: travel-driven gait, aim, shot/reload poses, short
  muzzle flash and a falling death pose. No AI/hitbox changes are intended.
- Static box visuals batched by material and 8 m region. Physics bodies remain
  separate. Runtime effects are not batched.
- `tests/render_profile.gd`: warmed static-view native measurements without
  screenshot readbacks in the measured interval.
- `tests/operators_visual.gd`: staged front, quarter, stride and reload captures.

## Evidence and unfinished review

The existing 221 checks and four seeded rounds passed on this checkpoint
(`artifacts/godot-check-EYvTD8/` in the local repository).
Windows Forward+/RTX 2060 rendered the operator pose captures without script
errors. These checks do not yet prove the new rig's anatomy, hand contact,
foot placement, batching transforms or full-package behavior.

Front and stride images were inspected. Team silhouettes and connected limbs
are improved, but pose/hand contact and ground contact still need close review.
The current staged camera has a crate obscuring part of the CT model; improve
the inspection angle before choosing a README release screenshot. Add focused
rig and batching regressions before promoting this work.

The **initial 16 m batching experiment with old 0.3 models**, at 1280×720 on
Windows/RTX 2060, reduced CT draw calls from 3568 to 620 and tunnel draw calls
from 3443 to 471. A-site calls increased from 334 to 447 and its median frame
time increased from 2.525 to 3.345 ms. Therefore groups were tightened to 8 m.
The final 8 m groups plus new models have **not been re-profiled**. Do not quote
the earlier numbers as the performance of this checkpoint or as live-match FPS.
Local raw profiles are in `builds/profiles/`; baseline copies accompany these notes.

Next: inspect/refine the new rig, add targeted tests, repeat the three-view
profile, then build and test a fresh immutable package. Keep native 0.3 available.
