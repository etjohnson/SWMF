!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
subroutine PW_initialize

  use ModNumConst, ONLY: cDegToRad
  use ModMpi
  use ModIoUnit, ONLY: io_unit_new,UnitTmp_
  use ModPwom
  use ModCommonPlanet,ONLY: nIon,iRho_I,iU_I,iP_I,iT_I
  use ModCommonVariables, ONLY:IYD,ALTD
  use ModTimeConvert, ONLY: time_int_to_real
  use ModPwTime
  use ModAurora, ONLY: init_aurora
  use ModPwWaves,ONLY: wave_init
  use ModCouplePWOMtoSE, ONLY: init_pwom_se_coupling
  use ModPhotoelectron, ONLY: PrecipEnergyMin, PrecipEnergyMax, &
       PrecipEnergyMean, PrecipEnergyFlux, UseFixedPrecip, DoCoupleSE,&
       PolarRainEMin, PolarRainEMax, &
       PolarRainEMean, PolarRainEFlux, UsePolarRain, IsVerboseSE
  use ModOvation, ONLY: UseOvation, StartTimeOvation=>StartTime, &
       OvationEmin,OvationEmax
  use CON_axes,         ONLY: init_axes
  implicit none

  ! Temporary variables
  real:: ddt1, xxx
  integer:: ns, iPe, iError,iIon
  integer:: iYear, iDOY

  integer, external :: julianday
  
  !---------------------------------------------------------------------------
  !***************************************************************************
  !  Set the number of fieldlines that each processor solves for
  !***************************************************************************
  
  if (nTotalLine < nProc) &
       call con_stop(&
       "PW ERROR:nTotalLine<nProc. Reduce number of procs for PW in LAYOUT.in")

  if (iProc < mod(nTotalLine,nProc)) then
     nLine= (nTotalLine+nProc-1)/nProc
  else
     nLine= nTotalLine/nProc
  endif

  allocate(nLine_P(0:nProc-1), nLineBefore_P(0:nProc-1))
  call MPI_allgather(nLine,1,MPI_INTEGER, nLine_P,1,MPI_INTEGER,iComm,iError)
  nLineBefore_P(0) = 0
  do iPe = 1, nProc - 1
     nLineBefore_P(iPe) = sum(nLine_P(0:iPe-1))
  end do

  !\
  ! Set the Time parameters
  !/
  iYear = iStartTime(1)
  iDOY  = julianday(iStartTime(1),iStartTime(2),iStartTime(3)) 
  IYD=mod(iYear,100)*1000+iDOY
  call time_int_to_real(iStartTime,CurrentTime)
  StartTime=CurrentTime
  
  !make ovation starttime match simulation start time
  if (UseOvation) StartTimeOvation=StartTime

  !\
  ! Set axes for coord transform when in standalone mode
  !/
  if (IsStandAlone) call init_axes(StartTime)

  !\
  ! Allocate arrays for simulation
  !/
  if (.not.allocated(r_C)) allocate(r_C(nAlt),&
       State_CVI(nAlt,nVar,nLine),&
       GeoMagLat_I(nLine),GeoMagLon_I(nLine),          &
       ThetaLine_I(nLine), PhiLine_I(nLine),           &
       ThetaLineOld_I(nLine), PhiLineOld_I(nLine),           &
       xLine_I(nLine),yLine_I(nLine),zLine_I(nLine),          &
       xLineOld_I(nLine),yLineOld_I(nLine),zLineOld_I(nLine), &
       UthetaLine_I(nLine),UphiLine_I(nLine),          &
       UxLine_I(nLine),UyLine_I(nLine),UzLine_I(nLine),       &
       OmegaLine_I(nLine),                      &
       JrLine_I(nLine),EfluxLine_I(nLine),AvELine_I(nLine),&
       iThetaLine_I(nLine),iPhiLine_I(nLine), &
       NameRestartIn(nLine), NameRestart(nLine), NameGraphics(nLine),&
       NameOutput(nLine),  iUnitRestart(nLine),iUnitRestartIn(nLine),&
       iUnitGraphics(nLine),iUnitOutput(nLine), iLineGlobal(nLine), &
       Dt_I(nLine))
  
  call wave_init(nAlt)
  
  !**************************************************************************
  !  Define file names and unit numbers, and open for reading and writing.
  !***************************************************************************
  NameSourceGraphics = 'PW/plot_sources.out'
  NameCollision      = 'PW/plots_collision.out'
  NamePhiNorth       = 'PW/North.dat'
  NamePhiSouth       = 'PW/South.dat'

  do iLine=1,nLine
     if (iproc .lt. mod(nTotalLine,nProc)) then
        iLineGlobal(iLine)=&
             iproc*ceiling(real(nTotalLine)/real(nProc))+iLine
     else
        iLineGlobal(iLine)=&
             (mod(NTotalLine,nProc))*ceiling(real(nTotalLine)/real(nProc)) &
             + ((iproc)-mod(nTotalLine,nProc))                        &
             *floor(real(nTotalLine)/real(nProc))+iLine
     endif
     write(NameRestartIn(iLine),"(a,i4.4,a)") &
          'PW/restartIN/restart_iline',iLineGlobal(iLine),'.dat'
     write(NameRestart(iLine),"(a,i4.4,a)") &
          'PW/restartOUT/restart_iline',iLineGlobal(iLine),'.dat'
     
     !Setup log files
     if (nLog == -1) then
        write(NameOutput(iLine),"(a,i4.4,a)") &
             'PW/log_iline',iLineGlobal(iLine),'.out'   
        iUnitOutput(iLine)  = io_unit_new()
        open(iUnitOutput(iLine),FILE=NameOutput(iLine))    
     elseif(nLog ==0) then
        !do nothing in this case
     elseif(nLog==iLineGlobal(iLine)) then
        write(NameOutput(iLine),"(a,i4.4,a)") &
             'PW/log_iline',iLineGlobal(iLine),'.out'      
        iUnitOutput(iLine)  = io_unit_new()
        open(iUnitOutput(iLine),FILE=NameOutput(iLine))     
     else
     end if

     
     
  enddo

