!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
!BOP
!MODULE: CON_router - set the connection between the grids of different models
!INTERFACE:
Module CON_router
  !USES:
  use CON_grid_descriptor
  use CON_global_vector
  use ModMPI, ONLY: MPI_UNDEFINED
  !DESCRIPTION:
!This file presents the class of routers between the grids, each!  
!of them can be either the uniformly spaced or Octree or Quadric!
!adaptive block grid                   .                      !
!
!The methods include: allocation, initialization, cleaner and !
!two different constructors.                                  !
!
!REVISION HISTORY:
! Sokolov I.V.                                                !
! 7.20.03-7.21.03                                             !
! igorsok@umich.edu                                           !
! phone(734)647-4705                                          !
!EOP
  implicit none

  logical,parameter:: UseUnionComm=.true.
!BOP
!DESCRIPTION:
!==========================DERIVED TYPES========================!
!\begin{verbatim}
  type DoAddPtrType
     logical,dimension(:),pointer::DoAdd_I
  end type DoAddPtrType
!\end{verbatim}
!---------------------------------------------------------------!
!See CON\_grid\_descriptor about iCB index. In the array iCB\_I !
!the second index enumerates the grid points belonging to some!
!list, while the first one numerates the position of (0) PE, at !
!which the point is localized, (1:nDim) grid point indexes in !
!the block and (nDim+1), if exists, stores the local block    !
!number.
!\begin{verbatim}
  type IndexPtrType
     integer,dimension(:,:),pointer::iCB_II
  end type IndexPtrType

  type WeightPtrType
     real,dimension(:),pointer::Weight_I
  end type WeightPtrType
!\end{verbatim}
!========================DERIVED TYPE===========================!
  type RouterType
!The router can be set between the grids of different dimensions!
     character(LEN=3)::Name
     integer:: iCompTarget, iCompSource
!For the router between LOCAL grids of a component we use the   !
!communicator of the model for sending-receiving the data,      !
!otherwise the global communicator                              !
!\begin{verbatim}
     logical::IsLocal,IsProc
     integer::iProc,nProc,iComm
!\end{verbatim}
!If the union group is constructed, then for use with broadcast !
!we need the union communicator and the root PE ranks in this   !
!communicator
!\begin{verbatim}
     integer::iCommUnion,iProc0Source,iProc0Target
     integer,dimension(:),pointer::iTranslated_P
!\end{verbatim}
!As the default we use iCB indexes to construct the router,     !
!hence the grid point is characterized by the                   !
!GridDescriptor%nDim grid point indexes plus one more index for !
!the block number. Also we allow to use exactly                 ! 
!GridDescriptor%nDim indexes, without the block number which    !
!only seems to be of sence for the component which is localized !
!at one PE only, or which has exactly one block per PE          !
!\begin{verbatim}
     integer::nIndexSource,nIndexTarget  
!\end{verbatim}
!The total amounts of the buffer segments to be sent-received   !
!to/from the PE. The total amounts of the grid points from which!
!the data should be got or to which the data should be put,some !
!data points may be counted more than one time                  !
!\begin{verbatim}
     integer, dimension(:), pointer :: &
          nGet_P, nPut_P, nRecv_P, nSend_P
!\end{verbatim}
!iCB indexes and the weight coefficients for the points of the  !
!target and source grids, which are connected through the router!
!\begin{verbatim}
     type(IndexPtrType), dimension(:), pointer :: iGet_P
     type(IndexPtrType), dimension(:), pointer :: iPut_P
     type(DoAddPtrType), dimension(:), pointer :: DoAdd_P
     type(WeightPtrType), dimension(:),pointer :: Get_P
     type(WeightPtrType), dimension(:),pointer :: Put_P
!\end{verbatim}
!Mapped gird points. Fully identical to global mapping vector, however, is
! not present on all processors, only on those which control either the target
! (source) points or the images of the mapped point on source (target)  
!\begin{verbatim}
     real, dimension(:,:), pointer:: BufferSource_II
     real, dimension(:,:), pointer:: BufferTarget_II
!\end{verbatim}
!As long as we do not keep the entire mapping vector, we may wabt to know 
!a list of global point numbers for the mapped points, i.e. nMappedPointIndex=1
!integer per each mapped point. It may be convenient to keep more than one 
!index (say, a global tree node number, global block number or so, with the 
!only restriction that these indexes are sufficient to recover the global 
!point number for the mapped point.) 
!\begin{verbatim}
     integer :: nMappedPointIndex
!\end{verbatim}
!\begin{verbatim}
     integer :: nBufferSource, nBufferTarget
     integer :: iPointGlobal_      
     integer :: iPointInBlock_
     integer :: iNodeGlobal_
     integer :: nVar, iCoordStart, iCoordEnd, iAuxStart, iAuxEnd
     integer :: iWeight, iData
!\end{verbatim}
  end type RouterType
!EOP
  integer,allocatable,dimension(:),save::iAux_P
!BOP
!PUBLIC MEMBER FUNCTIONS:
  private::allocate_get_arrays
  private::allocate_put_arrays
  private::allocate_buffer_target
  private::allocate_buffer_source
  private::check_router_allocation
  private::iAux_P
!EOP
contains
!BOP
!===============================================================!
!BOP
!IROUTINE: init_router - initialize the type
!INTERFACE:
  subroutine init_router(&
       GridDescriptorSource,&
       GridDescriptorTarget,&
       Router,&
       nIndexSource,&
       nIndexTarget,&
       nMappedPointIndex)
    !INPUT ARGUMENTS:
    type(GridDescriptorType),intent(in)::&
         GridDescriptorSource,&
         GridDescriptorTarget
    type (RouterType),intent(out)::Router
    integer,intent(in),optional::nIndexSource
    integer,intent(in),optional::nIndexTarget
    integer,intent(in),optional::nMappedPointIndex
    !EOP
    integer::iPE,iError
    integer::nProc
    integer::iProc0Source,iProc0Target,iProcUnion
    integer::iGroupUnion,iGroupSource,iGroupTarget, iGroup
    !---------------------------------------------------------------!
    !\
    ! Check grid registration
    !/
    Router%iCompSource = compid_grid(GridDescriptorSource%DD%Ptr)
    Router%iCompTarget = compid_grid(GridDescriptorTarget%DD%Ptr)
    !\
    !Check if the grids are both local or both global  
    !/             !
    if(is_local_grid(GridDescriptorSource%DD%Ptr).and.&
         is_local_grid(GridDescriptorTarget%DD%Ptr))then
       Router%IsLocal=.true.

       if( Router%iCompSource /= Router%iCompTarget)&
            call CON_stop(&
            'Do not couple Local grids of different components!')

       Router%iProc=i_proc(Router%iCompTarget)
       Router%nProc=n_proc(Router%iCompTarget)
       Router%iComm=i_comm(Router%iCompTarget)
       Router%iCommUnion=Router%iComm
       Router%iProc0Source=0
       Router%iProc0Target=0
       Router%IsProc=is_proc(Router%iCompTarget)

    elseif((.not.is_local_grid(GridDescriptorSource%DD%Ptr))&
         .and.(.not.is_local_grid(GridDescriptorTarget%DD%Ptr)))&
         then
       Router%IsLocal=.false.
       Router%iProc=i_proc()
       Router%nProc=n_proc()
       Router%iComm=i_comm()
       Router%IsProc=is_proc()
       iProc0Source=i_proc0(Router%iCompSource)
       iProc0Target=i_proc0(Router%iCompTarget)

       if(UseUnionComm)then
          if(.not.allocated(iAux_P))then
             allocate(iAux_P(0:n_proc()-1),stat=iError)
             call check_allocate(iError,'iAux_P')
             do iPE=0,n_proc()-1
                iAux_P(iPE)=iPE
             end do
          end if
          nProc=Router%nProc
          allocate(Router%iTranslated_P(0:nProc-1),stat=iError)
          call check_allocate(iError,'iTranslated_P')

          iGroupSource=i_group(Router%iCompSource)
          iGroupTarget=i_group(Router%iCompTarget)
          if(iProc0Target>iProc0Source)then
             call MPI_GROUP_UNION(&
                  iGroupSource,&
                  iGroupTarget,&
                  iGroupUnion,&
                  iError)
             Router%iProc0Source=0
             call MPI_GROUP_TRANSLATE_RANKS(&
                  i_group(),&
                  n_proc(),&
                  iAux_P(0),&
                  iGroupUnion,&
                  Router%iTranslated_P,&
                  iError)
             Router%iProc0Target=&
                  Router%iTranslated_P(iProc0Target)
          else
             call MPI_GROUP_UNION(&
                  iGroupTarget,&
                  iGroupSource,&
                  iGroupUnion,&
                  iError)
             Router%iProc0Target=0
             call MPI_GROUP_TRANSLATE_RANKS(&
                  i_group(),&
                  n_proc(),&
                  iAux_P(0),&
                  iGroupUnion,&
                  Router%iTranslated_P,&
                  iError)
             Router%iProc0Source=&
                  Router%iTranslated_P(iProc0Source)
          end if
          call MPI_COMM_CREATE(&
               i_comm(),&
               iGroupUnion,&
               Router%iCommUnion,&
               iError)
          call MPI_group_rank(iGroupUnion,iProcUnion,iError)
          Router%IsProc=iProcUnion/=MPI_UNDEFINED
          if(iProcUnion/=Router%iProc0Target.and.&
               i_proc()==iProc0Target)call CON_stop(&
               'Wrongly defined Router%iProc0Target')
          if(iProcUnion/=Router%iProc0Source.and.&
               i_proc()==iProc0Source)call CON_stop(&
               'Wrongly defined Router%iProc0Source')
          call MPI_GROUP_FREE(iGroupUnion,iError)
       else
          Router%iCommUnion=Router%iComm
          Router%iProc0Source=iProc0Source
          Router%iProc0Target=iProc0Target
       end if
    else
       call CON_stop(&
            'Do not couple a Local grid with a global one')
    end if

    Router%nIndexSource = &
         GridDescriptorSource%nDim + 1
    if(present(nIndexSource))then
       if(nIndexSource>=Router%nIndexSource-1&
            .or.nIndexSource==1)then
          Router%nIndexSource=nIndexSource
       else
          write(*,*)'IndexMin=',Router%nIndexSource-1
          call CON_stop('nIndexSource should be at least IndexMin')
       end if
    end if

    Router%nIndexTarget = &
         GridDescriptorTarget%nDim + 1

    if(present(nIndexTarget))then
       if(nIndexTarget>=Router%nIndexTarget-1&
            .or.nIndexTarget==1)then
          Router%nIndexTarget=nIndexTarget
       else
          write(*,*)'IndexMin=',Router%nIndexTarget-1
          call CON_stop('nIndexTarget should be at least IndexMin')
       end if
    end if

    Router%nMappedPointIndex   = -1 !Buffers will not be initialized

    Router%iPointGlobal_       = 0
    Router%iPointInBlock_      = 0
    Router%iNodeGlobal_        = 0
    Router%iCoordStart         = 1
    Router%iCoordEnd           = 0
    Router%iAuxStart           = 1
    Router%iAuxEnd             = 0
    Router%nVar                = 0
    if(present(nMappedPointIndex))then
       Router%nMappedPointIndex = &
            nMappedPointIndex
       Router%iCoordStart         = 1
       Router%iCoordEnd           = &
            GridDescriptorSource%nDim
       Router%iAuxStart = Router%iCoordEnd + 1
       Router%iAuxEnd   = Router%iCoordEnd + nMappedPointIndex
       Router%nVar      = Router%iAuxEnd
       select case(nMappedPointIndex)
       case(1)
          Router%iPointGlobal_       = 1
          Router%iPointInBlock_      = 0
          Router%iNodeGlobal_        = 0
       case(2)        
          Router%iPointGlobal_       = 0
          Router%iPointInBlock_      = 1
          Router%iNodeGlobal_        = 2
       case(0)
          !Do nothing, send coordinates only
       case default
          call CON_stop(&
               'Illegal number of mapped point indexes')
       end select
       nullify(Router%BufferSource_II)
       call allocate_buffer_source(Router, nProc)
       Router%nBufferSource = nProc
       nullify(Router%BufferTarget_II)
       call allocate_buffer_target(Router, nProc)
       Router%nBufferTarget = nProc
    end if
    nProc=Router%nProc

    !Allocation:
    allocate(Router%nGet_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'nGet_P')
    allocate(Router%nPut_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'nPut_P')
    allocate(Router%nSend_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'nSend_P')
    allocate(Router%nRecv_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'nRecv_P')
    allocate(Router%iGet_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'iGet_P') 
    allocate(Router%Get_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'Get_P')

    do iPE=0,nProc-1
       nullify(Router%iGet_P(iPE)%iCB_II)
       nullify(Router%Get_P(iPE)%Weight_I)
       call allocate_get_arrays(Router,iPE,1)
    end do
    allocate(Router%iPut_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'iPut_P') 
    allocate(Router%Put_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'Put_P')
    allocate(Router%DoAdd_P(0:nProc-1),stat=iError)
    call check_allocate(iError,'DoAdd_P')

    do iPE=0,nProc-1
       nullify(Router%iPut_P(iPE)%iCB_II)
       nullify(Router%Put_P(iPE)%Weight_I)
       nullify(Router%DoAdd_P(iPE)%DoAdd_I)
       call allocate_put_arrays(Router,iPE,1)
    end do
 
    Router%nGet_P  = 0
    Router%nPut_P  = 0
    Router%nSend_P = 0
    Router%nRecv_P = 0
    call check_router_allocation(Router)
  end subroutine init_router
