!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModPartImplicit

  implicit none
  private ! except

  public:: advance_part_impl

contains
  !=============================================================================
  subroutine advance_part_impl

    ! The implicit schemes used in this module are described in detail in
    !
    ! G. Toth, D. L. De Zeeuw, T. I. Gombosi, K. G. Powell, 2006,
    !  Journal of Computational Physics, 217, 722-758, 
    !  doi:10.1016/j.jcp.2006.01.029
    !
    ! and
    !
    ! Keppens, Toth, Botchev, van der Ploeg, 
    ! J. Int. Num. Methods in Fluids, 30, 335-352, 1999
    !
    ! Equation numbers below refer to the latter paper unless stated otherwise.
    !
    ! We solve the MHD equation written as 
    !
    !    dw/dt = R(t)                                                 (1)
    !
    ! by one of the following implicit schemes:
    !
    ! If UseBDF2 is false (and in any case for the 1st time step):
    ! 
    !    w^n+1 = w^n + dt^n*[R^n + ImplCoeff*(R_low^n+1 - R_low^n)]   (4)
    !
    ! where ImplCoeff is a fixed parameter in the [0,1] range. 
    ! Here R is a high order while R_imp is a possibly low order discretization.
    ! The low order scheme is typically the first order Rusanov scheme. 
    !
    ! If UseBDF2 is true (except for the 1st time step):
    !
    !    w^n+1 = w^n + dt^n*[ ImplCoeff*(R^n + R_low^n+1 - R_low^n)
    !
    !                        + (1-ImplCoeff)*(w^n - w^n-1)/dt^n-1]    (8)
    !
    ! where
    !
    !    ImplCoeff = (dt^n + dt^n-1)/(2*dt^n + dt^n-1) 
    !
    ! provides second order time accuracy.
    !
    ! A Newton iteration is used to solve the discrete equations (4) or (8):
    !
    !    w^(k=0) = w^n
    !
    ! Solve
    !
    !    (I - dt*ImplCoeff*dR_low/dw).dw = ImplCoeff*dt*R(w^n) 
    !
    !            + (1-ImplCoeff)*(w^n - w^n-1)*dt/dt^n-1 
    !
    !            + ImplCoeff*dt*[R_low(w^k) - R_low^n] + (w^n - w^k)
    !
    ! for the increment dw. Terms in the second line are only included for BDF2, 
    ! while terms in the third line are zero for the first k=0 iteration.
    !
    ! In each iteration update the iterate as
    !
    !    w^k+1 = w^k + dw
    !
    ! At most NewtonIterMax iterations are done. When the Newton iteration
    ! is finished, the solution is updated as
    !
    !    w^n+1 = w^k
    !
    ! In each iteration the linear problem is solved by a Krylov type iterative 
    ! method.
    !
    ! We use get_residual(.false.,...) to calculate R_expl
    ! and    get_residual(.true.,....) to calculate R_impl

    use ModImplicit
    use ModProcMH, ONLY: iComm, nProc
    use ModMain, ONLY: nBlockMax, nBlockExplAll, time_accurate, &
         n_step, time_simulation, dt, UseDtFixed, DtFixed, DtFixedOrig, Cfl, &
         iNewDecomposition, NameThisComp, &
         test_string, iTest, jTest, kTest, BlkTest, ProcTest, VarTest
    use ModVarIndexes, ONLY: Rho_
    use ModMultifluid, ONLY: select_fluid, iFluid, nFluid, iP
    use ModAdvance, ONLY : State_VGB, Energy_GBI, StateOld_VCB, EnergyOld_CBI, &
         time_BlK, tmp1_BLK, iTypeAdvance_B, iTypeAdvance_BP, &
         SkippedBlock_, ExplBlock_, ImplBlock_, UseUpdateCheck, DoFixAxis
    use ModPhysics, ONLY : No2Si_V, UnitT_
    use ModPointImplicit, ONLY: UsePointImplicit
    use ModLinearSolver, ONLY: solve_linear_multiblock
    use ModEnergy, ONLY: calc_old_pressure, calc_old_energy
    use ModImplHypre, ONLY: hypre_initialize
    use ModMessagePass, ONLY: exchange_messages
    use ModResistivity, ONLY: init_impl_resistivity
    use BATL_lib, ONLY: Unused_B, Unused_BP, Xyz_DGB
    use BATL_size, ONLY: j0_, nJp1_, k0_, nKp1_
    use ModMpi

    real, external :: minval_BLK, minval_loc_BLK

    integer :: iw, implBLK, iBLK, KrylovMatVec
    integer :: NewtonIter
    integer :: iError, iError1
    real    :: dwnrm, local_wnrm(nw), coef1

    logical:: converged

    real :: TimeSimulationOrig

    logical :: DoTest, DoTestMe, DoTestKrylov, DoTestKrylovMe

    logical :: UseUpdateCheckOrig, UsePointImplicitOrig, DoFixAxisOrig

    real    :: pRhoRelativeMin

    integer :: i, j, k, iBlock, iLoc_I(5)

    character(len=20) :: NameSub = 'MH_advance_part_impl'
    !----------------------------------------------------------------------------
    NameSub(1:2) = NameThisComp
    call set_oktest('implicit',DoTest,DoTestMe) 
    if(DoTestMe) write(*,*)NameSub,' starting at step=',n_step

    ! Initialize some variables in ModImplicit
    call implicit_init

    ! Get initial iterate from current state
    call explicit2implicit(0,nI+1,j0_,nJp1_,k0_,nKp1_,Impl_VGB)

    if(DoTestMe)write(*,*)NameSub,': nImplBLK=',nImplBLK
    if(DoTestMe.and.nImplBLK>0)write(*,*)NameSub,': Impl_VGB=',&
         Impl_VGB(:,iTest,jTest,kTest,implBLKtest)

    call MPI_allreduce(nimpl,nimpl_total, 1,MPI_INTEGER,MPI_SUM,iComm,iError)
    wnrm(1:nw)=-1.0
    ! Global norm of current w_(k=0) = w_n
    do iw=1,nw
       local_wnrm(iw)=sum(Impl_VGB(iw,1:nI,1:nJ,1:nK,1:nImplBLK)**2)
    end do
    call MPI_allreduce(local_wnrm, wnrm, nw, MPI_REAL, MPI_SUM, iComm,iError)
    wnrm=sqrt(wnrm/(nimpl_total/nw))
    where(wnrm < smalldouble) wnrm =1.0

    if(DoTestMe)write(*,*)NameSub,': nimpltot, wnrm=',nimpl_total,wnrm

    TimeSimulationOrig = Time_Simulation
    UseUpdateCheckOrig = UseUpdateCheck
    UseUpdateCheck     = .false.

    ! Advance explicitly treated blocks if any
    if(UsePartImplicit .and. nBlockExplALL > 0)then

       if(DoTestMe)write(*,*)NameSub,': advance explicit blocks'

       if(UseBDF2)then

          ! Save the current state into the previous state for BDF2 scheme
          ! This is needed for explicit blocks, because they may become
          ! implicit in the next time step...
          do iBLK=1,nBlock
             if(iTypeAdvance_B(iBLK) /= ExplBlock_)CYCLE
             ImplOld_VCB(:,:,:,:,iBLK) = State_VGB(:,1:nI,1:nJ,1:nK,iBLK)

             if(.not. UseImplicitEnergy) CYCLE
             ! Overwrite pressure with energy
             do iFluid = 1, nFluid
                call select_fluid
                ImplOld_VCB(iP,:,:,:,iBLK) = &
                     Energy_GBI(1:nI,1:nJ,1:nK,iBLK,iFluid)
             end do
          end do
       end if

       if(.not.UsePartImplicit2)then
          ! Select Unused_B = not explicit blocks
          iNewDecomposition=mod(iNewDecomposition+1, 10000)
          Unused_BP(1:nBlockMax,:) = &
               iTypeAdvance_BP(1:nBlockMax,:) /= ExplBlock_
          Unused_B(1:nBlockMax) = Unused_BP(1:nBlockMax,iProc)
       end if

       ! advance explicit blocks, calc timestep 
       if(.not.UseDtFixed)cfl=ExplCfl
       call advance_expl(.true., -1) 

       if(.not.UsePartImplicit2)then
          ! update ghost cells for the implicit blocks to time level n+1
          iNewDecomposition=mod(iNewDecomposition+1, 10000)
          Unused_BP(1:nBlockMax,:) = &
               iTypeAdvance_BP(1:nBlockMax,:) == SkippedBlock_
          Unused_B(1:nBlockMax) = Unused_BP(1:nBlockMax,iProc)
       end if

       call exchange_messages

       ! The implicit scheme is only applied on implicit blocks
       iNewDecomposition=mod(iNewDecomposition+1, 10000)
       Unused_BP(1:nBlockMax,:) = &
            iTypeAdvance_BP(1:nBlockMax,:) /= ImplBlock_
       Unused_B(1:nBlockMax) = Unused_BP(1:nBlockMax,iProc)
    end if

    !\
    ! Advance implicitly treated blocks
    !/

    ! Switch off point implicit scheme while advancing the implicit blocks
    UsePointImplicitOrig = UsePointImplicit
    UsePointImplicit = .false.

    ! Switch off merging the cells around the poles during the implicit solve
    DoFixAxisOrig      = DoFixAxis
    DoFixAxis          = .false.

    ! Use implicit time step
    if(.not.UseDtFixed)Cfl = ImplCfl

    if(UseDtFixed)then
       if(DoTestMe)write(*,*)NameSub,': call getdt_courant'
       call getdt_courant(dtexpl)
       dtexpl = 0.5*dtexpl
       dtcoeff = dt/dtexpl
    else
       if(DoTestMe)write(*,*)NameSub,': no call of getdt_courant'
       dtcoeff = implCFL/0.5
    endif

    if (UseBDF2.and.n_step==n_prev+1) then
       ! For 3 level BDF2 scheme set beta=ImplCoeff if previous state is known
       ImplCoeff = (dt+dt_prev)/(2*dt+dt_prev)
    else
       ImplCoeff = ImplCoeff0
    end if

    ! Advance time to level n+1 in case there is explicit time dependence:
    !   R(U^n+1,t^n+1) = R(U^n,t^n+1) + dR/dU(U^n,t^n+1).(U^n+1 - U^n)
    ! so the Jacobian should be evaliated at t^n+1

    Time_Simulation = TimeSimulationOrig + Dt*No2Si_V(UnitT_)

    if(DoTestMe.and.time_accurate)&
         write(*,*)NameSub,': dtcoeff,dtexpl,dt=',dtcoeff,dtexpl,dt
    if(DoTestMe.and.UseBDF2)write(*,*)NameSub,': n_prev,dt_prev,ImplCoeff=',&
         n_prev,dt_prev,ImplCoeff

    if(.not.UseBDF2)then
       ! Save the current state into ImplOld_VCB so that StateOld_VCB 
       ! can be restored. 
       ! The implicit blocks haven't been updated, so save current state
       do implBLK=1,nImplBlk
          iBLK=impl2iBLK(implBLK)
          ImplOld_VCB(:,:,:,:,iBLK) = Impl_VGB(:,1:nI,1:nJ,1:nK,implBLK)
       end do
    end if

    ! Initialize right hand side and dw. Uses ImplOld_VCB for BDF2 scheme.
    call impl_newton_init

    ! Save previous timestep for 3 level scheme
    if(UseBDF2)then
       n_prev  = n_step
       dt_prev = dt

       ! Save the current state into ImplOld_VCB so that StateOld_VCB 
       ! can be restored. 
       ! The implicit blocks haven't been updated, so save current state
       do implBLK=1,nImplBlk
          iBLK=impl2iBLK(implBLK)
          ImplOld_VCB(:,:,:,:,iBLK) = Impl_VGB(:,1:nI,1:nJ,1:nK,implBLK)
       end do
    endif

    ! Newton-Raphson iteration and iterative linear solver
    dwnrm = bigdouble
    NewtonIter = 0
    do
       NewtonIter = NewtonIter+1;
       if(DoTestMe)write(*,*)NameSub,': NewtonIter=',NewtonIter
       if(NewtonIter > NewtonIterMax)then
          write(*,*)'Newton-Raphson failed to converge NewtonIter=',NewtonIter
          if(time_accurate)call stop_mpi('Newton-Raphson failed to converge')
          exit
       endif
       nnewton=nnewton+1

       ! Calculate Jacobian matrix if required
       if(ImplParam%DoPrecond .and. (NewtonIter==1 .or. NewMatrix))then

          if(NewtonIter>1)then
             ! Update ghost cells for Impl_VGB, 
             ! because it is needed by impl_jacobian
             call implicit2explicit(Impl_VGB(:,1:nI,1:nJ,1:nK,:))
             call exchange_messages
             call explicit2implicit(0,nI+1,j0_,nJp1_,k0_,nKp1_,Impl_VGB)
          end if

          call timing_start('impl_jacobian')

          ! Initialize variables for preconditioner calculation
          call init_impl_resistivity

          ! Calculate approximate dR/dU matrix
          do implBLK = 1, nImplBLK
             call impl_jacobian(implBLK,MAT(1,1,1,1,1,1,implBLK))
          end do
          call timing_stop('impl_jacobian')

          if(DoTest)then
             call MPI_reduce(sum(MAT(:,:,:,:,:,:,1:nImplBLK)**2),coef1,1,&
                  MPI_REAL,MPI_SUM,PROCtest,iComm,iError)
             if(DoTestMe)write(*,*)NameSub,': sum(MAT**2)=',coef1
          end if

       endif

       ! Update rhs and initial dw if required
       if (NewtonIter>1) call impl_newton_loop

       if(DoTestMe.and.nImplBLK>0)write(*,*)NameSub,&
            ': initial dw(test), rhs(test)=',dw(implVARtest),rhs(implVARtest)

       ! solve implicit system

       ! For Newton solver the outer loop has to converge, 
       ! the inner loop only needs to reduce the error somewhat.
       if(UseNewton) ImplParam%ErrorMax = 0.1

       call set_oktest('krylov', DoTestKrylov, DoTestKrylovMe)

       call solve_linear_multiblock(ImplParam, &
            nVar, nDim, nI, nJ, nK, nImplBlk, iComm, &
            impl_matvec, Rhs, Dw, DoTestKrylovMe, MAT)

       if(DoTestMe .and. nImplBLK>0)&
            write(*,*)NameSub,': final     dw(test)=',dw(implVARtest)

       if(ImplParam%iError /= 0 .and. iProc == 0 .and. time_accurate) &
            call error_report(NameSub//': Krylov solver failed, Krylov error', &
            ImplParam%Error, iError1, .true.)

       ! Update w: Impl_VGB(k+1) = Impl_VGB(k) + coeff*dw  
       ! with coeff=1 or coeff<1 from backtracking (for steady state only) 
       ! based on reducing the residual 
       ! ||ResExpl_VCB(Impl_VGB+1)|| <= ||ResExpl_VCB(Impl_VGB)||. 
       ! Also calculates ResImpl_VCB=dtexpl*R_loImpl_VGB+1 
       ! and logical converged.
       call impl_newton_update(dwnrm, converged)

       if(DoTestMe.and.UseNewton) &
            write(*,*)NameSub,': dwnrm, converged=',dwnrm, converged

       if(converged) EXIT
    enddo ! Newton iteration

    ! Make the update conservative
    if(UseConservativeImplicit)call impl_newton_conserve

    ! Put back implicit result into the explicit code
    call implicit2explicit(Impl_VGB(:,1:nI,1:nJ,1:nK,:))

    if(DoFixAxisOrig)call fix_axis_cells

    ! Make explicit part available again for partially explicit scheme
    if(UsePartImplicit)then
       ! Restore Unused_B
       if(.not.UsePartImplicit2)then
          iNewDecomposition=mod(iNewDecomposition-3, 10000)
       else
          iNewDecomposition=mod(iNewDecomposition-1, 10000)
       end if
       Unused_BP(1:nBlockMax,:) = &
            iTypeAdvance_BP(1:nBlockMax,:) == SkippedBlock_
       Unused_B(1:nBlockMax) = Unused_BP(1:nBlockMax,iProc)
    endif

    ! Exchange messages, so ghost cells of all blocks are updated
    call exchange_messages

    if(DoTestMe)write(*,*) NameSub,': nmatvec=',nmatvec
    if(DoTestMe.and.nImplBLK>0)write(*,*)NameSub,': new w=',&
         Impl_VGB(VARtest,Itest,Jtest,Ktest,implBLKtest)
    if(UseNewton.and.DoTestMe)write(*,*)NameSub,': final NewtonIter, dwnrm=',&
         NewtonIter, dwnrm

    ! Restore StateOld and EnergyOld in the implicit blocks
    do implBLK=1,nImplBlk
       iBLK=impl2iBLK(implBLK)
       StateOld_VCB(:,:,:,:,iBLK) = ImplOld_VCB(:,:,:,:,iBLK)

       if(UseImplicitEnergy) then
          do iFluid = 1, nFluid
             call select_fluid
             EnergyOld_CBI(:,:,:,iBLK,iFluid) = ImplOld_VCB(iP,:,:,:,iBLK)
          end do
          call calc_old_pressure(iBlk) ! restore StateOld_VCB(P_...)
       else
          call calc_old_energy(iBlk) ! restore EnergyOld_CBI
       end if
    end do

    if(UseUpdateCheckOrig .and. time_accurate .and. UseDtFixed)then

       ! Calculate the largest relative drop in density or pressure
       do iBLK = 1, nBlock
          if(Unused_B(iBLK)) CYCLE
          ! Check p and rho
          tmp1_BLK(1:nI,1:nJ,1:nK,iBLK)=&
               min(State_VGB(P_,1:nI,1:nJ,1:nK,iBLK) / &
               StateOld_VCB(P_,1:nI,1:nJ,1:nK,iBLK), &
               State_VGB(Rho_,1:nI,1:nJ,1:nK,iBLK) / &
               StateOld_VCB(Rho_,1:nI,1:nJ,1:nK,iBLK) )
       end do

       if(index(Test_String, 'updatecheck') > 0)then
          pRhoRelativeMin = minval_loc_BLK(nProc, tmp1_BLK, iLoc_I)
          if(iLoc_I(5) == iProc)then
             i = iLoc_I(1); j = iLoc_I(2); k = iLoc_I(3); iBlock = iLoc_I(4)
             write(*,*) 'pRhoRelativeMin is at i,j,k,iBlock,iProc = ',iLoc_I
             write(*,*) 'x,y,z =', Xyz_DGB(:,i,j,k,iBlock)
             write(*,*) 'RhoOld,pOld=', StateOld_VCB((/Rho_,P_/),i,j,k,iBlock)
             write(*,*) 'RhoNew,pNew=', State_VGB((/Rho_,P_/),i,j,k,iBlock)
             write(*,*) 'pRhoRelativeMin=', pRhoRelativeMin
          end if
       else
          pRhoRelativeMin = minval_BLK(nProc,tmp1_BLK)
       end if
       if(pRhoRelativeMin < RejectStepLevel .or. ImplParam%iError /= 0)then
          ! Redo step if pressure decreased below RejectStepLevel
          ! or the Krylov iteration failed.
          Dt = 0.0
          ! Do not use previous step in BDF2 scheme
          n_prev = -1
          ! Reset the state variable, the energy and set time_BLK variable to 0
          do iBLK = 1,nBlock
             if(Unused_B(iBLK)) CYCLE
             State_VGB(:,1:nI,1:nJ,1:nK,iBLK)  = StateOld_VCB(:,:,:,:,iBLK)
             Energy_GBI(1:nI,1:nJ,1:nK,iBLK,:) = EnergyOld_CBI(:,:,:,iBLK,:)
             time_BLK(1:nI,1:nJ,1:nK,iBLK)     = 0.0
          end do
          ! Reduce next time step
          DtFixed = RejectStepFactor*DtFixed
          if(index(Test_String, 'updatecheck') > 0) write(*,*) NameSub, &
               ': RejectStepLevel, iError, DtFixed=', &
               RejectStepLevel, ImplParam%iError, DtFixed
       elseif(pRhoRelativeMin < ReduceStepLevel)then
          ! Reduce next time step if pressure is reduced below ReduceStepLevel
          DtFixed = ReduceStepFactor*DtFixed
          if(index(Test_String, 'updatecheck') > 0) write(*,*) NameSub, &
               ': ReduceStepLevel, DtFixed=', ReduceStepLevel, DtFixed
       elseif(pRhoRelativeMin > IncreaseStepLevel .and. Dt == DtFixed)then
          ! Increase next time step if pressure remained above IncreaseStepLevel
          ! and the last step was taken with DtFixed. Do not exceed DtFixedOrig
          DtFixed = min(DtFixedOrig, DtFixed*IncreaseStepFactor)
          if(index(Test_String, 'updatecheck') > 0) write(*,*) NameSub, &
               ': IncreaseStepLevel, DtFixed=', IncreaseStepLevel, DtFixed
       end if

       if(DoTestMe) write(*,*) NameSub,': pRelMin,Dt,DtFixed=',&
            pRhoRelativeMin,Dt*No2Si_V(UnitT_), DtFixed*No2Si_V(UnitT_)
    endif

    ! Advance time by Dt
    Time_Simulation = TimeSimulationOrig + Dt*No2Si_V(UnitT_)

    ! Restore logicals
    UseUpdateCheck   = UseUpdateCheckOrig
    UsePointImplicit = UsePointImplicitOrig
    DoFixAxis        = DoFixAxisOrig

  end subroutine advance_part_impl
  !=============================================================================
  subroutine impl_newton_init

    ! initialization for NR

    use ModProcMH
    use ModMain, ONLY : Itest,Jtest,Ktest,VARtest,n_step,dt,nOrder, &
         UseRadDiffusion
    use ModAdvance, ONLY : FluxType
    use ModImplicit
    use ModMpi
    use ModRadDiffusion, ONLY: IsNewTimestepRadDiffusion

    integer :: i,j,k,n,iw,implBLK,iBLK, iError
    real :: coef1, coef2, q1, q2, q3

    logical :: oktest, oktest_me
    !---------------------------------------------------------------------------
    call set_oktest('impl_newton',oktest,oktest_me)

    ! Calculate high and low order residuals
    ! ResExpl_VCB= dtexpl * R

    if(UseRadDiffusion) IsNewTimestepRadDiffusion = .true.

    !                not low,  dt,  subtract
    call get_residual(.false.,.true.,.true., &
         Impl_VGB(:,1:nI,1:nJ,1:nK,:),ResExpl_VCB)

    if(UseRadDiffusion) IsNewTimestepRadDiffusion = .false.

    if (nOrder==nOrder_Impl .and. FluxType==FluxTypeImpl) then
       ! If R_low=R then ResImpl_VCB = ResExpl_VCB
       ResImpl_VCB(:,:,:,:,1:nImplBLK) = ResExpl_VCB(:,:,:,:,1:nImplBLK)
    else
       ! ResImpl_VCB = dtexpl * R_low
       !                  low,  no dt, subtract
       call get_residual(.true.,.false.,.true., &
            Impl_VGB(:,1:nI,1:nJ,1:nK,:), ResImpl_VCB) 
    endif

    if(oktest_me.and.nImplBLK>0)write(*,*)'ResExpl_VCB,ResImpl_VCB(test)=',&
         ResExpl_VCB(VARtest,Itest,Jtest,Ktest,implBLKtest),&
         ResImpl_VCB(VARtest,Itest,Jtest,Ktest,implBLKtest)

    ! Calculate rhs used for NewtonIter=1
    n=0
    if(UseBDF2.and.n_step==n_prev+1)then
       ! Collect RHS terms from Eq 8 in Paper implvac
       ! Newton-Raphson iteration. The BDF2 scheme implies
       ! beta+alpha=1 and beta=(dt_n+dt_n-1)/(2*dt_n+dt_n-1)
       coef1=ImplCoeff*dtcoeff
       coef2=(1-ImplCoeff)*dt/dt_prev
       do implBLK=1,nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iw=1,nw
          iBLK=impl2iBLK(implBLK)
          n=n+1
          ! For 1st Newton iteration
          ! RHS = dt*(beta*R + alpha*(w_n-w_n-1)/dt_n-1)/wnrm 
          rhs(n)=(coef1*ResExpl_VCB(iw,i,j,k,implBLK) &
               + coef2*(Impl_VGB(iw,i,j,k,implBLK) &
               -        ImplOld_VCB(iw,i,j,k,iBLK)))/wnrm(iw)
       end do; end do; enddo; enddo; enddo

    else
       do implBLK = 1, nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iw = 1, nw
          n=n+1
          ! RHS = dt*R/wnrm for the first iteration
          rhs(n)=ResExpl_VCB(iw,i,j,k,implBLK)*dtcoeff/wnrm(iw)

       end do; end do; enddo; enddo; enddo

    endif

    if(UseNewton .or. UseConservativeImplicit)then
       ! Calculate RHS0 used for RHS when NewtonIter>1
       n=0
       do implBLK=1,nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iw=1,nw
          n=n+1
          !RHS0 = [dt*(R - beta*R_low) + w_n]/wnrm 
          !     = RHS + [-beta*dt*R_low + w_n]/wnrm
          rhs0(n) = rhs(n) + (- ImplCoeff*dtcoeff*ResImpl_VCB(iw,i,j,k,implBLK) &
               + Impl_VGB(iw,i,j,k,implBLK))/wnrm(iw)
       end do; end do; enddo; enddo; enddo
    endif

    if(oktest)then
       call MPI_allreduce(sum(ResImpl_VCB(:,:,:,:,1:nImplBLK)**2),q1,&
            1,MPI_REAL,MPI_SUM,iComm,iError)
       call MPI_allreduce(sum(ResExpl_VCB(:,:,:,:,1:nImplBLK)**2),q2,&
            1,MPI_REAL,MPI_SUM,iComm,iError)
       call MPI_allreduce(sum(rhs(1:nimpl)**2),q3,&
            1,MPI_REAL,MPI_SUM,iComm,iError)

       if(oktest_me)write(*,*)'Sum ResExpl_VCB**2,ResImpl_VCB**2,rhs**2:', &
            q1, q2, q3
    end if

    ! Initial guess for dw = w_n+1 - w_n
    non0dw=.true.
    select case(KrylovInitType)
    case('explicit')
       ! w_n+1-w_n = dt * R_n
       dw(1:nimpl) = rhs(1:nimpl)
    case('scaled')
       ! Like explicit, but amplitude reduced
       ! w_n+1-w_n = dtexpl * R_n
       dw(1:nimpl) = rhs(1:nimpl)/dtcoeff
    case('nul')
       ! w_n+1-w_n = 0
       dw(1:nimpl) = 0.0
       non0dw = .false.
    case('old')
    case default
       call stop_mpi('Unknown type for KrylovInitType='//KrylovInitType)
    end select

  end subroutine impl_newton_init
  !=============================================================================

  subroutine impl_newton_loop

    use ModProcMH
    use ModMain, ONLY : Itest,Jtest,Ktest,VARtest
    use ModImplicit
    use ModMpi

    integer :: i,j,k,iw,implBLK,n, iError
    real    :: q1
    logical :: oktest, oktest_me
    !---------------------------------------------------------------------------
    call set_oktest('impl_newton',oktest,oktest_me)

    ! Caculate RHS for 2nd or later Newton iteration
    n=0
    do implBLK=1,nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iw=1,nw
       n=n+1
       ! RHS = (dt*R_n - beta*dt*R_n_low + w_n + beta*dt*R_k_low - Impl_VGB)/wnrm
       ! use: RHS0 and ResImpl_VCB = dtexpl * R_k_low
       rhs(n)= rhs0(n)+(ImplCoeff*dtcoeff*ResImpl_VCB(iw,i,j,k,implBLK) &
            - Impl_VGB(iw,i,j,k,implBLK))/wnrm(iw)
    enddo; enddo; enddo; enddo; enddo

    if(oktest)then
       call MPI_allreduce(sum(rhs(1:nimpl)**2),q1,1,MPI_REAL,MPI_SUM,&
            iComm,iError)
       if(oktest_me)then
          write(*,*)'norm of rhs:',sqrt(q1/nimpl_total)
          if(nImplBLK>0)write(*,*)'rhs,rhs0,ResImpl_VCB,Impl_VGB(test)=',&
               rhs(implVARtest),rhs0(implVARtest),               &
               ResImpl_VCB(Ktest,VARtest,Itest,Jtest,implBLKtest),  &
               Impl_VGB(VARtest,Itest,Jtest,Ktest,implBLKtest)
       end if
    end if

    ! Initial guess for dw is always zero in later NR iterations
    dw(1:nimpl)=0.0
    non0dw=.false.

  end subroutine impl_newton_loop

  !=============================================================================
  subroutine impl_newton_update(dwnrm, converged)

    ! Update Impl_VGB(k+1) = Impl_VGB(k) + coeff*dw  with coeff from backtracking
    ! such that F(Impl_VGB+1) <= F(Impl_VGB) if possible

    use ModProcMH
    use ModMain, ONLY : nOrder,time_accurate
    use ModAdvance, ONLY : FluxType
    use ModGeometry, ONLY : true_cell
    use ModImplicit
    use ModMpi

    real,    intent(out):: dwnrm
    logical, intent(out):: converged

    integer:: i, j, k, iw, implBLK, n, itry, iError
    real:: coeff, resold, dwnrm_local, wnrm2, resexpl2

    logical :: oktest,oktest_me
    !---------------------------------------------------------------------------

    call set_oktest('impl_newton',oktest,oktest_me)

    if(UseNewton)then
       ! Calculate progress in NR scheme to set linear solver accuracy
       ! dwnrm = ||Impl_VGB(k+1) - Impl_VGB(k)||/||w_n||
       dwnrm_local=sum(dw(1:nimpl)**2)
       call MPI_allreduce(dwnrm_local,dwnrm,1,MPI_REAL,MPI_SUM,iComm,&
            iError)
       dwnrm = sqrt(dwnrm/nimpl_total)
       converged = dwnrm < NewtonErrorMax
       if(oktest_me)write(*,*)'dwnrm:',dwnrm
    else
       converged = .true.
    endif

    ! Initial guess for coeff is limited to avoid non-physical w for pseudo-time
    !if((.not.time_accurate).and.impldwlimit<bigdouble)then
    !  coeff=min(1.0,impldwlimit/(maxval(abs(dw(1:nimpl)))+smalldouble))
    !else
    coeff=1.0
    !endif

    ! For steady state calculations try changing coeff to reduce the residual
    itry=0
    resold=residual
    do
       itry=itry+1
       if(oktest_me)write(*,*)'itry, coeff:',itry,coeff

       ! w=w+dw for all true cells
       n=0
       do implBLK=1,nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iw = 1, nw
          n=n+1
          if(true_cell(i,j,k,impl2iBLK(implBLK)))&
               Impl_VGB(iw,i,j,k,implBLK) = Impl_VGB(iw,i,j,k,implBLK) &
               + coeff*dw(n)*wnrm(iw)
       enddo; enddo; enddo; enddo; enddo

       if(UseConservativeImplicit .or. .not.Converged) then
          !calculate low order residual ResImpl_VCB = dtexpl*RES_low(k+1)
          !                  low,   no dt, subtract
          call get_residual(.true., .false., .true., &
               Impl_VGB(:,1:nI,1:nJ,1:nK,:), ResImpl_VCB)
       end if

       ! Do not backtrack in a time accurate calculation or
       ! if Newton-Raphson converged or no Newton-Raphson is done
       if (time_accurate .or. converged) EXIT

       ! calculate high order residual ResExpl_VCB = dt*R(Impl_VGB(k+1))
       if ( nOrder==nOrder_Impl .and. FluxType==FluxTypeImpl ) then
          ResExpl_VCB(:,:,:,:,1:nImplBLK)=ResImpl_VCB(:,:,:,:,1:nImplBLK)
       else
          !                 not low, no dt, subtract
          call get_residual(.false.,.false.,.true.,Impl_VGB(:,1:nI,1:nJ,1:nK,:),&
               ResExpl_VCB)
       endif

       ! Calculate norm of high order residual
       residual = 0.0
       do iw = 1, nw
          call MPI_allreduce(sum(Impl_VGB(iw,1:nI,1:nJ,1:nK,1:nImplBLK)**2),&
               wnrm2,   1,MPI_REAL,MPI_SUM,iComm,iError)
          call MPI_allreduce(sum(ResExpl_VCB(iw,1:nI,1:nJ,1:nK,1:nImplBLK)**2),&
               resexpl2,1,MPI_REAL,MPI_SUM,iComm,iError)

          if(wnrm2<smalldouble)wnrm2=1.0
          residual = residual + resexpl2/wnrm2
       enddo
       residual=sqrt(residual/nw)
       if(oktest_me)write(*,*)'resold,residual:',resold,residual

       ! Exit if backtracked towards steady-state or giving up
       if(residual<=resold .or. itry>3)exit
       coeff=coeff*0.5
    end do

  end subroutine impl_newton_update

  !==============================================================================
  subroutine impl_newton_conserve

    ! Replace the final Newton iterate Impl_VGB with a flux based conservative update

    use ModImplicit
    use ModGeometry, ONLY : true_cell
    integer :: i,j,k,iw,n,implBLK
    !---------------------------------------------------------------------------

    ! w = Rhs0*wNrm + ImplCoeff*DtCoeff*ResImpl
    !
    ! Rhs0 is the normalized iteration independent part of the right hand side,
    ! which is calculated in impl_newton_init.
    !
    ! wNrm converts each variable from the normalized (second norm=1) 
    ! units to the units used in the explicit part BATSRUS
    !
    ! ResImpl is the (low order) residual obtained from the final newton iterate
    ! with a DtExpl time step. It is calculated in impl_newton_update.
    !
    ! DtCoeff = Dt/DtExpl is used to convert to the implicit time step

    n=0
    do ImplBlk=1,nImplBlk; do k=1,nK; do j=1,nJ; do i=1,nI; do iW=1,nW
       n=n+1
       if(true_cell(i,j,k,impl2iBLK(ImplBlk))) &
            Impl_VGB(iW,i,j,k,ImplBlk) = &
            Rhs0(n)*wNrm(iW) + ImplCoeff*DtCoeff*ResImpl_VCB(iW,i,j,k,ImplBlk)
    enddo; enddo; enddo; enddo; enddo

  end subroutine impl_newton_conserve

  !=============================================================================
  subroutine impl_matvec(x_I, y_I, n)

    ! Calculate y=P_L.A.P_R.x for the iterative solver, where 
    ! P_L and P_R are the left and right preconditioner matrices,
    ! A = I - beta*dt*dR/dw, and R is the residual from dw/dt = R(w).
    !
    ! The multiplication by A is done in a matrix free fashion.

    use ModImplicit
    use ModLinearSolver, ONLY: precond_left_multiblock, precond_right_multiblock

    integer, intent(in):: n
    real, intent(in)   :: x_I(n)
    real, intent(out)  :: y_I(n)

    logical :: DoTest, DoTestMe
    character(len=*), parameter:: NameSub = 'impl_matvec'
    !----------------------------------------------------------------------------
    call set_oktest(NameSub, DoTest, DoTestMe)

    if(DoTestMe)write(*,*)NameSub,': initial n,sum(x**2)=', n, sum(x_I**2)

    if(ImplParam%DoPrecond)then

       ! y = P_R.x, where P_R = I, U^{-1}, or U^{-1}L^{-1}
       ! for left, symmetric and right preconditioning, respectively
       y_I = x_I
       call precond_right_multiblock(ImplParam, &
            nVar, nDim, nI, nJ, nK, nBlock, MAT, y_I)

       ! y = A.y
       call impl_matvec_free(y_I, y_I)

       ! y = P_L.y, where P_L==U^{-1}.L^{-1}, L^{-1}, or I
       ! for left, symmetric, and right preconditioning, respectively
       call precond_left_multiblock(ImplParam, &
            nVar, nDim, nI, nJ, nK, nBlock, MAT, y_I)
    else
       ! y = A.y
       call impl_matvec_free(x_I, y_I)
    end if

    if(DoTestMe)write(*,*)'impl_matvec_prec final n, sum(y**2)=', n, sum(y_I**2)

  end subroutine impl_matvec

  !=============================================================================
  subroutine impl_matvec_free(x_I, y_I)

    ! Calculate y=L.x for the iterative solver, matrix-free 
    ! where L= I - beta*dt*dR/dw   (dt=dt_implicit)
    !
    ! One sided derivative:
    !----------------------
    ! ImplEps_VGB = Impl_VGB + eps*x            ! perturbation
    !
    ! ImplEps_VGB'=ImplEps_VGB + R(ImplEps_VGB,dtexpl)  ! advance ImplEps_VGB
    !
    ! dR/dw.x = (R(w+eps*x)-R(w))/eps 
    !          = [(ImplEps_VGB'-ImplEps_VGB) - (Impl_VGB'-Impl_VGB)]/eps/dtexpl
    !          = (ImplEps_VGB'-Impl_VGB')/eps/dtexpl - x/dtexpl
    !
    ! L.x = dx - beta*dt*dR/dw.x 
    !      = (1 + beta*dtcoeff)*x - beta*dtcoeff*(ImplEps_VGB' - w')/eps
    !
    ! where w=Impl_VGB, w'=w+R_low, beta=ImplCoeff, eps=sqrt(JacobianEps)/||x||
    ! instead of eps=(JacobianEps)^(1/2)*(Impl_VGB.x)/(x.x) suggested by Keyes

    use ModProcMH
    use ModMain, ONLY : Itest, Jtest, Ktest, VARtest
    use ModImplicit
    use ModMpi

    real, intent(in)   :: x_I(nImpl)
    ! Sometimes this subroutine called with the same array in both arguments
    ! that's why the intent of y cannot be set to out.
    real, intent(inout):: y_I(nImpl)

    real, allocatable, save:: ImplEps_VCB(:,:,:,:,:)
    integer:: n, i, j, k, iVar, iBlock, iError
    real:: Eps, xNorm, xNormTotal, Coef1, Coef2

    logical :: DoTest, DoTestMe
    character(len=*), parameter:: NameSub = 'impl_matvec_free'
    !----------------------------------------------------------------------------
    call set_oktest(NameSub, DoTest, DoTestMe)

    call timing_start(NameSub)

    if(.not.allocated(ImplEps_VCB)) &
         allocate(ImplEps_VCB(nVar,nI,nJ,nK,MaxImplBLK))

    xNorm = sum(x_I**2)
    call MPI_allreduce(xNorm, xNormTotal, 1, MPI_REAL, MPI_SUM,iComm,iError)

    if(DoTestMe)write(*,*) NameSub,': initial n,sum(x**2),xNormTotal=', &
         nImpl, xNorm, xNormTotal

    xNorm = sqrt(xNormTotal/nimpl_total)

    if(xNorm < SmallDouble) xNorm = 1.0

    Eps = sqrt(JacobianEps)/xNorm

    if(DoTestMe)write(*,*)'Eps, xNorm =',Eps,xNorm

    n=0
    do iBlock=1,nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iVar=1,nVar
       n = n + 1
       ImplEps_VCB(iVar,i,j,k,iBlock) = Impl_VGB(iVar,i,j,k,iBlock) &
            + Eps*x_I(n)*wnrm(iVar)
    enddo; enddo; enddo; enddo; enddo

    ! Advance ImplEps_VCB:low order,  no dt, don't subtract
    call get_residual(.true., .false., .false., ImplEps_VCB, ImplEps_VCB) 

    ! Calculate y = L.x = (1 + beta*dtcoeff)*x 
    !                       - beta*dtcoeff*(ImplEps_VCB' - Impl_VGB')/eps
    ! where ImplEps_VCB  = Impl_VGB + eps*x, 
    !       ImplEps_VCB' = ImplEps_VCB + dt*R(ImplEps_VCB) and 
    !       Impl_VGB'    = Impl_VGB + dt*R(w)
    ! y = x + beta*dtcoeff*x 
    !       - beta*dtcoeff*(Impl_VGB + eps*x + R(ImplEps_VCB) - w - R(w))/eps
    !   = x - beta*dtcoeff*(R(ImplEps_VCB)-R(Impl_VGB))/eps 
    !   = x - beta*dt*dR/dU*x

    Coef1 = 1 + ImplCoeff*dtcoeff
    Coef2 = ImplCoeff*dtcoeff/Eps

    if(DoTestMe)write(*,*)'dtcoeff,ImplCoeff,Coef1,Coef2=', &
         dtcoeff,ImplCoeff,Coef1,Coef2

    n=0
    do iBlock=1,nImplBLK; do k=1,nK; do j=1,nJ; do i=1,nI; do iVar=1,nVar
       n=n+1
       y_I(n) = Coef1*x_I(n) - Coef2*(ImplEps_VCB(iVar,i,j,k,iBlock) &
            - Impl_VGB(iVar,i,j,k,iBlock) &
            - ResImpl_VCB(iVar,i,j,k,iBlock))/wnrm(iVar)
    enddo; enddo; enddo; enddo; enddo

    call timing_stop(NameSub)

    if(DoTestMe)write(*,*) NameSub,': final n,sum(y**2)=', nImpl, sum(y_I**2)

  end subroutine impl_matvec_free

  !=============================================================================
  subroutine impl_jacobian(implBLK, JAC)

    ! Calculate Jacobian matrix for block implBLK:
    !
    !    JAC = I - dt*beta*dR/dw
    !
    ! using 1st order Rusanov scheme for the residual RES:
    !
    !    R_i = 1./Dx*[                 -(Fx_i+1/2 - Fx_i-1/2 )
    !                + 0.5*cmax_i+1/2 * (W_i+1    - W_i      )
    !                + 0.5*cmax_i-1/2 * (W_i-1    - W_i      )
    !                + 0.5*Q_i        * (Bx_i+1   - Bx_i-1   ) ]
    !         +1./Dy*[...]
    !         +1./Dz*[...]
    !         +S
    !
    ! where W contains the conservative variables, 
    ! Fx, Fy, Fz are the fluxes, cmax is the maximum speed,
    ! Q are the coefficients B, U and U.B in the Powell source terms, and
    ! S are the local source terms.
    !
    !    Fx_i+1/2 = 0.5*(FxL_i+1/2 + FxR_i+1/2)
    !
    ! For first order scheme 
    !
    !    FxL_i+1/2 = Fx[ W_i  , B0_i+1/2 ]
    !    FxR_i+1/2 = Fx[ W_i+1, B0_i+1/2 ]
    !
    ! We neglect terms containing d(cmax)/dW, and obtain a generalized eq.18:
    !
    ! Main diagonal stencil==1:
    !    dR_i/dW_i   = 0.5/Dx*[ (dFxR/dW-cmax)_i-1/2 - (dFxL/dW+cmax)_i+1/2 ]
    !                + 0.5/Dy*[ (dFyR/dW-cmax)_j-1/2 - (dFyL/dW+cmax)_j+1/2 ]
    !                + 0.5/Dz*[ (dFzR/dW-cmax)_k-1/2 - (dFzL/dW+cmax)_k+1/2 ]
    !                + dQ/dW_i*divB
    !                + dS/dW
    !
    ! Subdiagonal stencil==2:
    !    dR_i/dW_i-1 = 0.5/Dx* [ (dFxL/dW+cmax)_i-1/2
    !                           - Q_i*dBx_i-1/dW_i-1 ]
    ! Superdiagonal stencil==3:
    !    dR_i/dW_i+1 = 0.5/Dx* [-(dFxR/dW-cmax)_i+1/2
    !                           + Q_i*dBx_i+1/dW_i+1 ]
    !
    ! and similar terms for stencil=4,5,6,7.
    ! 
    ! The partial derivatives are calculated numerically 
    ! (except for the trivial dQ/dW and dB/dW terms):
    !
    !  dF_iw/dW_jw = [F_iw(W + eps*W_jw) - F_iw(W)] / eps
    !  dS_iw/dW_jw = [S_iw(W + eps*W_jw) - S_iw(W)] / eps

    use ModProcMH
    use ModMain
    use ModNumConst, ONLY: i_DD
    use ModvarIndexes
    use ModAdvance, ONLY: time_BLK
    use ModB0, ONLY: B0_DX, B0_DY, B0_DZ, set_b0_face
    use ModImplicit
    use ModHallResist, ONLY: UseHallResist, hall_factor
    use ModRadDiffusion, ONLY: add_jacobian_rad_diff
    use ModResistivity, ONLY: UseResistivity, add_jacobian_resistivity
    use ModGeometry, ONLY: true_cell
    use BATL_lib, ONLY: IsCartesianGrid, IsRzGeometry, &
         FaceNormal_DDFB, CellSize_DB, CellVolume_GB

    integer, intent(in) :: implBLK
    real,    intent(out):: JAC(nw,nw,nI,nJ,nK,nstencil)

    integer :: iBLK
    real, dimension(nw,nI,nJ,nK)                :: Impl_VC      , ImplEps_VC
    real, dimension(nI+1,nJ+1,nK+1)             :: dfdwLface, dfdwRface
    real, dimension(nw,nI,nJ,nK)                :: s_VC, sEps_VC, sPowell_VC
    real :: DivB(nI,nJ,nK)
    real :: B0_DFD(MaxDim,nI+1,nJ+1,nK+1,MaxDim), Cmax_DF(MaxDim,nI+1,nJ+1,nK+1)

    real   :: qeps, coeff
    logical:: divbsrc, UseDivbSource0
    integer:: i,j,k,i1,i2,i3,j1,j2,j3,k1,k2,k3,istencil,iw,jw,idim,qj

    logical :: oktest, oktest_me

    real :: Dxyz(MaxDim)
    real :: FluxLeft_VFD(nW,nI+1,nJ+1,nK+1,MaxDim) ! Unperturbed left flux
    real :: FluxRight_VFD(nW,nI,nJ,nK,MaxDim)      ! Unperturbed right flux
    real :: FluxEpsLeft_VF(nW,nI+1,nJ+1,nK+1)    ! Perturbed left flux
    real :: FluxEpsRight_VF(nW,nI,nJ,nK)         ! Perturbed right flux
    real :: FaceArea_F(nI, nJ, nK)               ! Only the inner faces

    real :: HallFactor_G(0:nI+1,j0_:nJp1_,k0_:nKp1_)
    !----------------------------------------------------------------------------

    if(iProc==PROCtest.and.implBLK==implBLKtest)then
       call set_oktest('impl_jacobian',oktest, oktest_me)
    else
       oktest=.false.; oktest_me=.false.
    end if

    qeps=sqrt(JacobianEps)

    divbsrc= UseDivbSource

    ! Extract state for this block
    Impl_VC = Impl_VGB(1:nw,1:nI,1:nJ,1:nK,implBLK)
    iBLK = impl2iBLK(implBLK)
    Dxyz = CellSize_DB(:,iBlk)
    if(UseB0)then
       call set_b0_face(iBLK)
       B0_DFD(:,1:nI+1,1:nJ  ,1:nK  ,x_)=B0_DX(:,1:nI+1,1:nJ,1:nK)
       B0_DFD(:,1:nI  ,1:nJ+1,1:nK  ,y_)=B0_DY(:,1:nI,1:nJ+1,1:nK)
       B0_DFD(:,1:nI  ,1:nJ  ,1:nK+1,z_)=B0_DZ(:,1:nI,1:nJ,1:nK+1)
    else
       B0_DFD =0.0
    end if

    if(UseHallResist)call impl_init_hall

    ! Initialize matrix to zero (to be safe)
    JAC = 0.0

    ! Initialize reference flux and the cmax array
    do iDim = 1, nDim

       i1 = 1+i_DD(1,idim); j1= 1+i_DD(2,idim); k1= 1+i_DD(3,idim)
       i2 =nI+i_DD(1,idim); j2=nJ+i_DD(2,idim); k2=nK+i_DD(3,idim);

       call get_face_flux(Impl_VC,B0_DFD(:,i1:i2,j1:j2,k1:k2,idim),&
            nI,nJ,nK,iDim,iBLK,FluxLeft_VFD(:,i1:i2,j1:j2,k1:k2,iDim))

       call get_face_flux(Impl_VC,B0_DFD(:,1:nI,1:nJ,1:nK,iDim),&
            nI,nJ,nK,iDim,iBLK,FluxRight_VFD(:,:,:,:,iDim))

       ! Average w for each cell interface into ImplEps_VC
       i1 = 1-i_DD(1,idim); j1= 1-i_DD(2,idim); k1= 1-i_DD(3,idim)

       ! Calculate orthogonal cmax for each interface in advance
       call get_cmax_face(                            &
            0.5*(Impl_VGB(1:nw, 1:i2, 1:j2, 1:k2,implBLK)+ &
            Impl_VGB(1:nw,i1:nI,j1:nJ,k1:nK,implBLK)),     &
            B0_DFD(:,1:i2,1:j2,1:k2,idim),       &
            i2,j2,k2,idim,iBlk,Cmax_DF(idim,1:i2,1:j2,1:k2))

       ! cmax always occurs as -ImplCoeff*0.5/dx*cmax
       coeff = -0.5 
       Cmax_DF(idim,1:i2,1:j2,1:k2)=coeff*Cmax_DF(idim,1:i2,1:j2,1:k2)
    enddo

    ! Initialize divB and sPowell_VC arrays 
    if(UseB .and. divbsrc)call impl_divbsrc_init

    ! Set s_VC=S(Impl_VC)
    if(implsource)call getsource(iBLK,Impl_VC,s_VC)

    ! The w to be perturbed and jw is the index for the perturbed variable
    ImplEps_VC=Impl_VC

    !DEBUG
    !write(*,*)'Initial ImplEps_VC=Impl_VC'
    !write(*,'(a,8(f10.6))')'Impl_VC(nK)   =', Impl_VC(:,Itest,Jtest,Ktest)
    !write(*,'(a,8(f10.6))')'Impl_VC(nK+1) =', Impl_VC(:,Itest,Jtest,Ktest+1)
    !write(*,'(a,8(f10.6))')'ImplEps_VC(nK)  =',ImplEps_VC(:,Itest,Jtest,Ktest)
    !write(*,'(a,8(f10.6))')'ImplEps_VC(nK+1)=',ImplEps_VC(:,Itest,Jtest,Ktest+1)

    do jw=1,nw; 
       ! Remove perturbation from previous jw if there was a previous one
       if(jw>1)ImplEps_VC(jw-1,:,:,:)=Impl_VC(jw-1,:,:,:)

       ! Perturb new jw variable
       coeff=qeps*wnrm(jw)
       ImplEps_VC(jw,:,:,:) = Impl_VC(jw,:,:,:) + coeff

       do iDim = 1, nDim
          ! Index limits for faces and shifted centers
          i1 = 1+i_DD(1,idim); j1= 1+i_DD(2,idim); k1= 1+i_DD(3,idim)
          i2 =nI+i_DD(1,idim); j2=nJ+i_DD(2,idim); k2=nK+i_DD(3,idim);
          i3 =nI-i_DD(1,idim); j3=nJ-i_DD(2,idim); k3=nK-i_DD(3,idim);

          call get_face_flux(ImplEps_VC,B0_DFD(:,i1:i2,j1:j2,k1:k2,idim),&
               nI,nJ,nK,iDim,iBLK,FluxEpsLeft_VF(:,i1:i2,j1:j2,k1:k2))

          call get_face_flux(ImplEps_VC,B0_DFD(:,1:nI,1:nJ,1:nK,iDim),&
               nI,nJ,nK,iDim,iBLK,FluxEpsRight_VF)

          ! Calculate dfdw=(feps-f0)/eps for each iw variable and both
          ! left and right sides
          do iw = 1, nw

             !call getflux(ImplEps_VC,B0_DFD(:,i1:i2,j1:j2,k1:k2,idim),&
             !     nI,nJ,nK,iw,idim,implBLK,fepsLface(i1:i2,j1:j2,k1:k2))

             !call getflux(ImplEps_VC,B0_DFD(:,1:nI,1:nJ,1:nK,idim),&
             !     nI,nJ,nK,iw,idim,implBLK,fepsRface(1:nI,1:nJ,1:nK))

             ! dfdw = F_iw(W + eps*W_jw) - F_iw(W)] / eps is multiplied by 
             ! -0.5 in all formulae
             Coeff = -0.5/(qeps*wnrm(jw)) 

             dfdwLface(i1:i2,j1:j2,k1:k2) = Coeff*&
                  (FluxEpsLeft_VF(iw,i1:i2,j1:j2,k1:k2) &
                  -  FluxLeft_VFD(iw,i1:i2,j1:j2,k1:k2,iDim)) 
             dfdwRface( 1:nI, 1:nJ, 1:nK) = Coeff*&
                  (FluxEpsRight_VF(iW,1:nI,1:nJ,1:nK) &
                  -  FluxRight_VFD(iW,1:nI,1:nJ,1:nK,iDim))

             if(oktest_me)write(*,'(a,i1,i2,6(f15.8))') &
                  'iw,jw,f0L,fepsL,dfdwL,R:', &
                  iw,jw,&
                  FluxLeft_VFD(iw,Itest,Jtest,Ktest,idim),&
                  FluxEpsLeft_VF(iW,Itest,Jtest,Ktest),&
                  dfdwLface(Itest,Jtest,Ktest),&
                  FluxRight_VFD(iw,Itest,Jtest,Ktest,idim),&
                  FluxEpsRight_VF(iW,Itest,Jtest,Ktest),&
                  dfdwRface(Itest,Jtest,Ktest)

             !DEBUG
             !if(idim==3.and.iw==4.and.jw==2)&
             !write(*,*)'BEFORE addcmax dfdw(iih)=',&
             !          dfdwLface(Itest,Jtest,Ktest-1)

             ! Add contribution of cmax to dfdwL and dfdwR
             if(iw == jw)then
                ! FxL_i-1/2 <-- (FxL + cmax)_i-1/2
                dfdwLface(i1:i2,j1:j2,k1:k2) = dfdwLface(i1:i2,j1:j2,k1:k2)&
                     + Cmax_DF(idim,i1:i2,j1:j2,k1:k2)
                ! FxR_i+1/2 <-- (FxR - cmax)_i+1/2
                dfdwRface(1:nI,1:nJ,1:nK) = dfdwRface(1:nI,1:nJ,1:nK) &
                     - Cmax_DF(idim,1:nI,1:nJ,1:nK)
             endif

             ! Divide flux*area by volume
             dfdwLface(i1:i2,j1:j2,k1:k2) = dfdwLface(i1:i2,j1:j2,k1:k2) &
                  /CellVolume_GB(1:nI,1:nJ,1:nK,iBlk)
             dfdwRface(1:nI,1:nJ,1:nK) = dfdwRface(1:nI,1:nJ,1:nK) &
                  /CellVolume_GB(1:nI,1:nJ,1:nK,iBlk)

             !DEBUG
             !if(idim==3.and.iw==4.and.jw==2)&
             !write(*,*)'AFTER  addcmax dfdwL(iih)=',&
             !           dfdwLface(Itest,Jtest,Ktest-1)

             ! Contribution of fluxes to main diagonal (middle cell)
             ! dR_i/dW_i = 0.5/Dx*[ (dFxR/dW-cmax)_i-1/2 - (dFxL/dW+cmax)_i+1/2 ]

             JAC(iw,jw,:,:,:,1) = JAC(iw,jw,:,:,:,1) &
                  - dfdwRface( 1:nI, 1:nJ, 1:nK)     &
                  + dfdwLface(i1:i2,j1:j2,k1:k2)

             ! Add Q*dB/dw to dfdwL and dfdwR for upper and lower diagonals
             ! These diagonals are non-zero for the inside interfaces only
             ! which corresponds to the range i1:nI,j1:nJ,k1:nK.
             if(UseB    .and. divbsrc .and. &
                  (     (iw >= RhoUx_ .and. iw <= RhoUz_) &
                  .or.  (iW >= Bx_    .and. iW <= Bz_   ) &
                  .or.  (iw == E_ .and. UseImplicitEnergy) &
                  ) )then
                if(.not.IsCartesianGrid .and. jw>=Bx_ .and. jw<=B_+nDim)then
                   ! The source terms are always multiplied by coeff
                   coeff=-0.5
                   ! Get the corresponding face area
                   FaceArea_F(i1:nI,j1:nJ,k1:nK) = &
                        FaceNormal_DDFB(jw-B_,iDim,i1:nI,j1:nJ,k1:nK,iBLK)

                   ! Relative to the right face flux Q is shifted to the left
                   dfdwLface(i1:nI,j1:nJ,k1:nK)=dfdwLface(i1:nI,j1:nJ,k1:nK)+ &
                        coeff*sPowell_VC(iw,i1:nI,j1:nJ,k1:nK) &
                        *FaceArea_F(i1:nI,j1:nJ,k1:nK) &
                        /CellVolume_GB(i1:nI,j1:nJ,k1:nK,iBlk)

                   dfdwRface(i1:nI,j1:nJ,k1:nK)=dfdwRface(i1:nI,j1:nJ,k1:nK)+ &
                        coeff*sPowell_VC(iw, 1:i3, 1:j3, 1:k3) &
                        *FaceArea_F(i1:nI,j1:nJ,k1:nK) &
                        /CellVolume_GB(1:i3,1:j3,1:k3,iBlk)

                elseif(jw==B_+idim)then
                   ! The source terms are always multiplied by coeff
                   coeff=-0.5/dxyz(idim)

                   ! Relative to the right face flux Q is shifted to the left
                   dfdwLface(i1:nI,j1:nJ,k1:nK)=dfdwLface(i1:nI,j1:nJ,k1:nK)+ &
                        coeff*sPowell_VC(iw,i1:nI,j1:nJ,k1:nK)

                   dfdwRface(i1:nI,j1:nJ,k1:nK)=dfdwRface(i1:nI,j1:nJ,k1:nK)+ &
                        coeff*sPowell_VC(iw, 1:i3, 1:j3, 1:k3)
                end if
             end if
             JAC(iw,jw,i1:nI,j1:nJ,k1:nK,2*idim  )= -dfdwLface(i1:nI,j1:nJ,k1:nK)
             JAC(iw,jw, 1:i3, 1:j3, 1:k3,2*idim+1)= +dfdwRface(i1:nI,j1:nJ,k1:nK)
          enddo ! iw
       enddo ! idim
       if(oktest_me)then
          write(*,*)'After fluxes jw=',jw,' stencil, row, JAC'
          do istencil=1,nstencil
             do qj=1,nw
                write(*,'(i1,a,i1,a,20(f9.5))')istencil,',',qj,':',&
                     JAC(:,qj,Itest,Jtest,Ktest,istencil)
             end do
          enddo
       endif

       !Derivatives of local source terms 
       if(implsource)then
          if(oktest_me)write(*,*)'Adding dS/dw'

          ! w2=S(Impl_VC+eps*W_jw)
          call getsource(iBLK,ImplEps_VC,sEps_VC)
          coeff = 1.0/(qeps*wnrm(jw))
          do iw = 1, nw
             ! JAC(..1) += dS/dW_jw
             JAC(iw,jw,:,:,:,1)=JAC(iw,jw,:,:,:,1)&
                  + coeff*(sEps_VC(iw,:,:,:) - s_VC(iw,:,:,:))
          enddo
       endif
    enddo

    if(oktest_me)write(*,*)'After fluxes and sources:  JAC(...,1):', &
         JAC(1:nw,1:nw,Itest,Jtest,Ktest,1)

    ! Contribution of middle to Powell's source terms
    if(UseB .and. divbsrc)then
       ! JAC(...1) += d(Q/divB)/dW*divB
       call impl_divbsrc_middle

       if(oktest_me)then
          write(*,*)'After divb sources: row, JAC(...,1):'
          do qj=1,nw
             write(*,'(i1,a,20(f9.5))')qj,':',&
                  JAC(:,qj,Itest,Jtest,Ktest,1)
          end do
       end if
    end if

    ! Add extra terms for (Hall) resistivity
    if(UseResistivity .or. UseHallResist) &
         call add_jacobian_resistivity(iBlk, nVar, JAC)

    ! Add extra terms for radiative diffusion
    if(UseRadDiffusion) &
         call add_jacobian_rad_diff(iBLK, nVar, JAC)

    ! Multiply JAC by the implicit timestep dt, ImplCoeff, wnrm, and -1
    if(time_accurate)then
       do iStencil = 1, nStencil; do k=1,nK; do j=1,nJ; do i=1,nI
          if(true_cell(i,j,k,iBLK))then
             do jw=1,nw; do iw=1,nw
                JAC(iw,jw,i,j,k,iStencil) = -JAC(iw,jw,i,j,k,iStencil) &
                     *dt*ImplCoeff*wnrm(jw)/wnrm(iw)
             end do; end do
          else
             ! Set JAC = 0.0 inside body
             JAC(:,:,i,j,k,iStencil) = 0.0
          end if
       end do; end do; end do; end do
    else
       ! Local time stepping has time_BLK=0.0 inside the body
       do iStencil = 1, nStencil; do k=1,nK; do j=1,nJ; do i=1,nI
          do jw=1,nw; do iw=1,nw
             JAC(iw,jw,i,j,k,istencil) = -JAC(iw,jw,i,j,k,istencil) &
                  *time_BLK(i,j,k,iBLK)*implCFL*ImplCoeff*wnrm(jw)/wnrm(iw)
          end do; end do; 
       end do; end do; end do; end do
    endif

    if(oktest_me)then
       write(*,*)'After boundary correction and *dt: row, JAC(...,1):'
       do qj=1,nw
          write(*,'(i1,a,20(f9.5))')qj,':',&
               JAC(:,qj,Itest,Jtest,Ktest,1)
       end do
    end if

    ! Add unit matrix to main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       do iw = 1, nw
          JAC(iw,iw,i,j,k,1) = JAC(iw,iw,i,j,k,1) + 1.0
       end do
    end do; end do; end do

    if(oktest_me)then
       write(*,*)'After adding I: row, JAC(...,1):'
       do qj=1,nw
          write(*,'(i1,a,20(f9.5))')qj,':',&
               JAC(:,qj,Itest,Jtest,Ktest,1)
       end do
    end if

    ! Restore UseDivbSource
    if(UseB .and. divbsrc)UseDivbSource=UseDivbSource0

  contains

    !===========================================================================
    subroutine impl_divbsrc_init

      ! Switch off UseDivbSource for addsource
      UseDivbSource0=UseDivbSource
      UseDivbSource=.false.

      ! Calculate div B for middle cell contribution to Powell's source terms
      if(IsCartesianGrid)then
         if(IsRzGeometry)call CON_stop('impl_divbsrc_init not working for RZ')

         divb = &
              ( Impl_VGB(Bx_,2:nI+1,1:nJ,1:nK,implBLK)           &
              - Impl_VGB(Bx_,0:nI-1,1:nJ,1:nK,implBLK))/dxyz(x_)
         if(nJ>1) divb = divb &
              +(Impl_VGB(By_,1:nI,2:nJ+1,1:nK,implBLK)           &
              - Impl_VGB(By_,1:nI,0:nJ-1,1:nK,implBLK))/dxyz(y_)
         if(nK>1) divb = divb &
              +(Impl_VGB(Bz_,1:nI,1:nJ,2:nK+1,implBLK)           &
              - Impl_VGB(Bz_,1:nI,1:nJ,0:nK-1,implBLK))/dxyz(z_)
         divb=0.5*divb

      else
         do k=1,nK; do j=1,nJ; do i=1,nI
            divb(i,j,k) = &
                 sum (Impl_VGB(Bx_:B_+nDim,i+1,j,k,implBLK) &
                 *    FaceNormal_DDFB(:,1,i+1,j,k,iBlk))&
                 -sum(Impl_VGB(Bx_:B_+nDim,i-1,j,k,implBLK) &
                 *    FaceNormal_DDFB(:,1,i,j,k,iBlk))  &
                 +sum(Impl_VGB(Bx_:B_+nDim,i,j+1,k,implBLK) &
                 *    FaceNormal_DDFB(:,2,i,j+1,k,iBlk))&
                 -sum(Impl_VGB(Bx_:B_+nDim,i,j-1,k,implBLK) &
                 *    FaceNormal_DDFB(:,2,i,j,k,iBlk))

            if(nK>1) divb(i,j,k) = divb(i,j,k) &
                 +sum(Impl_VGB(Bx_:B_+nDim,i,j,k+1,implBLK) &
                 *    FaceNormal_DDFB(:,3,i,j,k+1,iBlk))&
                 -sum(Impl_VGB(Bx_:B_+nDim,i,j,k-1,implBLK) &
                 *    FaceNormal_DDFB(:,3,i,j,k,iBlk))

            divb(i,j,k) = 0.5/CellVolume_GB(i,j,k,iBlk)*divb(i,j,k)

         end do; end do; end do
      end if

      ! Make sure that sPowell_VC is defined for all indexes
      sPowell_VC = 0.0
      do k=1,nK; do j=1,nJ; do i=1,nI
         ! Calculate coefficients Q that multiply div B in Powell source terms
         ! Q(rhoU)= B
         sPowell_VC(RhoUx_:RhoUz_,i,j,k)=Impl_VC(Bx_:Bz_,i,j,k)

         ! Q(B)   = U
         sPowell_VC(Bx_:Bz_,i,j,k) = Impl_VC(RhoUx_:RhoUz_,i,j,k) &
              /Impl_VC(Rho_,i,j,k) 

         if(.not. UseImplicitEnergy) CYCLE
         ! Q(E)   = U.B
         sPowell_VC(E_,i,j,k) = &
              sum(Impl_VC(Bx_:Bz_,i,j,k)*Impl_VC(RhoUx_:RhoUz_,i,j,k)) &
              /Impl_VC(Rho_,i,j,k)
      end do; end do; end do

    end subroutine impl_divbsrc_init

    !===========================================================================
    subroutine impl_divbsrc_middle

      integer:: i,j,k

      ! JAC(...1) += dQ/dW_i*divB

      ! Q(rhoU)= -divB*B
      ! dQ(rhoU)/dB = -divB
      do k=1,nK; do j=1,nJ; do i=1,nI
         JAC(rhoUx_,Bx_,i,j,k,1)=JAC(rhoUx_,Bx_,i,j,k,1)&
              - divb(i,j,k) 
         JAC(rhoUy_,By_,i,j,k,1)=JAC(rhoUy_,By_,i,j,k,1)&
              - divb(i,j,k) 
         JAC(rhoUz_,Bz_,i,j,k,1)=JAC(rhoUz_,Bz_,i,j,k,1)&
              - divb(i,j,k) 

         ! Q(B)= -divB*rhoU/rho
         ! dQ(B)/drho = +divB*rhoU/rho**2
         JAC(Bx_,rho_,i,j,k,1)=JAC(Bx_,rho_,i,j,k,1) &
              + divb(i,j,k) &
              *Impl_VC(rhoUx_,i,j,k)/Impl_VC(rho_,i,j,k)**2
         JAC(By_,rho_,i,j,k,1)=JAC(By_,rho_,i,j,k,1) &
              + divb(i,j,k) &
              *Impl_VC(rhoUy_,i,j,k)/Impl_VC(rho_,i,j,k)**2
         JAC(Bz_,rho_,i,j,k,1)=JAC(Bz_,rho_,i,j,k,1) &
              + divb(i,j,k) &
              *Impl_VC(rhoUz_,i,j,k)/Impl_VC(rho_,i,j,k)**2

         ! dQ(B)/drhoU= -divB/rho
         JAC(Bx_,rhoUx_,i,j,k,1)=JAC(Bx_,rhoUx_,i,j,k,1)&
              - divb(i,j,k)/Impl_VC(rho_,i,j,k) 
         JAC(By_,rhoUy_,i,j,k,1)=JAC(By_,rhoUy_,i,j,k,1)&
              - divb(i,j,k)/Impl_VC(rho_,i,j,k) 
         JAC(Bz_,rhoUz_,i,j,k,1)=JAC(Bz_,rhoUz_,i,j,k,1)&
              - divb(i,j,k)/Impl_VC(rho_,i,j,k) 

         if(.not.UseImplicitEnergy) CYCLE

         ! Q(E)= -divB*rhoU.B/rho
         ! dQ(E)/drho = +divB*rhoU.B/rho**2
         JAC(E_,rho_,i,j,k,1)=JAC(E_,rho_,i,j,k,1)&
              + divb(i,j,k)*&
              (Impl_VC(rhoUx_,i,j,k)*Impl_VC(Bx_,i,j,k)&
              +Impl_VC(rhoUy_,i,j,k)*Impl_VC(By_,i,j,k)&
              +Impl_VC(rhoUz_,i,j,k)*Impl_VC(Bz_,i,j,k))&
              /Impl_VC(rho_,i,j,k)**2

         ! dQ(E)/drhoU = -divB*B/rho
         JAC(E_,rhoUx_,i,j,k,1)=JAC(E_,rhoUx_,i,j,k,1) &
              - divb(i,j,k) &
              *Impl_VC(Bx_,i,j,k)/Impl_VC(rho_,i,j,k) 
         JAC(E_,rhoUy_,i,j,k,1)=JAC(E_,rhoUy_,i,j,k,1) &
              - divb(i,j,k) &
              *Impl_VC(By_,i,j,k)/Impl_VC(rho_,i,j,k) 
         JAC(E_,rhoUz_,i,j,k,1)=JAC(E_,rhoUz_,i,j,k,1) &
              - divb(i,j,k) &
              *Impl_VC(Bz_,i,j,k)/Impl_VC(rho_,i,j,k) 

         ! dQ(E)/dB = -divB*rhoU/rho
         JAC(E_,Bx_,i,j,k,1)=JAC(E_,Bx_,i,j,k,1) &
              - divb(i,j,k) &
              *Impl_VC(rhoUx_,i,j,k)/Impl_VC(rho_,i,j,k) 
         JAC(E_,By_,i,j,k,1)=JAC(E_,By_,i,j,k,1) &
              - divb(i,j,k) &
              *Impl_VC(rhoUy_,i,j,k)/Impl_VC(rho_,i,j,k) 
         JAC(E_,Bz_,i,j,k,1)=JAC(E_,Bz_,i,j,k,1) &
              - divb(i,j,k) &
              *Impl_VC(rhoUz_,i,j,k)/Impl_VC(rho_,i,j,k) 
      end do; end do; end do

    end subroutine impl_divbsrc_middle

    !===========================================================================
    subroutine impl_init_hall

      ! Calculate cell centered currents to be used by getflux

      use ModHallResist, ONLY: HallJ_CD, IonMassPerCharge_G, &
           set_ion_mass_per_charge

      use ModGeometry, ONLY: DgenDxyz_DDC, set_block_jacobian_cell 

      real :: DbDgen_DD(3,3)                     

      real :: InvDx2, InvDy2, InvDz2

      logical :: DoTest, DoTestMe
      character(len=*), parameter:: NameSub='impl_init_hall'
      !----------------------------------------------------------------------
      if(iProc == PROCtest.and.implBLK==implBLKtest)then
         call set_oktest(NameSub, DoTest, DoTestMe)
      else
         DoTest = .false.; DoTestMe = .false.
      end if

      call set_ion_mass_per_charge(iBlk)

      InvDx2 = 0.5/Dxyz(x_); InvDy2 = 0.5/Dxyz(y_); InvDz2 = 0.5/Dxyz(z_)

      if(IsCartesianGrid)then

         do k=1,nK; do j=1,nJ; do i=1,nI
            ! Jx = dBz/dy - dBy/dz
            if(nJ>1) HallJ_CD(i,j,k,x_) =                    &
                 +InvDy2*(Impl_VGB(Bz_,i,j+1,k,implBLK)      &
                 -        Impl_VGB(Bz_,i,j-1,k,implBLK))
            if(nK>1) HallJ_CD(i,j,k,x_) = HallJ_CD(i,j,k,x_) &
                 -InvDz2*(Impl_VGB(By_,i,j,k+1,implBLK)      &
                 -        Impl_VGB(By_,i,j,k-1,implBLK))
         end do; end do; end do

         do k=1,nK; do j=1,nJ; do i=1,nI
            ! Jy = dBx/dz - dBz/dx
            HallJ_CD(i,j,k,y_) = &
                 -InvDx2*(Impl_VGB(Bz_,i+1,j,k,implBLK)      &
                 -        Impl_VGB(Bz_,i-1,j,k,implBLK))
            if(nK>1) HallJ_CD(i,j,k,y_) = HallJ_CD(i,j,k,y_) &
                 +InvDz2*(Impl_VGB(Bx_,i,j,k+1,implBLK)      &
                 -        Impl_VGB(Bx_,i,j,k-1,implBLK))
         end do; end do; end do

         do k=1,nK; do j=1,nJ; do i=1,nI
            ! Jz = dBy/dx - dBx/dy
            HallJ_CD(i,j,k,z_) = &
                 +InvDx2*(Impl_VGB(By_,i+1,j,k,implBLK)      &
                 -        Impl_VGB(By_,i-1,j,k,implBLK))
            if(nJ>1) HallJ_CD(i,j,k,z_) = HallJ_CD(i,j,k,z_) &
                 -InvDy2*(Impl_VGB(Bx_,i,j+1,k,implBLK)      &
                 -        Impl_VGB(Bx_,i,j-1,k,implBLK))
         end do; end do; end do

      else                                        

         call set_block_jacobian_cell(iBlk)

         DbDgen_DD = 0.0 !!! make it MaxDim*nDim and use Dim1_, Dim2_, Dim3_

         do k=1,nK; do j=1,nJ; do i=1,nI
            DbDgen_DD(:,1) = InvDx2*&
                 (Impl_VGB(Bx_:Bz_,i+1,j,k,implBLK) &
                 -Impl_VGB(Bx_:Bz_,i-1,j,k,implBLK))
            if(nJ>1) DbDgen_DD(:,2) = InvDy2* &
                 (Impl_VGB(Bx_:Bz_,i,j+1,k,implBLK) &
                 -Impl_VGB(Bx_:Bz_,i,j-1,k,implBLK))
            if(nK>1) DbDgen_DD(:,3) = InvDz2* &
                 (Impl_VGB(Bx_:Bz_,i,j,k+1,implBLK) &
                 -Impl_VGB(Bx_:Bz_,i,j,k-1,implBLK))

            ! Jx = dBz/dy - dBy/dz
            if(nJ>1) HallJ_CD(i,j,k,x_) = &
                 + sum(DbDgen_DD(z_,:)*DgenDxyz_DDC(:,y_,i,j,k)) 
            if(nK>1) HallJ_CD(i,j,k,x_) = HallJ_CD(i,j,k,x_) &
                 - sum(DbDgen_DD(y_,:)*DgenDxyz_DDC(:,z_,i,j,k))

            ! Jy = dBx/dz - dBz/dx
            HallJ_CD(i,j,k,y_) = &
                 - sum(DbDgen_DD(z_,:)*DgenDxyz_DDC(:,x_,i,j,k))
            if(nK>1)HallJ_CD(i,j,k,y_) = HallJ_CD(i,j,k,y_) &
                 + sum(DbDgen_DD(x_,:)*DgenDxyz_DDC(:,z_,i,j,k))

            ! Jz = dBy/dx - dBx/dy
            HallJ_CD(i,j,k,z_) = &
                 + sum(DbDgen_DD(y_,:)*DgenDxyz_DDC(:,x_,i,j,k)) 
            if(nJ>1) HallJ_CD(i,j,k,z_) = HallJ_CD(i,j,k,z_) &
                 - sum(DbDgen_DD(x_,:)*DgenDxyz_DDC(:,y_,i,j,k))

         end do; end do; end do

      end if
      if(DoTestMe) write(*,*) NameSub,' HallJ_CD=',HallJ_CD(iTest,jTest,kTest,:)

      do k = k0_,nKp1_; do j=j0_,nJp1_; do i=0,nI+1
         HallFactor_G(i,j,k) = hall_factor(0,i,j,k,iBlk)
      end do; end do; end do

      !write(*,*)'iBlock, max(IonMassPerCh), max(HallFactor), max(HallJ) =', &
      !     implBlk,&
      !     maxval(IonMassPerCharge_G(1:nI,1:nJ,1:nK)),&
      !     maxval(abs(HallJ_CD(:,:,:,:)))

      do k=1,nK; do j=1,nJ; do i=1,nI
         HallJ_CD(i,j,k,:) = IonMassPerCharge_G(i,j,k) &
              *HallFactor_G(i,j,k)*HallJ_CD(i,j,k,:)
      end do; end do; end do

      !write(*,*)'iBlock, max(HallJ)=',implBlk,maxval(abs(HallJ_CD(:,:,:,:)))

    end subroutine impl_init_hall

  end subroutine impl_jacobian
  !===========================================================================
  subroutine implicit_init

    ! Set number of implicit blocks and variables, 
    ! and conversion array between explicit and implicit block indices
    ! The implicit blocks are contiguous (all used) from 1 ... nImplBLK

    use ModMain
    use ModImplicit
    use ModAdvance, ONLY: iTypeAdvance_B, ImplBlock_

    logical :: IsInitialized=.false.
    integer :: iBLK, iBlockImpl
    !---------------------------------------------------------------------------

    nImplBLK=count(iTypeAdvance_B(1:nBlock) == ImplBlock_)

    ! Check for too many implicit blocks
    if(nImplBLK>MaxImplBLK)then
       write(*,*)'ERROR: Too many implicit blocks!'
       write(*,*)'MaxImplBLK < nImplBLK :',MaxImplBLK,nImplBLK
       call stop_mpi( &
            'Change number of processors, reduce number of implicit blocks,'// &
            ' or increase MaxImplBLK in ModSize.f90 !')
    end if

    ! Number of implicit variables
    nImpl = nImplBLK*nwIJK
    ! Create conversion array and find the test block
    implBLKtest=1
    iBlockImpl=0
    do iBLK=1,nBlock
       if (iTypeAdvance_B(iBLK) == ImplBlock_) then
          iBlockImpl = iBlockImpl + 1
          impl2iBLK(iBlockImpl)=iBLK
          if(iBLK==BLKtest)implBLKtest=iBlockImpl
       endif
    end do

    ! The index of the test variable in the linear array
    implVARtest=VARtest+nw*(Itest-1+nI*(Jtest-1+nJ*(Ktest-1+nK*(implBLKtest-1))))

    if(.not.IsInitialized)then
       residual = bigdouble
       IsInitialized=.true.
    end if

  end subroutine implicit_init
  !==============================================================================

  subroutine explicit2implicit(imin,imax,jmin,jmax,kmin,kmax,Var_VGB)

    ! Convert data structure Var_VGB of the implicit code to the explicit code

    use ModMain
    use ModAdvance, ONLY : State_VGB, Energy_GBI
    use ModMultiFluid, ONLY: select_fluid, iFluid, nFluid, iP
    use ModImplicit
    use ModRadDiffusion,   ONLY: get_impl_rad_diff_state
    use ModHeatConduction, ONLY: get_impl_heat_cond_state
    use ModResistivity,    ONLY: get_impl_resistivity_state

    integer,intent(in) :: imin,imax,jmin,jmax,kmin,kmax
    real, intent(out)  :: Var_VGB(nw,imin:imax,jmin:jmax,kmin:kmax,MaxImplBLK)

    integer :: implBLK, iBLK
    logical :: DoTest, DoTestMe

    character(len=*), parameter:: NameSub = 'explicit2implicit'
    !---------------------------------------------------------------------------
    call set_oktest(NameSub,DoTest,DoTestMe)
    if(DoTestMe)write(*,*)'Starting explicit2implicit: ',&
         'imin,imax,jmin,jmax,kmin,kmax=',imin,imax,jmin,jmax,kmin,kmax

    if(DoTestMe)write(*,*)'E=',Energy_GBI(Itest,Jtest,Ktest,BLKtest,:)

    call timing_start('expl2impl')

    do implBLK=1,nImplBLK
       iBLK = impl2iBLK(implBLK)
       Var_VGB(:,:,:,:,implBLK) = &
            State_VGB(:,imin:imax,jmin:jmax,kmin:kmax,iBLK)

       if(UseImplicitEnergy)then
          do iFluid = 1, nFluid
             call select_fluid
             Var_VGB(iP,:,:,:,implBLK) = &
                  Energy_GBI(imin:imax,jmin:jmax,kmin:kmax,iBLK,iFluid)
          end do
       end if
    end do

    call timing_stop('expl2impl')

    if(DoTestMe.and.nImplBLK>0)write(*,*)'Finished explicit2implicit: Var_VGB=',&
         Var_VGB(:,iTest,jTest,kTest,implBLKtest)

  end subroutine explicit2implicit

  !==============================================================================

  subroutine impl2expl(Var_VC, iBLK)

    ! Convert the implicit block Var_VC to block iBLK of the explicit code

    use ModSize,     ONLY : nI, nJ, nK
    use ModAdvance,  ONLY : nVar, State_VGB, Energy_GBI
    use ModEnergy,   ONLY : calc_pressure_cell, calc_energy_cell
    use ModMultiFluid, ONLY: iFluid, nFluid, iP_I, iP
    use ModImplicit, ONLY: UseImplicitEnergy
    use ModGeometry, ONLY: true_cell

    real, intent(in)    :: Var_VC(nVar,nI,nJ,nK)
    integer, intent(in) :: iBLK
    integer :: i,j,k
    !---------------------------------------------------------------------------

    call timing_start('impl2expl')


    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       if(.not.true_cell(i,j,k,iBLK)) CYCLE
       State_VGB(1:nVar,i,j,k,iBLK) = Var_VC(1:nVar,i,j,k)
    end do; end do; end do

    if(UseImplicitEnergy)then
       do iFluid = 1, nFluid
          iP = iP_I(iFluid)
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.true_cell(i,j,k,iBLK)) CYCLE
             Energy_GBI(i,j,k,iBLK,iFluid) = Var_VC(iP,i,j,k)
          end do; end do; end do
       end do
       call calc_pressure_cell(iBLK)
    else
       call calc_energy_cell(iBLK)
    end if

    call timing_stop('impl2expl')

  end subroutine impl2expl

  !==============================================================================

  subroutine implicit2explicit(Var_VCB)

    use ModMain, ONLY: nI,nJ,nK,MaxImplBLK, iTest, jTest, kTest, BlkTest
    use ModAdvance, ONLY: State_VGB
    use ModImplicit,       ONLY: nw, nImplBLK, impl2iBLK
    use ModRadDiffusion,   ONLY: update_impl_rad_diff
    use ModHeatConduction, ONLY: update_impl_heat_cond
    use ModResistivity,    ONLY: update_impl_resistivity

    real :: Var_VCB(nw,nI,nJ,nK,MaxImplBLK)
    integer :: implBLK, iBLK

    logical:: DoTest, DoTestMe
    character(len=*), parameter:: NameSub = 'implicit2explicit'
    !---------------------------------------------------------------------------
    call set_oktest(NameSub,DoTest,DoTestMe)

    do implBLK=1,nImplBLK
       iBLK=impl2iBLK(implBLK)
       call impl2expl(Var_VCB(:,:,:,:,implBLK),iBLK)
    end do

    if(DoTestMe)write(*,*) NameSub,': State_VGB=',&
         State_VGB(:,iTest,jTest,kTest,BlkTest)

  end subroutine implicit2explicit

  !=============================================================================
  subroutine get_residual(IsLowOrder, DoCalcTimestep, DoSubtract, Var_VCB, &
       Res_VCB)

    ! If IsLowOrder is true apply low  order scheme
    ! otherwise             apply high order scheme
    !
    ! If DoCalcTimestep is true calculate time step based on CFL condition
    !
    ! If DoSubtract is true return  Res_VCB = Var_VCB(t+dtexpl)-Var_VCB(t) 
    ! otherwise return              Res_VCB = Var_VCB(t+dtexpl)

    use ModMain
    use ModAdvance, ONLY : FluxType,time_BLK
    use ModGeometry, ONLY : true_cell
    use ModImplicit
    use ModMessagePass, ONLY: exchange_messages
    use ModMpi

    logical, intent(in) :: IsLowOrder, DoCalcTimestep, DoSubtract
    real, intent(in)    :: Var_VCB(nVar,nI,nJ,nK,MaxImplBLK)
    ! The actual Var_VCB and Res_VCB arguments may be the same array: 
    ! intent(inout)
    real, intent(inout) :: Res_VCB(nVar,nI,nJ,nK,MaxImplBLK)

    real    :: CflTmp
    integer :: nOrderTmp, nStageTmp, implBLK, iBLK
    character (len=10) :: FluxTypeTmp

    logical :: DoTest, DoTestMe
    !--------------------------------------------------------------------------

    call set_oktest('get_residual',DoTest,DoTestMe)

    call timing_start('get_residual')

    if(DoTestMe.and.nImplBLK>0)&
         write(*,*)'get_residual DoSubtract,IsLowOrder,Var_VCB=',&
         DoSubtract,IsLowOrder,Var_VCB(Ktest,VARtest,Itest,Jtest,implBLKtest)

    nStageTmp       = nStage
    nStage          = 1
    if(IsLowOrder)then
       nOrderTmp    = nOrder
       nOrder       = nOrder_impl
       FluxTypeTmp  = FluxType
       FluxType     = FluxTypeImpl
    endif
    if(UseDtFixed)then
       do implBLK=1,nimplBLK
          iBLK=impl2iBLK(implBLK)
          time_BLK(:,:,:,iBLK)=0.0
          where(true_cell(1:nI,1:nJ,1:nK,iBLK)) &
               time_BLK(1:nI,1:nJ,1:nK,iBLK) = DtExpl
       end do
    else
       CflTmp = Cfl
       Cfl    = 0.5
    end if

    ! Res_VCB = Var_VCB(t+dt)
    call implicit2explicit(Var_VCB)
    call exchange_messages
    call advance_expl(DoCalcTimestep, -1)
    call explicit2implicit(1,nI,1,nJ,1,nK,Res_VCB)

    if(DoSubtract) Res_VCB(:,:,:,:,1:nImplBLK) = Res_VCB(:,:,:,:,1:nImplBLK) &
         - Var_VCB(:,:,:,:,1:nImplBLK)

    if(DoTestMe.and.nImplBLK>0)write(*,*)'get_residual Res_VCB:',&
         Res_VCB(VARtest,Itest,Jtest,Ktest,implBLKtest)

    ! Restore global variables
    nStage      = nStageTmp
    if(IsLowOrder)then
       nOrder   = nOrderTmp
       FluxType = FluxTypeTmp 
    end if
    if (.not.UseDtFixed) Cfl = CflTmp

    call timing_stop('get_residual')

  end subroutine get_residual
  !==============================================================================

  subroutine getsource(iBLK,Var_VCB,SourceImpl_VC)

    ! Get sources for block iBLK using implicit data Var_VCB

    use ModMain
    use ModVarIndexes
    use ModAdvance, ONLY : Source_VC  ! To communicate to calc_source
    use ModCalcSource, ONLY: calc_source
    use ModImplicit, ONLY : nw, UseImplicitEnergy

    integer, intent(in) :: iBLK
    real, intent(in)    :: Var_VCB(nI,nJ,nK,nw)
    real, intent(out)   :: SourceImpl_VC(nw,nI,nJ,nK)

    logical :: qUseDivbSource
    !--------------------------------------------------------------------------

    call timing_start('getsource')

    qUseDivbSource = UseDivbSource
    UseDivbSource  = .false.

    call impl2expl(Var_VCB,iBLK)

