from libc.stdlib cimport malloc, calloc, free

from pygpu.gpuarray cimport (gpucontext, GpuContext, _GpuArray, GpuArray,
                             ensure_context,
                             GA_NO_ERROR, get_exc, gpucontext_error,
                             GpuArray_IS_C_CONTIGUOUS,
                             GA_C_ORDER, GA_F_ORDER, GA_ANY_ORDER,
                             pygpu_empty_like, pygpu_empty, memcpy)
from pygpu.gpuarray import GpuArrayException


cdef class GpuCommCliqueId:
    """Represents a unique id shared among :ref:`GpuComm` communicators which
    participate in a multi-gpu clique.

    Parameters
    ----------
    context: :ref:`GpuContext`, optional
        Reference to which gpu this `GpuCommCliqueId` object belongs.
    comm_id: bytes, optional
        Existing unique id to be passed in this object.

    """
    def __cinit__(self, GpuContext context=None, bytes comm_id=None):
        self.context = ensure_context(context)
        if comm_id is not None:
            self.comm_id = comm_id
        else:
            comm_generate_id(self.context.ctx, self)

    def __eq__(self, other):
        return type(self) == type(other) and self.comm_id_py == other.comm_id_py

    def __hash__(self):
        return hash(self.__class__.__name__) ^ hash(self.comm_id_py)

    def __reduce__(self):
        raise RuntimeError, "Cannot pickle %s object" % self.__class__.__name__

    property comm_id:
        "Unique clique id to be used by each :ref:`GpuComm` in a group of devices"
        def __get__(self):
            cdef bytes res
            res = self.comm_id.internal[:GA_COMM_ID_BYTES]
            return res

        def __set__(self, unsigned char[:] bytearr):
            cdef int length
            length = bytearr.shape[0]
            if length < GA_COMM_ID_BYTES:
                raise ValueError, "GpuComm clique id must have length %d bytes" % (GA_COMM_ID_BYTES)
            memcpy(self.comm_id.internal, <char*>&bytearr[0], GA_COMM_ID_BYTES)


cdef class GpuComm:
    """Represents a communicator which participates in a multi-gpu clique.

    It is used to invoke collective operations to gpus inside its clique.

    Parameters
    ----------
    cid: :ref:`GpuCommCliqueId`
        Unique id shared among participating communicators.
    ndev: int
        Number of communicators inside the clique.
    rank: int
        User-defined rank of this communicator inside the clique. It influences
        order of collective operations.

    """
    def __dealloc__(self):
        gpucomm_free(self.c)

    def __cinit__(self, GpuCommCliqueId cid not None, int ndev, int rank):
        cdef int err
        err = gpucomm_new(&self.c, cid.context.ctx, cid.comm_id, ndev, rank)
        if err != GA_NO_ERROR:
            raise get_exc(err), gpucontext_error(cid.context.ctx, err)

    def __reduce__(self):
        raise RuntimeError, "Cannot pickle %s object" % self.__class__.__name__

    property count:
        "Total number of communicators inside the clique"
        def __get__(self):
            cdef int gpucount
            comm_get_count(self, &gpucount)
            return gpucount

    property rank:
        "User-defined rank of this communicator inside the clique"
        def __get__(self):
            cdef int gpurank
            comm_get_rank(self, &gpurank)
            return gpurank

    def reduce(self, GpuArray src not None, op, GpuArray dest=None, int root=-1):
        """Reduce collective operation for ranks in a communicator world.

        Parameters
        ----------
        src: :ref:`GpuArray`
            Array to be reduced.
        op: string
            Key indicating operation type.
        dest: :ref:`GpuArray`, optional
            Array to collecti reduce operation result.
        root: int
            Rank in `GpuComm` which will collect result.

        Notes
        -----
        * `root` is necessary when invoking from a non-root rank. Root caller
        needs not to provide `root` argument.
        * Not providing `dest` argument for a root caller will result in creating
        a new compatible :ref:`GpuArray` and returning result in it.

        """
        if dest is None:
            if root != -1:
                return comm_reduce_from(self, src, to_reduce_opcode(op), root)
            else:
                return pygpu_make_reduced(self, src, to_reduce_opcode(op))
        if root == -1:
            comm_get_rank(self, &root)
        return comm_reduce(self, src, dest, to_reduce_opcode(op), root)

    def all_reduce(self, GpuArray src not None, op, GpuArray dest=None):
        """AllReduce collective operation for ranks in a communicator world.

        Parameters
        ----------
        src: :ref:`GpuArray`
            Array to be reduced.
        op: string
            Key indicating operation type.
        dest: :ref:`GpuArray`, optional
            Array to collect reduce operation result.

        Notes
        -----
        * Not providing `dest` argument for a root caller will result in creating
        a new compatible :ref:`GpuArray` and returning result in it.

        """
        if dest is None:
            return pygpu_make_all_reduced(self, src, to_reduce_opcode(op))
        return comm_all_reduce(self, src, dest, to_reduce_opcode(op))

    def reduce_scatter(self, GpuArray src not None, op, GpuArray dest=None):
        """ReduceScatter collective operation for ranks in a communicator world.

        Parameters
        ----------
        src: :ref:`GpuArray`
            Array to be reduced.
        op: string
            Key indicating operation type.
        dest: :ref:`GpuArray`, optional
            Array to collect reduce operation scattered result.

        Notes
        -----
        * Not providing `dest` argument for a root caller will result in creating
        a new compatible :ref:`GpuArray` and returning result in it.

        """
        if dest is None:
            return pygpu_make_reduce_scattered(self, src, to_reduce_opcode(op))
        return comm_reduce_scatter(self, src, dest, to_reduce_opcode(op))

    def broadcast(self, GpuArray array not None, int root=-1):
        """Broadcast collective operation for ranks in a communicator world.

        Parameters
        ----------
        array: :ref:`GpuArray`
            Array to be reduced.
        root: int
            Rank in `GpuComm` which broadcasts its `array`.

        Notes
        -----
        * `root` is necessary when invoking from a non-root rank. Root caller
        does not need to provide `root` argument.

        """
        if root == -1:
            comm_get_rank(self, &root)
        return comm_broadcast(self, array, root)

    def all_gather(self, GpuArray src not None, GpuArray dest=None,
                   unsigned int nd_up=1):
        """AllGather collective operation for ranks in a communicator world.

        Parameters
        ----------
        src: :ref:`GpuArray`
            Array to be gathered.
        dest: :ref:`GpuArray`, optional
            Array to receive all gathered arrays from ranks in `GpuComm`.
        nd_up: unsigned int
            Used when creating result array. Indicates how many extra dimensions
            user wants result to have. Default is 1, which means that the result
            will store each rank's gathered array in one extra new dimension.

        Notes
        -----
        * Providing `nd_up` == 0 means that gathered arrays will be appended to
        the dimension with the largest stride.

        """
        if dest is None:
            return pygpu_make_all_gathered(self, src, nd_up)
        return comm_all_gather(self, src, dest)


