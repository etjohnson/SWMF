!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf

subroutine logfileDGCPM(dir, i3)

  use ModMainDGCPM, ONLY: mgridpot,CrossPotential, rkph
  use ModCoupleDGCPM, ONLY: IsCoupled
  use ModTimeDGCPM, ONLY: StartTime, CurrentTime
  use ModProcPS,   ONLY : iProc
  use ModIoUnit,   ONLY: UnitTmp_

  implicit none

  character (len=*), intent(in) :: dir
  integer, intent(in) ::  i3
  logical :: IsFirstTime = .true.
  real kp
  !----------------------------------------------------------------------------

  if (iProc == 0) then

     if (IsFirstTime) then
        if (i3 == 0 .and. StartTime == CurrentTime) then
           open(unit=UnitTmp_, &
                file=trim(dir)//"PS.log",status="replace")
           write(UnitTmp_,'(a)')  &
                'Dynamic Global Core Plasma Model'
           write(UnitTmp_,'(a)') &
                'nsolve t kp cpp[kV] pot_ratio'
        else
           open(unit=UnitTmp_, &
                file=trim(dir)//"PS.log",status="old", position="append")
        endif
        IsFirstTime = .false.
     else
        open(unit=UnitTmp_, &
             file=trim(dir)//"PS.log",status="old", position="append")
     endif

     write(UnitTmp_,'(i8,f20.0,f8.2)') &
          i3, CurrentTime, &
           CrossPotential
     close(UnitTmp_)

  endif

end subroutine logfileDGCPM

