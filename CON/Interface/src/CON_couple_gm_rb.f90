!^CMP COPYRIGHT UM
!^CMP FILE GM
!^CMP FILE RB

!BOP
!MODULE: CON_couple_gm_rb - couple GM and RB components
!
!DESCRIPTION:
! Couple GM and RB components one way for now. 
!
!INTERFACE:
module CON_couple_gm_rb

  !USES:
  use CON_coupler

  implicit none

  private ! except

  !PUBLIC MEMBER FUNCTIONS:

  public :: couple_gm_rb_init ! initialize both couplings
  public :: couple_gm_rb      ! couple GM to RB

  !REVISION HISTORY:
  ! 05/21/2004 O.Volberg - initial version
  !
  !EOP

  ! Communicator and logicals to simplify message passing and execution
  integer, save :: iCommGMRB
  logical :: IsInitialized = .false., UseMe=.true.

  ! Size of the 2D spherical structured (possibly non-uniform) RB grid
  integer, save :: iSize, jSize, nCells_D(2)

contains

  !BOP =======================================================================
  !IROUTINE: couple_gm_rb_init - initialize GM-RB coupling
  !INTERFACE:
  subroutine couple_gm_rb_init
    !DESCRIPTION:
    ! Store RB grid size.
    !EOP
    !------------------------------------------------------------------------
    if(IsInitialized) return
    IsInitialized = .true.

    UseMe = is_proc(RB_) .or. is_proc(GM_)
    if(.not.UseMe) return

    nCells_D=ncells_decomposition_d(RB_)
    iSize=nCells_D(1); jSize=nCells_D(2)

  end subroutine couple_gm_rb_init

  !BOP =======================================================================
  !IROUTINE: couple_gm_rb - couple GM to RB component
  !INTERFACE: couple_gm_rb(tSimulation)
  subroutine couple_gm_rb(tSimulation)

    !INPUT ARGUMENTS:
    real, intent(in) :: tSimulation     ! simulation time at coupling

    !DESCRIPTION:
    ! Couple between two components:\\
    !    Global Magnetosphere (GM) source\\
    !    Radiation Belt       (RB) target
    !
    ! Send field line volumes, average density and pressure and
    ! geometrical information.
    !EOP

    !\
    ! Coupling variables
    !/

    ! Number of variables to pass
    integer, parameter :: nVarGmRb=6

    ! Names of variables to pass
    character (len=*), parameter :: NameVar='vol:z0x:z0y:bmin:rho:p'

    ! Buffer for the variables on the 2D RB grid
    real, dimension(:,:,:), allocatable :: Buffer_IIV

    ! MPI related variables

    ! MPI status variable
    integer :: iStatus_I(MPI_STATUS_SIZE)

    ! General error code
    integer :: iError

    ! Message size
    integer :: nSize

    ! Name of this method
    character (len=*), parameter :: NameSub='couple_gm_rb'

    logical :: DoTest, DoTestMe
    integer :: iProcWorld

    !-------------------------------------------------------------------------
    call CON_set_do_test(NameSub,DoTest,DoTestMe)

    iProcWorld = i_proc()

    ! After everything is initialized exclude PEs which are not involved
    if(.not.UseMe) RETURN

    if(DoTest)write(*,*)NameSub,' starting, iProc=',iProcWorld
    if(DoTest)write(*,*)NameSub,', iProc, GMi_iProc0, i_proc0(RB_)=', &
         iProcWorld,i_proc0(GM_),i_proc0(RB_)

    !\
    ! Allocate buffers both in GM and RB
    !/
    allocate(Buffer_IIV(iSize,jSize,nVarGmRb), stat=iError)
    call check_allocate(iError,NameSub//": Buffer_IIV")

    if(DoTest)write(*,*)NameSub,', variables allocated',&
         ', iProc:',iProcWorld

    !\
    ! Get field line integrals from GM
    !/
    if(is_proc(GM_)) &
         call GM_get_for_rb(Buffer_IIV,iSize,jSize,nVarGmRb,NameVar)

    !\
    ! Transfer variables from GM to RB
    !/
    if(i_proc0(RB_) /= i_proc0(GM_))then
       nSize = iSize*jSize*nVarGmRb
       if(is_proc0(GM_)) &
            call MPI_send(Buffer_IIV,nSize,MPI_REAL,i_proc0(RB_),&
            1,i_comm(),iError)
       if(is_proc0(RB_)) &
            call MPI_recv(Buffer_IIV,nSize,MPI_REAL,i_proc0(GM_),&
            1,i_comm(),iStatus_I,iError)
    end if

    if(DoTest)write(*,*)NameSub,', variables transferred',&
         ', iProc:',iProcWorld

    !\
    ! Put variables into RB
    !/
    if(is_proc0(RB_))then
       call RB_put_from_gm(Buffer_IIV,iSize,jSize,nVarGmRb,NameVar)
       if(DoTest) &
            write(*,*)'RB got from GM: RB iProc, Buffer(1,1)=',&
            iProcWorld,Buffer_IIV(1,1,:)
    end if

    !\
    ! Deallocate buffer to save memory
    !/
    deallocate(Buffer_IIV)

    if(DoTest)write(*,*)NameSub,', variables deallocated',&
         ', iProc:',iProcWorld

    if(DoTest)write(*,*)NameSub,' finished, iProc=',iProcWorld

    ! if(DoTest.and.is_proc0(RB_)) call RB_print_variables('GM',iError)

  end subroutine couple_gm_rb

end module CON_couple_gm_rb
