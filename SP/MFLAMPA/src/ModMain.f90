!  Copyright (C) 2002 Regents of the University of Michigan
! portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module SP_ModMain

  use SP_ModSize, ONLY: &
       nDim, nLat, nLon, nNode, &
       iParticleMin, iParticleMax, nParticle,&
       Particle_, OriginLat_, OriginLon_
  
  use SP_ModWrite, ONLY: &
       set_write_param, write_output, NamePlotDir

  use SP_ModReadMhData, ONLY: &
       set_read_mh_data_param, read_mh_data, DoReadMhData

  use SP_ModRestart, ONLY: &
       save_restart=>write_restart, read_restart

  use SP_ModGrid, ONLY: &
       nVar, &
       LagrID_,X_,Y_,Z_,Rho_, Bx_,By_,Bz_,B_, Ux_,Uy_,Uz_, T_, BOld_, RhoOld_,&
       Wave1_, Wave2_, &
       XMin_, YMin_, ZMin_, Length_, &
       iComm, iProc, nProc, nBlock, &
       Proc_, Block_, Begin_, End_, Shock_, ShockOld_, Offset_,&
       LatMin, LatMax, LonMin, LonMax, &
       RMin, RBufferMin, RBufferMax, RMax, ROrigin, &
       iGridLocal_IB, iGridGlobal_IA, iNode_II, iNode_B, State_VIB, &
       Distribution_IIB, &
       ParamLocal_IB, TypeCoordSystem,&
       set_grid_param, init_grid, get_node_indexes, &
       append_particles
  
  use SP_ModAdvance, ONLY: &
       TimeGlobal, iIterGlobal, DoTraceShock, UseDiffusion, &
       advance, set_injection_param, init_advance_const

  implicit none

  SAVE

  private ! except
  real :: DataInputTime
  ! Methods and variables from this module 
  public:: &
       read_param, initialize, run, check, save_restart, &
       TimeGlobal, iIterGlobal, DataInputTime, DoRestart

  ! Methods and variables from ModSize
  public:: &
       nDim, nLat, nLon, nNode, &
       iParticleMin, iParticleMax, nParticle,&
       Particle_, OriginLat_, OriginLon_

  ! Methods and variables from ModGrid
  public:: &
       nVar, &
       LagrID_,X_,Y_,Z_,Rho_, Bx_,By_,Bz_,B_, Ux_,Uy_,Uz_, T_, RhoOld_, BOld_,&
       Wave1_, Wave2_, &
       XMin_, YMin_, ZMin_, Length_, &
       iComm, iProc, nProc, nBlock, &
       Proc_, Block_, Begin_, End_, Shock_, ShockOld_, Offset_,&
       LatMin, LatMax, LonMin, LonMax, &
       RMin, RBufferMin, RBufferMax, RMax, ROrigin,&
       iGridLocal_IB, iGridGlobal_IA, iNode_II, iNode_B, State_VIB, &
       Distribution_IIB, ParamLocal_IB, TypeCoordSystem,& 
       get_node_indexes, append_particles

  ! Methods and variables from ModWrite

  ! Methods and variables from ModAdvance

  !\
  ! Logicals for actions
  !----------------------------------------------------------------------------
  ! run the component
  logical:: DoRun = .true.
  ! restart the run 
  logical:: DoRestart = .false.
  ! perform initialization
  logical:: DoInit = .true.
  !/


