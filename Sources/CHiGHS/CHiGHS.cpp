#include "CHiGHS.h"

#include <highs/Highs.h>

extern "C" HighsInt CHighs_readBasis(void* highs, const char* filename) {
  if (highs == nullptr || filename == nullptr) {
    return kHighsStatusError;
  }
  return static_cast<HighsInt>(reinterpret_cast<Highs*>(highs)->readBasis(filename));
}

extern "C" HighsInt CHighs_writeBasis(void* highs, const char* filename) {
  if (highs == nullptr || filename == nullptr) {
    return kHighsStatusError;
  }
  return static_cast<HighsInt>(reinterpret_cast<Highs*>(highs)->writeBasis(filename));
}
