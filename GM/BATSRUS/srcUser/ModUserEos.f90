!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModUser

  use BATL_lib, ONLY: &
       test_start, test_stop
  ! This is the default user module which contains empty methods defined
  ! in ModUserEmpty.f90

  use ModUserEmpty,                                     &
       IMPLEMENTED1 => user_update_states

  include 'user_module.h' ! list of public methods

  real,              parameter :: VersionUserModule = 1.0
  character (len=*), parameter :: &
       NameUserModule = 'HYDRO + IONIZATION EQUILIBRIUM'
contains
  !============================================================================

  subroutine init_mod_user
  end subroutine init_mod_user

  !============================================================================

  subroutine clean_mod_user
  end subroutine clean_mod_user

  !============================================================================
  subroutine user_update_states(iBlock)

    use ModUpdateState, ONLY: update_state_normal
    use ModVarIndexes
    use ModSize
    use ModAdvance,   ONLY: State_VGB
    use ModMain,      ONLY: nStage
    use ModPhysics
    use ModEnergy,    ONLY: calc_energy_cell
    use CRASH_ModEos, ONLY: eos

    integer,intent(in):: iBlock
    integer:: i,j,k
    real:: PressureSI,EInternal,EInternalSI,RhoSI

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_update_states'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call update_state_normal(iBlock)
    !\
    ! Begin update of pressure and relaxation energy::
    !/
    do k=1,nK; do j=1,nJ; do i=1,nI
       ! Total external energy, ExtraEInt + P/(\gamma -1),
       ! transformed to SI
       EInternalSI = No2Si_V(UnitEnergyDens_)*&
            (InvGammaMinus1*State_VGB(P_,i,j,k,iBlock) + &
            State_VGB(ExtraEint_,i,j,k,iBlock))
       ! Density, transformed to SI

       RhoSI = No2Si_V(UnitRho_)*State_VGB(Rho_,i,j,k,iBlock)

       ! Apply the EOS, get pressure in SI
       call eos(&
            0,                        & ! Input: sort of material
            RhoSI,                    & ! Input mass density, SI [kg/m^3]
            ETotalIn=EInternalSI,     & ! Input total energy density SI,[J/m^3]
            PTotalOut=PressureSI      ) ! Output, OPTIONAL, pressure, SI [Pa]

       ! Put pressure and ExtraEInt = Total internal energy - P/(\gamma -1)
       State_VGB(P_,i,j,k,iBlock) = PressureSI*Si2No_V(UnitP_)
       State_VGB(ExtraEint_,i,j,k,iBlock) = Si2No_V(UnitEnergyDens_)*&
            (EInternalSI - PressureSI*InvGammaMinus1)
    end do; end do; end do
    call calc_energy_cell(iBlock)
    !\
    ! End update of pressure and relaxation energy::
    !/
    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_update_states
  !============================================================================
end module ModUser
!==============================================================================
