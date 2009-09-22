!^CFG COPYRIGHT UM
!========================================================================
module ModUser
  ! This is the default user module which contains empty methods defined
  ! in ModUserEmpty.f90

  use ModUserEmpty,                                     &
       IMPLEMENTED1 => user_update_states,              &
       IMPLEMENTED2 => user_calc_sources,               &
       IMPLEMENTED3 => user_set_outerbcs,               &
       IMPLEMENTED4 => user_read_inputs,                &
       IMPLEMENTED5 => user_set_plot_var,               &
       IMPLEMENTED6 => user_init_session,               &
       IMPLEMENTED7 => user_set_ics,                    &
       IMPLEMENTED8 => user_material_properties,        &
       IMPLEMENTED9 => user_amr_criteria

  use ModMain, ONLY: iTest, jTest, kTest, BlkTest, ProcTest, VarTest, &
       UseUserInitSession, UseUserIcs, UseUserSource, UseUserUpdateStates

  use CRASH_ModEos, ONLY: cAtomicMass_I, cAPolyimide

  include 'user_module.h' !list of public methods

  real,              parameter :: VersionUserModule = 1.2
  character (len=*), parameter :: &
       NameUserModule = 'HYDRO + IONIZATION EQUILIBRIUM + LEVEL SETS'

  ! There are 3 materials: Xe, Be and Plastic
  integer, parameter :: nMaterial = 3

  ! Average atomic mass of the materials (initialized in user_init_session)
  real, parameter:: MassMaterial_I(0:nMaterial-1) = &
       (/ cAtomicMass_I(54), cAtomicMass_I(4), cAPolyimide /)

  ! Fully 3D simulation?
  logical :: IsThreeDim = .false.

  ! Nozzle that shrinks the circular cross section of the tube 
  ! into an ellipse or smaller circle
  logical :: UseNozzle = .false.
  real    :: xStartNozzle = 0.0
  real    :: xEndNozzle   = 0.0
  real    :: yRatioNozzle = 0.0
  real    :: zRatioNozzle = 0.0

  ! Wall parameters
  logical:: UseTube = .false.
  real :: xEndTube   =   40.0    ! x coordinate of tube ending
  real :: rInnerTube =  287.5    ! inner radius [micron]
  real :: rOuterTube =  312.5    ! outer radius [micron]
  real :: RhoDimTube = 1430.0    ! density      [kg/m3]
  real :: RhoDimOutside = 6.5    ! density  of Xe outside tube [kg/m3]
  real :: pDimOutside   = 1.1e5  ! pressure of Xe outside tube [Pa]

  ! Allow overwriting the Xe state inside the tube for x > xUniformXe > 0
  real :: xUniformXe = -1.0

  ! Description of gold washer around the tube
  logical :: UseGold = .false.
  real :: WidthGold  = 50.0      ! width   [micron]
  real :: RhoDimGold = 20000.0   ! density [kg/m3]

  ! Use volume fraction method at the material interface
  logical :: UseVolumeFraction = .false.

  ! Treat cells near material interface as a mixture
  logical :: UseMixedCell = .false.

  ! Mixed material cell is assumed if the ratio of dominant to total
  ! atomic concentration is below MixLimit
  real :: MixLimit = 0.97

  ! Variables for Hyades file
  logical           :: UseHyadesFile   = .false. ! read Hyades file?
  character(len=100):: NameHyadesFile            ! name of hyades file
  integer           :: nDimHyades      = -1      ! number of dimensions 
  integer           :: nVarHyades      = -1      ! number of variables
  integer           :: nCellHyades     = -1      ! number of cells
  integer           :: iCellLastHyades = -1      ! cell with maximum X and r=0
  real              :: xBeHyades       = -1.0    ! position of Be-Xe interface
  real, allocatable :: DataHyades_VC(:,:)        ! cell centered Hyades data
  real, allocatable :: LevelHyades_VC(:,:)       ! level set functions
  integer           :: iXHyades        = -1      ! index of x coordinate
  integer           :: iRHyades        = -1      ! index of r coordinate
  integer           :: iRhoHyades      = -1      ! index of density
  integer           :: iUxHyades       = -1      ! index of x velocity
  integer           :: iUrHyades       = -1      ! index of r velocity
  integer           :: iPHyades        = -1      ! index of pressure
  integer           :: iZHyades        = -1      ! index of ionization level
  integer           :: iTeHyades       = -1      ! index of electron temper.
  integer           :: iTiHyades       = -1      ! index of ion temperature
  integer           :: iTrHyades       = -1      ! index of rad. temperature
  integer           :: iMaterialHyades = -1      ! index of material type


  ! Opacity scale factor for sensitivity studies on opacities (UQ only !)
  real :: RosselandScaleFactor_I(0:nMaterial-1) = 1.0
  real :: PlanckScaleFactor_I(0:nMaterial-1) = 1.0

  ! Gamma law per material (UQ only !)
  logical :: UseGammaLaw = .false.
  real :: Gamma_I(0:nMaterial-1) = 5.0/3.0

  ! Fixed average ion charge per material (UQ only !)
  logical :: UseFixedIonCharge = .false.
  real :: IonCharge_I(0:nMaterial-1) = 1.0


  ! Indexes for lookup tables
  integer:: iTablePPerE = -1, iTableEPerP = -1, iTableThermo = -1
  integer, parameter:: Cv_=1, Gamma_=2, Cond_=3, Te_=4, nThermo=4

  integer:: iTableOpacity = -1

  ! Variables for the left and right boundary conditions
  real :: DistBc1 = 200.0, TrkevBc1=0.0, EradBc1 = 0.0
  real :: DistBc2 = 200.0, TrkevBc2=0.0, EradBc2 = 0.0

  ! Variables for some tests
  logical :: UseWave    = .false.
  real    :: xStartWave = -100.0
  real    :: xEndWave   = +100.0
  real    :: DpWave     =  100.0

