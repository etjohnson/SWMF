!  Copyright (C) 2002 Regents of the University of Michigan, 
!  portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
!=============================================================!
module SP_wrapper
  
  implicit none

  save

  private ! except

  public:: SP_set_param
  public:: SP_init_session
  public:: SP_run
  public:: SP_save_restart
  public:: SP_finalize

  ! coupling with MHD components
  public:: SP_get_line_param
  public:: SP_put_input_time
  public:: SP_put_from_mh
  public:: SP_put_line
  public:: SP_get_request
  public:: SP_get_grid_descriptor_param
  public:: SP_get_line_all
  public:: SP_get_solar_corona_boundary
  public:: SP_put_r_min

contains

  subroutine SP_run(TimeSimulation,TimeSimulationLimit)

    real,intent(inout)::TimeSimulation
    real,intent(in)::TimeSimulationLimit
    call CON_stop('Can not call SP_run')
  end subroutine SP_run
  !========================================================================
  !======================================================================
  subroutine SP_init_session(iSession,TimeSimulation)

    integer,  intent(in) :: iSession         ! session number (starting from 1)
    real,     intent(in) :: TimeSimulation   ! seconds from start time
    call CON_stop('Can not call SP_init_session')
  end subroutine SP_init_session
  !======================================================================
  subroutine SP_finalize(TimeSimulation)

    real,intent(in)::TimeSimulation
    call CON_stop('Can not call SP_finalize')
  end subroutine SP_finalize
  !=========================================================
  subroutine SP_set_param(CompInfo,TypeAction)
    use CON_comp_info

    type(CompInfoType),intent(inout)       :: CompInfo
    character(len=*), intent(in)           :: TypeAction
    !-------------------------------------------------------------------------
    select case(TypeAction)
    case('VERSION')
       call put(CompInfo,&
            Use        =.false., &
            NameVersion='Empty', &
            Version    =0.0)

    case default
       call CON_stop('Can not call SP_set_param for '//trim(TypeAction))
    end select
  end subroutine SP_set_param
  !=========================================================
  subroutine SP_save_restart(TimeSimulation) 

    real,     intent(in) :: TimeSimulation 
    call CON_stop('Can not call SP_save restart')
  end subroutine SP_save_restart
  !=========================================================
  subroutine SP_put_input_time(TimeIn)

    real,     intent(in)::TimeIn
    call CON_stop('Can not call SP_get_input_time')
  end subroutine SP_put_input_time
  !===================================================================
  subroutine SP_put_from_mh(nPartial,iPutStart,Put,W,DoAdd,Buff_I,nVar)
    use CON_router, ONLY: IndexPtrType, WeightPtrType

    integer,intent(in)::nPartial,iPutStart,nVar
    type(IndexPtrType),intent(in)::Put
    type(WeightPtrType),intent(in)::W
    logical,intent(in)::DoAdd
    real,dimension(nVar),intent(in)::Buff_I
    call CON_stop('Can not put ih data')
  end subroutine SP_put_from_mh
  !===================================================================
  subroutine SP_get_line_param(DsOut, XyzOut_D, DSCOut, DIHOut)

    real,intent(out):: DsOut, XyzOut_D(3), DSCOut, DIHOut
    call CON_stop('Can not get line parameters from SP')

  end subroutine SP_get_line_param
  !===================================================================

  subroutine SP_get_solar_corona_boundary(RScOut)
    ! return the value of the solar corona boundary as set in SP component
    real, intent(out):: RScOut
    character(len=*), parameter:: NameSub='SP_get_solar_corona_boundary'
    !-----------------------------------------------------------------
    call CON_stop('SP: '//NameSub//' : cannot call the empty version')
  end subroutine SP_get_solar_corona_boundary

  !===================================================================

  subroutine SP_put_r_min(R)
    real, intent(in)::R
    character(len=*), parameter:: NameSub='SP_put_r_min'
    call CON_stop('SP:'//NameSub//': cannot call the empty version')
  end subroutine SP_put_r_min

  !===================================================================
  subroutine SP_get_request(nLine, nCoord, CoordOut_DI, iIndexOut_II,&
       nAux, AuxOut_VI)
    integer,              intent(out):: nLine
    integer,              intent(out):: nCoord
    real,    allocatable, intent(out):: CoordOut_DI(:, :)
    integer, allocatable, intent(out):: iIndexOut_II(:,:)
    integer,              intent(out):: nAux
    real,    allocatable, intent(out):: AuxOut_VI(:,:)
    character(len=*), parameter:: NameSub='SP_get_request'
    call CON_stop('SP:'//NameSub//': cannot call the empty version')
  end subroutine SP_get_request
  !===================================================================
  subroutine SP_put_line(nParticle, Coord_DI, iIndex_II)
    integer, intent(in):: nParticle
    real,    intent(in):: Coord_DI( 3, nParticle)
    integer, intent(in):: iIndex_II(4, nParticle)
    call CON_stop('Can not put line parameters')
  end subroutine SP_put_line
  !===================================================================

  subroutine SP_get_grid_descriptor_param(&
       iGridMin_D, iGridMax_D, Displacement_D)
    integer, intent(out):: iGridMin_D(3)
    integer, intent(out):: iGridMax_D(3)
    real,    intent(out):: Displacement_D(3)
    !-----------------------------------------
    call CON_stop('Can not get grid descriptor parameters')
  end subroutine SP_get_grid_descriptor_param

  !===================================================================

  subroutine SP_get_line_all(Xyz_DI)
    real, pointer:: Xyz_DI(:, :)
    !-----------------------------------------
    call CON_stop('Can not get field lines')
  end subroutine SP_get_line_all

end module SP_wrapper
