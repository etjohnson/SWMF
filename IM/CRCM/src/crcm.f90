
subroutine crcm_run(delta_t)
  !-----------------------------------------------------------------------------
  ! For the definitions of each input and output parameters, see wiki page:
  ! http://openggcm.sr.unh.edu/wiki/index.php/CRCM
  !
  ! Input/Output: np,nt,neng,npit,nspec(output when ijob=0, input when ijob > 0)
  !               rrio,ttio
  ! 
  ! Input: delta_t
  ! 
  ! Output: xlat,xmlt,energy,sinAo,fac,phot,flux
  use ModConst,       ONLY: cLightSpeed, cElectronCharge
  use ModCrcmInitialize
  use ModCrcm,        ONLY: kspec, f2, dt, Time, phot, Pressure_C,FAC_C
  use ModCrcmPlanet,  ONLY: re_m, dipmom, Hiono
  use ModFieldTrace,  ONLY: fieldpara, brad=>ro, ftv=>volume, xo,yo,rb,irm,&
                            ekev,iba,bo,pp,Have, sinA, vel, alscone, iw2
  use ModGmCrcm,      ONLY: rrio,ttio,StateIntegral_IIV,AveP_,AveDens_,iLatMin
  use ModIeCrcm,      ONLY: pot
  use ModCrcmPlot,    ONLY: Crcm_plot, DtOutput, DoSavePlot
  implicit none


  integer n,nstep,ib0(nt)
  real delta_t
  real flux(nspec,np,nt,neng,npit)
  real achar(np,nt,nm,nk)
  real vl(nspec,0:np,nt,nm,nk),vp(nspec,np,nt,nm,nk),fb(nspec,nt,nm,nk),rc
  integer iLat,iLon
  logical, save :: IsFirstCall =.true.
  !----------------------------------------------------------------------------

