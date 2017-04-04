!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
!This code is a copyright protected software (c) 2002- University of Michigan
!========================================================================
module ModUser
  ! This is the user module for Titan

  use ModSize
  use ModVarIndexes, ONLY: rho_, Ux_, Uy_, Uz_,p_,Bx_, Bz_,&
       rhoLp_,rhoMp_,MassSpecies_V,SpeciesFirst_,SpeciesLast_, MassFluid_I
  use ModUserEmpty,               &
       IMPLEMENTED1 => user_read_inputs,                &
       IMPLEMENTED2 => user_init_session,               &
       IMPLEMENTED3 => user_set_ics,                    &
       IMPLEMENTED5 => user_set_face_boundary,          &
       IMPLEMENTED6 => user_calc_sources,               &
       IMPLEMENTED7 => user_init_point_implicit,        &
       IMPLEMENTED8 => user_set_plot_var,               & 
       IMPLEMENTED9 => user_set_resistivity,            &        
       IMPLEMENTED10 => user_get_log_var


  include 'user_module.h' !list of public methods

  !\
  ! Here you must define a user routine Version number and a 
  ! descriptive string.
  !/
  real,              parameter :: VersionUserModule = 1.1
  character (len=*), parameter :: NameUserModule = &
       'Titan 7 species MHD code, Yingjuan Ma'

  integer, parameter :: MaxNuSpecies=10, MaxReactions=30

  integer, parameter :: MaxSpecies=7

  integer :: nSpecies=7, nNuSpecies=10

  ! Radius within which the point implicit scheme should be used
  real :: rPointImplicit = 2.5

  !number density of neutral Species
  real:: NumDenNeutral_VC(MaxNuSpecies, nI, nJ, nK)    

  !photonionzation and recombination rate 
  real:: PhotoIonRate_VC(MaxSpecies, nI, nJ, nK), &
       RecombRate_VC(MaxSpecies, nI, nJ, nK) 

  real, dimension(MaxReactions) :: ReactionRate_I
  real, dimension(MaxReactions,MaxSpecies):: CoeffSpecies_II, &
       dSdRho_II !, dLdRho_II
  real, dimension(MaxSpecies)::LossSpecies_I, &
       SiSpecies_I,  LiSpecies_I
  !        dStndRho_I,  dLtdRho_I,  dLtndNumRho_I, &
  real:: totalNumRho, totalLossRho, totalLossNumRho, &
       totalSourceNumRho, totalLossx, totalLossNumx, totalSourceRho

  !the reactions considered:(p means ion, em means electron)
  !the prefered order of a reaction is ions, Nus, hv and electrons
  integer, parameter :: &!reaction number
       M_hv__Mp_em_    = 1, &
       H1_hv__H1p_em_  = 2, &
       L_hv__Lp_em_    = 3, &
       Lp_em__L_       = 4, &
       Mp_em__M_       = 5, &
       H1p_em__H1_     = 6, &
       H2p_em__H2_     = 7, &
       MHCp_em__MHC_   = 8, &
       HHCp_em__HHC_   = 9, &
       HNIp_em__HNI_   = 10,&
       Lp_CH4__H1p_X_  = 11, &
       Lp_N2__Mp_X_    = 12, &
       Mp_CH4__H2p_X_  = 13, &
       Mp_C2H4__H1p_X_ = 14, &
       Mp_C2H6__H1p_X_ = 15, &
       H1p_HCN__H2p_X_ = 16, &
       H1p_HC3N__HNIp_X_ = 17, &
       H1p_C2H2__MHCp_X_ = 18, &
       H1p_C2H4__MHCp_X_ = 19, &
       H2p_HC3N__HNIp_X_ = 20, &
       H2p_C4H2__MHCp_X_ = 21, &
       MHCp_C2H2__HHCp_X_= 22, &
       MHCp_C2H4__HHCp_X_= 23, &
       MHCp_C3H4__HHCp_X_= 24, &
       MHCp_C4H2__HHCp_X_= 25

  integer, parameter :: &! order of ion species
       Lp_   = 1, &
       Mp_   = 2, &
       H1p_  = 3, &
       H2p_  = 4, &
       MHCp_ = 5, &
       HHCp_ = 6, &
       HNIp_ = 7
  integer, parameter :: & ! order of Neutral species
       N2_  = 1, &
       CH4_ = 2, &
       L_   = 3, &
       C3H4_= 4, & !
       C4H2_= 5, & !
       C2H2_= 6, &
       C2H4_= 7, &
       HCN_ = 8, &
       C2H6_= 9, &
       HC3N_=10

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  real, dimension(MaxReactions) :: Rate_I
  real, dimension(MaxReactions) :: Ratedim_I

  character (len=10), dimension(MaxSpecies):: &
       ion_name_I

  real, dimension(MaxNuSpecies):: &
       HNuSpecies_I, BodynDenNuSpdim_I,&
       BodynDenNuSpecies_I   

  real, dimension(MaxSpecies):: BodyRhoSpecies_I
  integer, parameter :: & ! other numbers
       em_=-1 ,&
       hv_=-2   

  real :: body_Tn_dim=160. !neutral temperature at the body                    
  real :: kTn, kTi0, kTp0  !dimensionless temperature of neutral, &
                           !new created ions, plasma at the body
!  real :: body_Ti_dim=350., kT0 !ion temperature at the body
  real :: Te_new_dim=1000., KTe0 !temperature of new created electrons
  real :: kT1000

  real :: Nu_C(1:nI,1:nJ,1:nK)
  real :: nu0_dim=1.0e-10,nu0

  logical :: UseImpact =.false.
  character*30 :: SolarCondition, type_innerbcs='reflect'
  integer, parameter :: num_Te = 9500, num_Ri = 199, num_nu=229
  !, num_n = 9500
  !  real, dimension(1:num_n) :: tmp_rn, tmp_hn, tmp_nL, tmp_nM, tmp_nH
  real, dimension(10,1:num_nu):: tmp_n
  real, dimension(1:num_nu):: tmp_hn
  real, dimension(1:num_Te) :: tmp_hT, tmp_Te
  real, dimension(1:num_Ri) :: tmp_hR 

  integer, parameter:: num_en= 101
  real, dimension(1:num_en) :: nu_Te 
  real, dimension(1:num_en,3) :: nu_en 

  real, dimension(1:num_Ri):: IMPACT_L, IMPACT_M,IMPACT_H

  integer, parameter :: maxNumSZA = 17
  integer :: NumSZA =17
  real, dimension(1:maxNumSZA,1:num_Ri):: tmp_RL0=0, tmp_RM0=0,tmp_RH0=0
  real, dimension(MaxSpecies,maxNumSZA+1):: BodyRhoSpecies_dim_II=1.0, coefSZAB_II
  real, dimension(1:maxNumSZA):: SZATitan_I=0.0, cosSZA_I  !for ionization
  real, dimension(1:maxNumSZA+1):: SZABTitan_I=0.0, cosSZAB_I !for ion density


  real, dimension(1:7,1:num_Ri):: tmp_ion
  real:: SW_Lp, SW_Mp,  SW_Lp_dim, SW_Mp_dim,Plas_T_ev
  real:: Plas_rho, Plas_T  

  !\
  ! The following are needed in user_sources::
  !/
  real, dimension(1:nI,1:nJ,1:nK):: &
       Srho,SrhoUx,SrhoUy,SrhoUz,SBx,SBy,SBz,Sp,SE
  real, dimension(MaxSpecies,1:nI,1:nJ,1:nK) :: &
       SrhoSpecies


  !  real:: SX0=0.673, SY0=0.663, SZ0=-0.32 !for T9 flyby
  real:: SX0=1.0, SY0=0.0, SZ0=0.0   !for symetric case
  !  real:: SX0=-0.325568, SY0=-0.945519, SZ0=0.0  !71  degree from -x
  !  real:: SX0=0.174, SY0=-0.9848, SZ0=0.0        !100 degree from -x
  !  real:: SX0=0.342, SY0=-0.9397, SZ0=0.0        !110 degree from -x
  !  real:: SX0=0.303654, SY0=-0.85936,SZ0=-0.3907 !long=110, lat=-23
  !  !from -x for Ta & Tb
  !  real:: SX0=0.9116, SY0=0.1697,SZ0=-0.374      !long=10.55, lat=-22
  !  !from x for T5

  logical:: UseCosSZA=.true.
  logical:: UseOldEnergy=.true., UseTempControl=.false.
contains
  !============================================================================

  subroutine user_read_inputs
    use ModProcMH,    ONLY: iProc
    use ModReadParam
    use ModPhysics, ONLY: SW_N_DIM, SW_T_DIM
    use ModIoUnit, ONLY: UnitTmp_

    character (len=100) :: NameCommand
    !    character (len=100) :: line
    character (len=100) :: linetitan
    character (len=100) :: fileH, fileM, fileL, &
         fileNeuDen, fileSZA, fileIonDen60deg
    integer:: i, j
    real:: tmp_ne,tmp_alt
    !--------------------------------------------------------------------------

    do
       if(.not.read_line() ) EXIT
       if(.not.read_command(NameCommand)) CYCLE
       select case(NameCommand)

       case('#SUBSOLARLOC')
          call read_var('SX0',SX0)
          call read_var('SY0',SY0)
          call read_var('SZ0',SZ0)

       case('#INNERBCS')
          call read_var('type_innerbcs',type_innerbcs)

       case('#BODYTEMP')
          call read_var('body_Tn_dim',body_Tn_dim)

       case('#USEOLDENERGY')
          call read_var('UseOldEnergy',UseOldEnergy)
          if(.not.UseOldEnergy)then
             call read_var('Te_new_dim',Te_new_dim)
             call read_var('UseTempControl',UseTempControl)
             
             !change temperature from ev to k
             Te_new_dim = Te_new_dim * 11610.0  
          end if

       case('#UPSTREAM')
          call read_var('SW_LP_dim', SW_LP_dim)
          call read_var('SW_MP_dim', SW_MP_dim)        
          call read_var('plas_T_ev', plas_T_ev)        
          SW_LP=SW_LP_dim*MassSpecies_V(rhoLp_)
          SW_MP=SW_MP_dim*MassSpecies_V(rhoMp_)
          Plas_rho =  SW_LP + SW_MP 
          SW_LP= SW_LP/Plas_rho 
          SW_MP= SW_MP/Plas_rho 
          MassFluid_I(1) = Plas_rho/(SW_LP_dim+SW_MP_dim)
