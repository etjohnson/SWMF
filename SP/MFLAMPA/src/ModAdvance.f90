!  Copyright (C) 2002 Regents of the University of Michigan, 
!  portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
!=============================================================!
module SP_ModAdvance

  ! The module contains methods for advancing the solution in time

  use ModNumConst,ONLY: cPi, cTiny

  use ModConst,   ONLY: cMu, cProtonMass, cGyroradius, cLightSpeed, RSun

  use SP_ModSize, ONLY: nParticleMax, nP=>nMomentum

  use SP_ModGrid, ONLY: State_VIB, iShock_IB, D_,  R_, Rho_, RhoOld_, U_, &
       B_, BOld_, T_, nParticle_B, Shock_, ShockOld_, DLogRho_, nBlock
       

  use SP_ModDiffusion, ONLY: advance_diffusion

  use SP_ModLogAdvection, ONLY: advance_log_advection
  use ModConst, ONLY: kinetic_energy_to_momentum, momentum_to_kinetic_energy,&
       momentum_to_energy, energy_in

  implicit none

  SAVE
  
  private ! except

  public:: TimeGlobal, iIterGlobal, DoTraceShock, UseDiffusion
  public:: init_advance_const, set_injection_param, advance, &
       set_initial_condition
  public::  EnergyScale_I, MomentumScale_I, &
       LogEnergyScale_I, LogMomentumScale_I, DMomentumOverDEnergy_I

  !\
  ! Global interation and time
  !-----------------------------
  real   :: TimeGlobal  = -1.0
  integer:: iIterGlobal = -1
  !-----------------------------
  ! units of energy
  character(len=*), parameter:: NameEUnit = 'kev'
  real:: UnitEnergy
  ! simulated particles
  character(len=*), parameter:: NameParticle = 'proton'
  !-----------------------------
  ! Injection and max energy in the simulation
  real:: EnergyInj=10.0, EnergyMax=1.0E+07
  real:: TotalEnergyInj
  !-----------------------------
  ! Injection and max momentum in the simulation
  real:: MomentumInj, MomentumMax
  !-----------------------------
  ! Size of a momentum bin on a log-scale
  real:: DLogMomentum
  !-----------------------------
  ! Injection efficiency
  real:: CInj = 1.0
  !-----------------------------
  ! Spectral index in the BC
  real:: SpectralIndex = 5.0
  !-----------------------------
  ! limitation of CFL number
  real:: CFLMax = 0.9
  !-----------------------------
  ! scale with respect to Momentum and log(Momentum)
  real:: MomentumScale_I(0:nP+1)
  real:: LogMomentumScale_I(0:nP+1)
  real:: EnergyScale_I(0:nP+1)
  real:: LogEnergyScale_I(0:nP+1)
  real:: DMomentumOverDEnergy_I(0:nP+1)
  !\
  !          Grid in the momentum space
  !iP     0     1                         nP   nP+1
  !       |     |    ....                 |     | 
  !P      P_inj P_inj*exp(\Delta (Ln P))  P_Max P_Max*exp(\Delta (Ln P))
  !This is because we put two boundary conditions: the background value at
  !the right one and the physical condition at the left one, for the 
  !distribution function
  ! Velosity Distribution Function (VDF) 
  ! Number of bins in the distribution is set in ModSize
  ! 1st index - log(momentum) bin
  ! 2nd index - particle index along the field line
  ! 3rd index - local block number
  real, public, allocatable:: Distribution_IIB(:,:,:)
  !/

  !-----------------------------
  ! level of turbulence
  real:: BOverDeltaB2 = 1.0
  !-----------------------------
  integer:: nWidth = 50
  !-----------------------------
  logical:: UseRealDiffusionUpstream = .true.
  logical:: DoTraceShock = .true., UseDiffusion = .true.
  !/


