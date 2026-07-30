---
description: Reuse MacroSolver's Italian surname tokenization in SwimmerSolver
---

# SwimmerSolver name tokenization

When working on `SwimmerSolver` parsing paths in the goggles_admin2 v2 data-fix pipeline:

1. Reuse `MacroSolver`'s Italian surname tokenization everywhere `SwimmerSolver` parses names, including:
   - LT4 strings/hashes
   - LT2 rows
   - relay swimmer fields
2. Handle multi-word Italian surnames such as `DE ROSA|GABRIELE` correctly.
3. Collect fuzzy-match candidates case-insensitively when imported swimmer names use mixed/camel case.