!          plas_T = plas_T_ev/MassFluid_I(1)*1.1610e4          
          plas_T = plas_T_ev*1.1610e4          
          if(iproc==0)then
             write(*,*)'MassFluid_I(1)=',MassFluid_I(1)           
             write(*,*)'plas_T=',plas_T
          end if

          SW_n_dim = Plas_rho/MassFluid_I(1)
          SW_T_dim = plas_T      

          !write(*,*)'SW_n_dim=',SW_n_dim,SW_T_dim

       case('#USETITANINPUT')
          call read_var('SolarCondition',SolarCondition)
          call read_var('UseImpact',UseImpact)

          select case(SolarCondition)
          case("Solarmax")              
             NumSZA = 9
             fileSZA="TitanInput/SZALIST_9.dat"
             fileH  ="TitanInput/HighsolarH.dat"
             fileM  ="TitanInput/HighsolarM.dat"
             fileL  ="TitanInput/HighsolarL.dat"
             fileIonDen60deg="TitanInput/TitanDen60degmax.dat"
             fileNeuDen ="TitanInput/NEUTRALDENSITY.dat"

          case("Solarmin")  
             NumSZA = 9
             fileSZA="TitanInput/SZALIST_9.dat"
             fileH  ="TitanInput/LowsolarH.dat"
             fileM  ="TitanInput/LowsolarM.dat"
             fileL  ="TitanInput/LowsolarL.dat"
             fileIonDen60deg="TitanInput/TitanDen60degmin.dat"
             fileNeuDen ="TitanInput/NEUTRALDENSITY.dat"

          case("Cassini3")                        
             NumSZA = 17
             fileSZA="TitanInput/SZALIST_17.dat"
             fileH  ="TitanInput/PhotoRate_H_Apr11.dat"
             fileM  ="TitanInput/PhotoRate_M_Apr11.dat"
             fileL  ="TitanInput/PhotoRate_L_Apr11.dat"
             fileIonDen60deg="TitanInput/TIondenSZ060_Apr11.dat"
             fileNeuDen ="TitanInput/NeuDen_Apr11.dat"

             open(UnitTmp_,file="TitanInput/TIondenAl725_Apr11.dat",status="old")
             read(UnitTmp_,'(a)')linetitan
            ! write(*,*)'linetitan',linetitan
             do i=1,NumSZA+1
                read(UnitTmp_,*)tmp_alt,SZABTitan_I(i),&
                     (BodyRhoSpecies_dim_II(j,i),j=1,7),tmp_ne
             end do
             close(UnitTmp_)
 
          case("CassiniTA")                        
             NumSZA = 12
             fileSZA="TitanInput/SZALIST_12.dat"
             fileH  ="TitanInput/HsolarPrdJan05.txt"
             fileM  ="TitanInput/MsolarPrdJan05.txt"
             fileL  ="TitanInput/LsolarPrdJan05.txt"
             if(UseCosSZA)then
                fileIonDen60deg="TitanInput/TitanDen60degmin.dat"
             else                 
                fileIonDen60deg="TitanInput/TitanDen60degCassini.dat"
             end if
             fileNeuDen ="TitanInput/NEUTRALDENSITYJan05.dat"

             open(UnitTmp_,file="TitanInput/IondenAlt725.dat",status="old")
             read(UnitTmp_,'(a)')linetitan

             do i=1,NumSZA+1
                read(UnitTmp_,*)tmp_alt,SZABTitan_I(i),&
                     (BodyRhoSpecies_dim_II(j,i),j=1,7),tmp_ne
             end do
             close(UnitTmp_)
          case default
             if(iProc==0) call stop_mpi('wrong solar condtion!')
          end select

          !read in SZA list
          open(UnitTmp_, file =fileSZA,status="old")              
          read(UnitTmp_,'(a)')linetitan
          read(UnitTmp_,*) (SZATitan_I(j),j=1,NumSZA)  
          close(UnitTmp_)

          !read in photoionzation rates of H, M and L
          open(UnitTmp_,file=fileH,status="old")
          read(UnitTmp_,'(a)')linetitan
          read(UnitTmp_,'(a)')linetitan
          do i=1,num_Ri
             read(UnitTmp_,*) tmp_hR(i),(tmp_RH0(j,i),j=1,NumSZA)              
          end do
          close(UnitTmp_)

          open(UnitTmp_,file=fileM,status="old")
          read(UnitTmp_,'(a)')linetitan
          read(UnitTmp_,'(a)')linetitan
          do i=1,num_Ri
             read(UnitTmp_,*) tmp_hR(i),(tmp_RM0(j,i),j=1,NumSZA)
          end do
          close(UnitTmp_)

          open(UnitTmp_,file=fileL,status="old")
          read(UnitTmp_,'(a)')linetitan
          read(UnitTmp_,'(a)')linetitan
          do i=1,num_Ri
             read(UnitTmp_,*)tmp_hR(i),(tmp_RL0(j,i),j=1,NumSZA)
          end do
          close(UnitTmp_)

          !read in ion density at lower boudnary
          open(UnitTmp_,file=fileIonDen60deg,status="old") 
          read(UnitTmp_,'(a)')linetitan
          read(UnitTmp_,'(a)')linetitan
          do i=1,num_Ri
             read(UnitTmp_,*)tmp_hR(i),(tmp_ion(j,i),j=1,7)
          end do
          close(UnitTmp_)    

          !read in neutral density
          open(UnitTmp_,file=fileNeuDen,status="old")  
          read(UnitTmp_,'(a)')linetitan
          !write(*,*)linetitan
          do i=1,num_nu
             read(UnitTmp_,*)tmp_hn(i),(tmp_n(j,i),j=1,10)
          end do
          close(UnitTmp_)

          !for impact ionization
          if(UseImpact)then
             open(UnitTmp_,file="TitanInput/magnetopara100evTatoub.txt",&
                  status="old")
             read(UnitTmp_,'(a)')linetitan
             do i=1,num_Ri
                read(UnitTmp_,*)tmp_hR(i),IMPACT_L(i),IMPACT_M(i),IMPACT_H(i)
             end do
             close(UnitTmp_)
          end if

          !for electron temperature
          open(UnitTmp_,file="TitanInput/T_e.dat",status="old")
          read(UnitTmp_,*) (tmp_hT(i),tmp_Te(i),i=1,num_Te)
          close(UnitTmp_)

          !for resistivity
          nu_en(:,:)=0.0
          open(UnitTmp_,file="TitanInput/e_n_collision.dat",&
               status="old")             
          read(UnitTmp_,'(a)')linetitan
          !write(*,*)linetitan
          do i=1,num_en
             read(UnitTmp_,*)nu_Te(i),(nu_en(i,j),j=1,3)
          end do
          close(UnitTmp_)

          if(iproc==0)then
             write(*,*)'tmp_hR(num_Ri)',tmp_hR(num_Ri)
             write(*,*)'tmp_hn(num_nu)',tmp_hn(num_nu)
             write(*,*)'tmp_hT(num_Te)',tmp_hT(num_Te)              
          end if


       case('#POINTIMPLICITREGION')
          call read_var('rPointImplicit',rPointImplicit)

       case('#USECOSSZA')
          call read_var('UseCosSZA',UseCosSZA)

       case('#USERINPUTEND')
          if(iProc==0) write(*,*)'USERINPUTEND'
          EXIT
       case default
          if(iProc==0) call stop_mpi( &
               'read_inputs: unrecognized command: '//NameCommand)
       end select
    end do
  end subroutine user_read_inputs

  !============================================================================

  subroutine user_init_point_implicit

    use ModVarIndexes
    use ModPointImplicit, ONLY: iVarPointImpl_I, IsPointImplMatrixSet

    ! Allocate and set iVarPointImpl_I
    allocate(iVarPointImpl_I(11))

    iVarPointImpl_I = (/RhoLp_, RhoMp_, RhoH1p_, RhoH2p_, RhoMHCp_ ,&
         RhoHHCp_,RhoHNIp_ , RhoUx_, RhoUy_, RhoUz_, P_/)

    ! Note that energy is not an independent variable for the 
    ! point implicit scheme. The pressure is an independent variable,
    ! and in this example there is no implicit pressure source term.

    ! Tell the point implicit scheme if dS/dU will be set analytically
    ! If this is set to true the DsDu_VVC matrix has to be set below.
    IsPointImplMatrixSet = .false.

  end subroutine user_init_point_implicit

  !============================================================================

  subroutine user_calc_sources(iBlock)

    use ModAdvance,  ONLY: Source_VC
    use ModMain, ONLY: iTest, jTest, kTest, ProcTest, BlkTest
    use ModProcMH,   ONLY: iProc
    use ModPointImplicit, ONLY: UsePointImplicit_B, UsePointImplicit, &
         IsPointImplSource
    use ModPhysics, ONLY: Rbody
    use ModGeometry,ONLY: R_BLK

    integer, intent(in) :: iBlock

    logical :: oktest,oktest_me
    !------------------------------------------------------------------------  
    if(iProc==PROCtest .and. iBlock==BLKtest)then
       call set_oktest('user_calc_sources',oktest,oktest_me)
    else
       oktest=.false.; oktest_me=.false.
    end if
    if(UsePointImplicit)&
         UsePointImplicit_B(iBlock) = &
         R_BLK(1,1,1,iBlock) <= rPointImplicit &
         .and. R_BLK(nI,1,1,iBlock) > rBody

    if(.not.(UsePointImplicit .and. UsePointImplicit_B(iBlock)) )then
       ! Add all source terms if we do not use the point implicit 
       ! scheme for the Block
       call user_expl_source(iBlock)
       call user_impl_source(iBlock)

    elseif(IsPointImplSource)then
       ! Add implicit sources only
       call user_impl_source(iBlock)
    else
       ! Add explicit sources only
       call user_expl_source(iBlock)
    end if

    if(oktest_me)then
       write(*,*)'After Source(rho, rhoSp)=', &
            Source_VC(rho_:8,iTest,jTest,kTest)
       write(*,*)'Source(rhoU)=', Source_VC(9:11,iTest,jTest,kTest)
       write(*,*)'Source(B)=', Source_VC(12:14,iTest,jTest,kTest)
       write(*,*)'Source(p,E)', Source_VC(P_:P_+1,iTest,jTest,kTest)
    end if
  end subroutine user_calc_sources

  !==========================================================================

  subroutine user_sources(iBlock)

    use ModMain, ONLY: PROCTEST,BLKTEST, iTest,jTest,kTest 
    use ModAdvance,  ONLY: State_VGB,VdtFace_x,VdtFace_y,VdtFace_z
    use ModGeometry, ONLY:R_BLK
    use ModProcMH,   ONLY: iProc
    use ModPhysics,  ONLY: Rbody, InvGammaMinus1, GammaMinus1
    use ModBlockData,ONLY: use_block_data, put_block_data, get_block_data, &
         MaxBlockData
    use ModPointImplicit, ONLY: UsePointImplicit_B
    use BATL_lib, ONLY: CellVolume_GB

    integer, intent(in) :: iBlock

    ! Variables required by this user subroutine
    integer:: i,j,k,iSpecies,iBlockLast = -1
    real :: inv_rho, inv_rho2, uu2,kTi, kTe
    real :: totalPSNumRho=0.0,totalRLNumRhox=0.0, temps
    logical:: oktest,oktest_me
    real :: SourceLossMax, vdtmin
    real :: RhoUTimesSrhoU  !for output the testing results

    !
    !--------------------------------------------------------------------------
    !\
    ! Variable meanings:
    !   Srho: Source terms for the continuity equation
    !   SE,SP: Source terms for the energy (conservative) and presure
    !          (primative) equations
    !   SrhoUx,SrhoUy,SrhoUz:  Source terms for the momentum equation
    !   SBx,SBy,SBz:  Souce terms for the magnetic field equations 
    !/
    !--------------------------------------------------------------------------
    !
    if (iProc==PROCtest.and.iBlock==BLKtest) then
       call set_oktest('user_sources',oktest,oktest_me)
    else
       oktest=.false.; oktest_me=.false.
    end if

    !\
    ! Compute Titan ionospheric source terms.
    !/
    MaxBlockData = (1 + MaxNuSpecies + 2*MaxSpecies)*nIJK

    if(iBlock /= iBlockLast)then
       iBlockLast = iBlock
       if(use_block_data(iBlock))then
          call get_block_data(iBlock, nI, nJ, nK, Nu_C)
          call get_block_data(iBlock,MaxNuSpecies,nI, nJ, nK, NumDenNeutral_VC)
          call get_block_data(iBlock, MaxSpecies, nI, nJ, nK, PhotoIonRate_VC)
          call get_block_data(iBlock, MaxSpecies, nI, nJ, nK, RecombRate_VC)
       else
          call titan_input(iBlock)
          call put_block_data(iBlock, nI, nJ, nK, Nu_C)
          call put_block_data(iBlock,MaxNuSpecies,nI, nJ, nK, NumDenNeutral_VC)
          call put_block_data(iBlock, MaxSpecies, nI, nJ, nK, PhotoIonRate_VC)
          call put_block_data(iBlock, MaxSpecies, nI, nJ, nK, RecombRate_VC)
       end if
    end if

    if (R_BLK(1,1,1,iBlock) > 5.0*Rbody) RETURN

    do k = 1, nK ;   do j = 1, nJ ;  do i = 1, nI

       if (R_BLK(i,j,k,iBlock) < Rbody) CYCLE

       inv_rho = 1.00/State_VGB(rho_,i,j,k,iBlock)
       inv_rho2 = inv_rho*inv_rho
       uu2 =(State_VGB(Ux_,i,j,k,iBlock)*State_VGB(Ux_,i,j,k,iBlock)  &
            +State_VGB(Uy_,i,j,k,iBlock)*State_VGB(Uy_,i,j,k,iBlock)  &
            +State_VGB(Uz_,i,j,k,iBlock)*State_VGB(Uz_,i,j,k,iBlock)) &
            *inv_rho2

       ReactionRate_I=0.0
       CoeffSpecies_II(:,:)=0.0
       LossSpecies_I=0.0
       totalNumRho=0.0
       !          dStndRho_I=0.0
       !          dLtdRho_I=0
       !          dLtndNumRho_I=0
       SiSpecies_I(:)=0.0
       LiSpecies_I(:)=0.0
       do iSpecies=1, nSpecies
          totalNumRho=totalNumRho  &
               +State_VGB(rho_+iSpecies,i,j,k,iBlock) &
               /MassSpecies_V(rho_+iSpecies)
       enddo
       
       !charge exchange
       
       ReactionRate_I(Lp_CH4__H1p_X_ )= &
            Rate_I(Lp_CH4__H1p_X_ )&
            * NumDenNeutral_VC(CH4_,i,j,k)
       CoeffSpecies_II(H1p_,Lp_)=ReactionRate_I(Lp_CH4__H1p_X_ )

       ReactionRate_I(Lp_N2__Mp_X_ )= &
            Rate_I(Lp_N2__Mp_X_ )&
            * NumDenNeutral_VC(N2_,i,j,k)
       CoeffSpecies_II(Mp_,Lp_)=ReactionRate_I(Lp_N2__Mp_X_ )

       ReactionRate_I(Mp_CH4__H2p_X_ )= &
            Rate_I( Mp_CH4__H2p_X_ )&
            * NumDenNeutral_VC(CH4_,i,j,k)
       CoeffSpecies_II(H2p_,Mp_)=ReactionRate_I(Mp_CH4__H2p_X_)

       ReactionRate_I(Mp_C2H4__H1p_X_  )= &
            Rate_I(Mp_C2H4__H1p_X_  )&
            * NumDenNeutral_VC(C2H4_,i,j,k)
       ReactionRate_I(Mp_C2H6__H1p_X_  )= &
            Rate_I(Mp_C2H6__H1p_X_  )&
            * NumDenNeutral_VC(C2H6_,i,j,k)
       CoeffSpecies_II(H1p_,Mp_)=ReactionRate_I(Mp_C2H6__H1p_X_  )&
            +ReactionRate_I(Mp_C2H4__H1p_X_  )


       ReactionRate_I(H1p_HCN__H2p_X_   )= &
            Rate_I(H1p_HCN__H2p_X_  )&
            * NumDenNeutral_VC(HCN_,i,j,k)
       CoeffSpecies_II(H2p_,H1p_)=ReactionRate_I(H1p_HCN__H2p_X_ )

       ReactionRate_I(H1p_HC3N__HNIp_X_    )= &
            Rate_I(H1p_HC3N__HNIp_X_   )&
            * NumDenNeutral_VC(HC3N_,i,j,k)
       CoeffSpecies_II(HNIp_,H1p_)=ReactionRate_I(H1p_HC3N__HNIp_X_ )

       ReactionRate_I( H1p_C2H2__MHCp_X_  )= &
            Rate_I(H1p_C2H2__MHCp_X_  )&
            * NumDenNeutral_VC(C2H2_,i,j,k)
       ReactionRate_I(H1p_C2H4__MHCp_X_   )= &
            Rate_I(H1p_C2H4__MHCp_X_  )&
            * NumDenNeutral_VC(C2H4_,i,j,k)
       CoeffSpecies_II(MHCp_,H1p_)=ReactionRate_I(H1p_C2H4__MHCp_X_ )&
            +ReactionRate_I(H1p_C2H2__MHCp_X_ )

       ReactionRate_I(H2p_HC3N__HNIp_X_   )= &
            Rate_I(H2p_HC3N__HNIp_X_  )&
            * NumDenNeutral_VC(HC3N_,i,j,k)
       CoeffSpecies_II(HNIp_,H2p_)=ReactionRate_I(H2p_HC3N__HNIp_X_ )

       ReactionRate_I( H2p_C4H2__MHCp_X_  )= &
            Rate_I(H2p_C4H2__MHCp_X_  )&
            * NumDenNeutral_VC(C4H2_,i,j,k)
       CoeffSpecies_II(MHCp_,H2p_)=ReactionRate_I(H2p_C4H2__MHCp_X_  )

       ReactionRate_I( MHCp_C2H2__HHCp_X_  )= &
            Rate_I(MHCp_C2H2__HHCp_X_  )&
            * NumDenNeutral_VC(C2H2_,i,j,k)
       ReactionRate_I( MHCp_C2H4__HHCp_X_)= &
            Rate_I(MHCp_C2H4__HHCp_X_ )&
            * NumDenNeutral_VC(C2H4_,i,j,k)
       ReactionRate_I(MHCp_C3H4__HHCp_X_  )= &
            Rate_I(MHCp_C3H4__HHCp_X_  )&
            * NumDenNeutral_VC(C3H4_,i,j,k)
       ReactionRate_I(MHCp_C4H2__HHCp_X_ )= &
            Rate_I(MHCp_C4H2__HHCp_X_ )&
            * NumDenNeutral_VC(C4H2_,i,j,k)
       CoeffSpecies_II(HHCp_,MHCp_)=ReactionRate_I(MHCp_C2H2__HHCp_X_  )&
            +ReactionRate_I( MHCp_C2H4__HHCp_X_)&
            +ReactionRate_I(MHCp_C3H4__HHCp_X_)&
            +ReactionRate_I(MHCp_C4H2__HHCp_X_)

       ! Recombination
       !end if  !(x>0.0)

       do iSpecies=1, nSpecies
          LossSpecies_I=LossSpecies_I &
               +CoeffSpecies_II(iSpecies, :)
          !                dStndRho_I=dStndRho_I  &
          !                     +CoeffSpecies_II(iSpecies, :)/MassSpecies_V(:)
          dSdRho_II(1:nSpecies, iSpecies)= &
               CoeffSpecies_II(1:nSpecies, iSpecies)&
               *MassSpecies_V(rho_+1:rho_+nSpecies)&
               /MassSpecies_V(rho_+iSpecies)

       enddo

!!!              do iSpecies=1, nSpecies
!!!                 dLdRho_II(1:nSpecies, iSpecies)=Recb_I(1:nSpecies)&
!!!                      *rhoSpecies_GBI(i,j,k,iBlock,1:nSpecies) &
!!!                      /MassSpecies_V(iSpecies)
!!!                 dLdRho_II(iSpecies, iSpecies)=  &
!!!                      dLdRho_II(iSpecies, iSpecies) &
!!!                      +LossSpecies_I(iSpecies)  &
!!!                      +Recb_I(iSpecies)*totalNumRho
!!!              enddo
!!!              !              dSLdRho_II=dSdRho_II-dLdRho_II
!!!
!!!              do iSpecies=1, nSpecies
!!!                 dLtdRho_I(:)=dLtdRho_I(:) +dLdRho_II(iSpecies,:)
!!!                 dLtndNumRho_I(:)=dLtndNumRho_I(:) &
!!!                      +dLdRho_II(iSpecies,:)*MassSpecies_V(:)/MassSpecies_V(iSpecies)
!!!              enddo              

       SiSpecies_I(:)=PhotoIonRate_VC(:,i,j,k)*MassSpecies_V(:)

       do iSpecies=1, nSpecies
          SiSpecies_I(1:nSpecies)=&
               SiSpecies_I(1:nSpecies)  &
               +dSdRho_II(1:nSpecies, iSpecies) &
               *State_VGB(rho_+iSpecies, i,j,k, iBlock)
          LiSpecies_I(iSpecies)= &
               LiSpecies_I(iSpecies)+(LossSpecies_I(iSpecies) &
               +RecombRate_VC(iSpecies,i,j,k)*totalNumRho)&
               *State_VGB(rho_+iSpecies, i,j,k, iBlock)
       enddo


       totalLossRho=sum(LiSpecies_I(1:nSpecies))    
       !sum of the (Loss term) of all ion species
       totalSourceRho=sum(SiSpecies_I(1:nSpecies))    
       !sum of the (Source term) of all ion species
       totalLossNumRho=sum(LiSpecies_I(1:nSpecies)&
            /MassSpecies_V(SpeciesFirst_:SpeciesLast_))   
       !sum of the (loss term/atom mass) of all ..
       totalSourceNumRho=sum(SiSpecies_I(1:nSpecies)&
            /MassSpecies_V(SpeciesFirst_:SpeciesLast_))
       ! sum of the (Source term/atom mass) of all..
       totalLossx=totalLossRho*inv_rho
       totalLossNumx=totalLossNumRho/totalNumRho
       totalPSNumRho=sum(PhotoIonRate_VC(:,i,j,k)) 
       ! sum of the photonionziation source/atom mass) of all..
       totalRLNumRhox=sum(RecombRate_VC(:,i,j,k) &
            *State_VGB(rho_+1:rho_+nSpecies, i,j,k, iBlock)/MassSpecies_V)

       !          if(.not.(UsePointImplicit .and. UsePointImplicit_B(iBlock)) )then
       if(.not.UsePointImplicit_B(iBlock) )then
          !sum of the (loss term/atom mass) due to recombination
          SourceLossMax = 3.0*maxval(abs(SiSpecies_I(1:nSpecies)+&
               LiSpecies_I(1:nSpecies) ) /&
               (State_VGB(rho_+1:rho_+nSpecies, i,j,k, iBlock)+1e-20))&
               *CellVolume_GB(i,j,k,iBlock)
          vdtmin=min(VdtFace_x(i,j,k),VdtFace_y(i,j,k),VdtFace_z(i,j,k))
          if(SourceLossMax > Vdtmin) then
             !UsePointImplicit_B(iBlock)=.true.
             !write(*,*)'should use Point-implicit or increase its region'
             VdtFace_x(i,j,k) = max (SourceLossMax, VdtFace_x(i,j,k) )
             VdtFace_y(i,j,k) = max (SourceLossMax, VdtFace_y(i,j,k) )
             VdtFace_z(i,j,k) = max (SourceLossMax, VdtFace_z(i,j,k) )
          end if
       end if
       !             if(Rmin_BLK(iBlock) <= 2.0*Rbody) then
       !          end if

       SrhoSpecies(1:nSpecies,i,j,k)=SrhoSpecies(1:nSpecies,i,j,k)&
            +SiSpecies_I(1:nSpecies) &
            -LiSpecies_I(1:nSpecies)

       Srho(i,j,k)=Srho(i,j,k)&
            +sum(SiSpecies_I(1:MaxSpecies))&
            -sum(LiSpecies_I(1:MaxSpecies))

       SrhoUx(i,j,k) = SrhoUx(i,j,k) &
            -State_VGB(Ux_,i,j,k,iBlock)*totalLossx  

       SrhoUy(i,j,k) = SrhoUy(i,j,k)  &
            -State_VGB(Uy_,i,j,k,iBlock)*totalLossx 

       SrhoUz(i,j,k) = SrhoUz(i,j,k)  &
            -State_VGB(Uz_,i,j,k,iBlock)*totalLossx 

       SrhoUx(i,j,k) = SrhoUx(i,j,k) &
            -Nu_C(i,j,k)*State_VGB(Ux_,i,j,k,iBlock)
       SrhoUy(i,j,k) = SrhoUy(i,j,k)  &
            -Nu_C(i,j,k)*State_VGB(Uy_,i,j,k,iBlock)
       SrhoUz(i,j,k) = SrhoUz(i,j,k)  &
            -Nu_C(i,j,k)*State_VGB(Uz_,i,j,k,iBlock)

       kTi = State_VGB(p_,i,j,k,iBlock)/totalNumRho/2.0
       kTe = kTi

       if(UseOldEnergy)then          
          SE(i,j,k) = SE(i,j,k)  &
               -0.5*State_VGB(rho_,i,j,k,iBlock)*uu2*Nu_C(i,j,k) 
          
          SE(i,j,k) = SE(i,j,k)  &
               +InvGammaMinus1*(totalSourceNumRho*kTn-totalLossNumRho*kTi) &
               -0.50*uu2*(totalLossRho) &
               +1.5*totalNumRho*(kTn-KTi)*Nu_C(i,j,k)
          
          SP(i,j,k) = SP(i,j,k)  &
               +0.5*GammaMinus1*State_VGB(rho_,i,j,k,iBlock)*uu2*&
               Nu_C(i,j,k)  &
               +(totalSourceNumRho*kTn-totalLossNumRho*kTi) &
               +0.50*GammaMinus1*uu2*(totalSourceRho) &
               +totalNumRho*(kTn-KTi)*Nu_C(i,j,k)
       else

          temps = totalSourceNumRho*kTn            &
               + totalNumRho*(kTn-KTi)*Nu_C(i,j,k) &
               + totalPSNumRho*kTe0                &
               - totalLossNumRho*kTi               &
               - totalRLNumRhox*totalNumRho*KTe
          
          if(UseTempControl.and.kTi > kT1000)&
               temps = temps+totalNumRho*(kT1000-KTi)*Nu_C(i,j,k)*5.0
          
          SE(i,j,k) = SE(i,j,k)  &
               -0.5*State_VGB(rho_,i,j,k,iBlock)*uu2*&
               Nu_C(i,j,k)  &
               -0.50*uu2*(totalLossRho) &
               +InvGammaMinus1*temps
             
          SP(i,j,k) = SP(i,j,k)  &
               +0.5*GammaMinus1*State_VGB(rho_,i,j,k,iBlock)*uu2*&
               Nu_C(i,j,k)  &
               +0.50*GammaMinus1*uu2*(totalSourceRho) &
               +temps
       end if
  
    end do; end do; end do     ! end of the i,j,k loop
    if(oktest_me)then
       RhoUTimesSrhoU = State_VGB(Ux_,itest,jtest,ktest,iBlock)*&
            SrhoUx(itest,jtest,ktest)&
            +State_VGB(Uy_,itest,jtest,ktest,iBlock)*&
            SrhoUy(itest,jtest,ktest)&
            +State_VGB(Uz_,itest,jtest,ktest,iBlock)*&
            SrhoUz(itest,jtest,ktest)

       uu2 = sum(State_VGB(Ux_:Uz_,itest,jtest,ktest,iBlock)&
            *State_VGB(Ux_:Uz_,itest,jtest,ktest,iBlock))/&
            State_VGB(rho_,itest,jtest,ktest,iBlock)/&
            State_VGB(rho_,itest,jtest,ktest,iBlock)

       write(*,*)'rhosp=        ',State_VGB(rho_:8,itest,jtest,ktest,iBlock)

       write(*,*)'srho=         ',Srho(itest,jtest,ktest)
       write(*,*)'state_VGB(u2)=',uu2
       write(*,*)'srho*uu2/2=   ',Srho(itest,jtest,ktest)*uu2/2

       write(*,*)'srhoUx=', SrhoUx(itest,jtest,ktest), &
            'srhoUy=', SrhoUy(itest,jtest,ktest),&
            'srhoUz=', SrhoUz(itest,jtest,ktest)

       write(*,*)'u.srhoU=',&
            RhoUTimesSrhoU/State_VGB(rho_,itest,jtest,ktest,iBlock)

       write(*,*)'se=        ',SE(itest,jtest,ktest)
       write(*,*)'InvGammaMinus1*sp=',InvGammaMinus1*SP(itest,jtest,ktest)
       write(*,*)'InvGammaMinus1*sp+u.srhoU-srho*uu2/2 =',&
            InvGammaMinus1*SP(itest,jtest,ktest) &
            +RhoUTimesSrhoU/State_VGB(rho_,itest,jtest,ktest,iBlock)&
            -Srho(itest,jtest,ktest)*uu2/2

       write(*,*)'state_VGB(B)=',&
            State_VGB(Bx_:Bz_,itest,jtest,ktest,iBlock) 
       write(*,*)'state_VGB(P)=',&
            State_VGB(p_,itest,jtest,ktest,iBlock) 

    end if

  end subroutine user_sources

  !==============================================================================
  subroutine user_init_session
    use ModSize, ONLY: nDim
    use ModMain, ONLY: Body1_, ExtraBc_, &
         Coord1MinBc_, Coord3MaxBc_, xMinBc_, zMaxBc_
    use ModPhysics
    use ModVarIndexes, ONLY: ScalarFirst_,ScalarLast_, &
         rhoUx_, rhoUz_,  UnitUser_V
    integer::iBoundary
    !--------------------------------------------------------------------------
    !For Outer Boundaries
    AverageIonCharge         = 1.0
    ElectronTemperatureRatio = 1.0   !default was 0.0

    do iBoundary=xMinBc_, zMaxBc_
       FaceState_VI(ScalarFirst_:ScalarLast_,iBoundary)  = cTiny8/1.0e5     
       !  FaceState_VI(ScalarFirst_:ScalarLast_,iBoundary)  = 0.0
       FaceState_VI(RhoLp_,iBoundary)=SW_LP
       FaceState_VI(RhoMp_,iBoundary)=SW_MP
       FaceState_VI(Rho_,iBoundary)=FaceState_VI(RhoLp_,iBoundary)+&
            FaceState_VI(RhoMp_,iBoundary)
    end do
    call set_multiSp_ICs  
    !    Rbody = 1.0 + 725.0e3/RTitan
    BodyRho_I(1) = sum(BodyRhoSpecies_I(1:nSpecies))
    BodyP_I(1) =max(sw_p, sum(BodyRhoSpecies_I(1:nSpecies)&
         /MassSpecies_V(SpeciesFirst_:SpeciesLast_))*kTp0)
    FaceState_VI(rho_,body1_)=BodyRho_I(1)
    FaceState_VI(ScalarFirst_:ScalarLast_,body1_) = BodyRhoSpecies_I
    FaceState_VI(P_,body1_)=BodyP_I(1)
    
    CellState_VI = FaceState_VI(:,xMinBc_:zMaxBc_)
    do iBoundary=1,2*nDim 
       CellState_VI(rhoUx_:rhoUz_,iBoundary) = &
            FaceState_VI(Ux_:Uz_,iBoundary)*FaceState_VI(rho_,iBoundary)
    end do

    UnitUser_V(ScalarFirst_:ScalarLast_) = No2Io_V(UnitRho_)/MassSpecies_V

  end subroutine user_init_session

  !======================================================================

  subroutine user_set_ICs(iBlock)

    use ModMain, ONLY: Body1_,itest,jtest,ktest,BLKtest,Coord1MinBc_
    use ModAdvance
    use ModGeometry, ONLY :Xyz_DGB,R_BLK
    use ModIO, ONLY : restart
    use ModPhysics
    use ModMultiFluid

    integer, intent(in) :: iBlock

    real ::CosSZA, hh
    integer :: i,j,k,n, m
    real :: dtm, dtmp1
    real,dimension(1:MaxSpecies) :: coefx, coefy
    logical :: oktest_me=.true.
    !-------------------------------------------------------------------------

    if(.not.restart)then
       !\
       ! Initialize solution quantities.
       !/

       do k=MinK,MaxK;do j=MinJ,MaxJ; do i=MinI,MaxI
          if (R_BLK(i,j,k,iBlock)< Rbody) then
             State_VGB(:,i,j,k,iBlock) = FaceState_VI(:,body1_)
             ! Convert velocity to momentum                            
             do iFluid = 1, nFluid
                call select_fluid
                State_VGB(iRhoUx,i,j,k,iBlock) = &
                     FaceState_VI(iUx,body1_)*FaceState_VI(iRho,body1_)
                State_VGB(iRhoUy,i,j,k,iBlock) = &
                     FaceState_VI(iUy,body1_)*FaceState_VI(iRho,body1_)
                State_VGB(iRhoUz,i,j,k,iBlock) = &
                     FaceState_VI(iUz,body1_)*FaceState_VI(iRho,body1_)
             end do
          else
             State_VGB(:,i,j,k,iBlock)   = CellState_VI(:,Coord1MinBc_)
             !State_VGB(Bx_:Bz_,i,j,k,iBlock)=0.0
          end if
       end do;end do; end do;

       coefy=BodyRhoSpecies_dim_II(:,1)/tmp_ion(:,1)           

       do k=MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
          cosSZA=(Xyz_DGB(x_,i,j,k,iBlock)*SX0 &
               + Xyz_DGB(y_,i,j,k,iBlock)*SY0 &
               + Xyz_DGB(z_,i,j,k,iBlock)*SZ0)&
               /max(R_BLK(i,j,k,iBlock),1.0e-3)

          ! Make sure these are set (printed in testing)
          dtm   = -1.0
          dtmp1 = -1.0
          m     = -1

          if(.not.UseCosSZA)then
             coefx=coefy
             if(cosSZA < 0.9)then
                do m=1,NumSZA
                   if((cosSZA < CosSZAB_I(m)).and.&
                        (cosSZA >= CosSZAB_I(m+1))) then
                      dtm = CosSZAB_I(m)- cosSZA
                      dtmp1 = CosSZA - CosSZAB_I(m+1)                   
                      coefx = coefy*(coefSZAB_II(:,m)*dtmp1+&
                           coefSZAB_II(:,m+1)*dtm)&
                           /(CosSZAB_I(m)-CosSZAB_I(m+1))

                   end if
                end do
             end if
          else
             coefx=2.0*cosSZA
             if(cosSZA < 0.5)then
                coefx =1.001+2.0/3.0*(cosSZA-0.5)
             end if
          end if

          if (R_BLK(i,j,k,iBlock)< Rbody)then
             State_VGB(rho_+1:rho_+nSpecies,i,j,k,iBlock)=&
                  BodyRhoSpecies_I(1:nSpecies)*coefx
          else
             hh = (R_BLK(i,j,k,iBlock)-1.00)*2575.0
             n= int((hh -725.0)/10.0+1.0)

             if(n<1) then 
                n=1
             else if(n> num_Ri-1) then
                n = num_Ri-1
             end if
             State_VGB(rho_+1:rho_+nSpecies,i,j,k,iBlock)=&
                  tmp_ion(:,n)+&
                  (tmp_ion(:,n+1)-tmp_ion(:,n))*&
                  (hh-tmp_hR(n))/(tmp_hR(n+1)-tmp_hR(n))

             State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock)= &
                  State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock)&
                  *coefx*MassSpecies_V(SpeciesFirst_:SpeciesLast_)/No2Io_V(UnitN_)

             State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock)=&
                  max(0.0,State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock))
             State_VGB(rhoLp_,i,j,k,iBlock)= SW_Lp
             State_VGB(rhoMp_,i,j,k,iBlock)=&
                  State_VGB(rhoMp_,i,j,k,iBlock)*&
                  (Rbody/R_BLK(i,j,k,iBlock))**2+ &
                  SW_Mp

          end if

          State_VGB(rho_,i,j,k,iBlock)   =&
               sum(State_VGB(rho_+1:rho_+MaxSpecies,i,j,k,iBlock))
          
          if (R_BLK(i,j,k,iBlock)< 2.0*Rbody)&
               State_VGB(Bx_:Bz_,i,j,k,iBlock)=0.0
          
          !State_VGB(ux_:uz_,i,j,k,iBlock)   = 0.0
          !&
          !               CellState_VI(ux_:Uz_,1)/CellState_VI(rho_,1)&
          !               *State_VGB(rho_,i,j,k,iBlock)
          State_VGB(P_,i,j,k,iBlock)= &
               sum(State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock)&
               /MassSpecies_V(SpeciesFirst_:SpeciesLast_))*KTp0
          
          if(R_BLK(i,j,k,iBlock).gt.2.0)&
               State_VGB(P_,i,j,k,iBlock)= &
               max(SW_p, State_VGB(P_,i,j,k,iBlock))
          

          if(oktest_me.and.&
               iBlock==Blktest.and.i==itest.and.j==jtest.and.k==ktest)then
             write(*,*)'itest,jtest,ktest,blktest=',&
                  itest,jtest,ktest,blktest
             write(*,*)'coefx=', coefx
             write(*,*)'coefy=',coefy
             write(*,*)'cosSZA=', cosSZA
             write(*,*)'n=',n
             write(*,*)'rhoSpecies_GBI(i,j,k,iBlock,1:nSpecies)=',&
                  State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock)
             write(*,*)'CosSZAB_I(:)',CosSZAB_I
             write(*,*)'dtm, dtmp1,m=',dtm, dtmp1,m
             write(*,*)'p_BLK(testcell)=',State_VGB(P_,i,j,k,iBlock)
             write(*,*)'tmp_ion(:,n)=',tmp_ion(:,n)
             !call stop_mpi('test')
          end if

       end do; end do; end do

       time_BLK(:,:,:,iBlock) = 0.00

    end if

  end subroutine user_set_ICs

  !========================================================================
  subroutine set_multiSp_ICs

    ! Calculate the scale height of ion and neutal species and 
    ! intial boundary value of ion species

    use ModMain
    use ModConst
    use ModIO
    use ModPhysics

    integer:: iSpecies
    logical:: oktest_me=.false.
    !---------------------------------------------------------------