contains
  
  subroutine set_injection_param
    use ModReadParam, ONLY: read_var
    !---------------------------------------------
    call read_var('EnergyInj',    EnergyInj)
    call read_var('EnergyMax',    EnergyMax)
    call read_var('SpectralIndex',SpectralIndex)
    call read_var('Efficiency',   CInj)
  end subroutine set_injection_param

  !============================================================================

  subroutine init_advance_const
    ! compute all needed constants
    integer:: iMomentumBin, iBlock, iParticle
    !---------------------------------------------
    ! account for units of energy
    UnitEnergy = energy_in(NameEUnit)
    EnergyInj = EnergyInj * UnitEnergy
    EnergyMax = EnergyMax * UnitEnergy
    ! convert energies to momenta
    MomentumInj  = kinetic_energy_to_momentum(EnergyInj, NameParticle)
    MomentumMax  = kinetic_energy_to_momentum(EnergyMax, NameParticle)
    ! total injection energy (including the rest mass energy
    TotalEnergyInj = momentum_to_energy(MomentumInj, NameParticle)
    DLogMomentum = log(MomentumMax/MomentumInj) / nP
    do iMomentumBin = 0, nP +1
       LogMomentumScale_I(iMomentumBin) = &
            log(MomentumInj) + iMomentumBin * DLogMomentum
       MomentumScale_I(iMomentumBin) = exp(LogMomentumScale_I(iMomentumBin))
       EnergyScale_I(iMomentumBin) = momentum_to_kinetic_energy(&
            MomentumScale_I(iMomentumBin), NameParticle)
       LogEnergyScale_I(iMomentumBin) = log(EnergyScale_I(iMomentumBin))
       DMomentumOverDEnergy_I(iMomentumBin) = &
            momentum_to_energy(MomentumScale_I(iMomentumBin), NameParticle) / &
            (MomentumScale_I(iMomentumBin) * cLightSpeed**2)
    end do
  end subroutine init_advance_const

  !============================================================================
  
  subroutine set_initial_condition
    use ModUtilities,      ONLY: check_allocate
    ! set the initial distribution on all lines
    integer:: iBlock, iParticle, iMomentumBin, iError
    !----------------------------------------------------------
    allocate(Distribution_IIB(&
         nP,1:nParticleMax,nBlock), stat=iError)
    call check_allocate(iError, 'Distribution_IIB')
    do iBlock = 1, nBlock
       do iParticle = 1, nParticleMax
          do iMomentumBin = 1, nP +1
             Distribution_IIB(iMomentumBin,iParticle,iBlock) = &
                  cTiny / kinetic_energy_to_momentum(EnergyMax,&
                  NameParticle)/(MomentumScale_I(iMomentumBin))**2
          end do
       end do
    end do
  end subroutine set_initial_condition

  !===================================================================

  subroutine get_shock_location(iBlock)
    integer, intent(in) :: iBlock
    ! find location of a shock wave on every field line
    !--------------------------------------------------------------------------
    ! loop variable
    integer:: iSearchMin, iSearchMax
    integer:: iShockCandidate
    !--------------------------------------------------------------------------
    if(.not.DoTraceShock)then
       iShock_IB(Shock_, iBlock) = 1
       RETURN
    end if

    ! shock front is assumed to be location of max gradient log(Rho1/Rho2);
    ! shock never moves back
    iSearchMin = max(iShock_IB(ShockOld_, iBlock), 1 + nWidth )
    iSearchMax = nParticle_B(iBlock) - nWidth - 1
    iShockCandidate = iSearchMin - 1 + maxloc(&
         State_VIB(DLogRho_,iSearchMin:iSearchMax,iBlock),&
         1, MASK = State_VIB(R_,iSearchMin:iSearchMax,iBlock) > 1.2)

    if(State_VIB(DLogRho_,iShockCandidate,iBlock) > 0.0)&
         iShock_IB(Shock_, iBlock) = iShockCandidate
  end subroutine get_shock_location
  !===========================================================================
  subroutine advance(TimeLimit)
    ! advance the solution in time
    real, intent(in):: TimeLimit
    integer:: iEnd, iBlock, iParticle, iShock, iShockOld
    integer:: Momentum, iMomentumBin
    integer:: nProgress, iProgress, iStep
    !Subcycling advection multiple times per each diffusion step, if desired
    integer, parameter:: nStep = 1
    real   :: Alpha
    real::  DiffCoeffMin =1.0E+04 /RSun
    real:: DtFull, DtProgress, Dt
    real:: MachAlfven
    !Local arrays
    real, dimension(1:nParticleMax):: Rho_I, RhoOld_I, U_I, T_I
    real, dimension(1:nParticleMax):: Radius_I, B_I, BOld_I 
    real, dimension(1:nParticleMax):: DLogRho_I, FermiFirst_I
    !-----------------------------
    ! df/dt = DOuter * d(DInner * df/dx)/dx
    real, dimension(1:nParticleMax):: DOuter_I, DInner_I, DInnerInj_I
    character(len=*), parameter:: NameSub = 'SP:advance'
    !--------------------------------------------------------------------------
    ! the full time step
    DtFull = TimeLimit - TimeGlobal
    ! go line by line and advance the solution
    do iBlock = 1, nBlock

       ! the active particles on the line
       iEnd   = nParticle_B( iBlock)
       ! various data along the line
       Radius_I( 1:iEnd) = State_VIB(R_,      1:iEnd,iBlock)
       Rho_I(    1:iEnd) = State_VIB(Rho_,    1:iEnd,iBlock)
       U_I(      1:iEnd) = State_VIB(U_,      1:iEnd,iBlock)
       T_I(      1:iEnd) = State_VIB(T_,      1:iEnd,iBlock)
       BOld_I(   1:iEnd) = State_VIB(BOld_,   1:iEnd,iBlock)
       RhoOld_I( 1:iEnd) = State_VIB(RhoOld_, 1:iEnd,iBlock)
       !log(Rho_I(1:iEnd)/RhoOld_I(1:iEnd)
       DLogRho_I(1:iEnd) = State_VIB(DLogRho_,1:iEnd,iBlock)

       ! identify shock in the data
       call get_shock_location(iBlock)

       ! find how far shock has travelled on this line: nProgress
       iShock    = iShock_IB(Shock_,   iBlock)
       iShockOld = iShock_IB(ShockOld_,iBlock)
       nProgress = MAX(1, iShock - iShockOld)
       iShockOld = MIN(iShockOld, iShock-1)

       ! each particles shock has crossed should be
       ! processed separately => reduce the time step
       DtProgress = DtFull / nProgress

       ! go over each crossed particle
       do iProgress = 1, nProgress
          ! account for change in the background up to the current moment
          Alpha = real(iProgress) / real(nProgress)
          Rho_I(1:iEnd) = State_VIB(RhoOld_,1:iEnd,iBlock) +Alpha *&
               (State_VIB(Rho_,  1:iEnd,iBlock) - &
               State_VIB(RhoOld_,1:iEnd,iBlock))

          DLogRho_I(1:iEnd)=log(Rho_I(1:iEnd)/RhoOld_I(1:iEnd))

          B_I(1:iEnd) = State_VIB(BOld_,1:iEnd,iBlock) + Alpha*&
               (State_VIB(B_,  1:iEnd,iBlock) - &
               State_VIB(BOld_,1:iEnd,iBlock))
          iShock = iShockOld + iProgress

          ! find the shock alfven mach number, also steepen the shock
          if(iShock < iEnd - nWidth .and. iShock > nWidth)then
             MachAlfven = mach_alfven()
             call steepen_shock
          else
             MachAlfven = 1.0
          end if

          ! 1st order Fermi acceleration is responsible for advection 
          ! in momentum space
          ! first order Fermi acceleration for the current line
          !--------------------------------------------------------
          FermiFirst_I(1:iEnd) = DLogRho_I(1:iEnd) / (3*DLogMomentum)

          RhoOld_I(1:iEnd) = Rho_I(1:iEnd)
          BOld_I(  1:iEnd) = B_I(  1:iEnd)

          Dt = DtProgress
          if(nStep>1)then !Currently not used
             Dt = Dt / nStep
             FermiFirst_I(1:iEnd) = FermiFirst_I(1:iEnd) / nStep
          end if

          ! compute diffusion along the field line
          call set_diffusion
          do iStep = 1, nStep !Currently nStep = 1
             ! update bc for advection
             call set_advection_boundary_condition

             ! advection in the momentum space
             do iParticle = 2, iEnd
                call advance_log_advection(&
                     FermiFirst_I(iParticle),nP,1,1,&
                     Distribution_IIB(0:nP+1,iParticle,iBlock), &
                     .false.)
             end do

             ! diffusion along the field line
             if(.not.UseDiffusion) CYCLE
             do iMomentumBin = 1, nP
                Momentum = exp((iMomentumBin-1) * DLogMomentum)
                DInner_I(1:iEnd) =&
                     DInnerInj_I(1:iEnd) * Momentum**2 * &
                     TotalEnergyInj/&
                     momentum_to_energy(Momentum*MomentumInj,NameParticle)
                if(UseRealDiffusionUpstream)then
                   where(Radius_I(1:iEnd) > 0.9*Radius_I(iShock))
                      ! upstream:
                      DInner_I(1:iEnd) = &
                           DInner_I(1:iEnd) / Momentum**(2.0/3)
                   end where
                end if
                DInner_I(1:iEnd) = max(DInner_I(1:iEnd),&
                     DiffCoeffMin/DOuter_I(1:iEnd))
                call advance_diffusion(Dt, iEnd,&
                     State_VIB(D_,1:iEnd,iBlock), &
                     Distribution_IIB(iMomentumBin,1:iEnd,iBlock),&
                     DOuter_I(1:iEnd), DInner_I(1:iEnd))
             end do
          end do
       end do
    end do
  contains
    function mach_alfven() result(MachAlfven)
      ! alfvenic mach number for the current line
      real:: MachAlfven
      
      real:: SpeedAlfvenUpstream, SpeedUpstream
      !--------------------------------------------
      ! speed upstream is relative to the shock:
      ! \rho_u * (U_u - V_{shock}) = \rho_d * (U_d - V_{shock})
      SpeedUpstream = Rho_I(iShock+1-nWidth)*&
           (U_I(  iShock + 1 - nWidth) - U_I(  iShock + nWidth))/ &
           (Rho_I(iShock + 1 - nWidth) - Rho_I(iShock + nWidth))
      SpeedAlfvenUpstream = B_I(iShock + nWidth)/ &
           sqrt(cMu*cProtonMass*Rho_I(iShock + nWidth))
      MachAlfven = SpeedUpstream / SpeedAlfvenUpstream
    end function mach_alfven
    !=======================
    subroutine steepen_shock
      ! change the density profile near the shock front so it becomes steeper
      ! for the current line
      integer:: iParticle ! loop variable
      real   :: DLogRhoBackground, DLogRhoExcess, Misc, Length
      !--------------------------------------------------------------------------
      ! compute the background value of DLogRho as average in the upstream 
      DLogRhoBackground = 0.0

      ! find the excess of DLogRho within the shock compared to background
      ! averaged over length
      DLogRhoExcess = 0.0
      Length = 0.0
      do iParticle = iShock - nWidth, iShock + nWidth - 1
         Misc = 0.5 * (DLogRho_I(iParticle) + DLogRho_I(iParticle+1)) - &
              DLogRhoBackground
         if(Misc > 0.0)then
            DLogRhoExcess = DLogRhoExcess + &
                 Misc*State_VIB(D_, iParticle, iBlock)
            Length = Length + State_VIB(D_, iParticle, iBlock)
         end if
      end do

      ! check for zero excess
      if(DLogRhoExcess == 0.0)RETURN
      ! otherwise, get the averaged value
      DLogRhoExcess = DLogRhoExcess / Length

      ! apply the result within the shock width
      DLogRho_I(iShock-nWidth:iShock+nWidth) = min(&
           DLogRhoBackground, &
           DLogRho_I(iShock-nWidth:iShock+nWidth))
      DLogRho_I(iShock) = DLogRhoExcess + DLogRhoBackground

      ! also, sharpen the magnitude of the magnetic field
      ! post shock part
      B_I(iShock+1-nWidth:iShock+1) = maxval(B_I(iShock+1-nWidth:iShock+1))
      ! pre shock part
      B_I(iShock+1:iShock+nWidth  ) = minval(B_I(iShock+1:iShock+nWidth))
    end subroutine steepen_shock
    !=============================================================
    subroutine set_diffusion
      ! set diffusion coefficient for the current line
      !-----------------------------------------------------------
      DOuter_I(1:iEnd) = B_I(1:iEnd)
      !DInner = DiffusionCoeff/B_)
      if(.not.UseRealDiffusionUpstream)then
         ! Sokolov et al., 2004: eq (4), 
         ! note: P = TotalEnergy * Vel / C**2
         ! Gyroradius = cGyroRadius * momentum / |B|
         ! DInner = (B/\delta B)**2*Gyroradius*Vel/|B| 
         DInnerInj_I(1:iEnd) = BOverDeltaB2*&
              cGyroRadius*(MomentumInj*cLightSpeed)**2/&
              (B_I(1:iEnd)**2*TotalEnergyInj)/RSun**2
      else
         ! diffusion is different up- and down-stream
         ! Sokolov et al. 2004, paragraphs before and after eq (4)
         where(Radius_I(1:iEnd) > 0.9 * Radius_I(iShock))
            ! upstream:
            DInnerInj_I(1:iEnd) = &
                 0.2/3.0 * Radius_I(1:iEnd) / RSun * &
                 (MomentumInj*cLightSpeed**2)/(B_I(1:iEnd)*TotalEnergyInj)*&
                 (MomentumInj*cLightSpeed/energy_in('GeV'))**(1.0/3)
         elsewhere
            ! downstream
            DInnerInj_I(1:iEnd)=&
                 cGyroRadius*(MomentumInj*cLightSpeed)**2 / RSun**2/&
                 (B_I(1:iEnd)**2 * TotalEnergyInj)/&
                 (10.0*CInj*MachAlfven) / &
                 min(1.0, 1.0/0.9 * Radius_I(1:iEnd)/Radius_I(iShock))
         end where
      end if

      ! set the boundary condition for diffusion
      Distribution_IIB(2:nP, 1, iBlock) = &
           Distribution_IIB(1, 1, iBlock) * &
           (MomentumScale_I(1)/MomentumScale_I(2:nP))**SpectralIndex
    end subroutine set_diffusion
    !=========================================================================
    subroutine set_advection_boundary_condition
      ! set boundary conditions on each particle on the current line
      !----------------------------------------
      ! loop variable
      integer:: iParticle
      real   :: MomentumTi  !Momentum for the thermal energy k_BTi
      !----------------------------------------
      do iParticle = 1, iEnd
         ! default injection distribution, see Sokolov et al., 2004, eq (3)
         MomentumTi = kinetic_energy_to_momentum(&
              State_VIB(T_,iParticle,iBlock)*UnitEnergy,NameParticle)
         Distribution_IIB(0,iParticle,iBlock) = &
              0.25/cPi/(SpectralIndex-3)*CInj*Rho_I(iParticle)/ &
              MomentumTi**3 * (MomentumTi/MomentumInj)**SpectralIndex
      end do
    end subroutine set_advection_boundary_condition
  end subroutine advance
end module SP_ModAdvance
