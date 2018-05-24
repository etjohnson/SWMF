!  Copyright (C) 2002 Regents of the University of Michigan, 
!  portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
subroutine write_plot_particle(iFile)

  ! Save particle data

  use ModProcMH,  ONLY: iComm, iProc, nProc
  use ModMain,    ONLY: n_step, time_accurate, time_simulation
  use ModIO,      ONLY: &
       StringDateOrTime, NamePlotDir, &
       TypeFile_I, plot_type, plot_form, &
       Plot_

  use ModPlotFile,ONLY: save_plot_file

  use ModParticleFieldLine
  
  implicit none

  integer, intent(in):: iFile

  character(len=100) :: NameFile, NameStart, NameVar
  character (len=80) :: NameProc
  ! container for data
  real, allocatable:: PlotVar_VI(:,:)

  logical:: IsIdl
  integer:: iPlotFile
  integer:: iParticle ! loop variable
  integer:: nParticle

  character(len=*), parameter :: NameSub = 'write_plot_particle'
  !------------------------------------------------------------------------

  iPlotFile = iFile - Plot_

  ! Set the name of the variables based on plot form
  select case(plot_form(iFile))
  case('tec')
     IsIdl = .false.
     NameVar = '"X", "Y", "Z"'
     NameVar = trim(NameVar)//', "FieldLine"'
  case default
     call CON_stop(NameSub//' ERROR invalid plot form='//plot_form(iFile))
  end select

  ! name of output files
  if(iPlotFile < 10)then
     write(NameStart,'(a,i1,a)') &
          trim(NamePlotDir)//trim(plot_type(iFile))//'_',iPlotFile
  else
     write(NameStart,'(a,i2,a)') &
          trim(NamePlotDir)//trim(plot_type(iFile))//'_',iPlotFile
  end if

  NameFile = NameStart

  if(time_accurate)then
     call get_time_string
     NameFile = trim(NameFile)// "_t"//StringDateOrTime
  end if
  write(NameFile,'(a,i7.7,a)') trim(NameFile) // '_n',n_step

  ! String containing the processor index
  if(nProc < 10000) then
     write(NameProc, '(a,i4.4,a)') "_pe", iProc
  elseif(nProc < 100000) then
     write(NameProc, '(a,i5.5,a)') "_pe", iProc
  else
     write(NameProc, '(a,i6.6,a)') "_pe", iProc
  end if

  NameFile = trim(NameFile) // trim(NameProc)

  if(IsIdl)then
     NameFile = trim(NameFile) // '.out'
  else
     NameFile = trim(NameFile) // '.dat'
  end if

  ! get the data on this processor
  if(allocated(PlotVar_VI)) deallocate(PlotVar_VI)
  allocate(PlotVar_VI(5,n_particle_reg()))
  call get_particle_data(5, 'xx yy zz fl id', PlotVar_VI)

  call save_plot_file(&
       NameFile, &
       TypeFileIn     = TypeFile_I(iFile), &
       StringHeaderIn = "TEMPORARY", &
       TimeIn         = time_simulation, &
       nStepIn        = n_step, &
       NameVarIn      = 'X Y Z FieldLine Index', &
       IsCartesianIn  = .false., &
       CoordIn_I      = PlotVar_VI(1, :), &
       VarIn_VI       = PlotVar_VI(2:,:))

  deallocate(PlotVar_VI)

end subroutine write_plot_particle