!    write(*,*)'cPi=', cPi
!    write(*,*)'SZATitan_I',SZATitan_I
!    write(*,*)'cosSZA_I',cosSZA_I
    CosSZA_I=cos(SZATitan_I*cPi/180.0)
    cosSZAB_I =cos(SZABTitan_I*cPi/180.0)     
    do iSpecies =1, nSpecies
       BodyRhoSpecies_I(iSpecies)=BodyRhoSpecies_dim_II(iSpecies,1)&
            *MassSpecies_V(rho_+iSpecies)/No2Io_V(UnitN_)
       coefSZAB_II(iSpecies,:)=BodyRhoSpecies_dim_II(iSpecies,:)&
            /BodyRhoSpecies_dim_II(iSpecies,1)
    end do
    if(UseCosSZA)then
       BodyRhoSpecies_I(:)=tmp_ion(1:nSpecies,1)*&
            MassSpecies_V(SpeciesFirst_:SpeciesLast_)/No2Io_V(UnitN_)
    end if
    if(oktest_me)then
       write(*,*)'tmp_ion(:,1)=',tmp_ion(1:nSpecies,1)
       write(*,*)'BodyRhoSpecies_dim_II(iSpecies,1)=',&
            BodyRhoSpecies_dim_II(:,1)
    end if


    KTn = body_Tn_dim*Si2No_V(UnitTemperature_) !normalized body neutral temperature
    kTi0=kTn                                    !normalized body ion temperature
    kTp0=2.0*kTn                                !normalized body plasma temperature
    kTe0=max(Te_new_dim, body_Tn_dim)*Si2No_V(UnitTemperature_)   
						!normalized newly created electron temperature
    kT1000=1000.*Si2No_V(UnitTemperature_)