cdef dict TO_RED_OP = {
    '+': GA_SUM,
    "sum": GA_SUM,
    "add": GA_SUM,
    '*': GA_PROD,
    "prod": GA_PROD,
    "product": GA_PROD,
    "max": GA_MAX,
    "maximum": GA_MAX,
    "min": GA_MIN,
    "minimum": GA_MIN,
    }

cdef int to_reduce_opcode(op) except -1:
    res = TO_RED_OP.get(op.lower())
    if res is not None:
        return res
    raise ValueError, "Invalid reduce operation: %s" % (str(op))

cdef gpucontext* comm_context(GpuComm comm) except NULL:
    cdef gpucontext* res
    res = gpucomm_context(comm.c)
    if res is NULL:
        raise GpuArrayException, "Invalid communicator or destroyed context"
    return res

cdef int comm_generate_id(gpucontext* ctx, GpuCommCliqueId comm_id) except -1:
    cdef int err
    err = gpucomm_gen_clique_id(ctx, &comm_id.comm_id)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(ctx, err)

cdef int comm_get_count(GpuComm comm, int* gpucount) except -1:
    cdef int err
    err = gpucomm_get_count(comm.c, gpucount)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_get_rank(GpuComm comm, int* gpurank) except -1:
    cdef int err
    err = gpucomm_get_count(comm.c, gpurank)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_reduce_from(GpuComm comm, GpuArray src, int opcode,
                          int root) except -1:
    cdef int err
    err = GpuArray_reduce_from(&src.ga, opcode, root, comm.c)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_reduce(GpuComm comm, GpuArray src, GpuArray dest, int opcode,
                     int root) except -1:
    cdef int err
    err = GpuArray_reduce(&src.ga, &dest.ga, opcode, root, comm.c)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_all_reduce(GpuComm comm, GpuArray src, GpuArray dest,
                         int opcode) except -1:
    cdef int err
    err = GpuArray_all_reduce(&src.ga, &dest.ga, opcode, comm.c)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_reduce_scatter(GpuComm comm, GpuArray src, GpuArray dest,
                             int opcode) except -1:
    cdef int err
    err = GpuArray_reduce_scatter(&src.ga, &dest.ga, opcode, comm.c)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_broadcast(GpuComm comm, GpuArray arr, int root) except -1:
    cdef int err
    err = GpuArray_broadcast(&arr.ga, root, comm.c)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef int comm_all_gather(GpuComm comm, GpuArray src, GpuArray dest) except -1:
    cdef int err
    err = GpuArray_all_gather(&src.ga, &dest.ga, comm.c)
    if err != GA_NO_ERROR:
        raise get_exc(err), gpucontext_error(comm_context(comm), err)

