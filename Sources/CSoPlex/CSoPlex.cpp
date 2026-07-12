#include "CSoPlex.h"

#include <exception>
#include <string>

#if __has_include(<soplex/soplex.h>)
#include <soplex/soplex.h>
#elif __has_include(<soplex.h>)
#include <soplex.h>
#else
#error "could not find SoPlex headers"
#endif

struct CSoPlexModel
{
   soplex::SoPlex solver;
   std::string lastError;
};

namespace
{
   typedef soplex::SPxSolver::VarStatus VarStatus;

   int fail(CSoPlexModel* model, const char* message)
   {
      if(model != nullptr)
         model->lastError = message;
      return 1;
   }

   int fail(CSoPlexModel* model, const std::exception& error)
   {
      if(model != nullptr)
         model->lastError = error.what();
      return 1;
   }

   bool isValidVarStatus(int status)
   {
      return status >= static_cast<int>(VarStatus::ON_UPPER)
         && status <= static_cast<int>(VarStatus::UNDEFINED);
   }
}

double CSoPlex_infinity(void)
{
   try
   {
      soplex::SoPlex solver;
      return solver.realParam(soplex::SoPlex::INFTY);
   }
   catch(...)
   {
      return 1e100;
   }
}

CSoPlexModel* CSoPlex_newModel(int logToConsole)
{
   try
   {
      CSoPlexModel* model = new CSoPlexModel();
      model->solver.setIntParam(soplex::SoPlex::OBJSENSE, soplex::SoPlex::OBJSENSE_MINIMIZE);
      model->solver.setIntParam(soplex::SoPlex::ALGORITHM, soplex::SoPlex::ALGORITHM_DUAL);
      model->solver.setIntParam(soplex::SoPlex::REPRESENTATION, soplex::SoPlex::REPRESENTATION_AUTO);
      model->solver.setIntParam(soplex::SoPlex::READMODE, soplex::SoPlex::READMODE_REAL);
      model->solver.setIntParam(soplex::SoPlex::SOLVEMODE, soplex::SoPlex::SOLVEMODE_REAL);
      model->solver.setIntParam(soplex::SoPlex::CHECKMODE, soplex::SoPlex::CHECKMODE_REAL);
      model->solver.setIntParam(soplex::SoPlex::SYNCMODE, soplex::SoPlex::SYNCMODE_ONLYREAL);
      model->solver.setIntParam(soplex::SoPlex::SCALER, soplex::SoPlex::SCALER_BIEQUI);
      model->solver.setIntParam(soplex::SoPlex::SIMPLIFIER, soplex::SoPlex::SIMPLIFIER_OFF);
      model->solver.setIntParam(
         soplex::SoPlex::VERBOSITY,
         logToConsole ? soplex::SoPlex::VERBOSITY_NORMAL : soplex::SoPlex::VERBOSITY_ERROR
      );
      return model;
   }
   catch(...)
   {
      return nullptr;
   }
}

void CSoPlex_deleteModel(CSoPlexModel* model)
{
   delete model;
}

int CSoPlex_addColumn(CSoPlexModel* model, double objective, double lower, double upper)
{
   if(model == nullptr)
      return 1;

   try
   {
      soplex::DSVector column(0);
      model->solver.addColReal(soplex::LPCol(objective, column, upper, lower));
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while adding column");
   }
}

int CSoPlex_addColumns(
   CSoPlexModel* model,
   const double* objectives,
   const double* lowers,
   const double* uppers,
   int count
)
{
   if(model == nullptr)
      return 1;
   if(count < 0)
      return fail(model, "negative column count");

   try
   {
      soplex::LPColSet columns(count);
      soplex::DSVector column(0);
      for(int i = 0; i < count; ++i)
         columns.add(objectives[i], lowers[i], column, uppers[i]);
      model->solver.addColsReal(columns);
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while adding columns");
   }
}

int CSoPlex_addRow(
   CSoPlexModel* model,
   const int* indices,
   const double* values,
   int count,
   double lower,
   double upper
)
{
   if(model == nullptr)
      return 1;
   if(count < 0)
      return fail(model, "negative row entry count");

   try
   {
      soplex::DSVector row(count);
      for(int i = 0; i < count; ++i)
      {
         if(values[i] != 0.0)
            row.add(indices[i], values[i]);
      }
      model->solver.addRowReal(soplex::LPRow(lower, row, upper));
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while adding row");
   }
}