!    KTn = body_Ti_dim*Si2No_V(UnitTemperature_) 
    
!    kTp0=kTn  !2.0*kT0

    nu0=nu0_dim*No2Io_V(UnitN_)*No2Io_V(UnitT_)

    Ratedim_I(M_hv__Mp_em_ )=1.0   !1
    Ratedim_I(H1_hv__H1p_em_)=1.0  !2
    Ratedim_I(L_hv__Lp_em_)=1.0    !3
    Ratedim_I(Lp_em__L_)=3.5e-12   !4
    Ratedim_I(Mp_em__M_)=7.0e-7    !5 
    Ratedim_I(H1p_em__H1_)=1.9e-6
    Ratedim_I(H2p_em__H2_)=6.4e-7
    Ratedim_I(MHCp_em__MHC_)=1.0e-6
    Ratedim_I(HHCp_em__HHC_)=1.0e-6
    Ratedim_I(HNIp_em__HNI_)=1.0e-6   !10
    Ratedim_I(Lp_CH4__H1p_X_)=1.3e-9
    Ratedim_I(Lp_N2__Mp_X_  )=4.0e-10
    Ratedim_I(Mp_CH4__H2p_X_  )=1.0e-11
    Ratedim_I(Mp_C2H4__H1p_X_  )=1.5e-9
    Ratedim_I( Mp_C2H6__H1p_X_ )=2.0e-10 !15
    Ratedim_I(H1p_HCN__H2p_X_  )=2.7e-9
    Ratedim_I(H1p_HC3N__HNIp_X_  )=3.6e-9
    Ratedim_I(H1p_C2H2__MHCp_X_ )=1.0e-10
    Ratedim_I(H1p_C2H4__MHCp_X_  )=3.9e-10
    Ratedim_I(H2p_HC3N__HNIp_X_ )=3.4e-9   !20
    Ratedim_I(H2p_C4H2__MHCp_X_  )=1.6e-9
    Ratedim_I(MHCp_C2H2__HHCp_X_ )=4.0e-10
    Ratedim_I(MHCp_C2H4__HHCp_X_ )=2.0e-10
    Ratedim_I(MHCp_C3H4__HHCp_X_ )=6.0e-10
    Ratedim_I(MHCp_C4H2__HHCp_X_ )=4.0e-10  !25

    ion_name_I(Lp_ ) ='Lp  '
    ion_name_I(Mp_ ) ='Mp  '
    ion_name_I(H1p_ ) ='H1p  '
    ion_name_I(H2p_ ) ='H2p  '
    ion_name_I(MHCp_ ) ='MHCp  '
    ion_name_I(HHCp_ ) ='HHCp  '
    ion_name_I(HNIp_ ) ='HNIp  '

    BodynDenNuSpdim_I(:)=tmp_n(1:nNuSpecies,1)
    BodynDenNuSpecies_I(1:nNuSpecies)=&
         BodynDenNuSpdim_I(1:nNuSpecies)/No2Io_V(UnitN_)

    Rate_I(4:25)=Ratedim_I(4:25)*No2Io_V(UnitT_)*No2Io_V(UnitN_)

  end subroutine set_multiSp_ICs

  !============================================================================

  subroutine user_set_face_boundary(VarsGhostFace_V)

    use ModAdvance,  ONLY: nVar
    use ModFaceBoundary, ONLY: VarsTrueFace_V, FaceCoords_D

    real, intent(out):: VarsGhostFace_V(nVar)

    real:: XFace,YFace,ZFace, rFace, rFace2
    real:: cosSZA
    real,dimension(1:MaxSpecies) :: coefx
    real :: dtm, dtmp1
    integer :: m
    real:: uDotR, bDotR

    !--------------------------------------------------------------------------
    XFace = FaceCoords_D(1)
    YFace = FaceCoords_D(2)
    ZFace = FaceCoords_D(3)

    rFace2 = XFace**2 + YFace**2 + ZFace**2
    rFace  = sqrt(rFace2)

    !Apply boundary conditions
    cosSZA = (XFace*SX0 + YFace*SY0 + ZFace*SZ0)/max(RFace,1.0e-3)

    if(.not.UseCosSZA)then
       coefx=1.0
       if(cosSZA.lt.0.95)then
          do m=1,NumSZA
             if((cosSZA < CosSZAB_I(m)).and.&
                  (cosSZA >= CosSZAB_I(m+1))) then
                dtm = CosSZAB_I(m)- cosSZA
                dtmp1 = cosSZA - CosSZAB_I(m+1)                
                coefx = (coefSZAB_II(:,m)*dtmp1+&
                     coefSZAB_II(:,m+1)*dtm)&
                     /(CosSZAB_I(m)-CosSZAB_I(m+1))

             end if
          end do
       end if
    else
       coefx=2.0*cosSZA
       if(cosSZA.lt.0.5)then
          coefx =1.001+2.0/3.0*(cosSZA-0.5)
       end if
    end if
    VarsGhostFace_V(rho_+1:rho_+nSpecies) = &
         BodyRhoSpecies_I(1:nSpecies)*coefx

    VarsGhostFace_V(rho_) = sum(VarsGhostFace_V(rho_+1:rho_+nSpecies))
    VarsGhostFace_V(P_)=sum(VarsGhostFace_V(rho_+1:rho_+nSpecies)&
         /MassSpecies_V(SpeciesFirst_:SpeciesLast_))*kTp0

    ! Reflective in radial direction
    uDotR = sum(VarsTrueFace_V(Ux_:Uz_)*FaceCoords_D)/rFace2
    bDotR = sum(VarsTrueFace_V(Bx_:Bz_)*FaceCoords_D)/rFace2

    select case (type_innerbcs)
    case('float')
       VarsGhostFace_V(Ux_:Uz_)= VarsTrueFace_V(Ux_:Uz_)
       VarsGhostFace_V(Bx_:Bz_)= VarsTrueFace_V(Bx_:Bz_)
    case('reflect')
       VarsGhostFace_V(Ux_:Uz_) = &
            VarsTrueFace_V(Ux_:Uz_) - 2*uDotR*FaceCoords_D
       VarsGhostFace_V(Bx_:Bz_) = &
            VarsTrueFace_V(Bx_:Bz_) - 2*bDotR*FaceCoords_D
    case('zeroB')
       VarsGhostFace_V(Ux_:Uz_) = &
            VarsTrueFace_V(Ux_:Uz_) - 2*uDotR*FaceCoords_D
       VarsGhostFace_V(Bx_:Bz_) = 0.0
    case('default')
       write(*,*)'unknown type of user inner bcs'
    end select

    !\
    ! Apply corotation?
    !/
    !if (UseRotatingBcHere) then
    !   call calc_corotation_velocities(FaceCoords_D, v_phi)
    !   VarsGhostFace_V(Ux_:Uz_) = VarsGhostFace_V(Ux_:Uz_)  + 2*v_phi
    !end if

  end subroutine user_set_face_boundary

  !============================================================================
  real function neutral_density(R0,iNu)
    use ModPhysics, ONLY :Rbody,cZero

    real, intent(in) :: R0
    integer, intent(in) :: iNu

    !-----------------------------------------------------------------------
    neutral_density = cZero
    if( R0 >= 0.9*Rbody .and. R0< 3.0*Rbody ) &
         neutral_density= exp(-(R0-Rbody)/HNuSpecies_I(iNu))

  end function neutral_density
  !============================================================================
  subroutine titan_input(iBlock)
    use ModPhysics
    use ModGeometry

    integer, intent(in):: iBlock

    !  integer, parameter :: num_Te = 9500, num_Ri = 9496, num_n = 9500
    real, parameter :: TINY=1.0E-4 
    !  real, dimension(1:num_n) :: tmp_rn, tmp_hn, tmp_nL, tmp_nM, tmp_nH
    !  real, dimension(1:num_Te) :: tmp_hT, tmp_Te
    !  real, dimension(1:num_Ri) :: tmp_hR, tmp_RL0, tmp_RM0,tmp_RH0
    real, dimension(1:nI,1:nJ,1:nK) :: Te_C, RateM_C, RateH_C, RateL_C 
    real :: hh, cosS0, dhn,dhnp1, dtm, dtmp1
    integer :: i,j,k,n, m

    !------ Interpolation/Expolation for Te,nL,nM,nH,RM0,RH0 ----- 
    !------ Original data units are as follows -----------------
    !Radius (km)     Number Density (cm^-3)
    !                 Light   Med.   Heavy
    !---------------------------------------


    !Altitude (km)       Te (k)
    !---------------------------------------


    !Altitude (km)   Ion Prod. Rates (cm^-3 S^-1)
    !                  Light   Med.   Heavy
    !---------------------------------------


