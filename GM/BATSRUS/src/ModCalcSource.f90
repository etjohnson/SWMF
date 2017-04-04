!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
!==============================================================================
module ModCalcSource

  implicit none
  save

  private !except

  ! Public methods
  public :: calc_source

contains

  !============================================================================

  subroutine calc_source(iBlock)

    use ModMain,          ONLY: ProcTest,iTest,jTest,kTest,BlkTest,VarTest,&
         UseB0,UseDivBsource,GravityDir,UseBody2,&
         TypeCoordSystem,Useraddiffusion,&
         DoThinCurrentSheet,UseUSerSource,test_string
    use ModAdvance
    use ModGeometry,      ONLY: R_BLK, R2_Blk, true_cell
    use ModPhysics
    use ModCoordTransform
    use ModImplicit,      ONLY: UseFullImplicit
    use ModRadDiffusion,  ONLY: calc_source_rad_diffusion
    use ModMultiFluid
    use ModPointImplicit, ONLY: UsePointImplicit, UsePointImplicit_B
    use ModMultiIon,      ONLY: multi_ion_source_expl, multi_ion_source_impl
    use ModIonElectron,   ONLY: ion_electron_source_impl
    use ModWaves,         ONLY: UseWavePressure, GammaWave, DivU_C
    use ModCoronalHeating,ONLY: UseCoronalHeating, get_block_heating, &
         CoronalHeating_C, UseAlfvenWaveDissipation, WaveDissipation_VC, &
         apportion_coronal_heating, UseTurbulentCascade, get_wave_reflection
    use ModRadiativeCooling, ONLY: RadCooling_C,UseRadCooling, &
         get_radiative_cooling, add_chromosphere_heating
    use ModChromosphere,  ONLY: DoExtendTransitionRegion, extension_factor, &
         UseChromosphereHeating, get_tesi_c, TeSi_C
    use ModFaceFlux,      ONLY: Pe_G
    use ModHallResist,    ONLY: UseBiermannBattery, IonMassPerCharge_G
    use ModB0,            ONLY: set_b0_source, UseB0Source, UseCurlB0, &
         rCurrentFreeB0, DivB0_C, CurlB0_DC, B0_DGB, B0_DX, B0_DY, B0_DZ
    use BATL_lib,         ONLY: IsCartesian, IsRzGeometry, &
         Xyz_DGB, CellSize_DB, CellVolume_GB, x_, y_, z_, Dim1_, Dim2_, Dim3_
    use ModViscosity,     ONLY: &
         UseViscosity, set_visco_factor_cell, ViscoFactor_C
    use ModUserInterface ! user_calc_sources

    integer, intent(in):: iBlock

    integer :: i, j, k, iVar
    real :: Pe, Pwave, DivU
    real :: Coef

    ! Variable for B0 source term

    real :: CurlB0CrossB_D(3)

    ! Variables needed for Boris source terms also used for div(u)
    real :: FullB_DC(MaxDim,nI,nJ,nK), RhoInv
    real :: E_D(MaxDim), DivE

    ! Variables needed for anisotropic pressure
    real :: b_D(MaxDim), GradU_DD(nDim,MaxDim), bDotGradparU

    ! Gravitational force towards body
    real :: ForcePerRho_D(3)

    ! Momentum index parallel with gravity direction
    integer:: iRhoUGrav

    ! For centrifugal force
    real :: Omega2

    ! Viscosity
    real, parameter:: cTwoThirds = 2.0/3.0
    real :: Visco, Tmp, ViscoCoeff

    ! Coronal Heating
    real :: QPerQtotal_I(IonFirst_:IonLast_)
    real :: QparPerQtotal_I(IonFirst_:IonLast_)
    real :: QePerQtotal

    ! Variables for multi-ion MHD
    real :: InvElectronDens, uPlus_D(3), U_D(3)
    real, dimension(nIonFluid) :: &
         NumDens_I, ChargeDens_I, Rho_I, InvRho_I, Ux_I, Uy_I, Uz_I

    logical :: DoTest, DoTestMe

    character(len=*), parameter :: NameSub = 'calc_source'
    !--------------------------------------------------------------------------

    if(iProc==PROCtest .and. iBlock==BLKtest)then
       call set_oktest(NameSub, DoTest, DoTestMe)
    else
       DoTest=.false.; DoTestMe=.false.
    end if

    Source_VC = 0.0

    ! Calculate source terms for ion pressure
    if(UseNonconservative .or. UseAnisoPressure)then
       do iFluid = 1, nFluid
          call select_fluid

          if((UseAnisoPressure .and. IsIon_I(iFluid)) &
               .or. (UseViscosity .and. nFluid == 1))then

             if(UseViscosity)call set_visco_factor_cell(iBlock)

             ! Source terms for anisotropic pressure equations
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE

                if(UseViscosity) then
                   ViscoCoeff = ViscoFactor_C(i,j,k)
                   if(.not. UseAnisoPressure .and. ViscoCoeff <= 0.0 ) CYCLE
                end if

                ! Calculate gradient tensor of velocity
                call calc_grad_U(GradU_DD, i, j, k, iBlock)

                if(UseAnisoPressure .and. IsIon_I(iFluid))then
                   ! Calculate bDotGradparU = b dot (b matmul GradU)

                   ! Calculate unit vector parallel with full B field
                   b_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
                   if(UseB0) b_D = b_D + B0_DGB(:,i,j,k,iBlock)
                   b_D = b_D/sqrt(max(1e-30, sum(b_D**2)))

                   ! Calculate b.grad u.b
                   bDotGradparU= dot_product(b_D, matmul(b_D(1:nDim),GradU_DD))

                   ! p parallel: -2*ppar*b.(b.(Grad U))
                   Source_VC(iPpar,i,j,k) = Source_VC(iPpar,i,j,k) &
                        - 2*State_VGB(iPpar,i,j,k,iBlock)*bDotGradparU

                   ! p : 2/3*(pperp - ppar)*b.(b.(GradU))
                   !     = (p - ppar)*b.(b.(GradU)) 
                   Source_VC(iP,i,j,k) = Source_VC(iP,i,j,k) &
                        + (State_VGB(iP,i,j,k,iBlock) -  &
                        State_VGB(iPpar,i,j,k,iBlock))*bDotGradparU
                end if

                if(UseViscosity) then

                   if(ViscoCoeff <= 0.0 ) CYCLE

                   ! Source(p) = (gamma - 1)*d_i u_j tau_ij
                   ! tau_ij = rho*nu*(d_i u_j + d_j u_i - 2/3 delta_ij div u)

                   ! Calculate first -2/3 (div u)^2
                   Visco              =         GradU_DD(Dim1_,1)
                   if(nDim > 1) Visco = Visco + GradU_DD(Dim2_,2) 
                   if(nDim > 2) Visco = Visco + GradU_DD(Dim3_,3)
                   Visco = -cTwoThirds*Visco**2

                   ! Add 2*Sum_i (d_i u_i)^2
                   Visco              = Visco + 2.0*GradU_DD(Dim1_,1)**2 
                   if(nDim > 1) Visco = Visco + 2.0*GradU_DD(Dim2_,2)**2
                   if(nDim > 2) Visco = Visco + 2.0*GradU_DD(Dim3_,3)**2

                   ! Add Sum_{i<j} (d_i u_j + d_j u_i)^2
                   Tmp              =       GradU_DD(Dim1_,2)
                   if(nDim > 1) Tmp = Tmp + GradU_DD(Dim2_,1)
                   Visco = Visco + Tmp**2

                   Tmp              =       GradU_DD(Dim1_,3)
                   if(nDim > 2) Tmp = Tmp + GradU_DD(Dim3_,1)
                   Visco = Visco + Tmp**2

                   if(nDim > 1)then
                      Tmp              =       GradU_DD(Dim2_,3)
                      if(nDim > 2) Tmp = Tmp + GradU_DD(Dim3_,2)
                      Visco = Visco + Tmp**2
                   end if

                   ! Source(p) = (gamma - 1)*tau:grad u
                   Source_VC(p_,i,j,k) = Source_VC(p_,i,j,k) + &
                        GammaMinus1*ViscoCoeff * &
                        State_VGB(Rho_,i,j,k,iBlock)*Visco
                end if
             end do; end do; end do

             if(DoTestMe .and. UseAnisoPressure .and. &
                  (VarTest == iPparIon_I(IonFirst_) .or. VarTest == p_)) &
                  call write_source('After bDotGradparU')

          end if

          ! Adiabatic heating: -(g-1)*P*Div(U)
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.true_cell(i,j,k,iBlock)) CYCLE

             DivU = uDotArea_XI(i+1,j,k,iFluid) - uDotArea_XI(i,j,k,iFluid)
             if(nJ > 1) DivU = DivU &
                  + uDotArea_YI(i,j+1,k,iFluid) - uDotArea_YI(i,j,k,iFluid)
             if(nK > 1) DivU = DivU &
                  + uDotArea_ZI(i,j,k+1,iFluid) - uDotArea_ZI(i,j,k,iFluid)
             DivU = DivU/CellVolume_GB(i,j,k,iBlock)
             if(UseAnisoPressure .and. IsIon_I(iFluid))then
                Source_VC(iP,i,j,k) = Source_VC(iP,i,j,k) &
                     - (State_VGB(iP,i,j,k,iBlock) &
                     - State_VGB(iPpar,i,j,k,iBlock)/3.0)*DivU
             else
                Source_VC(iP,i,j,k) = Source_VC(iP,i,j,k) &
                     - GammaMinus1_I(iFluid)*State_VGB(iP,i,j,k,iBlock)*DivU
             end if
          end do; end do; end do

          if(DoTestMe .and. VarTest==iP)call write_source('After p div U')

       end do
    end if

    if(UseWavePressure)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          if(UseMultiIon)then
             ! The following should be Div(Uplus). For zero Hall velocity
             ! this is the same as Div(Ue).
             DivU = uDotArea_XI(i+1,j,k,eFluid_) - uDotArea_XI(i,j,k,eFluid_)
             if(nJ > 1) DivU = DivU &
                  + uDotArea_YI(i,j+1,k,eFluid_) - uDotArea_YI(i,j,k,eFluid_)
             if(nK > 1) DivU = DivU &
                  + uDotArea_ZI(i,j,k+1,eFluid_) - uDotArea_ZI(i,j,k,eFluid_)
          else
             DivU = uDotArea_XI(i+1,j,k,1) - uDotArea_XI(i,j,k,1)
             if(nJ > 1) DivU = DivU &
                  + uDotArea_YI(i,j+1,k,1) - uDotArea_YI(i,j,k,1)
             if(nK > 1) DivU = DivU &
                  + uDotArea_ZI(i,j,k+1,1) - uDotArea_ZI(i,j,k,1)
          end if
          DivU = DivU/CellVolume_GB(i,j,k,iBlock)

          ! Store div U so it can be used in ModWaves
          DivU_C(i,j,k) = DivU

          do iVar = WaveFirst_, WaveLast_
             Source_VC(iVar,i,j,k) = Source_VC(iVar,i,j,k) &
                  - DivU*(GammaWave - 1)*State_VGB(iVar,i,j,k,iBlock)
          end do

          if(.not.UseMultiIon)then
             Pwave = (GammaWave - 1) &
                  *sum(State_VGB(WaveFirst_:WaveLast_,i,j,k,iBlock))

             ! The energy equation contains the work of the wave pressure
             ! -u.grad Pwave = -div(u Pwave) + Pwave div(u)
             ! The -div(u Pwave) is implemented as a flux in ModFaceFlux.
             ! Here we add the Pwave div(u) source term
             Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) + DivU*Pwave

             ! Add "geometrical source term" p/r to the radial momentum
             ! equation. The "radial" direction is along the Y axis
             ! NOTE: here we have to use signed radial distance!
             if(IsRzGeometry) Source_VC(RhoUy_,i,j,k) = &
                  Source_VC(RhoUy_,i,j,k) + Pwave/Xyz_DGB(Dim2_,i,j,k,iBlock)
          end if
       end do; end do; end do
    end if

    if(UseTurbulentCascade) call get_wave_reflection(iBlock)

    if(UseCoronalHeating .and. DoExtendTransitionRegion .or. UseRadCooling) &
         call get_tesi_c(iBlock, TeSi_C)

    if(UseCoronalHeating)then
       call get_block_heating(iBlock)

       if(UseChromosphereHeating.and. DoExtendTransitionRegion)then
          call add_chromosphere_heating(TeSi_C, iBlock)
          do k=1,nK; do j=1,nJ; do i=1,nI
             CoronalHeating_C(i,j,k) = &
                  CoronalHeating_C(i,j,k)/extension_factor(TeSi_C(i,j,k))
          end do; end do; end do
       end if

       if(UseAlfvenWaveDissipation)then
          if(DoExtendTransitionRegion)then
             ! Does not work together with UseChromosphereHeating
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                Coef = extension_factor(TeSi_C(i,j,k))
                WaveDissipation_VC(:,i,j,k) = WaveDissipation_VC(:,i,j,k)/Coef
                CoronalHeating_C(i,j,k) = CoronalHeating_C(i,j,k)/Coef
             end do; end do; end do
          end if

          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             Source_VC(WaveFirst_:WaveLast_,i,j,k) = &
                  Source_VC(WaveFirst_:WaveLast_,i,j,k) &
                  - WaveDissipation_VC(:,i,j,k)
          end do; end do; end do
       end if

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(UseElectronPressure)then
             call apportion_coronal_heating(i, j, k, iBlock, &
                  CoronalHeating_C(i,j,k), QPerQtotal_I, QparPerQtotal_I, &
                  QePerQtotal)

             Source_VC(Pe_,i,j,k) = Source_VC(Pe_,i,j,k) &
                  + CoronalHeating_C(i,j,k)*GammaElectronMinus1*QePerQtotal

             Source_VC(iPIon_I,i,j,k) = Source_VC(iPIon_I,i,j,k) &
                  + CoronalHeating_C(i,j,k)*QPerQtotal_I &
                  *GammaMinus1_I(IonFirst_:IonLast_)
             Source_VC(Energy_-1+IonFirst_:Energy_-1+IonLast_,i,j,k) = &
                  Source_VC(Energy_-1+IonFirst_:Energy_-1+IonLast_,i,j,k) &
                  + CoronalHeating_C(i,j,k)*QPerQtotal_I

             if(UseAnisoPressure)then
                do iFluid = IonFirst_, IonLast_
                   Source_VC(iPparIon_I(iFluid),i,j,k) = &
                        Source_VC(iPparIon_I(iFluid),i,j,k) &
                        + CoronalHeating_C(i,j,k)*QparPerQtotal_I(iFluid)*2.0
                end do
             end if
          else
             Source_VC(p_,i,j,k) = Source_VC(p_,i,j,k) &
                  + CoronalHeating_C(i,j,k)*GammaMinus1
             Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) &
                  + CoronalHeating_C(i,j,k)
          end if
       end do; end do; end do

    end if

    if(UseRadCooling)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          call get_radiative_cooling(i, j, k, iBlock, TeSi_C(i,j,k), &
               RadCooling_C(i,j,k))

          if(UseElectronPressure)then
             Source_VC(Pe_,i,j,k) = Source_VC(Pe_,i,j,k) &
                  + RadCooling_C(i,j,k)*GammaElectronMinus1
          else
             Source_VC(p_,i,j,k)  = Source_VC(p_,i,j,k) &
                  + RadCooling_C(i,j,k)*GammaMinus1
             Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) &
                  + RadCooling_C(i,j,k)
          end if
       end do; end do; end do
    end if

    if(UseElectronPressure .and. &
         .not.(UseElectronEntropy .and. UseMultiIon))then
       ! Calculate DivU = div(U_e)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          DivU = uDotArea_XI(i+1,j,k,eFluid_) - uDotArea_XI(i,j,k,eFluid_)
          if(nJ > 1) DivU = DivU &
               + uDotArea_YI(i,j+1,k,eFluid_) - uDotArea_YI(i,j,k,eFluid_)
          if(nK > 1) DivU = DivU &
               + uDotArea_ZI(i,j,k+1,eFluid_) - uDotArea_ZI(i,j,k,eFluid_)
          DivU = DivU/CellVolume_GB(i,j,k,iBlock)

          Pe = State_VGB(Pe_,i,j,k,iBlock)

          ! Adiabatic heating for electron pressure: -(g-1)*Pe*Div(U)
          ! For electron entropy equation there is no such term
          if(.not.UseElectronEntropy) Source_VC(Pe_,i,j,k) = &
               Source_VC(Pe_,i,j,k) - GammaElectronMinus1*Pe*DivU

          if(.not.UseMultiIon)then
             ! The energy equation contains the work of the electron pressure
             ! -u.grad Pe = -div(u Pe) + Pe div(u)
             ! The -div(u Pe) is implemented as a flux in ModFaceFlux.
             ! Here we add the Pe div(u_e) source term
             Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) + Pe*DivU

             ! Add "geometrical source term" p/r to the radial momentum
             ! equation. The "radial" direction is along the Y axis
             ! NOTE: here we have to use signed radial distance!
             if(IsRzGeometry) Source_VC(RhoUy_,i,j,k) = &
                  Source_VC(RhoUy_,i,j,k) + Pe/Xyz_DGB(y_,i,j,k,iBlock)
          end if
       end do; end do; end do
       if(DoTestMe.and.VarTest==Pe_)call write_source('After Pe div Ue')
    end if

    if(IsRzGeometry)then
       ! The following geometrical source terms are added for the MHD equations
       ! Source[mr]  =(p+B^2/2-Bphi**2+mphi**2/rho)/radius
       ! Source[mphi]=(-mphi*mr/rho+Bphi*Br)/radius(if no angular momentum fix)
       ! Source[Bphi]=((Bphi*mr-Br*mphi)/rho)/radius

       ! The cylindrical coordinates are renamed to X,Y,Z
       ! The cylindrical axis is along X
       ! The "radial" direction is along the Y axis
       ! The azimuthal direction is along the Z axis

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          ! Source[mr] = (p+mphi**2/rho)/radius
          Source_VC(iRhoUy_I,i,j,k) = Source_VC(iRhoUy_I,i,j,k) &
               + (State_VGB(iP_I,i,j,k,iBlock) &
               +  State_VGB(iRhoUz_I,i,j,k,iBlock)**2 &
               /  State_VGB(iRho_I,i,j,k,iBlock)) &
               / Xyz_DGB(y_,i,j,k,iBlock)

          ! Source[mphi] = (-mphi*mr/rho)/radius
          Source_VC(iRhoUz_I,i,j,k) = Source_VC(iRhoUz_I,i,j,k) &
               - State_VGB(iRhoUz_I,i,j,k,iBlock) &
               * State_VGB(iRhoUy_I,i,j,k,iBlock) &
               /(State_VGB(iRho_I,i,j,k,iBlock)*Xyz_DGB(y_,i,j,k,iBlock))

          if(UseB)then
             ! Source[mr] = (B^2/2-Bphi**2)/radius
             Source_VC(RhoUy_,i,j,k) = Source_VC(RhoUy_,i,j,k) &
                  + (0.5*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)**2) &
                  -  State_VGB(Bz_,i,j,k,iBlock)**2) / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[mphi]=Bphi*Br/radius
             Source_VC(RhoUz_,i,j,k) = Source_VC(RhoUz_,i,j,k) &
                  + State_VGB(Bz_,i,j,k,iBlock)*State_VGB(By_,i,j,k,iBlock) &
                  / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[Bphi]=((Bphi*mr-Br*mphi)/rho)/radius
             Source_VC(Bz_,i,j,k) = Source_VC(Bz_,i,j,k) &
                  + (State_VGB(Bz_,i,j,k,iBlock) &
                  *   State_VGB(RhoUy_,i,j,k,iBlock) &
                  -  State_VGB(By_,i,j,k,iBlock) &
                  *   State_VGB(RhoUz_,i,j,k,iBlock))&
                  /State_VGB(Rho_,i,j,k,iBlock)/Xyz_DGB(y_,i,j,k,iBlock)
          end if
          if(UseB .and. UseB0)then
             ! Source[mr] = (B0.B1 - 2 B0phi * Bphi)/radius
             Source_VC(RhoUy_,i,j,k) = Source_VC(RhoUy_,i,j,k) &
                  + (sum(State_VGB(Bx_:Bz_,i,j,k,iBlock) &
                  *      B0_DGB(:,i,j,k,iBlock)) &
                  - 2.0*State_VGB(Bz_,i,j,k,iBlock)*B0_DGB(z_,i,j,k,iBlock)) &
                  / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[mphi] = (B0phi * Br + Bphi * B0r)/radius
             Source_VC(RhoUz_,i,j,k) = Source_VC(RhoUz_,i,j,k) &
                  + (B0_DGB(z_,i,j,k,iBlock)*State_VGB(By_,i,j,k,iBlock) &
                  +  B0_DGB(y_,i,j,k,iBlock)*State_VGB(Bz_,i,j,k,iBlock)) &
                  / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[Bphi]=((B0phi * mr - B0r * mphi)/rho)/radius
             Source_VC(Bz_,i,j,k) = Source_VC(Bz_,i,j,k) &
                  + (B0_DGB(z_,i,j,k,iBlock)*State_VGB(RhoUy_,i,j,k,iBlock) &
                  -  B0_DGB(y_,i,j,k,iBlock)*State_VGB(RhoUz_,i,j,k,iBlock))&
                  /State_VGB(Rho_,i,j,k,iBlock)/Xyz_DGB(y_,i,j,k,iBlock)
          end if
       end do; end do; end do

       ! For now, no Hall MHD implementation for rz-geometry
       if(UseB .and. UseBiermannBattery .and. &
            (UseElectronPressure .or. ElectronPressureRatio > 0.0 .or. &
            .not.UseIdealEos))then

          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.true_cell(i,j,k,iBlock)) CYCLE

             ! Source[Bphi] = [ 1/(q_e*n_e) * (dP_e/dZ) ] / radius
             Source_VC(Bz_,i,j,k) = Source_VC(Bz_,i,j,k) &
                  + IonMassPerCharge_G(i,j,k)/State_VGB(Rho_,i,j,k,iBlock) &
                  /Xyz_DGB(y_,i,j,k,iBlock) &
                  *0.5*(Pe_G(i+1,j,k) - Pe_G(i-1,j,k))/CellSize_DB(x_,iBlock)
          end do; end do; end do
       end if
    end if

    ! We consider two cases: curl(B0) is zero analytically or non-zero
    ! These are distinguished by UseCurlB0 being true or false.
    !
    ! Momentum equation has the Lorentz force J x B
    !     = (curl B1) x (B1 + B0)     if curl B0 = 0
    !     = (curl B1+B0) x (B1 + B0)  if curl B0 is not 0
    !
    ! Conservative fluxes add the divergence of the Maxwell tensor
    !     div(B1^2 + B1.B0 - B1 B1 - B1 B0 - B0 B1)
    ! 
    ! Deviations between these two are
    !   -B1 div(B1)       - usual div B source
    !   -B1 div(B0)       - div(B0) source
    !   -curl(B0) x B1    - remove this if curl B0 = 0
    !   +curl(B0) x B0    - add this if curl B0 is not 0

    if(UseB0) call set_b0_source(iBlock)

    if(UseB .and. UseDivbSource)then
       if(IsCartesian)then
          call calc_divb_source
       else
          call calc_divb_source_gencoord
       end if

       if(DoTestMe)write(*,*)'divb=',DivB1_GB(iTest,jTest,kTest,BlkTest)
       if(DoTestMe.and.VarTest>=RhoUx_.and.VarTest<=RhoUz_)&
            call write_source('After B0B1 source')

       ! Add contributions to other source terms
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          RhoInv = 1.0/State_VGB(Rho_,i,j,k,iBlock)
          if(UseMultiIon)then
             ChargeDens_I = ChargeIon_I*State_VGB(iRhoIon_I,i,j,k,iBlock) &
                  /MassIon_I
             InvElectronDens = 1.0/sum(ChargeDens_I)
             Rho_I    = State_VGB(iRhoIon_I,i,j,k,iBlock)
             InvRho_I = 1.0/Rho_I
             Ux_I = InvRho_I*State_VGB(iUxIon_I,i,j,k,iBlock)
             Uy_I = InvRho_I*State_VGB(iUyIon_I,i,j,k,iBlock)
             Uz_I = InvRho_I*State_VGB(iUzIon_I,i,j,k,iBlock)
             uPlus_D(x_) = InvElectronDens*sum(ChargeDens_I*Ux_I)
             uPlus_D(y_) = InvElectronDens*sum(ChargeDens_I*Uy_I)
             uPlus_D(z_) = InvElectronDens*sum(ChargeDens_I*Uz_I)
             U_D = 0.5*(uPlus_D + RhoInv*State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock))

             Source_VC(Bx_:Bz_,i,j,k) = Source_VC(Bx_:Bz_,i,j,k) &
                  -DivB1_GB(i,j,k,iBlock)*uPlus_D
          else
             U_D = RhoInv*State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock)

             Source_VC(Bx_:Bz_,i,j,k) = Source_VC(Bx_:Bz_,i,j,k) &
                  -DivB1_GB(i,j,k,iBlock)*U_D
          end if

          if(.not. IsMhd) CYCLE

          ! -B1 div(B1)       - usual div B source

          Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
               -DivB1_GB(i,j,k,iBlock)*State_VGB(Bx_:Bz_,i,j,k,iBlock)

          Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) &
               -DivB1_GB(i,j,k,iBlock)*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)*U_D)
       end do; end do; end do

       if(DoTestMe)call write_source('After divb source')

       if(UseB0Source .and. IsMhd)then

          !   -B1 div(B0)     - div(B0) source
          ! -curl(B0) x B1    - remove this term (in case curl B0 should be 0) 
          !                     have to undo this if curl B0 is actually not 0

          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.true_cell(i,j,k,iBlock)) CYCLE
             Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(rhoUx_:rhoUz_,i,j,k) &
                  - State_VGB(Bx_:Bz_,i,j,k,iBlock)*DivB0_C(i,j,k) &
                  - cross_product( &
                  CurlB0_DC(:,i,j,k), State_VGB(Bx_:Bz_,i,j,k,iBlock))
          end do; end do; end do

          if(DoTestMe.and.VarTest>=RhoUx_.and.VarTest<=RhoUz_)then 
             write(*,*)'DivB0_C  =',DivB0_C(iTest,jTest,kTest)
             write(*,*)'CurlB0_DC=',CurlB0_DC(:,iTest,jTest,kTest)
             call write_source('After B0 source')
          end if
       end if
    else
       if(UseB)call calc_divb(iBlock)
    end if

    if(UseB .and. UseCurlB0 .and. IsMhd)then

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          if(R_BLK(i,j,k,iBlock) < rCurrentFreeB0)CYCLE

          ! +curl(B0) x B1    - undo source term above
          ! +curl(B0) x B0    - add this since curl B0 is not 0
          CurlB0CrossB_D = cross_product( CurlB0_DC(:,i,j,k),&
               State_VGB(Bx_:Bz_,i,j,k,iBlock) + B0_DGB(:,i,j,k,iBlock))
          Source_VC(rhoUx_:rhoUz_,i,j,k) = Source_VC(rhoUx_:rhoUz_,i,j,k) &
               + CurlB0CrossB_D
          ! Energy equation source term is u.(curl(B0)xB)
          Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) &
               + sum(CurlB0CrossB_D*State_VGB(rhoUx_:rhoUz_,i,j,k,iBlock))&
               /State_VGB(rho_,i,j,k,iBlock)
       end do; end do; end do

       if(DoTestMe .and. &
            (VarTest==Energy_.or.VarTest>=RhoUx_.and.VarTest<=RhoUz_))&
            call write_source('After curl B0')
    end if

    if(UseB .and. boris_correction &
         .and. boris_cLIGHT_factor < 0.9999 & 
         .and. index(test_string,'nodivE')<1) then

       Coef = (boris_cLIGHT_factor**2 - 1.0)*inv_c2LIGHT
       FullB_DC = State_VGB(Bx_:Bz_,1:nI,1:nJ,1:nK,iBlock)
       if(UseB0)FullB_DC = FullB_DC + B0_DGB(:,1:nI,1:nJ,1:nK,iBlock) 
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          E_D = cross_product(FullB_DC(:,i,j,k),&
               State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock))/&
               State_VGB(Rho_,i,j,k,iBlock)

          ! Calculate divergence of electric field 
          DivE =                     EDotFA_X(i+1,j,k) - EDotFA_X(i,j,k) 
          if(nDim > 1) DivE = DivE + EDotFA_Y(i,j+1,k) - EDotFA_Y(i,j,k)
          if(nDim > 2) DivE = DivE + EDotFA_Z(i,j,k+1) - EDotFA_Z(i,j,k)
          DivE = DivE/CellVolume_GB(i,j,k,iBlock)

          Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
               + Coef*DivE*E_D 

          if(DoTestMe.and.VarTest>=RhoUx_.and.VarTest<=RhoUz_) &
               call write_source('After E div E')

       end do; end do; end do
    end if

    ! These source terms apply to all the fluids
    do iFluid = 1, nFluid
       call select_fluid
       if(UseGravity)then
          ! Add gravitational force
          if(GravityDir == 0)then
             ! Force is toward the body at the origin
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE
                ForcePerRho_D = &
                     Gbody*Xyz_DGB(:,i,j,k,iBlock)/r_BLK(i,j,k,iBlock)**3
                Source_VC(iRhoUx:iRhoUz,i,j,k) =Source_VC(iRhoUx:iRhoUz,i,j,k)&
                     + State_VGB(iRho,i,j,k,iBlock)*ForcePerRho_D
                Source_VC(iEnergy,i,j,k) = Source_VC(iEnergy,i,j,k) + &
                     sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)*ForcePerRho_D)
             end do; end do; end do

             if(UseBody2)then
                do k = 1, nK; do j = 1, nJ; do i = 1, nI
                   if(.not.true_cell(i,j,k,iBlock)) CYCLE
                   ForcePerRho_D = Gbody2 &
                        * (Xyz_DGB(:,i,j,k,iBlock)-(/xBody2,yBody2,zBody2/)) &
                        / r2_BLK(i,j,k,iBlock)**3
                   Source_VC(iRhoUx:iRhoUz,i,j,k) = &
                        Source_VC(iRhoUx:iRhoUz,i,j,k) &
                        + State_VGB(iRho,i,j,k,iBlock)*ForcePerRho_D
                   Source_VC(iEnergy,i,j,k) = Source_VC(iEnergy,i,j,k) + &
                        sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock) &
                        *   ForcePerRho_D)
                end do; end do; end do
             end if
          else
             iRhoUGrav = iRhoUx - 1 + GravityDir
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE
                Source_VC(iRhoUGrav,i,j,k) = Source_VC(iRhoUGrav,i,j,k) &
                     + Gbody*State_VGB(iRho,i,j,k,iBlock)
                Source_VC(iEnergy,i,j,k) = Source_VC(iEnergy,i,j,k) &
                     + Gbody*State_VGB(iRhoUGrav,i,j,k,iBlock)
             end do; end do; end do
          end if
          if(DoTestMe.and. &
               (VarTest==Energy_ .or. VarTest>=iRhoUx.and.VarTest<=iRhoUz))then
             call write_source('After gravity')
          end if
       end if

       ! Add Coriolis forces
       if(UseRotatingFrame)then
          ! Add centrifugal and Coriolis forces
          select case(TypeCoordSystem)
          case('HGC','HGR','GEO')
             ! This is a special case since Omega is parallel with the Z axis
             Omega2 = OmegaBody**2
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE
                Source_VC(iRhoUx,i,j,k) = Source_VC(iRhoUx,i,j,k) &
                     + 2*OmegaBody*State_VGB(iRhoUy,i,j,k,iBlock) &
                     + State_VGB(iRho,i,j,k,iBlock) &
                     *Omega2 * Xyz_DGB(x_,i,j,k,iBlock)

                Source_VC(iRhoUy,i,j,k) = Source_VC(iRhoUy,i,j,k) &
                     - 2*OmegaBody*State_VGB(iRhoUx,i,j,k,iBlock) &
                     + State_VGB(iRho,i,j,k,iBlock) &
                     *Omega2 * Xyz_DGB(y_,i,j,k,iBlock)

                Source_VC(iEnergy,i,j,k) = Source_VC(iEnergy,i,j,k) &
                     + Omega2 * sum(State_VGB(iRhoUx:iRhoUy,i,j,k,iBlock) &
                     *                         Xyz_DGB(x_:y_,i,j,k,iBlock))
             end do; end do; end do
          case default
             call stop_mpi(NameSub // &
                  ' Inertial forces are not implemented for'// &
                  ' TypeCoordSystem='//TypeCoordSystem)
          end select
          if(DoTestMe.and.VarTest>=iRhoUx .and. VarTest<=iRhoUy) &
               call write_source('After Coriolis')
       end if
    end do

    if(UseMultiIon)then
       ! Add momentum source terms containing the gradient of electron pressure
       call multi_ion_source_expl(iBlock)

       if(DoTestMe) call write_source('After MultiIon sources explicit')

       ! Add stiff momentum source terms (uPlus - Uion) and artificial friction
       ! Explicit evaluation of these source terms is for code development only
       if (.not. (UsePointImplicit .and. UsePointImplicit_B(iBlock)) ) then
          call multi_ion_source_impl(iBlock)
          if(DoTestMe) call write_source('After MultiIon sources implicit')
       end if
    end if

    if(UseEfield)then
       ! Add total charge density source term for HypE scalar
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          Source_VC(HypE_,i,j,k) = C2light**2 * &
               sum(State_VGB(iRhoIon_I,i,j,k,iBlock)*ChargePerMass_I)
       end do; end do; end do

    end if

    if(UseEfield .and. .not.UsePointImplicit)then
       ! Explicit evaluation of these source terms is for code development only
       call ion_electron_source_impl(iBlock)
       if(DoTestMe) call write_source('After IonElectron sources implicit')
    end if

    if(UseB .and. .not.IsMhd .and. .not.(UseMultiIon .or. UseEfield))then
       ! Add JxB term for nonconservative MHD scheme (like LFM)
       call multi_ion_source_expl(iBlock)

       if(DoTestMe) call write_source('After JxB term')
    end if

    if(UseRadDiffusion .and. UseFullImplicit) &
         call calc_source_rad_diffusion(iBlock)


    if(SignB_>1 .and. DoThinCurrentSheet)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          ! Note that the velocity of the first (and only) fluid is used
          DivU            =        uDotArea_XI(i+1,j,k,1) -uDotArea_XI(i,j,k,1)
          if(nJ > 1) DivU = DivU + uDotArea_YI(i,j+1,k,1) -uDotArea_YI(i,j,k,1)
          if(nK > 1) DivU = DivU + uDotArea_ZI(i,j,k+1,1) -uDotArea_ZI(i,j,k,1)
          DivU = DivU/CellVolume_GB(i,j,k,iBlock)

          Source_VC(SignB_,i,j,k) = Source_VC(SignB_,i,j,k) &
               + State_VGB(SignB_,i,j,k,iBlock)*DivU
       end do; end do; end do
    end if

    if(UseUserSource)then
       call user_calc_sources(iBlock)
       if(DoTestMe) call write_source('After user sources')
    end if

    if(DoTestMe) call write_source('final')

  contains
    !==========================================================================
    subroutine calc_grad_u(GradU_DD, i, j, k, iBlock)

      use BATL_lib, ONLY: FaceNormal_DDFB, CellVolume_GB, Dim1_, Dim2_, Dim3_

      integer, intent(in) :: i, j, k, iBlock
      real,   intent(out) :: GradU_DD(nDim,MaxDim)

      integer :: iDir
      character(len=*), parameter:: NameSub = 'ModCalcSource::calc_grad_u'
      !------------------------------------------------------------------------

      GradU_DD = 0.0

      ! Calculate gradient tensor of velocity
      if(IsCartesian) then
         GradU_DD(Dim1_,:) = &
              ( LeftState_VX(iUx:iUz,i+1,j,k)   &
              + RightState_VX(iUx:iUz,i+1,j,k)  &
              - LeftState_VX(iUx:iUz,i,j,k)     &
              - RightState_VX(iUx:iUz,i,j,k) )  &
              /(2*CellSize_DB(Dim1_,iBlock))

         if(nJ > 1) GradU_DD(Dim2_,:) = &
              ( LeftState_VY(iUx:iUz,i,j+1,k)   &
              + RightState_VY(iUx:iUz,i,j+1,k)  &
              - LeftState_VY(iUx:iUz,i,j,k)     &
              - RightState_VY(iUx:iUz,i,j,k) )  &
              /(2*CellSize_DB(Dim2_,iBlock))

         if(nK > 1) GradU_DD(Dim3_,:) = &
              ( LeftState_VZ(iUx:iUz,i,j,k+1)   &
              + RightState_VZ(iUx:iUz,i,j,k+1)  &
              - LeftState_VZ(iUx:iUz,i,j,k)     &
              - RightState_VZ(iUx:iUz,i,j,k) )  &
              /(2*CellSize_DB(Dim3_,iBlock))

      else if(IsRzGeometry) then
         call stop_mpi(NameSub//': RZ geometry to be implemented')
      else
         do iDir = 1, MaxDim
            iVar = iUx - 1 + iDir

            GradU_DD(:,iDir) = &
                 0.5*(LeftState_VX(iVar,i+1,j,k) &
                 + RightState_VX(iVar,i+1,j,k))* &
                 FaceNormal_DDFB(:,1,i+1,j,k,iBlock) &
                 - 0.5*(LeftState_VX(iVar,i,j,k) &
                 + RightState_VX(iVar,i,j,k))* &
                 FaceNormal_DDFB(:,1,i,j,k,iBlock)

            if(nJ == 1) CYCLE

            GradU_DD(:,iDir) = GradU_DD(:,iDir) + &
                 0.5*(LeftState_VY(iVar,i,j+1,k) &
                 + RightState_VY(iVar,i,j+1,k))* &
                 FaceNormal_DDFB(:,2,i,j+1,k,iBlock) &
                 - 0.5*(LeftState_VY(iVar,i,j,k) &
                 + RightState_VY(iVar,i,j,k))* &
                 FaceNormal_DDFB(:,2,i,j,k,iBlock)

            if(nK == 1) CYCLE

            GradU_DD(:,iDir) = GradU_DD(:,iDir) + &
                 0.5*(LeftState_VZ(iVar,i,j,k+1) &
                 + RightState_VZ(iVar,i,j,k+1))* &
                 FaceNormal_DDFB(:,3,i,j,k+1,iBlock) &
                 - 0.5*(LeftState_VZ(iVar,i,j,k) &
                 + RightState_VZ(iVar,i,j,k))* &
                 FaceNormal_DDFB(:,3,i,j,k,iBlock)
         end do

         GradU_DD = GradU_DD / CellVolume_GB(i,j,k,iBlock)

      end if

    end subroutine calc_grad_u
    !==========================================================================
    subroutine calc_divb_source

      ! Variables needed for div B source terms
      real:: DxInvHalf, DyInvHalf, DzInvHalf, DivBInternal_C(1:nI,1:nJ,1:nK)
      real:: dB1nFace1, dB1nFace2, dB1nFace3, dB1nFace4, dB1nFace5, dB1nFace6
      !------------------------------------------------------------------------

      DxInvHalf = 0.5/CellSize_DB(x_,iBlock)
      DyInvHalf = 0.5/CellSize_DB(y_,iBlock)
      DzInvHalf = 0.5/CellSize_DB(z_,iBlock)

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE

         dB1nFace1 = DxInvHalf*&
              (RightState_VX(Bx_,i,j,k)-LeftState_VX(Bx_,i,j,k))

         dB1nFace2 = DxInvHalf*&
              (RightState_VX(Bx_,i+1,j,k)-LeftState_VX(Bx_,i+1,j,k))

         if(nJ > 1)then
            dB1nFace3 = DyInvHalf* &
                 (RightState_VY(By_,i,j,k)-LeftState_VY(By_,i,j,k))

            dB1nFace4 = DyInvHalf* &
                 (RightState_VY(By_,i,j+1,k)-LeftState_VY(By_,i,j+1,k))
         end if

         if(nK > 1)then
            dB1nFace5 = DzInvHalf * &
                 (RightState_VZ(Bz_,i,j,k)-LeftState_VZ(Bz_,i,j,k))

            dB1nFace6 = DzInvHalf * &
                 (RightState_VZ(Bz_,i,j,k+1)-LeftState_VZ(Bz_,i,j,k+1))
         end if

         DivBInternal_C(i,j,k) = &
              2*DxInvHalf*(LeftState_VX(Bx_,i+1,j,k) -RightState_VX(Bx_,i,j,k))

         if(nJ > 1) DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) + &
              2*DyInvHalf*(LeftState_VY(By_,i,j+1,k) -RightState_VY(By_,i,j,k))

         if(nK > 1) DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) + &
              2*DzInvHalf*(LeftState_VZ(Bz_,i,j,k+1) -RightState_VZ(Bz_,i,j,k))

         DivB1_GB(i,j,k,iBlock)  = DivBInternal_C(i,j,k) &
              + dB1nFace1 + dB1nFace2

         if(nJ > 1) DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) &
              + dB1nFace3 + dB1nFace4

         if(nK > 1) DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) &
              + dB1nFace5 + dB1nFace6

         ! Momentum source term from B0 only needed for div(B^2/2 - BB) 
         ! discretization
         if(.not.(IsMhd.and.UseB0)) CYCLE

         Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
              -B0_DX(:,i,j,k)*dB1nFace1    &
              -B0_DX(:,i+1,j,k)*dB1nFace2

         if(nJ > 1) &
              Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
              -B0_DY(:,i,j,k)*dB1nFace3   &
              -B0_DY(:,i,j+1,k)*dB1nFace4

         if(nK > 1) &
              Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
              -B0_DZ(:,i,j,k)*dB1nFace5     &
              -B0_DZ(:,i,j,k+1)*dB1nFace6

      end do; end do; end do

      ! Momentum source term from B0 only needed for true MHD equations
      if(.not.(IsMhd .and. UseB0)) RETURN

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE
         Source_VC(rhoUx_:rhoUz_,i,j,k) = Source_VC(rhoUx_:rhoUz_,i,j,k) &
              - DivBInternal_C(i,j,k)*B0_DGB(:,i,j,k,iBlock)
      end do; end do; end do

    end subroutine calc_divb_source
    !==========================================================================
    subroutine calc_divb_source_gencoord

      use BATL_lib, ONLY: FaceNormal_DDFB

      real :: FaceArea_D(nDim), vInvHalf
      real :: B1nJumpL, B1nJumpR, DivBInternal_C(1:nI,1:nJ,1:nK)
      integer :: i, j, k

      character(len=*), parameter:: NameSub = 'calc_divb_source_gencoord'
      !------------------------------------------------------------------------

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE

         VInvHalf = 0.5/CellVolume_GB(i,j,k,iBlock)
         FaceArea_D = FaceNormal_DDFB(:,1,i,j,k,iBlock)
         B1nJumpL =VInvHalf*&
              sum(FaceArea_D*(RightState_VX(Bx_:B_+nDim,i,j,k) &
              -               LeftState_VX(Bx_:B_+nDim,i,j,k)))
         DivBInternal_C(i,j,k) = &
              -sum(FaceArea_D*RightState_VX(Bx_:B_+nDim,i,j,k))

         FaceArea_D = FaceNormal_DDFB(:,1,i+1,j,k,iBlock)
         B1nJumpR =  VInvHalf*&
              sum(FaceArea_D*(RightState_VX(Bx_:B_+nDim,i+1,j,k) &
              -               LeftState_VX(Bx_:B_+nDim,i+1,j,k)))

         DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
              + sum(FaceArea_D*LeftState_VX(Bx_:B_+nDim,i+1,j,k))

         DivB1_GB(i,j,k,iBlock)  = B1nJumpL + B1nJumpR

         if(.not.(IsMhd .and. UseB0)) CYCLE

         Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
              - B0_DX(:,i,j,k)*B1nJumpL   &
              - B0_DX(:,i+1,j,k)*B1nJumpR

      end do; end do; end do

      if(DoTestMe)write(*,*)NameSub,' after i divbint, divb1=', &
           DivBInternal_C(iTest,jTest,kTest), &
           DivB1_GB(iTest,jTest,kTest,BlkTest)

      do k = 1, nK; do j = 1, nJ; do i = 1, nI 
         if(.not.true_cell(i,j,k,iBlock)) CYCLE

         VInvHalf = 0.5/CellVolume_GB(i,j,k,iBlock)
         FaceArea_D = FaceNormal_DDFB(:,2,i,j,k,iBlock)
         B1nJumpL = VInvHalf*&
              sum(FaceArea_D*(RightState_VY(Bx_:B_+nDim,i,j,k) &
              -               LeftState_VY(Bx_:B_+nDim,i,j,k)))
         DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
              - sum(FaceArea_D*RightState_VY(Bx_:B_+nDim,i,j,k))

         FaceArea_D =  FaceNormal_DDFB(:,2,i,j+1,k,iBlock)
         B1nJumpR = VInvHalf*&
              sum(FaceArea_D*(RightState_VY(Bx_:B_+nDim,i,j+1,k) &
              -               LeftState_VY(Bx_:B_+nDim,i,j+1,k)))

         DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
              + sum(FaceArea_D*LeftState_VY(Bx_:B_+nDim,i,j+1,k))

         DivB1_GB(i,j,k,iBlock)  = DivB1_GB(i,j,k,iBlock) &
              + B1nJumpL + B1nJumpR

         if(.not.(IsMhd .and. UseB0)) CYCLE

         Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k)&
              -B0_DY(:,i,j,k)*B1nJumpL &
              -B0_DY(:,i,j+1,k)*B1nJumpR

      end do; end do; end do

      if(DoTestMe)write(*,*)NameSub,' after j divbint, divb1=', &
           DivBInternal_C(iTest,jTest,kTest), &
           DivB1_GB(iTest,jTest,kTest,BlkTest)

      if(nK > 1)then
         do k = 1, nK; do j = 1, nJ; do i = 1, nI 
            if(.not.true_cell(i,j,k,iBlock)) CYCLE

            VInvHalf = 0.5/CellVolume_GB(i,j,k,iBlock)
            FaceArea_D = FaceNormal_DDFB(:,3,i,j,k,iBlock)
            B1nJumpL = VInvHalf*&
                 sum(FaceArea_D*(RightState_VZ(Bx_:B_+nDim,i,j,k) &
                 -                LeftState_VZ(Bx_:B_+nDim,i,j,k)))

            DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
                 - sum(FaceArea_D*RightState_VZ(Bx_:B_+nDim,i,j,k))

            FaceArea_D = FaceNormal_DDFB(:,3,i,j,k+1,iBlock)
            B1nJumpR = VInvHalf*&
                 sum(FaceArea_D*(RightState_VZ(Bx_:B_+nDim,i,j,k+1) &
                 -               LeftState_VZ(Bx_:B_+nDim,i,j,k+1)))

            DivBInternal_C(i,j,k) = (DivBInternal_C(i,j,k) + &
                 sum(FaceArea_D*LeftState_VZ(Bx_:B_+nDim,i,j,k+1))) &
                 /CellVolume_GB(i,j,k,iBlock)

            DivB1_GB(i,j,k,iBlock)  = DivB1_GB(i,j,k,iBlock) &
                 + B1nJumpL + B1nJumpR

            if(.not.(IsMhd .and. UseB0)) CYCLE

            Source_VC(rhoUx_:rhoUz_,i,j,k) = Source_VC(rhoUx_:rhoUz_,i,j,k)&
                 -B0_DZ(:,i,j,k)*B1nJumpL &
                 -B0_DZ(:,i,j,k+1)*B1nJumpR
         end do; end do; end do
      end if

      if(DoTestMe)write(*,*)NameSub,' after k divbint, divb1=', &
           DivBInternal_C(iTest,jTest,kTest), &
           DivB1_GB(iTest,jTest,kTest,BlkTest)

      do k = 1, nK; do j = 1, nJ; do i = 1, nI 
         if(.not.true_cell(i,j,k,iBlock)) CYCLE
         DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) +DivBInternal_C(i,j,k)
      end do; end do; end do

      if(DoTestMe)write(*,*)NameSub,' final divb1=', &
           DivB1_GB(iTest,jTest,kTest,BlkTest)

      if(.not.(IsMhd .and. UseB0)) RETURN

      do k = 1, nK; do j = 1, nJ; do i = 1, nI 
         if(.not.true_cell(i,j,k,iBlock)) CYCLE
         Source_VC(RhoUx_:RhoUz_,i,j,k) = Source_VC(RhoUx_:RhoUz_,i,j,k) &
              - DivBInternal_C(i,j,k)*B0_DGB(:,i,j,k,iBlock)            
      end do; end do; end do

    end subroutine calc_divb_source_gencoord
    !==========================================================================

    subroutine write_source(String)
      character(len=*), intent(in) :: String
      write(*,'(a,es13.5)') NameSub//": "//String//" S(VarTest)=",&
           Source_VC(VarTest,iTest,jTest,kTest) 
    end subroutine write_source

  end subroutine calc_source

  !============================================================================

  subroutine calc_divb(iBlock)

    ! Calculate div B for a block and store result into DivB1_GB
    ! Compute divB using averaged and conservatively corrected 
    ! left and right values

    use BATL_lib,      ONLY: CellSize_DB, x_, y_, z_
    use ModMain,       ONLY: nI, nJ, nK
    use ModVarIndexes, ONLY: Bx_, By_, Bz_
    use ModAdvance,    ONLY: DivB1_GB, &
         LeftState_VX, RightState_VX, &
         LeftState_VY, RightState_VY, &
         LeftState_VZ, RightState_VZ

    integer, intent(in) :: iBlock

    integer:: i, j, k
    real   :: DivB, InvDx, InvDy, InvDz
    !--------------------------------------------------------------------------

    InvDx            = 1/CellSize_DB(x_,iBlock)
    if(nJ > 1) InvDy = 1/CellSize_DB(y_,iBlock)
    if(nK > 1) InvDz = 1/CellSize_DB(z_,iBlock)

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       DivB = InvDx* &
            (  LeftState_VX(Bx_,i+1,j,k)  &
            + RightState_VX(Bx_,i+1,j,k)  &
            -  LeftState_VX(Bx_,i,j,k)    &
            - RightState_VX(Bx_,i,j,k) )

       if(nJ > 1) DivB = DivB + InvDy* &
            (  LeftState_VY(By_,i,j+1,k)   &
            + RightState_VY(By_,i,j+1,k)   &
            -  LeftState_VY(By_,i,j,k)     &
            - RightState_VY(By_,i,j,k) )

       if(nK > 1) DivB = DivB + InvDz* &
            (  LeftState_VZ(Bz_,i,j,k+1)    &
            + RightState_VZ(Bz_,i,j,k+1)    &
            -  LeftState_VZ(Bz_,i,j,k)      &
            - RightState_VZ(Bz_,i,j,k) )

       DivB1_GB(i,j,k,iBlock) = 0.5*DivB

    end do; end do; end do

  end subroutine calc_divb

end module ModCalcSource