#!python
#cython: boundscheck=False
#cython: wraparound=False
#cython: initializedcheck=False
#cython: cdivision=True

from libc.math cimport fmin, fmax, sin
import cython
import netCDF4 as nc
import numpy as np
cimport ParallelMPI as ParallelMPI
cimport PrognosticVariables as PrognosticVariables
cimport Grid as Grid
cimport ReferenceState
cimport DiagnosticVariables
cimport numpy as np
from thermodynamic_functions cimport pd_c, pv_c
from entropies cimport sv_c, sd_c
from scipy.special import erf
import pickle as pickle
cimport TimeStepping
from scipy.interpolate import pchip
from thermodynamic_functions cimport cpm_c
from cfsites_forcing_reader import cfreader
from cfgrid_forcing_reader import cfreader_grid
include 'parameters.pxi'

cdef class Damping:
    def __init__(self, namelist, ParallelMPI.ParallelMPI Pa):
        if(namelist['damping']['scheme'] == 'None'):
            self.scheme = Dummy(namelist, Pa)
            Pa.root_print('No Damping!')
        elif(namelist['damping']['scheme'] == 'Rayleigh'):
            casename = namelist['meta']['casename']
            if casename == 'GCMNew':
                self.scheme = RayleighGCMNew(namelist, Pa)
            elif casename == 'GCMVarying':
                self.scheme = RayleighGCMNew(namelist, Pa)
            else:
                self.scheme = Rayleigh(namelist, Pa)
                Pa.root_print('Using Rayleigh Damping')


        return

    cpdef initialize(self, Grid.Grid Gr, ReferenceState.ReferenceState RS):
        self.scheme.initialize(Gr, RS)
        return

    cpdef update(self, Grid.Grid Gr, ReferenceState.ReferenceState RS, PrognosticVariables.PrognosticVariables PV,
                 DiagnosticVariables.DiagnosticVariables DV, ParallelMPI.ParallelMPI Pa, TimeStepping.TimeStepping TS):
        self.scheme.update(Gr, RS, PV, DV, Pa, TS)
        return

cdef class Dummy:
    def __init__(self, namelist, ParallelMPI.ParallelMPI Pa):
        return

    cpdef update(self, Grid.Grid Gr, ReferenceState.ReferenceState RS, PrognosticVariables.PrognosticVariables PV,
                 DiagnosticVariables.DiagnosticVariables DV, ParallelMPI.ParallelMPI Pa, TimeStepping.TimeStepping TS):
        return

    cpdef initialize(self, Grid.Grid Gr, ReferenceState.ReferenceState RS):
        return