!!!!!-------------------------- Interpolation/Expolation for Te ---------------------
    !     open(1,file="T_e.dat",status="old")
    !     read(1,*) (tmp_hT(i),tmp_Te(i),i=1,num_Te)
    !     close(1)


    if (R_BLK(1,1,1,iBlock) > 5.0*Rbody) RETURN
    Te_C          = 0.0
    RecombRate_VC = 0.0

    do k=1,nK;do j=1,nJ; do i=1,nI
       if (R_BLK(i,j,k,iBlock) >= Rbody) then
          hh = (R_BLK(i,j,k,iBlock)-1.00)*2575.0
          do n=1,num_Te-1
             if ((hh <= tmp_hT(n+1)) .and. (hh > tmp_hT(n))) then
                Te_C(i,j,k) = tmp_Te(n) + (tmp_Te(n+1)-tmp_Te(n))*(hh-tmp_hT(n))/ &
                     (tmp_hT(n+1)-tmp_hT(n))
             end if
          end do
          if (hh <= tmp_hT(1)) Te_C(i,j,k) = tmp_Te(1) + (tmp_Te(1)-tmp_Te(2))* &
               (tmp_hT(1)-hh)/(tmp_hT(2)-tmp_hT(1))

          if (hh >= tmp_hT(num_Te)) Te_C(i,j,k) = tmp_Te(num_Te) 

          if (Te_C(i,j,k) < 0.0) Te_C(i,j,k) = 200.0

          RecombRate_VC(Lp_,i,j,k)=Rate_I(Lp_em__L_ )
          RecombRate_VC(Mp_,i,j,k) = Rate_I(Mp_em__M_ )
          RecombRate_VC(H1p_,i,j,k) = Rate_I(H1p_em__H1_ )
          RecombRate_VC(H2p_,i,j,k) = Rate_I(H2p_em__H2_ )
          RecombRate_VC(MHCp_,i,j,k) = Rate_I(MHCp_em__MHC_ )
          RecombRate_VC(HHCp_,i,j,k) = Rate_I(HHCp_em__HHC_ )
          RecombRate_VC(HNIp_,i,j,k) = Rate_I(HNIp_em__HNI_ )
          RecombRate_VC(:,i,j,k) = RecombRate_VC(:,i,j,k)*sqrt(300.0/Te_C(i,j,k))

          !                    write(*,*)'i,j,k,iBlock=',i,j,k,iBlock,Rate_I(mep_em__me_),Rate_I(hap_em__ha_),&
          !                         'recb=',Recb_I(i,j,k,iBlock,mep_), Recb_I(i,j,k,iBlock,hap_)
       end if
    end do;end do; end do