!============================PRIVATE============================!
  subroutine  allocate_get_arrays(Router,iPE,nLength)
    type(RouterType),intent(inout)::Router
    integer,intent(in)::iPE,nLength
    integer::iError
    if(associated(Router%iGet_P(iPE)%iCB_II))&
         deallocate(Router%iGet_P(iPE)%iCB_II)
    if(associated(Router%Get_P(iPE)%Weight_I))&
         deallocate(Router%Get_P(iPE)%Weight_I)
    allocate(Router%iGet_P(iPE)%iCB_II(&
         0:Router%nIndexSource,nLength),stat=iError)
    call check_allocate(iError,'iGet_P%iCB_II')
    Router%iGet_P(iPE)%iCB_II = 0
    allocate(Router%Get_P(iPE)%Weight_I(nLength),stat=iError)
    call check_allocate(iError,'Get_P%Weight_I')
    Router%Get_P(iPE)%Weight_I = 0.0
  end subroutine allocate_get_arrays
  !==========================PRIVATE===========================!
  subroutine allocate_buffer_source(Router, nLength)
    type(RouterType),intent(inout) :: Router
    integer,         intent(in)    :: nLength
    integer::iError
    !----------------
    if(associated(Router%BufferSource_II))&
         deallocate(Router%BufferSource_II)
    allocate(Router%BufferSource_II(&
         Router%nVar,nLength),stat=iError)
    call check_allocate(iError,'BufferSource_II')
    Router%BufferSource_II = 0.0
    Router%nBufferSource = nLength
  end subroutine allocate_buffer_source
  !============================PRIVATE======================!
  subroutine allocate_put_arrays(Router,iPE,nLength)
    type(RouterType),intent(inout)::Router
    integer,intent(in)::iPE,nLength
    integer::iError
    if(associated(Router%iPut_P(iPE)%iCB_II))&
         deallocate(Router%iPut_P(iPE)%iCB_II)
    if(associated(Router%DoAdd_P(iPE)%DoAdd_I))&
         deallocate(Router%DoAdd_P(iPE)%DoAdd_I)
    allocate(Router%iPut_P(iPE)%iCB_II(&
         0:Router%nIndexTarget,nLength),stat=iError)
    call check_allocate(iError,'iPut_P%iCB_II') 
    Router%iPut_P(iPE)%iCB_II = 0
    allocate(Router%Put_P(iPE)%Weight_I(nLength),stat=iError)
    call check_allocate(iError,'Put_P%Weight_I')  
    Router%Put_P(iPE)%Weight_I = 0.0
    allocate(Router%DoAdd_P(iPE)%DoAdd_I(nLength),stat=iError)
    call check_allocate(iError,'DoAdd_P%DoAdd_I')
    Router%DoAdd_P(iPE)%DoAdd_I = .false.
  end subroutine allocate_put_arrays
  !============================PRIVATE======================!
  subroutine allocate_buffer_target(Router, nLength)
    type(RouterType),intent(inout) :: Router
    integer,         intent(in)    :: nLength
    integer::iError
    !----------------
    if(associated(Router%BufferTarget_II))&
         deallocate(Router%BufferTarget_II)
    allocate(Router%BufferTarget_II(&
         Router%nVar,nLength),stat=iError)
    call check_allocate(iError,'BufferTarget_II')
    Router%BufferTarget_II = 0.0
    Router%nBufferTarget   = nLength
  end subroutine allocate_buffer_target
  !=========================================================!
  integer function nlength_buffer_source(Router)
    type(RouterType),intent(inout)::Router
    nlength_buffer_source = sum(Router%nSend_P(:))
  end function nlength_buffer_source
  !---------------------------------
  integer function nlength_buffer_target(Router)
    type(RouterType),intent(inout)::Router
    nlength_buffer_target = sum(Router%nRecv_P(:))
  end function nlength_buffer_target
  !============================PRIVATE======================!
  subroutine check_router_allocation(Router)
    type(RouterType),intent(inout)::Router
    integer :: iPE, nTotalPut, nTotalGet, UBound_I(2)
    do iPE=0,Router%nProc-1
       if(ubound(&
            Router%iPut_P(iPE)%iCB_II,2)<&
            Router%nPut_P(iPE))then
          call allocate_put_arrays&
               (Router,iPE,Router%nPut_P(iPE))
       end if
       if(ubound(&
            Router%iGet_P(iPE)%iCB_II,2)<&
            Router%nGet_P(iPE))then
          call allocate_get_arrays&
               (Router,iPE,Router%nGet_P(iPE))
       end if
    end do
    if(Router%nVar > 0)then
       UBound_I = ubound(Router%BufferTarget_II)
       if(  Ubound_I(1)/=Router%nVar.or.&
            UBound_I(2) < nlength_buffer_target(Router))&
            call allocate_buffer_target(Router, &
            nlength_buffer_target(Router))
       UBound_I = ubound(Router%BufferSource_II)
       if(  Ubound_I(1)/=Router%nVar.or.&
            UBound_I(2) < nlength_buffer_source(Router))&
            call allocate_buffer_source(Router, &
            nlength_buffer_source(Router))
    end if
  end subroutine check_router_allocation
!===============================================================!
!Done up to this place 7.21.03                                  !
  subroutine bcast_global_vector_in_router(&
       NameVector,&
       GD,&
       Router,&
       NameMask)
    character(LEN=*),intent(in)::NameVector,NameMask
    optional::NameMask
    type(GridDescriptorType),intent(in)::GD
    type(RouterType),intent(in)::Router

    if(Router%IsLocal)then
       call bcast_global_vector(&
            NameVector,&
            GD,&
            NameMask)
    else
       call bcast_global_vector(&
            NameVector,&
            GD,&
            Router%iTranslated_P,&
            Router%iCommUnion,&
            NameMask)
    end if
  end subroutine bcast_global_vector_in_router

!===============================================================!
!===============================================================!
!BOP
!IROUTINE: set_router - work for a case of mapping FROM TARGET
!INTERFACE:
  subroutine set_router(&
!The Descriptor for Source grid points                          !
       GridDescriptorSource,& 
!The Descriptor for Target grid points                          !
       GridDescriptorTarget,&
!The Router to be set                                           !
       Router,&
!Logical function which allows to skip the block if there is no !
!interface points in it. Optional, if not present then all the  !
!blocks are checked for the presence of the interface points    !
       is_interface_block,&
!The subroutine which defines if the grid point is inside the   !
!interface layer. Optional, if not present, then all the grid   !
!points (at the target grid) are considered as the interface    !
!layer points                                                   !     
       interface_point_coords, &
!Mapping transformation which, in the treated case, maps the    !
!target grid point to an image point into the source domain,    !
!in case this mapping is implemented through a routine          !
       mapping,&
!Mapping transformation which, in the treated case, maps the    !
!target grid point to an image point into the source domain,    !
!in case this mapping is implemented through a global vector    !    
       NameMappingVector,&
!If mapping throught a global vector is used, some points can
!be avoided in setting the router using the named mask array
       NameMask,&
!First or second order interpolation procedures are available   !
!(see CON_grid_descriptor) to find the grid point at the source !
!grid and the interpoltion weights for the image point:         !
!nearest_grid_points and bilinear_interpolation.                !
!Optional, if not present then the nearest_grid_points is used  !
       interpolate)
    use ModIOUnit,ONLY:io_unit_new
    !INPUT ARGUMENTS:

    interface
       logical function is_interface_block(lGlobalNode)
         implicit none
         integer,intent(in)::lGlobalNode 
       end function is_interface_block

       subroutine interface_point_coords(&
            GridDescriptor,&
            lGlobalTreeNode,&
            nDim,&
            Xyz_D,&
            nIndex,&
            iIndex_I,&
            IsInterfacePoint)
         use CON_grid_descriptor
         implicit none
         type(GridDescriptorType),intent(in)::GridDescriptor
         integer,intent(in)::lGlobalTreeNode,nIndex
         logical,intent(out)::IsInterfacePoint
         integer,intent(in)::nDim
         real,intent(inout)::Xyz_D(nDim)
         integer,intent(inout)::iIndex_I(nIndex)
       end subroutine interface_point_coords

       subroutine mapping(&
            nDimFrom,XyzFrom_D,nDimTo,XyzTo_D,IsInterfacePoint)
         implicit none                                                  
         integer,intent(in)::nDimFrom,nDimTo       
         real,dimension(nDimFrom),intent(in)::XyzFrom_D
         real,dimension(nDimTo),intent(out)::XyzTo_D
         logical,intent(out)::IsInterfacePoint
       end subroutine mapping

       subroutine interpolate(&
            nDim,&
            Xyz_D,&
            GridDescriptor,&
            nIndex, &
            iIndex_II,&
            nImage,  &
            Weight_I)
         use CON_grid_descriptor
         implicit none
         integer,intent(in)::nDim
         real,intent(inout)::Xyz_D(nDim)
         type(GridDescriptorType)::GridDescriptor     
         integer,intent(in)::nIndex
         integer,     intent(out):: iIndex_II(0:nIndex,2**nDim)
         integer,intent(out)::nImage
         real,dimension(2**nDim),intent(out)::Weight_I
       end subroutine interpolate
    end interface

    optional::is_interface_block,interface_point_coords
    optional::mapping,interpolate

    character(LEN=*),intent(in),optional::NameMappingVector
    character(LEN=*),intent(in),optional::NameMask

    type(GridDescriptorType),intent(in):: GridDescriptorSource
    type(GridDescriptorType),intent(in):: GridDescriptorTarget
    type(RouterType),intent(inout)::Router
    !EOP
    integer::iProc,nProc
    integer::lGlobalNode,iBlockAll
    integer::iGlobalGridPoint,nGridPointsPerBlock
    logical::IsInterfacePoint
    integer::iImage,nImage,nImagePart,iToGet
    integer::iProcTo,iBlockTo,iProcFrom,iProcDoNotAdd,iPE
    integer,dimension(0:Router%nProc-1)::&
         nGetUbound_P,nPutUbound_P

    real,dimension(GridDescriptorTarget%nDim)::XyzTarget_D
    real,dimension(GridDescriptorSource%nDim)::&
         XyzSource_D,XyzStored_D
    integer,dimension(GridDescriptorTarget%nDim)::iCell_D
    integer, dimension(Router%nIndexTarget)::iIndexRecv_I
    integer,dimension(0:Router%nIndexSource,&
         2**GridDescriptorSource%nDim)::&
         iIndexGet_II
    integer,dimension(2**GridDescriptorSource%nDim)::&
         iProcLookUp_I
    integer::nProcToGet,iProcToGet
    logical::DoCountOnly,DoCountRed
    real,dimension(2**GridDescriptorSource%nDim)::Weight_I

    real,dimension(:,:),pointer::XyzMapping_DI

    logical,dimension(:),pointer::Used_I
    logical::UseMask,UseMappingVector,UseMappingFunction

    logical::DoCheckBlock,DoCheckPoint,DoInterpolate
    integer::iError,iFile
    logical::DoTest,DoTestMe
    character(LEN=*),parameter::NameSub='Router'
    character(LEN=100):: NameFile
    !-------------------------

    !For given PE the number in the communicator is:
    iProc=Router%iProc
    !

    !Return if the processor does not belong to the communicator
    if(iProc<0)return

    DoTest=.false.; DoTestMe=.false.


    !Check a presence of mapping array.
    !Associate pointer if required.

    UseMappingVector=present(NameMappingVector)

    if(UseMappingVector)&
         call associate_with_global_vector(&
         XyzMapping_DI,NameMappingVector)

    UseMask=present(NameMask)

    if(UseMask)then
       call associate_with_global_mask(&
            Used_I,NameMask)
    end if
    if(UseMask)then
       NameFile = 'router_'//NameMask
       call CON_set_do_test(NameFile,DoTest,DoTestMe)

    elseif(UseMappingVector)then
       NameFile ='router_'//NameMappingVector
       call CON_set_do_test(NameFile,DoTest,DoTestMe)
    end if
    DoTestMe=DoTest.and.iProc==Router%iProc0Target
    if(DoTestMe)write(*,*)'Router starts'
    UseMappingFunction=present(mapping)

    if(.not.(UseMappingFunction.or.UseMappingVector).and.&
         GridDescriptorTarget%nDim/=GridDescriptorSource%nDim)&
         call CON_stop(&
         'Mapping is needed for Target%nDim/=Source%nDim')
    nProc=Router%nProc

    DoCheckBlock=present(is_interface_block)
    DoCheckPoint=present(interface_point_coords)
    DoInterpolate=present(interpolate)

    !Check dimensions

    DoCountOnly=.true. !To enter the loop
    do while(DoCountOnly)
       call check_router_allocation(Router)


!Store Upper bounds to control if the alllocated index array    !
!have sufficient size
       do iPE=0,nProc-1
          nGetUbound_P(iPE)=ubound(Router%iGet_P(iPE)%iCB_II,2)
          nPutUbound_P(iPE)=ubound(Router%iPut_P(iPE)%iCB_II,2)
       end do

       DoCountOnly=.false.
!If the check shows that the allocated array is not sufficient, ! 
!then DoCountOnly will be set to true. The loop then will be    !
!repeated for the second time                                   !
       if(DoTestMe)then
          iFile=io_unit_new()
          open(iFile,file=trim(NameFile),status='replace')
          write(iFile,*)'iPointGlobal Xyz_D'
          write(iFile,*)'iProcFrom   iCB indexes  Weitht  Sum(Weight)'//&
               'iImage '
       end if


!Initialize the counters                                        !
       Router%nGet_P=0
       Router%nPut_P=0
       Router%nSend_P=0
       Router%nRecv_P=0

       nGridPointsPerBlock=n_grid_points_per_block(&
            GridDescriptorTarget)

!Block loop                                                     !
       do iBlockAll=1,n_block_total(GridDescriptorTarget%DD%Ptr)

          lGlobalNode=i_global_node_a(&
               GridDescriptorTarget%DD%Ptr,iBlockAll)

          call pe_and_blk(&
               GridDescriptorTarget%DD%Ptr,lGlobalNode,&
               iProcTo,iBlockTo)
!Skip the block if desired: if there is known to be no interface!
!point in it                                                    !
          if( DoCheckBlock)then
             if(.not.is_interface_block(lGlobalNode))CYCLE
          end if