cdef class RayleighGCMNew:
    def __init__(self, namelist, ParallelMPI.ParallelMPI Pa):

        self.file = str(namelist['gcm']['file'])
        try:
            self.griddata = namelist['gcm']['griddata']
        except:
            self.griddata = False
        if self.griddata:
            self.lat = namelist['gcm']['lat']
            self.lon = namelist['gcm']['lon']
        else:
            self.site = namelist['gcm']['site']

        try:
            self.z_d = namelist['damping']['Rayleigh']['z_d']
        except:
            Pa.root_print('Rayleigh damping z_d not given in namelist')
            Pa.root_print('Killing simulation now!')
            Pa.kill()
        
        try:
            self.gamma_r = namelist['damping']['Rayleigh']['gamma_r']
        except:
            Pa.root_print('Rayleigh damping gamm_r not given in namelist')
            Pa.root_print('Killing simulation now!')
            Pa.kill()
        
        try:
            self.truncate = namelist['damping']['Rayleigh']['truncate']
        except:
            self.truncate = False
        
        try:
            self.tau_max = namelist['damping']['Rayleigh']['tau_max']
        except:
            self.tau_max = 43200.0

        try:
            self.damp_scalar = namelist['damping']['Rayleigh']['damp_scalar']
        except:
            self.damp_scalar = False
        
        try:
            self.damp_scalar = namelist['damping']['Rayleigh']['damp_w']
        except:
            self.damp_w = False

        self.gcm_profiles_initialized = False
        self.t_indx = 0

        return

    cpdef initialize(self, Grid.Grid Gr, ReferenceState.ReferenceState RS):
        cdef:
            int k
            double z_top

        self.gamma_zhalf = np.zeros(
            (Gr.dims.nlg[2]),
            dtype=np.double,
            order='c')
        self.gamma_z = np.zeros((Gr.dims.nlg[2]), dtype=np.double, order='c')
        self.xi_z = np.zeros((Gr.dims.nlg[2]), dtype=np.double, order='c')
        self.ucomp = np.zeros((Gr.dims.nlg[2]), dtype=np.double, order='c')
        self.vcomp = np.zeros((Gr.dims.nlg[2]), dtype=np.double, order='c')
        z_top = Gr.zpl[Gr.dims.nlg[2] - Gr.dims.gw]

        #self.z_d = 20000.0 #122019[ZS]
        with nogil:
            for k in range(Gr.dims.nlg[2]):
                if Gr.zpl_half[k] >= z_top - self.z_d:
                    self.gamma_zhalf[
                        k] = self.gamma_r * sin((pi / 2.0) * (1.0 - (z_top - Gr.zpl_half[k]) / self.z_d))**2.0
                if Gr.zpl[k] >= z_top - self.z_d:
                    self.gamma_z[
                        k] = self.gamma_r * sin((pi / 2.0) * (1.0 - (z_top - Gr.zpl[k]) / self.z_d))**2.0
        #with nogil:
        #    for k in range(Gr.dims.nlg[2]):
        #        self.gamma_zhalf[k] = self.gamma_r * (0.5 + 0.5 * tanh((Gr.zpl_half[k] - self.z_d) / self.h))
        #        self.gamma_z[k] = self.gamma_r * (0.5 + 0.5 * tanh((Gr.zpl[k] - self.z_d) / self.h))
        
        if self.truncate:
            with nogil:
                for k in range(Gr.dims.nlg[2]):
                    if self.gamma_zhalf[k] < 1.0 / self.tau_max:
                        self.gamma_zhalf[k] = 1.0 / self.tau_max
                    if self.gamma_z[k] < 1.0 / self.tau_max:
                        self.gamma_z[k] = 1.0 / self.tau_max
