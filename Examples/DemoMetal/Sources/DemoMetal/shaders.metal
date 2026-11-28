#include <metal_stdlib>
using namespace metal;

kernel void xtool_verify(
    device const uint *input [[buffer(0)]],
    device uint *output [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    output[id] = input[id] * input[id] + 0x5854; // "XT"
}
