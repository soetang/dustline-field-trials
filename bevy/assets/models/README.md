# Dustline operators

Original procedural character models authored by `scripts/make-operators.py`
using Blender. No external model, texture or animation downloads are required.
Both teams use vertex-coloured, bevelled equipment and separate hip-pivoted legs.
Each model has four material primitives and fewer than 10,000 triangles.

Regenerate with:

```sh
.tools/blender-4.5.13-linux-x64/blender --background --threads 4 --python bevy/scripts/make-operators.py
```

The script also produces `artifacts/operator-preview.png` for visual inspection.
Run `node tests/models-check.js` to check export size, material budgets and pivots.