!!!!!----------------- Interpolation/Expolation for ionization rates ----------------
    !     open(1,file="ion_prod_rate.dat",status="old")
    !     read(1,*) (tmp_hR(i),tmp_RL0(i),tmp_RM0(i),tmp_RH0(i),i=1,num_Ri)
    !     close(1)
    RateL_C         = 0.0
    RateM_C         = 0.0
    RateH_C         = 0.0
    PhotoIonRate_VC = 0.0

    do k=1,nK;do j=1,nJ; do i=1,nI
       if (R_BLK(i,j,k,iBlock) < Rbody) CYCLE

       hh = (R_BLK(i,j,k,iBlock)-1.00)*2575.0
       n= int((hh -725.0)/10.0+1.0)
       if(n<1) then 
          n=1
       else if(n> num_Ri-1) then
          n = num_Ri-1
       end if

       dhn = hh - tmp_hR(n)
       dhnp1 = tmp_hR(n+1) - hh

       cosS0=(Xyz_DGB(x_,i,j,k,iBlock)*SX0  & 
            + Xyz_DGB(y_,i,j,k,iBlock)*SY0  &
            + Xyz_DGB(z_,i,j,k,iBlock)*SZ0 )&
            /max(R_BLK(i,j,k,iBlock),1.0e-3)

       if (cosS0 < CosSZA_I(NumSZA)) then
          m=NumSZA
          !                    dhn = hh - tmp_hR(n)
          !                    dhnp1 = tmp_hR(n+1) - hh
          dtm = CosSZA_I(m)- cosS0
          dtmp1 = cosS0+1.001
          RateL_C(i,j,k) = (tmp_RL0(m,n  )*dhnp1*dtmp1 &
               +            tmp_RL0(m,n+1)*dhn  *dtmp1)&
               /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)+1.001)

          RateM_C(i,j,k) = (tmp_RM0(m,n  )*dhnp1*dtmp1 &
               +            tmp_RM0(m,n+1)*dhn  *dtmp1)&
               /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)+1.001)

          RateH_C(i,j,k) = (tmp_RH0(m,n  )*dhnp1*dtmp1 &
               +            tmp_RH0(m,n+1)*dhn  *dtmp1)&
               /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)+1.001)                    

       else if (cosS0 > cosSZA_I(1)) then                    
          m=1
          dtm = CosSZA_I(m)- cosS0
          dtmp1 = cosS0 - CosSZA_I(m+1)
          RateL_C(i,j,k) = (tmp_RL0(m,n  )*dhnp1*dtmp1 &
               +            tmp_RL0(m,n+1)*dhn  *dtmp1 &
               +            tmp_RL0(m+1,n  )*dhnp1*dtm   &
               +            tmp_RL0(m+1,n+1)*dhn  *dtm)  &
               /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)-CosSZA_I(m+1))
          RateM_C(i,j,k) = (tmp_RM0(m,n  )*dhnp1*dtmp1 &
               +            tmp_RM0(m,n+1)*dhn  *dtmp1 &
               +            tmp_RM0(m+1,n  )*dhnp1*dtm   &
               +            tmp_RM0(m+1,n+1)*dhn  *dtm)  &
               /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)-CosSZA_I(m+1))

          RateH_C(i,j,k) = (tmp_RH0(m,n  )*dhnp1*dtmp1 &
               +            tmp_RH0(m,n+1)*dhn  *dtmp1 &
               +            tmp_RH0(m+1,n  )*dhnp1*dtm &
               +            tmp_RH0(m+1,n+1)*dhn  *dtm)&
               /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)-CosSZA_I(m+1))

       else                    
          do m=1,NumSZA-1
             if((cosS0 <= CosSZA_I(m)).and.(cosS0 > CosSZA_I(m+1))) then
                !                          dhn = hh - tmp_hR(n)
                !                          dhnp1 = tmp_hR(n+1) - hh
                dtm = CosSZA_I(m)- cosS0
                dtmp1 = cosS0 - CosSZA_I(m+1)
                RateL_C(i,j,k) = &
                     (tmp_RL0(m  ,n)*dhnp1*dtmp1+tmp_RL0(m  ,n+1)*dhn*dtmp1 &
                     +tmp_RL0(m+1,n)*dhnp1*dtm  +tmp_RL0(m+1,n+1)*dhn*dtm  )&
                     /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)-CosSZA_I(m+1))
                RateM_C(i,j,k) = &
                     (tmp_RM0(m  ,n)*dhnp1*dtmp1+tmp_RM0(m  ,n+1)*dhn*dtmp1 &
                     +tmp_RM0(m+1,n)*dhnp1*dtm  +tmp_RM0(m+1,n+1)*dhn*dtm  )&
                     /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)-CosSZA_I(m+1))
                RateH_C(i,j,k) = &
                     (tmp_RH0(m  ,n)*dhnp1*dtmp1+tmp_RH0(m  ,n+1)*dhn*dtmp1 &
                     +tmp_RH0(m+1,n)*dhnp1*dtm  +tmp_RH0(m+1,n+1)*dhn*dtm  )&
                     /(tmp_hR(n+1)-tmp_hR(n))/(CosSZA_I(m)-CosSZA_I(m+1))

             end if
          end do
       end if

       RateL_C(i,j,k)=RateL_C(i,j,k)+ &
            (IMPACT_L(n)*dhnp1+IMPACT_L(n+1)*dhn)/(tmp_hR(n+1)-tmp_hR(n))
       RateM_C(i,j,k)=RateM_C(i,j,k)+ &
            (IMPACT_M(n)*dhnp1+IMPACT_M(n+1)*dhn)/(tmp_hR(n+1)-tmp_hR(n))
       RateH_C(i,j,k)=RateH_C(i,j,k)+ &
            (IMPACT_H(n)*dhnp1+IMPACT_H(n+1)*dhn)/(tmp_hR(n+1)-tmp_hR(n))

       if (RateL_C(i,j,k) < 0.0) RateL_C(i,j,k) = 0.0
       if (RateM_C(i,j,k) < 0.0) RateM_C(i,j,k) = 0.0
       if (RateH_C(i,j,k) < 0.0) RateH_C(i,j,k) = 0.0

       PhotoIonRate_VC(Lp_,i,j,k) = RateL_C(i,j,k) * No2Io_V(UnitT_)/No2Io_V(UnitN_)
       PhotoIonRate_VC(Mp_,i,j,k) = RateM_C(i,j,k) * No2Io_V(UnitT_)/No2Io_V(UnitN_)
       PhotoIonRate_VC(H1p_,i,j,k)= RateH_C(i,j,k) * No2Io_V(UnitT_)/No2Io_V(UnitN_)
       !                 if(hh.lt.1500.0.and.cosS0.gt.0.998)then
       !                    write(*,*)hh, RateH_C(i,j,k), cosS0
       !                 end if
    end do; end do; end do