int CSoPlex_addRows(
   CSoPlexModel* model,
   const int* rowStarts,
   const int* rowLengths,
   const int* indices,
   const double* values,
   const double* lowers,
   const double* uppers,
   int rowCount,
   int valueCount
)
{
   if(model == nullptr)
      return 1;
   if(rowCount < 0)
      return fail(model, "negative row count");
   if(valueCount < 0)
      return fail(model, "negative row value count");

   try
   {
      soplex::LPRowSet rows(rowCount);
      for(int i = 0; i < rowCount; ++i)
      {
         int start = rowStarts[i];
         int length = rowLengths[i];
         if(start < 0 || length < 0 || start + length > valueCount)
            return fail(model, "invalid row sparse matrix range");
         soplex::DSVector row(length);
         for(int j = 0; j < length; ++j)
            row.add(indices[start + j], values[start + j]);
         rows.add(lowers[i], row, uppers[i]);
      }
      model->solver.addRowsReal(rows);
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while adding rows");
   }
}

int CSoPlex_optimize(CSoPlexModel* model)
{
   if(model == nullptr)
      return -1;

   try
   {
      model->lastError.clear();
      return static_cast<int>(model->solver.optimize());
   }
   catch(const std::exception& error)
   {
      fail(model, error);
      return -1;
   }
   catch(...)
   {
      fail(model, "unknown SoPlex error while optimizing");
      return -1;
   }
}

int CSoPlex_basicBasisStatus(void)
{
   return static_cast<int>(VarStatus::BASIC);
}

int CSoPlex_isOptimalStatus(int status)
{
   return status == static_cast<int>(soplex::SPxSolver::OPTIMAL);
}

int CSoPlex_getPrimal(CSoPlexModel* model, double* values, int count)
{
   if(model == nullptr)
      return 1;
   if(count < 0)
      return fail(model, "negative primal vector size");

   try
   {
      if(!model->solver.getPrimalReal(values, count))
         return fail(model, "SoPlex did not return a primal solution");
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while reading primal solution");
   }
}

int CSoPlex_hasBasis(CSoPlexModel* model)
{
   if(model == nullptr)
      return 0;
   return model->solver.hasBasis() ? 1 : 0;
}

int CSoPlex_getBasis(
   CSoPlexModel* model,
   int* rowStatuses,
   int rowCount,
   int* colStatuses,
   int colCount
)
{
   if(model == nullptr)
      return 1;
   if(rowCount != model->solver.numRowsReal() || colCount != model->solver.numColsReal())
      return fail(model, "basis dimensions do not match model dimensions");
   if(!model->solver.hasBasis())
      return fail(model, "SoPlex has no basis to save");

   try
   {
      VarStatus* rows = reinterpret_cast<VarStatus*>(rowStatuses);
      VarStatus* cols = reinterpret_cast<VarStatus*>(colStatuses);
      model->solver.getBasis(rows, cols);
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while reading basis");
   }
}

int CSoPlex_setBasis(
   CSoPlexModel* model,
   const int* rowStatuses,
   int rowCount,
   const int* colStatuses,
   int colCount
)
{
   if(model == nullptr)
      return 1;
   if(rowCount != model->solver.numRowsReal() || colCount != model->solver.numColsReal())
      return fail(model, "basis dimensions do not match model dimensions");

   for(int i = 0; i < rowCount; ++i)
   {
      if(!isValidVarStatus(rowStatuses[i]))
         return fail(model, "invalid row basis status");
   }
   for(int i = 0; i < colCount; ++i)
   {
      if(!isValidVarStatus(colStatuses[i]))
         return fail(model, "invalid column basis status");
   }

   try
   {
      const VarStatus* rows = reinterpret_cast<const VarStatus*>(rowStatuses);
      const VarStatus* cols = reinterpret_cast<const VarStatus*>(colStatuses);
      model->solver.setBasis(rows, cols);
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while setting basis");
   }
}

int CSoPlex_clearBasis(CSoPlexModel* model)
{
   if(model == nullptr)
      return 1;

   try
   {
      model->solver.clearBasis();
      model->lastError.clear();
      return 0;
   }
   catch(const std::exception& error)
   {
      return fail(model, error);
   }
   catch(...)
   {
      return fail(model, "unknown SoPlex error while clearing basis");
   }
}

int CSoPlex_numberRows(CSoPlexModel* model)
{
   if(model == nullptr)
      return -1;
   return model->solver.numRowsReal();
}

int CSoPlex_numberCols(CSoPlexModel* model)
{
   if(model == nullptr)
      return -1;
   return model->solver.numColsReal();
}

const char* CSoPlex_lastError(CSoPlexModel* model)
{
   if(model == nullptr)
      return "missing SoPlex model";
   return model->lastError.c_str();
}