!GlobalCellNumber Loop, for a given (octree) block              !
          do iGlobalGridPoint=&
               1+nGridPointsPerBlock*(iBlockAll-1),&
               nGridPointsPerBlock*iBlockAll

             if(UseMask)then
                if(DoTestMe)&
                     write(iFile,*)'iGlobalPoint=',iGlobalGridPoint,&
                     ' Used_I=', Used_I(iGlobalGridPoint)
                if(.not.Used_I(iGlobalGridPoint))&
                     CYCLE
             end if

             iIndexRecv_I(1)=iGlobalGridPoint
             if(Router%nIndexTarget==1.and.&
                  UseMappingVector)then

                XyzSource_D=XyzMapping_DI(&
                     1:GridDescriptorSource%nDim,&
                     iGlobalGridPoint)
             else 
                call global_i_grid_point_to_icb(&
                     GridDescriptorTarget,&
                     iGlobalGridPoint,&
                     lGlobalNode,& 
                     iCell_D)

                if(Router%nIndexTarget/=1)then
                   iIndexRecv_I(Router%nIndexTarget)=iBlockTo
                   iIndexRecv_I(1:GridDescriptorTarget%nDim)=&
                        iCell_D
                end if
                if(UseMappingVector)then
                   XyzSource_D=XyzMapping_DI(&
                        1:GridDescriptorSource%nDim,&
                        iGlobalGridPoint)
                else
                   XyzTarget_D=xyz_grid_d(&
                        GridDescriptorTarget,&
                        lGlobalNode,&
                        iCell_D)
                   if( DoCheckPoint)then
                      call interface_point_coords(&
                           GridDescriptorTarget,&
                           lGlobalNode,&
                           GridDescriptorTarget%nDim,&
                           XyzTarget_D,&
                           Router%nIndexTarget,&
                           iIndexRecv_I,&
                           IsInterfacePoint)
                      if(.not.IsInterfacePoint)CYCLE 
                   end if
                   if(UseMappingFunction)then
                      call mapping(&
                           GridDescriptorTarget%nDim,&
                           XyzTarget_D,&
                           GridDescriptorSource%nDim,&
                           XyzSource_D,&
                           IsInterfacePoint)
                      if(.not.IsInterfacePoint)CYCLE
                   else
                      XyzSource_D=XyzTarget_D
                   end if
                end if
             end if
             ! call timing_start('set_router_interp')
             if(DoTestMe)then
                XyzStored_D=XyzSource_D
                write(iFile,*)iGlobalGridPoint,XyzSource_D
             end if
             if( DoInterpolate)then
                call interpolate(&
                     GridDescriptorSource%nDim,&
                     XyzSource_D,&
                     GridDescriptorSource,&
                     Router%nIndexSource,&
                     iIndexGet_II,&
                     nImage,&
                     Weight_I)
             else
                call nearest_grid_points(&
                     GridDescriptorSource%nDim,&
                     XyzSource_D,&
                     GridDescriptorSource,&
                     Router%nIndexSource,&
                     iIndexGet_II,&
                     nImage,&
                     Weight_I)
             end if
             if(nImage<1)then
                write(*,*)'nImage=', nImage
                call CON_stop('interpolation failed')
             end if
             if(DoTestMe)then
                do iImage=1,nImage
                   if(iImage==1)then
                      write(iFile,*)iIndexGet_II(:,iImage),Weight_I(iImage),&
                           sum(Weight_I(1:nImage))
                   else
                      write(iFile,*)iIndexGet_II(:,iImage),Weight_I(iImage),&
                           iImage
                   end if
                end do
                if(Router%nIndexSource==&
                     GridDescriptorSource%nDim+1)then
                   XyzSource_D=0.0
                   do iImage=1,nImage
                      XyzSource_D=&
                           XyzSource_D+&
                           xyz_grid_d(GridDescriptorSource,&
                           i_global_node_bp(&
                           GridDescriptorSource%DD%Ptr,&
                           iIndexGet_II(Router%nIndexSource,iImage),&
                           iIndexGet_II(0,iImage)),&
                           iIndexGet_II(1:GridDescriptorSource%nDim,&
                           iImage))*Weight_I(iImage)

                   end do
                   write(iFile,*)'Interpolated coordinate values=',&
                        XyzSource_D,' Error=',&
                        sqrt(sum((XyzSource_D-XyzStored_D)**2))
                end if
                write(iFile,*)
             end if
             ! call timing_stop('set_router_interp')
!--------------------------------------------------------------!
!Lookup
             nImagePart=0     !At all CPUs


             do iImage=1,nImage
                iProcFrom=iIndexGet_II(0,iImage)
!At the source PEs the number of terms in the partial sums are !
!found                                                         !
                if(iProc==iProcFrom)then
                   nImagePart=nImagePart+1
                   Router%nGet_P(iProcTo)=&
                        Router%nGet_P(iProcTo)+1
                   DoCountOnly=DoCountOnly.or.&
                        Router%nGet_P(iProcTo)>&
                        nGetUbound_P(iProcTo)
                end if

!At the target processor the PE list is defined which will send!
!partial sums                                                 !
                if(iProc==iProcTo)then
                   if(iImage==1)then
                      iProcLookUp_I(1)=iProcFrom
                      nProcToGet=1
                      Router%nPut_P(iProcFrom)=&
                           Router%nPut_P(iProcFrom)+1
                      Router%nRecv_P(iProcFrom)=&
                           Router%nRecv_P(iProcFrom)+1
                      DoCountOnly=DoCountOnly.or.&
                           Router%nPut_P(iProcFrom)>&
                           nPutUbound_P(iProcFrom)
                   else
                      if(.not.any(iProcLookUp_I(&
                           1:nProcToGet)==iProcFrom))then
                         nProcToGet=nProcToGet+1
                         iProcLookUp_I(nProcToGet)=iProcFrom
                         Router%nPut_P(iProcFrom)=&
                              Router%nPut_P(iProcFrom)+1
                         Router%nRecv_P(iProcFrom)=&
                              Router%nRecv_P(iProcFrom)+1
                         DoCountOnly=DoCountOnly.or.&
                              Router%nRecv_P(iProcFrom)>&
                              nPutUbound_P(iProcFrom)
                      end if
                   end if
                end if
             end do

             if(nImagePart>0)Router%nSend_P(iProcTo)=&
                  Router%nSend_P(iProcTo)+1

             if(.not.DoCountOnly)then
                do iImage=1,nImage
                   iProcFrom=iIndexGet_II(0,iImage)
                   if(iProc==iProcFrom)then
                      iToGet=Router%nGet_P(iProcTo)+1-nImagePart
                      Router%iGet_P(iProcTo)%iCB_II(:,iToGet)&
                           =iIndexGet_II(:,iImage)
                      Router%iGet_P(iProcTo)%iCB_II(0,iToGet)&
                           =nImagePart
                      Router%Get_P(iProcTo)%Weight_I(iToGet)&
                           =Weight_I(iImage)
                      nImagePart=nImagePart-1
                   end if
                end do
                if(iProc==iProcTo)then
                   do iProcToGet=1,nProcToGet
                      iProcFrom=iProcLookUp_I(iProcToGet)
                      Router%iPut_P(iProcFrom)%&
                           iCB_II(1:Router%nIndexTarget,&
                           Router%nPut_P(iProcFrom))&
                           =iIndexRecv_I(1:Router%nIndexTarget)
                      Router%iPut_P(iProcFrom)%&
                           iCB_II(0,Router%nPut_P(iProcFrom))&
                           =1
                      Router%Put_P(iProcFrom)%&
                           Weight_I(Router%nPut_P(iProcFrom))&
                           =cOne
                      Router%DoAdd_P(iProcFrom)%&
                           DoAdd_I(Router%nRecv_P(iProcFrom))=&
                           .true.
                   end do
                   if(any(iProcLookUp_I(&
                        1:nProcToGet)==iProcTo))then
                      iProcDoNotAdd=iProcTo
                   else
                      iProcDoNotAdd=minval(&
                           iProcLookUp_I(1:nProcToGet))
                   end if
                   Router%DoAdd_P(iProcDoNotAdd)%&
                        DoAdd_I(Router%nRecv_P(iProcDoNotAdd))=&
                        .false.
                end if
             end if
          end do !Global cell
       end do    !Target block

       if(DoTestMe)close(iFile)
    end do       !Check if DoCountOnly
    if(UseMappingVector)nullify(XyzMapping_DI)
    if(UseMask)nullify(Used_I)
  end subroutine set_router
