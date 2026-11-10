// Native kernels for the route optimizer, called from Dart via dart:ffi.
//
// Plain C ABI so the same library works from Dart, Flutter (as an FFI
// plugin) and C++ code such as an embedded Valhalla build.
#ifndef ROUTE_KERNELS_H_
#define ROUTE_KERNELS_H_

#include <stdint.h>

#if defined(_WIN32)
#define RK_EXPORT __declspec(dllexport)
#else
#define RK_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Bumped whenever a signature changes; Dart checks it on load.
RK_EXPORT int32_t rk_abi_version(void);

// Zero-initialised, 64-byte aligned memory that Dart views as typed lists.
// Large tables (the travel-time matrix) live here, so native code and Dart
// read the same bytes with no copying.
RK_EXPORT void* rk_alloc(int64_t bytes);
RK_EXPORT void rk_free(void* ptr);

// Time-dependent arrival times for a batch of legs (Ichoua-Gendreau-Potvin).
// Same arithmetic, in the same order, as TimeDependentTravel.arrive in Dart,
// so results are bit-identical.
//
//   free_flow  capacity x capacity free-flow seconds (row-major, uint16)
//   zone_of    zone of every node
//   speeds     zones x buckets speed factors (zone-major)
//   from/to/depart/out_arrival  `count` legs
RK_EXPORT void rk_td_arrivals(const uint16_t* free_flow, int32_t capacity, const uint8_t* zone_of,
                              const float* speeds, int32_t buckets, int32_t bucket_seconds,
                              const int32_t* from, const int32_t* to, const int32_t* depart,
                              int32_t count, int32_t* out_arrival);

// Re-prices every arc of the first `n` nodes for one departure time:
// out[i * n + j] = travel seconds from i to j when leaving at `depart`.
// A full time-dependent snapshot of a round in one call.
RK_EXPORT void rk_td_matrix(const uint16_t* free_flow, int32_t capacity, const uint8_t* zone_of,
                            const float* speeds, int32_t buckets, int32_t bucket_seconds,
                            int32_t n, int32_t depart, int32_t* out);

#ifdef __cplusplus
}
#endif

#endif  // ROUTE_KERNELS_H_
