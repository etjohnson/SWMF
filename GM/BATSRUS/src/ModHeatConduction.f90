!^CFG COPYRIGHT UM
!==============================================================================
module ModHeatConduction

  implicit none
  save

  private ! except

  ! Public methods
  public :: read_heatconduction_param
  public :: init_heat_conduction
  public :: get_heat_flux
  public :: add_jacobian_heat_conduction

  ! Logical for adding parallel heat conduction
  Logical, public :: UseParallelConduction = .false.
  logical, public :: IsNewBlockHeatConduction = .true.

  ! Variables for setting the parallel heat conduction coefficient
  character(len=20), public :: TypeHeatConduction = 'test'
  logical :: DoModifyHeatConduction, DoTestHeatConduction
  real :: HeatConductionParSi = 1.23e-11
  real :: TmodifySi = 2.5e5, DeltaTmodifySi = 2.0e4
  real :: HeatConductionPar, Tmodify, DeltaTmodify

  ! electron temperature used for calculating field parallel heat flux
  real, allocatable :: Te_G(:,:,:)

contains

  !============================================================================

  subroutine read_heatconduction_param(NameCommand)

    use ModReadParam, ONLY: read_var

    character(len=*), intent(in) :: NameCommand

    character(len=*), parameter :: NameSub = 'read_heatconduction_param'
    !--------------------------------------------------------------------------

    select case(NameCommand)
    case("#PARALLELCONDUCTION")
       call read_var('UseParallelConduction', UseParallelConduction)
       if(UseParallelConduction)then
          call read_var('TypeHeatConduction', TypeHeatConduction)
          call read_var('HeatConductionParSi', HeatConductionParSi)

          select case(TypeHeatConduction)
          case('test','spitzer')
          case('modified')
             call read_var('TmodifySi', TmodifySi)
             call read_var('DeltaTmodifySi', DeltaTmodifySi)
          case default
             call stop_mpi(NameSub//': unknown TypeHeatConduction = ' &
                  //TypeHeatConduction)
          end select
       end if
    case default
       call stop_mpi(NameSub//' invalid NameCommand='//NameCommand)
    end select

  end subroutine read_heatconduction_param

  !============================================================================

  subroutine init_heat_conduction

    use ModPhysics, ONLY: Si2No_V, UnitEnergyDens_, UnitTemperature_, &
         UnitU_, UnitX_
    use ModSize, ONLY: nI, nJ, nK

    character(len=*), parameter :: NameSub = 'init_heat_conduction'
    !--------------------------------------------------------------------------
    
    if(allocated(Te_G)) RETURN

    allocate(Te_G(-1:nI+2,-1:nJ+2,-1:nK+2))

    DoTestHeatConduction = .false.
    DoModifyHeatConduction = .false.

    if(TypeHeatConduction == 'test')then
       DoTestHeatConduction = .true.
    elseif(TypeHeatConduction == 'modified')then
       DoModifyHeatConduction = .true.
    end if

    HeatConductionPar = HeatConductionParSi &
         *Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_) &
         *Si2No_V(UnitU_)*Si2No_V(UnitX_)
    if(DoModifyHeatConduction)then
       Tmodify = TmodifySi*Si2No_V(UnitTemperature_)
       DeltaTmodify = DeltaTmodifySi*Si2No_V(UnitTemperature_)
    end if

  end subroutine init_heat_conduction

  !============================================================================

  subroutine get_heat_flux(iDir, i, j, k, iBlock, State_V, Normal_D, &
       HeatCondCoefNormal, HeatFlux_D)

    use ModAdvance,      ONLY: State_VGB
    use ModB0,           ONLY: B0_DX, B0_DY, B0_DZ
    use ModFaceGradient, ONLY: calc_face_gradient
    use ModMain,         ONLY: UseB0
    use ModNumConst,     ONLY: cTolerance
    use ModPhysics,      ONLY: inv_gm1, Si2No_V, UnitTemperature_, &
         UnitEnergyDens_
    use ModUser,         ONLY: user_material_properties
    use ModVarIndexes,   ONLY: nVar, Bx_, Bz_, Rho_, p_

    integer, intent(in) :: iDir, i, j, k, iBlock
    real,    intent(in) :: State_V(nVar), Normal_D(3)
    real,    intent(out):: HeatCondCoefNormal, HeatFlux_D(3)

    real :: B_D(3), Bunit_D(3), Bnorm, Cv, CvSi
    real :: FaceGrad_D(3), HeatCoef, TemperatureSi, Temperature, &
         FractionSpitzer

    character(len=*), parameter :: NameSub = 'get_heat_flux'
    !--------------------------------------------------------------------------

    if(UseB0)then
       select case(iDir)
       case(1)
          B_D = State_V(Bx_:Bz_) + B0_DX(:,i,j,k)
       case(2)
          B_D = State_V(Bx_:Bz_) + B0_DY(:,i,j,k)
       case(3)
          B_D = State_V(Bx_:Bz_) + B0_DZ(:,i,j,k)
       end select
    else
       B_D = State_V(Bx_:Bz_)
    end if

    ! The magnetic field should nowhere be zero. The following fix will
    ! turn the magnitude of the field direction to zero.
    Bnorm = max(sqrt(sum(B_D**2)),cTolerance)
    Bunit_D = B_D/Bnorm


    if(IsNewBlockHeatConduction) &
         !!!do k = -1, nK+2; do j = -1, nJ+2; do i = -1, nI+2
         !!!   call user_material_properties( &
         !!!      State_VGB(:,i,j,k,iBlock), TeSiOut=TemperatureSi)
         !!!   Te_G(i,j,k) = TemperatureSi*Si2No_V(UnitTemperature_)
         !!!end do; end do; end do

         Te_G = State_VGB(p_,:,:,:,iBlock)/State_VGB(Rho_,:,:,:,iBlock)

    call calc_face_gradient(iDir, i, j, k, iBlock, &
         Te_G, IsNewBlockHeatConduction, FaceGrad_D)


    !!! ! Note we assume that the heat conduction formulas for the
    !!! ! ideal state is still applicable for the mixed state
    !!! call user_material_properties( &
    !!!    State_V, TeSiOut=TemperatureSi, CvSiOut = CvSi)
    !!! Temperature = TemperatureSi*Si2No_V(UnitTemperature_)
    Temperature = State_V(p_)/State_V(Rho_)

    if(DoTestHeatConduction)then
       HeatCoef = 1.0
    else

       if(DoModifyHeatConduction)then
          ! Artificial modified heat conduction for a smoother transition
          ! region, Linker et al. (2001)
          FractionSpitzer = 0.5*(1.0+tanh((Temperature-Tmodify)/DeltaTmodify))
          HeatCoef = HeatConductionPar*(FractionSpitzer*Temperature**2.5 &
               + (1.0 - FractionSpitzer)*Tmodify**2.5)
       else
          ! Spitzer form for collisional regime
          HeatCoef = HeatConductionPar*Temperature**2.5
       end if
    end if

    HeatFlux_D = -HeatCoef*Bunit_D*dot_product(Bunit_D,FaceGrad_D)

    ! get the heat conduction coefficient normal to the face for
    ! time step restriction
    !!!Cv = CvSi*Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_)
    Cv = State_V(Rho_)*inv_gm1
    HeatCondCoefNormal = HeatCoef*dot_product(Bunit_D,Normal_D)**2/Cv

  end subroutine get_heat_flux

  !============================================================================

  subroutine add_jacobian_heat_conduction(iBlock, nVar, Jacobian_VVCI)

    use ModMain, ONLY: nI, nJ, nK, nDim

    integer, parameter :: nStencil = 2*nDim + 1

    integer, intent(in) :: iBlock, nVar
    real, intent(inout) :: Jacobian_VVCI(nVar,nVar,nI,nJ,nK,nStencil)
    !--------------------------------------------------------------------------


  end subroutine add_jacobian_heat_conduction

end module ModHeatConduction