!!! Explicit time dependence  t+ImplCoeff*dt !!!
    !call calc_point_sources(t+ImplCoeff*dt)
    call calc_source(iBlk)

    SourceImpl_VC = Source_VC(1:nVar,:,:,:)

    if(UseImplicitEnergy)then
       ! Overwrite pressure source terms with energy source term
       SourceImpl_VC(iP_I,:,:,:) = Source_VC(Energy_:Energy_+nFluid-1,:,:,:)
    end if

    UseDivbSource   =qUseDivbSource
    call timing_stop('getsource')

  end subroutine getsource

  !==============================================================================
  subroutine get_face_flux(StateCons_VC,B0_DC,nI,nJ,nK,iDim,iBlock,Flux_VC)

    ! We need the cell centered physical flux function, but to keep
    ! the implicit scheme general for all equations, we reuse
    ! subroutine get_physical_flux from ModFaceFlux.

    use ModVarIndexes,ONLY: nFluid, nVar, Energy_
    use ModProcMH,   ONLY: iProc
    use ModMain,     ONLY: MaxDim, x_, y_, z_, &
         ProcTest, BlkTest,iTest,jTest,kTest
    use ModFaceFlux, ONLY: nFlux, iFace, jFace, kFace, Area, &
         set_block_values, set_cell_values, get_physical_flux, &
         HallJx, HallJy, HallJz, UseHallGradPe, DoTestCell
    use ModHallResist, ONLY: UseHallResist, HallJ_CD
    use ModMultiFluid, ONLY: nFluid, iP_I
    use ModImplicit,   ONLY: UseImplicitEnergy

    integer, intent(in):: nI,nJ,nK,idim,iBlock
    real, intent(in)   :: StateCons_VC(nVar,nI,nJ,nK)
    real, intent(in)   :: B0_DC(MaxDim,nI,nJ,nK)
    real, intent(out)  :: Flux_VC(nVar,nI,nJ,nK)

    real :: Primitive_V(nVar), Conservative_V(nFlux), Flux_V(nFlux)

    real :: Un_I(nFluid+1), En, Pe
    integer :: i, j, k

    logical :: DoTest, DoTestMe
    !--------------------------------------------------------------------------

    if(iBlock==BLKtest .and. iProc==PROCtest)then
       call set_oktest('get_face_flux', DoTest, DoTestMe)
    else
       DoTest=.false.; DoTestMe=.false.
    end if

    call set_block_values(iBlock, iDim)
    ! Set iFace=i, jFace=j, kFace=k so that 
    ! call set_cell_values and call get_physical_flux work
    ! This is not quite right but good enough for the preconditioner
    do k = 1, nK; kFace=k; do j = 1, nJ; jFace=j; do i = 1, nI; iFace=i

       DoTestCell = DoTestMe .and. &
            i==iTest .and. j==jTest .and. k==kTest

       Primitive_V = StateCons_VC( :,i, j, k)
       call conservative_to_primitive(Primitive_V)

