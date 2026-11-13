# Mesh optimization dependency

`Vendor/` contains unmodified `meshoptimizer.h`, `simplifier.cpp`, and `allocator.cpp`
from [meshoptimizer v1.3](https://github.com/zeux/meshoptimizer/tree/v1.3), commit
`9e1f07b159d3cb777f1c67ed31fc11fd117986f4`.

MIT license: [THIRD_PARTY_LICENSE_MESHOPTIMIZER.txt](../../THIRD_PARTY_LICENSE_MESHOPTIMIZER.txt).
Only the macOS importer links this target. No dependency or model is added to firmware.

The C boundary validates counts and indices, uses attribute-aware simplification
with locked borders, and returns indices into the unchanged original vertices.
Normals, UVs and all Morph position deltas participate in the error metric.
The Swift importer compacts every attribute with the same remap and retains all
node transforms and animation tracks. It never overwrites the source GLB.
