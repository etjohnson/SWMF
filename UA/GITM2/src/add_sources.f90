
subroutine add_sources

  use ModGITM
  use ModSources
  use ModInputs

  implicit none

  integer :: iBlock, iLon, iLat, iAlt, iSpecies

  call report("add_sources",2)

  do iBlock = 1, nBlocks

     ! All the physics is left out or added in in calc_GITM_sources.  If
     ! you want to turn something off, look for the UseWhatever variable
     ! in calc_GITM_sources.  Then fill the source with 0.0, so this routine
     ! does not change.

     call calc_GITM_sources(iBlock)

     Temperature(1:nLons, 1:nLats, 1:nAlts, iBlock) = &
          Temperature(1:nLons, 1:nLats, 1:nAlts, iBlock) + Dt * ( &
          EuvHeating(1:nLons, 1:nLats, 1:nAlts, iBlock) &
          - NOCooling - OCooling + AuroralHeating + JouleHeating) + &
          Conduction + ChemicalHeatingRate

     do while (minval(temperature(1:nLons, 1:nLats, 1:nAlts, iBlock)) < 0.0)
        write(*,*) "Negative Temperature Found!!!  Correcting!!!"
        do iLon = 1, nLons
           do iLat = 1, nLats
              iAlt = 1
              if (temperature(iLon, iLat, iAlt, iBlock) < 0.0) &
                   temperature(iLon, iLat, iAlt, iBlock) = &
                   temperature(iLon, iLat, iAlt-1, iBlock)
              do iAlt = 2, nAlts
                 if (temperature(iLon, iLat, iAlt, iBlock) < 0.0) &
                      temperature(iLon, iLat, iAlt, iBlock) = &
                      (temperature(iLon, iLat, iAlt-1, iBlock) +  &
                      temperature(iLon, iLat, iAlt+1, iBlock))/2.0
              enddo
           enddo
        enddo
     enddo

     if (iDebugLevel > 2 .and. Is1D) then
!        do iAlt = 1,nAlts
iAlt = 10
           write(*,*) "===> MaxVal Temp Sources : ", iAlt, dt,&
                EuvHeating(1, 1, iAlt, iBlock)*dt, &
!                NOCooling(1,1,iAlt)*dt, &
!                OCooling(1,1,iAlt)*dt, &
                AuroralHeating(1,1,iAlt)*dt, &
                JouleHeating(1,1,iAlt)*dt, &
                ChemicalHeatingRate(1,1,iAlt), &
                Conduction(1,1,iAlt), temperature(1,1,iAlt,iBlock)
!        enddo
     endif

     iAlt = nAlts-2
     if (iDebugLevel > 2) &
          write(*,*) "===> MaxVal Temp Sources : ", &
          maxval(EuvHeating(1:nLons, 1:nLats, iAlt, iBlock))*dt, &
          maxval(NOCooling(:,:,iAlt))*dt, maxval(OCooling(:,:,iAlt))*dt, &
          maxval(AuroralHeating(:,:,iAlt))*dt, &
          maxval(JouleHeating(:,:,iAlt))*dt, &
          maxval(Conduction(:,:,iAlt))

     Velocity(1:nLons, 1:nLats, 1:nAlts, :, iBlock) = &
          Velocity(1:nLons, 1:nLats, 1:nAlts, :, iBlock) + Dt * ( &
          IonDrag) + Viscosity
     
     do iSpecies = 1, nSpecies
        VerticalVelocity(1:nLons, 1:nLats, 1:nAlts, iSpecies, iBlock) = &
             VerticalVelocity(1:nLons, 1:nLats, 1:nAlts, iSpecies, iBlock) + &
             Dt*(VerticalIonDrag(:,:,:,iSpecies)) + &
             NeutralFriction(:,:,:,iSpecies) 
     enddo

     call calc_electron_temperature(iBlock)

     do iSpecies = 1, nSpecies
        NDensityS(1:nLons, 1:nLats, 1:nAlts, iSpecies, iBlock) =  &
             NDensityS(1:nLons, 1:nLats, 1:nAlts, iSpecies, iBlock)+ &
             Diffusion(1:nLons, 1:nLats, 1:nAlts, iSpecies)*Dt
     enddo

     do iLon = 1, nLons
        do iLat = 1, nLats
           do iAlt = 1, nAlts
              Rho(iLon, iLat, iAlt, iBlock) = &
                   sum(Mass(1:nSpecies) * &
                   NDensityS(iLon,iLat,iAlt,1:nSpecies,iBlock) )
              NDensity(iLon, iLat, iAlt, iBlock) = &
                   sum(NDensityS(iLon,iLat,iAlt,1:nSpecies,iBlock) )
           enddo
        enddo
     enddo

     Velocity(1:nLons, 1:nLats, 1:nAlts, iUp_, iBlock) = 0.0
     do iSpecies = 1, nSpecies
        Velocity(1:nLons, 1:nLats, 1:nAlts, iUp_, iBlock) = &
             Velocity(1:nLons, 1:nLats, 1:nAlts, iUp_, iBlock) + &
             VerticalVelocity(1:nLons, 1:nLats, 1:nAlts, iSpecies, iBlock)* &
             Mass(iSpecies) * &
             NDensityS(1:nLons, 1:nLats, 1:nAlts, iSpecies, iBlock) / &
             Rho(1:nLons, 1:nLats, 1:nAlts, iBlock)
     enddo

  enddo

end subroutine add_sources
