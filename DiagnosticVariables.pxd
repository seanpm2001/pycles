cimport ParallelMPI
cimport Grid
cimport ReferenceState
from NetCDFIO cimport NetCDFIO_Stats
cdef class DiagnosticVariables:
    cdef:
        dict name_index
        dict units
        dict nice_name
        dict desc
        list index_name
        Py_ssize_t nv
        double [:] values
        double [:] bc_type
        long [:] sedv_index
        Py_ssize_t nsedv
        dict name_index_2d
        dict units_2d
        Py_ssize_t  nv_2d
        double [:] values_2d
        void communicate_variable(self,Grid.Grid Gr,ParallelMPI.ParallelMPI PM, long nv)
        
    cpdef mean_prof(self, Grid.Grid Gr, ParallelMPI.ParallelMPI Pa, str var)
    cpdef add_variables(self, name, units, nice_name, desc, bc_type, ParallelMPI.ParallelMPI Pa)
    cpdef initialize(self,Grid.Grid Gr, NetCDFIO_Stats NS, ParallelMPI.ParallelMPI Pa)
    cpdef get_variable_array(self,name,Grid.Grid Gr)
    cdef inline int get_nv(self, str variable_name):
        return self.name_index[variable_name]
    cdef inline int get_varshift(self, Grid.Grid Gr, str variable_name):
        return self.name_index[variable_name] * Gr.dims.npg
    cpdef val_nan(self,PA,message)
    cpdef stats_io(self, Grid.Grid Gr, NetCDFIO_Stats NS, ParallelMPI.ParallelMPI Pa)
    cpdef add_variables_2d(self, name, units)
    cpdef debug_large(self, Grid.Grid Gr, ReferenceState.ReferenceState RS ,NetCDFIO_Stats NS, ParallelMPI.ParallelMPI Pa, str message)
    cdef inline int get_nv_2d(self, str variable_name):
        return self.name_index_2d[variable_name]
    cdef inline int get_varshift_2d(self, Grid.Grid Gr, str variable_name):
        return self.name_index_2d[variable_name] * Gr.dims.nlg[0] * Gr.dims.nlg[1]