#        import pylab as plt
#        plt.figure()
#        plt.plot(self.gamma_z)
#        plt.show()
#        import sys; sys.exit()


        #Set up tendency damping using error function
        #fh = open(self.file, 'r')
        #input_data_tv = pickle.load(fh)
        #fh.close()

        if self.griddata:
            rdr = cfreader_grid(self.file, self.lat, self.lon)
        else:
            rdr = cfreader(self.file, self.site)

        #Compute height for damping profiles
        #dt_qg_conv = np.mean(input_data_tv['dt_qg_param'][:,::-1],axis=0)
        #zfull = rdr.get_profile_mean('height')#np.mean(input_data_tv['zfull'][:,::-1], axis=0)
        temp = rdr.get_interp_profile('ta', Gr.zp_half)
        self.ucomp = rdr.get_interp_profile('ua', Gr.zp_half)
        self.vcomp = rdr.get_interp_profile('va', Gr.zp_half)
        #temp = interp_pchip(Gr.zp_half, zfull, temp)
        #import pylab as plt
        #plt.plot(np.abs(dt_qg_conv))

        return

    cpdef update(self, Grid.Grid Gr, ReferenceState.ReferenceState RS, PrognosticVariables.PrognosticVariables PV,
                 DiagnosticVariables.DiagnosticVariables DV, ParallelMPI.ParallelMPI Pa, TimeStepping.TimeStepping TS):
        cdef:
            Py_ssize_t var_shift
            Py_ssize_t imin = Gr.dims.gw
            Py_ssize_t jmin = Gr.dims.gw
            Py_ssize_t kmin = Gr.dims.gw
            Py_ssize_t gw = Gr.dims.gw
            Py_ssize_t imax = Gr.dims.nlg[0] - Gr.dims.gw
            Py_ssize_t jmax = Gr.dims.nlg[1] - Gr.dims.gw
            Py_ssize_t kmax = Gr.dims.nlg[2] - Gr.dims.gw
            Py_ssize_t istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            Py_ssize_t jstride = Gr.dims.nlg[2]
            Py_ssize_t i, j, k, ishift, jshift, ijk
            double[:] domain_mean
            double[:] u_mean
            double[:] v_mean
            Py_ssize_t t_shift = DV.get_varshift(Gr, 'temperature')
            Py_ssize_t ql_shift = DV.get_varshift(Gr,'ql')
            Py_ssize_t qt_shift = PV.get_varshift(Gr, 'qt')
            Py_ssize_t s_shift
            Py_ssize_t u_shift = PV.get_varshift(Gr, 'u')
            Py_ssize_t v_shift = PV.get_varshift(Gr, 'v')
            double pd, pv, qt, qv, p0, rho0, t
            double weight


       # if not self.gcm_profiles_initialized or int(TS.t // (3600.0 * 6.0)) > self.t_indx:
       #     self.t_indx = int(TS.t // (3600.0 * 6.0))
       #     self.gcm_profiles_initialized = True
       #     Pa.root_print('Updating Total Tendencies in damping!')

       #     fh = open(self.file, 'r')
       #     input_data_tv = pickle.load(fh)
       #     fh.close()

            #zfull = input_data_tv['zfull'][self.t_indx,::-1]
            #temp_dt_total = input_data_tv['temp_total'][self.t_indx,::-1]
            #shum_dt_total = input_data_tv['dt_qg_total'][self.t_indx,::-1]

           # zfull = np.mean(input_data_tv['zfull'][:,::-1], axis=0)
            #temp_dt_total = np.mean(input_data_tv['temp_total'][:,::-1], axis=0)
            #shum_dt_total = np.mean(input_data_tv['dt_qg_total'][:,::-1], axis=0)

            #self.dt_tg_total = interp_pchip(Gr.zp_half, zfull, temp_dt_total)
            #self.dt_qg_total =  interp_pchip(Gr.zp_half, zfull, shum_dt_total)




        for var_name in PV.name_index:
            var_shift = PV.get_varshift(Gr, var_name)
            domain_mean = Pa.HorizontalMean(Gr, & PV.values[var_shift])
            if var_name == 'w' and self.damp_w:
                Pa.root_print('Damping w')
                with nogil:
                    for i in xrange(imin, imax):
                        ishift = i * istride
                        for j in xrange(jmin, jmax):
                            jshift = j * jstride
                            for k in xrange(kmin, kmax):
                                ijk = ishift + jshift + k
                                PV.tendencies[var_shift + ijk] -= (PV.values[var_shift + ijk] - 0.0) * self.gamma_zhalf[k]

            elif var_name == 'u' or var_name == 'v':
                with nogil:
                    for i in xrange(imin, imax):
                        ishift = i * istride
                        for j in xrange(jmin, jmax):
                            jshift = j * jstride
                            for k in xrange(kmin, kmax):
                                ijk = ishift + jshift + k
                                PV.tendencies[var_shift + ijk] -= (PV.values[var_shift + ijk] - domain_mean[k]) * self.gamma_z[k]
            elif self.damp_scalar:
                #Pa.root_print('Damping scalar')
                with nogil:
                    for i in xrange(imin, imax):
                        ishift = i * istride
                        for j in xrange(jmin, jmax):
                            jshift = j * jstride
                            for k in xrange(kmin, kmax):
                                ijk = ishift + jshift + k
                                #PV.tendencies[var_shift + ijk] *= self.tend_flat[k]
                                PV.tendencies[var_shift + ijk] -= (PV.values[var_shift + ijk] - domain_mean[k]) * self.gamma_z[k]
        u_shift = PV.get_varshift(Gr, 'u')
        u_mean = Pa.HorizontalMean(Gr, & PV.values[u_shift])
        v_shift = PV.get_varshift(Gr, 'v')
        v_mean = Pa.HorizontalMean(Gr, & PV.values[v_shift])
        return

