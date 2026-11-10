#include "route_kernels.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace {

constexpr double kEps = 1e-6;

inline int32_t bucket_of(int32_t t, int32_t bs) {
  return t >= 0 ? t / bs : -((-t + bs - 1) / bs);
}

inline double zone_speed(const float* speeds, int32_t buckets, int32_t zone, int32_t b) {
  return (b < 0 || b >= buckets) ? 1.0 : static_cast<double>(speeds[zone * buckets + b]);
}

// Must mirror TimeDependentTravel.arrive (lib/src/travel_time.dart) exactly.
inline int32_t arrive(const uint16_t* free_flow, int32_t capacity, const uint8_t* zone_of,
                      const float* speeds, int32_t buckets, int32_t bs, int32_t from, int32_t to,
                      int32_t depart) {
  const int32_t work = free_flow[static_cast<int64_t>(from) * capacity + to];
  if (work == 0) return depart;
  const int32_t zi = zone_of[from], zj = zone_of[to];
  double remaining = static_cast<double>(work);
  double t = static_cast<double>(depart);
  int32_t b = bucket_of(depart, bs);
  for (;;) {
    const double v = 0.5 * (zone_speed(speeds, buckets, zi, b) + zone_speed(speeds, buckets, zj, b));
    const int32_t bucket_end = (b + 1) * bs;
    const double reachable = (static_cast<double>(bucket_end) - t) * v;
    if (reachable >= remaining) {
      t += remaining / v;
      break;
    }
    remaining -= reachable;
    t = static_cast<double>(bucket_end);
    b++;
  }
  return static_cast<int32_t>(std::ceil(t - kEps));
}

}  // namespace

extern "C" {

int32_t rk_abi_version(void) { return 1; }

void* rk_alloc(int64_t bytes) {
  if (bytes <= 0) return nullptr;
  const size_t size = (static_cast<size_t>(bytes) + 63) & ~static_cast<size_t>(63);
#if defined(_WIN32)
  void* p = _aligned_malloc(size, 64);
#else
  void* p = std::aligned_alloc(64, size);
#endif
  if (p != nullptr) std::memset(p, 0, size);
  return p;
}

void rk_free(void* ptr) {
#if defined(_WIN32)
  _aligned_free(ptr);
#else
  std::free(ptr);
#endif
}

void rk_td_arrivals(const uint16_t* free_flow, int32_t capacity, const uint8_t* zone_of, const float* speeds,
                    int32_t buckets, int32_t bucket_seconds, const int32_t* from, const int32_t* to,
                    const int32_t* depart, int32_t count, int32_t* out_arrival) {
  for (int32_t k = 0; k < count; k++) {
    out_arrival[k] =
        arrive(free_flow, capacity, zone_of, speeds, buckets, bucket_seconds, from[k], to[k], depart[k]);
  }
}

void rk_td_matrix(const uint16_t* free_flow, int32_t capacity, const uint8_t* zone_of, const float* speeds,
                  int32_t buckets, int32_t bucket_seconds, int32_t n, int32_t depart, int32_t* out) {
  for (int32_t i = 0; i < n; i++) {
    int32_t* row = out + static_cast<int64_t>(i) * n;
    for (int32_t j = 0; j < n; j++) {
      row[j] = arrive(free_flow, capacity, zone_of, speeds, buckets, bucket_seconds, i, j, depart) - depart;
    }
  }
}

}  // extern "C"
