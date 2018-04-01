#ifndef LINEARSOLVER
#define LINEARSOLVER

#ifdef BATSRUS

#include "linear_solver_wrapper_c.h"
#include "../../srcInterface/multi_ipic3d_domain.h"

void iPIC3D_MaxwellImage(double *vecIn, double *vecOut, int n){
  SimRun[iIPIC]->EM_MaxwellImage(vecIn, vecOut, n);
}

void iPIC3D_PoissonImage(double *vecIn, double *vecOut, int n){
  SimRun[iIPIC]->EM_PoissonImage(vecIn, vecOut, n);
}

void iPIC3D_matvec_weight_correction(double *vecIn, double *vecOut, int n){
  SimRun[iIPIC]->EM_matvec_weight_correction(vecIn, vecOut, n);
}

#endif

#endif
