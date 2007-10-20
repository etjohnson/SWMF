subroutine PW_initialize

  use ModNumConst, ONLY: cDegToRad
  use ModMpi
  use ModIoUnit, ONLY: io_unit_new,UnitTmp_
  use ModPwom
  use ModCommonPlanet,ONLY: nIon,iRho_I,iU_I,iP_I,iT_I
  use ModCommonVariables, ONLY:IYD
  use ModTimeConvert, ONLY: time_int_to_real
  use ModPwTime
  use ModAurora, ONLY: init_aurora
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

     write(NameGraphics(iLine),"(a,i4.4,a)") &
          'PW/plots/plots_iline',iLineGlobal(iLine),'.out'

     iUnitGraphics(iLine)  = io_unit_new()
     open(iUnitGraphics(iLine),FILE=NameGraphics(iLine),STATUS='replace')
     
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

     do iLine=1,nLine
        OPEN(UNIT=UnitTmp_, FILE=NameRestartIn(iLine), STATUS='OLD')
        READ (UnitTmp_,*) TIME,DDT1,nStep
        READ (UnitTmp_,*) GeoMagLat_I(iLine),GeoMagLon_I(iLine)

        ThetaLine_I (iLine) = (90.0-GeoMagLat_I(iLine)) * cDegToRad
        PhiLine_I   (iLine) = GeoMagLon_I(iLine)        * cDegToRad
        
        do iIon=1,nIon
           READ (UnitTmp_,*) &
                (XXX,State_CVI(i,iU_I(iIon),iLine),State_CVI(i,iP_I(iIon),iLine),&
                State_CVI(i,iRho_I(iIon),iLine),State_CVI(i,iT_I(iIon),iLine),&
                i=1,nAlt)
        enddo
        
        CLOSE(UNIT=UnitTmp_)
     enddo
  else
     do iLine = 1, nLine
        ThetaLine_I (iLine) = 10.0 * cDegToRad
        PhiLine_I   (iLine) = 0.0
     end do
     Time=0.0
  endif
  
  CurrentTime=StartTime+Time

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