!!!!!----------------- Interpolation/Expolation for neutral densities --------------
    !  open(1,file="n.dat",status="old")
    !    read(1,*) (tmp_rn(i),tmp_nL(i),tmp_nM(i),tmp_nH(i),i=1,num_n)
    !  close(1)

    !  tmp_n(15,:)=tmp_n(C4H2_,:)  !5
    !  tmp_n(HC3N_,:)=tmp_n(11,:) !10
    !  tmp_n(C3H4_,:)= tmp_n(12,:) !4
    !  tmp_n(C4H2_,:)=tmp_n(15,:)  !5

    Nu_C = 0.0
    NumDenNeutral_VC = 0.0

    !  tmp_hn = tmp_rn-2575.0
    !  do iBlock = 1,nBlockMax

    do k=1,nK; do j=1,nJ; do i=1,nI

       if (R_BLK(i,j,k,iBlock) >= Rbody) then
          hh = (R_BLK(i,j,k,iBlock)-1.00)*2575.0
          n= int((hh -725.0)/10.0+1.0)
          !------------ Interpolation/Expolation --------------
          if (hh < tmp_hn(1)) then
             NumDenNeutral_VC(:,i,j,k) = tmp_n(1:nNuSpecies,1) + &
                  (tmp_n(1:nNuSpecies,1)-tmp_n(1:nNuSpecies,2))*(tmp_hn(1)-hh)/(tmp_hn(2)-tmp_hn(1))
          else if(hh > tmp_hn(num_nu-1)) then
             NumDenNeutral_VC(:,i,j,k) = tmp_n(1:nNuSpecies,num_nu) + &
                  (tmp_n(1:nNuSpecies,num_nu)-tmp_n(1:nNuSpecies,num_nu-1))*&
                  (hh-tmp_hn(num_nu))/(tmp_hn(num_nu)-tmp_hn(num_nu-1))
          else                                  
             NumDenNeutral_VC(:,i,j,k) = tmp_n(1:nNuSpecies,n) + &
                  (tmp_n(1:nNuSpecies,n+1)-tmp_n(1:nNuSpecies,n))*(hh-tmp_hn(n))/(tmp_hn(n+1)-tmp_hn(n))
          end if

       end if
    end do; end do; end do

    NumDenNeutral_VC = max(0.0, NumDenNeutral_VC)/No2Io_V(UnitN_)
    Nu_C = nu0*sum(NumDenNeutral_VC, dim=1)

  end subroutine titan_input

  !====================================================================

  subroutine user_set_plot_var(iBlock, NameVar, IsDimensional, &
       PlotVar_G, PlotVarBody, UsePlotVarBody, &
       NameTecVar, NameTecUnit, NameIdlUnit, IsFound)

    use ModPhysics, ONLY: rBody, No2Io_V, UnitB_
    use ModMain, ONLY: Body1_
    use ModAdvance, ONLY: State_VGB, Bx_, By_, Bz_, B_
    use ModGeometry, ONLY: Xyz_DGB, r_BLK
    use ModBoundaryGeometry, ONLY: iBoundary_GB
    use ModMain, ONLY: iTest, jTest, kTest, ProcTest, BlkTest
    use ModProcMH,   ONLY: iProc


    integer,          intent(in) :: iBlock
    character(len=*), intent(in) :: NameVar
    logical,          intent(in) :: IsDimensional
    real,             intent(out):: PlotVar_G(MinI:MaxI, MinJ:MaxJ, MinK:MaxK)
    real,             intent(out):: PlotVarBody
    logical,          intent(out):: UsePlotVarBody
    character(len=*), intent(out):: NameTecVar
    character(len=*), intent(out):: NameTecUnit
    character(len=*), intent(out):: NameIdlUnit
    logical,          intent(out):: IsFound

    character (len=*), parameter :: Name='user_set_plot_var'

    integer :: iVar, i, j, k
    real :: Xyz_D(3), NormXyz_D(3),r, Br0, Br1, Br2, B_D(3), dBr_D(3)

    logical :: oktest,oktest_me
    !------------------------------------------------------------------------  
    if(iProc==PROCtest .and. iBlock==BLKtest)then
       call set_oktest('user_set_plot_var',oktest,oktest_me)
    else
       oktest=.false.; oktest_me=.false.
    end if

    select case(NameVar)
    case('b_x_r')
       iVar=Bx_
       NameTecVar = 'b_x_r'
    case('b_y_r')
       iVar=By_
       NameTecVar = 'b_y_r'
    case('b_z_r')
       iVar=Bz_
       NameTecVar = 'b_z_r'
    case default
       call stop_mpi(Name//': unimplemented variable='//NameVar)
    end select
    NameTecUnit = '[nT]'
    NameIdlUnit = 'nT'
    PlotVar_G = State_VGB(iVar,:,:,:,iBlock)
    UsePlotVarBody = .true.
    PlotVarBody    = 0.0

    if(IsDimensional) PlotVar_G = PlotVar_G*No2Io_V(UnitB_)

    if(.not. any(iBoundary_GB(:,:,:,iBlock)==body1_) ) RETURN

    ! Reflect at surface of the body
    do i=0,nI
       if(r_BLK(i+1,1,1,iBlock)>=rBody) EXIT
    end do

    if(oktest_me)&
         write(*,*)'i,r_BLK(i,1,1,iBlock),rBody=',i,r_BLK(i,1,1,iBlock),rBody

    if(r_BLK(i,1,1,iBlock)>rBody) RETURN

    i=i+1
    do k=MinK,MaxK; do j=MinJ,MaxJ
       Xyz_D = &
            (/ Xyz_DGB(x_,i,j,k,iBlock), Xyz_DGB(y_,i,j,k,iBlock), Xyz_DGB(z_,i,j,k,iBlock)/)
       r= r_BLK(i,j,k,iBlock)
       NormXyz_D = Xyz_D/r

       B_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
       Br0 = sum(NormXyz_D*B_D)

       Br1 = sum(NormXyz_D*State_VGB(Bx_:Bz_,i+1,j,k,iBlock))
       Br2 = sum(NormXyz_D*State_VGB(Bx_:Bz_,i+2,j,k,iBlock))

       ! Change radial component so that field is reflected at i+1/2
       dBr_D = (-Br2 - 2*Br1 - Br0)*NormXyz_D

       ! Apply change
       B_D = B_D + dBr_D

       PlotVar_G(i,j,k) = B_D(iVar-B_)

       if(oktest_me.and.j==jTest.and.k==kTest)then
          write(*,*)'i=',i,'iTest=',iTest
          write(*,*)'r=',r,&
               'r_BLK(iTest,j,k,iBlock)=',r_BLK(iTest,j,k,iBlock)
          write(*,*)'Br0, Br1,Br2=',Br0, Br1,Br2
          write(*,*)'State_VGB(Bx_:Bz_,i,j,k,iBlock)=',&
               State_VGB(Bx_:Bz_,i,j,k,iBlock)
          write(*,*)'B_D=', B_D
          write(*,*)'NormXyz_D=',NormXyz_D
       end if


    end do; end do

  end subroutine user_set_plot_var

  !=====================================================================
  subroutine user_get_log_var(VarValue, TypeVar, Radius)

    use ModGeometry,   ONLY: Xyz_DGB, R_BLK
    use ModMain,       ONLY: Unused_B
    use ModVarIndexes
    use ModAdvance,    ONLY: State_VGB,tmp1_BLK
    use ModPhysics,ONLY: No2Si_V, UnitN_, UnitX_, UnitU_

    real, intent(out)            :: VarValue
    character (len=*), intent(in):: TypeVar
    real, intent(in), optional :: Radius

    real, external :: calc_sphere
    real ::mass
    integer:: i,j,k,iBLK,index
    character (len=*), parameter :: Name='user_get_log_var'
    logical:: oktest=.false.,oktest_me
    !-------------------------------------------------------------------
    call set_oktest('user_get_log_var',oktest,oktest_me)
    if(oktest)write(*,*)'in user_get_log_var: TypeVar=',TypeVar
    select case(TypeVar)
    case('lpflx')
       index = RhoLp_

    case('mpflx')
       index = RhoMp_

    case('h1pflx')
       index = RhoH1p_

    case('h2pflx')
       index = RhoH2p_

    case('mhcpflx')
       index= RhoMHCp_

    case('hhcpflx')
       index= RhoHHCp_

    case('hnipflx')
       index= RhoHNIp_

    !case('neflx')

    case default
       call stop_mpi('wrong logvarname')
    end select

    do iBLK=1,nBLK
       if (Unused_B(iBLK)) CYCLE
       do k=0,nK+1; do j=0,nJ+1; do i=0,nI+1
          tmp1_BLK(i,j,k,iBLK) = State_VGB(index,i,j,k,iBLK)* &
               (State_VGB(rhoUx_,i,j,k,iBLK)*Xyz_DGB(x_,i,j,k,iBLK) &
               +State_VGB(rhoUy_,i,j,k,iBLK)*Xyz_DGB(y_,i,j,k,iBLK) &
               +State_VGB(rhoUz_,i,j,k,iBLK)*Xyz_DGB(z_,i,j,k,iBLK) &
               )/R_BLK(i,j,k,iBLK)/State_VGB(rho_,i,j,k,iBLK)
       end do; end do; end do
    end do

    VarValue = calc_sphere('integrate', 360, Radius, tmp1_BLK)

    mass = MassSpecies_V(index)
    VarValue=VarValue*No2Si_V(UnitN_)*No2Si_V(UnitX_)**2*No2Si_V(UnitU_)/mass

    !change to user value from normalized flux
    !    write(*,*)'varvalue, unitSI_n, unitSI_x, unitSI_U, mass, unitSI_t=',&
    !         varvalue, unitSI_n, unitSI_x, unitSI_U, mass, unitSI_t


  end subroutine user_get_log_var

  !============================================================================

  subroutine user_impl_source(iBlock)

    ! This is a test and example for using point implicit source terms
    ! Apply friction relative to some medium at rest
    ! The friction force is proportional to the velocity and the density.


    use ModAdvance, ONLY: Source_VC
    use ModNumConst, ONLY: cZero
    use ModVarIndexes, ONLY: Rho_, &
          RhoUx_, RhoUy_, RhoUz_, P_, &
         Energy_, Bx_, By_, Bz_
    use ModMain, ONLY: iTest, jTest, kTest, ProcTest, BlkTest
    use ModProcMH,   ONLY: iProc

    integer, intent(in) :: iBlock

    logical :: oktest,oktest_me
    !    real, dimension(nI,nJ,nK) :: InvRho_C, Ux_C, Uy_C, Uz_C
    !-------------------------------------------------------------------------

    if(iProc==PROCtest .and. iBlock==BLKtest)then
       call set_oktest('user_imp_sources',oktest,oktest_me)
    else
       oktest=.false.; oktest_me=.false.
    end if

    Srho   = cZero
    SrhoSpecies=cZero
    SrhoUx = cZero
    SrhoUy = cZero
    SrhoUz = cZero
    SBx    = cZero
    SBy    = cZero
    SBz    = cZero
    SP     = cZero
    SE     = cZero
    if(oktest_me)then
       !   write(*,*)'before Source(rhoU)=', Source_VC(6:8,itest,jtest,ktest)
       write(*,*)'Source(p,E)', Source_VC(P_:P_+1,iTest,jTest,kTest)
    end if

    call user_sources(iBlock)

    Source_VC(rho_       ,:,:,:) = Srho+Source_VC(rho_,:,:,:)
    Source_VC(rho_+1:rho_+MaxSpecies,:,:,:) = &
         SrhoSpecies+Source_VC(rho_+1:rho_+MaxSpecies,:,:,:)
    Source_VC(rhoUx_     ,:,:,:) = SrhoUx+Source_VC(rhoUx_,:,:,:)
    Source_VC(rhoUy_     ,:,:,:) = SrhoUy+Source_VC(rhoUy_,:,:,:)
    Source_VC(rhoUz_     ,:,:,:) = SrhoUz+Source_VC(rhoUz_,:,:,:)
    Source_VC(Bx_        ,:,:,:) = SBx+Source_VC(Bx_,:,:,:)
    Source_VC(By_        ,:,:,:) = SBy+Source_VC(By_,:,:,:)
    Source_VC(Bz_        ,:,:,:) = SBz+Source_VC(Bz_,:,:,:)
    Source_VC(P_     ,:,:,:) = SP+Source_VC(P_,:,:,:)

    !    InvRho_C = 1.0/State_VGB(Rho_,1:nI,1:nJ,1:nK,iBlock)
    !    Ux_C = InvRho_C*State_VGB(RhoUx_,1:nI,1:nJ,1:nK,iBlock)
    !    Uy_C = InvRho_C*State_VGB(RhoUy_,1:nI,1:nJ,1:nK,iBlock)
    !    Uz_C = InvRho_C*State_VGB(RhoUz_,1:nI,1:nJ,1:nK,iBlock)

    !    SE = InvGammaMinus1*SP + Ux_C*SrhoUx  + Uy_C*SrhoUy  + Uz_C*SrhoUz  &
    !         - 0.5*(Ux_C**2 + Uy_C**2 + Uz_C**2)*Srho

    Source_VC(Energy_,:,:,:) = SE+Source_VC(Energy_,:,:,:)

  end subroutine user_impl_source

  !===========================================================================

  subroutine user_expl_source(iBlock)
    !    use ModMain,    ONLY: nI, nJ, nK
    !    use ModPointImplicit,ONLY: UsePointImplicit, UsePointImplicit_B

    integer, intent(in) :: iBlock

    !---------------------------------------------------------------------
    ! Here come the explicit source terms

  end subroutine user_expl_source

  !===========================================================================

  subroutine user_set_resistivity(iBlock, Eta_G)
    use ModPhysics,  ONLY: No2Io_V, Io2No_V, No2Si_V, Si2No_V, &
         UnitN_, UnitTemperature_, UnitX_,UnitT_, Rbody
    use ModProcMH,   ONLY: iProc
    use ModMain, ONLY: ProcTest, BlkTest, iTest,jTest,kTest
    use ModAdvance,  ONLY: State_VGB
    use ModGeometry, ONLY: Rmin_BLK, R_BLK
    use ModResistivity, ONLY: Eta0Si

    integer, intent(in) :: iBlock
    real,intent(out) :: Eta_G(MinI:MaxI,MinJ:MaxJ,MinK:MaxK) 

    real   :: Te_dim, tx1, txp1, hh
    real   :: loc_c(3), NumDenNeutral_V(3), Eta0
    integer:: i, j, k, nte, n
    logical:: oktest, oktest_me=.true.
    !---------------------------------------------------------------------
    if(iProc==PROCtest .and. iBlock == BlkTest)then
       call set_oktest('user_set_resistivity',oktest,oktest_me)
    else
       oktest=.false.; oktest_me=.false.
    end if

    !\
    ! Dimensionalize:: Eta* is in units of [m^2/s]
    !/
    Eta_G = 0.0

    if (Rmin_BLK(iBlock) > 5.0*Rbody) RETURN !in Rbody unit

    Eta0 = Eta0Si * Si2No_V(UnitX_)**2/Si2No_V(UnitT_)


    do k=MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI; 
       totalNumRho=sum(State_VGB(rho_+1:rho_+MaxSpecies,i,j,k,iBlock) &
            /MassSpecies_V(rho_+1:rho_+MaxSpecies))

       Te_dim= State_VGB(p_,i,j,k,iBlock)/(totalNumRho+1.0e-8)&
            *No2Si_V(UnitTemperature_)/2

       nte=int( (log10(Te_dim)-2.0)/0.05 )+1
       if(Te_dim <= nu_Te(1))then
          loc_c(:)=nu_en(1,:)
       else if(Te_dim >= nu_Te(num_en))then
          loc_c(:)=nu_en(num_en,:)  
       else
          tx1=( Te_dim- nu_Te(nte) )/( nu_Te(nte+1)-nu_Te(nte) )
          if(tx1.gt.1.001.or.tx1.lt.-1.0e-3)then 
             write(*,*)'wrong  tx1=', tx1, log10(Te_dim), &
                  nte, Te_dim, nu_Te(nte)
          end if
          txp1=1.0-tx1
          loc_c(:)=nu_en(nte,:)*txp1+nu_en(nte+1,:)*tx1
       end if

       NumDenNeutral_V= 0.0
       if (R_BLK(i,j,k,iBlock) >= Rbody) then
          hh = (R_BLK(i,j,k,iBlock)-1.00)*2575.0
          n= int((hh -725.0)/10.0+1.0)
          !------------ Interpolation/Expolation --------------
          if (hh < tmp_hn(1)) then   !only consider three major neutral species
             NumDenNeutral_V(1:3) = tmp_n(1:3,1)   &
                  +(tmp_n(1:3,1)-tmp_n(1:3,2)) &
                  *(tmp_hn(1)-hh)/(tmp_hn(2)-tmp_hn(1))
          else if(hh > tmp_hn(num_nu-1)) then
             NumDenNeutral_V(1:3) = tmp_n(1:3,num_nu) + &
                  (tmp_n(1:3,num_nu)-tmp_n(1:3,num_nu-1))*&
                  (hh-tmp_hn(num_nu))/(tmp_hn(num_nu)-tmp_hn(num_nu-1))
          else                                  
             NumDenNeutral_V(1:3) = tmp_n(1:3,n)     &
                  +(tmp_n(1:3,n+1)-tmp_n(1:3,n)) &
                  *(hh-tmp_hn(n))/(tmp_hn(n+1)-tmp_hn(n))
          end if

       end if
       NumDenNeutral_V = max(0.0, NumDenNeutral_V)*Io2No_V(UnitN_)

       loc_c(:)=loc_c(:)*No2Io_V(UnitN_)/1.0e8
       Eta_G(i,j,k) = Eta0* &
            sum(loc_c(:)*NumDenNeutral_V(1:3))/&
            (totalNumRho+1.0e-8)*Io2No_V(unitN_)

       if(oktest_me.and.itest==i.and.jtest==j.and.ktest==k)then
          write(*,*)'loc_c=', loc_c
          write(*,*)'Te_dim=', Te_dim
          write(*,*)'TotalNumRho=',TotalNumRho
          write(*,*)'NumDenNeutral=', NumDenNeutral_V 
          write(*,*)'Eta_G=',Eta_G(Itest,Jtest,Ktest)
          write(*,*)'Eta0Si, Eta0=',Eta0Si, Eta0
       end if
    end do; end do; end do

  end subroutine user_set_resistivity

end module ModUser