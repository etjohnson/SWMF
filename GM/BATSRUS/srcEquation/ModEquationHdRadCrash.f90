module ModVarIndexes

  use ModSingleFluid, &
       Redefine1 => IsMhd

  use ModExtraVariables, &
       Redefine2 => Erad_, &
       Redefine3 => nWave, &
       Redefine4 => WaveFirst_, &
       Redefine5 => WaveLast_, &
       Redefine6 => ExtraEint_

  implicit none

  save

  ! This equation module contains the CRASH equations.
  character (len=*), parameter :: NameEquation='HD+Ionization+Levels+Radiation'

  logical, parameter :: IsMhd = .false.

  ! loop variable for implied do-loop over spectrum
  integer, private :: iWave

  ! Number of wave bins in spectrum
  integer, parameter :: nWave = 1
  integer, parameter :: nVar = 9 + nWave

  ! Named indexes for State_VGB and other variables
  ! These indexes should go subsequently, from 1 to nVar+nFluid.
  ! The energies are handled as an extra variable, so that we can use
  ! both conservative and non-conservative scheme and switch between them.
  integer, parameter :: &
       Rho_       = 1,                  &
       RhoUx_     = 2, Ux_ = 2,         &
       RhoUy_     = 3, Uy_ = 3,         &
       RhoUz_     = 4, Uz_ = 4,         &
       LevelXe_   = 5,                  & ! Xenon
       LevelBe_   = 6,                  & ! Berillium
       LevelPl_   = 7,                  & ! Plastic
       WaveFirst_ = 8,                  &
       WaveLast_  = WaveFirst_+nWave-1, &
       ExtraEint_ = WaveLast_+1,        &
       p_         = nVar,               &
       Energy_    = nVar+1

  ! This is for backward compatibility with single group radiation
  integer, parameter :: Erad_ = WaveFirst_

  ! This allows to calculate RhoUx_ as RhoU_+x_ and so on.
  integer, parameter :: U_ = Ux_ - 1, RhoU_ = RhoUx_-1

  ! Bx_, By_, Bz_ have to be defined so that the code compiles
  ! but the Bx_ = Ux_ choice indicates that B is not used (see UseB in ModMain)
  integer, parameter :: Bx_ = Ux_, By_ = Uy_, Bz_ = Uz_, B_ = U_

  ! The default values for the state variables:
  ! Variables which are physically positive should be set to 1,
  ! variables that can be positive or negative should be set to 0:
  real, parameter :: DefaultState_V(nVar+nFluid) = (/ & 
       1.0, & ! Rho_
       0.0, & ! RhoUx_
       0.0, & ! RhoUy_
       0.0, & ! RhoUz_
       0.0, & ! LevelXe_
       0.0, & ! LevelBe_
       0.0, & ! LevelPl_
       (1.0, iWave=WaveFirst_,WaveLast_), &
       0.0, & ! ExtraEint_
       1.0, & ! p_
       1.0 /) ! Energy_

  ! The names of the variables used in i/o
  character(len=*), parameter :: NameVar_V(nVar+nFluid) = (/ &
       'Rho ', & ! Rho_
       'Mx  ', & ! RhoUx_
       'My  ', & ! RhoUy_
       'Mz  ', & ! RhoUz_
       'Xe  ', & ! LevelXe_ 
       'Be  ', & ! LevelBe_
       'Pl  ', & ! LevelPl_
       ('Ew  ', iWave=WaveFirst_,WaveLast_), &
       'EInt', & ! ExtraEint_
       'P   ', & ! p_
       'E   '/)  ! Energy_

  ! The space separated list of nVar conservative variables for plotting
  character(len=*), parameter :: NameConservativeVar = &
       'Rho Mx My Mz Xe Be Pl Ew EInt E'

  ! The space separated list of nVar primitive variables for plotting
  character(len=*), parameter :: NamePrimitiveVar = &
       'Rho Ux Uy Uz Xe Be Pl Ew EInt P'

  ! The space separated list of nVar primitive variables for TECplot output
  character(len=*), parameter :: NamePrimitiveVarTec = &
       '"`r", "U_x", "U_y", "U_z", "Xe", "Be", "Pl", "Ew", "EInt", "p"'

  ! Names of the user units for IDL and TECPlot output
  character(len=20) :: &
       NameUnitUserIdl_V(nVar+nFluid) = '', NameUnitUserTec_V(nVar+nFluid) = ''

  ! The user defined units for the variables
  real :: UnitUser_V(nVar+nFluid) = 1.0

  ! Advected are the three level sets and the extra internal energy
  integer, parameter :: ScalarFirst_ = LevelXe_, ScalarLast_ = ExtraEint_

  ! There are no multi-species
  logical, parameter :: UseMultiSpecies = .false.

  ! Declare the following variables to satisfy the compiler
  integer, parameter :: SpeciesFirst_ = 1, SpeciesLast_ = 1
  real               :: MassSpecies_V(SpeciesFirst_:SpeciesLast_)
  integer, parameter :: iRho_I(nFluid)   = (/Rho_/)
  integer, parameter :: iRhoUx_I(nFluid) = (/RhoUx_/)
  integer, parameter :: iRhoUy_I(nFluid) = (/RhoUy_/)
  integer, parameter :: iRhoUz_I(nFluid) = (/RhoUz_/)
  integer, parameter :: iP_I(nFluid)     = (/p_/)

contains

  subroutine init_mod_equation

    call init_mhd_variables

    ! Set the unit and unit name for the wave energy variable
    do iWave = WaveFirst_, WaveLast_
       UnitUser_V(iWave)        = UnitUser_V(Energy_)
       NameUnitUserTec_V(iWave) = NameUnitUserTec_V(Energy_)
       NameUnitUserIdl_V(iWave) = NameUnitUserIdl_V(Energy_)
    end do

    UnitUser_V(LevelXe_:LevelPl_) = 1e-6 ! = No2Io_V(UnitX_) = micron

  end subroutine init_mod_equation

end module ModVarIndexes
