#ifndef C_HIGHS_H
#define C_HIGHS_H

#include <highs/interfaces/highs_c_api.h>

#ifdef __cplusplus
extern "C" {
#endif

HighsInt CHighs_readBasis(void* highs, const char* filename);
HighsInt CHighs_writeBasis(void* highs, const char* filename);

#ifdef __cplusplus
}
#endif

#endif
