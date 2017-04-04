!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
subroutine polar_wind

  ! Discussion:
  ! This subroutine solves the polar wind solution along a given field line
  ! called by advance_line. A. Glocer
  !
  ! photoelectron impact ionization modified for no conjugate hemisphere
  ! P. E. sources. See Subroutine Glowex, variable 'rat' D. Cannata 9May90
  ! 
  ! ADDED SUBROUTINE CALL FOR IMPACT IONIZATION "call precip" PRESENTLY
  ! HARD WIRED FOR POLAR RAIN FOR INVARIENT LATITUDES GREATER THAN 75 DEG.
  ! CHANGES FOR CUSP OR AURORAL PRECIPITATION CAN BE MADE BY CHANGING
  ! ALF1(x) AND FLUX1(x) ARRAY, x=1->4. MODIFIFIED BY DICK AND STEVE 6-90.
  !
  
  use ModPWOM, only: DtVertical,nLine,IsStandAlone,DoSavePlot,iLine,&
       IsFullyImplicit,UseExplicitHeat,DoTimeAccurate,MaxStep,DnOutput,&
       nAlt, IsVariableDt
  use ModIoUnit, ONLY: UnitTmp_
  use ModCommonVariables
  use ModFieldLine
  use ModPwImplicit, only: PW_implicit_update
  use ModPwPlots, ONLY: PW_print_plot,DoPlotNeutral,plot_neutral_pw
  use ModOvation, ONLY:DoPlotOvation,plot_ovation_polar

  INTEGER NOTP(100)
  
  !     define the output files and attaching units
  character*100 :: NameRestart
  logical,save  :: IsFirstCall=.true.
  real    :: Jr, DtVariable
  real    :: NewState_GV(-1:maxGrid,nVar)
  
  !-----------------------------------------------------------------------
  nDim = nAlt
  call get_field_line(nDim,State_GV(1:nDim,:),                       &
       SmLat,SmLon,Jr,wHorizontal,uJoule2=uJoule2,                &
       iUnitOutput=iUnitOutput,       &
       NameRestart=NameRestart,                                    &
       iLine=iLine, Time=Time,MaxLineTime=Tmax,                    &
       TypeSolver=TypeSolver,                                      &
       DToutput=DToutput,DoLog=DoLog,&
       nStep=nStep,Dt=DtVariable,AvE=AveIE,Eflux=EfluxIE)
  
  ! If using variable timestep, then set Dt=Dt(Last line call)
  if (IsVariableDt) then
     Dt = DtVariable
  else
     DT=DtVertical
  endif
  
  CURR(1) = Jr

  NTS = 1
  NCL = 60
    
21 FORMAT(2X,I8)
  
  KSTEP=1
  MSTEP=1
  
  NDIM2=NDIM-1
  NDIM1=NDIM+1
  NDIMM=NDIM+2

  CALL STRT
  
  if (IsFirstCall .and. DoSavePlot) then
     CALL PW_print_plot
     if (DoPlotNeutral) call plot_neutral_pw
     if (DoPlotOvation) call plot_ovation_polar
     if(iLine == nLine) IsFirstCall = .false.
  endif

  !***************************************************************************
  ! This is the start of a while loop that carries out the main steps of
  ! the simulation
  !***************************************************************************
  
  TIMELOOP: DO
     StateOld_GV=State_GV
     If (IsFullyImplicit) then
        call PW_implicit_update
     else
        !       advect and add collisional and chemistry sources
        !       calculate heatflux for ions and update ion temp.
        !       calculate heatflux for electrons, update electron temp.
        !       update boundaries
        !       calculate collisional and chemistry source
        !       calculate electric field with new electron temp.
        call advect
        CALL PW_iheat_flux
        if (.not.UseExplicitHeat) call PW_eheat_flux
        CALL PW_set_upper_bc
        CALL COLLIS(NDIM,State_GV(-1:nDim+2,:))
        CALL PW_calc_efield(nDim,State_GV(-1:nDim+2,:))         

     endif

     NSTEP=NSTEP+1
      if (IsVariableDt) call calc_dt
     StateOld_GV=State_GV
     if (DoTimeAccurate)then
        TIME=TIME+DT
        if (floor((Time+1.0e-5)/DToutput)/=floor((Time+1.0e-5-DT)/DToutput) )then 
           CALL PW_print_plot
           if (DoPlotNeutral) call plot_neutral_pw
           if (DoPlotOvation) call plot_ovation_polar
        endif
     else if (mod(nStep,DnOutput) == 0) then
        CALL PW_print_plot
        if (DoPlotNeutral) call plot_neutral_pw
     end if
     !       Reverse order of advection and implicit temperature update
     
     If (IsFullyImplicit) then
        call PW_implicit_update
     else
        CALL PW_iheat_flux
        if (.not.UseExplicitHeat) call PW_eheat_flux
        CALL advect
        CALL PW_set_upper_bc
        CALL COLLIS(NDIM,State_GV(-1:nDim+2,:))
        CALL PW_calc_efield(nDim,State_GV(-1:nDim+2,:))         
      
     endif

     !    finish update by calculating boundaries, collision source 
     !    and electric field
     !    these will be used in the next time step

     NSTEP=NSTEP+1
     if (IsVariableDt) call calc_dt
     if (DoTimeAccurate)then
        TIME=TIME+DT
        if (floor((Time+1.0e-5)/DToutput)/=floor((Time+1.0e-5-DT)/DToutput) )then 
           CALL PW_print_plot
           if (DoPlotNeutral) call plot_neutral_pw
           if (DoPlotOvation) call plot_ovation_polar
        endif
        IF (IsStandAlone .and. &
             floor((Time+1.0e-5)/DToutput)/=floor((Time+1.0e-5-2.0*DT)/DToutput) )&
             call PW_write_restart(&
             nDim,RAD(1:nDim),SmLat,SmLon,Time,DT,nStep,NameRestart, &    
             State_GV(1:nDim,:))                  
        IF (TIME+1.0e-5 >= TMAX) Then 
           Call put_field_line(nDim,State_GV(1:nDim,:),    &
                SmLat,SmLon,Jr,wHorizontal,&
                Time=Time,nStep=nStep,r_C=RAD   ) 
           RETURN
        endif
     else 
        if (mod(nStep,DnOutput) == 0 .or. mod(nStep-1,DnOutput) == 0) then
           CALL PW_print_plot
           if (DoPlotNeutral) call plot_neutral_pw
           if (DoPlotOvation) call plot_ovation_polar
           IF (IsStandAlone)&
                call PW_write_restart(&
                nDim,RAD(1:nDim),SmLat,SmLon,Time,DT,nStep,NameRestart, &    
                State_GV(1:nDim,:))             
        endif
        IF (nStep >= MaxStep) Then 
           Call put_field_line(nDim,State_GV(1:nDim,:),    &
                SmLat,SmLon,Jr,wHorizontal,&
                Time=Time,nStep=nStep,r_C=RAD   ) 
           RETURN
        end if
     endif
  enddo TIMELOOP
  
