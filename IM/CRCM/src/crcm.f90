 
subroutine crcm_run(delta_t)
  use ModConst,       ONLY: cLightSpeed, cElectronCharge
  use ModCrcmInitialize
  use ModCrcm,        ONLY: f2,dt, Time, phot, Ppar_IC, Pressure_IC, &
                            PressurePar_IC,FAC_C, Bmin_C, &
                            eChangeOperator_IV,OpBfield_,OpDrift_,OpLossCone_, &
                            OpChargeEx_, OpStrongDiff_,rbsumLocal,rbsumGlobal, &
                            driftin, driftout
  use ModCrcmPlanet,  ONLY: re_m, dipmom, Hiono, nspec, amu_I, &
                            dFactor_I,tFactor_I
  use ModFieldTrace,  ONLY: fieldpara, brad=>ro, ftv=>volume, xo,yo,rb,irm,&
                            ekev,iba,bo,pp,Have, sinA, vel, alscone, iw2,xmlto
  use ModGmCrcm,      ONLY: Den_IC,Temp_IC,Temppar_IC,StateBmin_IIV,&
                            AveP_,AvePpar_,AveDens_, AveDen_I,AveP_I,iLatMin,&
                            DoMultiFluidGMCoupling,DoAnisoPressureGMCoupling
  use ModIeCrcm,      ONLY: pot
  use ModCrcmPlot,    ONLY: Crcm_plot, Crcm_plot_fls, crcm_plot_log, &
                            DtOutput, DtLogOut,DoSavePlot, DoSaveFlux, DoSaveLog
  use ModCrcmRestart, ONLY: IsRestart
  use ModImTime
  use ModTimeConvert, ONLY: time_real_to_int
  use ModImSat,       ONLY: nImSats,write_im_sat, DoWriteSats, DtSatOut
  use ModCrcmGrid,    ONLY: iProc,nProc,iComm,nLonPar,nLonPar_P,nLonBefore_P
  use ModMpi
  implicit none


  integer n,nstep,ib0(nt)
  real delta_t, FactorTotalDens
  real flux(nspec,np,nt,neng,npit)
  real achar(nspec,np,nt,nm,nk)
  real vl(nspec,0:np,nt,nm,nk),vp(nspec,np,nt,nm,nk),fb(nspec,nt,nm,nk),rc
  integer iLat, iLon, iSpecies, iSat
  logical, save :: IsFirstCall =.true.
  
  !Vars for mpi passing
  integer ::iSendCount,iM,iK,iLon1,iError,iEnergy,iPit,iRecvLower,iRecvUpper,iPe
  integer,allocatable :: iRecieveCount_P(:),iDisplacement_P(:)
  real :: BufferSend_C(np,nt),BufferRecv_C(np,nt)
  integer :: BufferSend_I(nt),BufferRecv_I(nt)
  integer,allocatable :: iBufferSend_I(:),iBufferRecv_I(:)
  integer :: iStatus_I(MPI_STATUS_SIZE)

  real,   allocatable :: ekevSEND_IIII(:,:,:,:),ekevRECV_IIII(:,:,:,:)
  real,   allocatable :: sinaSEND_III(:,:,:),sinaRECV_III(:,:,:)
  real,   allocatable :: F2SEND_IIIII(:,:,:,:,:),f2RECV_IIIII(:,:,:,:,:)

  !----------------------------------------------------------------------------

  if (dt==0) then
     nstep = 0
     dt = 0.0
  else
     nstep=nint(delta_t/dt)
     dt=delta_t/nstep         ! new dt
  endif

  ! Update CurrentTime and iCurrentTime_I
  CurrentTime = StartTime+Time
  call time_real_to_int(CurrentTime,iCurrentTime_I)
  
  ! do field line integration and determine vel, ekev, momentum (pp), etc.
  rc=(re_m+Hiono*1000.)/re_m        ! ionosphere distance in RE`

  call timing_start('crcm_fieldpara')
  call fieldpara(Time,dt,cLightSpeed,cElectronCharge,rc,re_m,xlat,xmlt,phi,xk,&
                 dipmom)
  call timing_stop('crcm_fieldpara')

  ! get Bmin, needs to be passed to GM for anisotropic pressure coupling
  Bmin_C = bo

  !set boundary density and temperature inside iba
  if (.not. DoMultiFluidGMCoupling) then
     ! When not Multifluid we get the total density from Rho_MHD as follows:
     ! Rho = (m1n1+m2n2+...) = n * sum(m_i*dFactor_i)
     ! where sum(dFactor_i)=1 (over ions) and n_i=dFactor_i*n 
     ! n_i = dFactor_i*Rho_MHD/(sum(m_i*dFactor_i))
     ! n_total = Rho_MHD/sum(m_i*dfactor_i)
     ! FactorTotalDens = sum(m_i*dfactor_i)
     FactorTotalDens = sum(dFactor_I(1:nspec-1)*amu_I(1:nspec-1))
     do iSpecies = 1, nspec
        do iLon=MinLonPar,MaxLonPar
           do iLat=1,irm(iLon) 
              if (iLat < iLatMin) then
                 !Inside MHD boundary set den and temp to value at boundary
                 Den_IC(iSpecies,iLat,iLon) = dFactor_I(iSpecies) * &
                      StateBmin_IIV(iLatMin,iLon,AveDens_)/FactorTotalDens
                 Temp_IC(iSpecies,iLat,iLon) = tFactor_I(iSpecies) * &
                      StateBmin_IIV(iLatMin,iLon,AveP_) * FactorTotalDens &
                      / StateBmin_IIV(iLatMin,iLon,AveDens_) &
                      * 6.2415e18 !J-->eV
                 if(DoAnisoPressureGMCoupling) &
                      Temppar_IC(iSpecies,iLat,iLon) = tFactor_I(iSpecies) * &
                      StateBmin_IIV(iLatMin,iLon,AvePpar_) * FactorTotalDens &
                      / StateBmin_IIV(iLatMin,iLon,AveDens_) &
                      * 6.2415e18 !J-->eV
!                 Den_IC(iSpecies,iLat,iLon) = dFactor_I(iSpecies) * 1.0e6
!                 Temp_IC(iSpecies,iLat,iLon) = tFactor_I(iSpecies)* 5000.0
              else
                 !Outside MHD boundary set den and temp from MHD
                 Den_IC(iSpecies,iLat,iLon) = dFactor_I(iSpecies) * &
                      StateBmin_IIV(iLat,iLon,AveDens_)/FactorTotalDens
                 Temp_IC(iSpecies,iLat,iLon) = tFactor_I(iSpecies) * &
                      StateBmin_IIV(iLat,iLon,AveP_) * FactorTotalDens &
                      / StateBmin_IIV(iLat,iLon,AveDens_) &
                      * 6.2415e18 !J-->eV
                 if(DoAnisoPressureGMCoupling) &
                      Temppar_IC(iSpecies,iLat,iLon) = tFactor_I(iSpecies) * &
                      StateBmin_IIV(iLat,iLon,AvePpar_) * FactorTotalDens &
                      / StateBmin_IIV(iLat,iLon,AveDens_) &
                      * 6.2415e18 !J-->eV  
              endif
           end do
        end do
     end do
  else
     !Multifluid Case
     !Set Ion density and temperature
     do iSpecies = 1, nspec-1
        do iLon=MinLonPar,MaxLonPar
           do iLat=1,irm(iLon) 
              if (iLat < iLatMin) then
                 !Inside MHD boundary set den and temp to value at boundary
                 Den_IC(iSpecies,iLat,iLon) = &
                      StateBmin_IIV(iLatMin,iLon,AveDen_I(iSpecies))&
                      / amu_I(iSpecies)
                 Temp_IC(iSpecies,iLat,iLon) = &
                      StateBmin_IIV(iLatMin,iLon,AveP_I(iSpecies))&
                      /(Den_IC(iSpecies,iLat,iLon)) &
                        * 6.2415e18 !J-->eV
!                 Den_IC(iSpecies,iLat,iLon) = dFactor_I(iSpecies) * 1.0e6
!                 Temp_IC(iSpecies,iLat,iLon) = tFactor_I(iSpecies)* 5000.0
              else
                 !Outside MHD boundary set den and temp from MHD
                 Den_IC(iSpecies,iLat,iLon) = &
                      StateBmin_IIV(iLat,iLon,AveDen_I(iSpecies))&
                      / amu_I(iSpecies)
                 Temp_IC(iSpecies,iLat,iLon) = &
                      StateBmin_IIV(iLat,iLon,AveP_I(iSpecies))&
                      /(Den_IC(iSpecies,iLat,iLon)) &
                         * 6.2415e18 !J-->eV  
              endif
           end do
        end do
     end do
     !Set Electron density and temperature
     do iLon=MinLonPar,MaxLonPar
        do iLat=1,irm(iLon) 
           ! Density set by quasineutrality
           Den_IC(nspec,iLat,iLon)  = sum(Den_IC(1:nspec-1,iLat,iLon))
           ! Temp is set by 1/7 of weighted sum of ion temperatures
           Temp_IC(nspec,iLat,iLon) = 0.128205 * sum( &
                Den_IC(1:nspec-1,iLat,iLon)*Temp_IC(1:nspec-1,iLat,iLon)) &
                / Den_IC(nspec,iLat,iLon)
        end do
     end do
    !call CON_STOP('CRCM not set to use multifluid')
  endif
  ! Bcast DoWriteSats on firstcall
  if (IsFirstCall .and. nProc > 1) then
     call MPI_bcast(DoWriteSats,1,MPI_LOGICAL,0,iComm,iError)
  endif

  ! setup initial distribution
  if (IsFirstCall .and. .not.IsRestart) then
     !set initial state when no restarting
     call initial_f2(nspec,np,nt,iba,amu_I,vel,xjac,ib0)
     IsFirstCall=.false.
  elseif(IsFirstCall .and. IsRestart) then
     ib0=iba
     IsFirstCall=.false.
  endif

  ! calculate boundary flux (fb) at the CRCM outer boundary at the equator
  call boundaryIM(nspec,np,nt,nm,nk,iba,irm,amu_I,xjac,vel,fb)

  if (Time == 0.0 .and. nProc == 1 .and. DoSavePlot) then
     call timing_start('crcm_output')
     call crcm_output(np,nt,nm,nk,nspec,neng,npit,iba,ftv,f2,ekev, &
          sinA,energy,sinAo,delE,dmu,amu_I,xjac,pp,xmm,dmm,dk,xlat,dphi, &
          re_m,Hiono,flux,FAC_C,phot,Ppar_IC,Pressure_IC,PressurePar_IC)
     call timing_stop('crcm_output')
     
     call timing_start('crcm_plot')
     call Crcm_plot(np,nt,xo,yo,Pressure_IC,PressurePar_IC,phot,Ppar_IC,Den_IC,&
          bo,ftv,pot,FAC_C,Time,dt)
     call timing_stop('crcm_plot')
     if (DoSaveFlux) call Crcm_plot_fls(rc,flux,time)
  endif

  ! calculate the drift velocity
  call timing_start('crcm_driftV')
  call driftV(nspec,np,nt,nm,nk,irm,re_m,Hiono,dipmom,dphi,xlat, &
       dlat,ekev,pot,vl,vp) 
  call timing_stop('crcm_driftV')

  ! calculate the depreciation factor, achar, due to charge exchange loss
  call timing_start('crcm_ceparaIM')
  call ceparaIM(nspec,np,nt,nm,nk,irm,dt,vel,ekev,Have,achar)
  call timing_stop('crcm_ceparaIM')

  ! Calculate the strong diffusion lifetime for electrons
  call timing_start('crcm_StDiTime')
  call StDiTime(dt,vel,ftv,rc,re_m,dipmom,iba)
  call timing_stop('crcm_StDiTime')

  !get energy contribution from Bfield change before start of time loop
  call sume(eChangeOperator_IV(:,OpBfield_))
  ! time loop
  do n=1,nstep
     call timing_start('crcm_driftIM')
     call driftIM(iw2,nspec,np,nt,nm,nk,dt,dlat,dphi,brad,rb,vl,vp, &
          fb,f2,driftin,driftout,ib0)
     call sume(eChangeOperator_IV(:,OpDrift_))
     call timing_stop('crcm_driftIM')

     call timing_start('crcm_charexchange')
     call charexchangeIM(np,nt,nm,nk,nspec,iba,achar,f2)
     call sume(eChangeOperator_IV(:,OpChargeEx_))
     call timing_stop('crcm_charexchange')

     call timing_start('crcm_lossconeIM')
     call lossconeIM(np,nt,nm,nk,nspec,iba,alscone,f2)
     call sume(eChangeOperator_IV(:,OpLossCone_))
     call timing_stop('crcm_lossconeIM')

     call timing_start('crcm_StrongDiff')
     call StrongDiff(iba)        
     call sume(eChangeOperator_IV(:,OpStrongDiff_))
     call timing_stop('crcm_StrongDiff')                       
     
     Time = Time+dt
     ! Update CurrentTime and iCurrentTime_I
     CurrentTime = StartTime+Time
     call time_real_to_int(CurrentTime,iCurrentTime_I)
  enddo

  ! After time loop sum rbsumLocal tp rbsumglobal
  do n=1,nspec
     if (nProc >0) then
        call MPI_REDUCE (rbsumLocal(n), rbsumGlobal(n), 1, MPI_REAL, &
               MPI_SUM, 0, iComm, iError)
     else
        rbsumGlobal(n)=rbsumLocal(n)
     endif
  enddo


  call timing_start('crcm_output')
  call crcm_output(np,nt,nm,nk,nspec,neng,npit,iba,ftv,f2,ekev, &
       sinA,energy,sinAo,delE,dmu,amu_I,xjac,pp,xmm,dmm,dk,xlat,dphi, &
       re_m,Hiono,flux,FAC_C,phot,Ppar_IC,Pressure_IC,PressurePar_IC)
  call timing_stop('crcm_output')
  
  ! When nProc >1 consolodate: phot, Ppar_IC, Pressure_IC, PressurePar_IC, fac and iba on iProc 0
  if (nProc>1) then    
     if (.not.allocated(iRecieveCount_P)) &
          allocate(iRecieveCount_P(nProc), iDisplacement_P(nProc))       
     !Gather to root
     iSendCount = np*nLonPar
     iRecieveCount_P=np*nLonPar_P
     iDisplacement_P = np*nLonBefore_P
     BufferSend_C(:,:) = FAC_C(:,:) 
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) FAC_C(:,:)=BufferRecv_C(:,:)

     do iSpecies=1,nspec
        BufferSend_C(:,:)=Pressure_IC(iSpecies,:,:)
        call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, &
             MPI_REAL, BufferRecv_C,iRecieveCount_P, iDisplacement_P,MPI_REAL, &
             0, iComm, iError)
        if (iProc==0) Pressure_IC(iSpecies,:,:)=BufferRecv_C(:,:)

        BufferSend_C(:,:)=PressurePar_IC(iSpecies,:,:)
        call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, &
             MPI_REAL, BufferRecv_C,iRecieveCount_P, iDisplacement_P,MPI_REAL, &
             0, iComm, iError)
        if (iProc==0) PressurePar_IC(iSpecies,:,:)=BufferRecv_C(:,:)

        BufferSend_C(:,:)=phot(iSpecies,:,:)
        call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, &
             MPI_REAL, BufferRecv_C,iRecieveCount_P, iDisplacement_P,MPI_REAL, &
             0, iComm, iError)
        if (iProc==0) phot(iSpecies,:,:)=BufferRecv_C(:,:)

        BufferSend_C(:,:)=Ppar_IC(iSpecies,:,:)
        call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, &
             MPI_REAL, BufferRecv_C,iRecieveCount_P, iDisplacement_P,MPI_REAL, &
             0, iComm, iError)
        if (iProc==0) Ppar_IC(iSpecies,:,:)=BufferRecv_C(:,:)

        BufferSend_C(:,:)=Den_IC(iSpecies,:,:)
        call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, &
             MPI_REAL, BufferRecv_C,iRecieveCount_P, iDisplacement_P,MPI_REAL, &
             0, iComm, iError)
        if (iProc==0) Den_IC(iSpecies,:,:)=BufferRecv_C(:,:)
     enddo

     BufferSend_I(:) = iba(:)
     call MPI_GATHERV(BufferSend_I(MinLonPar:MaxLonPar),nLonPar, MPI_INTEGER, &
          BufferRecv_I, nLonPar_P, nLonBefore_P, MPI_INTEGER, &
          0, iComm, iError)
     if (iProc==0) iba(:)=BufferRecv_I(:)

     BufferSend_C(:,:) = Bmin_C(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) Bmin_C(:,:)=BufferRecv_C(:,:)
     
  endif
  
  ! On processor O, gather info and save plots
  ! When time to write output, consolodate xo,yo,flux,pot,ftv, bo, and irm 
  ! on iProc 0
  if (nProc>1 .and. DoSavePlot  .and.&
       (floor((Time+1.0e-5)/DtOutput))/=&
       floor((Time+1.0e-5-delta_t)/DtOutput)) then
     
!     call MPI_GATHERV(pot(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
!          pot, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
!          0, iComm, iError)

     BufferSend_C(:,:)=ftv(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) ftv(:,:)=BufferRecv_C(:,:)
     BufferSend_C(:,:)=xo(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) xo(:,:)=BufferRecv_C(:,:)
     BufferSend_C(:,:)=yo(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) yo(:,:)=BufferRecv_C(:,:)
     BufferSend_C(:,:)=bo(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) bo(:,:)=BufferRecv_C(:,:)
     BufferSend_C(:,:)=xmlto(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) xmlto(:,:)=BufferRecv_C(:,:)
     BufferSend_C(:,:)=brad(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)
     if (iProc==0) brad(:,:)=BufferRecv_C(:,:)
     BufferSend_I(:)=irm(:)
     call MPI_GATHERV(BufferSend_I(MinLonPar:MaxLonPar), nLonPar, MPI_INTEGER, &
          BufferRecv_I, nLonPar_P, nLonBefore_P, MPI_INTEGER, 0, iComm, iError)
     if (iProc==0) irm(:)=BufferRecv_I(:)
  elseif (nProc > 1 .and. DoWriteSats .and. &
       (floor((Time+1.0e-5)/DtSatOut))/=&
       floor((Time+1.0e-5-delta_t)/DtSatOut)) then
     BufferSend_C(:,:)=bo(:,:)
     call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
          BufferRecv_C, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
          0, iComm, iError)     
     if (iProc==0) bo(:,:)=BufferRecv_C(:,:)
  endif


  if (nProc>1 .and. ((DoSavePlot  .and.&
       (floor((Time+1.0e-5)/DtOutput))/=&
       floor((Time+1.0e-5-delta_t)/DtOutput)) .or.&
       ((floor((Time+1.0e-5)/DtSatOut))/=&
       floor((Time+1.0e-5-delta_t)/DtSatOut).and.DoWriteSats))) then
     do  iSpecies=1,nspec
        do iEnergy=1,neng
           do iPit=1,nPit
              BufferSend_C(:,:)=flux(iSpecies,:,:,iEnergy,iPit)
              call MPI_GATHERV(BufferSend_C(:,MinLonPar:MaxLonPar),iSendCount, &
                   MPI_REAL, BufferRecv_C,iRecieveCount_P, iDisplacement_P, &
                   MPI_REAL, 0, iComm, iError)
              if (iProc==0) flux(iSpecies,:,:,iEnergy,iPit)=BufferRecv_C(:,:)
           enddo
        enddo
     enddo
  endif
  
  !Gather to root
  !    iSendCount = np*nLonPar
  !    iRecieveCount_P=np*nLonPar_P
  !    iDisplacement_P = np*nLonBefore_P
  !    call MPI_GATHERV(ftv(:,MinLonPar:MaxLonPar), iSendCount, MPI_REAL, &
  !         ftv, iRecieveCount_P, iDisplacement_P, MPI_REAL, &
  !            0, iComm, iError)
  if (iProc == 0) then
     ! do main plotting
     if (DoSavePlot.and.&
          (floor((Time+1.0e-5)/DtOutput))/=&
          floor((Time+1.0e-5-delta_t)/DtOutput)) then
        call timing_start('crcm_plot')
        call Crcm_plot(np,nt,xo,yo,Pressure_IC,PressurePar_IC,phot,Ppar_IC,Den_IC,&
             bo,ftv,pot,FAC_C,Time,dt)
        call timing_stop('crcm_plot')

        if (DoSaveFlux) call Crcm_plot_fls(rc,flux,time)
     endif
  
     ! Write Sat Output
     if(DoWriteSats .and. DoSavePlot .and. &
          (floor((Time+1.0e-5)/DtSatOut))/=&
          floor((Time+1.0e-5-delta_t)/DtSatOut))then
        do iSat=1,nImSats
           call timing_start('crcm_write_im_sat')
           call write_im_sat(iSat,np,nt,neng,npit,flux)
           call timing_stop('crcm_write_im_sat')
        enddo
     endif

     ! Write Logfile
     if(DoSaveLog .and. &
          (floor((Time+1.0e-5)/DtLogOut))/=&
          floor((Time+1.0e-5-delta_t)/DtLogOut))then
        call timing_start('crcm_plot_log')
        call crcm_plot_log(Time)
        call timing_stop('crcm_plot_log')
     endif
  endif
  


end subroutine Crcm_run

!-----------------------------------------------------------------------------
subroutine crcm_init
  !---------------------------------------------------------------------------
  ! Routine does CRCM initialization: fill arrays
  !
  ! Input: np,nt,neng,npit,nspec,re_m,dipmom,Hiono
  ! Output: xlat,xmlt,energy,sinAo (through augments)
  !         xmm1,xk1,phi1,dlat1,dphi1,dmm1,dk1,delE1,dmu1,xjac,d4,amu (through 
  !         common block cinitialization

  use ModPlanetConst, ONLY: Earth_,DipoleStrengthPlanet_I,rPlanet_I
  use ModConst,       ONLY: cElectronCharge
  use ModNumConst,    ONLY: cDegToRad,cRadToDeg,cPi
  use ModCrcmPlanet,  ONLY: re_m, dipmom, Hiono, amu_I
  use ModCrcmInitialize
  use ModCrcmRestart, ONLY: IsRestart, crcm_read_restart
  use ModImTime
  use ModCrcmGrid,    ONLY: iProcLeft, iProcRight, iLonLeft, iLonRight,d4Element_C
  use ModTimeConvert, ONLY: time_int_to_real,time_real_to_int
  use ModMpi

  implicit none

  integer i,n,k,m,iPe, iError
  
  real rw,rsi,rs1
  real xjac1,sqrtm
  real d2

  ! Set up proc distribution
  if (iProc < mod(nt,nProc))then
     nLonPar=(nt+nProc-1)/nProc
  else
     nLonPar=nt/nProc
  endif
  
  !Define neighbors and ghost cell indicies
  iProcLeft=iProc-1
  iLonLeft=MinLonPar-1
  if (iProcLeft < 0) then 
     iProcLeft=nProc-1
     iLonLeft = nt
  endif
  iProcRight=iProc+1
  iLonRight=MaxLonPar+1
  if (iProcRight == nProc) then
     iProcRight=0
     iLonRight=1
  endif

  
  if (.not.allocated(nLonBefore_P)) allocate(nLonBefore_P(0:nProc-1))
  if (.not.allocated(nLonPar_P))    allocate(nLonPar_P(0:nProc-1))
  call MPI_allgather(nLonPar,1,MPI_INTEGER,nLonPar_P,1,MPI_INTEGER,iComm,iError)
  nLonBefore_P(0) = 0
  do iPe = 1, nProc - 1
     nLonBefore_P(iPe) = sum(nLonPar_P(0:iPe-1))
  end do

  if (iProc == 0) then
     MinLonPar=1
     MaxLonPar=nLonPar
  else
     MinLonPar=sum(nLonPar_P(0:iProc-1))+1
     MaxLonPar=minLonPar+nLonPar-1
  endif

  !Define and iLonMidnightiProcMidnight, needed for setting iw2 in fieldpara
  iLonMidnight=nt/2
  if (nProc>1) then
     PROCLIST: do iPe=0,nProc-1
        if (nLonBefore_P(iPe)<iLonMidnight .and. &
             nLonBefore_P(iPe)+nLonPar_P(iPe)>=iLonMidnight)then
           iProcMidnight=iPe
        endif
     enddo PROCLIST
  else
     iProcMidnight=0
  endif
  ! Set start time

  call time_int_to_real(iStartTime_I,CurrentTime)
  StartTime=CurrentTime

  ! Define constants
  re_m = rPlanet_I(Earth_)                            ! earth's radius (m)
  dipmom=abs(DipoleStrengthPlanet_I(Earth_)*re_m**3)  ! earth's dipole moment
  

  ! CRCM xlat and xmlt grids
  do i=1,np
     xlat(i)=xlat_data(i)
     dlat(i)=0.5*(xlat_data(i+1)-xlat_data(i-1))*cDegToRad    ! dlat in radian
  enddo
  xlatr=xlat*cDegToRad  
  dphi=2.*cPi/nt
  do i=1,nt
     phi(i)=(i-1)*dphi
     xmlt(i)=mod(phi(i)*12.0/cPi + 12.0,24.0)   
  enddo

  ! CRCM output grids: energy, sinAo, delE1, dmu1
  energy=(/1.0000,1.6795,2.8209,4.7378,7.9574,13.365, &
       22.447,37.701,63.320,106.35,178.62,300.00/)
  delE=0.5243*energy
  sinAo=(/0.010021,0.030708,0.062026,0.086108,0.16073,0.27682, &
       0.430830,0.601490,0.753790,0.863790,0.94890,0.98827/)
  dmu=(/0.000207365,0.000868320,0.00167125,0.00489855,0.0165792,0.0404637, &
       0.078819500,0.121098000,0.14729600,0.16555900,0.1738560,0.2486830/)
  do k=2,neng
     Ebound(k)=sqrt(energy(k-1)*energy(k))
  enddo
  Ebound(1) = energy(1)**2.0/Ebound(2)
  Ebound(neng+1)=energy(neng)**2.0/Ebound(neng)

  ! CRCM magnetic moment, xmm1
  xmm(1)=energy(1)*cElectronCharge/(dipmom/(2*re_m)**3.0)
  dmm(1)=xmm(1)*2.              
  rw=1.55                       
  do i=2,nm                    
     dmm(i)=dmm(1)*rw**(i-1)           
     xmm(i)=xmm(i-1)+0.5*(dmm(i-1)+dmm(i))
  enddo

  ! CRCM K, xk
  rsi=1.47
  xk(1)=40.*rsi
  rs1=(rsi-1.)/sqrt(rsi) ! in following sutup: xk(i+0.5)=sqrt(xk(i)*xk(i+1))
  do i=1,nk
     if (i.gt.1) xk(i)=xk(i-1)*rsi
     dk(i)=xk(i)*rs1                 
  enddo

  ! Calculate Jacobian, xjac
  do n=1,nspec 
     xjac1=4.*sqrt(2.)*cPi*(1.673e-27*amu_I(n))*dipmom/(re_m+Hiono*1000.)
     sqrtm=sqrt(1.673e-27*amu_I(n))
     do i=1,np
        do k=1,nm
           xjac(n,i,k)=xjac1*sin(2.*xlatr(i))*sqrt(xmm(k))*sqrtm
        enddo
     enddo
  enddo

  ! Calculate d4Element_C: dlat*dphi*dmm*dk
      do i=1,np
         d2=dlat(i)*dphi
         do k=1,nm
            do m=1,nk
               d4Element_C(i,k,m)=d2*dmm(k)*dk(m)
            enddo
         enddo
      enddo

  if(IsRestart) then
     !set initial state when restarting
     call crcm_read_restart
  endif

end subroutine crcm_init

!-------------------------------------------------------------------------------
subroutine initial_f2(nspec,np,nt,iba,amu_I,vel,xjac,ib0)
  !-----------------------------------------------------------------------------
  ! Routine setup initial distribution.
  ! 
  ! Input: nspec,np,nt,iba,Den_IC,Temp_IC,amu,vel,xjac
  ! Output: ib0,f2,rbsum,xleb,xled,xlel,xlee,xles,driftin,driftout
  !         (through common block cinitial_f2)
  use ModIoUnit, ONLY: UnitTmp_
  use ModGmCrcm, ONLY: Den_IC, Temp_IC, Temppar_IC, DoAnisoPressureGMCoupling
  use ModCrcm,   ONLY: f2,eChangeOperator_IV,nOperator,driftin,driftout,rbsumLocal,rbsumGlobal
  use ModCrcmInitialize,   ONLY: IsEmptyInitial, IsDataInitial, IsGmInitial
  use ModCrcmGrid,ONLY: nm,nk,MinLonPar,MaxLonPar,iProc,nProc,iComm,d4Element_C
  use ModFieldTrace, ONLY: sinA,ro, ekev,pp,iw2,irm
  use ModMpi
  implicit none

  integer,parameter :: np1=51,nt1=48,nspec1=1  
  !integer,parameter :: nm=35,nk=28 ! dimension of CRCM magnetic moment and K
 
  integer nspec,np,nt,iba(nt),ib0(nt),n,j,i,k,m, iError
  real amu_I(nspec),vel(nspec,np,nt,nm,nk)
  real velperp2, velpar2
  real xjac(nspec,np,nm),pi,xmass,chmass,f21,vtchm
  real Tempperp_IC(nspec,np,nt)
  real xleb(nspec),xled(nspec),xlel(nspec),xlee(nspec),xles(nspec)

  ! Variables needed for data initialization 
  integer :: il, ie, iunit
  real, allocatable :: roi(:), ei(:), fi(:,:)
  real :: roii, e1,x, fluxi,psd2
  
  character(11) :: NameFile='quiet_x.fin'
  pi=acos(-1.)

  ib0=iba
  f2=0.

  if (IsEmptyInitial) then
     ! Set initial f2 to a small number
     f2(:,:,:,:,:)=1.0e-40
  elseif(IsGmInitial) then
     ! Set initial f2 based on Maxwellian or bi-Maxwellian
     if(DoAnisoPressureGMCoupling) &
          Tempperp_IC(:,:,:) = (3*Temp_IC(:,:,:) - Temppar_IC(:,:,:))/2.
     do n=1,nspec
        xmass=amu_I(n)*1.673e-27
        chmass=1.6e-19/xmass
        do j=MinLonPar,MaxLonPar
           do i=1,iba(j)
              if(DoAnisoPressureGMCoupling)then
                 f21=Den_IC(n,i,j)/(2.*pi*xmass*Temppar_IC(n,i,j)*1.6e-19)**0.5 &
                      /(2.*pi*xmass*Tempperp_IC(n,i,j)*1.6e-19)
              else
                 f21=Den_IC(n,i,j)/(2.*pi*xmass*Temp_IC(n,i,j)*1.6e-19)**1.5
              end if
              do k=1,nm
                 do m=1,nk
                    if(DoAnisoPressureGMCoupling)then
                       velperp2 = (vel(n,i,j,k,m)*sinA(i,j,m))**2
                       velpar2 = vel(n,i,j,k,m)**2 - velperp2
                       vtchm = -velpar2/(2*Temppar_IC(n,i,j)*chmass) &
                            -velperp2/(2*Tempperp_IC(n,i,j)*chmass)
                    else                    
                       vtchm = -vel(n,i,j,k,m)**2/(2*Temp_IC(n,i,j)*chmass)
                    end if
                    f2(n,i,j,k,m)=xjac(n,i,k)*f21*exp(vtchm)
                 end do
              end do
           end do
        end do
     end do
  elseif(IsDataInitial) then
     do n=1,nspec
        !set the file name, open it and read it
        if(n==1) NameFile='quiet_h.fin'
        if(n==2 .and. n /= nspec) then 
           NameFile='quiet_o.fin'
        else
           if(n==1) NameFile='quiet_e.fin'
        endif
        if (n==nspec) NameFile='quiet_e.fin'
        open(unit=UnitTmp_,file='IM/'//NameFile,status='old')
        read(UnitTmp_,*) il,ie
        allocate (roi(il),ei(ie),fi(il,ie))
        read(UnitTmp_,*) iunit   ! 1=flux in (cm2 s sr keV)^-1, 2=in (cm2 s MeV)^-1
        read(UnitTmp_,*) roi
        read(UnitTmp_,*) ei      ! ei in keV
        read(UnitTmp_,*) fi
        close(UnitTmp_)
        if(iunit.eq.2) fi(:,:)=fi(:,:)/4./pi/1000. !con.To(cm^2 s sr keV)^-1\
        
        
        ei(:)=log10(ei(:))                      ! take log of ei 
        fi(:,:)=log10(fi(:,:))                  ! take log of fi
        
        
        !interpolate data from quiet.fin files to CRCM grid
        do j=MinLonPar,MaxLonPar
           do i=1,irm(j)
              roii=ro(i,j)
              do m=1,nk
                 do k=1,iw2(m)
                    e1=log10(ekev(i,j,k,m)) 
                    if (e1.le.ei(ie)) then
                       if (e1.lt.ei(1)) e1=ei(1)    ! flat dist. at low E
                       if (roii.lt.roi(1)) roii=roi(1) ! flat dist @ lowL
                       if (roii.gt.roi(il)) roii=roi(il) ! flat @ high L
                       call lintp2IM(roi,ei,fi,il,ie,roii,e1,x)
                       fluxi=10.**x          ! flux in (cm^2 s sr keV)^-1
                       psd2=fluxi/(1.6e19*pp(n,i,j,k,m))/pp(n,i,j,k,m)
                       f2(n,i,j,k,m)=psd2*xjac(n,i,k)*1.e20*1.e19  
                    endif
                 enddo                            ! end of k loop
              enddo                               ! end of m loop
              
           enddo                                  ! end of i loop
        enddo                                     ! end of j loop
        deallocate (roi,ei,fi)
        !f2(:,1,:,:,:)=f2(:,2,:,:,:)
     enddo                                        ! end of n loop
  end if

! Calculation of rbsum
  do n=1,nspec
     call calc_rbsumlocal(n)
     !reduce local sum to global
     if (nProc >0) then
        call MPI_REDUCE (rbsumLocal(n), rbsumGlobal(n), 1, MPI_REAL, &
               MPI_SUM, 0, iComm, iError)
     else
        rbsumGlobal(n)=rbsumLocal(n)
     endif
  enddo                 


! Setup variables for energy gain/loss from each process
  eChangeOperator_IV(1:nspec,1:nOperator)=0.0
!  xleb(1:nspec)=0.          ! energy gain/loss due to changing B field        
!  xled(1:nspec)=0.          ! energy gain/loss due to drift
!  xlel(1:nspec)=0.          ! energy loss due to losscone 
!  xlee(1:nspec)=0.          ! energy loss due to charge exchange         
!  xles(1:nspec)=0.          ! energy loss due to strong diffusion 
  driftin(1:nspec)=0.      ! energy gain due injection
  driftout(1:nspec)=0.     ! energy loss due drift-out loss

end subroutine initial_f2


!-------------------------------------------------------------------------------
subroutine boundaryIM(nspec,np,nt,nm,nk,iba,irm,amu_I,xjac,vel,fb)
  !-----------------------------------------------------------------------------
  ! Routine setup the boundary distribution for the CRCM. Distribution at the
  ! boundary is assumed to be Maxwellian. Boundary temperature and density are
  ! from MHD.
  !
  ! Input: nspec,np,nt,nm,nk,iba,irm,amu,xjac,Den_IC,Temp_IC,vel
  ! Output: fb
  Use ModGmCrcm, ONLY: Den_IC, Temp_IC, Temppar_IC, DoAnisoPressureGMCoupling
  use ModCrcm,       ONLY: MinLonPar,MaxLonPar, f2
  use ModFieldTrace, ONLY: sinA
  implicit none

  integer nspec,np,nt,nm,nk,iba(nt),irm(nt),j,n,k,m,ib1
  real amu_I(nspec),xjac(nspec,np,nm)
  real vel(nspec,np,nt,nm,nk),fb(nspec,nt,nm,nk),pi,xmass,chmass,fb1,vtchm
  real velperp2, velpar2
  real Tempperp_IC(nspec,np,nt)

  pi=acos(-1.)

  if(DoAnisoPressureGMCoupling) &
          Tempperp_IC(:,:,:) = (3*Temp_IC(:,:,:) - Temppar_IC(:,:,:))/2.
  
  do n=1,nspec
     xmass=amu_I(n)*1.673e-27
     chmass=1.6e-19/xmass
     do j=MinLonPar,MaxLonPar
        ib1=iba(j)+1
        if (ib1.gt.irm(j)) ib1=irm(j)
        if(DoAnisoPressureGMCoupling)then
           fb1=Den_IC(n,ib1,j)/(2.*pi*xmass*Temppar_IC(n,ib1,j)*1.6e-19)**0.5 &
                /(2.*pi*xmass*Tempperp_IC(n,ib1,j)*1.6e-19)
        else
           fb1=Den_IC(n,ib1,j)/(2.*pi*xmass*Temp_IC(n,ib1,j)*1.6e-19)**1.5
        end if
        do k=1,nm
           do m=1,nk
              if(DoAnisoPressureGMCoupling)then
                 velperp2 = (vel(n,ib1,j,k,m)*sinA(ib1,j,m))**2
                 velpar2 = vel(n,ib1,j,k,m)**2 - velperp2
                 vtchm = -velpar2/(2*Temppar_IC(n,ib1,j)*chmass) &
                      -velperp2/(2*Tempperp_IC(n,ib1,j)*chmass)
              else                    
                 vtchm = -vel(n,ib1,j,k,m)**2/(2*Temp_IC(n,ib1,j)*chmass)
              end if
                 fb(n,j,k,m)=xjac(n,ib1,k)*fb1*exp(vtchm)
           enddo
        enddo
     enddo
  enddo

end subroutine boundaryIM


!-------------------------------------------------------------------------------
subroutine ceparaIM(nspec,np,nt,nm,nk,irm,dt,vel,ekev,Have,achar)
  !-----------------------------------------------------------------------------
  ! Routine calculates the depreciation factor of H+, achar, due to charge
  ! exchange loss
  !
  ! Input: irm,nspec,np,nt,nm,nk,dt,vel,ekev,Have     ! Have: bounce-ave [H]
  ! Output: achar
  use ModCrcmPlanet,  ONLY: a0_I,a1_I,a2_I,a3_I,a4_I
  use ModCrcm,       ONLY: MinLonPar,MaxLonPar
  
  implicit none

  integer np,nt,nspec,nk,irm(nt),nm,i,j,k,m,n
  real vel(nspec,np,nt,nm,nk),ekev(np,nt,nm,nk),Have(np,nt,nk)
  real achar(nspec,np,nt,nm,nk),dt,Havedt,x,d,sigma,alpha

  do n=1,nspec-1
     do j=MinLonPar,MaxLonPar
        do i=1,irm(j)
           do m=1,nk
              Havedt=Have(i,j,m)*dt
              do k=1,nm
                 x=log10(ekev(i,j,k,m))
                 if (x.lt.-2.) x=-2.
                 d=a0_I(n)+a1_I(n)*x+a2_I(n)*x**2+a3_I(n)*x**3+a4_I(n)*x**4
                 sigma=10.**d        ! charge exchange cross section of H+ in m2
                 alpha=vel(n,i,j,k,m)*sigma*Havedt
                 achar(n,i,j,k,m)=exp(-alpha) ! charge. exchange decay rate
              enddo
           enddo
        enddo
     enddo
  enddo

end subroutine ceparaIM


!-------------------------------------------------------------------------------
subroutine driftV(nspec,np,nt,nm,nk,irm,re_m,Hiono,dipmom,dphi,xlat, &
     dlat,ekev,pot,vl,vp)
  !-----------------------------------------------------------------------------
  ! Routine calculates the drift velocities
  !
  ! Input: re_m,Hiono,dipmom,dphi,xlat,dlat,ekev,pot,nspec,np,nt,nm,nk,irm
  ! Output: vl,vp
  use ModCrcmGrid, ONLY: iProc,nProc,iComm,MinLonPar,MaxLonPar, &
       iProcLeft, iLonLeft, iProcRight, iLonRight
  use ModMpi 
  implicit none

  integer nspec,np,nt,nm,nk,irm(nt),n,i,ii,j,k,m,i0,i2,j0,j2,icharge
  real kfactor,xlat(np),xlatr(np),dlat(np),ekev(np,nt,nm,nk),pot(np,nt)
  real ksai,ksai1,xlat1,sf0,sf2,dlat2,re_m,Hiono,dipmom,dphi,pi,dphi2,cor
  real ham(np,nt),vl(nspec,0:np,nt,nm,nk),vp(nspec,np,nt,nm,nk)

  ! MPI status variable
  integer :: iStatus_I(MPI_STATUS_SIZE), iError

  pi=acos(-1.)
  dphi2=dphi*2.
  kfactor=dipmom/(re_m+Hiono*1000.)
  cor=2.*pi/86400.                        ! corotation speed in rad/s
  xlatr=xlat*pi/180.

  nloop: do n=1,nspec
     if (n < nspec) then
        icharge=1
     else
        icharge=-1
     endif

     mloop: do m=1,nk
        kloop: do k=1,nm  

           ! ham: Hamiltonian/q
           ham(1:np,1:nt)=icharge*ekev(1:np,1:nt,k,m)*1000.+pot(1:np,1:nt)

           ! When nProc>1 exchange ghost cell info for ham and irm
           if (nProc >1) then
              !send to neigboring Procs
              call MPI_send(ham(1:np,MaxLonPar),np,MPI_REAL,iProcRight,&
                   1,iComm,iError)
              call MPI_send(ham(1:np,MinLonPar),np,MPI_REAL,iProcLeft,&
                   2,iComm,iError)
              call MPI_send(irm(MaxLonPar),1,MPI_INTEGER,iProcRight,&
                   3,iComm,iError)
              call MPI_send(irm(MinLonPar),1,MPI_INTEGER,iProcLeft,&
                   4,iComm,iError)
              !recieve from neigboring Procs
              call MPI_recv(ham(1:np,iLonLeft),np,MPI_REAL,iProcLeft,&
                   1,iComm,iStatus_I,iError)
              call MPI_recv(ham(1:np,iLonRight),np,MPI_REAL,iProcRight,&
                   2,iComm,iStatus_I,iError)
              call MPI_recv(irm(iLonLeft),1,MPI_INTEGER,iProcLeft,&
                   3,iComm,iStatus_I,iError)
              call MPI_recv(irm(iLonRight),1,MPI_INTEGER,iProcRight,&
                   4,iComm,iStatus_I,iError)
              
           endif

           ! calculate drift velocities vl and vp
           iloop: do i=0,np
              ii=i
              if (i.eq.0) ii=1
              if (i.ge.1) ksai=kfactor*sin(2.*xlatr(i))
              if (i.lt.np) xlat1=0.5*(xlatr(ii)+xlatr(i+1))    ! xlat(i+0.5)
              ksai1=kfactor*sin(2.*xlat1)                   ! ksai at i+0.5
              jloop: do j=MinLonPar,MaxLonPar
                 j0=j-1
                 if (j0.lt.1) j0=j0+nt
                 j2=j+1
                 if (j2.gt.nt) j2=j2-nt

                 ! calculate vl 
                 if (irm(j0).gt.i.and.irm(j2).gt.i) then
                    sf0=0.5*ham(ii,j0)+0.5*ham(i+1,j0)
                    sf2=0.5*ham(ii,j2)+0.5*ham(i+1,j2)
                    vl(n,i,j,k,m)=-(sf2-sf0)/dphi2/ksai1   ! vl at (i+0.5,j)
                 else
                    vl(n,i,j,k,m)=vl(n,i-1,j,k,m)
                 endif

                 ! calculate vp
                 if (i.ge.1) then
                    if (irm(j2).gt.i) then
                       i0=i-1
                       if (i.eq.1) i0=1
                       i2=i+1
                       if (i.eq.np) i2=np
                       dlat2=xlatr(i2)-xlatr(i0)
                       sf0=0.5*(ham(i0,j2)+ham(i0,j))
                       sf2=0.5*(ham(i2,j2)+ham(i2,j))
                       vp(n,i,j,k,m)=cor+(sf2-sf0)/dlat2/ksai  ! vp at (i,j+0.5)
                    else
                       vp(n,i,j,k,m)=vp(n,i-1,j,k,m)
                    endif
                 endif

              enddo jloop
           enddo iloop
        enddo kloop
     enddo mloop
  enddo nloop

end subroutine driftV


!-------------------------------------------------------------------------------
subroutine driftIM(iw2,nspec,np,nt,nm,nk,dt,dlat,dphi,brad,rb,vl,vp, &
     fb,f2,driftin,driftout,ib0)
  !-----------------------------------------------------------------------------
  ! Routine updates f2 due to drift
  !
  ! Input: iw2,nspec,np,nt,nm,nk,iba,dt,dlat,dphi,brad,rb,vl,vp,fbi
  ! Input/Output: f2,ib0,driftin,driftout
  use ModCrcmGrid, ONLY: iProc,nProc,iComm,MinLonPar,MaxLonPar, &
       iProcLeft, iLonLeft, iProcRight, iLonRight, d4Element_C
  use ModFieldTrace, ONLY: iba, ekev
    
  use ModMpi
  implicit none

  integer nk,iw2(nk),nspec,np,nt,nm,ib0(nt)
  integer n,i,j,k,m,j1,j_1,ibaj,ib,ibo,nrun,nn
  real dt,dlat(np),dphi,brad(np,nt),vl(nspec,0:np,nt,nm,nk),vp(nspec,np,nt,nm,nk)
  real rb,fb(nspec,nt,nm,nk),f2(nspec,np,nt,nm,nk)
  real f2d(np,nt),cmax,cl1,cp1,cmx,dt1,fb0(nt),fb1(nt),fo_log,fb_log,f_log
  real slope,cl(np,nt),cp(np,nt),fal(0:np,nt),fap(np,nt),fupl(0:np,nt),fupp(np,nt)
  real driftin(nspec),driftout(nspec),dEner,dPart,dEnerLocal,dPartLocal
  logical :: UseUpwind=.false.

  ! MPI status variable
  integer :: iStatus_I(MPI_STATUS_SIZE)
  integer :: iError
  real, allocatable :: cmax_P(:)
  
  if (.not.allocated(cmax_P) .and. nProc>1) allocate(cmax_P(nProc))
  
  ! When nProc>1 pass iba from neighboring procs
  if (nProc >1) then
     !send to neigboring Procs
     call MPI_send(iba(MinLonPar),1,MPI_INTEGER,iProcLeft,&
          1,iComm,iError)
     !recieve from neigboring Procs
     call MPI_recv(iba(iLonRight),1,MPI_INTEGER,iProcRight,&
          1,iComm,iStatus_I,iError)
  endif

  nloop: do n=1,nspec
     mloop: do m=1,nk
        kloop: do k=1,iw2(m)
           f2d(1:np,1:nt)=f2(n,1:np,1:nt,k,m)         ! initial f2
           ! find nrun and new dt (dt1)
           cmax=0.
           do j=MinLonPar,MaxLonPar
              j1=j+1
              if (j1.gt.nt) j1=j1-nt
              ibaj=max(iba(j),iba(j1))
              do i=1,ibaj
                 cl1=dt/dlat(i)*vl(n,i,j,k,m)
                 cp1=dt/dphi*vp(n,i,j,k,m)
                 cmx=max(abs(cl1),abs(cp1))
                 cmax=max(cmx,cmax)
              enddo
           enddo
           
           !get same cmax on all procs
           if (nProc > 1) then
              call MPI_allgather(cmax,1,MPI_REAL,cmax_P,1,MPI_REAL,iComm,iError)
              cmax=maxval(cmax_P)
           endif
           
           nrun=ifix(cmax/0.50)+1     ! nrun to limit the Courant number
           dt1=dt/nrun                ! new dt
           ! Setup boundary fluxes and Courant numbers
           do j=MinLonPar,MaxLonPar
              ib=iba(j)
              ibo=ib0(j)
              fb0(j)=f2d(1,j)                   ! psd at inner boundary
              fb1(j)=fb(n,j,k,m)              ! psd at outer boundary
              if (ib.gt.ibo) then             ! during dipolarization
                 fo_log=-50.
                 if (f2d(ibo,j).gt.1.e-50) fo_log=log10(f2d(ibo,j))
                 fb_log=-50.
                 if (fb1(j).gt.1.e-50) fb_log=log10(fb1(j))
                 slope=(fo_log-fb_log)/(brad(ibo,j)-rb)
                 do i=ibo+1,ib
                    f_log=fo_log+slope*(brad(i,j)-brad(ibo,j))
                    f2d(i,j)=10.**f_log
                 enddo
              endif
              do i=1,np
                 cl(i,j)=dt1/dlat(i)*vl(n,i,j,k,m)
                 cp(i,j)=dt1/dphi*vp(n,i,j,k,m)
              enddo
           enddo

           ! run drift nrun times
           do nn=1,nrun
              UseUpwind=.false.
              ! When nProc>1, pass fb0, fb1, and f2d
              !send to neigboring Procs
             if (nProc>1) then
                 !send f2d ghostcells
                 call MPI_send(f2d(1:np,MaxLonPar),np,MPI_REAL,iProcRight,&
                      3,iComm,iError)
                 call MPI_send(f2d(1:np,MinLonPar:MinLonPar+1),2*np,MPI_REAL,&
                      iProcLeft,4,iComm,iError)
                 !recieve f2d ghostcells from neigboring Procs
                 call MPI_recv(f2d(1:np,iLonLeft),np,MPI_REAL,iProcLeft,&
                      3,iComm,iStatus_I,iError)
                 call MPI_recv(f2d(1:np,iLonRight:iLonRight+1),2*np,MPI_REAL,&
                      iProcRight,4,iComm,iStatus_I,iError)

                 !send fb0 ghostcells
                 call MPI_send(fb0(MinLonPar:MinLonPar+1),2,MPI_REAL,iProcLeft,&
                      5,iComm,iError)
                 call MPI_send(fb0(MaxLonPar),1,MPI_REAL,iProcRight,&
                      6,iComm,iError)
                 !recieve fb0 from neigboring Procs
                 call MPI_recv(fb0(iLonRight:iLonRight+1),2,MPI_REAL,&
                      iProcRight,5,iComm,iStatus_I,iError)
                 call MPI_recv(fb0(iLonLeft),1,MPI_REAL,iProcLeft,&
                      6,iComm,iStatus_I,iError)

                 !send fb1 ghostcells
                 call MPI_send(fb1(MinLonPar:MinLonPar+1),2,MPI_REAL,iProcLeft,&
                      7,iComm,iError)
                 call MPI_send(fb1(MaxLonPar),1,MPI_REAL,iProcRight,&
                      8,iComm,iError)
                 !recieve fb1 from neigboring Procs
                 call MPI_recv(fb1(iLonRight:iLonRight+1),2,MPI_REAL,&
                      iProcRight,7,iComm,iStatus_I,iError)
                 call MPI_recv(fb1(iLonLeft),1,MPI_REAL,iProcLeft,&
                      8,iComm,iStatus_I,iError)
              endif
              call FLS_2D(np,nt,iba,fb0,fb1,cl,cp,f2d,fal,fap,fupl,fupp)
              fal(0,1:nt)=f2d(1,1:nt)
              ! When nProc>1 pass needed ghost cell info for fap,fupp and cp
              if (nProc>1) then
                 !send fap ghostcells
                 call MPI_send(fap(:,MaxLonPar),np,MPI_REAL,iProcRight,&
                      9,iComm,iError)
                 !recieve fap from neigboring Procs
                 call MPI_recv(fap(:,iLonLeft),np,MPI_REAL,iProcLeft,&
                      9,iComm,iStatus_I,iError)

                 !send fupp ghostcells
                 call MPI_send(fupp(:,MaxLonPar),np,MPI_REAL,iProcRight,&
                      10,iComm,iError)
                 !recieve fupp from neigboring Procs
                 call MPI_recv(fupp(:,iLonLeft),np,MPI_REAL,iProcLeft,&
                      10,iComm,iStatus_I,iError)

                 !send cp ghostcells
                 call MPI_send(cp(:,MaxLonPar),np,MPI_REAL,iProcRight,&
                      11,iComm,iError)
                 !recieve cp from neigboring Procs
                 call MPI_recv(cp(:,iLonLeft),np,MPI_REAL,iProcLeft,&
                      11,iComm,iStatus_I,iError)
              endif

              jloop: do j=MinLonPar,MaxLonPar
                 j_1=j-1
                 if (j_1.lt.1) j_1=j_1+nt
                 iloop: do i=1,iba(j)
                    f2d(i,j)=f2d(i,j)+dt1/dlat(i)* &
                         (vl(n,i-1,j,k,m)*fal(i-1,j)-vl(n,i,j,k,m)*fal(i,j))+ &
                         cp(i,j_1)*fap(i,j_1)-cp(i,j)*fap(i,j)
                    if (f2d(i,j).lt.0.) then
                       if (f2d(i,j).gt.-1.e-30) then
                          f2d(i,j)=0.
                       else
                          write(*,*)'IM WARNING: f2d < 0 in drift ',n,i,j,k,m
                          write(*,*)'IM WARNING: Retrying step with upwind scheme'
                          UseUpwind=.true.
                          exit jloop
                       endif
                    endif
                 enddo iloop
                 ! Calculate gain or loss at the outer boundary
                 dPartLocal = -dt1/dlat(iba(j)) &
                      *vl(n,iba(j),j,k,m)*fal(iba(j),j)*d4Element_C(iba(j),k,m)
                 dEnerLocal=ekev(iba(j),j,k,m)*dPartLocal
                 !sum all dEner to root proc
                 if(nProc>1) then
                    call MPI_REDUCE (dPartLocal, dPart, 1, MPI_REAL, &
                         MPI_SUM, 0, iComm, iError)
                    call MPI_REDUCE (dEnerLocal, dEner, 1, MPI_REAL, &
                         MPI_SUM, 0, iComm, iError)
                 else
                    dPart=dPartLocal
                    dEner=dEnerLocal
                 endif
                 
                 if(iProc==0) then
                    if (dPart.gt.0.) driftin(n)=driftin(n)+dEner
                    if (dPart.lt.0.) driftout(n)=driftout(n)+dEner
                 else
                    driftin(n)=0
                    driftout(n)=0
                 endif
              enddo jloop

              ! When regular scheme fails, try again with upwind scheme before 
              ! returning an error
              if (UseUpwind) then
                 fupl(0,1:nt)=f2d(1,1:nt)
                 do j=MinLonPar,MaxLonPar
                    j_1=j-1
                    if (j_1.lt.1) j_1=j_1+nt
                    iLoopUpwind: do i=1,iba(j)
                       f2d(i,j)=f2d(i,j)+dt1/dlat(i)* &
                        (vl(n,i-1,j,k,m)*fupl(i-1,j)-vl(n,i,j,k,m)*fupl(i,j))+ &
                        cp(i,j_1)*fupp(i,j_1)-cp(i,j)*fupp(i,j)
                       if (f2d(i,j).lt.0.) then
                          if (f2d(i,j).gt.-1.e-30) then
                             f2d(i,j)=0.
                          else
                             !write(*,*)'IM ERROR: f2d < 0 in drift ',n,i,j,k,m
                             !call CON_STOP('CRCM dies in driftIM')
                             !write(*,*)'IM WARNING: f2d < 0 in drift ',n,i,j,k,m
                             !write(*,*)'IM WARNING: upwind scheme failed, setting f2d(i,j)=0.0'
                             !write(*,*)'IM WARNING: repeated failure may need to be examined'
                             ! should now have f2d(i,j)=0. but didnt before

                             write(*,*)'IM WARNING: f2d < 0 in drift ',n,i,j,k,m
                             write(*,*)'IM WARNING: upwind scheme failed, making iba(j)=i'
                             write(*,*)'IM WARNING: repeated failure may need to be examined'
                             f2d(i,j)=0.0
                             iba(j)=i
                             exit iLoopUpwind
                          endif
                       endif
                    enddo iLoopUpwind
                    ! Calculate gain or loss at the outer boundary
                    dPartLocal=-dt1/dlat(iba(j))*vl(n,iba(j),j,k,m)*fupl(iba(j),j)*d4Element_C(iba(j),k,m)
                    dEnerLocal=ekev(iba(j),j,k,m)*dPart
                    !sum all dEner to root proc
                    if(nProc>1) then
                       call MPI_REDUCE (dPartLocal, dPart, 1, MPI_REAL, &
                            MPI_SUM, 0, iComm, iError)
                       call MPI_REDUCE (dEnerLocal, dEner, 1, MPI_REAL, &
                            MPI_SUM, 0, iComm, iError)
                    else
                       dPart=dPartLocal
                       dEner=dEnerLocal
                    endif
                    if(iProc==0) then
                       if (dPart.gt.0.) driftin(n)=driftin(n)+dEner
                       if (dPart.lt.0.) driftout(n)=driftout(n)+dEner
                    else
                       driftin(n)=0
                       driftout(n)=0
                    endif
                 enddo
              endif
           enddo          ! end of do nn=1,nrun
           f2(n,1:np,1:nt,k,m)=f2d(1:np,1:nt)
        enddo kloop
     enddo mloop
  enddo nloop


  ! Update ib0
  ib0(1:nt)=iba(1:nt)

end subroutine driftIM


!-------------------------------------------------------------------------------
subroutine charexchangeIM(np,nt,nm,nk,nspec,iba,achar,f2)
  !-----------------------------------------------------------------------------
  ! Routine updates f2 due to charge exchange loss
  !
  ! Input: np,nt,nm,nk,nspec,achar   ! charge exchange depreciation of H+ 
  ! Input/Output: f2
  use ModCrcm,       ONLY: MinLonPar,MaxLonPar
  implicit none

  integer np,nt,nm,nk,nspec,iba(nt),n,i,j
  real achar(nspec,np,nt,nm,nk),f2(nspec,np,nt,nm,nk)

  do n=1,nspec-1             
     do j=MinLonPar,MaxLonPar
        do i=1,iba(j)
           f2(n,i,j,1:nm,1:nk)=f2(n,i,j,1:nm,1:nk)*achar(n,i,j,1:nm,1:nk)
        enddo
     enddo
  enddo
 
end subroutine charexchangeIM

!******************************************************************************
!                                StDiTime                                      
!  Routine calculate the strong diffusion lifetime for electrons.     
!*****************************************************************************
subroutine StDiTime(dt,vel,volume,rc,re_m,xme,iba)
  use ModCrcm,       ONLY: SDtime
  use ModCrcmGrid,   ONLY: np,nt,nm,nk, xlatr,MinLonPar,MaxLonPar
  use ModCrcmPlanet, ONLY: nspec
  real vel(nspec,np,nt,nm,nk),volume(np,nt)
  integer iba(nt)
  
  
  eb=0.25                         ! fraction of back scatter e-   
  xmer3=xme/(rc*re_m)**3
  
  do j=MinLonPar,MaxLonPar
     do i=1,iba(j)
        !              xlat2=xlati(i)*xlati(i)!- from M.-Ch., Aug 1 2007  
        !              Bi=xmer3*sqrt(3.*xlat2+1.)     
        sinlat2=sin(xlatr(i))*sin(xlatr(i))
        Bi=xmer3*sqrt(3.*sinlat2+1.)      ! magnetic field at ionosphere 
        
        vBe=2.*volume(i,j)*Bi/(1.-eb)
        do k=1,nm
           do m=1,nk
              SDtime1=vBe/vel(nspec,i,j,k,m) !strong diff T,(gamma*mo/p = 1/v)
              SDtime(i,j,k,m)=exp(-dt/SDtime1)
           enddo
        enddo
     enddo
  enddo
  
  return
end subroutine StDiTime


!***********************************************************************   
!                            StrongDiff                                     
!  Routine calculate the change of electron psd (f2) by strong diffusion  
!***********************************************************************        
subroutine StrongDiff(iba)                               
  use ModCrcm,       ONLY: SDtime,f2
  use ModCrcmGrid,   ONLY: np,nt,nm,nk,MinLonPar,MaxLonPar
  use ModCrcmPlanet, ONLY: nspec  
  implicit none
  integer iba(nt),i,j,k,m
  
  do j=MinLonPar,MaxLonPar
     do i=2,iba(j)
        do m=1,nk
           do k=1,nm
              f2(nspec,i,j,k,m)=f2(nspec,i,j,k,m)*SDtime(i,j,k,m)
           enddo
        enddo
     enddo
  enddo
  
  return
end subroutine StrongDiff



!-------------------------------------------------------------------------------
subroutine lossconeIM(np,nt,nm,nk,nspec,iba,alscone,f2)
  !-----------------------------------------------------------------------------
  ! Routine calculate the change of f2 due to lossconeIM loss
  ! 
  ! Input: np,nt,nm,nk,nspec,iba,alscone
  ! Input/Output: f2
  use ModCrcm,       ONLY: MinLonPar,MaxLonPar
  implicit none

  integer np,nt,nm,nk,nspec,iba(nt),n,i,j,k,m
  real alscone(nspec,np,nt,nm,nk),f2(nspec,np,nt,nm,nk)

  do n=1,nspec
     do j=MinLonPar,MaxLonPar
        do i=1,iba(j)
           do k=1,nm
              do m=1,nk
                 if (alscone(n,i,j,k,m).lt.1.) &
                      f2(n,i,j,k,m)=f2(n,i,j,k,m)*alscone(n,i,j,k,m)
              enddo
           enddo
        enddo
     enddo
  enddo

end subroutine lossconeIM

!==============================================================================

subroutine sume(xle)
!-------------------------------------------------------------------------------
! Routine updates rbsum and xle
! 
! Input: f2,ekev,iba
! Input/Output: rbsum,xle
  use ModCrcm,       ONLY: rbsumLocal
  use ModFieldTrace, ONLY: iba
  use ModCrcmGrid,   ONLY: nProc,iProc,iComm
  use ModCrcmPlanet, ONLY: nspec
  use ModMPI
  implicit none
  
  real, intent(inout):: xle(nspec)
  
  integer n,i,j,k,m,iError
  real rbsumLocal0,xleChange,xleChangeLocal

  do n=1,nspec
     rbsumLocal0=rbsumLocal(n)
     
     call calc_rbsumlocal(n)

     xleChangeLocal=rbsumLocal(n)-rbsumLocal0
     
     if (nProc >1) call MPI_REDUCE (xleChangeLocal, xleChange, 1, MPI_REAL, &
           MPI_SUM, 0, iComm, iError)

     if(iProc==0) then 
        xle(n)=xle(n)+xleChange
     else
        xle(n)=0.0
     endif
 enddo

end subroutine sume

!==============================================================================

subroutine calc_rbsumlocal(iSpecies)
  use ModCrcm,       ONLY: f2,rbsumLocal
  use ModCrcmGrid,   ONLY: np,nm,nk,MinLonPar,MaxLonPar,d4Element_C
  use ModFieldTrace, ONLY: iba, ekev
  implicit none

  integer, intent(in) :: iSpecies
  real    :: weight
  integer :: i,j,k,m
  !-----------------------------------------------------------------------------
  rbsumLocal(iSpecies)=0.
  do j=MinLonPar,MaxLonPar
     do i=1,iba(j)
        do k=1,nm
           do m=1,nk
              weight=f2(iSpecies,i,j,k,m)*d4Element_C(i,k,m)*ekev(i,j,k,m)
              rbsumLocal(iSpecies)=rbsumLocal(iSpecies)+weight        ! rbsum in keV
           enddo
        enddo
     enddo
  enddo

end subroutine calc_rbsumlocal

!==============================================================================

subroutine crcm_output(np,nt,nm,nk,nspec,neng,npit,iba,ftv,f2,ekev, &
     sinA,energy,sinAo,delE,dmu,amu_I,xjac,pp,xmm, &
     dmm,dk,xlat,dphi,re_m,Hiono,flux,fac,phot,Ppar_IC,Pressure_IC,PressurePar_IC)
  !-----------------------------------------------------------------------------
  ! Routine calculates CRCM output, flux, fac and phot from f2
  !
  ! Input: np,nt,nm,nk,nspec,neng,npit,iba,ftv,f2,ekev,sinA,energy,sinAo,xjac
  !        delE,dmu,amu_I,xjac,pp,xmm,dmm,dk,xlat,dphi,re_m,Hiono
  ! Output: flux,fac,phot,Ppar_IC,Den_IC,Temp_IC
  Use ModGmCrcm, ONLY: Den_IC, Temp_IC
  use ModConst,   ONLY: cProtonMass
  use ModNumConst,ONLY: cPi, cDegToRad
  use ModCrcmGrid,ONLY: iProc,nProc,iComm,MinLonPar,MaxLonPar,&
       iProcLeft, iLonLeft, iProcRight, iLonRight
  use ModMpi
  implicit none

  integer np,nt,nm,nk,nspec,neng,npit,iba(nt),i,j,k,m,n,j1,j_1
  real f2(nspec,np,nt,nm,nk),ekev(np,nt,nm,nk),sinA(np,nt,nk),re_m,Hiono,rion
  real ftv(np,nt),ftv1,energy(neng),sinAo(npit),delE(neng),dmu(npit),aloge(neng)
  real flux2D(nm,nk),pp(nspec,np,nt,nm,nk),xjac(nspec,np,nm)
  real sinA1D(nk),cosA2(nk),flx,ekev2D(nm,nk),flx_lo,pf(nspec),delEE(neng),pi,cosAo2(npit)
  real sina1,sina0,dcosa
  real amu_I(nspec),amu1,psd1,psd(nspec,np,nt,nm,nk),fave(nspec,np,nt,neng)
  real xmm(nm),dmm(nm),dk(nk),xlat(np),xlatr(np),dphi,eta(nspec,np,nt,nm,nk)
  real flux(nspec,np,nt,neng,npit),detadi,detadj,dwkdi,dwkdj
  real fac(np,nt),phot(nspec,np,nt),Ppar_IC(nspec,np,nt)
  real Pressure_IC(nspec,np,nt), PressurePar_IC(nspec,np,nt)
  real Pressure0, Pressure1, PressurePar1, Coeff
  integer :: iStatus_I(MPI_STATUS_SIZE), iError
  logical, parameter :: DoCalcFac=.true.
  flux=0.
  fac=0.
  eta=0.
  phot=0.
  Ppar_IC = 0.
  PressurePar_IC = 0.

  ! Some constants for pressure, fac calculations
  rion=re_m+Hiono*1000.                      ! ionosphere distance in meter
  do n=1,nspec
     pf(n)=4.*cPi*1.e4/3.*sqrt(2.*cProtonMass*amu_I(n))*sqrt(1.6e-16)*1.e9  ! phot(nPa)
  enddo
  delEE=delE*sqrt(energy)
  xlatr=xlat*cDegToRad

  ! Calculate CRCM ion density (m^-3), Den_IC, and flux (cm^-2 s^-1 keV^-1 sr^-1)
  ! at fixed energy & pitch-angle grids 
  aloge=log10(energy)
  jloop1: do j=MinLonPar,MaxLonPar
     iloop1: do i=1,iba(j)
        ftv1=ftv(i,j)     ! ftv1: flux tube volume in m^3/Wb
        nloop: do n=1,nspec
           Pressure0=0.0
           Pressure1=0.0
           PressurePar1=0.0
           Den_IC(n,i,j)=0.0
           amu1=amu_I(n)**1.5
!!!! Calculate Den_IC, and 2D flux, fl2D(log), ekev2D(log) and sinA1D
           do m=1,nk
              sinA1D(m) = sinA(i,j,m)
              cosA2(m) = 1 - sinA1D(m)**2
           end do
           do m=1,nk
              if (m.eq.1) sina0=1.
              if (m.gt.1) sina0=0.5*(sinA1D(m)+sinA1D(m-1))
              if (m.eq.nk) sina1=0.
              if (m.lt.nk) sina1=0.5*(sinA1D(m)+sinA1D(m+1))
              dcosa=sqrt(1.-sina1*sina1)-sqrt(1.-sina0*sina0)
              do k=1,nm
                 !write(*,*) 'n,i,k,xjac(n,i,k)',n,i,k,xjac(n,i,k)
                 psd1=f2(n,i,j,k,m)/1.e20/1.e19/xjac(n,i,k)  ! mug^-3cm^-6s^3
                 flx=psd1*(1.6e19*pp(n,i,j,k,m))*pp(n,i,j,k,m)
                 flux2D(k,m)=-50.
                 if (flx.gt.1.e-50) flux2D(k,m)=log10(flx)
                 ekev2D(k,m)=log10(ekev(i,j,k,m))
                 eta(n,i,j,k,m)=amu1*1.209*psd1*sqrt(xmm(k))*dmm(k)*dk(m)
                 psd(n,i,j,k,m)=psd1

                 ! The old rho and p calculation based on RCM method:
                 !   Den_IC(n,i,j) = Den_IC(n,i,j)+eta(n,i,j,k,m)/ftv1
                 !   Pressure0     = eta(n,i,j,k,m)*ekev(i,j,k,m)/ftv1
                 ! might be incorrect, giving different results from the 
                 ! following calculation based on integration of flux.
                 
                 ! Number density comes from the integration of "psd":
                 ! n = int(psd*dp^3) = int(flx/p^2*4*pi*p^2*sinA*dpdA)
                 ! with M = p^2/(2*m0*Bm) --> dp = p/2M*dM
                 ! so n = 2*pi*int(flx*p/M*dcosAdM)
                 ! 
                 ! Total pressure and parallel pressure are from
                 !   P    = 4*pi/3*int(E*flx*p/M*dcosAdM)
                 !   Ppar = 4*pi*int(E*flx*p/M*(cosA)^2*dcosAdM)
                 
                 Den_IC(n,i,j) = Den_IC(n,i,j) & 
                      + flx*pp(n,i,j,k,m)/xmm(k)*dmm(k)*dcosa
                 Pressure0 = ekev(i,j,k,m)*flx*pp(n,i,j,k,m)/xmm(k)*dmm(k)*dcosa
                 Pressure1 = Pressure1 + Pressure0
                 PressurePar1 = PressurePar1 + 3.*Pressure0*cosA2(m)
              enddo
           enddo
           
           Den_IC(n,i,j) = Den_IC(n,i,j)*2*cPi/1.6e-20   ! density in m^-3
           !Coeff = 1.6e-16*2./3.*1.e9                   ! for the old p
           Coeff = 4.*cPi/3.*1.e4*1.e9
           Pressure_IC(n,i,j) = Pressure1*Coeff          ! pressure in nPa
           PressurePar_IC(n,i,j) = PressurePar1*Coeff

!!!! Map flux to fixed energy and pitch-angle grids (energy, sinAo)
           do k=1,neng
              do m=1,npit
                 call lintp2aIM(ekev2D,sinA1D,flux2D,nm,nk,aloge(k),sinAo(m),flx_lo)
                 flux(n,i,j,k,m)=10.**flx_lo
              enddo
           enddo
        enddo nloop
     enddo iloop1
  enddo jloop1

  ! Calculate pressure of the 'hot' ring current, phot, and temperature, Temp_IC
  jloop2: do j=MinLonPar,MaxLonPar
     iloop2: do i=1,iba(j)
!!!! calculate pitch-angle averaged flux
        do n=1,nspec
           do k=1,neng
              fave(n,i,j,k)=0.
              do m=1,npit
                 fave(n,i,j,k)=fave(n,i,j,k)+flux(n,i,j,k,m)*dmu(m)
              enddo
           enddo
        enddo
!!!! calculate pressure and temperature
        do n=1,nspec
           do k=1,neng
              phot(n,i,j)=phot(n,i,j)+fave(n,i,j,k)*delEE(k)*pf(n) ! phot in nPa
           enddo
           Temp_IC(n,i,j)=0.
           if (Den_IC(n,i,j).gt.0.) &
                Temp_IC(n,i,j)=phot(n,i,j)*1.e-9/Den_IC(n,i,j)/1.6e-19   ! eV
        enddo
!!!! calculate parallel pressure
        cosAo2(1:npit) = 1-sinAo(1:npit)**2  !store 1-sinAo^2
        do n=1,nspec
           do k=1,neng
              do m=1,npit
                 Ppar_IC(n,i,j) = Ppar_IC(n,i,j) + flux(n,i,j,k,m) &
                      *cosAo2(m)*dmu(m)*delEE(k)*pf(n)*3.
              enddo
           enddo
        enddo
     enddo iloop2
  enddo jloop2


  if (DoCalcFac) then
     ! Calculate field aligned current, fac
     ! First get ghost cell info for eta and ekev when nProc>1
     if (nProc>1) then
        !send ekev ghostcells
        do k=1,nm
           do m=1,nk
              call MPI_send(ekev(:,MaxLonPar,k,m),np,MPI_REAL,iProcRight,&
                   1,iComm,iError)
              call MPI_send(ekev(:,MinLonPar,k,m),np,MPI_REAL,iProcLeft,&
                   2,iComm,iError)
              !recieve ekev from neigboring Procs
              call MPI_recv(ekev(:,iLonLeft,k,m),np,MPI_REAL,iProcLeft,&
                   1,iComm,iStatus_I,iError)
              call MPI_recv(ekev(:,iLonRight,k,m),np,MPI_REAL,iProcRight,&
                   2,iComm,iStatus_I,iError)
              do n=1,nspec
                 !send eta ghostcells
                 call MPI_send(eta(n,:,MaxLonPar,k,m),np,MPI_REAL,iProcRight,&
                      1,iComm,iError)
                 call MPI_send(eta(n,:,MinLonPar,k,m),np,MPI_REAL,iProcLeft,&
                      2,iComm,iError)
                 !recieve eta from neigboring Procs
                 call MPI_recv(eta(n,:,iLonLeft,k,m),np,MPI_REAL,iProcLeft,&
                      1,iComm,iStatus_I,iError)
                 call MPI_recv(eta(n,:,iLonRight,k,m),np,MPI_REAL,iProcRight,&
                      2,iComm,iStatus_I,iError)
              enddo
           enddo
        enddo
     endif
     jloop3: do j=MinLonPar,MaxLonPar
        j1=j+1
        j_1=j-1
        if (j1.gt.nt) j1=j1-nt          !! periodic boundary condition
        if (j_1.lt.1) j_1=j_1+nt        !!
        iloop3: do i=2,iba(j)-1
           do k=1,nm
              do m=1,nk
                 dwkdi=(ekev(i+1,j,k,m)-ekev(i-1,j,k,m))/(xlatr(i+1)-xlatr(i-1))
                 dwkdj=(ekev(i,j1,k,m)-ekev(i,j_1,k,m))/(2.*dphi)
                 do n=1,nspec
                    detadi=(eta(n,i+1,j,k,m)-eta(n,i-1,j,k,m))/(xlatr(i+1)-xlatr(i-1))
                    detadj=(eta(n,i,j1,k,m)-eta(n,i,j_1,k,m))/(2.*dphi)
                    fac(i,j)=fac(i,j)+(detadi*dwkdj-detadj*dwkdi)
                 enddo
              enddo
           enddo
           fac(i,j)=1.6e-16*fac(i,j)/cos(xlatr(i))/rion**2    ! fac in Amp/m^2
        enddo iloop3
     enddo jloop3
  else
     fac(:,:)=0.0
  endif
end subroutine crcm_output


!-------------------------------------------------------------------------------
subroutine FLS_2D(np,nt,iba,fb0,fb1,cl,cp,f2d,fal,fap,fupl,fupp)
!-------------------------------------------------------------------------------
  !  Routine calculates the inter-flux, fal(i+0.5,j) and fap(i,j+0.5), using
  !  2nd order flux limited scheme with super-bee flux limiter method
  !
  !  Input: np,nt,iba,fb0,fb1,cl,cp,f2d
  !  Output: fal,fap
  use ModCrcm, ONLY: UseMcLimiter, BetaLimiter
  use ModCrcm,       ONLY: MinLonPar,MaxLonPar
  implicit none

  integer np,nt,iba(nt),i,j,j_1,j1,j2,ib
  real cl(np,nt),cp(np,nt),f2d(np,nt),fal(0:np,nt),fap(np,nt),fwbc(0:np+2,nt)
  real fb0(nt),fb1(nt),x,fup,flw,xsign,corr,xlimiter,r

  real,intent(out) :: fupl(0:np,nt), fupp(np,nt)
  fwbc(1:np,1:nt)=f2d(1:np,1:nt)        ! fwbc is f2d with boundary condition

  ! Set up boundary condition
  fwbc(0,1:nt)=fb0(1:nt)
  do j=MinLonPar,MaxLonPar
     ib=iba(j)
     fwbc(ib+1:np+2,j)=fb1(j)
  enddo

  ! find fal and fap
  jloop: do j=MinLonPar,MaxLonPar
     j_1=j-1
     j1=j+1
     j2=j+2
     if (j_1.lt.1) j_1=j_1+nt
     if (j1.gt.nt) j1=j1-nt
     if (j2.gt.nt) j2=j2-nt
     iloop: do i=1,np
        ! find fal
        xsign=sign(1.,cl(i,j))
        fupl(i,j)=0.5*(1.+xsign)*fwbc(i,j)+0.5*(1.-xsign)*fwbc(i+1,j) ! upwind
        flw=0.5*(1.+cl(i,j))*fwbc(i,j)+0.5*(1.-cl(i,j))*fwbc(i+1,j)   ! LW
        x=fwbc(i+1,j)-fwbc(i,j)
        if (abs(x).le.1.e-27) fal(i,j)=fupl(i,j)
        if (abs(x).gt.1.e-27) then
           if (xsign.eq.1.) r=(fwbc(i,j)-fwbc(i-1,j))/x
           if (xsign.eq.-1.) r=(fwbc(i+2,j)-fwbc(i+1,j))/x
           if (r.le.0.) fal(i,j)=fupl(i,j)
           if (r.gt.0.) then
              if(UseMcLimiter)then
                 xlimiter = min(BetaLimiter*r, BetaLimiter, 0.5*(1+r))
              else
                 xlimiter = max(min(2.*r,1.),min(r,2.))
              end if
              corr=flw-fupl(i,j)
              fal(i,j)=fupl(i,j)+xlimiter*corr
           endif
        endif
        ! find fap
        xsign=sign(1.,cp(i,j))
        fupp(i,j)=0.5*(1.+xsign)*fwbc(i,j)+0.5*(1.-xsign)*fwbc(i,j1) ! upwind
        flw=0.5*(1.+cp(i,j))*fwbc(i,j)+0.5*(1.-cp(i,j))*fwbc(i,j1)   ! LW
        x=fwbc(i,j1)-fwbc(i,j)
        if (abs(x).le.1.e-27) fap(i,j)=fupp(i,j)
        if (abs(x).gt.1.e-27) then
           if (xsign.eq.1.) r=(fwbc(i,j)-fwbc(i,j_1))/x
           if (xsign.eq.-1.) r=(fwbc(i,j2)-fwbc(i,j1))/x
           if (r.le.0.) fap(i,j)=fupp(i,j)
           if (r.gt.0.) then
              if(UseMcLimiter)then
                 xlimiter = min(BetaLimiter*r, BetaLimiter, 0.5*(1+r))
              else
                 xlimiter = max(min(2.*r,1.),min(r,2.))
              end if
              corr=flw-fupp(i,j)
              fap(i,j)=fupp(i,j)+xlimiter*corr
           endif
        endif
     enddo iloop
  enddo jloop

end subroutine FLS_2D

! OLD LINTP
!!-----------------------------------------------------------------------
!subroutine lintp(xx,yy,n,x,y,ier)
!  !-----------------------------------------------------------------------
!  !  Routine does 1-D interpolation.  xx must be increasing or decreasing
!  !  monotonically.  x is between xx(1) and xx(n)
!  ! 
!  !  input: xx,yy,n,x
!  !  output: y,ier
!
!  implicit none
!
!  integer n,ier,i,jl,ju,jm,j
!  real xx(n),yy(n),x,y,d
!
!  ier = 0
!
!  ! Make sure xx is increasing or decreasing monotonically
!  do i=2,n
!     if (xx(n).gt.xx(1).and.xx(i).lt.xx(i-1)) then
!        write(*,*) ' lintp: xx is not increasing monotonically '
!        write(*,*) n,xx
!        stop
!     endif
!     if (xx(n).lt.xx(1).and.xx(i).gt.xx(i-1)) then
!        write(*,*) ' lintp: xx is not decreasing monotonically '
!        write(*,*) n,xx
!        stop
!     endif
!  enddo
!
!  ! Set ier=1 if out of range
!  if (xx(n).gt.xx(1)) then
!     if (x.lt.xx(1).or.x.gt.xx(n)) ier=1
!  else
!     if (x.gt.xx(1).or.x.lt.xx(n)) ier=1
!  endif
!  if (ier.eq.1) then
!     write(*,*) ' Error: ier.eq.1'
!     print *,'n,x ',n,x
!     print *,'xx(1:n) ',xx(1:n)
!     stop
!  endif
!
!  ! initialize lower and upper values
!  jl=1
!  ju=n
!
!  ! if not done compute a midpoint
!10 if (ju-jl.gt.1) then
!     jm=(ju+jl)/2
!     ! now replace lower or upper limit
!     if ((xx(n).gt.xx(1)).eqv.(x.gt.xx(jm))) then
!        jl=jm
!     else
!        ju=jm
!     endif
!     ! try again
!     go to 10
!  endif
!
!  ! this is the j
!  j=jl      ! if x.le.xx(1) then j=1
!  ! if x.gt.x(j).and.x.le.x(j+1) then j=j
!  ! if x.gt.x(n) then j=n-1
!  d=xx(j+1)-xx(j)
!  y=(yy(j)*(xx(j+1)-x)+yy(j+1)*(x-xx(j)))/d
!
!end subroutine lintp


!-------------------------------------------------------------------------------
subroutine lintp2aIM(x,y,v,nx,ny,x1,y1,v1)
  !-----------------------------------------------------------------------------
  !  This sub program takes 2-d interplation. x is 2-D and y is 1-D.
  !
  !  Input: x,y,v,nx,ny,x1,y1
  !  Output: v1

  implicit none               

  integer nx,ny,j,j1,i,i1,i2,i3
  real x(nx,ny),y(ny),v(nx,ny),x1,y1,v1,a,a1,b,x1d(1000)   ! max(nx)=1000
  real q00,q01,q10,q11

  call locate1IM(y,ny,y1,j)
  j1=j+1
  if (j.eq.0.or.j1.gt.ny) then
     b=1.
     if (j.eq.0) j=j1
     if (j1.gt.ny) j1=j
  else
     b=(y1-y(j))/(y(j+1)-y(j))
  endif

  x1d(1:nx)=x(1:nx,j)

  call locate1IM(x1d,nx,x1,i)
  i1=i+1
  if (i.eq.0.or.i1.gt.nx) then
     a=1.
     if (i.eq.0) i=i1
     if (i1.gt.nx) i1=i
  else
     a=(x1-x1d(i))/(x1d(i+1)-x1d(i))
  endif

  x1d(1:nx)=x(1:nx,j1)
  
  call locate1IM(x1d,nx,x1,i2)
  i3=i2+1
  if (i2.eq.0.or.i3.gt.nx) then
     a1=1.
     if (i2.eq.0) i2=i3
     if (i3.gt.nx) i3=i2
  else
     a1=(x1-x1d(i2))/(x1d(i2+1)-x1d(i2))
  endif

  q00=(1.-a)*(1.-b)
  q01=(1.-a1)*b
  q10=a*(1.-b)
  q11=a1*b
  v1=q00*v(i,j)+q01*v(i2,j1)+q10*v(i1,j)+q11*v(i3,j1)

end subroutine lintp2aIM

!-------------------------------------------------------------------------------
subroutine lintp2IM(x,y,v,nx,ny,x1,y1,v1)
!-------------------------------------------------------------------------------
!  Routine does 2-D interpolation.  x and y must be increasing or decreasing
!  monotonically
!
  real x(nx),y(ny),v(nx,ny)
  
  call locate1IM(x,nx,x1,i)
  if (i.gt.(nx-1)) i=nx-1      ! extrapolation if out of range
  if (i.lt.1) i=1              ! extrapolation if out of range
  i1=i+1
  a=(x1-x(i))/(x(i1)-x(i))
  
  call locate1IM(y,ny,y1,j)
  if (j.gt.(ny-1)) j=ny-1      ! extrapolation if out of range
  if (j.lt.1) j=1              ! extrapolation if out of range
  j1=j+1
  b=(y1-y(j))/(y(j1)-y(j))
  
  q00=(1.-a)*(1.-b)
  q01=(1.-a)*b
  q10=a*(1.-b)
  q11=a*b
  v1=q00*v(i,j)+q01*v(i,j1)+q10*v(i1,j)+q11*v(i1,j1)
  
  return
end subroutine lintp2IM



!--------------------------------------------------------------------------
subroutine locate1IM(xx,n,x,j)
  !--------------------------------------------------------------------------
  !  Routine return a value of j such that x is between xx(j) and xx(j+1).
  !  xx must be increasing or decreasing monotonically.
  !  If xx is increasing:
  !     If x=xx(m), j=m-1 so if x=xx(1), j=0  and if x=xx(n), j=n-1
  !     If x < xx(1), j=0  and if x > xx(n), j=n
  !  If xx is decreasing:
  !     If x=xx(m), j=m so if x=xx(1), j=1  and if x=xx(n), j=n
  !     If x > xx(1), j=0  and if x < xx(n), j=n
  !
  !  Input: xx,n,x
  !  Output: j

  implicit none

  integer n,j,i,jl,ju,jm
  real xx(n),x

  ! Make sure xx is increasing or decreasing monotonically
  do i=2,n
     if (xx(n).gt.xx(1).and.xx(i).lt.xx(i-1)) then
        write(*,*) ' locate1IM: xx is not increasing monotonically '
        write(*,*) n, (xx(j),j=1,n)
        call CON_STOP('CRCM stopped in locate1IM')
     endif
     if (xx(n).lt.xx(1).and.xx(i).gt.xx(i-1)) then
        write(*,*) ' locate1IM: xx is not decreasing monotonically '
        write(*,*) ' n, xx  ',n,xx
        call CON_STOP('CRCM stopped in locate1IM')
     endif
  enddo

  jl=0
  ju=n+1
  test: do
     if (ju-jl.le.1) exit test
     jm=(ju+jl)/2
     if ((xx(n).gt.xx(1)).eqv.(x.gt.xx(jm))) then
        jl=jm
     else
        ju=jm
     endif
  end do test
  j=jl

end subroutine locate1IM


!Old CLOSED SUBROUTINE
!!--------------------------------------------------------------------------
!subroutine closed(n1,n2,yy,dx,ss)
!  !--------------------------------------------------------------------------
!  ! Routine does numerical integration using closed form.
!  ! 
!  ! Input: n1,n2,yy,dx
!  ! Output: ss
!
!  implicit none
!
!  integer n1,n2,i
!  real yy(n2),dx(n2),ss
!
!  ss=0.
!  do i=n1,n2
!     ss=ss+yy(i)*dx(i)
!  enddo
!
!end subroutine closed

