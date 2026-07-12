#ifndef C_SOPLEX_H
#define C_SOPLEX_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CSoPlexModel CSoPlexModel;

double CSoPlex_infinity(void);
CSoPlexModel *CSoPlex_newModel(int logToConsole);
void CSoPlex_deleteModel(CSoPlexModel *model);

int CSoPlex_addColumn(CSoPlexModel *model, double objective, double lower, double upper);
int CSoPlex_addColumns(
  CSoPlexModel *model,
  const double *objectives,
  const double *lowers,
  const double *uppers,
  int count
);
int CSoPlex_addRow(
  CSoPlexModel *model,
  const int *indices,
  const double *values,
  int count,
  double lower,
  double upper
);
int CSoPlex_addRows(
  CSoPlexModel *model,
  const int *rowStarts,
  const int *rowLengths,
  const int *indices,
  const double *values,
  const double *lowers,
  const double *uppers,
  int rowCount,
  int valueCount
);
int CSoPlex_optimize(CSoPlexModel *model);
int CSoPlex_isOptimalStatus(int status);
int CSoPlex_getPrimal(CSoPlexModel *model, double *values, int count);
int CSoPlex_hasBasis(CSoPlexModel *model);
int CSoPlex_getBasis(CSoPlexModel *model, int *rowStatuses, int rowCount, int *colStatuses, int colCount);
int CSoPlex_setBasis(
  CSoPlexModel *model,
  const int *rowStatuses,
  int rowCount,
  const int *colStatuses,
  int colCount
);
int CSoPlex_clearBasis(CSoPlexModel *model);
int CSoPlex_basicBasisStatus(void);
int CSoPlex_numberRows(CSoPlexModel *model);
int CSoPlex_numberCols(CSoPlexModel *model);
const char *CSoPlex_lastError(CSoPlexModel *model);

#ifdef __cplusplus
}
#endif

#endif