contains      
  !============================================================================
  
  subroutine advect
    use ModPhotoElectron
    use ModCouplePWOMtoSE, only: get_se_for_pwom
    use ModPwTime,ONLY: StartTime, Hour_,Minute_, Second_, iCurrentTime_I, &
         CurrentTime
    use ModTimeConvert, ONLY: time_real_to_int
    use ModOvation, ONLY: UseOvation,get_ovation_point,read_ovation_all, &
         OvationEmin,OvationEmax
    
    real :: EMeanDiff,EFluxDiff,EMeanWave,EFluxWave,EMeanMono,EFluxMono
    real :: UTsec
    !--------------------------------------------------------------------------

    !get the SE fluxes from SE first
    if (.not.allocated(SeDens_C)) allocate(SeDens_C(nDim))
    if (.not.allocated(SeFlux_C)) allocate(SeFlux_C(nDim))
    if (.not.allocated(SeHeat_C)) allocate(SeHeat_C(nDim))

    if ((floor((Time+1.0e-5)/DtGetSe)/=floor((Time+1.0e-5-DT)/DtGetSe))&
         .and.DoCoupleSE) then
       !get UT for current time
       CurrentTime=StartTime+Time
       call time_real_to_int(CurrentTime,iCurrentTime_I)
       UTsec = iCurrentTime_I(Hour_)*3600.0+iCurrentTime_I(Minute_)*60.0 &
            +iCurrentTime_I(Second_)

       If (UseOvation) then
          call read_ovation_all(Time)
          call get_ovation_point(SmLat,SmLon,EMeanDiff,EFluxDiff,&
               EMeanWave,EFluxWave,EMeanMono,EFluxMono)
          call get_se_for_pwom(Time,UTsec,iLine,(/min(GmLat,88.0),GmLon/),&
               (/GLAT,GLONG/),(/GLAT2,GLONG2/),                   &
               State_GV(1:nDim,RhoE_)/Mass_I(nIon),State_GV(1:nDim,Te_),&
               Efield(1:nDim),Ap,F107,F107A,IYD,SeDens_C, SeFlux_C, SeHeat_C,&
               EMeanDiffPW=EMeanDiff,EFluxDiffPW=EFluxDiff, &
               EMeanWavePW=EMeanWave,EFluxWavePW=EFluxWave, &
               EMeanMonoPW=EMeanMono,EFluxMonoPW=EFluxMono)
       else
          call get_se_for_pwom(Time,UTsec,iLine,(/min(GmLat,88.0),GmLon/),&
            (/GLAT,GLONG/),(/GLAT2,GLONG2/),                   &
            State_GV(1:nDim,RhoE_)/Mass_I(nIon),State_GV(1:nDim,Te_),&
            Efield(1:nDim),Ap,F107,F107A,IYD,SeDens_C, SeFlux_C, SeHeat_C)
       endif


    endif

    if((.not.DoCoupleSE) .or. (.not.UseFeedbackFromSE)) then
       SeDens_C(:)=0.0
       SeFlux_C(:)=0.0
       SeHeat_C(:)=0.0
    endif
    
    NewState_GV = State_GV
    if (TypeSolver == 'Godunov') then
       Do iIon=1,nIon-1
          CALL Solver(iIon,nDim,Dt,&
               State_GV(-1:nDim+2,iRho_I(iIon):iT_I(iIon)),&
               Source_CV(1:nDim,iRho_I(iIon)),Source_CV(1:nDim,iP_I(iIon)),&
               Source_CV(1:nDim,iU_I(iIon)),&
               RGAS_I(iIon),HeatCon_GI(0:nDim+1,iIon),&
               NewState_GV(-1:nDim+2,iRho_I(iIon):iT_I(iIon)))
       enddo

      else if (TypeSolver == 'Rusanov') then
         do iIon=1,nIon-1
            call rusanov_solver(iIon,nDim,RGAS_I(iIon),dt,   &
                 State_GV(-1:nDim+2,iRho_I(iIon):iP_I(iIon)),&
                 State_GV(-1:nDim+2,iRho_I(nIon):iP_I(nIon)),&
                 Source_CV(1:nDim,iRho_I(iIon)), Source_CV(1:nDim,iU_I(iIon)),&
                 Source_CV(1:nDim,iP_I(iIon)),  &
                 HeatCon_GI(0:nDim+1,iIon), &
                 NewState_GV(-1:nDim+2,iRho_I(iIon):iP_I(iIon)))
            !get T from p and rho
            NewState_GV(1:nDim,iT_I(iIon))=&
                 NewState_GV(1:nDim,iP_I(iIon))&
                 /Rgas_I(iIon)&
                 /NewState_GV(1:nDim,iRho_I(iIon))
         enddo
      endif
      
      if (UseExplicitHeat) then
         call PW_eheat_flux_explicit(nDim,RGAS_I(nIon),dt,   &
              State_GV(-1:nDim+2,iRho_I(nIon):iP_I(nIon)),&
              Source_CV(:,iRho_I(nIon)), Source_CV(:,iU_I(nIon)),&
              Source_CV(:,iP_I(nIon)),  &
              HeatCon_GI(0:nDim+1,nIon), &
              NewState_GV(-1:nDim+2,iT_I(nIon)))
         ! Set electron density and velocity
         NewState_GV(1:nDim,RhoE_)= -SeDens_C(:)*Mass_I(nIon)
         NewState_GV(1:nDim,uE_)  = -SeFlux_C(:)*Mass_I(nIon)