!===============================================================!
!===============================================================!
  subroutine construct_router_from_source(&
!The Descriptor for Source grid points:   
       GridDescriptorSource,& !<<<<<<<<<<<<<<
!The Descriptor for Target grid points:   
       GridDescriptorTarget,& !<<<<<<<<<<<<<<
!The Router to be set 
       Router,&               !<<<<<<<<<<<<<<
!Logical function which allows to skip the block if there is no !
!interface points in it. Optional, if not present then all the  !
!blocks are checked for the presence of the interface points    !
       is_interface_block,&   !<<<<<<<<<<<<<<
!The subroutine which defines if the grid point is inside the   !
!interface layer. Optional, if not present, then all the grid   !
!points (at the source grid) are considered as the interface    !
!layer points 
       interface_point_coords, &  !<<<<<<<<<<
!Mapping transformation which, in the treated case, maps the    !
!source grid point to an image point into the target domain,    !
!in case this mapping is implemented through a routine          !
       mapping,&              !<<<<<<<<<<<<<<
!Mapping transformation which, in the treated case, maps the    !
!source grid point to an image point into the target domain,    !
!in case this mapping is implemented through a global vector    !    
       NameMappingVector,&    !<<<<<<<<<<<<<<
!If mapping throught a global vector is used, some points can
!be avoided in setting the router using the named mask array
       NameMask,&             !<<<<<<<<<<<<<<
!First or second order interpolation procedures are available   !
!(see CON_grid_descriptor) to find the grid point at the target !
!grid and the interpoltion weights for the image point:         !
!nearest_grid_points and bilinear_interpolation.                !
!Optional, if not present then the nearest_grid_points is used  !
       interpolate)           !<<<<<<<<<<<<<<
    use ModIOUnit,ONLY:io_unit_new

    !INPUT ARGUMENTS:

    interface
       logical function is_interface_block(lGlobalNode)
         implicit none
         integer,intent(in)::lGlobalNode 
       end function is_interface_block

       subroutine interface_point_coords(&
            GridDescriptor,&
            lGlobalTreeNode,&
            nDim,&
            Xyz_D,&
            nIndex,&
            iIndex_I,&
            IsInterfacePoint)
         use CON_grid_descriptor
         implicit none
         type(GridDescriptorType),intent(in)::GridDescriptor
         integer,intent(in)::lGlobalTreeNode,nIndex
         logical,intent(out)::IsInterfacePoint
         integer,intent(in)::nDim
         real,intent(inout)::Xyz_D(nDim)
         integer,intent(inout)::iIndex_I(nIndex)
       end subroutine interface_point_coords

       subroutine mapping(&
            nDimFrom,XyzFrom_D,nDimTo,XyzTo_D,IsInterfacePoint)
         implicit none                                                  
         integer,intent(in)::nDimFrom,nDimTo       
         real,dimension(nDimFrom),intent(in)::XyzFrom_D
         real,dimension(nDimTo),intent(out)::XyzTo_D
         logical,intent(out)::IsInterfacePoint
       end subroutine mapping

       subroutine interpolate(&
            nDim,&
            Xyz_D,&
            GridDescriptor,&
            nIndex,&
            iIndex_II,&
            nImage,&
            Weight_I)
         use CON_grid_descriptor
         implicit none
         integer,intent(in)::nDim
         real,intent(inout)::Xyz_D(nDim)
         type(GridDescriptorType)::GridDescriptor     
         integer,intent(in)::nIndex
         integer,     intent(out):: iIndex_II(0:nIndex,2**nDim)
         integer,intent(out)::nImage
         real,dimension(2**nDim),intent(out)::Weight_I
       end subroutine interpolate
    end interface

    optional::is_interface_block,interface_point_coords
    optional::mapping,interpolate

    character(LEN=*),intent(in),optional::NameMappingVector
    character(LEN=*),intent(in),optional::NameMask

    type(GridDescriptorType),intent(in):: GridDescriptorSource
    type(GridDescriptorType),intent(in):: GridDescriptorTarget
    type(RouterType),intent(inout)::Router
    !EOP
    integer::iProc,nProc
    integer::lGlobalNode,iBlockAll
    integer::iGlobalGridPoint,nGridPointsPerBlock
    logical::IsInterfacePoint
    integer::iImage,nImage,nImagePart,iToPut
    integer::iProcTo,iBlockFrom,iProcFrom,iPE
    integer,dimension(0:Router%nProc-1)::&
         nGetUbound_P,nPutUbound_P

    real,dimension(GridDescriptorTarget%nDim)::&
         XyzTarget_D, XyzStored_D
    real,dimension(GridDescriptorSource%nDim)::XyzSource_D

    integer,dimension(GridDescriptorSource%nDim)::iCell_D
    integer, dimension(Router%nIndexSource)::iIndexGet_I

    integer,dimension(0:Router%nIndexTarget,&
         2**GridDescriptorTarget%nDim)::&
         iIndexPut_II

    integer,dimension(2**GridDescriptorTarget%nDim)::&
         iProcLookUp_I

    integer::nProcToPut,iProcToPut
    logical::DoCountOnly,DoCountRed

    real,dimension(2**GridDescriptorTarget%nDim)::Weight_I 

    real,dimension(:,:),pointer::XyzMapping_DI

    logical,dimension(:),pointer::Used_I
    logical::UseMask,UseMappingVector,UseMappingFunction
    logical::DoInterpolate,DoCheckBlock,DoCheckPoint
    integer::iError,iFile
    logical::DoTest,DoTestMe

    character(LEN=100):: NameFile
    !------------------------

    !For given PE the number in the communicator is:
    iProc=Router%iProc
    !

    !Return if the processor does not belong to the communicator
    if(iProc<0)return

    DoTest=.false.; DoTestMe=.false.


    !Check a presence of mapping array.
    !Associate pointer if required.

    UseMappingVector=present(NameMappingVector)

    if(UseMappingVector)&
         call associate_with_global_vector(&
         XyzMapping_DI,NameMappingVector)

    UseMask=present(NameMask)

    if(UseMask)then
       call associate_with_global_mask(&
            Used_I,NameMask)
    end if
    if(UseMask)then
       NameFile = 'router_'//NameMask
       call CON_set_do_test(trim(NameFile),DoTest,DoTestMe)
       NameFile = 'from_source_'//NameFile
    else
       NameFile ='router_'//NameMappingVector
       if(UseMappingVector)call CON_set_do_test(&
            trim(NameFile),DoTest,DoTestMe)
       NameFile = 'from_source_'//NameFile
    end if

    DoTestMe=DoTest.and.iProc==Router%iProc0Source
    if(DoTestMe)write(*,*)'Router from source starts'

    UseMappingFunction=present(mapping)

    if(.not.(UseMappingFunction.or.UseMappingVector).and.&
         GridDescriptorTarget%nDim/=GridDescriptorSource%nDim)&
         call CON_stop(&
         'Mapping is needed for Target%nDim/=Source%nDim')
    nProc=Router%nProc

    DoCheckBlock=present(is_interface_block)
    DoCheckPoint=present(interface_point_coords)
    DoInterpolate=present(interpolate)

    !Check dimensions

    DoCountOnly=.true. !To enter the loop
    do while(DoCountOnly)
       call check_router_allocation(Router)


       !Store Upper bounds to control if the alllocated index array    !
       !have sufficient size
       do iPE=0,nProc-1
          nGetUbound_P(iPE)=ubound(Router%iGet_P(iPE)%iCB_II,2)
          nPutUbound_P(iPE)=ubound(Router%iPut_P(iPE)%iCB_II,2)
       end do

       DoCountOnly=.false.

       !If the check shows that the allocated array is not sufficient, ! 
       !DoCountOnly will be set to true. The loop then will be repeated!
       ! for the second time

       if(DoTestMe)then
          iFile=io_unit_new()
          open(iFile,file=NameFile,status='replace')
          write(iFile,*)'iPointGlobal Xyz_D'
          write(iFile,*)'iProcTo   iCB indexes  Weitht  Sum(Weight)'//&
               'iImage '
       end if


       !Initialize the counters
       Router%nGet_P=0
       Router%nPut_P=0
       Router%nSend_P=0
       Router%nRecv_P=0

       nGridPointsPerBlock=n_grid_points_per_block(&
            GridDescriptorSource)

       !Block loop
       do iBlockAll=1,n_block_total(GridDescriptorSource%DD%Ptr)

          !Skip non-end octree nodes, if any                              !
          lGlobalNode=i_global_node_a(&
               GridDescriptorSource%DD%Ptr,iBlockAll)

          call pe_and_blk(&
               GridDescriptorSource%DD%Ptr,lGlobalNode,&
               iProcFrom,iBlockFrom)


          !Skip the block if desired: if there is known to be no interface!
          ! point in it
          if( DoCheckBlock)then
             if(.not.is_interface_block(lGlobalNode))CYCLE
          end if

          !GlobalCellNumber Loop, for a given (octree) block              !
          do iGlobalGridPoint=&
               1+nGridPointsPerBlock*(iBlockAll-1),&
               nGridPointsPerBlock*iBlockAll
             if(UseMask)then
                if(DoTestMe)&
                     write(iFile,*)'iGlobalPoint=',iGlobalGridPoint,&
                     ' Used_I=', Used_I(iGlobalGridPoint)
                if(.not.Used_I(iGlobalGridPoint))&
                     CYCLE
             end if

             !Treat separately a case when
             !a single-index global vector 
             !is a source

             iIndexGet_I(1) = iGlobalGridPoint
             !This value will be rewritten otherwise

             if(Router%nIndexSource==1.and.&
                  UseMappingVector)then
                XyzTarget_D=XyzMapping_DI(&
                     1:GridDescriptorTarget%nDim,&
                     iGlobalGridPoint)
             else
                call global_i_grid_point_to_icb(&
                     GridDescriptorSource,&
                     iGlobalGridPoint,&
                     lGlobalNode, &
                     iCell_D) 
                if(Router%nIndexSource/=1)then
                   iIndexGet_I(Router%nIndexSource)=iBlockFrom
                   iIndexGet_I(1:GridDescriptorSource%nDim) =&
                        iCell_D
                end if


                if(UseMappingVector)then
                   XyzTarget_D=XyzMapping_DI(&
                        1:GridDescriptorTarget%nDim,&
                        iGlobalGridPoint) 
                else 
                   XyzSource_D=xyz_grid_d(&
                        GridDescriptorSource,&
                        lGlobalNode,&
                        iIndexGet_I(1:GridDescriptorSource%nDim))

                   if( DoCheckPoint)then
                      call interface_point_coords(&
                           GridDescriptorSource,&
                           lGlobalNode,&
                           GridDescriptorSource%nDim,&
                           XyzSource_D,&
                           Router%nIndexSource,&
                           iIndexGet_I,&
                           IsInterfacePoint)
                      if(.not.IsInterfacePoint)CYCLE 
                   end if
                   if(UseMappingFunction)then
                      call mapping(GridDescriptorSource%nDim,&
                           XyzSource_D,&
                           GridDescriptorTarget%nDim,&
                           XyzTarget_D,&
                           IsInterfacePoint)
                      if(.not.IsInterfacePoint)CYCLE 
                   else
                      XyzTarget_D=XyzSource_D
                   end if   !Mapping function
                end if  !MappingVector
             end if  !Global vector as a source
             if(DoTestMe)then
                XyzStored_D=XyzTarget_D
                write(iFile,*)iGlobalGridPoint,XyzTarget_D
             end if
             if( DoInterpolate)then
                call interpolate(&
                     GridDescriptorTarget%nDim,&
                     XyzTarget_D,&
                     GridDescriptorTarget,&
                     Router%nIndexTarget,&
                     iIndexPut_II,&
                     nImage,&
                     Weight_I)
             else
                call nearest_grid_points(&
                     GridDescriptorTarget%nDim,&   
                     XyzTarget_D,&
                     GridDescriptorTarget,&
                     Router%nIndexTarget,&
                     iIndexPut_II,&
                     nImage,&
                     Weight_I)
             end if
             if(nImage<1)then
                write(*,*)'nImage=', nImage
                call CON_stop('interpolation failed in router from source')
             end if
             if(DoTestMe)then
                do iImage=1,nImage
                   if(iImage==1)then
                      write(iFile,*)iIndexPut_II(:,iImage),Weight_I(iImage),&
                           sum(Weight_I(1:nImage))
                   else
                      write(iFile,*)iIndexPut_II(:,iImage),Weight_I(iImage),&
                           iImage
                   end if
                end do
                if(Router%nIndexTarget==&
                     GridDescriptorTarget%nDim+1)then
                   XyzTarget_D=0.0
                   do iImage=1,nImage
                      XyzTarget_D=&
                           XyzTarget_D+&
                           xyz_grid_d(GridDescriptorTarget,&
                           i_global_node_bp(&
                           GridDescriptorTarget%DD%Ptr,&
                           iIndexPut_II(Router%nIndexTarget,iImage),&
                           iIndexPut_II(0,iImage)),&
                           iIndexPut_II(1:GridDescriptorTarget%nDim,&
                           iImage))*Weight_I(iImage)

                   end do
                   write(iFile,*)'Interpolated coordinate values=',&
                        XyzTarget_D,' Error=',&
                        sqrt(sum((XyzTarget_D-XyzStored_D)**2))
                end if
                write(iFile,*)
             end if
             !See interface
             !--------------------------------------!
             !Lookup

             nImagePart=0     !At all CPUs

             do iImage=1,nImage
                iProcTo=iIndexPut_II(0,iImage)
                !At the target PEs the number of terms 
                !in the partial sums are found

                if(iProc==iProcTo)then
                   nImagePart=nImagePart+1
                   Router%nPut_P(iProcFrom)=&
                        Router%nPut_P(iProcFrom)+1
                   DoCountOnly=DoCountOnly.or.&
                        Router%nPut_P(iProcFrom)>&
                        nPutUbound_P(iProcFrom)
                end if

                !At the source processor the PE list is defined !
                !which will get the  partial sums
                if(iProc==iProcFrom)then
                   if(iImage==1)then
                      iProcLookUp_I(1)=iProcTo
                      nProcToPut=1
                      Router%nGet_P(iProcTo)=&
                           Router%nGet_P(iProcTo)+1
                      Router%nSend_P(iProcTo)=&
                           Router%nSend_P(iProcTo)+1
                      DoCountOnly=DoCountOnly.or.&
                           Router%nGet_P(iProcTo)>&
                           nGetUbound_P(iProcTo)
                   else
                      if(.not.any(iProcLookUp_I(&
                           1:nProcToPut)==iProcTo))then
                         nProcToPut=nProcToPut+1
                         iProcLookUp_I(nProcToPut)=iProcTo
                         Router%nGet_P(iProcTo)=&
                              Router%nGet_P(iProcTo)+1
                         Router%nSend_P(iProcTo)=&
                              Router%nSend_P(iProcTo)+1
                         DoCountOnly=DoCountOnly.or.&
                              Router%nGet_P(iProcTo)>&
                              nGetUbound_P(iProcTo)
                      end if
                   end if
                end if
             end do

             if(nImagePart>0)Router%nRecv_P(iProcFrom)=&
                  Router%nRecv_P(iProcFrom)+1

             if(.not.DoCountOnly)then
                do iImage=1,nImage
                   iProcTo=iIndexPut_II(0,iImage)
                   if(iProc==iProcTo)then
                      iToPut= Router%nPut_P(iProcFrom)+1&
                           -nImagePart
                      Router%iPut_P(iProcFrom)%iCB_II(:,iToPut)&
                           =iIndexPut_II(:,iImage)
                      Router%iPut_P(iProcFrom)%iCB_II(0,iToPut)&
                           =nImagePart
                      Router%Put_P(iProcFrom)%Weight_I(iToPut)&
                           =Weight_I(iImage)
                      Router%DoAdd_P(iProcFrom)%&
                           DoAdd_I(iToPut)=.true.
                      nImagePart=nImagePart-1
                   end if
                end do
                if(iProc==iProcFrom)then
                   do iProcToPut=1,nProcToPut
                      iProcTo=iProcLookUp_I(iProcToPut)
                      Router%iGet_P(iProcTo)%&
                           iCB_II(1:Router%nIndexSource,&
                           Router%nGet_P(iProcTo))&
                           =iIndexGet_I(1:Router%nIndexSource)
                      Router%iGet_P(iProcTo)%&
                           iCB_II(0,Router%nGet_P(iProcTo))&
                           =1
                      Router%Get_P(iProcTo)%&
                           Weight_I(Router%nGet_P(iProcTo))&
                           =cOne
                   end do
                   ! The efficient way to properly find doadd's is not 
                   ! found yet. For a while the target state vector which
                   ! is filled in with this subroutine, should be nullified
                   ! before applying the global message pass  
                end if
             end if
          end do !Global cell
       end do    !Target block
       if(DoTestMe)close(iFile)
    end do       !Check if DoCountOnly
    if(UseMappingVector)nullify(XyzMapping_DI)
    if(UseMask)nullify(Used_I)
  end subroutine construct_router_from_source
  !====================================
  subroutine set_semi_router_from_target(&
       ! the GridDescriptor for the Source component
       GridDescriptorSource, &
       ! the GridDescriptor for the Target component
       GridDescriptorTarget, &
       ! the router to be set
       Router, &
       !Logical function which allows to skip the block if there is no !
       !interface points in it. Optional, if not present then all the  !
       !blocks are checked for the presence of the interface points    !
       is_interface_block,&
       !The subroutine which defines if the grid point is inside the   !
       !interface layer. Optional, if not present, then all the grid   !
       !points (at the target grid) are considered as the interface    !
       !layer points                                                   !     
       interface_point_coords, &
       ! transformation of the location coordinates between components
       mapping, &
       ! interpolation subroutine for the Source's grid
       interpolate)
    !-------------------------------------------------------------------------!
    type(GridDescriptorType),intent(in)   :: GridDescriptorSource
    type(GridDescriptorType),intent(in)   :: GridDescriptorTarget
    type(RouterType),        intent(inout):: Router
    !INPUT ARGUMENTS:
    interface
       logical function is_interface_block(lGlobalNode)
         implicit none
         integer,intent(in)::lGlobalNode 
       end function is_interface_block
       subroutine interface_point_coords(&
            GridDescriptor,&
            lGlobalTreeNode,&
            nDim,&
            Xyz_D,&
            nIndex,&
            iIndex_I,&
            IsInterfacePoint)
         use CON_grid_descriptor
         implicit none
         type(GridDescriptorType),intent(in)::GridDescriptor
         integer,intent(in)::lGlobalTreeNode,nIndex
         logical,intent(out)::IsInterfacePoint
         integer,intent(in)::nDim
         real,intent(inout)::Xyz_D(nDim)
         integer,intent(inout)::iIndex_I(nIndex)
       end subroutine interface_point_coords
       !----------------------------------------------------------------------!
       subroutine mapping(nDimIn, CoordIn_D, nDimOut, CoordOut_D, &
            IsInterfacePoint)
         ! this subroutine mapss coordinates between components
         integer, intent(in) :: nDimIn
         real,    intent(in) :: CoordIn_D(nDimIn)
         integer, intent(in) :: nDimOut
         real,    intent(out):: CoordOut_D(nDimOut)
         logical, intent(out):: IsInterfacePoint
       end subroutine mapping
       !----------------------------------------------------------------------!
       subroutine interpolate(&
            nDim, Xyz_D, GridDescriptor, &
            nIndex, iIndex_II, nImage, Weight_I)
         ! interpolation on Source's grid; 
         ! provides PE and indices to access images of
         ! data location and interpolation weights
         use CON_grid_descriptor
         implicit none
         ! number of indices per data entry
         integer, intent(in):: nDim
         ! data location on Source
         real,    intent(inout):: Xyz_D(nDim)
         ! grid descriptor
         type(GridDescriptorType):: GridDescriptor
         ! indices of images, their number and interpolation weights
         integer, intent(in) :: nIndex
         integer, intent(out):: iIndex_II(0:nIndex,2**GridDescriptor%nDim)
         integer, intent(out):: nImage
         real,    intent(out):: Weight_I(2**GridDescriptor%nDim)
       end subroutine interpolate
    end interface
    optional:: is_interface_block
    optional:: interface_point_coords
    optional:: mapping
    optional:: interpolate
    !-------------------------------------------------------------------------!
    !==========================Declarations from set_target===================!
    !EOP
    ! MPI-related variables
    integer :: iProc, nProc
    integer :: lGlobalNode, iBlockAll
    integer :: iGlobalGridPoint, nGridPointsPerBlock
    logical :: IsInterfacePoint
    integer :: iImage, nImage !!!,nImagePart,iToGet
    integer :: iProcTo, iBlockTo, iProcFrom, iProcDoNotAdd, iPE
    integer, dimension(0:Router%nProc-1)::&
         nGetUbound_P,nPutUbound_P

    real,    dimension(GridDescriptorTarget%nDim) :: XyzTarget_D
    real,    dimension(GridDescriptorSource%nDim) ::&
         XyzSource_D !,XyzStored_D
    integer, dimension(GridDescriptorTarget%nDim) ::iCell_D
    integer, dimension(Router%nIndexTarget)       :: iIndexRecv_I
    integer, dimension(0:Router%nIndexSource,&
         2**GridDescriptorSource%nDim)            :: iIndexGet_II
    integer, dimension(2**GridDescriptorSource%nDim) :: &
         iProcLookUp_I
    integer :: nProcToGet, iProcToGet
    logical :: DoCountOnly, DoCountRed
    real,    dimension(2**GridDescriptorSource%nDim) :: Weight_I
    !\
    ! The presunce of optional parameters
    !/
    logical :: UseMappingFunction, &
         DoCheckBlock ,DoCheckPoint,DoInterpolate

    !integer :: iError
    !logical :: DoTest,DoTestMe
    !==========================End of declaration from set_target=============!
    ! components ids
    integer:: iCompSource, iCompTarget
    ! dimensionality of components
    integer:: nDimSource, nDimTarget
    ! number of indices (e.g. cell indices) on components
    integer:: nIndexSource, nIndexTarget
    ! loop variables
    integer:: iIndex, iBuffer
    ! send and recv buffers
    ! buffers' size
    integer:: nBufferSMax, nBufferTarget
    ! offsets in buffers
    integer:: nSendCumSum
    ! aux arrays to put data in BufferS_II in the correct order
    integer, allocatable:: iProcImage_I(:), iOrderSend_I(:)   
    ! optional actions to be taken
    ! aux variables to go through a buffer
    integer:: iAuxStart, iAuxEnd 
    ! number of auxilary variables passed via request
    integer:: nAux
    integer, parameter:: iPointGlobal_ = 0,  &    
         iPointInBlock_ = 2, iBlockAll_ = 1 
    integer :: iGlobalPointLast, iPointInBlock 
    integer :: iAux_I(0:2), iAux
    ! error message containers
    character(len=200):: StringErrorFormat, StringErrorMessage
    character(len=*),parameter:: NameSub = &
         'CON_router:set_semi_router_from_target'
    !-------------------------------------------------------------------------!
    ! identify components
    iCompSource = Router%iCompSource
    iCompTarget = Router%iCompTarget

    !For given PE the index in the communicator is:
    iProc = Router % iProc

    !Return if the processor does not belong to the communicator
    if(iProc<0) RETURN

    ! determine which optional actions should be taken
    UseMappingFunction        = present(mapping)
    DoInterpolate             = present(interpolate)
    ! introduced for a better readability
    nDimTarget   = GridDescriptorTarget%nDim
    nDimSource   = GridDescriptorSource%nDim
    nIndexTarget = Router%nIndexTarget
    nIndexSource = Router%nIndexSource
    if(.not.UseMappingFunction.and.&
         nDimTarget /= nDimSource )&
         call CON_stop(&
         'Mapping is needed for Target%nDim/=Source%nDim')
    nProc=Router%nProc
    ! some data will be sent to Source, determine amount:
    ! cell and block indexes are sent
    nAux = Router%nMappedPointIndex
    !\
    ! Temporary: to be removed
    !/
    Router%iCoordStart         = 1
    Router%iCoordEnd = GridDescriptorSource%nDim
    Router%iAuxStart = Router%iCoordEnd + 1
    Router%nVar      = Router%iCoordEnd + Router%nMappedPointIndex
    Router%iAuxEnd   = Router%iCoordEnd + Router%nMappedPointIndex
    !\
    ! Stage 1:
    ! on Target PE determine the sources of data and
    ! how much data is to be requested from them
    !/
    if(.not.is_proc(iCompTarget))RETURN
    DoCheckBlock=present(is_interface_block)
    DoCheckPoint=present(interface_point_coords)

    !Check dimensions
    DoCountOnly=.true. !To enter the loop
    do while(DoCountOnly)
       call check_router_allocation(Router)
       !\
       !Store Upper bounds to control if the alllocated     !
       !index arrays have sufficient size
       do iPE = 0, nProc-1
          nPutUbound_P(iPE) = ubound(Router%iPut_P(iPE)%iCB_II,2)
       end do     
       ! which processor holds a current image
       call check_size(1, (/Router%nBufferTarget/), iBuffer_I = iProcImage_I)
       ! correct order of images in the send buffer
       call check_size(1, (/Router%nBufferTarget/), iBuffer_I = iOrderSend_I)
       ! reset basic coupling information
       Router%nPut_P  = 0
       Router%nRecv_P = 0
       ! reset index of a current data entry in the buffer
       iBuffer = 0
       DoCountOnly=.false.
       !\
       !If the check shows that the allocated array is not 
       !sufficient, then DoCountOnly will be set to true. The loop 
       !then will be repeated for the second time
       !/
       nGridPointsPerBlock=n_grid_points_per_block(&
            GridDescriptorTarget)
                                                            !
       BLOCKS: do iBlockAll = 1, &
            n_block_total(GridDescriptorTarget%DD%Ptr)

          lGlobalNode=i_global_node_a(&
               GridDescriptorTarget%DD%Ptr,iBlockAll)

          call pe_and_blk(&
               GridDescriptorTarget%DD%Ptr,lGlobalNode,&
               iProcTo, iBlockTo)
          if(iProc /= iProcTo)CYCLE BLOCKS 
          !Skip the block if desired: if there is known to be no interface!
          !point in it                                                    !
          if( DoCheckBlock)then
             if(.not.is_interface_block(lGlobalNode))CYCLE BLOCKS
          end if
          !GlobalCellNumber Loop, for a given (octree) block 
          !\
          ! Global number of the last grid point in the previous
          ! global block, with the global block number = nBlockAll-1
          !/
          iGlobalPointLast = nGridPointsPerBlock*(iBlockAll-1)
          POINTS:do iPointInBlock  = 1, nGridPointsPerBlock
             iGlobalGridPoint =   iGlobalPointLast + iPointInBlock
             call global_i_grid_point_to_icb(&
                  GridDescriptorTarget,&
                  iGlobalGridPoint,&
                  lGlobalNode,& 
                  iCell_D)
             
             if(nIndexTarget/=1)then
                iIndexRecv_I(nIndexTarget) = iBlockTo
                iIndexRecv_I(1:nDimTarget) = &
                     iCell_D
             end if
             XyzTarget_D = xyz_grid_d(&
                  GridDescriptorTarget,&
                  lGlobalNode,&
                  iCell_D)
             if( DoCheckPoint)then
                call interface_point_coords(&
                     GridDescriptorTarget,&
                     lGlobalNode,&
                     nDimTarget,&
                     XyzTarget_D,&
                     nIndexTarget,&
                     iIndexRecv_I,&
                     IsInterfacePoint)
                if(.not.IsInterfacePoint)CYCLE POINTS
             end if
             if(UseMappingFunction)then
                call mapping(&
                     nDimTarget,&
                     XyzTarget_D,&
                     nDimSource,&
                     XyzSource_D, &
                     IsInterfacePoint)
             else
                XyzSource_D=XyzTarget_D
             end if
               
             if( DoInterpolate)then
                call interpolate(&
                     nDim           = nDimSource, &
                     Xyz_D          = XyzSource_D, &
                     GridDescriptor = GridDescriptorSource, &
                     nIndex         = nIndexSource, &
                     iIndex_II      = iIndexGet_II, &
                     nImage         = nImage, &
                     Weight_I       = Weight_I)
             else
                call nearest_grid_points(&
                     nDim           = nDimSource, &
                     Xyz_D          = XyzSource_D, &
                     GridDescriptor = GridDescriptorSource, &
                     nIndex         = nIndexSource, &
                     iIndex_II      = iIndexGet_II, &
                     nImage         = nImage, &
                     Weight_I       = Weight_I)
             end if
             if(nImage < 1)then
                write(StringErrorFormat,'(a,i3,a)') '(a,',nDimSource,'es15.7)'
                write(StringErrorMessage,StringErrorFormat)&
                     NameSub//': Interpolation failed at location ', &
                     XyzSource_D
                call CON_stop(StringErrorMessage)
             end if

             ! go over the list of images and process result of interpolation
             IMAGES1:do iImage = 1, nImage
                iProcFrom = iIndexGet_II(0, iImage)
                if(iImage==1)then
                   iProcLookUp_I(1)=iProcFrom
                   nProcToGet=1
                else
                   if(.not.any(iProcLookUp_I(&
                        1:nProcToGet)==iProcFrom))then
                      nProcToGet=nProcToGet+1
                      iProcLookUp_I(nProcToGet)=iProcFrom
                   else
                      CYCLE IMAGES1
                   end if
                end if
                ! index of current data entry in the buffer
                Router%nPut_P(iProcFrom)=&
                     Router%nPut_P(iProcFrom) + 1
                Router%nRecv_P(iProcFrom)=&
                     Router%nRecv_P(iProcFrom) + 1
                
                DoCountOnly = DoCountOnly.or.&
                     Router%nPut_P(iProcFrom)>&
                     nPutUbound_P(iProcFrom)  
             end do IMAGES1 
             if(.not.DoCountOnly)then
                PROCFROM:do iProcToGet=1,nProcToGet
                   iProcFrom=iProcLookUp_I(iProcToGet)
                   Router%iPut_P(iProcFrom)%&
                        iCB_II(1:Router%nIndexTarget,&
                        Router%nPut_P(iProcFrom))&
                        =iIndexRecv_I(1:Router%nIndexTarget)
                   Router%iPut_P(iProcFrom)%&
                        iCB_II(0,Router%nPut_P(iProcFrom))&
                        =1
                   Router%Put_P(iProcFrom)%&
                        Weight_I(Router%nPut_P(iProcFrom))&
                        = 1.0
                   Router%DoAdd_P(iProcFrom)%&
                        DoAdd_I(Router%nRecv_P(iProcFrom))=&
                        .true.
                   ! indices of the location where data has to be put
                   ! store processor id for later use
                   iBuffer = iBuffer + 1
                   iProcImage_I(iBuffer) = iProcFrom
                   
                   ! index of the image in the buffer FOR CURRENT source processor
                   iOrderSend_I(iBuffer) = Router%nRecv_P(iProcFrom)
                   
                   ! fill the buffer to be sent
                   ! coordinates on Source
                   Router%BufferTarget_II(&
                        Router%iCoordStart:Router%iCoordEnd,iBuffer)=&
                        XyzSource_D
                   if(nAux > 0)then
                      iAux_I(iPointGlobal_ ) = iGlobalGridPoint   
                      iAux_I(iPointInBlock_) = iPointInBlock
                      iAux_I(iBlockAll_    ) = iBlockAll
                      Router%BufferTarget_II(&
                           Router%iAuxStart:Router%iAuxEnd,iBuffer) = &
                           real(iAux_I(1:nAux))
                   end if
                end do PROCFROM
                !DoAdd should be set to .false. for the same PE or for
                !the minimal PE
                if(any(iProcLookUp_I(&
                     1:nProcToGet)==iProcTo))then
                   iProcDoNotAdd=iProcTo
                else
                   iProcDoNotAdd=minval(&
                        iProcLookUp_I(1:nProcToGet))
                end if
                Router%DoAdd_P(iProcDoNotAdd)%&
                     DoAdd_I(Router%nRecv_P(iProcDoNotAdd))=&
                     .false.
                
             end if
          end do POINTS   !iGlobalPoints
       end do BLOCKS      !iGlobalBlock
    end do         !

    ! all data locations are processed, save the actual size of the buffer
    nBufferTarget = iBuffer
    ! fix the order of Buffer_I so contiguous chunks of data can be sent
    ! to the appropriate processors of Source,
    ! currently iOrderSend_I contains indices WITHIN these chunks
    nSendCumSum = 0
    do iProcFrom = i_proc0(iCompSource), i_proc_last(iCompSource), &
         i_proc_stride(iCompSource)
       where(iProcImage_I(1:Router%nBufferTarget) == iProcFrom)&
            iOrderSend_I(1:Router%nBufferTarget)= &
            iOrderSend_I(1:Router%nBufferTarget)+nSendCumSum
       nSendCumSum = nSendCumSum + Router%nRecv_P(iProcFrom)
    end do

    ! the correct order is found, apply it
    Router%BufferTarget_II(:,iOrderSend_I(1:nBufferTarget)) = &
         Router%BufferTarget_II(:,1:nBufferTarget)
  end subroutine set_semi_router_from_target
  !===============================================
  subroutine synchronize_router_target_to_source(Router)
    type(RouterType),        intent(inout):: Router

    integer:: nRecvCumSum, nRecvCumSumMy, nSendCumSum

    ! MPI-related variables
    integer, allocatable:: iStatus_II(:,:), iRequestS_I(:), iRequestR_I(:)
    integer:: nRequestR, nRequestS, iError, iTag=0
    integer:: iProc, nProc
    integer:: iProcFrom, iProcTo
    !-------------------------------------------------------------------------!
    !For given PE the index in the communicator is:
    iProc = Router % iProc

    !Return if the processor does not belong to the communicator
    if(iProc<0) RETURN
    ! identify components
    ! total number of processors and on components
    nProc       = Router%nProc
    !\
    ! Temporary: to be removed
    !/
    Router%iCoordStart         = 1
    Router%iCoordEnd = 3!!!!!!!!!!!!!!!!!
    Router%iAuxStart = Router%iCoordEnd + 1
    Router%nVar      = Router%iCoordEnd + Router%nMappedPointIndex
    Router%iAuxEnd   = Router%iCoordEnd + Router%nMappedPointIndex
    !\
    ! Stage 2:
    ! send the router info to Source:
    ! first, send the amount of data to be received,
    ! then the info itself (stored in buffer on Target)
    !/
    call check_size(1, (/nProc/), iBuffer_I = iRequestS_I)
    call check_size(1, (/nProc/), iBuffer_I = iRequestR_I)
    call check_size(2, (/MPI_STATUS_SIZE, 2*nProc/), iBuffer_II = iStatus_II)

    ! post recvs
    nRequestR = 0
    if(is_proc(Router%iCompSource))then
       do iProcFrom = i_proc0(Router%iCompTarget), i_proc_last(Router%iCompTarget), &
            i_proc_stride(Router%iCompTarget)
          !\
          ! Do not wait for the message from self
          !/
          if(iProc==iProcFrom)CYCLE
          nRequestR = nRequestR + 1
          call MPI_Irecv(Router % nSend_P(iProcFrom), 1, MPI_INTEGER,&
               iProcFrom, iTag, Router%iComm, iRequestR_I(nRequestR), iError)
       end do
    end if

    ! post sends
    nRequestS = 0
    if(is_proc(Router%iCompTarget))then
       do iProcTo =  i_proc0(Router%iCompSource), i_proc_last(Router%iCompSource), &
            i_proc_stride(Router%iCompSource)
          !\
          !Copy, if needed
          !/
          if(iProc==iProcTo)then
             Router % nSend_P(iProc) = Router % nRecv_P(iProc)
             CYCLE
          end if
          nRequestS = nRequestS + 1
          call MPI_Isend(Router % nRecv_P(iProcTo), 1, MPI_INTEGER,&
               iProcTo, iTag, Router%iComm, iRequestS_I(nRequestS), iError)
       end do
    end if

    ! Finalize transfer                                                       
    call MPI_waitall(nRequestR, iRequestR_I, iStatus_II, iError)
    call MPI_waitall(nRequestS, iRequestS_I, iStatus_II, iError)

    !\
    ! send the actual router info
    !/
    ! post recvs
    nRequestR = 0
    if(is_proc(Router%iCompSource))then
       ! size of the recv buffer
       Router%nBufferSource = sum(Router%nSend_P)

       call check_size(2, (/Router%nVar, Router%nBufferSource/),&
            PBuffer_II=Router%BufferSource_II)
       Router%BufferSource_II = 0

       nRecvCumSum = 0
       do iProcFrom =  i_proc0(Router%iCompTarget), i_proc_last(Router%iCompTarget),&
            i_proc_stride(Router%iCompTarget)
          if(Router%nSend_P(iProcFrom) == 0)&
               CYCLE
          !\
          ! Do not wait for the message from self
          !/
          if(iProc==iProcFrom)then
             nRecvCumSumMy = nRecvCumSum
          else
             nRequestR = nRequestR + 1
             call MPI_Irecv(Router%BufferSource_II(1:Router%nVar,&
                  1+nRecvCumSum:Router%nSend_P(iProcFrom)+nRecvCumSum), &
                  Router%nSend_P(iProcFrom)*Router%nVar, MPI_REAL,&
                  iProcFrom, iTag, Router%iComm, iRequestR_I(nRequestR), iError)
          end if
          nRecvCumSum = nRecvCumSum + Router%nSend_P(iProcFrom)
       end do
    end if

    ! post sends
    nRequestS = 0
    if(is_proc(Router%iCompTarget))then
       nSendCumSum = 0
       do iProcTo =  i_proc0(Router%iCompSource), i_proc_last(Router%iCompSource), &
            i_proc_stride(Router%iCompSource)
          if(Router % nRecv_P(iProcTo) == 0)&
               CYCLE
          if(iProcTo==iProc)then
             Router%BufferSource_II(:,1+nRecvCumSumMy:nRecvCumSumMy+Router%nSend_P(iProc)) = &
                  Router%BufferTarget_II(:,1+nSendCumSum:nSendCumSum+Router%nRecv_P(iProcTo))
          else
             nRequestS = nRequestS + 1
             call MPI_Isend(Router%BufferTarget_II(1:Router%nVar,&
                  1+nSendCumSum:Router%nRecv_P(iProcTo)+nSendCumSum), &
                  Router%nRecv_P(iProcTo)*Router%nVar, MPI_REAL,&
                  iProcTo, iTag, Router%iComm, iRequestS_I(nRequestS), iError)
          end if
          nSendCumSum = nSendCumSum + Router%nRecv_P(iProcTo)
       end do
    end if

    ! Finalize transfer                                                       
    call MPI_waitall(nRequestR, iRequestR_I, iStatus_II, iError)
    call MPI_waitall(nRequestS, iRequestS_I, iStatus_II, iError)
  end subroutine synchronize_router_target_to_source
  !===============================================
  subroutine update_semi_router_at_source(&
       Router,              &
       GridDescriptorSource,&
       interpolate)
    integer :: iCompSource
    integer :: iCompTarget
    type(RouterType),        intent(inout):: Router
    type(GridDescriptorType),intent(in)   :: GridDescriptorSource
    interface
       subroutine interpolate(&
            nDim, Xyz_D, GridDescriptor, &
            nIndex, iIndex_II, nImage, Weight_I)
         ! interpolation on Source's grid; 
         ! provides PE and indices to access images of
         ! data location and interpolation weights
         use CON_grid_descriptor
         implicit none
         ! number of indices per data entry
         integer, intent(in):: nDim
         ! data location on Source
         real,    intent(inout):: Xyz_D(nDim)
         ! grid descriptor
         type(GridDescriptorType):: GridDescriptor
         ! indices of images, their number and interpolation weights
         integer, intent(in) :: nIndex
         integer, intent(out):: iIndex_II(0:nIndex,2**GridDescriptor%nDim)
         integer, intent(out):: nImage
         real,    intent(out):: Weight_I(2**GridDescriptor%nDim)
       end subroutine interpolate
    end interface
    !optional:: interpolate
    integer:: nRecvCumSum
    integer:: iStart, iEnd, iProcTo, iBuffer, iProcFrom, iToGet
    integer:: iProc, nProc
    ! interpolation-related variables
    integer:: iIndexGet_II(&
         0:GridDescriptorSource%nDim+1, &
         2**GridDescriptorSource%nDim)
    real :: XyzSource_D(GridDescriptorSource%nDim)
    real :: Weight_I(2**GridDescriptorSource%nDim)
    integer:: iImage, nImage, nImageMax, nImagePart
    integer:: nAux, nDimSource, nIndexSource


    !For given PE the index in the communicator is:
    iProc = Router % iProc

    !Return if the processor does not belong to the communicator
    if(iProc<0) RETURN
    ! identify components
    iCompSource = Router%iCompSource
    iCompTarget = Router%iCompTarget
    ! total number of processors and on components
    nProc       = Router%nProc
    !\
    ! Stage 3 set semi-router for source
    !/
    ! process the data that has been received
    !\
    ! Temporary: to be removed
    !/
    Router%iCoordStart         = 1
    Router%iCoordEnd = GridDescriptorSource%nDim
    Router%iAuxStart = Router%iCoordEnd + 1
    Router%nVar      = Router%iCoordEnd + Router%nMappedPointIndex
    Router%iAuxEnd   = Router%iCoordEnd + Router%nMappedPointIndex
    nDimSource  = GridDescriptorSource%nDim
    nIndexSource= Router%nIndexSource

    if(.not.is_proc(Router%iCompSource))RETURN
    nImageMax = 2**nDimSource
    ! prepare containers for router information of Source side
    do iProcTo = i_proc0(iCompTarget), i_proc_last(iCompTarget), &
         i_proc_stride(iCompTarget)
       Router%nGet_P(iProcTo) = Router%nSend_P(iProcTo)*nImageMax
    end do
    call check_router_allocation(Router)
    Router%nGet_P = 0
    ! fill these containers
    nRecvCumSum = 0
    do iProcTo =  i_proc0(iCompTarget), i_proc_last(iCompTarget), &
         i_proc_stride(iCompTarget)
       do iBuffer = nRecvCumSum + 1, &
            nRecvCumSum + Router%nSend_P(iProcTo)
          XyzSource_D = Router%BufferSource_II(&
               Router%iCoordStart:Router%iCoordEnd, iBuffer)
          call interpolate(&
               GridDescriptorSource%nDim,&
               XyzSource_D,&
               GridDescriptorSource,&
               nIndexSource,&
               iIndexGet_II,&
               nImage,&
               Weight_I)
          nImagePart = count(iIndexGet_II(0,1:nImage)==iProc)
          Router%nGet_P(iProcTo) = Router%nGet_P(iProcTo) + nImagePart
          if(nImagePart==0)call CON_stop('No image on the requested PE')
          ! indices
          do iImage=1,nImage
             iProcFrom = iIndexGet_II(0,iImage)
             if(iProc==iProcFrom)then
                iToGet=Router%nGet_P(iProcTo)+1-nImagePart
                Router%iGet_P(iProcTo)%iCB_II(:,iToGet)&
                     =iIndexGet_II(:,iImage)
                Router%iGet_P(iProcTo)%iCB_II(0,iToGet)&
                     =nImagePart
                Router%Get_P(iProcTo)%Weight_I(iToGet)&
                     =Weight_I(iImage)
                nImagePart=nImagePart-1
             end if
          end do
       end do
       ! increment the offset
       nRecvCumSum = nRecvCumSum + Router%nSend_P(iProcTo)
    end do
  end subroutine update_semi_router_at_source
  !===========================================================================!
  subroutine set_semi_router_from_source(&
       ! the GridDescriptor for the Source component
       GridDescriptorSource, &
       ! the GridDescriptor for the Target component
       GridDescriptorTarget, &
       ! the router to be set
       Router, &
       ! the subroutine that provides the location of data on the Source;
       ! this information may be as generic as needed
       get_scatter_source, &
       ! mapping of the location coordinates between components
       mapping, &
       ! interpolation subroutine for the Target's grid
       interpolate_target, &
       ! interpolation subroutine for the Source's grid
       interpolate_source)
    !-------------------------------------------------------------------------!
    type(GridDescriptorType),intent(in)   :: GridDescriptorSource
    type(GridDescriptorType),intent(in)   :: GridDescriptorTarget
    type(RouterType),        intent(inout):: Router

    interface
       subroutine get_scatter_source(&
            nData,  &
            Coord_II, iIndex_II, nAux, iAux_II)
         ! this subroutine returns info that identifies location of the data
         ! in the domain, may be as generic as needed, i.e. Coord_II need NOT
         ! to be the actual coordinates
         implicit none
         ! number of data entries
         integer,       intent(out):: nData
         ! data locations themselves
         real,    allocatable, intent(out):: Coord_II(:,:)
         ! indices to access the data locations on Source
         integer, allocatable, intent(out):: iIndex_II(:,:)
         integer, intent(in):: nAux
         integer, allocatable, intent(out):: iAux_II(:,:)
       end subroutine get_scatter_source
       !----------------------------------------------------------------------!
       subroutine mapping(nDimIn, CoordIn_D, nDimOut, CoordOut_D, &
            IsInterfacePoint)
         ! this subroutine maps location coordinates between components
         integer, intent(in) :: nDimIn
         real,    intent(in) :: CoordIn_D(nDimIn)
         integer, intent(in) :: nDimOut
         real,    intent(out):: CoordOut_D(nDimOut)
         logical, intent(out):: IsInterfacePoint
       end subroutine mapping
       !----------------------------------------------------------------------!
       subroutine interpolate_target(&
            nCoord, Coord_I, GridDescriptor, &
            nIndex, iIndex_II, nImage, Weight_I,&
            nAux, iAux_I)
         ! interpolation on Target's grid; 
         ! provides PE and indices to access images of
         ! data location and interpolation weights
         use CON_grid_descriptor
         implicit none
         ! number of indices per data entry
         integer, intent(in):: nCoord
         ! data location on Target
         real,    intent(inout):: Coord_I(nCoord)
         ! grid descriptor
         type(GridDescriptorType):: GridDescriptor
         ! indices of images, their number and interpolation weights
         integer, intent(in) :: nIndex
         integer, intent(out):: iIndex_II(0:nIndex,2**GridDescriptor%nDim)
         integer, intent(out):: nImage
         real,    intent(out):: Weight_I(2**GridDescriptor%nDim)
         integer, intent(in)::nAux
         integer, intent(in)::iAux_I(nAux)
       end subroutine interpolate_target
       !----------------------------------------------------------------------!
       subroutine interpolate_source(&
            nCoord, Coord_I, GridDescriptor, &
            nIndex, iIndex_II, nImage, Weight_I)
         ! interpolation on Source's grid; 
         ! provides PE and indices to access images of
         ! data location and interpolation weights
         use CON_grid_descriptor
         implicit none
         ! number of indices per data entry
         integer, intent(in):: nCoord
         ! data location on Source
         real,    intent(inout):: Coord_I(nCoord)
         ! grid descriptor
         type(GridDescriptorType):: GridDescriptor
         ! indices of images, their number and interpolation weights
         integer, intent(in) :: nIndex
         integer, intent(out):: iIndex_II(0:nIndex,2**GridDescriptor%nDim)
         integer, intent(out):: nImage
         real,    intent(out):: Weight_I(2**GridDescriptor%nDim)
       end subroutine interpolate_source
    end interface
    optional:: get_scatter_source
    optional:: mapping
    optional:: interpolate_target
    optional:: interpolate_source
    !-------------------------------------------------------------------------!
    ! dimensionality of components
    integer:: nDimTarget, nDimSource
    ! number of generlized coordinates per data location:
    ! includes coordinates plus any aux info that facilitates interpolation

    ! number of indices (e.g. cell indices) on components
    integer:: nIndexSource, nIndexTarget
    ! number of data locations on the current processor
    integer:: nData 
    ! loop variables
    integer:: iIndex, iData, iBuffer, iImageTarget, iImageSource
    integer:: iProcFrom, iProcTo
    ! send and recv buffers
    !    real, allocatable:: BufferS_II(:,:), BufferR_II(:,:)
    ! biffers' size
    integer:: nBufferSMax
    ! offsets in buffers
    integer:: nSendCumSum, nRecvCumSum, nRecvCumSumMy
    ! aux arrays to put data in BufferS_II in the correct order
    integer, allocatable:: iProcImage_I(:), iOrderSend_I(:)
    ! MPI-realated variables
    integer, allocatable:: iStatus_II(:,:), iRequestS_I(:), iRequestR_I(:)
    integer:: nRequestR, nRequestS, iError, iTag=0
    integer:: iProc, nProc
    ! components ids
    integer:: iCompSource, iCompTarget   
    !interpolation-interpolated variables
    integer:: iIndexPut_II(&
         0:GridDescriptorTarget%nDim+1, &
         2**GridDescriptorTarget%nDim)
    integer:: iIndexGet_II(&
         0:GridDescriptorSource%nDim+1, &
         2**GridDescriptorSource%nDim)
    integer:: nImageTarget, nImageTargetMax
    integer:: nImageSource, nImageSourceMax
    real:: WeightTarget_I(2**GridDescriptorTarget%nDim)
    real:: WeightSource_I(2**GridDescriptorSource%nDim)

    integer:: iProcLookup_I(2**GridDescriptorTarget%nDim)
    ! optional actions to be taken
    logical:: &
         DoGetScatterSource, UseMappingFunction, &
         DoInterpolateSource, DoInterpolateTarget
    ! aux variable to go through a buffer
    integer::  iStart, iEnd, iGet, iOffset
    ! variable indices
    integer:: iVarWeight, iVarDimStart, iVarDimEnd, iVarData, nAux
    integer:: nProcToPut

    logical:: IsInterfacePoint
    ! storage for scatter
    real,    allocatable:: Coord_II(:,:)
    integer, allocatable:: iIndex_II(:,:)
    integer, allocatable:: iAux_II(:,:)
    ! aux array that hold router information on Source
    integer, allocatable:: iCB_II(:,:)
    ! interpolation weights on Source
    real,    allocatable:: WeightSource_II(:,:)
    ! aux array to hold coordinate of a location currently being processed
    real, allocatable:: Coord_D(:)
    ! error message containers
    character(len=200):: StringErrorFormat, StringErrorMessage
    character(len=*),parameter:: NameSub = 'CON_router:set_semi_router_from_source'
    !-------------------------------------------------------------------------!
    ! identify components
    iCompSource = compid_grid(GridDescriptorSource%DD%Ptr)
    iCompTarget = compid_grid(GridDescriptorTarget%DD%Ptr)

    !For given PE the index in the communicator is:
    iProc = Router % iProc

    !Return if the processor does not belong to the communicator
    if(iProc<0) RETURN

    ! total number of processors
    nProc       = Router%nProc
    ! reset basic coupling information
    Router%nGet_P  = 0
    Router%nPut_P  = 0
    Router%nSend_P = 0
    Router%nRecv_P = 0

    ! reset sizes of send and recv buffers (BOTH may be used on this proc )
    Router%nBufferSource = 0; Router%nBufferTarget = 0

    ! determine which optional actions should be taken
    DoGetScatterSource = present(get_scatter_source)
    UseMappingFunction= present(mapping)
    DoInterpolateSource= present(interpolate_source)
    DoInterpolateTarget= present(interpolate_target)
    if(.not.DoGetScatterSource .or. .not. DoInterpolateTarget)&
         call CON_stop(NameSub//': this type of call is not implemented yet')

    ! introduced for a better readability
    nDimTarget      = GridDescriptorTarget%nDim
    nDimSource      = GridDescriptorSource%nDim
    nIndexTarget    = Router%nIndexTarget
    nIndexSource    = Router%nIndexSource
    nImageTargetMax = 2**nDimTarget

    nAux = Router%nMappedPointIndex

    ! if interpolation for source is not provided,
    ! it is assumed that each data locations is the only image of itself
    if(DoInterpolateSource)then
       nImageSourceMax = 2**nDimSource
    else
       nImageSourceMax = 1
    end if

    !\
    ! Stage 1:
    ! on Source PE determine the recepients of data and
    ! how much data is to be sent to them
    !/
    if(is_proc(iCompSource))then

       ! get the data locations Source as well as corresponding indices
       call get_scatter_source( nData, &
            Coord_II, iIndex_II, nAux, iAux_II)
       if(.not.allocated(iIndex_II) .and. .not. DoInterpolateSource)&
            call CON_stop(NameSub//&
            ': incorrect call, scatter indices are not provided')


       ! max size of buffer to be sent
       nBufferSMax= nImageTargetMax * nImageSourceMax * nData

       ! make sure that all allocatables are sufficiently large,
       ! if they are => they are not reallocated

       ! passed to interpolation subroutine
       call check_size(1, (/nDimTarget/), Buffer_I = Coord_D)
       ! send buffer
       call check_size(2, (/Router%nVar, nBufferSMax/), PBuffer_II = Router%BufferSource_II)
       ! aux array that holds indices of scatter locations
       call check_size(2, (/(nIndexSource+1)*nImageSourceMax,nBufferSMax/), iBuffer_II=iCB_II)
       ! interpolation weights on Source
       call check_size(2, (/nImageSourceMax,nBufferSMax/), Buffer_II=WeightSource_II)
       ! which processor holds a current image
       call check_size(1, (/nBufferSMax/), iBuffer_I = iProcImage_I)
       ! correct order of images in the send buffer
       call check_size(1, (/nBufferSMax/), iBuffer_I = iOrderSend_I)

       ! reset index of a current data entry in the buffer
       iBuffer = 0

       ! go over the list of scattered data location
       do iData = 1, nData

          ! map coordinates of a data location if needed
          if(UseMappingFunction)then
             call mapping(&
                  nDimSource, Coord_II(1:nDimSource, iData), &
                  nDimTarget, Coord_D( 1:nDimTarget), IsInterfacePoint)
          end if

          ! interpolation procedure yields recepient PE of Target and
          ! indices identifying images,
          ! one data entry may be split into several images
          call interpolate_target(&
               nCoord         = nDimTarget, &
               Coord_I        = Coord_D(1:nDimTarget), &
               GridDescriptor = GridDescriptorTarget, &
               nIndex         = nIndexTarget, &
               iIndex_II      = iIndexPut_II, &
               nImage         = nImageTarget, &
               Weight_I       = WeightTarget_I,&
               nAux           = nAux, &
               iAux_I         = iAux_II(1:nAux,iData))

          ! check if interpolation has succeeded
          if(nImageTarget < 1)then
             write(StringErrorFormat,'(a,i3,a)') '(a,',nDimTarget,'es15.7)'
             write(StringErrorMessage,StringErrorFormat)&
                  NameSub//': Interpolation failed on Target at location ', &
                  Coord_D(1:nDimTarget)
             call CON_stop(StringErrorMessage)
          end if

          ! interpolate on Source if necessary
          if(DoInterpolateSource)then
             call interpolate_source(&
                  nCoord         = nDimSource, &
                  Coord_I        = Coord_II(1:nDimSource, iData), &
                  GridDescriptor = GridDescriptorSource, &
                  nIndex         = nIndexSource, &
                  iIndex_II      = iIndexGet_II, &
                  nImage         = nImageSource, &
                  Weight_I       = WeightSource_I)
             if(nImageSource < 1)then
                write(StringErrorFormat,'(a,i3,a)') '(a,',nDimSource,'es15.7)'
                write(StringErrorMessage,StringErrorFormat)&
                     NameSub//': Interpolation on Source failed at location ',&
                     Coord_D(1:nDimSource)
                call CON_stop(StringErrorMessage)
             end if

             ! IMPORTANT: ALL IMAGES SHOULD BE ON THE CURRENT PROC FOR NOW
             if(any(iIndexGet_II(0,1:nImageSource) /= iProc))then
                write(StringErrorFormat,'(a,i3,a)') &
                     '(a,',nDimSource,'es15.7,a,i6)'
                write(StringErrorMessage,StringErrorFormat)&
                     NameSub//': some images of a scatter location', &
                     Coord_II(1:nDimSource, iData),&
                     ' are not on the processor that provided it, iProc=', &
                     iProc
                call CON_stop(StringErrorMessage)
             end if
          else
             ! scatter location is the only image of itself
             iIndexGet_II(1:nIndexSource,1) = iIndex_II(1:nIndexSource, iData)
             WeightSource_I(1) = 1.0
          end if

          ! go over the list of images and process the result of interpolation
          do iImageTarget = 1, nImageTarget

             ! processor of target the image belongs to
             iProcTo = iIndexPut_II(0, iImageTarget)

             if(iImageTarget==1)then
                iProcLookUp_I(1)=iProcTo
                nProcToPut=1
             else
                if(.not.any(iProcLookUp_I(&
                     1:nProcToPut)==iProcTo))then
                   nProcToPut=nProcToPut+1
                   iProcLookUp_I(nProcToPut)=iProcTo
                else
                   CYCLE
                end if
             end if

             ! index of current data entry in the buffer
             iBuffer = iBuffer + 1

             ! update router info
             Router%nSend_P(iProcTo) = Router%nSend_P(iProcTo) + 1
             Router%nGet_P( iProcTo) = Router%nGet_P( iProcTo) + nImageSource

             ! indices of the location where data has to be fetched from
             ! NOTE:number if images is last entry here,but in router it is 0th
             do iImageSource = 1, nImageSource
                WeightSource_II(iImageSource,iBuffer) = &
                  WeightSource_I(iImageSource)
                iCB_II((1+nIndexSource)*iImageSource, iBuffer) = &
                     nImageSource + 1 - iImageSource
                iStart =  (1+nIndexSource)*(iImageSource-1)+1
                iEnd   =  (1+nIndexSource)*(iImageSource-1)+nIndexSource
                iCB_II(iStart:iEnd, iBuffer) = &
                     iIndexGet_II(1:nIndexSource,iImageSource)
             end do

             ! store processor id for later use
             iProcImage_I(iBuffer) = iProcTo

             ! index of the image in the buffer FOR CURRENT target processor
             iOrderSend_I(iBuffer) = Router%nSend_P(iProcTo)

             ! fill the buffer to be sent
             Router%BufferSource_II(&
                  Router%iCoordStart:Router%iCoordEnd, iBuffer) = &
                  Coord_D(1:nDimTarget) 
              Router%BufferSource_II(&
                  Router%iAuxStart:Router%iAuxEnd,iBuffer) = &
                  real(iAux_II(1:nAux,iData))
           end do !iImageTarget
        end do !iData

       ! all data locations are processed, save the actual size of the buffer
       Router%nBufferSource = iBuffer

       ! fix the order of Buffer_I so contiguous chunks of data can be sent
       ! to the appropriate processors of Target,
       ! currently iOrderSend_I contains indices within these chunks
       nSendCumSum = 0
       do iProcTo =  i_proc0(iCompTarget), i_proc_last(iCompTarget), &
            i_proc_stride(iCompTarget)
          where(iProcImage_I(1:Router%nBufferSource) == iProcTo)&
               iOrderSend_I(1:Router%nBufferSource) = &
               iOrderSend_I(1:Router%nBufferSource)+nSendCumSum
          nSendCumSum = nSendCumSum + Router%nSend_P(iProcTo)
       end do

       ! the correct order is found, apply it
       Router%BufferSource_II(:,iOrderSend_I(1:Router%nBufferSource)) = &
            Router%BufferSource_II(:,1:Router%nBufferSource)
       iCB_II(:,iOrderSend_I(1:Router%nBufferSource)) = &
            iCB_II(:,1:Router%nBufferSource)
       WeightSource_II(:,iOrderSend_I(1:Router%nBufferSource)) = &
            WeightSource_II(:,1:Router%nBufferSource)

       ! prepare containers for router information on Source side
       call check_router_allocation(Router)
       ! fill these containers
       nSendCumSum = 0
       do iProcTo =  i_proc0(iCompTarget), i_proc_last(iCompTarget), &
            i_proc_stride(iCompTarget)
          iGet = 1
          iStart = nSendCumSum + 1
          iEnd = nSendCumSum + Router%nSend_P(iProcTo)
          do iBuffer = iStart, iEnd
             do iImageSource = 1, iCB_II(1+nIndexSource, iBuffer)
                iOffset = (1+nIndexSource) * (iImageSource-1)
                Router%iGet_P( iProcTo) % iCB_II(0:nIndexSource, iGet) =  &
                     cshift(&
                     iCB_II(1+iOffset:1+nIndexSource+iOffset, iBuffer), -1)
                Router%Get_P(iProcTo) % Weight_I(iGet) = &
                     WeightSource_II(iImageSource, iBuffer)
                iGet = iGet+1
             end do
          end do
          nSendCumSum = nSendCumSum + Router%nSend_P(iProcTo)
       end do
    end if
  end subroutine set_semi_router_from_source
  !===========================================================================!
  subroutine synchronize_router_source_to_target(Router)
    type(RouterType), intent(inout):: Router
    integer:: nRecvCumSum, nRecvCumSumMy, nSendCumSum

    ! MPI-related variables
    integer, allocatable:: iStatus_II(:,:), iRequestS_I(:), iRequestR_I(:)
    integer:: nRequestR, nRequestS, iError, iTag=0
    integer:: iProc, nProc
    integer:: iProcFrom, iProcTo
    character(len=*),parameter:: NameSub = &
         'CON_router:synchronize_router_source_to_target'
    !-------------------------------------------------------------------------!

    !For given PE the index in the communicator is:
    iProc = Router % iProc

    !Return if the processor does not belong to the communicator
    if(iProc<0) RETURN

    ! total number of processors and on components
    nProc       = Router%nProc

    !\
    ! Stage 2:
    ! send the router info to Target:
    ! first, send the amount of data to be received,
    ! then the info itself (stored in buffer on Source)
    !/
    call check_size(1, (/nProc/), iBuffer_I = iRequestS_I)
    call check_size(1, (/nProc/), iBuffer_I = iRequestR_I)
    call check_size(2, (/MPI_STATUS_SIZE, 2*nProc/), iBuffer_II = iStatus_II)

    ! post recvs
    nRequestR = 0
    if(is_proc(Router%iCompTarget))then
       do iProcFrom =  i_proc0(Router%iCompSource), i_proc_last(Router%iCompSource), &
            i_proc_stride(Router%iCompSource)
          !\
          ! Do not expect the message from self
          !/
          if(iProcFrom==iProc)CYCLE
          nRequestR = nRequestR + 1
          call MPI_Irecv(Router % nRecv_P(iProcFrom), 1, MPI_INTEGER,&
               iProcFrom, iTag, Router%iComm, iRequestR_I(nRequestR), iError)
       end do
    end if

    ! post sends
    nRequestS = 0
    if(is_proc(Router%iCompSource))then
       do iProcTo =  i_proc0(Router%iCompTarget), i_proc_last(Router%iCompTarget), &
            i_proc_stride(Router%iCompTarget)
          if(iProc==iProcTo)then
             Router % nRecv_P(iProc) = Router % nSend_P(iProc)
             CYCLE
          end if
          nRequestS = nRequestS + 1
          call MPI_Isend(Router % nSend_P(iProcTo), 1, MPI_INTEGER,&
               iProcTo, iTag, Router%iComm, iRequestS_I(nRequestS), iError)
       end do
    end if

    ! Finalize transfer                                                       
    call MPI_waitall(nRequestR, iRequestR_I, iStatus_II, iError)
    call MPI_waitall(nRequestS, iRequestS_I, iStatus_II, iError)

    !\
    ! send the actual router info
    !/
    ! post recvs
    nRequestR = 0
    if(is_proc(Router%iCompTarget))then
       ! size of the recv buffer
       Router%nBufferTarget = sum(Router%nRecv_P)
       call check_size(2, (/Router%nVar, Router%nBufferTarget/), PBuffer_II=Router%BufferTarget_II)
       Router%BufferTarget_II = 0

       nRecvCumSum = 0
       do iProcFrom = i_proc0(Router%iCompSource), i_proc_last(Router%iCompSource), &
            i_proc_stride(Router%iCompSource)
          if(Router%nRecv_P(iProcFrom) == 0)&
               CYCLE
          if(iProc==iProcFrom)then
             nRecvCumSumMy = nRecvCumSum
          else
             nRequestR = nRequestR + 1
             call MPI_Irecv(Router%BufferTarget_II(1:Router%nVar,&
                  1+nRecvCumSum:Router%nRecv_P(iProcFrom)+nRecvCumSum), &
                  Router%nRecv_P(iProcFrom)*Router%nVar, MPI_REAL,&
                  iProcFrom, iTag, Router%iComm, iRequestR_I(nRequestR), iError)
          end if
          nRecvCumSum = nRecvCumSum + Router%nRecv_P(iProcFrom)
       end do
    end if

    ! post sends
    nRequestS = 0
    if(is_proc(Router%iCompSource))then
       nSendCumSum = 0
       do iProcTo =  i_proc0(Router%iCompTarget), i_proc_last(Router%iCompTarget), &
            i_proc_stride(Router%iCompTarget)
          if(Router % nSend_P(iProcTo) == 0) &
               CYCLE
          if(iProc==iProcTo)then
             Router%BufferTarget_II(:,&
                  1+nRecvCumSumMy:Router%nRecv_P(iProc)+nRecvCumSumMy) = &
                  Router%BufferSource_II(:,&
                  1+nSendCumSum:Router%nSend_P(iProc)+nSendCumSum)
          else
             nRequestS = nRequestS + 1
             call MPI_Isend(Router%BufferSource_II(1:Router%nVar,&
                  1+nSendCumSum:Router%nSend_P(iProcTo)+nSendCumSum), &
                  Router%nSend_P(iProcTo)*Router%nVar, MPI_REAL,&
                  iProcTo, iTag, Router%iComm, iRequestS_I(nRequestS), iError)
          end if
          nSendCumSum = nSendCumSum + Router%nSend_P(iProcTo)
       end do
    end if

    ! Finalize transfer                                                       
    call MPI_waitall(nRequestR, iRequestR_I, iStatus_II, iError)
    call MPI_waitall(nRequestS, iRequestS_I, iStatus_II, iError)

  end subroutine synchronize_router_source_to_target
  !===========================================================================!
  subroutine update_semi_router_at_target(Router,&
    GridDescriptorTarget,interpolate)

    type(RouterType), intent(inout):: Router
    type(GridDescriptorType), intent(in):: GridDescriptorTarget
    !----------------------------------------------------------------------!
    interface
       subroutine interpolate(&
            nDim, Xyz_D, GridDescriptor, &
            nIndex, iIndex_II, nImage, Weight_I,&
            nAux, iAux_I)
         ! interpolation on Source's grid;
         ! provides PE and indices to access images of
         ! data location and interpolation weights
         use CON_grid_descriptor
         implicit none
         ! number of indices per data entry
         integer, intent(in):: nDim
         ! data location on Source
         real,    intent(inout):: Xyz_D(nDim)
         ! grid descriptor
         type(GridDescriptorType):: GridDescriptor
         ! indices of images, their number and interpolation weights
         integer, intent(in) :: nIndex
         integer, intent(out):: iIndex_II(0:nIndex,2**GridDescriptor%nDim)
         integer, intent(out):: nImage
         real,    intent(out):: Weight_I(2**GridDescriptor%nDim)
         integer, intent(in) :: nAux
         integer, intent(in) :: iAux_I(nAux)
       end subroutine interpolate
    end interface
    !----------------------------------------------------------------------!
    integer:: iProc, nProc, iProcFrom, iStart, iEnd
    integer:: iBuffer, iPut, iImage, nImage
    integer:: nRecvCumSum
    integer:: nIndexTarget, nDimTarget
    integer, dimension(&
         0:GridDescriptorTarget%nDim+1, &
         2**GridDescriptorTarget%nDim):: iIndex_II
    integer:: nImageMax
    real, dimension(2**GridDescriptorTarget%nDim):: Weight_I
    real, dimension(   GridDescriptorTarget%nDim):: Coord_D
    integer:: iAux_I(0:2)

    character(len=*),parameter:: NameSub = &
         'CON_router:update_router_at_target'
    !----------------------------------------------------------------------!

    !For given PE the index in the communicator is:
    iProc = Router % iProc

    !Return if the processor does not belong to the communicator
    if(iProc<0) RETURN
    
    ! total number of processors and on components
    nProc       = Router%nProc
    
    nDimTarget  = Router%nIndexTarget-1
    nIndexTarget= Router%nIndexTarget
    nImageMax   = 2**nDimTarget
    
    ! process the data that has been received
    if(is_proc(Router%iCompTarget))then
       
       ! prepare containers for router information of Target side
       do iProcFrom = i_proc0(Router%iCompSource), i_proc_last(Router%iCompSource), &
            i_proc_stride(Router%iCompSource)
          Router%nPut_P(iProcFrom) = Router%nRecv_P(iProcFrom)*nImageMax
       end do
       
       
       call check_router_allocation(Router)
       
       ! fill these containers
       nRecvCumSum = 0
       do iProcFrom =  i_proc0(Router%iCompSource), i_proc_last(Router%iCompSource), &
            i_proc_stride(Router%iCompSource)
          
          iStart = nRecvCumSum + 1
          iEnd   = nRecvCumSum + Router%nRecv_P(iProcFrom)
          if(iEnd < iStart) &
               CYCLE
          iPut = 1
          do iBuffer = iStart, iEnd
             Coord_D(1:nDimTarget) = &
                  Router%BufferTarget_II(Router%iCoordStart:Router%iCoordEnd, iBuffer)
             iAux_I(1:Router%nMappedPointIndex) = &
                  Router%BufferTarget_II(Router%iAuxStart:Router%iAuxEnd, iBuffer)
             call interpolate(&
                  nDim         = nDimTarget, &
                  Xyz_D        = Coord_D(1:nDimTarget), &
                  nAux           = Router%nMappedPointIndex, &
                  iAux_I         = iAux_I(1:Router%nMappedPointIndex),&
                  GridDescriptor = GridDescriptorTarget, &
                  nIndex         = nIndexTarget, &
                  iIndex_II      = iIndex_II, &
                  nImage         = nImage, &
                  Weight_I       = Weight_I)
             
             do iImage = 1, nImage
                Router%iPut_P(iProcFrom) % iCB_II(0,iPut) = &
                     nImage + 1 - iImage
                Router%iPut_P(iProcFrom) % iCB_II(1:nIndexTarget,iPut) =&
                     iIndex_II(1:nIndexTarget, iImage)
                Router%Put_P(iProcFrom) % Weight_I(iPut)=Weight_I(iImage)
                Router%DoAdd_P(iProcFrom)%DoAdd_I(iPut) = iImage/=1
                iPut = iPut+1
             end do
             
          end do
          ! increment the offest
          nRecvCumSum = nRecvCumSum + Router%nRecv_P(iProcFrom)
       end do
    end if
  end subroutine update_semi_router_at_target
  !===========================================================================!
  subroutine access_router_buffer_source(Router, access_buffer)
    !----------------------------------------------------------------------!
    ! Method to access data that is stored in the Buffer at Source
    type(RouterType), intent(in):: Router
    interface 
       subroutine access_buffer(nPartial, nIndex, &
                iIndex_II, Weight_I)
         implicit none
         integer,intent(in) :: nPartial, nIndex
         integer,intent(in) :: iIndex_II(1:nIndex,1:nPartial)
         real,   intent(in) :: Weight_I(1:nPartial)
       end subroutine access_buffer
    end interface
    !----------------------------------------------------------------------!
    integer:: iBuffer, iGet, iPe, iV, nPartialGet
    !----------------------------------------------------------------------!
    iBuffer=1
    do iPE=0,Router%nProc-1
       if(Router%nSend_P(iPE)==0) CYCLE
       iGet=1
       do iV=1,Router%nSend_P(iPE)
          nPartialGet=Router%iGet_P(iPE)%iCB_II(0,iGet)
          call access_buffer(nPartialGet,   &
               nIndex=Router%nIndexSource,&
               iIndex_II=Router%iGet_P(iPE)%iCB_II(&
               1:Router%nIndexSource,&
               iGet:iGet+nPartialGet-1),    &
               Weight_I=Router%Get_P(iPE)%Weight_I(  &
               iGet:iGet+nPartialGet-1))
          iGet   = iGet   +nPartialGet
          iBuffer= iBuffer+1
       end do
    end do
  end subroutine access_router_buffer_source
  !===========================================================================!
  subroutine check_size(nRank, nSize_I, &
       Buffer_I, Buffer_II, PBuffer_I, PBuffer_II,&
       iBuffer_I, iBuffer_II, DoBuffer_I)
    ! check if size of a given array is sufficient;
    ! can call the subroutine for only one array at a time
    integer,                     intent(in)   :: nRank
    integer,                     intent(in)   :: nSize_I(nRank)
    real,   allocatable,optional,intent(inout)::  Buffer_I(:), Buffer_II(:,:)
    real,   pointer,    optional,intent(inout):: PBuffer_I(:),PBuffer_II(:,:)
    integer,allocatable,optional,intent(inout):: iBuffer_I(:),iBuffer_II(:,:)
    logical,allocatable,optional,intent(inout)::DoBuffer_I(:)

    logical:: IsPresent_I(7)
    character(len=*), parameter:: NameSub= &
         'CON_router:check_buffer'
    !-----------------------------------------------------------------------!
    IsPresent_I = (/&
         present(  Buffer_I), present( Buffer_II), &
         present( PBuffer_I), present(PBuffer_II), &
         present( iBuffer_I), present(iBuffer_II), &
         present(DoBuffer_I)/)

    if(count(IsPresent_I) /= 1)&
         call CON_stop(NameSub // ': incorrect call')

    select case(nRank)
    case(1)
       if(present(Buffer_I))then
          if(allocated(Buffer_I))then
             if(any(ubound(Buffer_I) < nSize_I))then
                deallocate(Buffer_I)
             else
                RETURN
             end if
          end if
          allocate(Buffer_I(nSize_I(1)))
          RETURN
       elseif(present(PBuffer_I))then
          if(associated(PBuffer_I))then
             if(any(ubound(PBuffer_I) < nSize_I))then
                deallocate(PBuffer_I)
             else
                RETURN
             end if
          end if
          allocate(PBuffer_I(nSize_I(1)))
          RETURN
       elseif(present(iBuffer_I))then
          if(allocated(iBuffer_I))then
             if(any(ubound(iBuffer_I) < nSize_I))then
                deallocate(iBuffer_I)
             else
                RETURN
             end if
          end if
          allocate(iBuffer_I(nSize_I(1)))
          RETURN
       elseif(present(DoBuffer_I))then
          if(allocated(DoBuffer_I))then
             if(any(ubound(DoBuffer_I) < nSize_I))then
                deallocate(DoBuffer_I)
             else
                RETURN
             end if
          end if
          allocate(DoBuffer_I(nSize_I(1)))
          RETURN
       end if
    case(2)
       if(present(Buffer_II))then
          if(allocated(Buffer_II))then
             if(ubound(Buffer_II,1)/=nSize_I(1).or.&
                  ubound(Buffer_II,2)<nSize_I(2))then
                deallocate(Buffer_II)
             else
                RETURN
             end if
          end if
          allocate(Buffer_II(nSize_I(1), nSize_I(2)))
          RETURN
       elseif(present(iBuffer_II))then
          if(allocated(iBuffer_II))then
             if(ubound(iBuffer_II,1)/=nSize_I(1).or.&
                  ubound(iBuffer_II,2)<nSize_I(2))then
                deallocate(iBuffer_II)
             else
                RETURN
             end if
          end if
          allocate(iBuffer_II(nSize_I(1), nSize_I(2)))
          RETURN
       elseif(present(PBuffer_II))then
          if(associated(PBuffer_II))then
             if(ubound(PBuffer_II,1)/=nSize_I(1).or.&
                  ubound(PBuffer_II,2)<nSize_I(2))then
                deallocate(PBuffer_II)
             else
                RETURN
             end if
          end if
          allocate(PBuffer_II(nSize_I(1), nSize_I(2)))
          RETURN
       end if
    case default
       call CON_stop(NameSub // ': incorrect call')
    end select
  end subroutine check_size

  !====================END========================================!
end Module CON_router