!!! Conservative_V(1:nVar) = StateCons_VC( :,i, j, k)
!!! do iFluid=1, nFluid
!!!    iP = iP_I(iFluid)
!!!    Conservative_V(iP) = Primitive_V(iP)
!!!    Conservative_V(nVar+iFluid) = StateCons_VC( iP,i, j, k)
!!! end do

       if(UseHallResist)then
          HallJx = HallJ_CD(i, j, k, x_)
          HallJy = HallJ_CD(i, j, k, y_)
          HallJz = HallJ_CD(i, j, k, z_)
       end if

       call set_cell_values

       ! Ignore gradient of electron pressure in the preconditioner
       UseHallGradPe = .false.

       call get_physical_flux(Primitive_V, &
            B0_DC(x_, i, j, k), &
            B0_DC(y_, i, j, k), &
            B0_DC(z_, i, j, k), &
            Conservative_V, Flux_V, Un_I, En, Pe)

       Flux_VC(1:nVar,i,j,k)= Flux_V(1:nVar)*Area

       if(UseImplicitEnergy)then
          ! Replace pressure flux with energy flux
          Flux_VC(iP_I,i,j,k) = Flux_V(Energy_:Energy_+nFluid-1)*Area
       end if

    end do; end do; end do

  end subroutine get_face_flux

  !==============================================================================
  subroutine get_cmax_face(Var_VF,B0_DF,qnI,qnJ,qnK,iDim,iBlock,Cmax)

    use ModProcMH,   ONLY: iProc
    use ModMain,     ONLY: MaxDim, x_, y_, z_, ProcTest, BlkTest,iTest,jTest,kTest
    use ModImplicit, ONLY: nw
    use ModFaceFlux, ONLY: DoTestCell, iFace, jFace, kFace, Area, &
         set_block_values, set_cell_values, get_speed_max, nFluid, &
         DoLf, DoAw, DoRoe, DoHll, DoHlld, UnLeft_I, UnRight_I
    use ModAdvance,  ONLY: eFluid_

    integer, intent(in):: qnI,qnJ,qnK,idim,iBlock
    real, intent(in)   :: Var_VF(nw,qnI,qnJ,qnK)
    real, intent(in)   :: B0_DF(MaxDim,qnI,qnJ,qnK)
    real, intent(out)  :: Cmax(qnI,qnJ,qnK)

    real :: Primitive_V(nw), Cmax_I(nFluid)

    character(len=*), parameter:: NameSub = 'get_cmax_face'
    logical :: DoTest, DoTestMe
    !--------------------------------------------------------------------------

    if(iBlock==BLKtest .and. iProc==PROCtest)then
       call set_oktest('get_cmax_face', DoTest, DoTestMe)
    else
       DoTest=.false.; DoTestMe=.false.
    end if

    DoLf  = .true.
    DoAw  = .false.
    DoRoe = .false.
    DoHll = .false.
    DoHlld= .false.

    ! The electron speed is set to zero (I can't remember why)
    UnLeft_I(eFluid_)  = 0.0
    UnRight_I(eFluid_) = 0.0

    call set_block_values(iBlock, iDim)
    do kFace = 1, qnK; do jFace = 1, qnJ; do iFace = 1, qnI

       DoTestCell = DoTestMe .and. &
            iFace==iTest .and. jFace==jTest .and. kFace==kTest

       Primitive_V = Var_VF(:,iFace, jFace, kFace)

       call conservative_to_primitive(Primitive_V)

       call set_cell_values

       call get_speed_max(Primitive_V, &
            B0_DF( x_,iFace, jFace, kFace), &
            B0_DF( y_,iFace, jFace, kFace), &
            B0_DF( z_,iFace, jFace, kFace), &
            cmax_I = Cmax_I)

       cmax(iFace, jFace, kFace) = maxval(Cmax_I)*Area

    end do; end do; end do

    if(DoTestMe)write(*,*) NameSub,': Area, cmax=', &
         Area, cmax(iTest, jTest, kTest)

  end subroutine get_cmax_face

  !==============================================================================
  subroutine conservative_to_primitive(State_V)

    use ModAdvance, ONLY: UseElectronPressure
    use ModImplicit, ONLY: nw, UseImplicitEnergy
    use ModVarIndexes, ONLY: Bx_, Bz_, IsMhd, nFluid, Pe_
    use ModMultiFluid, ONLY: select_fluid, nIonFluid, &
         iFluid, iRho, iRhoUx, iUx, iRhoUz, iUz, iP, &
         iRho_I, iUx_I, iUy_I, iUz_I, iRhoUx_I, iRhoUy_I, iRhoUz_I
    use ModPhysics, ONLY: gm1

    real, intent(inout):: State_V(nw)
    real :: InvRho, InvRho_I(nFluid)
    !---------------------------------------------------------------------------
    if(UseImplicitEnergy)then
       do iFluid = 1, nFluid
          call select_fluid

          InvRho = 1.0/State_V(iRho)

          State_V(iP) = gm1*(State_V(iP) - &
               0.5*sum(State_V(iRhoUx:iRhoUz)**2)*InvRho)

          if(nIonFluid == 1 .and. iFluid == 1)then
             if(UseElectronPressure) State_V(iP) = State_V(iP) - State_V(Pe_)
          end if

          if(iFluid == 1 .and. IsMhd) &
               State_V(iP) = State_V(iP) - 0.5*gm1*sum(State_V(Bx_:Bz_)**2)

          State_V(iUx:iUz) = InvRho*State_V(iRhoUx:iRhoUz)
       end do
    else
       InvRho_I = 1.0/State_V(iRho_I)
       State_V(iUx_I) = InvRho_I*State_V(iRhoUx_I)
       State_V(iUy_I) = InvRho_I*State_V(iRhoUy_I)
       State_V(iUz_I) = InvRho_I*State_V(iRhoUz_I)
    end if

  end subroutine conservative_to_primitive

  !==============================================================================
  subroutine getdt_courant(qdt)

    use ModProcMH
    use ModMain
    use ModAdvance, ONLY : B0_DGB
    use ModGeometry, ONLY : true_cell, true_BLK
    use ModImplicit
    use ModMpi
    use BATL_lib, ONLY: CellVolume_GB

    real, intent(out) :: qdt

    real :: cmax(nI,nJ,nK), B0_DC(MaxDim,nI,nJ,nK), qdt_local
    integer :: idim, implBLK, iBLK, iError

    logical :: DoTest, DoTestMe
    !-------------------------------------------------------------------------
    call set_oktest('getdt_courant',DoTest,DoTestMe)

    ! First calculate max(cmax/dx) for each cell and dimension
    qdt_local=0.0
    do implBLK=1,nImplBLK; 
       iBLK=impl2iBLK(implBLK);

       if(UseB0)then
          B0_DC = B0_DGB(:,1:nI,1:nJ,1:nK,iBLK)
       else
          B0_DC = 0.0
       end if

       do iDim = 1, nDim

          call get_cmax_face(Impl_VGB(1:nw,1:nI,1:nJ,1:nK,implBLK),B0_DC,&
               nI, nJ, nK, iDim, iBlk, Cmax)

          if(.not.true_BLK(iBLK))then
             where(.not.true_cell(1:nI,1:nJ,1:nK,iBLK))cmax=0.0
          end if

          qdt_local = &
               max(qdt_local,maxval(cmax/CellVolume_GB(1:nI,1:nJ,1:nK,iBlk)))

          if(DoTestMe)write(*,*)'getdt_courant idim,dx,cmax,1/qdt=',&
               idim,cmax(Itest,Jtest,Ktest),qdt_local
       end do
    end do

    ! Take global maximum
    call MPI_allreduce(qdt_local,qdt,1,MPI_REAL,MPI_MAX,iComm,iError)

    if(DoTestMe)write(*,*)'1/dt_local,1/dt=',qdt_local,qdt

    ! Take inverse, and reduce so it is OK for 3D calculation
    qdt=0.3/qdt

    if(DoTestMe)write(*,*)'getdt_courant final dt=',qdt

  end subroutine getdt_courant

end module ModPartImplicit