!         NewState_GV(1:nDim,RhoE_)=0.0
!         NewState_GV(1:nDim,uE_)  =0.0
         do k=1,nDim
            do iIon=1,nIon-1
               NewState_GV(K,RhoE_) = &
                    NewState_GV(k,RhoE_)+MassElecIon_I(iIon)*NewState_GV(K,iRho_I(iIon))
               NewState_GV(K,uE_)= &
                    NewState_GV(k,uE_)+ &
                    (MassElecIon_I(iIon)*NewState_GV(K,iRho_I(iIon))&
                    *NewState_GV(K,iU_I(iIon)))
            enddo
            NewState_GV(k,RhoE_) = &
                 max(NewState_GV(k,RhoE_),eThermalDensMin*Mass_I(nIon))
            NewState_GV(K,uE_)=(NewState_GV(K,uE_) -1.8965E-18*CURR(K))/NewState_GV(K,RhoE_)
         enddo
         !get T from p and rho
         NewState_GV(1:nDim,iP_I(nIon))=&
              NewState_GV(1:nDim,iT_I(nIon))&
              *Rgas_I(nIon)&
              *NewState_GV(1:nDim,iRho_I(nIon))
      else         
         ! Set electron density and velocity
         NewState_GV(1:nDim,RhoE_)= -SeDens_C(:)*Mass_I(nIon)
         NewState_GV(1:nDim,uE_)  = -SeFlux_C(:)*Mass_I(nIon)
!         NewState_GV(1:nDim,RhoE_)=0.0
!         NewState_GV(1:nDim,uE_)  =0.0
         do k=1,nDim
            do iIon=1,nIon-1
               NewState_GV(K,RhoE_) = &
                    NewState_GV(k,RhoE_)+MassElecIon_I(iIon)*NewState_GV(K,iRho_I(iIon))
               NewState_GV(K,uE_)= &
                    NewState_GV(k,uE_)+ &
                    (MassElecIon_I(iIon)*NewState_GV(K,iRho_I(iIon))&
                    *NewState_GV(K,iU_I(iIon)))
            enddo
            NewState_GV(k,RhoE_) = &
                 max(NewState_GV(k,RhoE_),eThermalDensMin*Mass_I(nIon))
            NewState_GV(K,uE_)=(NewState_GV(K,uE_) -1.8965E-18*CURR(K))/NewState_GV(K,RhoE_)
         enddo
      endif
      !Update State
      State_GV(:,:) = NewState_GV(:,:)
    end subroutine advect
    
  end Subroutine POLAR_WIND
