! Copyright (C) 2001-2009 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .

! This program writes the structure and wavefunction to a binary file
! (with extension pwc) read by critic2. At present, this is used
! in combination with the output of wannier90 in the calculation of
! delocalization indices via maximally localized Wannier functions
! (http://dx.doi.org/10.1021/acs.jctc.8b00549).
!
! Preferred use: with norm-conserving pseudos, since critic2 will not
! know about the transformation near the atoms. Some notes:
! - The density in critic2 won't match exactly the one generated by
!   pp.x in general because QE symmetrizes the contributions in
!   reciprocal space (see the sym_rho subroutine in
!   PW/src/symme.f90). critic2 will not do this, so the densities will
!   be slightly different, but nothing too bad in general. If you
!   still feel uneasy about it, use nosym=.true. in the calculation.
! - Non-colinear case not supported.
! - Right now, pw2critic only works in serial mode (no mpirun xx)
!   and the SCF calculation needs to be run with wf_collect=.true.
!
! Input: only one namelist (&inputpp) with variables:
! - outdir - the output directory.
! - prefix - the prefix for the SCF calculation.
! - seedname - the prefix for the generated pwc file
! - smoothgrid - if .true., write the smooth grid dimensions.
!   (default:.false.)
!
! TODO: handle parallelization.
! Contact: Alberto Otero de la Roza <aoterodelaroza@gmail.com>
PROGRAM pw2critic
  USE io_global, ONLY : ionode, ionode_id
  USE mp_global, ONLY : mp_startup
  USE wavefunctions, ONLY: evc
  USE wvfct, ONLY: nbnd, npwx, et, wg
  USE gvecs, ONLY: ngms
  USE mp, ONLY : mp_bcast
  USE mp_world, ONLY : world_comm, nproc
  USE cell_base, ONLY : at, alat
  USE ions_base, ONLY: nat, nsp, atm, ityp, tau
  USE lsda_mod, ONLY : nspin
  USE klist, ONLY : nkstot, ngk, igk_k, wk, xk
  USE fft_base, ONLY: dffts, dfftp
  USE io_files, ONLY : prefix, tmp_dir, nwordwfc, iunwfc
  USE control_flags, ONLY : gamma_only
  USE environment, ONLY : environment_start, environment_end
  USE start_k, ONLY : nk1, nk2, nk3
  IMPLICIT NONE

  INTEGER, EXTERNAL :: find_free_unit
  CHARACTER(LEN=256), EXTERNAL :: trimcheck
  INTEGER :: ios, i, j, ibnd, ik, is, lu1, n1, n2, n3, nk, npw
  CHARACTER(len=256) :: outdir, seedname
  logical :: smoothgrid

  NAMELIST /inputpp/ outdir, prefix, seedname, smoothgrid

  ! initialise environment
#if defined(__MPI)
  CALL mp_startup()
#endif
  if (nproc /= 1) &
     CALL errore('pw2wannier90','pw2critic only works with 1 processor',1)
  CALL environment_start('PW2CRITIC')

  ! read the input variables
  ios = 0
  IF(ionode) THEN
     CALL input_from_file()
     CALL get_environment_variable( 'ESPRESSO_TMPDIR', outdir )
     IF (trim(outdir) == ' ' ) outdir = './'
     prefix = ' '
     seedname = 'wannier'
     smoothgrid = .false.
     READ (5, inputpp, iostat=ios)
     tmp_dir = trimcheck(outdir)
  endif

  ! broadcast to all processors
  CALL mp_bcast(ios, ionode_id, world_comm)
  IF (ios /= 0) CALL errore('pw2critic','reading inputpp namelist',abs(ios))
  CALL mp_bcast(outdir, ionode_id, world_comm)
  CALL mp_bcast(tmp_dir, ionode_id, world_comm)
  CALL mp_bcast(prefix, ionode_id, world_comm)
  CALL mp_bcast(seedname, ionode_id, world_comm)
  CALL mp_bcast(smoothgrid, ionode_id, world_comm)

  ! read the calculation info
  CALL read_file()
  CALL openfil_pp()
  IF (nspin > 2) &
     CALL errore('pw2critic','nspin > 2 not implemented',1)
  nk = nkstot / nspin

  ! open the pwc file
  lu1 = find_free_unit()
  OPEN(unit=lu1,file=trim(seedname)//".pwc",form='unformatted')

  ! header and structural info
  WRITE (lu1) 1 ! version number
  WRITE (lu1) nsp, nat
  WRITE (lu1) atm(1:nsp)
  WRITE (lu1) ityp(1:nat)
  WRITE (lu1) tau(:,1:nat) * alat
  WRITE (lu1) at(1:3,1:3) * alat

  ! global info for the wavefunction
  write (lu1) nk, nbnd, nspin, gamma_only
  write (lu1) nk1, nk2, nk3
  if (smoothgrid) then
     write (lu1) dffts%nr1, dffts%nr2, dffts%nr3
  else
     write (lu1) dfftp%nr1, dfftp%nr2, dfftp%nr3
  end if
  write (lu1) npwx, ngms

  ! k-point information in nspin==2, these are doubled (nkstot = 2 *
  ! nk), but it seems to be a convention in the rest of the code that
  ! xk(:,1:nk) is the same as xk(:,nk+1:nkstot), so I write only the
  ! relevant part of it
  write (lu1) xk(:,1:nk)
  write (lu1) wk(1:nk)

  ! Band energies (in Ry) and occupations. 1->nk is spin up and nk+1
  ! -> nkstot is spin down. The occupations (wg) already factor in the
  ! k-point weights (wk).
  write (lu1) et(1:nbnd,1:nkstot)
  write (lu1) wg(1:nbnd,1:nkstot)

  ! k-point mapping 
  write (lu1) ngk(1:nk)
  write (lu1) igk_k(1:npwx,1:nk)
  if (smoothgrid) then
     write (lu1) dffts%nl
     if (gamma_only) then
        write (lu1) dffts%nlm
     end if
  else
     write (lu1) dfftp%nl
     if (gamma_only) then
        write (lu1) dfftp%nlm
     end if
  end if

  ! KS state coefficients. Note the loop over nkstot writes both
  ! spins if nspin == 2.
  do ik = 1, nkstot
     npw = ngk(ik)
     call davcio(evc, 2*nwordwfc, iunwfc, ik, -1 )
     do ibnd = 1, nbnd
        write (lu1) evc(1:npw,ibnd)
     end do
  end DO

  ! clean up and exit
  CLOSE(lu1)
  CALL environment_end('PW2CRITIC')
  CALL stop_pp()

END PROGRAM pw2critic
 