cdef api GpuArray pygpu_make_reduced(GpuComm comm, GpuArray src, int opcode):
    cdef GpuArray res
    res = pygpu_empty_like(src, GA_ANY_ORDER, -1)
    cdef int rank
    comm_get_rank(comm, &rank)
    comm_reduce(comm, src, res, opcode, rank)
    return res

cdef api GpuArray pygpu_make_all_reduced(GpuComm comm, GpuArray src, int opcode):
    cdef GpuArray res
    res = pygpu_empty_like(src, GA_ANY_ORDER, -1)
    comm_all_reduce(comm, src, res, opcode)
    return res

cdef api GpuArray pygpu_make_reduce_scattered(GpuComm comm, GpuArray src, int opcode):
    if src.ga.nd < 1:
        raise TypeError, "Source GpuArray must have number of dimensions >= 1"

    cdef GpuArray res
    cdef int gpucount
    cdef bint is_c_cont
    cdef unsigned int nd
    cdef size_t chosen_dim_size
    cdef size_t* dims
    cdef unsigned int j

    comm_get_count(comm, &gpucount)
    is_c_cont = GpuArray_IS_C_CONTIGUOUS(&src.ga)
    nd = src.ga.nd
    dims = <size_t*>calloc(nd, sizeof(size_t))
    if dims == NULL:
        raise MemoryError, "Could not allocate dims"

    try:
        if is_c_cont:
            # Smallest in index dimension has the largest stride
            if src.ga.dimensions[0] % gpucount == 0:
                chosen_dim_size = src.ga.dimensions[0] / gpucount
                if chosen_dim_size != 1:
                    dims[0] = chosen_dim_size
                    for j in range(1, nd):
                        dims[j] = src.ga.dimensions[j]
                else:
                    for j in range(nd - 1):
                        dims[j] = src.ga.dimensions[1 + j]
                    nd -= 1
            else:
                raise TypeError, "Source GpuArray cannot be split in %d c-contiguous arrays" % (gpucount)
        else:
            # Largest in index dimension has the largest stride
            if src.ga.dimensions[nd - 1] % gpucount == 0:
                chosen_dim_size = src.ga.dimensions[nd - 1] / gpucount
                for j in range(nd - 1):
                    dims[j] = src.ga.dimensions[j]
                if chosen_dim_size != 1:
                    dims[nd - 1] = chosen_dim_size
                else:
                    nd -= 1
            else:
                raise TypeError, "Source GpuArray cannot be split in %d c-contiguous arrays" % (gpucount)
        res = pygpu_empty(nd, dims, src.ga.typecode,
                          GA_C_ORDER if is_c_cont else GA_F_ORDER,
                          src.context, type(src))
        comm_reduce_scatter(comm, src, res, opcode)
    finally:
        free(dims)

    return res

cdef api GpuArray pygpu_make_all_gathered(GpuComm comm, GpuArray src,
                                          unsigned int nd_up):
    if src.ga.nd < 1:
        raise TypeError, "Source GpuArray must have number of dimensions >= 1"

    cdef GpuArray res
    cdef int gpucount
    cdef bint is_c_cont
    cdef unsigned int nd
    cdef size_t* dims
    cdef unsigned int j

    comm_get_count(comm, &gpucount)
    is_c_cont = GpuArray_IS_C_CONTIGUOUS(&src.ga)
    nd = src.ga.nd + nd_up
    dims = <size_t*>calloc(nd, sizeof(size_t))
    if dims == NULL:
        raise MemoryError, "Could not allocate dims"

    try:
        if is_c_cont:
            # Smallest in index dimension has the largest stride
            if nd_up == 0:
                dims[0] = <size_t>gpucount * src.ga.dimensions[0]
                for j in range(1, nd):
                    dims[j] = src.ga.dimensions[j]
            else:
                dims[0] = <size_t>gpucount
                for j in range(1, nd_up):
                    dims[j] = 1
                for j in range(src.ga.nd):
                    dims[nd_up + j] = src.ga.dimensions[j]
        else:
            # Largest in index dimension has the largest stride
            if nd_up == 0:
                dims[nd - 1] = <size_t>gpucount * src.ga.dimensions[nd - 1]
                for j in range(nd - 1):
                    dims[j] = src.ga.dimensions[j]
            else:
                dims[nd - 1] = <size_t>gpucount
                for j in range(nd_up - 1):
                    dims[src.ga.nd + j] = 1
                for j in range(src.ga.nd):
                    dims[j] = src.ga.dimensions[j]
        res = pygpu_empty(nd, dims, src.ga.typecode,
                          GA_C_ORDER if is_c_cont else GA_F_ORDER,
                          src.context, type(src))
        comm_all_gather(comm, src, res)
    finally:
        free(dims)

    return res