!******************************************************************************
!  Read the restart file
!******************************************************************************

  if(IsRestart)then
     call PW_read_restart
  else
     do iLine = 1, nLine
        ThetaLine_I (iLine) = 10.0 * cDegToRad
        PhiLine_I   (iLine) = 0.0
     end do
     Time=0.0
  endif
  
  CurrentTime=StartTime+Time
  
  ! Set the output plot files
  do iLine =1, nLine
     if(ThetaLine_I(iLine) <= 90 * cDegToRad)then
        write(NameGraphics(iLine),"(a,i4.4,a)") &
             'PW/plots/north_plots_iline',iLineGlobal(iLine),'.out'
     else
        write(NameGraphics(iLine),"(a,i4.4,a)") &
             'PW/plots/south_plots_iline',iLineGlobal(iLine),'.out'
     endif
     
     open(UnitTmp_,FILE=NameGraphics(iLine),STATUS='replace')
     close(UnitTmp_)
  enddo
  !****************************************************************************
  ! Set vertical field-line grid
  !****************************************************************************
  call set_vertical_grid

  !****************************************************************************
  ! Use Get_GITM to bring in neutral atmosphere from GITM
  !****************************************************************************
  !call GetNeutralData

  !****************************************************************************
  !  Set parameters for reading in potential and time of simulation
  !****************************************************************************
 
  TimeMax = Tmax

  !****************************************************************************
  ! Read information from IE file, and get the velocities
  !****************************************************************************
  
  if(.not.UseIe)then
     call PW_get_electrodynamics

     !initialize field line locations
     call initial_line_location
  end if


  if (UseAurora) call init_aurora

  ! initialize the SE model (note cannot use fix precip and ovation 
  ! simultaneously)
  if(DoCoupleSE) then
     if(UseFixedPrecip .and. UsePolarRain .and. .not.UseOvation) then
        call init_pwom_se_coupling(IsVerboseSE,nAlt,nLine,iLineGlobal,ALTD,&
             PrecipEminPwIn=PrecipEnergyMin,PrecipEmaxPwIn=PrecipEnergyMax, &
             PrecipEmeanPwIn=PrecipEnergyMean,PrecipEfluxPwIn=PrecipEnergyFlux,&
             PolarRainEminPwIn=PolarRainEMin,PolarRainEmaxPwIn=PolarRainEMax, &
             PolarRainEmeanPwIn=PolarRainEMean,&
             PolarRainEfluxPwIn=PolarRainEFlux)
     elseif(.not.UseFixedPrecip .and. UsePolarRain .and. UseOvation) then
        call init_pwom_se_coupling(IsVerboseSE,nAlt,nLine,iLineGlobal,ALTD,&
             PolarRainEminPwIn=PolarRainEMin,PolarRainEmaxPwIn=PolarRainEMax, &
             PolarRainEmeanPwIn=PolarRainEMean,&
             PolarRainEfluxPwIn=PolarRainEFlux,&
             OvationEminPwIn=OvationEmin,      &
             OvationEmaxPwIn=OvationEmax)
     elseif(UseFixedPrecip) then
        call init_pwom_se_coupling(IsVerboseSE,nAlt,nLine,iLineGlobal,ALTD,&
             PrecipEminPwIn=PrecipEnergyMin,PrecipEmaxPwIn=PrecipEnergyMax, &
             PrecipEmeanPwIn=PrecipEnergyMean,PrecipEfluxPwIn=PrecipEnergyFlux)
     elseif(UsePolarRain) then
        call init_pwom_se_coupling(IsVerboseSE,nAlt,nLine,iLineGlobal,ALTD,&
             PolarRainEminPwIn=PolarRainEMin,PolarRainEmaxPwIn=PolarRainEMax, &
             PolarRainEmeanPwIn=PolarRainEMean,&
             PolarRainEfluxPwIn=PolarRainEFlux)
     elseif(UseOvation) then
        call init_pwom_se_coupling(IsVerboseSE,nAlt,nLine,iLineGlobal,ALTD,&
             OvationEminPwIn=OvationEmin,      &
             OvationEmaxPwIn=OvationEmax)
     else
        call init_pwom_se_coupling(IsVerboseSE,nAlt,nLine,iLineGlobal,ALTD)
     end if
  end if
end subroutine PW_initialize

!=============================================================================
integer function julianday(year, mon, day) result(Julian_Day)
  
  implicit none
  
  integer :: i
  integer, dimension(1:12) :: dayofmon
  integer :: year, mon, day
  
  dayofmon(1) = 31
  dayofmon(2) = 28
  dayofmon(3) = 31
  dayofmon(4) = 30
  dayofmon(5) = 31
  dayofmon(6) = 30
  dayofmon(7) = 31
  dayofmon(8) = 31
  dayofmon(9) = 30
  dayofmon(10) = 31
  dayofmon(11) = 30
  dayofmon(12) = 31
  
  if (mod(year,4).eq.0) dayofmon(2) = dayofmon(1) + 1
  Julian_Day = 0
  do i = 1, mon-1
     Julian_Day = Julian_Day + dayofmon(i)
  enddo
  Julian_Day = Julian_Day + day
  
end function julianday