contains

  subroutine read_param(TypeAction)
    ! Read input parameters for SP component
    use ModReadParam, ONLY: read_var, read_line, read_command
    character (len=*), intent(in)     :: TypeAction ! What to do  

    ! aux variables 
    integer:: nParticleCheck, nLonCheck, nLatCheck
    ! The name of the command
    character (len=100) :: NameCommand
    character (len=*), parameter :: NameSub='SP:read_param'
    !--------------------------------------------------------------------------
    ! Read the corresponding section of input file
    do
       if(.not.read_line() ) EXIT
       if(.not.read_command(NameCommand)) CYCLE
       select case(NameCommand)
       case('#RESTART')
          call read_var('DoRestart',DoRestart)
       case('#CHECKGRIDSIZE')
          call read_var('nParticle',nParticleCheck)
          call read_var('nLon',     nLonCheck)
          call read_var('nLat',     nLatCheck)
          if(iProc==0.and.any(&
               (/nParticle,     nLon,     nLat/) /= &
               (/nParticleCheck,nLonCheck,nLatCheck/)))then
             write(*,*)'Code is compiled with nParticle,nLon,nLat=',&
                  (/nParticle, nLon, nLat/)
             call CON_stop(&
                  'Change nParticle,nLon,nLat with Config.pl -g & recompile!')
          end if
       case('#NSTEP')
          call read_var('nStep',iIterGlobal)
       case('#TIMESIMULATION')
          call read_var('tSimulation',TimeGlobal)
       case('#GRID', '#ORIGIN')
          call set_grid_param(NameCommand)
       case('#DORUN')
          call read_var('DoRun',DoRun)
       case('#SAVEPLOT')
          call set_write_param
       case('#READMHDATA')
          call set_read_mh_data_param
       case('#COORDSYSTEM',"#COORDINATESYSTEM")
          call read_var('TypeCoordSystem',TypeCoordSystem,IsUpperCase=.true.)
       case('#INJECTION')
          call set_injection_param
       case('#TEST')
          ! various test modes that allow to disable certain features
          call read_var('DoTraceShock', DoTraceShock)
          call read_var('UseDiffusion', UseDiffusion)
       case default
          call CON_stop(NameSub//': Unknown command '//NameCommand)
       end select
    end do
  end subroutine read_param

  !============================================================================

  subroutine initialize(TimeStart)
    ! initialize the model
    real, intent(in):: TimeStart
    character(LEN=*),parameter:: NameSub='SP:initialize'
    !--------------------------------------------------------------------------
    if(DoInit)then
       DoInit=.false.
    else
       RETURN
    end if
    iIterGlobal = 0
    TimeGlobal = TimeStart
    call init_advance_const
    call init_grid(DoRestart .or. DoReadMhData)
    if(DoRestart)&
         call read_restart
  end subroutine initialize
  !============================================================================

  subroutine run(TimeInOut, TimeLimit, DoFinalizeIn)
    ! advance the solution in time
    real,              intent(inout):: TimeInOut
    real,              intent(in)   :: TimeLimit
    logical, optional, intent(in)   :: DoFinalizeIn
    logical:: DoFinalize
    logical, save:: IsFirstCall = .true.
    !------------------------------
    if(present(DoFinalizeIn))then
       DoFinalize = DoFinalizeIn
    else
       DoFinalize = .false.
    end if

    if(DoReadMhData)then
       !\
       ! data flow is different when read MHD data from file:
       ! the final data file has alredy been read, no new data is available
       !/
       if(DoFinalize) RETURN

       !\
       ! Read the background data from file
       !/
       ! copy old state
       State_VIB((/RhoOld_,BOld_/), :, 1:nBlock) = &
            State_VIB((/Rho_,B_/),  :, 1:nBlock)
       call read_mh_data(DataInputTime)
       TimeInOut = DataInputTime
    else
       TimeInOut = TimeLimit
    end if

    !\
    ! recompute the derived variables, e.g. magnitude of velocity etc.
    !/
    call fix_grid_consistency

    !\
    ! write the initial background state to the output file
    !/
    if(IsFirstCall)then
       ! print the initial state
       call write_output(IsInitialOutput = .true.)
       IsFirstCall = .false.
    end if

    !\
    ! if no new background data loaded, don't advance in time
    !/
    if(DataInputTime <= TimeGlobal)&
         RETURN
    if(DoRun) &
         ! run the model
         call advance(min(DataInputTime,TimeLimit))

    ! update time & iteration counters
    iIterGlobal = iIterGlobal + 1
    TimeGlobal = min(DataInputTime,TimeLimit)
    
    call write_output(IsInitialOutput=.not.DoRun)
  contains
    !============================================================================

    subroutine fix_grid_consistency
      use SP_ModGrid, ONLY: U_, D_, S_, DLogRho_, distance_to_next
      ! recompute some values (magnitudes of plasma velocity and magnetic field)
      ! so they are consistent with components for all lines
      integer:: iBlock, iParticle, iBegin, iEnd
      !--------------------------------------------------------------------------
      do iBlock = 1, nBlock
         iBegin = iGridLocal_IB(Begin_,iBlock)
         iEnd   = iGridLocal_IB(End_,  iBlock)
         do iParticle = iBegin, iEnd
            ! if particle has left the domain -> cut the rest of the line
            if(sum(State_VIB(X_:Z_, iParticle, iBlock)**2) > RMax**2)then
               iGridLocal_IB(End_,  iBlock) = iParticle - 1
               EXIT
            end if
            ! plasma speed
            State_VIB(U_,iParticle, iBlock) = &
                 sqrt(sum(State_VIB(Ux_:Uz_,iParticle,iBlock)**2))
            
            ! divergence of plasma velocity
            if(DataInputTime > TimeGlobal) then
               State_VIB(DLogRho_,iParticle,iBlock) = log(&
                    State_VIB(Rho_,iParticle,iBlock) / &
                    State_VIB(RhoOld_,iParticle,iBlock))
            end if
            ! magnetic field
            State_VIB(B_,iParticle, iBlock) = &
                 sqrt(sum(State_VIB(Bx_:Bz_,iParticle,iBlock)**2))

            ! distances between particles
            if(iParticle < iGridLocal_IB(End_,  iBlock))&
                 State_VIB(D_, iParticle, iBlock) = &
                 distance_to_next(iParticle, iBlock)

            ! distance from the beginning of the line
            if(iParticle == iGridLocal_IB(Begin_,  iBlock))then
               State_VIB(S_, iParticle, iBlock) = 0.0
            else
               State_VIB(S_, iParticle, iBlock) = &
                    State_VIB(S_, iParticle-1, iBlock) + &
                    State_VIB(D_, iParticle-1, iBlock)
            end if
         end do
         ! location of shock
         if(iGridLocal_IB(ShockOld_, iBlock) < iParticleMin)&
              iGridLocal_IB(ShockOld_, iBlock)= iBegin
         if(iGridLocal_IB(Shock_, iBlock) < iParticleMin)&
              iGridLocal_IB(Shock_, iBlock)   = iBegin
      end do
    end subroutine fix_grid_consistency
  end subroutine run

  !============================================================================

  subroutine check
    use ModUtilities, ONLY: make_dir
    character(LEN=*),parameter:: NameSub='SP:check'
    !--------------------------------------------------------------------------
    ! Make output and check input directories
    if(iProc==0) call make_dir(NamePlotDir)
  end subroutine check

end module SP_ModMain