cdef class Rayleigh:
    def __init__(self, namelist, ParallelMPI.ParallelMPI Pa):


        try:
            self.z_d = namelist['damping']['Rayleigh']['z_d']
        except:
            Pa.root_print('Rayleigh damping z_d not given in namelist')
            Pa.root_print('Killing simulation now!')
            Pa.kill()

        try:
            self.gamma_r = namelist['damping']['Rayleigh']['gamma_r']
        except:
            Pa.root_print('Rayleigh damping gamm_r not given in namelist')
            Pa.root_print('Killing simulation now!')
            Pa.kill()
        return

    cpdef initialize(self, Grid.Grid Gr, ReferenceState.ReferenceState RS):
        cdef:
            int k
            double z_top

        self.gamma_zhalf = np.zeros(
            (Gr.dims.nlg[2]),
            dtype=np.double,
            order='c')
        self.gamma_z = np.zeros((Gr.dims.nlg[2]), dtype=np.double, order='c')
        z_top = Gr.zpl[Gr.dims.nlg[2] - Gr.dims.gw]

        with nogil:
            for k in range(Gr.dims.nlg[2]):
                if Gr.zpl_half[k] >= z_top - self.z_d:
                    self.gamma_zhalf[
                        k] = self.gamma_r * sin((pi / 2.0) * (1.0 - (z_top - Gr.zpl_half[k]) / self.z_d))**2.0
                if Gr.zpl[k] >= z_top - self.z_d:
                    self.gamma_z[
                        k] = self.gamma_r * sin((pi / 2.0) * (1.0 - (z_top - Gr.zpl[k]) / self.z_d))**2.0



        #Set up tendency damping using error function
        z_damp = z_top - self.z_d
        z = (np.array(Gr.zp) - z_damp)/( self.z_d*0.5)
        z_half = (np.array(Gr.zp_half) - z_damp)/( self.z_d*0.5)

        tend_flat = erf(z)
        tend_flat[tend_flat < 0.0] = 0.0
        tend_flat = 1.0 - tend_flat
        self.tend_flat = tend_flat
        tend_flat = erf(z_half)
        tend_flat[tend_flat < 0.0] = 0.0
        tend_flat = 1.0 - tend_flat
        self.tend_flat_half = tend_flat


        return

    cpdef update(self, Grid.Grid Gr, ReferenceState.ReferenceState RS, PrognosticVariables.PrognosticVariables PV,
                 DiagnosticVariables.DiagnosticVariables DV, ParallelMPI.ParallelMPI Pa, TimeStepping.TimeStepping TS):
        cdef:
            Py_ssize_t var_shift
            Py_ssize_t imin = Gr.dims.gw
            Py_ssize_t jmin = Gr.dims.gw
            Py_ssize_t kmin = Gr.dims.gw
            Py_ssize_t imax = Gr.dims.nlg[0] - Gr.dims.gw
            Py_ssize_t jmax = Gr.dims.nlg[1] - Gr.dims.gw
            Py_ssize_t kmax = Gr.dims.nlg[2] - Gr.dims.gw
            Py_ssize_t istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            Py_ssize_t jstride = Gr.dims.nlg[2]
            Py_ssize_t i, j, k, ishift, jshift, ijk
            double[:] domain_mean


        for var_name in PV.name_index:
            var_shift = PV.get_varshift(Gr, var_name)
            domain_mean = Pa.HorizontalMean(Gr, & PV.values[var_shift])
            if var_name == 'w':
                with nogil:
                    for i in xrange(imin, imax):
                        ishift = i * istride
                        for j in xrange(jmin, jmax):
                            jshift = j * jstride
                            for k in xrange(kmin, kmax):
                                ijk = ishift + jshift + k
                                PV.tendencies[var_shift + ijk] *= self.tend_flat_half[k]

            elif var_name == 'u' or var_name == 'v':
                with nogil:
                    for i in xrange(imin, imax):
                        ishift = i * istride
                        for j in xrange(jmin, jmax):
                            jshift = j * jstride
                            for k in xrange(kmin, kmax):
                                ijk = ishift + jshift + k
                                PV.tendencies[var_shift + ijk] -= (PV.values[var_shift + ijk] - domain_mean[k]) * self.gamma_z[k]
            else:
                with nogil:
                    for i in xrange(imin, imax):
                        ishift = i * istride
                        for j in xrange(jmin, jmax):
                            jshift = j * jstride
                            for k in xrange(kmin, kmax):
                                ijk = ishift + jshift + k
                                PV.tendencies[var_shift + ijk] *= self.tend_flat[k]
                                PV.tendencies[var_shift + ijk] -= (PV.values[var_shift + ijk] - domain_mean[k]) * self.gamma_z[k]
        return


from scipy.interpolate import pchip
def interp_pchip(z_out, z_in, v_in, pchip_type=False):
    if pchip_type:
        p = pchip(z_in, v_in, extrapolate=True)
        return p(z_out)
    else:
        return np.interp(z_out, z_in, v_in)