!  dt=10.                   
  nstep=nint(delta_t/dt)
  if (nstep == 0) then
     nstep = 1
  endif

  dt=delta_t/nstep         ! new dt
  
  ! do field line integration and determine vel, ekev, momentum (pp), etc.
  rc=(re_m+Hiono*1000.)/re_m        ! ionosphere distance in RE`
  call fieldpara(Time,dt,cLightSpeed,cElectronCharge,rc,re_m,xlat,xmlt,phi,xk,&
                 amu,dipmom)
!  old call
!  call fieldpara(nspec,np,nt,nm,nk,npt,npmax,neng,gb,bb,beq,brad, &
!       xlat,xmm,xk,Hiono,rb,re_m,amu,dt,energy,iba,irm,iw2,vel, &
!       ekev,pp,sinA,Have,alscone)
  
  
  !set boundary density and temperature inside iba
  do iLon=1,nt
     do iLat=1,irm(iLon) 
        if (iLat < iLatMin) then
           !Inside MHD boundary set density and temperature to value at boundary
           ttio(iLat,iLon) = &
                StateIntegral_IIV(iLatMin,iLon,AveP_)&
                / StateIntegral_IIV(iLatMin,iLon,AveDens_) *6.2415e18 !J-->eV   
           rrio(iLat,iLon) = StateIntegral_IIV(iLatMin,iLon,AveDens_)
        else
           !Outside MHD boundary set density and temperature from MHD
           !write(*,*)'iLat,iLon,StateIntegral_IIV(iLat,iLon,AveP_),StateIntegral_IIV(iLat,iLon,AveDens_)',&
           !     iLat,iLon,StateIntegral_IIV(iLat,iLon,AveP_),StateIntegral_IIV(iLat,iLon,AveDens_)
           ttio(iLat,iLon) = &
                StateIntegral_IIV(iLat,iLon,AveP_)&
                / StateIntegral_IIV(iLat,iLon,AveDens_) *6.2415e18 !J-->eV    
           rrio(iLat,iLon) = StateIntegral_IIV(iLat,iLon,AveDens_)
        endif
     end do
  end do

  ! setup initial distribution
  if (IsFirstCall) then
     call initial_f2(nspec,np,nt,iba,amu,vel,xjac,ib0)
     IsFirstCall=.false.
  endif

  ! calculate boundary flux (fb) at the CRCM outer boundary at the equator
  call boundary(nspec,np,nt,nm,nk,iba,irm,amu,xjac,rrio,ttio,vel,fb)
  
  ! calculate the drift velocity
  call driftV(nspec,np,nt,nm,nk,kspec,irm,re_m,Hiono,dipmom,dphi,xlat, &
       dlat,ekev,pot,vl,vp) 
  
  ! calculate the depreciation factor, achar, due to charge exchange loss
  call cepara(kspec,nspec,np,nt,nm,nk,irm,dt,vel,ekev,Have,achar)
  
  ! time loop
  do n=1,nstep
     call drift(iw2,nspec,np,nt,nm,nk,iba,dt,dlat,dphi,brad,rb,vl,vp, &
          fb,f2,ib0)
     call charexchange(np,nt,nm,nk,nspec,kspec,iba,achar,f2)
     call losscone(np,nt,nm,nk,nspec,iba,alscone,f2)
     Time = Time+dt
 enddo
  
  ! Calculate CRCM output: flux, fac, phot
  call crcm_output(np,nt,nm,nk,nspec,neng,npit,kspec,iba,ftv,f2,ekev, &
       sinA,energy,sinAo,delE,dmu,amu,xjac,pp,xmm, &
       dmm,dk,xlat,dphi,re_m,Hiono,flux,FAC_C,phot,Pressure_C,rrio,ttio)

  if (DoSavePlot.and.&
       (floor((Time+1.0e-5)/DtOutput))/=floor((Time+1.0e-5-delta_t)/DtOutput))&
       call Crcm_plot(np,nt,xo,yo,Pressure_C,phot,rrio,bo,ftv,pot,FAC_C,Time,dt)
end subroutine crcm_run


!-----------------------------------------------------------------------------
subroutine crcm_init
  !---------------------------------------------------------------------------
  ! Routine does CRCM initialization: fill arrays
  !
  ! Input: np,nt,neng,npit,nspec,re_m,dipmom,Hiono
  ! Output: kspec,xlat,xmlt,energy,sinAo (through augments)
  !         xmm1,xk1,phi1,dlat1,dphi1,dmm1,dk1,delE1,dmu1,xjac,amu (through 
  !         common block cinitialization

  use ModPlanetConst, ONLY: Earth_,DipoleStrengthPlanet_I,rPlanet_I
  use ModConst,       ONLY: cElectronCharge
  use ModNumConst,    ONLY: cDegToRad,cRadToDeg,cPi
  use ModCrcmPlanet,  ONLY: re_m, dipmom, Hiono
  use ModCrcm,        ONLY: kspec
  use ModCrcmInitialize
  implicit none

  integer i,n,k
  real xlat_data(0:np+1)
  real rw,rsi,rs1,xlatr(np)
  real xjac1,sqrtm

  ! Define constants
  re_m = rPlanet_I(Earth_)                            ! earth's radius (m)
  dipmom=abs(DipoleStrengthPlanet_I(Earth_)*re_m**3)  ! earth's dipole moment
  

  xlat_data=[11.812,13.777,15.742,17.705,19.665,21.622,23.576,25.527,27.473, &
       29.414,31.350,33.279,35.200,37.112,39.012,40.897,42.763,44.604, &
       46.409,48.163,49.837,51.382,52.725,53.823,54.720,55.488,56.175, &
       56.812,57.413,57.990,58.547,59.090,59.622,60.144,60.659,61.168, &
       61.671,62.170,62.666,63.159,63.649,64.137,64.624,65.109,65.593, &
       66.077,66.560,67.043,67.526,68.009,68.492,68.975,69.458]

  ! Setup kspec and amu
  kspec=[2]      ! H+
  do n=1,nspec
     if (kspec(n).eq.1) amu(n)=5.4462e-4      ! e-
     if (kspec(n).eq.2) amu(n)=1.             ! H+
  enddo

  ! CRCM xlat and xmlt grids
  do i=1,np
     xlat(i)=xlat_data(i)
     dlat(i)=0.5*(xlat_data(i+1)-xlat_data(i-1))*cDegToRad    ! dlat in radian
  enddo
  xlatr=xlat*cDegToRad  
  dphi=2.*cPi/nt
  do i=1,nt
     phi(i)=(i-1)*dphi
     xmlt(i)=mod(phi(i)*12.0/cPi + 12.0,24.0)   
  enddo

  ! CRCM output grids: energy, sinAo, delE1, dmu1
  energy=[1.0000,1.6795,2.8209,4.7378,7.9574,13.365, &
       22.447,37.701,63.320,106.35,178.62,300.00]
  delE=0.5243*energy
  sinAo=[0.010021,0.030708,0.062026,0.086108,0.16073,0.27682, &
       0.430830,0.601490,0.753790,0.863790,0.94890,0.98827]
  dmu=[0.000207365,0.000868320,0.00167125,0.00489855,0.0165792,0.0404637, &
       0.078819500,0.121098000,0.14729600,0.16555900,0.1738560,0.2486830]

  ! CRCM magnetic moment, xmm1
  xmm(1)=energy(1)*cElectronCharge/(dipmom/(2*re_m)**3.0)
  dmm(1)=xmm(1)*2.              
  rw=1.55                       
  do i=2,nm                    
     dmm(i)=dmm(1)*rw**(i-1)           
     xmm(i)=xmm(i-1)+0.5*(dmm(i-1)+dmm(i))
  enddo

  ! CRCM K, xk
  rsi=1.47
  xk(1)=40.*rsi
  rs1=(rsi-1.)/sqrt(rsi) ! in following sutup: xk(i+0.5)=sqrt(xk(i)*xk(i+1))
  do i=1,nk
     if (i.gt.1) xk(i)=xk(i-1)*rsi
     dk(i)=xk(i)*rs1                 
  enddo

  ! Calculate Jacobian, xjac
  do n=1,nspec 
     xjac1=4.*sqrt(2.)*cPi*(1.673e-27*amu(n))*dipmom/(re_m+Hiono*1000.)
     sqrtm=sqrt(1.673e-27*amu(n))
     do i=1,np
        do k=1,nm
           xjac(n,i,k)=xjac1*sin(2.*xlatr(i))*sqrt(xmm(k))*sqrtm
        enddo
     enddo
  enddo

end subroutine crcm_init

! OLD FIELDPARA
!!-------------------------------------------------------------------------------
!subroutine fieldpara(nspec,np,nt,nm,nk,npt,npmax,neng,gb,bb,beq,brad, &
!     xlat,xmm,xk,Hiono,rb,re_m,amu,dt,energy,iba,irm,iw2,vel, &
!     ekev,pp,sinA,Have,alscone)
!  !-----------------------------------------------------------------------------
!  ! Routine does field line integration and calculate momentum (pp) and other 
!  ! parameters for given location and adiabatic invariants.
!  !
!  ! Input: nspec,np,nt,nm,nk,npt,npmax,gb,bb,beq,brad,xlat,xmm,xk 
!  !        Hiono,rb,re_m,amu,dt
!  ! Output: iba,irm,iw2,vel,ekev,pp,sinA,Have,alscone
!
!  implicit none
!
!  integer nspec,np,nt,nm,nk,npt(np,nt),npmax,neng,iba(nt),irm(nt),iw2(nk)
!  integer n5,n,i,j,k,m,mir,npf,npf1,im,im1,im2,igood,n6,n7,n8,ii,ier
!  real energy(neng),xlat(np),xlatr(np),xmm(nm),xk(nk),Hiono,amu(nspec),dt
!  real brad(np,nt),beq(np,nt),rb,xd,yd,zd,dss1,dss2,dssm,pp1,pc,c2m,eJoule
!  real sinA(np,nt,nk),Have(np,nt,nk),alscone(nspec,np,nt,nm,nk)
!  real si3(npmax),h3(npmax),yint(npmax),yint1(npmax),yint2(npmax)
!  real pp(nspec,np,nt,nm,nk),vel(nspec,np,nt,nm,nk),ekev(np,nt,nm,nk)
!  real xli(np),dssa(npmax),ra(npmax),rm(npmax),bm1(npmax),bm(np,nt,nk)
!  real gb(np,nt,npmax,3),bb(np,nt,npmax)
!  real xa(npmax),ya(npmax),za(npmax),bba(npmax)
!  real pi,q,rc,dre,EM_speed,rme,re_m,xme,rm1,rl,cost,sqrtb,bsi,x,dssp,ss,ss1,ss2
!  real sim,bmmx,rmm,tya3(npmax),dss(npmax),rs(npmax),bs(npmax),hden
!  real rmir(np,nt,nk),tya(np,nt,nk),tya33,h33,xmass,c2mo,c4mo2,ro2
!  real tcone1,tcone2,dtcone
!
!  pi=acos(-1.)
!  rc=(re_m+Hiono*1000.)/re_m        ! ionosphere distance in RE
!  dre=0.06                          ! r interval below ionosphere
!  n5=16                             ! no. of point below the ionosphere
!  EM_speed=3.e8                     ! speed of light in m/s
!  q=1.6e-19                         ! electron charge
!  xlatr=xlat*pi/180.
!
!  ! Determine irm and iba
!  do j=1,nt
!     do i=1,np
!        if (npt(i,j).gt.0) irm(j)=i
!     enddo
!     do i=1,irm(j)
!        if (brad(i,j).le.rb) iba(j)=i
!     enddo
!  enddo
!
!  ! Do filed line integration to find bm, sinA and other parameters
!  jloop: do j=1,nt
!     iloop: do i=1,irm(j)
!        npf1=npt(i,j)
!        xa(1:npf1)=gb(i,j,1:npf1,1)
!        ya(1:npf1)=gb(i,j,1:npf1,2)
!        za(1:npf1)=gb(i,j,1:npf1,3)
!        bba(1:npf1)=bb(i,j,1:npf1)
!        xli(i)=rc/cos(xlatr(i))/cos(xlatr(i))
!
!        ! calculate ra and dssa
!        dssa(1)=0.
!        do m=1,npf1
!           ra(m)=sqrt(xa(m)*xa(m)+ya(m)*ya(m)+za(m)*za(m))
!           if (m.gt.1) then
!              xd=xa(m)-xa(m-1)
!              yd=ya(m)-ya(m-1)
!              zd=za(m)-za(m-1)
!              dss1=sqrt(xd**2+yd**2+zd**2)
!              dssa(m)=dssa(m-1)+dss1
!           endif
!        enddo
!
!        ! find the middle point
!        dss2=dssa(npf1)/2.  
!        call locate1(dssa,npf1,dss2,im)
!        im1=im
!        if ((dssa(im+1)-dss2).lt.(dss2-dssa(im))) im1=im+1
!
!        ! make sure B decreases to bba(im1) and rises
!        npf=n5          
!        dssm=0.
!        do m=1,npf1
!           if (m.lt.npf1) dssm=dssm+(dssa(m+1)-dssa(m))
!           igood=-1
!           if (m.eq.1.or.m.eq.im1) igood=1
!           if (m.gt.1.and.m.lt.im1.and.bba(m).gt.bba(im1).and. &
!                bba(m).lt.bm1(npf)) igood=1     ! B should be decreasing
!           if (m.gt.im1.and.bba(m).gt.bba(im1).and. &
!                bba(m).gt.bm1(npf)) igood=1     ! B should be increasing
!           if (igood.eq.1) then
!              npf=npf+1
!              bm1(npf)=bba(m)*1.e-9         ! new bba in T
!              rm(npf)=ra(m)                 ! new ra
!              if (m.lt.npf1) dss(npf)=dssm
!              dssm=0.                       ! reset dssm
!              if (m.eq.im1) im2=npf         ! new im1
!           endif
!        enddo
!
!        ! Add n5 points below both ionospheres
!        rme=rc*re_m
!        xme=bba(1)*1.e-9*rme**3/sqrt(4.-3.*rc/xli(i))    ! local dipole moment
!        do m=1,n5           
!           rm1=rc-m*dre
!           rme=rm1*re_m
!           rm(n5-m+1)=rm1
!           rm(npf+m)=rm1
!           bm1(n5-m+1)=sqrt(4.-3.*rm1/xli(i))*xme/rme**3 !assume dipole
!           bm1(npf+m)=bm1(n5-m+1)
!        enddo
!
!        npf=npf+n5
!        n=npf-1  ! new no. of intervals from N to S hemisphere
!        do m=1,n
!           rs(m)=0.5*(rm(m+1)+rm(m))
!           bs(m)=0.5*(bm1(m+1)+bm1(m))
!        enddo
!        do m=1,n
!           if (m.le.n5.or.m.ge.(npf-n5)) then
!              rl=rs(m)/xli(i)
!              cost=sqrt(1.-rl*rl)
!              dss(m)=dre*sqrt(3.*cost*cost+1.)/2./cost
!           endif
!        enddo
!
!        ! Set up arrarys at trace grids
!        si3(im2)=0.               ! equatorially mirroring
!        h3(im2)=hden(rm(im2))
!        do mir=1,im2-1     
!           sqrtb=sqrt(bm1(mir))
!           n8=npf
!           integration: do ii=mir,n
!              bsi=bs(ii)
!              if (bm1(ii+1).ge.bm1(mir)) bsi=0.5*(bm1(mir)+bm1(ii))
!              yint(ii)=sqrt(bm1(mir)-bsi)
!              x=sqrt(1.-bsi/bm1(mir))
!              yint1(ii)=1./x
!              yint2(ii)=hden(rs(ii))/x
!              if (bm1(ii+1).ge.bm1(mir)) then
!                 n8=ii+1
!                 exit integration
!              endif
!           enddo integration
!           n7=n8-1
!           n6=n7-1
!           dssp=dss(n7)*(bm1(mir)-bm1(n7))/(bm1(n8)-bm1(n7)) !partial ds
!           call closed(mir,n6,yint,dss,ss)  ! use closed form integration
!           ss=ss+yint(n7)*dssp
!           si3(mir)=ss*re_m
!           call closed(mir,n6,yint1,dss,ss1)
!           ss1=ss1+yint1(n7)*dssp
!           tya3(mir)=ss1/brad(i,j)/2.
!           call closed(mir,n6,yint2,dss,ss2)
!           ss2=ss2+yint2(n7)*dssp
!           h3(mir)=ss2/ss1
!        enddo
!        tya3(im2)=tya3(im2-1)
!
!        ! Calculate bm, sinA, rmir, tya, Have (bounced average H density)
!        do m=1,nk
!           sim=xk(m)      
!           call lintp(si3,bm1,im2,sim,bmmx,ier)
!           bm(i,j,m)=bmmx
!           sinA(i,j,m)=sqrt(beq(i,j)*1.e-9/bmmx)
!           if (sinA(i,j,m).gt.1.) sinA(i,j,m)=1.
!           call lintp(si3,rm,im2,sim,rmm,ier)
!           rmir(i,j,m)=rmm
!           call lintp(si3,tya3,im2,sim,tya33,ier)
!           tya(i,j,m)=tya33
!           call lintp(si3,h3,im2,sim,h33,ier)
!           Have(i,j,m)=h33          ! bounce-averaged hydrogen density
!        enddo
!     enddo iloop
!  enddo jloop
!
!  ! Determine pp,vel
!  do n=1,nspec
!     xmass=1.673e-27*amu(n)
!     c2mo=EM_speed*EM_speed*xmass
!     c4mo2=c2mo*c2mo
!     do j=1,nt
!        do i=1,irm(j)
!           ro2=2.*brad(i,j)*re_m
!           do m=1,nk
!              tcone1=ro2*tya(i,j,m)
!              pp1=sqrt(2.*xmass*bm(i,j,m))
!              do k=1,nm
!                 pp(n,i,j,k,m)=pp1*sqrt(xmm(k))
!                 pc=pp(n,i,j,k,m)*EM_speed
!                 c2m=sqrt(pc*pc+c4mo2)
!                 eJoule=c2m-c2mo                           ! E in J
!                 if (n.eq.1) ekev(i,j,k,m)=eJoule/1000./q  ! E(keV) not depend n
!                 vel(n,i,j,k,m)=pc*EM_speed/c2m
!                 alscone(n,i,j,k,m)=1.
!                 if (rmir(i,j,m).le.rc) then
!                    tcone2=tcone1/vel(n,i,j,k,m)           ! Tbounce/2
!                    dtcone=dt/tcone2
!                    alscone(n,i,j,k,m)=0.
!                    if (dtcone.le.80.) alscone(n,i,j,k,m)=exp(-dtcone)
!                 endif
!              enddo     ! k loop
!           enddo        ! m loop
!        enddo           ! i loop
!     enddo              ! j loop
!  enddo                 ! n loop
!
!  ! Find iw2(m)
!  do m=1,nk
!     iw2(m)=nm
!     find_iw2: do k=1,nm
!        if (ekev(irm(1),1,k,m).gt.energy(neng)) then
!           iw2(m)=k
!           exit find_iw2
!        endif
!     enddo find_iw2
!  enddo
!
!end subroutine fieldpara


!-------------------------------------------------------------------------------
subroutine initial_f2(nspec,np,nt,iba,amu,vel,xjac,ib0)
  !-----------------------------------------------------------------------------
  ! Routine setup initial distribution.
  ! 
  ! Input: nspec,np,nt,iba,rrio,ttio,amu,vel,xjac
  ! Output: ib0,f2 (through common block cinitial_f2)
  Use ModGmCrcm, ONLY: rrio, ttio
  use ModCrcm,   ONLY: f2
  implicit none

  integer,parameter :: np1=51,nt1=48,nspec1=1  
  integer,parameter :: nm=35,nk=28 ! dimension of CRCM magnetic moment and K
  integer nspec,np,nt,iba(nt),ib0(nt),n,j,i,k,m
  real amu(nspec),vel(nspec,np,nt,nm,nk)
  real xjac(nspec,np,nm),pi,xmass,chmass,f21,vtchm

  pi=acos(-1.)

  ib0=iba
  f2=0.

  do n=1,nspec
     xmass=amu(n)*1.673e-27
     chmass=1.6e-19/xmass
     do j=1,nt
        do i=1,iba(j)
           f21=rrio(i,j)/(2.*pi*xmass*ttio(i,j)*1.6e-19)**1.5
           do k=1,nm
              do m=1,nk
                 vtchm=-vel(n,i,j,k,m)*vel(n,i,j,k,m)/2./ttio(i,j)/chmass
                 f2(n,i,j,k,m)=xjac(n,i,k)*f21*exp(vtchm)
!                 if(j==1.and.k==1.and.m==1.and.i==1) &
!                      write(*,*)'vel(n,i,j,k,m),ttio(i,j),chmass,f2,f21,vtchm,xjac'&
!                      ,vel(n,i,j,k,m),ttio(i,j),chmass,f2(n,i,j,k,m),f21,vtchm,xjac(n,i,k)
                 
              enddo
           enddo
        enddo
     enddo
  enddo

end subroutine initial_f2


!-------------------------------------------------------------------------------
subroutine boundary(nspec,np,nt,nm,nk,iba,irm,amu,xjac,rrio,ttio,vel,fb)
  !-----------------------------------------------------------------------------
  ! Routine setup the boundary distribution for the CRCM. Distribution at the
  ! boundary is assumed to be Maxwellian. Boundary temperature and density are
  ! from MHD.
  !
  ! Input: nspec,np,nt,nm,nk,iba,irm,amu,xjac,rrio,ttio,vel
  ! Output: fb

  implicit none

  integer nspec,np,nt,nm,nk,iba(nt),irm(nt),j,n,k,m,ib1
  real amu(nspec),xjac(nspec,np,nm),rrio(np,nt),ttio(np,nt)
  real vel(nspec,np,nt,nm,nk),fb(nspec,nt,nm,nk),pi,xmass,chmass,fb1,vtchm

  pi=acos(-1.)

  do n=1,nspec
     xmass=amu(n)*1.673e-27
     chmass=1.6e-19/xmass
     do j=1,nt
        ib1=iba(j)+1
        if (ib1.gt.irm(j)) ib1=irm(j)
        fb1=rrio(ib1,j)/(2.*pi*xmass*ttio(ib1,j)*1.6e-19)**1.5
        do k=1,nm
           do m=1,nk
              vtchm=-vel(n,ib1,j,k,m)*vel(n,ib1,j,k,m)/2./ttio(ib1,j)/chmass
              fb(n,j,k,m)=xjac(n,ib1,k)*fb1*exp(vtchm)
           enddo
        enddo
     enddo
  enddo

end subroutine boundary


!-------------------------------------------------------------------------------
subroutine cepara(kspec,nspec,np,nt,nm,nk,irm,dt,vel,ekev,Have,achar)
  !-----------------------------------------------------------------------------
  ! Routine calculates the depreciation factor of H+, achar, due to charge
  ! exchange loss
  !
  ! Input: irm,kspec,nspec,np,nt,nm,nk,dt,vel,ekev,Have     ! Have: bounce-ave [H]
  ! Output: achar

  implicit none

  integer np,nt,nspec,nk,irm(nt),kspec(nspec),nm,i,j,k,m,n
  real vel(nspec,np,nt,nm,nk),ekev(np,nt,nm,nk),Have(np,nt,nk)
  real achar(np,nt,nm,nk),dt,Havedt,x,d,sigma,alpha

  do n=1,nspec
     if (kspec(n).eq.2) then       ! do H+ only
        do j=1,nt
           do i=1,irm(j)
              do m=1,nk
                 Havedt=Have(i,j,m)*dt
                 do k=1,nm
                    x=log10(ekev(i,j,k,m))
                    if (x.lt.-2.) x=-2.
                    d=-18.767-0.11017*x-3.8173e-2*x**2-0.1232*x**3-5.0488e-2*x**4
                    sigma=10.**d        ! charge exchange cross section of H+ in m2
                    alpha=vel(n,i,j,k,m)*sigma*Havedt
                    achar(i,j,k,m)=exp(-alpha) ! charge. exchange decay rate
                 enddo
              enddo
           enddo
        enddo
     endif
  enddo

end subroutine cepara


!-------------------------------------------------------------------------------
subroutine driftV(nspec,np,nt,nm,nk,kspec,irm,re_m,Hiono,dipmom,dphi,xlat, &
     dlat,ekev,pot,vl,vp)
  !-----------------------------------------------------------------------------
  ! Routine calculates the drift velocities
  !
  ! Input: re_m,Hiono,dipmom,dphi,xlat,dlat,ekev,pot,nspec,np,nt,nm,nk,kspec,irm
  ! Output: vl,vp

  implicit none

  integer nspec,np,nt,nm,nk,kspec(nspec),irm(nt),n,i,ii,j,k,m,i0,i2,j0,j2,icharge
  real kfactor,xlat(np),xlatr(np),dlat(np),ekev(np,nt,nm,nk),pot(np,nt)
  real ksai,ksai1,xlat1,sf0,sf2,dlat2,re_m,Hiono,dipmom,dphi,pi,dphi2,cor
  real ham(np,nt),vl(nspec,0:np,nt,nm,nk),vp(nspec,np,nt,nm,nk)

  pi=acos(-1.)
  dphi2=dphi*2.
  kfactor=dipmom/(re_m+Hiono*1000.)
  cor=2.*pi/86400.                        ! corotation speed in rad/s
  xlatr=xlat*pi/180.

  nloop: do n=1,nspec
!     if (kspec(n).eq.1) icharge=-1       ! electrons
!     if (kspec(n).gt.1) icharge=1        ! ions
     icharge=1
     mloop: do m=1,nk
        kloop: do k=1,nm  

           ! ham: Hamiltonian/q
           ham(1:np,1:nt)=icharge*ekev(1:np,1:nt,k,m)*1000.+pot(1:np,1:nt)

           ! calculate drift velocities vl and vp
           iloop: do i=0,np
              ii=i
              if (i.eq.0) ii=1
              if (i.ge.1) ksai=kfactor*sin(2.*xlatr(i))
              if (i.lt.np) xlat1=0.5*(xlatr(ii)+xlatr(i+1))    ! xlat(i+0.5)
              ksai1=kfactor*sin(2.*xlat1)                   ! ksai at i+0.5
              jloop: do j=1,nt
                 j0=j-1
                 if (j0.lt.1) j0=j0+nt
                 j2=j+1
                 if (j2.gt.nt) j2=j2-nt

                 ! calculate vl
                 if (irm(j0).gt.i.and.irm(j2).gt.i) then
                    sf0=0.5*ham(ii,j0)+0.5*ham(i+1,j0)
                    sf2=0.5*ham(ii,j2)+0.5*ham(i+1,j2)
                    vl(n,i,j,k,m)=-(sf2-sf0)/dphi2/ksai1   ! vl at (i+0.5,j)
                 else
                    vl(n,i,j,k,m)=vl(n,i-1,j,k,m)
                 endif

                 ! calculate vp
                 if (i.ge.1) then
                    if (irm(j2).gt.i) then
                       i0=i-1
                       if (i.eq.1) i0=1
                       i2=i+1
                       if (i.eq.np) i2=np
                       dlat2=xlatr(i2)-xlatr(i0)
                       sf0=0.5*(ham(i0,j2)+ham(i0,j))
                       sf2=0.5*(ham(i2,j2)+ham(i2,j))
                       vp(n,i,j,k,m)=cor+(sf2-sf0)/dlat2/ksai  ! vp at (i,j+0.5)
                    else
                       vp(n,i,j,k,m)=vp(n,i-1,j,k,m)
                    endif
                 endif

              enddo jloop
           enddo iloop
        enddo kloop
     enddo mloop
  enddo nloop

end subroutine driftV


!-------------------------------------------------------------------------------
subroutine drift(iw2,nspec,np,nt,nm,nk,iba,dt,dlat,dphi,brad,rb,vl,vp, &
     fb,f2,ib0)
  !-----------------------------------------------------------------------------
  ! Routine updates f2 due to drift
  !
  ! Input: iw2,nspec,np,nt,nm,nk,iba,dt,dlat,dphi,brad,rb,vl,vp,fb 
  ! Input/Output: f2,ib0

  implicit none

  integer nk,iw2(nk),nspec,np,nt,nm,iba(nt),ib0(nt)
  integer n,i,j,k,m,j1,j_1,ibaj,ib,ibo,nrun,nn
  real dt,dlat(np),dphi,brad(np,nt),vl(nspec,0:np,nt,nm,nk),vp(nspec,np,nt,nm,nk)
  real rb,fb(nspec,nt,nm,nk),f2(nspec,np,nt,nm,nk)
  real f2d(np,nt),cmax,cl1,cp1,cmx,dt1,fb0(nt),fb1(nt),fo_log,fb_log,f_log
  real slope,cl(np,nt),cp(np,nt),fal(0:np,nt),fap(np,nt)

  nloop: do n=1,nspec
     mloop: do m=1,nk
        kloop: do k=1,iw2(m)
           f2d(1:np,1:nt)=f2(n,1:np,1:nt,k,m)         ! initial f2

           ! find nrun and new dt (dt1)
           cmax=0.
           do j=1,nt
              j1=j+1
              if (j1.gt.nt) j1=j1-nt
              ibaj=max(iba(j),iba(j1))
              do i=1,ibaj
                 cl1=dt/dlat(i)*vl(n,i,j,k,m)
                 cp1=dt/dphi*vp(n,i,j,k,m)
                 cmx=max(abs(cl1),abs(cp1))
                 cmax=max(cmx,cmax)
              enddo
           enddo
           nrun=ifix(cmax/0.50)+1     ! nrun to limit the Courant number
           dt1=dt/nrun                ! new dt
           ! Setup boundary fluxes and Courant numbers
           do j=1,nt
              ib=iba(j)
              ibo=ib0(j)
              fb0(j)=f2d(1,j)                   ! psd at inner boundary
              fb1(j)=fb(n,j,k,m)              ! psd at outer boundary
              if (ib.gt.ibo) then             ! during dipolarization
                 fo_log=-50.
                 if (f2d(ibo,j).gt.1.e-50) fo_log=log10(f2d(ibo,j))
                 fb_log=-50.
                 if (fb1(j).gt.1.e-50) fb_log=log10(fb1(j))
                 slope=(fo_log-fb_log)/(brad(ibo,j)-rb)
                 do i=ibo+1,ib
                    f_log=fo_log+slope*(brad(i,j)-brad(ibo,j))
                    f2d(i,j)=10.**f_log
                 enddo
              endif
              do i=1,np
                 cl(i,j)=dt1/dlat(i)*vl(n,i,j,k,m)
                 cp(i,j)=dt1/dphi*vp(n,i,j,k,m)
              enddo
           enddo

           ! run drift nrun times
           do nn=1,nrun
              call FLS_2D(np,nt,iba,fb0,fb1,cl,cp,f2d,fal,fap)
              fal(0,1:nt)=f2d(1,1:nt)
              do j=1,nt
                 j_1=j-1
                 if (j_1.lt.1) j_1=j_1+nt
                 do i=1,iba(j)
                    f2d(i,j)=f2d(i,j)+dt1/dlat(i)* &
                         (vl(n,i-1,j,k,m)*fal(i-1,j)-vl(n,i,j,k,m)*fal(i,j))+ &
                         cp(i,j_1)*fap(i,j_1)-cp(i,j)*fap(i,j)
                    if (f2d(i,j).lt.0.) then
                       if (f2d(i,j).gt.-1.e-30) then
                          f2d(i,j)=0.
                       else
                          write(*,*)' f2d < 0 in drift ',n,i,j,k,m
                          stop
                       endif
                    endif
                 enddo
              enddo
           enddo
           f2(n,1:np,1:nt,k,m)=f2d(1:np,1:nt)

        enddo kloop
     enddo mloop
  enddo nloop

  ! Update ib0
  ib0(1:nt)=iba(1:nt)

end subroutine drift


!-------------------------------------------------------------------------------
subroutine charexchange(np,nt,nm,nk,nspec,kspec,iba,achar,f2)
  !-----------------------------------------------------------------------------
  ! Routine updates f2 due to charge exchange loss
  !
  ! Input: np,nt,nm,nk,nspec,kspec,achar   ! charge exchange depreciation of H+ 
  ! Input/Output: f2

  implicit none

  integer np,nt,nm,nk,nspec,kspec(nspec),iba(nt),n,i,j
  real achar(np,nt,nm,nk),f2(nspec,np,nt,nm,nk)

  do n=1,nspec             
     if (kspec(n).eq.2) then        ! do H+ only
        do j=1,nt
           do i=1,iba(j)
              f2(n,i,j,1:nm,1:nk)=f2(n,i,j,1:nm,1:nk)*achar(i,j,1:nm,1:nk)
           enddo
        enddo
     endif
  enddo

end subroutine charexchange


!-------------------------------------------------------------------------------
subroutine losscone(np,nt,nm,nk,nspec,iba,alscone,f2)
  !-----------------------------------------------------------------------------
  ! Routine calculate the change of f2 due to losscone loss
  ! 
  ! Input: np,nt,nm,nk,nspec,iba,alscone
  ! Input/Output: f2

  implicit none

  integer np,nt,nm,nk,nspec,iba(nt),n,i,j,k,m
  real alscone(nspec,np,nt,nm,nk),f2(nspec,np,nt,nm,nk)

  do n=1,nspec
     do j=1,nt
        do i=1,iba(j)
           do k=1,nm
              do m=1,nk
                 if (alscone(n,i,j,k,m).lt.1.) &
                      f2(n,i,j,k,m)=f2(n,i,j,k,m)*alscone(n,i,j,k,m)
              enddo
           enddo
        enddo
     enddo
  enddo

end subroutine losscone


!-------------------------------------------------------------------------------
subroutine crcm_output(np,nt,nm,nk,nspec,neng,npit,kspec,iba,ftv,f2,ekev, &
     sinA,energy,sinAo,delE,dmu,amu,xjac,pp,xmm, &
     dmm,dk,xlat,dphi,re_m,Hiono,flux,fac,phot,Pressure_C,rrio,ttio)
  !-----------------------------------------------------------------------------
  ! Routine calculates CRCM output, flux, fac and phot from f2
  !
  ! Input: np,nt,nm,nk,nspec,neng,npit,kspec,iba,ftv,f2,ekev,sinA,energy,sinAo,xjac
  !        delE,dmu,amu,xjac,pp,xmm,dmm,dk,xlat,dphi,re_m,Hiono
  ! Output: flux,fac,phot,rrio,ttio
  use ModConst,   ONLY: cProtonMass
  use ModNumConst,ONLY: cPi, cDegToRad
  implicit none

  integer np,nt,nm,nk,nspec,neng,npit,kspec(nspec),iba(nt),i,j,k,m,n,j1,j_1
  real f2(nspec,np,nt,nm,nk),ekev(np,nt,nm,nk),sinA(np,nt,nk),re_m,Hiono,rion
  real ftv(np,nt),ftv1,energy(neng),sinAo(npit),delE(neng),dmu(npit),aloge(neng)
  real flux2D(nm,nk),pp(nspec,np,nt,nm,nk),xjac(nspec,np,nm)
  real sinA1D(nk),flx,ekev2D(nm,nk),flx_lo,pf(nspec),delEE(neng),pi
  real amu(nspec),amu1,psd1,psd(nspec,np,nt,nm,nk),fave(nspec,np,nt,neng)
  real xmm(nm),dmm(nm),dk(nk),xlat(np),xlatr(np),dphi,eta(nspec,np,nt,nm,nk)
  real flux(nspec,np,nt,neng,npit),detadi,detadj,dwkdi,dwkdj
  real fac(np,nt),phot(np,nt),Pressure_C(np,nt),rrio(np,nt),ttio(np,nt)
  real Pressure1

  flux=0.
  fac=0.
  phot=0.

  ! Some constants for pressure, fac calculations
  rion=re_m+Hiono*1000.                      ! ionosphere distance in meter
  do n=1,nspec
     pf(n)=4.*cPi*1.e4/3.*sqrt(2.*cProtonMass*amu(n))*sqrt(1.6e-16)*1.e9  ! phot(nPa)
  enddo
  delEE=delE*sqrt(energy)
  xlatr=xlat*cDegToRad

  ! Calculate CRCM ion density (m^-3), rrio, and flux (cm^-2 s^-1 keV^-1 sr^-1)
  ! at fixed energy & pitch-angle grids 
  aloge=log10(energy)
  jloop1: do j=1,nt
     iloop1: do i=1,iba(j)
        ftv1=ftv(i,j)     ! ftv1: flux tube volume in m^3/Wb
        rrio(i,j)=0.
        Pressure1=0.0
        nloop: do n=1,nspec
           amu1=amu(n)**1.5
!!!! Calculate rrio, and 2D flux, fl2D(log), ekev2D(log) and sinA1D
           do m=1,nk
              sinA1D(m)=sinA(i,j,m)
              do k=1,nm
                 psd1=f2(n,i,j,k,m)/1.e20/1.e19/xjac(n,i,k)  ! mug^-3cm^-6s^3
                 flx=psd1*(1.6e19*pp(n,i,j,k,m))*pp(n,i,j,k,m)
                 flux2D(k,m)=-50.
                 if (flx.gt.1.e-50) flux2D(k,m)=log10(flx)
                 ekev2D(k,m)=log10(ekev(i,j,k,m))
                 eta(n,i,j,k,m)=amu1*1.209*psd1*sqrt(xmm(k))*dmm(k)*dk(m)
                 psd(n,i,j,k,m)=psd1
                 rrio(i,j)=rrio(i,j)+eta(n,i,j,k,m)/ftv1
                 Pressure1=Pressure1+eta(n,i,j,k,m)*ekev(i,j,k,m)/ftv1
              enddo
           enddo
           Pressure1=Pressure1*1.6e-16*2./3.      ! pressure in Pa
           Pressure_C(i,j)=Pressure1*1.e9           ! pressure in nPa
!!!! Map flux to fixed energy and pitch-angle grids (energy, sinAo)
           do k=1,neng
              do m=1,npit
                 call lintp2a(ekev2D,sinA1D,flux2D,nm,nk,aloge(k),sinAo(m),flx_lo)
                 flux(n,i,j,k,m)=10.**flx_lo
              enddo
           enddo
        enddo nloop
     enddo iloop1
  enddo jloop1

  ! Calculate pressure of the 'hot' ring current, phot, and temperature, ttio
  jloop2: do j=1,nt
     iloop2: do i=1,iba(j)
!!!! calculate pitch-angle averaged flux
        do n=1,nspec
           do k=1,neng
              fave(n,i,j,k)=0.
              do m=1,npit
                 fave(n,i,j,k)=fave(n,i,j,k)+flux(n,i,j,k,m)*dmu(m)
              enddo
           enddo
        enddo
!!!! calculate pressure and temperature
        do n=1,nspec
           do k=1,neng
              phot(i,j)=phot(i,j)+fave(n,i,j,k)*delEE(k)*pf(n)  ! phot in nPa
           enddo
        enddo
        ttio(i,j)=0.
        if (rrio(i,j).gt.0.) ttio(i,j)=phot(i,j)*1.e-9/rrio(i,j)/1.6e-19   ! eV
     enddo iloop2
  enddo jloop2

  ! Calculate field aligned current, fac
  jloop3: do j=1,nt
     j1=j+1
     j_1=j-1
     if (j1.gt.nt) j1=j1-nt          !! periodic boundary condition
     if (j_1.lt.1) j_1=j_1+nt        !!
     iloop3: do i=2,iba(j)-1
        do k=1,nm
           do m=1,nk
              dwkdi=(ekev(i+1,j,k,m)-ekev(i-1,j,k,m))/(xlatr(i+1)-xlatr(i-1))
              dwkdj=(ekev(i,j1,k,m)-ekev(i,j_1,k,m))/(2.*dphi)
              do n=1,nspec
                 detadi=(eta(n,i+1,j,k,m)-eta(n,i-1,j,k,m))/(xlatr(i+1)-xlatr(i-1))
                 detadj=(eta(n,i,j1,k,m)-eta(n,i,j_1,k,m))/(2.*dphi)
                 fac(i,j)=fac(i,j)+(detadi*dwkdj-detadj*dwkdi)
              enddo
           enddo
        enddo
        fac(i,j)=1.6e-16*fac(i,j)/cos(xlatr(i))/rion**2    ! fac in Amp/m^2
     enddo iloop3
  enddo jloop3

end subroutine crcm_output


!-------------------------------------------------------------------------------
subroutine FLS_2D(np,nt,iba,fb0,fb1,cl,cp,f2d,fal,fap)
  !-------------------------------------------------------------------------------
  !  Routine calculates the inter-flux, fal(i+0.5,j) and fap(i,j+0.5), using
  !  2nd order flux limited scheme with super-bee flux limiter method
  !
  !  Input: np,nt,iba,fb0,fb1,cl,cp,f2d
  !  Output: fal,fap

  implicit none

  integer np,nt,iba(nt),i,j,j_1,j1,j2,ib
  real cl(np,nt),cp(np,nt),f2d(np,nt),fal(0:np,nt),fap(np,nt),fwbc(0:np+2,nt)
  real fb0(nt),fb1(nt),x,fup,flw,xsign,corr,xlimiter,r

  fwbc(1:np,1:nt)=f2d(1:np,1:nt)        ! fwbc is f2d with boundary condition

  ! Set up boundary condition
  fwbc(0,1:nt)=fb0(1:nt)
  do j=1,nt
     ib=iba(j)
     fwbc(ib+1:np+2,j)=fb1(j)
  enddo

  ! find fal and fap
  jloop: do j=1,nt
     j_1=j-1
     j1=j+1
     j2=j+2
     if (j_1.lt.1) j_1=j_1+nt
     if (j1.gt.nt) j1=j1-nt
     if (j2.gt.nt) j2=j2-nt
     iloop: do i=1,np
        ! find fal
        xsign=sign(1.,cl(i,j))
        fup=0.5*(1.+xsign)*fwbc(i,j)+0.5*(1.-xsign)*fwbc(i+1,j)       ! upwind
        flw=0.5*(1.+cl(i,j))*fwbc(i,j)+0.5*(1.-cl(i,j))*fwbc(i+1,j)   ! LW
        x=fwbc(i+1,j)-fwbc(i,j)
        if (abs(x).le.1.e-27) fal(i,j)=fup
        if (abs(x).gt.1.e-27) then
           if (xsign.eq.1.) r=(fwbc(i,j)-fwbc(i-1,j))/x
           if (xsign.eq.-1.) r=(fwbc(i+2,j)-fwbc(i+1,j))/x
           if (r.le.0.) fal(i,j)=fup
           if (r.gt.0.) then
              xlimiter=max(min(2.*r,1.),min(r,2.))
              corr=flw-fup
              fal(i,j)=fup+xlimiter*corr
           endif
        endif
        ! find fap
        xsign=sign(1.,cp(i,j))
        fup=0.5*(1.+xsign)*fwbc(i,j)+0.5*(1.-xsign)*fwbc(i,j1)   ! upwind
        flw=0.5*(1.+cp(i,j))*fwbc(i,j)+0.5*(1.-cp(i,j))*fwbc(i,j1)   ! LW
        x=fwbc(i,j1)-fwbc(i,j)
        if (abs(x).le.1.e-27) fap(i,j)=fup
        if (abs(x).gt.1.e-27) then
           if (xsign.eq.1.) r=(fwbc(i,j)-fwbc(i,j_1))/x
           if (xsign.eq.-1.) r=(fwbc(i,j2)-fwbc(i,j1))/x
           if (r.le.0.) fap(i,j)=fup
           if (r.gt.0.) then
              xlimiter=max(min(2.*r,1.),min(r,2.))
              corr=flw-fup
              fap(i,j)=fup+xlimiter*corr
           endif
        endif
     enddo iloop
  enddo jloop

end subroutine FLS_2D

! OLD LINTP
!!-----------------------------------------------------------------------
!subroutine lintp(xx,yy,n,x,y,ier)
!  !-----------------------------------------------------------------------
!  !  Routine does 1-D interpolation.  xx must be increasing or decreasing
!  !  monotonically.  x is between xx(1) and xx(n)
!  ! 
!  !  input: xx,yy,n,x
!  !  output: y,ier
!
!  implicit none
!
!  integer n,ier,i,jl,ju,jm,j
!  real xx(n),yy(n),x,y,d
!
!  ier = 0
!
!  ! Make sure xx is increasing or decreasing monotonically
!  do i=2,n
!     if (xx(n).gt.xx(1).and.xx(i).lt.xx(i-1)) then
!        write(*,*) ' lintp: xx is not increasing monotonically '
!        write(*,*) n,xx
!        stop
!     endif
!     if (xx(n).lt.xx(1).and.xx(i).gt.xx(i-1)) then
!        write(*,*) ' lintp: xx is not decreasing monotonically '
!        write(*,*) n,xx
!        stop
!     endif
!  enddo
!
!  ! Set ier=1 if out of range
!  if (xx(n).gt.xx(1)) then
!     if (x.lt.xx(1).or.x.gt.xx(n)) ier=1
!  else
!     if (x.gt.xx(1).or.x.lt.xx(n)) ier=1
!  endif
!  if (ier.eq.1) then
!     write(*,*) ' Error: ier.eq.1'
!     print *,'n,x ',n,x
!     print *,'xx(1:n) ',xx(1:n)
!     stop
!  endif
!
!  ! initialize lower and upper values
!  jl=1
!  ju=n
!
!  ! if not done compute a midpoint
!10 if (ju-jl.gt.1) then
!     jm=(ju+jl)/2
!     ! now replace lower or upper limit
!     if ((xx(n).gt.xx(1)).eqv.(x.gt.xx(jm))) then
!        jl=jm
!     else
!        ju=jm
!     endif
!     ! try again
!     go to 10
!  endif
!
!  ! this is the j
!  j=jl      ! if x.le.xx(1) then j=1
!  ! if x.gt.x(j).and.x.le.x(j+1) then j=j
!  ! if x.gt.x(n) then j=n-1
!  d=xx(j+1)-xx(j)
!  y=(yy(j)*(xx(j+1)-x)+yy(j+1)*(x-xx(j)))/d
!
!end subroutine lintp


!-------------------------------------------------------------------------------
subroutine lintp2a(x,y,v,nx,ny,x1,y1,v1)
  !-----------------------------------------------------------------------------
  !  This sub program takes 2-d interplation. x is 2-D and y is 1-D.
  !
  !  Input: x,y,v,nx,ny,x1,y1
  !  Output: v1

  implicit none               

  integer nx,ny,j,j1,i,i1,i2,i3
  real x(nx,ny),y(ny),v(nx,ny),x1,y1,v1,a,a1,b,x1d(1000)   ! max(nx)=1000
  real q00,q01,q10,q11

  call locate1(y,ny,y1,j)
  j1=j+1
  if (j.eq.0.or.j1.gt.ny) then
     b=1.
     if (j.eq.0) j=j1
     if (j1.gt.ny) j1=j
  else
     b=(y1-y(j))/(y(j+1)-y(j))
  endif

  x1d(1:nx)=x(1:nx,j)
  call locate1(x1d,nx,x1,i)
  i1=i+1
  if (i.eq.0.or.i1.gt.nx) then
     a=1.
     if (i.eq.0) i=i1
     if (i1.gt.nx) i1=i
  else
     a=(x1-x1d(i))/(x1d(i+1)-x1d(i))
  endif

  x1d(1:nx)=x(1:nx,j1)
  call locate1(x1d,nx,x1,i2)
  i3=i2+1
  if (i2.eq.0.or.i3.gt.nx) then
     a1=1.
     if (i2.eq.0) i2=i3
     if (i3.gt.nx) i3=i2
  else
     a1=(x1-x1d(i2))/(x1d(i2+1)-x1d(i2))
  endif

  q00=(1.-a)*(1.-b)
  q01=(1.-a1)*b
  q10=a*(1.-b)
  q11=a1*b
  v1=q00*v(i,j)+q01*v(i2,j1)+q10*v(i1,j)+q11*v(i3,j1)

end subroutine lintp2a


!--------------------------------------------------------------------------
subroutine locate1(xx,n,x,j)
  !--------------------------------------------------------------------------
  !  Routine return a value of j such that x is between xx(j) and xx(j+1).
  !  xx must be increasing or decreasing monotonically.
  !  If xx is increasing:
  !     If x=xx(m), j=m-1 so if x=xx(1), j=0  and if x=xx(n), j=n-1
  !     If x < xx(1), j=0  and if x > xx(n), j=n
  !  If xx is decreasing:
  !     If x=xx(m), j=m so if x=xx(1), j=1  and if x=xx(n), j=n
  !     If x > xx(1), j=0  and if x < xx(n), j=n
  !
  !  Input: xx,n,x
  !  Output: j

  implicit none

  integer n,j,i,jl,ju,jm
  real xx(n),x

  ! Make sure xx is increasing or decreasing monotonically
  do i=2,n
     if (xx(n).gt.xx(1).and.xx(i).lt.xx(i-1)) then
        write(*,*) ' locate1: xx is not increasing monotonically '
        write(*,*) n, (xx(j),j=1,n)
        stop
     endif
     if (xx(n).lt.xx(1).and.xx(i).gt.xx(i-1)) then
        write(*,*) ' locate1: xx is not decreasing monotonically '
        write(*,*) ' n, xx  ',n,xx
        stop
     endif
  enddo

  jl=0
  ju=n+1
  test: do
     if (ju-jl.le.1) exit test
     jm=(ju+jl)/2
     if ((xx(n).gt.xx(1)).eqv.(x.gt.xx(jm))) then
        jl=jm
     else
        ju=jm
     endif
  end do test
  j=jl

end subroutine locate1


!Old CLOSED SUBROUTINE
!!--------------------------------------------------------------------------
!subroutine closed(n1,n2,yy,dx,ss)
!  !--------------------------------------------------------------------------
!  ! Routine does numerical integration using closed form.
!  ! 
!  ! Input: n1,n2,yy,dx
!  ! Output: ss
!
!  implicit none
!
!  integer n1,n2,i
!  real yy(n2),dx(n2),ss
!
!  ss=0.
!  do i=n1,n2
!     ss=ss+yy(i)*dx(i)
!  enddo
!
!end subroutine closed