contains

  !============================================================================
  subroutine user_read_inputs

    use ModReadParam
    use CRASH_ModEos,      ONLY: read_eos_parameters
    use ModGeometry, ONLY: TypeGeometry, UseCovariant

    logical :: IsCylindrical
    character (len=100) :: NameCommand
    character(len=*), parameter :: NameSub = 'user_read_inputs'
    !------------------------------------------------------------------------

    UseUserUpdateStates = .true. ! for internal energy and cylindrical symm.
    UseUserInitSession  = .true. ! to set units for level set variables
    UseUserIcs          = .true. ! to read in Hyades file
    !                              and initialize the level set variables

    do
       if(.not.read_line() ) EXIT
       if(.not.read_command(NameCommand)) CYCLE
       select case(NameCommand)
       case("#HYADES")
          call read_var('UseHyadesFile', UseHyadesFile)
          call read_var('NameHyadesFile',NameHyadesFile)
       case("#TUBE")
          UseTube = .true.
          call read_var('xEndTube',   xEndTube)
          call read_var('rInnerTube', rInnerTube)
          call read_var('rOuterTube', rOuterTube)
          call read_var('RhoDimTube', RhoDimTube)
          call read_var('RhoDimOutside', RhoDimOutside)
          call read_var('pDimOutside',   pDimOutside)
          call read_var('xUniformXe',    xUniformXe)
       case("#GOLD")
          call read_var('UseGold',    UseGold)
          call read_var('WidthGold',  WidthGold)
          call read_var('RhoDimGold', RhoDimGold)
       case("#VOLUMEFRACTION")
          call read_var('UseVolumeFraction', UseVolumeFraction)
       case("#MIXEDCELL")
          call read_var('UseMixedCell', UseMixedCell)
          if(UseMixedCell)call read_var('MixLimit', MixLimit)
       case("#CYLINDRICAL")
          call read_var('IsCylindrical', IsCylindrical)
          if(IsCylindrical)then
             UseCovariant = .true.  ; TypeGeometry = 'rz'
          else
             UseCovariant = .false. ; TypeGeometry = 'cartesian'
          end if
       case("#EOS")
          call read_eos_parameters

       case("#OPACITYSCALEFACTOR") ! UQ only
          call read_var('PlanckScaleFactorXe', PlanckScaleFactor_I(0))
          call read_var('PlanckScaleFactorBe', PlanckScaleFactor_I(1))
          call read_var('PlanckScaleFactorPl', PlanckScaleFactor_I(2))
          call read_var('RosselandScaleFactorXe', RosselandScaleFactor_I(0))
          call read_var('RosselandScaleFactorBe', RosselandScaleFactor_I(1))
          call read_var('RosselandScaleFactorPl', RosselandScaleFactor_I(2))

       case("#GAMMALAW") ! UQ only
          call read_var('UseGammaLaw', UseGammaLaw)
          call read_var('GammaXe', Gamma_I(0))
          call read_var('GammaBe', Gamma_I(1))
          call read_var('GammaPl', Gamma_I(2))

       case("#FIXEDIONCHARGE") ! UQ only
          call read_var('UseFixedIonCharge', UseFixedIonCharge)
          call read_var('IonChargeXe', IonCharge_I(0))
          call read_var('IonChargeBe', IonCharge_I(1))
          call read_var('IonChargePl', IonCharge_I(2))

       case("#THREEDIM")
          call read_var('IsThreeDim', IsThreeDim)
       case("#NOZZLE")
          call read_var('UseNozzle', UseNozzle)
          if(UseNozzle)then
             call read_var('xStartNozzle', xStartNozzle)
             call read_var('xEndNozzle',   xEndNozzle)
             call read_var('yRatioNozzle', yRatioNozzle)
             call read_var('zRatioNozzle', zRatioNozzle)
          end if
       case("#WAVE")
          call read_var('UseWave',    UseWave)
          if(UseWave)then
             call read_var('xStartWave', xStartWave)
             call read_var('xEndWave',   xEndWave)
             call read_var('DpWave',     DpWave)
          end if
       case("#RADBOUNDARY")
          call read_var('DistBc1', DistBc1)
          call read_var('TrkevBc1', TrkevBc1)
          call read_var('DistBc2', DistBc2)
          call read_var('TrkevBc2', TrkevBc2)
       case('#USERINPUTEND')
          EXIT
       case default
          call stop_mpi('ERROR in ModUserCrash: unknown command='//NameCommand)
       end select
    end do

  end subroutine user_read_inputs
  !============================================================================
  subroutine user_set_outerbcs(iBlock, iSide, TypeBc, IsFound)

    use ModSize, ONLY: nI, nJ, nK
    use ModAdvance, ONLY: State_VGB, Erad_
    use ModImplicit, ONLY: StateSemi_VGB
    use ModGeometry, ONLY: dx_BLK

    integer,          intent(in)  :: iBlock, iSide
    character(len=20),intent(in)  :: TypeBc
    logical,          intent(out) :: IsFound

    character (len=*), parameter :: NameSub = 'user_set_outerbcs'

    real :: Dx
    !-------------------------------------------------------------------
    IsFound = iSide < 3
    if(.not.IsFound) RETURN

    ! Mixed boundary condition for Erad: 
    ! assume a linear profile to a fixed value at some distance
    Dx = dx_BLK(iBlock)

    if(iSide == 1)then
       if(TypeBc /= 'usersemi')then

          ! Float for all variables

          State_VGB(:, 0,:,:,iBlock) = State_VGB(:,1,:,:,iBlock)
          State_VGB(:,-1,:,:,iBlock) = State_VGB(:,1,:,:,iBlock)

          State_VGB(Erad_,0,:,:,iBlock) = &
               ( (DistBc1 - 0.5*Dx)*State_VGB(Erad_,1,:,:,iBlock) &
               + Dx*EradBc1 ) / (DistBc1 + 0.5*Dx)
          State_VGB(Erad_,-1,:,:,iBlock) = &
               2*State_VGB(Erad_,0,:,:,iBlock) &
               - State_VGB(Erad_,1,:,:,iBlock)
       else
          StateSemi_VGB(1,0,:,:,iBlock) = &
               ( (DistBc1 - 0.5*Dx)*StateSemi_VGB(1,1,:,:,iBlock) &
               + Dx*EradBc1 ) / (DistBc1 + 0.5*Dx)
          StateSemi_VGB(1,-1,:,:,iBlock) = &
               2*StateSemi_VGB(1,0,:,:,iBlock) &
               - StateSemi_VGB(1,1,:,:,iBlock)
       end if
    else
       if(TypeBc /= 'usersemi')then
          ! Float for all variables
          State_VGB(:,nI+1,:,:,iBlock) = State_VGB(:,nI,:,:,iBlock)
          State_VGB(:,nI+2,:,:,iBlock) = State_VGB(:,nI,:,:,iBlock)

          State_VGB(Erad_,nI+1,:,:,iBlock) = &
               ( (DistBc2 - 0.5*Dx)*State_VGB(Erad_,nI,:,:,iBlock) &
               + Dx*EradBc2 ) / (DistBc2 + 0.5*Dx)
          State_VGB(Erad_,nI+2,:,:,iBlock) = &
               2*State_VGB(Erad_,nI+1,:,:,iBlock) &
               - State_VGB(Erad_,nI  ,:,:,iBlock)
       else
          StateSemi_VGB(1,nI+1,:,:,iBlock) = &
               ( (DistBc2 - 0.5*Dx)*StateSemi_VGB(1,nI,:,:,iBlock) &
               + Dx*EradBc2 ) / (DistBc2 + 0.5*Dx)
          StateSemi_VGB(1,nI+2,:,:,iBlock) = &
               2*StateSemi_VGB(1,nI+1,:,:,iBlock) &
               - StateSemi_VGB(1,nI  ,:,:,iBlock)
       end if
    end if

  end subroutine user_set_outerbcs

  !============================================================================
  subroutine user_set_ics

    use ModProcMH,      ONLY: iProc
    use ModMain,        ONLY: GlobalBlk, nI, nJ, nK
    use ModPhysics,     ONLY: inv_gm1, ShockPosition, ShockSlope, &
         Io2No_V, No2Si_V, Si2No_V, UnitRho_, UnitP_, UnitEnergyDens_
    use ModAdvance,     ONLY: State_VGB, Rho_, RhoUx_, RhoUz_, p_, &
         ExtraEint_, LevelBe_, LevelXe_, LevelPl_, &
         Ee_, UseElectronEnergy
    use ModVarIndexes,  ONLY: Erad_
    use ModGeometry,    ONLY: x_BLK, y_BLK, z_BLK
    use ModLookupTable, ONLY: interpolate_lookup_table
    use ModConst,       ONLY: cPi
    use CRASH_ModEos,   ONLY: eos

    real    :: x, y, z, r, xBe, DxBe, DxyPl, EinternalSi
    real    :: DxyGold = -1.0

    integer :: iBlock, i, j, k

    character(len=*), parameter :: NameSub = "user_set_ics"
    !------------------------------------------------------------------------

    iBlock = GlobalBlk

    if(UseHyadesFile)then
       ! Read in and interpolate Hyades output
       if(.not.allocated(DataHyades_VC)) call read_hyades_file

       if(nDimHyades == 1)then
          call interpolate_hyades1d(iBlock)
       else
          call interpolate_hyades2d(iBlock)
       end if
    end if

    if(UseElectronEnergy .and. (UseTube .or. UseGold))then
       call stop_mpi(NameSub //" electron energy does not yet work " &
            //"with plastic tube or gold washer")
    end if

    ! Set level set functions, internal energy, and other values
    do k=1, nK; do j=1, nJ; do i=1, nI 

       x = x_BLK(i,j,k,iBlock)
       y = y_BLK(i,j,k,iBlock)
       z = z_BLK(i,j,k,iBlock)

       if(UseNozzle) call set_nozzle_yz(x,y,z)

       if(IsThreeDim)then
          r = sqrt(y**2 + z**2)
       else
          r = abs(y)
       end if

       if(UseTube)then
          ! Distance from plastic wall: 
          ! positive for rInnerTube < |y| < rOuterTube and x > xEndTube only
          DxyPl = &
               min(r - rInnerTube, rOuterTube - r, x - xEndTube)

          ! Set plastic tube state
          if(DxyPl > 0.0)then

             ! Use the density and pressure given by the #TUBE command
             State_VGB(Rho_,i,j,k,iBlock) = RhoDimTube*Io2No_V(UnitRho_)
             State_VGB(p_  ,i,j,k,iBlock) = pDimOutside*Io2No_V(UnitP_)
             State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock) = 0.0

             call set_small_radiation_energy
             if(nDimHyades == 2)then
                State_VGB(LevelPl_,i,j,k,iBlock) =  DxyPl
                State_VGB(LevelXe_,i,j,k,iBlock) =  &
                     max(State_VGB(LevelBe_,i,j,k,iBlock), r - rOuterTube)
             end if
          end if

          ! Set pressure and speed outside the tube. 
          ! For 1D Hyades input do not overwrite values left of xEndTube
          if(r > rOuterTube .and. (nDimHyades == 1 .or. x > xEndTube) ) then
             State_VGB(Rho_,i,j,k,iBlock) = RhoDimOutside*Io2No_V(UnitRho_)
             State_VGB(p_  ,i,j,k,iBlock) = pDimOutside*Io2No_V(UnitP_)
             State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock) = 0.0
             call set_small_radiation_energy
             if(nDimHyades == 2)then
                State_VGB(LevelXe_,i,j,k,iBlock) =  &
                     min(r - rOuterTube,x - xEndTube) 
                State_VGB(LevelPl_,i,j,k,iBlock) =  rOuterTube - r
             end if
          end if

          ! Set the Xe state inside the tube for x > xUniformXe if it is set
          if(xUniformXe > 0.0 .and. x > xUniformXe .and. r < rInnerTube)then
             State_VGB(Rho_,i,j,k,iBlock) = RhoDimOutside*Io2No_V(UnitRho_)
             State_VGB(p_  ,i,j,k,iBlock) = pDimOutside*Io2No_V(UnitP_)
             State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock) = 0.0
             call set_small_radiation_energy
          end if
       end if
       ! Distance from gold washer xEndTube < x < xEndTube + WidthGold
       if(UseGold) then

          DxyGold = &
               min(x - xEndTube, xEndTube + WidthGold - x, r - rOuterTube)

          ! Set density of gold washer (if present)
          if(DxyGold > 0.0) then

             State_VGB(Rho_,i,j,k,iBlock) = RhoDimGold*Io2No_V(UnitRho_)
             State_VGB(p_  ,i,j,k,iBlock) = pDimOutside*Io2No_V(UnitP_)
             State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock) = 0.0
             call set_small_radiation_energy
             DxyGold = min(x - xEndTube, r - rOuterTube)
             if(nDimHyades == 2)then
                State_VGB(LevelPl_,i,j,k,iBlock) = rOuterTube - r 
                State_VGB(LevelXe_,i,j,k,iBlock) = DxyGold
             end if
          end if

       end if

       ! Create sound wave by making a pressure hump (for testing)
       if(UseWave .and. x > xStartWave .and. x < xEndWave) &
            State_VGB(p_,i,j,k,iBlock) = State_VGB(p_,i,j,k,iBlock) + &
            Io2No_V(UnitP_)*DpWave &
            *sin( cPi*(x - xStartWave)/(xEndWave - xStartWave) )**2

       if(nDimHyades /= 2)then

          if(UseHyadesFile)then
             ! Be - Xe interface is given by Hyades file
             xBe = xBeHyades
          else
             ! Be - Xe interface is at the shock defined by #SHOCKPOSITION
             xBe = ShockPosition - ShockSlope*y_BLK(i,j,k,iBlock)
          end if

          ! Distance from Be disk: positive for x < xBe
          DxBe = xBe - x

          ! Add a plastic tube if required
          if(UseTube)then
             ! Distance from plastic wall: 
             ! positive for rInnerTube < |y| < rOuterTube and x > xEndTube only
             DxyPl = min(r - rInnerTube, rOuterTube - r, x - xEndTube)

             ! Berylium is left of xBe inside rInnerTube 
             ! and it is left of xEndTube outside
             State_VGB(LevelBe_,i,j,k,iBlock) = &
                  max(xEndTube - x, min(DxBe, rInnerTube - r))

             ! Xenon is right of xBe inside rInnerTube and 
             ! right of xEndTube outside rOuterTube
             State_VGB(LevelXe_,i,j,k,iBlock) = max( &
                  min( x - xEndTube, r - rOuterTube), &
                  min( -DxBe, rInnerTube - r) )

             ! Plastic 
             State_VGB(LevelPl_,i,j,k,iBlock) = DxyPl
          else
             ! If there is no plastic tube, things are easy
             State_VGB(LevelBe_,i,j,k,iBlock) =  DxBe
             State_VGB(LevelXe_,i,j,k,iBlock) = -DxBe
             State_VGB(LevelPl_,i,j,k,iBlock) = -1e30
          end if

       end if ! nDimHyades /= 2

       if(UseMixedCell)then
          ! Use atomic concentrations instead of smooth level set functions

          if(maxval( State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) ) <= 0.0)then
             State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) = 1.0/(3*MassMaterial_I)
          else
             State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) = &
                  max(0.0, State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock))

             where( State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) > 0.0) &
                  State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) = 1./MassMaterial_I
          end if

       end if

       ! Multiply level set functions with density unless the 
       ! non-conservative approach is used
       if(.not.UseUserSource) &
            State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) = &
            State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) &
            *State_VGB(Rho_,i,j,k,iBlock)

       ! Calculate internal energy
       call user_material_properties(State_VGB(:,i,j,k,iBlock), &
            i, j, k, iBlock, EinternalSiOut=EinternalSi)

       if(UseElectronEnergy)then
          State_VGB(ExtraEint_,i,j,k,iBlock) = &
               EinternalSi*Si2No_V(UnitEnergyDens_) &
               - State_VGB(Ee_,i,j,k,iBlock)
       else
          State_VGB(ExtraEint_,i,j,k,iBlock) = &
               EinternalSi*Si2No_V(UnitEnergyDens_) &
               - inv_gm1*State_VGB(P_,i,j,k,iBlock)
       end if

    end do; end do; end do

  contains
    !==========================================================================
    subroutine set_small_radiation_energy

      use ModMain,ONLY: UseRadDiffusion
      use ModPhysics,ONLY: cRadiationNo, Si2No_V, UnitTemperature_
      !----------------------------------------------------------------------
      if(.not.UseRadDiffusion)RETURN

      State_VGB(Erad_,i,j,k,iBlock) = cRadiationNo * &
           (500.0 * Si2No_V(UnitTemperature_))**4

    end subroutine set_small_radiation_energy

  end subroutine user_set_ics

  !============================================================================

  subroutine read_hyades_file

    use ModAdvance,   ONLY: UseElectronEnergy
    use ModIoUnit,    ONLY: UnitTmp_
    use ModPhysics,   ONLY: Si2No_V, Io2No_V, UnitX_, UnitRho_, UnitU_, &
         UnitP_, UnitTemperature_
    use ModUtilities, ONLY: split_string
    use CRASH_ModEos, ONLY: Xe_, Be_, Plastic_
    use ModConst,     ONLY: cKevToK
    use ModMain,      ONLY: UseRadDiffusion

    integer             :: nStepHyades, nEqparHyades
    integer, allocatable:: nCellHyades_D(:)
    real                :: TimeHyades
    real, allocatable   :: EqparHyades_I(:), Hyades2No_V(:)
    character(len=100)  :: StringHeadHyades, NameVarHyades

    ! Variables for reading in variable names
    integer, parameter:: MaxString = 20
    character(len=10) :: String_I(MaxString)
    integer           :: nString

    ! Variables for setting level set functions
    integer :: iError, i, iCell, iMaterial, jMaterial
    real    :: x, r
    integer, allocatable:: iMaterial_C(:)
    real,    allocatable:: Distance2_C(:)

    character(len=*), parameter :: NameSub = "ModUser::read_hyades_file"
    !-------------------------------------------------------------------------
    open(UnitTmp_, FILE=NameHyadesFile, STATUS="old", IOSTAT=iError)

    if(iError /= 0)call stop_mpi(NameSub // &
         " could not open Hyades file="//NameHyadesFile)

    read(UnitTmp_, "(a)") StringHeadHyades
    read(UnitTmp_, *) &
         nStepHyades, TimeHyades, nDimHyades, nEqparHyades, nVarHyades

    ! Ignore negative value (signaling distorted grid)
    nDimHyades = abs(nDimHyades)

    ! Read grid size
    allocate(nCellHyades_D(nDimHyades))
    read(UnitTmp_,*) nCellHyades_D
    nCellHyades = product(nCellHyades_D)

    ! Read equation parameters
    allocate(EqparHyades_I(nEqparHyades))
    read(UnitTmp_,*) EqparHyades_I

    ! Read coordinate, variable and eqpar names
    read(UnitTmp_, "(a)") NameVarHyades
    call split_string(NameVarHyades, MaxString, String_I, nString)

    ! Find the columns for the coordinates and variables
    do i = 1, nDimHyades + nVarHyades
       ! The first nDimHyades strings are for the coordinates
       select case(String_I(i))
       case('x')
          iXHyades   = i
       case('y', 'r')
          iRHyades   = i
       case('rho')
          iRhoHyades = i
       case('ux')
          iUxHyades  = i
       case('uy', 'ur')
          iUrHyades  = i
       case('p')
          iPHyades   = i
       case('te')
          iTeHyades  = i
       case('ti')
          iTiHyades  = i
       case('tr')
          iTrHyades  = i
       case('z')
          iZHyades   = i
       case('material')
          iMaterialHyades = i
       end select

    end do
    ! Check if every coordinate/variable has been found
    if(iRhoHyades < 0)call stop_mpi(NameSub// &
         ' could not find rho in '//trim(NameVarHyades))

    if(iPHyades < 0)call stop_mpi(NameSub// &
         ' could not find p in '//trim(NameVarHyades))

    if(iUxHyades < 0)call stop_mpi(NameSub// &
         ' could not find ux in '//trim(NameVarHyades))

    if(iZHyades < 0 .and. iMaterialHyades < 0) call stop_mpi(NameSub// &
         ' could not find neither z nor material in '//trim(NameVarHyades))

    if(nDimHyades > 1)then
       ! y, uy and material are needed in 2D
       if(iRHyades < 0) call stop_mpi(NameSub// &
            ' could not find y/r in '//trim(NameVarHyades))
       if(iUrHyades < 0) call stop_mpi(NameSub// &
            ' could not find uy/ur in '//trim(NameVarHyades))
       if(iMaterialHyades < 0) call stop_mpi(NameSub// &
            ' could not find material in '//trim(NameVarHyades))
    end if

    ! Set conversion from Hyades units to normalized units
    allocate(Hyades2No_V(nDimHyades + nVarHyades))
    Hyades2No_V = 1.0
    Hyades2No_V(iXHyades)   = 0.01   * Si2No_V(UnitX_)   ! cm    -> m
    Hyades2No_V(iRhoHyades) = 1000.0 * Si2No_V(UnitRho_) ! g/cm3 -> kg/m3
    Hyades2No_V(iUxHyades)  = 0.01   * Si2No_V(UnitU_)   ! cm/s  -> m/s
    Hyades2No_V(iPHyades)   = 0.1    * Si2No_V(UnitP_)   ! dyne  -> Pa

    if(UseRadDiffusion .or. UseElectronEnergy)then
       if(iTeHyades < 0) call stop_mpi(NameSub// &
            ' could not find electron temperature in '//trim(NameVarHyades))

       Hyades2No_V(iTeHyades)= cKevToK* Si2No_V(UnitTemperature_) ! KeV   -> K
    end if

    if(UseRadDiffusion)then
       if(iTrHyades < 0) call stop_mpi(NameSub// &
            ' could not find radiation temperature in '//trim(NameVarHyades))

       Hyades2No_V(iTrHyades)= cKevToK* Si2No_V(UnitTemperature_) ! KeV   -> K
    end if

    if(UseElectronEnergy)then
       if(iTiHyades < 0) call stop_mpi(NameSub// &
            ' could not find ion temperature in '//trim(NameVarHyades))

       Hyades2No_V(iTiHyades)= cKevToK* Si2No_V(UnitTemperature_) ! KeV   -> K
    end if

    if(nDimHyades > 1)then
       Hyades2No_V(iRHyades)  = 0.01 * Si2No_V(UnitX_)   ! cm    -> m
       Hyades2No_V(iUrHyades) = 0.01 * Si2No_V(UnitU_)   ! cm/s  -> m/s
    end if

    ! Read in the data
    allocate(DataHyades_VC(nDimHyades + nVarHyades, nCellHyades))
    do iCell = 1, nCellHyades
       read(UnitTmp_, *) DataHyades_VC(:, iCell)
       ! Convert from CGS to normalized units
       DataHyades_VC(:, iCell) = DataHyades_VC(:, iCell) * Hyades2No_V
    end do
    close(UnitTmp_)

    if(iMaterialHyades > 0)then
       ! Convert material indexes to the 3 values used in CRASH
       ! Gold (3), Acrylic (4), Vacuum (5) --> Polyimid
       where(nint(DataHyades_VC(iMaterialHyades, :)) >= 3) &
            DataHyades_VC(iMaterialHyades, :) = Plastic_
    end if

    if(nDimHyades == 1)then

       ! Locate the Be-Xe interface in 1D 
       do iCell = 2, nCellHyades
          if(iMaterialHyades > 0)then
             ! Check if material changes from Be to Xe
             if(  nint(DataHyades_VC(iMaterialHyades, iCell-1)) == Be_ .and. &
                  nint(DataHyades_VC(iMaterialHyades, iCell  )) == Xe_) EXIT
          else
             ! Check if ionization level jumps through 5
             if(  DataHyades_VC(iZHyades, iCell-1) < 5.0 .and.  &
                  DataHyades_VC(iZHyades, iCell)   > 5.0 ) EXIT
          end if
       end do
       if(iCell > nCellHyades)call stop_mpi(NameSub // &
            ' could not find Be/Xe interface')

       xBeHyades = 0.5* &
            ( DataHyades_VC(iXHyades, iCell-1) &
            + DataHyades_VC(iXHyades, iCell))

    else

       ! Fix the pressure where it is set to some very small value
       where(DataHyades_VC(iPHyades, :) < 1e-10) &
            DataHyades_VC(iPHyades, :) = pDimOutside*Io2No_V(UnitP_)

       ! Find cell with maximum X coordinate along the symmetry axis
       iCellLastHyades = nCellHyades_D(1)

       ! Calculate level set functions on the Hyades grid using 
       ! the minimum distance between cells of different materials
       allocate(LevelHyades_VC(0:nMaterial-1, nCellHyades))

       if(UseMixedCell)then
          ! Simply set 1.0 the levelset function corresponding to the material
          LevelHyades_VC = -1.0
          do iCell = 1, nCellHyades
             LevelHyades_VC(nint(DataHyades_VC(iMaterialHyades,iCell)),iCell) &
                  = 1.0
          end do
       else
          ! Determine distance functions
          allocate(Distance2_C(nCellHyades), iMaterial_C(nCellHyades))
          do iCell = 1, nCellHyades
             x         = DataHyades_VC(iXHyades, iCell)
             r         = DataHyades_VC(iRHyades, iCell)
             iMaterial = DataHyades_VC(iMaterialHyades, iCell)

             ! Distance squared from all other points
             Distance2_C = (x - DataHyades_VC(iXHyades,:))**2       &
                  +        (r - DataHyades_VC(iRHyades,:))**2

             ! Integer value of material in Hyades grid
             iMaterial_C = DataHyades_VC(iMaterialHyades,:)

             ! For each cell set 3 level set functions
             do jMaterial = 0, nMaterial-1
                if(iMaterial == jMaterial)then
                   ! Level is the smallest distance to a different material
                   LevelHyades_VC(jMaterial, iCell) =  sqrt(minval &
                        ( Distance2_C, MASK=iMaterial_C /= jMaterial))
                else
                   ! Level is -1 times the smallest distance to same material
                   LevelHyades_VC(jMaterial, iCell) = - sqrt(minval &
                        ( Distance2_C, MASK=iMaterial_C == jMaterial))
                end if
             end do
          end do
          deallocate(Distance2_C, iMaterial_C)
       end if
    end if

    deallocate(EqparHyades_I)

  end subroutine read_hyades_file

  !============================================================================

  subroutine interpolate_hyades1d(iBlock)

    use ModSize,     ONLY: nI, nJ, nK
    use ModAdvance,  ONLY: State_VGB, Rho_, RhoUx_, RhoUy_, RhoUz_, p_, &
         Erad_, UseElectronEnergy, Ee_
    use ModGeometry, ONLY: x_BLK
    use ModPhysics,  ONLY: Si2No_V, No2Si_V, UnitTemperature_, &
         UnitP_, UnitN_, cRadiationNo, UnitEnergyDens_, inv_gm1
    use ModMain,     ONLY: UseRadDiffusion

    integer, intent(in) :: iBlock

    integer :: i, j, k, iCell
    real :: x, Weight1, Weight2
    real :: Tr, Te, TeSi, PeSi, Ti, Natomic, NatomicSi
    character(len=*), parameter :: NameSub='interpolate_hyades1d'
    !-------------------------------------------------------------------------
    do i = -1, nI+2
       ! Find the Hyades points around this position
       x = x_Blk(i,1,1,iBlock)

       do iCell=1, nCellHyades
          if(DataHyades_VC(iXHyades, iCell) >= x) EXIT
       end do
       if (iCell == 1) call stop_mpi(NameSub // &
            " Hyades solution does not cover the left boundary")

       if(iCell > nCellHyades)then
          ! Cell is beyond the last point of Hyades output: use last cell
          iCell   = nCellHyades
          Weight1 = 0.0
          Weight2 = 1.0
       else
          ! Assign weights for linear interpolation between iCell-1, iCell
          Weight1 = (DataHyades_VC(iXHyades, iCell) - x) &
               /    (DataHyades_VC(iXHyades, iCell) &
               -     DataHyades_VC(iXHyades, iCell-1))
          Weight2 = 1.0 - Weight1
       end if

       do k = -1,nk+2; do j = -1,nJ+2
          ! Interpolate density, momentum and pressure

          State_VGB(Rho_,i,j,k,iBlock) = &
               ( Weight1*DataHyades_VC(iRhoHyades, iCell-1) &
               + Weight2*DataHyades_VC(iRhoHyades, iCell) )

          State_VGB(RhoUx_,i,j,k,iBlock) =  State_VGB(Rho_,i,j,k,iBlock) * &
               ( Weight1*DataHyades_VC(iUxHyades, iCell-1) &
               + Weight2*DataHyades_VC(iUxHyades, iCell) )

          if(UseElectronEnergy)then
             Te = ( Weight1*DataHyades_VC(iTeHyades, iCell-1) &
                  + Weight2*DataHyades_VC(iTeHyades, iCell) )
             Ti = ( Weight1*DataHyades_VC(iTiHyades, iCell-1) &
                  + Weight2*DataHyades_VC(iTiHyades, iCell) )

             TeSi = Te*No2Si_V(UnitTemperature_)
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, TeSiIn=TeSi, &
                  PressureSiOut=PeSi, NatomicSiOut=NatomicSi)

             Natomic = NatomicSi*Si2No_V(UnitN_)
             State_VGB(p_,i,j,k,iBlock)  = Natomic*Ti
             State_VGB(Ee_,i,j,k,iBlock) = inv_gm1*PeSi*Si2No_V(UnitP_)
          else
             State_VGB(p_,i,j,k,iBlock) = &
                  ( Weight1*DataHyades_VC(iPHyades, iCell-1) &
                  + Weight2*DataHyades_VC(iPHyades, iCell) )
          end if

          ! Set transverse momentum to zero
          State_VGB(RhoUy_:RhoUz_,i,j,k,iBlock) = 0.0

          ! Radiation energy = cRadiation*Trad**4
          if(UseRadDiffusion)then
             Tr = ( Weight1*DataHyades_VC(iTrHyades, iCell-1) &
                  + Weight2*DataHyades_VC(iTrHyades, iCell) )

             State_VGB(Erad_,i,j,k,iBlock) = cRadiationNo*Tr**4
          end if

       end do; end do
    end do

  end subroutine interpolate_hyades1d

  !============================================================================

  subroutine interpolate_hyades2d(iBlock)

    ! Use Delaunay triangulation to interpolate Hyades grid onto CRASH grid

    use ModSize,     ONLY: nI, nJ, nK
    use ModAdvance,  ONLY: State_VGB, Rho_, RhoUx_, RhoUy_, RhoUz_, p_, &
         LevelXe_, LevelPl_, Erad_, UseElectronEnergy, Ee_
    use ModGeometry,    ONLY: x_BLK, y_BLK, z_BLK, y2
    use ModTriangulate, ONLY: calc_triangulation, find_triangle
    use ModMain,        ONLY: UseRadDiffusion
    use ModPhysics,     ONLY: cRadiationNo, No2Si_V, Si2No_V, &
         UnitTemperature_, UnitN_, UnitP_, UnitEnergyDens_, inv_gm1

    integer, intent(in) :: iBlock

    integer, save              :: nTriangle
    integer, allocatable, save :: iNodeTriangle_II(:,:)
    real, allocatable,    save :: DataHyades_V(:)
    real                       :: LevelHyades_V(0:nMaterial-1)

    integer :: i, j, k, iNode1, iNode2, iNode3
    real    :: x, y, z, r, Weight1, Weight2, Weight3
    real    :: WeightNode_I(3), WeightMaterial_I(0:nMaterial-1), Weight
    real    :: Te, TeSi, PeSi, Ti, Natomic, NatomicSi

    integer :: iMaterial, iMaterial_I(1), iMaterialNode_I(3)

    character(len=*), parameter :: NameSub='interpolate_hyades2d'
    !-------------------------------------------------------------------------
    if(.not.allocated(iNodeTriangle_II))then
       ! allocate variables and do triangulation
       allocate(iNodeTriangle_II(3,2*nCellHyades))
       allocate(DataHyades_V(nDimHyades + nVarHyades))
       call calc_triangulation( &
            nCellHyades, DataHyades_VC( (/iXHyades, iRHyades/), :), &
            iNodeTriangle_II, nTriangle)
    end if

    ! Interpolate points 
    do j = 1, nJ; do i = 1, nI; do k = 1, nk

       if(k == 1 .or. IsThreeDim)then
          x = x_Blk(i,j,k,iBlock)
          y = y_Blk(i,j,k,iBlock)
          z = z_Blk(i,j,k,iBlock)

          if(UseNozzle) call set_nozzle_yz(x, y, z)

          if(IsThreeDim)then
             r = sqrt(y**2 + z**2)
          else
             r = abs(y)
             z = 0.0
          end if

          ! Check if we are further away than the width of the box
          if(r > y2)then
             ! Shrink coordinates in the radial direction to y2
             y = y*y2/r
             z = z*y2/r
             r = y2
          end if

          ! Check if we are at the end of the Hyades grid
          if(x >= DataHyades_VC(iXHyades, iCellLastHyades))then
             iNode1 = iCellLastHyades;  Weight1 = 1.0
             iNode2 = 1;                Weight2 = 0.0
             iNode3 = 1;                Weight3 = 0.0
          else
             ! Find the Hyades triangle around this position
             call find_triangle(&
                  nCellHyades, nTriangle, &
                  (/x, r/), DataHyades_VC( (/iXHyades, iRHyades/),:), &
                  iNodeTriangle_II(:,1:nTriangle), &
                  iNode1, iNode2, iNode3, Weight1, Weight2, Weight3)
          end if

          ! Check if the 3 points consist of the same material or not
          ! If the materials are different use the points with the
          ! material that has the largest total weight

          ! Weight and material of the 3 nodes of the triangle
          WeightNode_I    = (/ Weight1, Weight2, Weight3 /)
          iMaterialNode_I = DataHyades_VC(iMaterialHyades, &
               (/iNode1, iNode2, iNode3/) )

          if(maxval(iMaterialNode_I) /= minval(iMaterialNode_I))then

             ! Add up the weights for all materials
             do iMaterial = 0, nMaterial - 1
                WeightMaterial_I(iMaterial) = sum(WeightNode_I, &
                     MASK = (iMaterialNode_I == iMaterial) )
             end do

             ! Find the dominant material
             iMaterial_I = maxloc(WeightMaterial_I)
             iMaterial   = iMaterial_I(1) - 1
             Weight      = WeightMaterial_I(iMaterial)

             where(iMaterialNode_I == iMaterial) 
                ! Reset weights so they add up to 1 for the dominant material
                WeightNode_I = WeightNode_I / Weight
             elsewhere
                ! Other materials get zero weight
                WeightNode_I = 0.0
             end where

          end if

          DataHyades_V = &
               WeightNode_I(1)*DataHyades_VC(:, iNode1) + &
               WeightNode_I(2)*DataHyades_VC(:, iNode2) + &
               WeightNode_I(3)*DataHyades_VC(:, iNode3)

          LevelHyades_V = &
               WeightNode_I(1)*LevelHyades_VC(:, iNode1) + &
               WeightNode_I(2)*LevelHyades_VC(:, iNode2) + &
               WeightNode_I(3)*LevelHyades_VC(:, iNode3)
       end if

       ! Interpolate density, momentum and pressure

       State_VGB(Rho_,i,j,k,iBlock)  = DataHyades_V(iRhoHyades)

       if(UseElectronEnergy)then
          Te = DataHyades_V(iTeHyades)
          Ti = DataHyades_V(iTiHyades)

          TeSi = Te*No2Si_V(UnitTemperature_)
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, TeSiIn=TeSi, &
               PressureSiOut=PeSi, NatomicSiOut=NatomicSi)

          Natomic = NatomicSi*Si2No_V(UnitN_)
          State_VGB(p_,i,j,k,iBlock)  = Natomic*Ti
          State_VGB(Ee_,i,j,k,iBlock) = inv_gm1*PeSi*Si2No_V(UnitP_)
       else
          State_VGB(p_,i,j,k,iBlock)  = DataHyades_V(iPHyades)
       end if

       State_VGB(RhoUx_,i,j,k,iBlock) = &
            DataHyades_V(iRhoHyades) * DataHyades_V(iUxHyades)

       State_VGB(RhoUy_:RhoUz_,i,j,k,iBlock) = (/y, z/)/r * &
            DataHyades_V(iRhoHyades) * DataHyades_V(iUrHyades)

       ! Interpolate level set functions
       State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock) = LevelHyades_V

       ! Radiation energy = cRadiation*Trad**4
       if(UseRadDiffusion) State_VGB(Erad_,i,j,k,iBlock) = &
            cRadiationNo * DataHyades_V(iTrHyades)**4

    end do; end do; end do

  end subroutine interpolate_hyades2d

  !============================================================================

  subroutine user_update_states(iStage,iBlock)

    use ModSize,    ONLY: nI, nJ, nK
    use ModAdvance, ONLY: State_VGB, p_, ExtraEint_, &
         UseNonConservative, IsConserv_CB, &
         Source_VC, uDotArea_XI, uDotArea_YI, uDotArea_ZI, &
         UseElectronEnergy
    use ModGeometry, ONLY: vInv_CB
    use ModPhysics,  ONLY: g, inv_gm1, Si2No_V, No2Si_V, &
         UnitP_, UnitEnergyDens_
    use ModEnergy,  ONLY: calc_energy_cell

    implicit none

    integer, intent(in):: iStage,iBlock

    integer:: i, j, k
    real   :: PressureSi, EinternalSi, GammaEos
    logical:: IsConserv

    character(len=*), parameter :: NameSub = 'user_update_states'
    !------------------------------------------------------------------------
    if(UseElectronEnergy)then
       call update_states_electron

       RETURN
    end if

    ! Fix adiabatic compression source for pressure
    if(UseNonConservative)then
       do k=1,nK; do j=1,nJ; do i=1,nI
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, GammaOut=GammaEos)
          Source_VC(p_,i,j,k) = Source_VC(p_,i,j,k) &
               -(GammaEos-g)*State_VGB(p_,i,j,k,iBlock)*&
               vInv_CB(i,j,k,iBlock)*&
               ( uDotArea_XI(i+1,j,k,1) - uDotArea_XI(i,j,k,1) &
               + uDotArea_YI(i,j+1,k,1) - uDotArea_YI(i,j,k,1) &
               + uDotArea_ZI(i,j,k+1,1) - uDotArea_ZI(i,j,k,1) )
       end do; end do; end do
    end if

    call update_states_MHD(iStage,iBlock)

    ! update of pressure, ionization and total energies
    do k=1,nK; do j=1,nJ; do i=1,nI
       ! Total internal energy ExtraEint + P/(\gamma -1) transformed to SI

       if(allocated(IsConserv_CB))then
          IsConserv = IsConserv_CB(i,j,k,iBlock)
       else
          IsConserv = .not. UseNonConservative
       end if

       if(IsConserv)then
          ! At this point p=(g-1)(e-rhov^2/2) with the ideal gamma g.
          ! Use this p to get total internal energy density.
          EinternalSi = No2Si_V(UnitEnergyDens_)*&
               (inv_gm1*State_VGB(P_,i,j,k,iBlock) + &
               State_VGB(ExtraEint_,i,j,k,iBlock))
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, &
               EinternalSiIn=EinternalSi, PressureSiOut=PressureSi)

          ! Set true pressure
          State_VGB(p_,i,j,k,iBlock) = PressureSi*Si2No_V(UnitP_)
       else
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, EinternalSiOut=EinternalSi)
       end if

       ! Set ExtraEint = Total internal energy - P/(gamma -1)
       State_VGB(ExtraEint_,i,j,k,iBlock) = &
            Si2No_V(UnitEnergyDens_)*EinternalSi &
            - inv_gm1*State_VGB(p_,i,j,k,iBlock)

    end do; end do; end do

    call calc_energy_cell(iBlock)

  contains

    subroutine update_states_electron

      use ModAdvance, ONLY: Ee_

      real :: PeSi, Ee, EeSi
      !------------------------------------------------------------------------

      call update_states_MHD(iStage,iBlock)

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         ! At this point Pe=(g-1)*Ee with the ideal gamma g.
         ! Use this Pe to get electron internal energy density.

         Ee = State_VGB(Ee_,i,j,k,iBlock) + State_VGB(ExtraEint_,i,j,k,iBlock)
         EeSi = Ee*No2Si_V(UnitEnergyDens_)

         call user_material_properties(State_VGB(:,i,j,k,iBlock), &
              i, j, k, iBlock, &
              EinternalSiIn=EeSi, PressureSiOut=PeSi)

         ! use true electron pressure
         State_VGB(Ee_,i,j,k,iBlock) = inv_gm1*PeSi*Si2No_V(UnitP_)

         ! Set ExtraEint = electron internal energy - Pe/(gamma -1)
         State_VGB(ExtraEint_,i,j,k,iBlock) = Ee - State_VGB(Ee_,i,j,k,iBlock)

         if(State_VGB(ExtraEint_,i,j,k,iBlock)<0.0)then
            write(*,*)NameSub,': ERROR extra internal energy =', &
                 State_VGB(ExtraEint_,i,j,k,iBlock)
            write(*,*)NameSub,': ERROR at i,j,k,iBlock=', i, j, k, iBlock
            call stop_mpi(NameSub//': ERROR negative extra internal energy')
         end if

      end do; end do; end do

    end subroutine update_states_electron

  end subroutine user_update_states

  !============================================================================

  subroutine user_calc_sources

    use ModMain,     ONLY: nI, nJ, nK, GlobalBlk
    use ModAdvance,  ONLY: State_VGB, LevelXe_, LevelPl_, &
         Source_VC, uDotArea_XI, uDotArea_YI, uDotArea_ZI
    use ModGeometry, ONLY: vInv_CB

    integer :: i, j, k, iBlock
    real :: DivU
    character (len=*), parameter :: NameSub = 'user_calc_sources'
    !-------------------------------------------------------------------

    iBlock = globalBlk

    ! Add Level*div(u) as a source term so level sets beome advected scalars
    ! Note that all levels use the velocity of the first (and only) fluid

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       DivU = vInv_CB(i,j,k,iBlock) &
            *(uDotArea_XI(i+1,j,k,1) - uDotArea_XI(i,j,k,1) &
            + uDotArea_YI(i,j+1,k,1) - uDotArea_YI(i,j,k,1) &
            + uDotArea_ZI(i,j,k+1,1) - uDotArea_ZI(i,j,k,1))

       Source_VC(LevelXe_:LevelPl_,i,j,k) = &
            Source_VC(LevelXe_:LevelPl_,i,j,k) &
            + State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock)*DivU

    end do; end do; end do

  end subroutine user_calc_sources

  !===========================================================================

  subroutine user_set_plot_var(iBlock, NameVar, IsDimensional, &
       PlotVar_G, PlotVarBody, UsePlotVarBody, &
       NameTecVar, NameTecUnit, NameIdlUnit, IsFound)

    use ModConst,   ONLY: cKtoKev, cBoltzmann
    use ModSize,    ONLY: nI, nJ, nK
    use ModAdvance, ONLY: State_VGB, Rho_, p_, LevelXe_, LevelBe_, LevelPl_, &
         nWave, WaveFirst_, WaveLast_, UseElectronEnergy
    use ModPhysics, ONLY: No2Si_V, No2Io_V, UnitRho_, UnitP_, &
         UnitTemperature_, cRadiationNo, No2Si_V, UnitEnergyDens_
    use ModLookupTable, ONLY: interpolate_lookup_table
    use ModGeometry, ONLY: r_BLK, x_BLK, y_BLK, TypeGeometry
    use CRASH_ModEos, ONLY: eos, Xe_, Be_, Plastic_

    integer,          intent(in)   :: iBlock
    character(len=*), intent(in)   :: NameVar
    logical,          intent(in)   :: IsDimensional
    real,             intent(out)  :: PlotVar_G(-1:nI+2, -1:nJ+2, -1:nK+2)
    real,             intent(out)  :: PlotVarBody
    logical,          intent(out)  :: UsePlotVarBody
    character(len=*), intent(inout):: NameTecVar
    character(len=*), intent(inout):: NameTecUnit
    character(len=*), intent(inout):: NameIdlUnit
    logical,          intent(out)  :: IsFound

    character (len=*), parameter :: Name='user_set_plot_var'

    real    :: p, Rho, pSi, RhoSi, TeSi, WaveEnergy
    real    :: PiSi, TiSi, NatomicSi
    real    :: AbsorptionOpacitySi_W(nWave)
    real    :: DiffusionOpacitySi_W(nWave)
    integer :: i, j, k, iMaterial, iMaterial_I(1), iLevel, iWave
    real    :: Value_V(nMaterial*nThermo) ! Cv,Gamma,Kappa,Te for 3 materials
    !------------------------------------------------------------------------  
    IsFound = .true.
    select case(NameVar)
    case('level', 'material')
       do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
          iMaterial_I = maxloc(State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock))
          PlotVar_G(i,j,k) = iMaterial_I(1)
       end do; end do; end do
    case('tekev', 'TeKev')
       NameIdlUnit = 'KeV'
       do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, TeSiOut = PlotVar_G(i,j,k))
          PlotVar_G(i,j,k) = PlotVar_G(i,j,k) * cKToKev
       end do; end do; end do
    case('tikev', 'TiKev')
       NameIdlUnit = 'KeV'
       if(UseElectronEnergy)then
          do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, NatomicSiOut=NatomicSi)
             PiSi = State_VGB(p_,i,j,k,iBlock)*No2Si_V(UnitP_)
             TiSi = PiSi/(cBoltzmann*NatomicSi)
             PlotVar_G(i,j,k) = TiSi*cKToKev
          end do; end do; end do
       else
          ! Te = Ti at all times, use Te
          do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, TeSiOut = PlotVar_G(i,j,k))
             PlotVar_G(i,j,k) = PlotVar_G(i,j,k) * cKToKev
          end do; end do; end do
       end if
    case('tradkev','trkev')
       ! radiation temperature is physically meaningless, but only
       ! used as a measure of the total radiation energy !!!
       ! multiply by sign of Erad for debugging purpose
       NameIdlUnit = 'KeV'
       do k = -1, nK+2; do j = -1, nJ+2; do i = -1, nI+2
          WaveEnergy = 0.0
          do iWave = WaveFirst_, WaveLast_
             WaveEnergy = WaveEnergy + State_VGB(iWave,i,j,k,iBlock)
          end do
          PlotVar_G(i,j,k) = sign(1.0,WaveEnergy) &
               *sqrt(sqrt(abs(WaveEnergy)/cRadiationNo))&
               * No2Si_V(UnitTemperature_) * cKToKev
       end do; end do; end do
    case('planck')
       do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, &
               AbsorptionOpacitySiOut_W = AbsorptionOpacitySi_W)
          PlotVar_G(i,j,k) = AbsorptionOpacitySi_W(1)
       end do; end do; end do
    case('ross')
       do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, &
               DiffusionOpacitySiOut_W = DiffusionOpacitySi_W)
          PlotVar_G(i,j,k) = DiffusionOpacitySi_W(1)
       end do; end do; end do
    case('cond')
       do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, HeatCondSiOut = PlotVar_G(i,j,k))
       end do; end do; end do
    case('teti')
       do k=-1, nK+1; do j=-1, nJ+1; do i=-1,nI+2
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, TeTiRelaxSiOut = PlotVar_G(i,j,k))
       end do; end do; end do
    case('usersphere')
       ! Test function for LOS images: sphere with "density" 
       !    100 - r^2 inside r=10, and 0 outside.
       if(TypeGeometry == 'rz')then
          ! In R-Z geometry the "sphere" is a circle in the X-Y plane
          PlotVar_G = max(0.0, &
               100 - x_BLK(:,:,:,iBlock)**2 - y_BLK(:,:,:,iBlock)**2)
       else
          ! In Cartesian geometry it is real sphere
          PlotVar_G = max(0.0, 100 - r_BLK(:,:,:,iBlock)**2)
       end if
    case('rhoxe', 'rhobe', 'rhopl')
       select case(NameVar)
       case('rhoxe')
          iLevel = LevelXe_; iMaterial = Xe_
       case('rhobe')
          iLevel = LevelBe_; iMaterial = Be_
       case('rhopl')
          iLevel = LevelPl_; iMaterial = Plastic_
       end select
       if(UseMixedCell)then
          PlotVar_G = State_VGB(iLevel,:,:,:,iBlock)*MassMaterial_I(iMaterial)
       else
          do k=-1,nK+2; do j=-1,nJ+2; do i=-1,nI+2
             iMaterial_I = maxloc(State_VGB(LevelXe_:LevelPl_,i,j,k,iBlock))
             if(iMaterial_I(1) - 1 == iMaterial) then
                PlotVar_G(i,j,k) = State_VGB(Rho_,i,j,k,iBlock)
             else
                PlotVar_G(i,j,k) = 0.0
             end if
          end do; end do; end do
       end if
       if(IsDimensional) PlotVar_G = No2Io_V(UnitRho_)*PlotVar_G
    case default
       IsFound = .false.
    end select

    UsePlotVarBody = .false.
    PlotVarBody    = 0.0

  end subroutine user_set_plot_var

  !===========================================================================

  subroutine user_init_session

    use ModProcMH,      ONLY: iProc, iComm
    use ModVarIndexes,  ONLY: LevelXe_, LevelPl_, Rho_, UnitUser_V
    use ModLookupTable, ONLY: i_lookup_table, make_lookup_table
    use ModPhysics,     ONLY: cRadiationNo, Si2No_V, UnitTemperature_
    use ModConst,       ONLY: cKevToK, cHPlanckEV
    use ModWaves,       ONLY: nWave, FreqMinSI, FreqMaxSI
    use CRASH_ModMultiGroup, ONLY: set_multigroup
    character (len=*), parameter :: NameSub = 'user_init_session'
    !-------------------------------------------------------------------

    if(UseUserSource)then
       UnitUser_V(LevelXe_:LevelPl_) = 1.e-6 ! = No2Io_V(UnitX_) = micron
    else if(UseMixedCell) then
       UnitUser_V(LevelXe_:LevelPl_) = UnitUser_V(Rho_)
    else
       UnitUser_V(LevelXe_:LevelPl_) = UnitUser_V(Rho_)*1.e-6
    end if

    EradBc1 = cRadiationNo*(TrkevBc1*cKeVtoK*Si2No_V(UnitTemperature_))**4
    EradBc2 = cRadiationNo*(TrkevBc2*cKeVtoK*Si2No_V(UnitTemperature_))**4

    if(iProc==0) write(*,*) NameSub, 'EradBc1,EradBc2=', EradBc1, EradBc2

    iTablePPerE    = i_lookup_table('pPerE(rho,e/rho)')
    iTableEPerP    = i_lookup_table('ePerP(rho,p/rho)')
    iTableThermo   = i_lookup_table('Thermo(rho,p/rho)')
    iTableOpacity  = i_lookup_table('Opacity(rho,T)')

    if(iProc==0) write(*,*) NameSub, &
         ' iTablePPerE, EPerP, Thermo, Opacity, Electron = ', &
         iTablePPerE, iTableEPerP, iTableThermo, iTableOpacity

    if(iTablePPerE > 0) &
         call make_lookup_table(iTablePPerE, calc_table_value, iComm)
    if(iTableEPerP > 0) &
         call make_lookup_table(iTableEPerP, calc_table_value, iComm)
    if(iTableThermo > 0) &
         call make_lookup_table(iTableThermo, calc_table_value, iComm)
    !\
    !Set the photon energy range
    !/
    !First, check if the values of FreqMinSI and FreqSI are set:
    
    if(FreqMinSI <= 0) then
       !Reset the minimum photon enrgy to be 0.1 eV
       FreqMinSI = 0.1 /cHPlanckEV
    end if

    if(FreqMaxSI <= 0) then
       !Reset the maximum photon enrgy to be 1 keV
       FreqMaxSI = 1000.0 /cHPlanckEV
    end if

    !If the frequency range IN HERZ has been alredy set, the previous
    !commands are skiped
    !Now set the number of groups and the frequency range:
    call set_multigroup(nWave, FreqMinSI, FreqMaxSI)

  end subroutine user_init_session

  !===========================================================================
  subroutine calc_table_value(iTable, Arg1, Arg2, Value_V)

    use CRASH_ModEos, ONLY: eos
    use ModConst,ONLY: cProtonMass, cBoltzmann

    integer, intent(in):: iTable
    real, intent(in)   :: Arg1, Arg2
    real, intent(out)  :: Value_V(:)

    real:: Rho, p, e, Cv, Gamma, HeatCond, Te
    integer:: iMaterial
    character(len=*), parameter:: NameSub = 'ModUser::calc_table_value'
    !-----------------------------------------------------------------------

    if(UseGammaLaw)then
       ! UQ only
       call calc_table_gammalaw

       RETURN
    end if


    if(iTable == iTablePPerE)then
       ! Calculate p/e for Xe_, Be_ and Plastic_ for given Rho and e/Rho
       Rho = Arg1
       e   = Arg2*Rho
       do iMaterial = 0, nMaterial-1
          call eos(iMaterial, Rho, EtotalIn=e, pTotalOut=p)

          ! Material index starts from 0 :-( hence the +1
          if(p > 0.0)then
             Value_V(iMaterial+1) = p/e
          else
             Value_V(iMaterial+1) = 2./3.
          end if
       end do
    elseif(iTable == iTableEPerP)then
       ! Calculate e/p for Xe_, Be_ and Plastic_ for given Rho and p/Rho
       Rho = Arg1
       p   = Arg2*Rho
       do iMaterial = 0, nMaterial-1
          call eos(iMaterial, Rho, PtotalIn=p, eTotalOut=e)

          ! Material index starts from 0 :-( hence the +1
          if(e > 0.0)then
             Value_V(iMaterial+1) = e/p
          else
             Value_V(iMaterial+1) = 1.5
          end if
       end do
    elseif(iTable == iTableThermo)then
       ! Calculate cV, gamma, HeatCond and Te for Xe_, Be_ and Plastic_ 
       ! for given Rho and p/Rho
       Rho = Arg1
       p   = Arg2*Rho
       do iMaterial = 0, nMaterial-1
          call eos(iMaterial, Rho, PtotalIn=p, &
               CvTotalOut=Cv, GammaOut=Gamma, HeatCond=HeatCond, TeOut=Te)

          ! Note that material index starts from 0
          if(Te > 0.0)then
             Value_V(Cv_   +iMaterial*nThermo) = Cv
             Value_V(Gamma_+iMaterial*nThermo) = Gamma
             Value_V(Cond_ +iMaterial*nThermo) = HeatCond
             Value_V(Te_   +iMaterial*nThermo) = Te
          else
             ! The eos() function returned impossible values, take ideal gas
             Value_V(Cv_   +iMaterial*nThermo) = 1.5*Rho
             Value_V(Gamma_+iMaterial*nThermo) = 5./3.
             Value_V(Cond_ +iMaterial*nThermo) = 0.0
             Value_V(Te_   +iMaterial*nThermo) = p/Rho*cProtonMass/cBoltzmann
          end if
       end do
    else
       write(*,*)NameSub,' iTable=', iTable
       call stop_mpi(NameSub//' invalid value for iTable')
    endif

  contains

    subroutine calc_table_gammalaw

      use ModConst, ONLY: cAtomicMass

      real :: NatomicSi
      !------------------------------------------------------------------------
      if(iTable == iTablePPerE)then
         ! Calculate p/e for Xe_, Be_ and Plastic_ for given Rho and e/Rho
         Rho = Arg1
         e   = Arg2*Rho
         do iMaterial = 0, nMaterial-1
            Value_V(iMaterial+1) = Gamma_I(iMaterial) - 1.0
         end do
      elseif(iTable == iTableEPerP)then
         ! Calculate e/p for Xe_, Be_ and Plastic_ for given Rho and p/Rho
         Rho = Arg1
         p   = Arg2*Rho
         do iMaterial = 0, nMaterial-1
            Value_V(iMaterial+1) = 1.0/(Gamma_I(iMaterial) - 1.0)
         end do
      elseif(iTable == iTableThermo)then
         ! Calculate cV, gamma, HeatCond and Te for Xe_, Be_ and Plastic_
         ! for given Rho and p/Rho
         Rho = Arg1
         p   = Arg2*Rho
         do iMaterial = 0, nMaterial-1
            if(UseFixedIonCharge)then
               NatomicSi = Rho/(cAtomicMass*MassMaterial_I(iMaterial))
               Te = p/( (1.0+IonCharge_I(iMaterial))*NatomicSi*cBoltzmann )
            else
               call eos(iMaterial, Rho, PtotalIn=p, TeOut=Te)
            end if

            Value_V(Cv_   +iMaterial*nThermo) = p/Te/(Gamma_I(iMaterial)-1)
            Value_V(Gamma_+iMaterial*nThermo) = Gamma_I(iMaterial)
            Value_V(Cond_ +iMaterial*nThermo) = 0.0
            Value_V(Te_   +iMaterial*nThermo) = Te
         end do
      else
         write(*,*)NameSub,' iTable=', iTable
         call stop_mpi(NameSub//' invalid value for iTable')
      endif

    end subroutine calc_table_gammalaw

  end subroutine calc_table_value
  !===========================================================================

  subroutine user_material_properties(State_V, i, j, k, iBlock, iDir, &
       EinternalSiIn, TeSiIn, NatomicSiOut, &
       EinternalSiOut, TeSiOut, PressureSiOut, &
       CvSiOut, GammaOut, HeatCondSiOut, TeTiRelaxSiOut, &
       AbsorptionOpacitySiOut_W, DiffusionOpacitySiOut_W, &
       PlanckSiOut_W, CgTeSiOut_W, CgTgSiOut_W, TgSiOut_W)

    ! The State_V vector is in normalized units, all other physical
    ! quantities are in SI.
    !
    ! If the electron energy is used, then EinternalSiIn, EinternalSiOut,
    ! PressureSiOut, CvSiOut refer to the electron internal energies,
    ! electron pressure, and electron specific heat, respectively.
    ! Otherwise they refer to the total (electron + ion) internal energies,
    ! total (electron + ion) pressure, and the total specific heat.

    use CRASH_ModEos,  ONLY: eos, Xe_, Be_, Plastic_
    use CRASH_ModMultiGroup, ONLY: get_energy_g_from_temperature, &
         get_temperature_from_energy_g
    use ModMain,       ONLY: nI, nJ, nK
    use ModAdvance,    ONLY: State_VGB, UseElectronEnergy
    use ModPhysics,    ONLY: No2Si_V, UnitRho_, UnitP_, UnitEnergyDens_, &
         inv_gm1, g, Si2No_V, cRadiationNo, UnitTemperature_
    use ModVarIndexes, ONLY: nVar, Rho_, LevelXe_, LevelPl_, p_, nWave, &
         WaveFirst_, ExtraEint_, Ee_
    use ModLookupTable,ONLY: interpolate_lookup_table
    use ModConst,      ONLY: cAtomicMass

    real, intent(in) :: State_V(nVar)
    integer, optional, intent(in):: i, j, k, iBlock, iDir    ! cell/face index
    real, optional, intent(in)  :: EinternalSiIn             ! [J/m^3]
    real, optional, intent(in)  :: TeSiIn                    ! [K]
    real, optional, intent(out) :: NatomicSiOut              ! [1/m^3]
    real, optional, intent(out) :: EinternalSiOut            ! [J/m^3]
    real, optional, intent(out) :: TeSiOut                   ! [K]
    real, optional, intent(out) :: PressureSiOut             ! [Pa]
    real, optional, intent(out) :: CvSiOut                   ! [J/(K*m^3)]
    real, optional, intent(out) :: GammaOut                  ! dimensionless
    real, optional, intent(out) :: HeatCondSiOut             ! [J/(m*K*s)]
    real, optional, intent(out) :: TeTiRelaxSiOut            ! [1/s]
    real, optional, intent(out) :: &
         AbsorptionOpacitySiOut_W(nWave)                     ! [1/m]
    real, optional, intent(out) :: &
         DiffusionOpacitySiOut_W(nWave)                      ! [1/m]

    ! Multi-group specific interface. The variables are respectively:
    !  Group Planckian spectral energy density
    !  Derivative of group Planckian by electron temperature
    !  Group specific heat of the radiation
    !  Group radiation temperature
    real, optional, intent(out) :: PlanckSiOut_W(nWave)      ! [J/m^3]
    real, optional, intent(out) :: CgTeSiOut_W(nWave)        ! [J/(m^3*K)]
    real, optional, intent(out) :: CgTgSiOut_W(nWave)        ! [J/(m^3*K)]
    real, optional, intent(out) :: TgSiOut_W(nWave)          ! [K]

    logical :: IsMix
    integer :: iMaterial, iMaterial_I(1)
    real    :: pSi, RhoSi, TeSi, LevelSum
    real    :: Value_V(nMaterial*nThermo), Opacity_V(2*nMaterial)
    real, dimension(0:nMaterial-1) :: &
         pPerE_I, EperP_I, RhoToARatioSi_I, Weight_I
    real :: Level_I(3), LevelLeft, LevelRight

    ! multi-group variables
    integer :: iWave, iVar
    real :: EgSi, PlanckSi, CgTeSi, TgSi, CgTgSi, Tg

    character (len=*), parameter :: NameSub = 'user_material_properties'
    !-------------------------------------------------------------------------
    ! Density, transformed to SI
    RhoSi = No2Si_V(UnitRho_)*State_V(Rho_)

    ! The electron temperature may be needed for the opacities
    ! Initialize to negative value to see if it gets set
    TeSi = -7.70

    ! Find maximum level set value. 
    iMaterial_I = maxloc(State_V(LevelXe_:LevelPl_))
    iMaterial   = iMaterial_I(1) - 1

    ! By default use weight 1 for the material with maximum level
    IsMix               = .false.
    Weight_I            = 0.0
    Weight_I(iMaterial) = 1.0

    ! Calculate the weights
    if(UseVolumeFraction)then
       if(present(i) .and. .not. present(iDir))then
          ! This implementation is for 1D only !!!
          if(i>=0.and.i<=nI+1)then
             ! Divide by density to get actual levelset function
             Level_I = State_VGB(LevelXe_,i-1:i+1,j,k,iBlock) &
                  /    State_VGB(Rho_    ,i-1:i+1,j,k,iBlock)
             ! Calculate face values for the level set function
             LevelLeft  = 0.5*(Level_I(1)+Level_I(2))
             LevelRight = 0.5*(Level_I(2)+Level_I(3))
             ! Cell is mixed if face values change signs
             IsMix = LevelLeft*LevelRight < 0
             if(IsMix)then
                ! Make weight proportional to the cell volume fraction
                Weight_I(Xe_)      = max(LevelLeft,  LevelRight) &
                     /               abs(LevelLeft - LevelRight)
                Weight_I(Be_)      = 1 - Weight_I(Xe_)
                Weight_I(Plastic_) = 0.0
             end if
          end if
       end if
    elseif(UseMixedCell)then
       ! Shall we use mixed material cells?
       LevelSum = sum(State_V(LevelXe_:LevelPl_))
       IsMix = maxval(State_V(LevelXe_:LevelPl_)) < MixLimit*LevelSum 

       if(IsMix)then
          ! Use number densities for eos() or weights in look up tables.
          RhoToARatioSi_I = State_V(LevelXe_:LevelPl_)*No2Si_V(UnitRho_)
          Weight_I = State_V(LevelXe_:LevelPl_)/LevelSum
       end if
    end if

    if(UseElectronEnergy)then
       call get_electron_thermo
    else
       call get_thermo
    end if

    if(present(TeSiOut)) TeSiOut = TeSi

    if(present(AbsorptionOpacitySiOut_W) &
         .or. present(DiffusionOpacitySiOut_W))then

       if(iTableOpacity > 0 .and. nWave==1)then
          call interpolate_lookup_table(iTableOpacity, RhoSi, TeSi, &
               Opacity_V, DoExtrapolate = .false.)
          Opacity_V(1:2*nMaterial:2) = Opacity_V(1:2*nMaterial:2) &
               *PlanckScaleFactor_I
          Opacity_V(2:2*nMaterial:2) = Opacity_V(2:2*nMaterial:2) &
               *RosselandScaleFactor_I
          if(UseVolumeFraction)then
             if(present(AbsorptionOpacitySiOut_W)) AbsorptionOpacitySiOut_W &
                  = sum(Weight_I*Opacity_V(1:2*nMaterial:2)) * RhoSi
             if(present(DiffusionOpacitySiOut_W)) DiffusionOpacitySiOut_W &
                  = sum(Weight_I*Opacity_V(2:2*nMaterial:2)) * RhoSi
          else
             if(present(AbsorptionOpacitySiOut_W)) AbsorptionOpacitySiOut_W &
                  = Opacity_V(2*iMaterial + 1) * RhoSi
             if(present(DiffusionOpacitySiOut_W)) DiffusionOpacitySiOut_W &
                  = Opacity_V(2*iMaterial + 2) * RhoSi
          end if

       else
          ! multi-group opacities
          if(IsMix)then
             call eos(RhoToARatioSi_I, TeIn=TeSi, &
                  OpacityPlanckOut_I=AbsorptionOpacitySiOut_W, &
                  OpacityRosselandOut_I=DiffusionOpacitySiOut_W)
          else
             call eos(iMaterial, RhoSi, TeIn=TeSi, &
                  OpacityPlanckOut_I=AbsorptionOpacitySiOut_W, &
                  OpacityRosselandOut_I=DiffusionOpacitySiOut_W)
          end if

       end if
    end if

    if(present(PlanckSiOut_W) .or. present(CgTeSiOut_W))then
       do iWave = 1, nWave
          call get_energy_g_from_temperature( &
               iWave, TeSi, EgSI=PlanckSi, CgSI=CgTeSi)

          if(present(PlanckSiOut_W)) PlanckSiOut_W(iWave) = PlanckSi
          if(present(CgTeSiOut_W)) CgTeSiOut_W(iWave) = CgTeSi
       end do
    end if

    if(present(TgSiOut_W) .or. present(CgTgSiOut_W))then
       if(nWave == 1)then
          Tg = sqrt(sqrt(State_V(WaveFirst_)/cRadiationNo))
          if(present(TgSiOut_W)) TgSiOut_W = Tg*No2Si_V(UnitTemperature_)
          if(present(CgTgSiOut_W)) CgTgSiOut_W = 4.0*cRadiationNo*Tg**3 &
               *No2Si_V(UnitEnergyDens_)/No2Si_V(UnitTemperature_)
       else
          do iWave = 1, nWave
             iVar = WaveFirst_ + iWave - 1
             EgSi = State_V(iVar)*No2Si_V(UnitEnergyDens_)
             call get_temperature_from_energy_g(iWave, EgSi, &
                  TgSIOut=TgSi, CgSIOut=CgTgSi)

             if(present(TgSiOut_W)) TgSiOut_W(iWave) = TgSi
             if(present(CgTgSiOut_W)) CgTgSiOut_W(iWave) = CgTgSi
          end do
       end if
    end if

  contains

    !========================================================================

    subroutine get_thermo

      !----------------------------------------------------------------------

      ! Obtain the pressure from EinternalSiIn or TeSiIn or State_V
      ! Do this for various cases: mixed cell or not, lookup tables or not
      if(present(EinternalSiIn))then
         ! Obtain the pressure from EinternalSiIn
         if(iTablePPerE > 0)then
            ! Use lookup table
            call interpolate_lookup_table(iTablePPerE, RhoSi, &
                 EinternalSiIn/RhoSi, pPerE_I, DoExtrapolate = .false.)
            ! Use a number density weighted average
            pSi = EinternalSiIn*sum(Weight_I*pPerE_I)
         else
            ! Use EOS function
            if(IsMix)then
               call eos(RhoToARatioSi_I, eTotalIn=EinternalSiIn, &
                    pTotalOut=pSi, TeOut=TeSi, CvTotalOut=CvSiOut, &
                    GammaOut=GammaOut, HeatCond=HeatCondSiOut)
            else
               call eos(iMaterial, Rho=RhoSi, eTotalIn=EinternalSiIn, &
                    pTotalOut=pSi, TeOut=TeSi, CvTotalOut=CvSiOut, &
                    GammaOut=GammaOut, HeatCond=HeatCondSiOut)
            end if
         end if
      elseif(present(TeSiIn))then
         ! Calculate pressure from electron temperature
         TeSi = TeSiIn
         if( IsMix ) then
            call eos(RhoToARatioSi_I, TeIn=TeSiIn, &
                 eTotalOut=EinternalSiOut, pTotalOut=pSi, &
                 CvTotalOut=CvSiOut, GammaOut=GammaOut, &
                 HeatCond=HeatCondSiOut)
         else
            call eos(iMaterial, Rho=RhoSi, TeIn=TeSiIn, &
                 eTotalOut=EinternalSiOut, pTotalOut=pSi, &
                 CvTotalOut=CvSiOut, GammaOut=GammaOut, &
                 HeatCond=HeatCondSiOut)
         end if
      else
         ! Pressure is simply part of State_V
         pSi = State_V(p_)*No2Si_V(UnitP_)
         if(present(EinternalSiOut))then
            ! Obtain the internal energy from pressure
            if(iTableEPerP > 0)then
               call interpolate_lookup_table(iTableEPerP, RhoSi, &
                    pSi/RhoSi, EPerP_I, DoExtrapolate = .false.)
               ! Use a number density weighted average
               EinternalSiOut = pSi*sum(Weight_I*EPerP_I)
            else
               if(IsMix)then
                  call eos(RhoToARatioSi_I, pTotalIn=pSi, &
                       EtotalOut=EinternalSiOut, TeOut=TeSi, &
                       CvTotalOut=CvSiOut, GammaOut=GammaOut, &
                       HeatCond=HeatCondSiOut)
               else
                  call eos(iMaterial,RhoSi,pTotalIn=pSi, &
                       EtotalOut=EinternalSiOut, TeOut=TeSi, &
                       CvTotalOut=CvSiOut, GammaOut=GammaOut, &
                       HeatCond=HeatCondSiOut)
               end if
            end if
         end if
      end if

      if(present(PressureSiOut)) PressureSiOut = pSi

      if(present(TeSiOut) .or. present(CvSiOut) .or. present(GammaOut) .or. &
           present(HeatCondSiOut) .or. &
           present(AbsorptionOpacitySiOut_W) .or. &
           present(DiffusionOpacitySiOut_W) .or. &
           present(PlanckSiOut_W) .or. present(CgTeSiOut_W))then

         if(iTableThermo > 0)then
            call interpolate_lookup_table(iTableThermo, RhoSi, pSi/RhoSi, &
                 Value_V, DoExtrapolate = .false.)

            ! Value_V: elements 1,4,7 are Cv, 2,5,8 are Gamma, 3,6,9 are Te
            if(UseVolumeFraction)then
               if(present(CvSiOut))  CvSiOut  &
                    = sum(Weight_I*Value_V(Cv_   :nMaterial*nThermo:nThermo))
               if(present(GammaOut)) GammaOut &
                    = sum(Weight_I*Value_V(Gamma_:nMaterial*nThermo:nThermo))
               if(present(HeatCondSiOut)) HeatCondSiOut &
                    = sum(Weight_I*Value_V(Cond_:nMaterial*nThermo:nThermo))
               TeSi = sum(Weight_I*Value_V(Te_  :nMaterial*nThermo:nThermo))
            else
               if(present(CvSiOut))  &
                    CvSiOut       = Value_V(Cv_   +iMaterial*nThermo)
               if(present(GammaOut)) &
                    GammaOut      = Value_V(Gamma_+iMaterial*nThermo)
               if(present(HeatCondSiOut)) &
                    HeatCondSiOut = Value_V(Cond_ +iMaterial*nThermo)
               TeSi               = Value_V(Te_   +iMaterial*nThermo)
            end if

         elseif(TeSi < 0.0) then
            ! If TeSi is not set yet then we need to calculate things here
            if(IsMix) then
               call eos(RhoToARatioSi_I, pTotalIn=pSi, &
                    TeOut=TeSi, eTotalOut = EinternalSiOut, &
                    CvTotalOut=CvSiOut, GammaOut=GammaOut, &
                    HeatCond=HeatCondSiOut)
            else
               call eos(iMaterial, RhoSi, pTotalIn=pSi, &
                    TeOut=TeSi, eTotalOut = EinternalSiOut, &
                    CvTotalOut=CvSiOut, GammaOut=GammaOut, &
                    HeatCond=HeatCondSiOut)
            end if
         end if
      end if

    end subroutine get_thermo

    !========================================================================

    subroutine get_electron_thermo

      real :: PeSi, EeSi
      !----------------------------------------------------------------------

      ! get the atomic concentration
      if(present(NatomicSiOut))then
         if(IsMix)then
            NatomicSiOut = sum(RhoToARatioSi_I)/cAtomicMass
         else
            NatomicSiOut = RhoSi/(cAtomicMass*MassMaterial_I(iMaterial))
         end if
      end if

      ! Obtain the pressure from EinternalSiIn or TeSiIn or State_V
      ! Do this for mixed cell or not
      if(present(EinternalSiIn))then
         ! Obtain electron pressure from the true electron internal energy
         EeSi = EinternalSiIn
         if(IsMix)then
            call eos(RhoToARatioSi_I, eElectronIn=EeSi, &
                 pElectronOut=PeSi, TeOut=TeSi, CvElectronOut=CvSiOut, &
                 HeatCond=HeatCondSiOut, TeTiRelax=TeTiRelaxSiOut)
         else
            call eos(iMaterial, Rho=RhoSi, eElectronIn=EeSi, &
                 pElectronOut=PeSi, TeOut=TeSi, CvElectronOut=CvSiOut, &
                 HeatCond=HeatCondSiOut, TeTiRelax=TeTiRelaxSiOut)
         end if
      elseif(present(TeSiIn))then
         ! Calculate electron pressure from electron temperature
         TeSi = TeSiIn
         if(IsMix) then
            call eos(RhoToARatioSi_I, TeIn=TeSiIn, &
                 eElectronOut=EinternalSiOut, &
                 pElectronOut=PeSi, CvElectronOut=CvSiOut, &
                 HeatCond=HeatCondSiOut, TeTiRelax=TeTiRelaxSiOut)
         else
            call eos(iMaterial, Rho=RhoSi, TeIn=TeSiIn, &
                 eElectronOut=EinternalSiOut, &
                 pElectronOut=PeSi, CvElectronOut=CvSiOut, &
                 HeatCond=HeatCondSiOut, TeTiRelax=TeTiRelaxSiOut)
         end if
      else
         ! electron pressure is (g - 1)*State_V(Ee_)
         ! Use this pressure to calculate the true electron internal energy
         PeSi = (g - 1)*State_V(Ee_)*No2Si_V(UnitP_)
         if(present(EinternalSiOut))then
            if(IsMix)then
               call eos(RhoToARatioSi_I, pElectronIn=PeSi, &
                    TeOut=TeSi, eElectronOut=EinternalSiOut, &
                    CvElectronOut=CvSiOut, HeatCond=HeatCondSiOut, &
                    TeTiRelax=TeTiRelaxSiOut)
            else
               call eos(iMaterial, RhoSi, pElectronIn=PeSi, &
                    TeOut=TeSi, eElectronOut=EinternalSiOut, &
                    CvElectronOut=CvSiOut, HeatCond=HeatCondSiOut, &
                    TeTiRelax=TeTiRelaxSiOut)
            end if
         end if
      end if

      if(present(PressureSiOut)) PressureSiOut = PeSi

      if(present(TeSiOut) .or. present(CvSiOut) .or. &
           present(HeatCondSiOut) .or. present(TeTiRelaxSiOut) .or. &
           present(AbsorptionOpacitySiOut_W) .or. &
           present(DiffusionOpacitySiOut_W) .or. &
           present(PlanckSiOut_W) .or. present(CgTeSiOut_W))then

         if(TeSi < 0.0) then
            ! If TeSi is not set yet then we need to calculate things here
            if(IsMix) then
               call eos(RhoToARatioSi_I, pElectronIn=PeSi, &
                    TeOut=TeSi, CvElectronOut=CvSiOut, &
                    HeatCond=HeatCondSiOut, TeTiRelax=TeTiRelaxSiOut)
            else
               call eos(iMaterial, RhoSi, pElectronIn=PeSi, &
                    TeOut=TeSi, CvElectronOut=CvSiOut, &
                    HeatCond=HeatCondSiOut, TeTiRelax=TeTiRelaxSiOut)
            end if
         end if
      end if

    end subroutine get_electron_thermo

  end subroutine user_material_properties

  !===========================================================================
  subroutine user_amr_criteria(iBlock, UserCriteria, TypeCriteria, IsFound)

    use ModSize,     ONLY: nI, nJ, nK
    use ModAdvance,  ONLY: State_VGB, LevelBe_, LevelXe_, LevelPl_, Rho_
    use ModAMR,      ONLY: RefineCritMin_I, CoarsenCritMax
    use ModPhysics,  ONLY: Io2No_V, UnitRho_

    ! Variables required by this user subroutine
    integer, intent(in)          :: iBlock
    real, intent(out)            :: UserCriteria
    character (len=*),intent(in) :: TypeCriteria
    logical ,intent(inout)       :: IsFound

    real, parameter:: RhoMinAmrDim = 20.0

    real :: RhoMin
    integer:: i, j, k
    !------------------------------------------------------------------

    ! Location of sound wave edges and the tangential discontinuity

    RhoMin = RhoMinAmrDim*Io2No_V(UnitRho_)

    UserCriteria = 0.0
    LOOPCELL: do k = 1, nK; do j=1, nJ; do i = -1, nI+2
       if(State_VGB(LevelXe_,i,j,k,iBlock) > &
            maxval(State_VGB(LevelBe_:LevelPl_,i,j,k,iBlock)) &
            .and. State_VGB(Rho_,i,j,k,iBlock) > RhoMin)then
          UserCriteria = 1.0
          EXIT LOOPCELL
       end if
    end do; end do; end do LOOPCELL

    ! Do not refine blocks far from discontinuity (crit=0.0)
    ! Do not coarsen blocks near discontinuity    (crit=1.0)
    RefineCritMin_I = 0.5
    CoarsenCritMax  = 0.5

    IsFound = .true.

  end subroutine user_amr_criteria

  !===========================================================================

  subroutine set_nozzle_yz(x,y,z)
    real, intent(in):: x
    real, intent(inout):: y, z

    ! Set the Y,Z coordinates for the nozzle geometry.
    ! The Y and Z coordinates are divided by a factor
    !
    ! 1 (for x <= xStartNozzle)  and 
    ! yRatioNozzle or zRatioNozzle (for x >= xEndNozzle), respectively.
    !
    ! The factor is linearly varying in the [xStartNozzle,xEndNozzle] interval.

    real :: Factor
    !-------------------------------------------------------------------------
    Factor = max(0.0, min(1.0, &
         (x - xStartNozzle)/(xEndNozzle - xStartNozzle)))
    y = y/(1 + Factor*(yRatioNozzle-1))
    z = z/(1 + Factor*(zRatioNozzle-1))

  end subroutine set_nozzle_yz

end module ModUser
