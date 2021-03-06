"""
Binding for libsvm[1]
---------------------
We do not use the binding that ships with libsvm because we need to
access svm_model.sv_coeff (and other fields), but libsvm does not
provide an accessor. Our solution is to export svm_model and access it
manually, this is done un function see svm_train_wrap.

Low-level memory management is done in libsvm_helper.c. If we happen
to run out of memory a MemoryError will be raised. In practice this is
not very helpful since hight changes are malloc fails inside svm.cpp,
where no sort of memory checks are done.

These are low-level routines, not meant to be used directly. See
scikits.learn.svm for a higher-level API.

[1] http://www.csie.ntu.edu.tw/~cjlin/libsvm/

Notes
-----
Maybe we could speed it a bit further by decorating functions with
@cython.boundscheck(False), but probably it is not worth since all
work is done in lisvm_helper.c
Also, the signature mode='c' is somewhat superficial, since we already
check that arrays are C-contiguous in svm.py

Authors
-------
2010: Fabian Pedregosa <fabian.pedregosa@inria.fr>
      Gael Varoquaux <gael.varoquaux@normalesup.org>
"""

import  numpy as np
cimport numpy as np

################################################################################
# Includes

cdef extern from "svm.h":
    cdef struct svm_node
    cdef struct svm_model
    cdef struct svm_parameter
    cdef struct svm_problem
    char *svm_check_parameter(svm_problem *, svm_parameter *)
    svm_model *svm_train(svm_problem *, svm_parameter *)


cdef extern from "libsvm_helper.c":
    # this file contains methods for accessing libsvm 'hidden' fields
    svm_node **dense_to_sparse (char *, np.npy_intp *)
    svm_parameter *set_parameter (int , int , int , double, double ,
                                  double , double , double , double,
                                  double, int, int, int, char *, char *)
    svm_problem * set_problem (char *, char *, np.npy_intp *, int)

    svm_model *set_model (svm_parameter *, int, char *, np.npy_intp *,
                         char *, np.npy_intp *, np.npy_intp *, char *,
                         char *, char *, char *, char *, char *)

    void copy_sv_coef   (char *, svm_model *)
    void copy_intercept (char *, svm_model *, np.npy_intp *)
    void copy_SV        (char *, svm_model *, np.npy_intp *)
    int copy_support (char *data, svm_model *model)
    int copy_predict (char *, svm_model *, np.npy_intp *, char *)
    int copy_predict_proba (char *, svm_model *, np.npy_intp *, char *)
    int copy_predict_values(char *, svm_model *, np.npy_intp *, char *, int)
    np.npy_intp get_nonzero_SV ( svm_model *)
    void copy_nSV     (char *, svm_model *)
    void copy_label   (char *, svm_model *)
    void copy_probA   (char *, svm_model *, np.npy_intp *)
    void copy_probB   (char *, svm_model *, np.npy_intp *)
    np.npy_intp  get_l  (svm_model *)
    np.npy_intp  get_nr (svm_model *)
    int  free_problem   (svm_problem *)
    int  free_model     (svm_model *)
    int  free_param     (svm_parameter *)
    void svm_free_and_destroy_model(svm_model** model_ptr_ptr)    
    void set_verbosity(int)

################################################################################
# Wrapper functions

def libsvm_train (np.ndarray[np.float64_t, ndim=2, mode='c'] X, 
                  np.ndarray[np.float64_t, ndim=1, mode='c'] Y,
                  int svm_type, int kernel_type, int degree, double gamma,
                  double coef0, double eps, double C, 
                  np.ndarray[np.float64_t, ndim=2, mode='c'] sv_coef,
                  np.ndarray[np.float64_t, ndim=1, mode='c'] intercept,
                  np.ndarray[np.int32_t,   ndim=1, mode='c'] weight_label,
                  np.ndarray[np.float64_t, ndim=1, mode='c'] weight,
                  np.ndarray[np.int32_t,   ndim=1, mode='c'] nclass_SV,
                  double nu, double cache_size, double p,
                  int shrinking, int probability):
    """
    Train the model

    Parameters
    ----------
    X: array-like, dtype=float, size=[n_samples, n_features]

    Y: array, dtype=float, size=[n_samples]
        target vector

    svm_type : {0, 1, 2, 3, 4}
        Type of SVM: C SVC, nu SVC, one class, epsilon SVR, nu SVR

    kernel_type : {0, 1, 2, 3, 4}
        Kernel to use in the model: linear, polynomial, RBF, sigmoid
        or precomputed.

    degree : int
        Degree of the polynomial kernel (only relevant if kernel is
        set to polynomial)

    gamma : float
        Gamma parameter in RBF kernel (only relevant if kernel is set
        to RBF)

    coef0 : float
        Independent parameter in poly/sigmoid kernel.

    eps : float
        Stopping criteria.

    Return
    ------
    support : index of support vectors
    support_vectors : support vectors
    label : labels for different classes (only relevant in classification).
    probA : probability estimates
    probB : probability estimates

    TODO: put default values when possible
    """

    cdef svm_parameter *param
    cdef svm_problem *problem
    cdef svm_model *model
    cdef char *error_msg

    # set libsvm problem
    problem = set_problem(X.data, Y.data, X.shape, kernel_type)

    # set parameters
    param = set_parameter(svm_type, kernel_type, degree, gamma,
                          coef0, nu, cache_size,
                          C, eps, p, shrinking, probability,
                          <int> weight.shape[0], weight_label.data, weight.data)

    # check parameters
    if (param == NULL or problem == NULL):
        raise MemoryError("Seems we've run out of of memory")
    error_msg = svm_check_parameter(problem, param);
    if error_msg:
        free_problem(problem)
        free_param(param)
        raise ValueError(error_msg)

    # call svm_train, this does the real work
    model = svm_train(problem, param)

    # from here until the end, we just copy the data returned by
    # svm_train
    cdef np.npy_intp SV_len = get_l(model)
    cdef np.npy_intp nr     = get_nr(model)

    # copy model.sv_coef
    # we create a new array instead of resizing, otherwise
    # it would not erase previous information
    sv_coef.resize ((nr-1, SV_len), refcheck=False)
    copy_sv_coef (sv_coef.data, model)

    # copy model.rho into the intercept
    # the intercept is just model.rho but with sign changed
    intercept.resize (nr*(nr-1)/2, refcheck=False)
    copy_intercept (intercept.data, model, intercept.shape)

    cdef np.ndarray[np.int32_t, ndim=1, mode='c'] support
    support = np.empty (SV_len, dtype=np.int32)
    copy_support (support.data, model)

    # copy model.SV
    cdef np.ndarray[np.float64_t, ndim=2, mode='c'] support_vectors
    if kernel_type == 4:
        support_vectors = np.empty((0, 0), dtype=np.float64)
    else:
        support_vectors = np.empty((SV_len, X.shape[1]), dtype=np.float64)
        copy_SV(support_vectors.data, model, support_vectors.shape)

    # copy model.nSV
    # TODO: do only in classification
    nclass_SV.resize(nr, refcheck=False)
    copy_nSV(nclass_SV.data, model)

    # copy label
    cdef np.ndarray[np.int32_t, ndim=1, mode='c'] label
    label = np.empty((nr), dtype=np.int32)
    copy_label(label.data, model)

    # copy probabilities
    cdef np.ndarray[np.float64_t, ndim=1, mode='c'] probA
    cdef np.ndarray[np.float64_t, ndim=1, mode='c'] probB
    if probability != 0:
        # this is only valid for SVC
        probA = np.empty(nr*(nr-1)/2, dtype=np.float64)
        probB = np.empty(nr*(nr-1)/2, dtype=np.float64)
        copy_probA(probA.data, model, probA.shape)
        copy_probB(probB.data, model, probB.shape)

    svm_free_and_destroy_model(&model)
    free_problem(problem)
    free_param(param)

    return support, support_vectors, label, probA, probB


def libsvm_predict (np.ndarray[np.float64_t, ndim=2, mode='c'] T,
                            np.ndarray[np.float64_t, ndim=2, mode='c'] SV,
                            np.ndarray[np.float64_t, ndim=2, mode='c'] sv_coef,
                            np.ndarray[np.float64_t, ndim=1, mode='c']
                            intercept, int svm_type, int kernel_type, int
                            degree, double gamma, double coef0, double
                            eps, double C, 
                            np.ndarray[np.int32_t, ndim=1] weight_label,
                            np.ndarray[np.float64_t, ndim=1] weight,
                            double nu, double cache_size, double p, int
                            shrinking, int probability,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] nSV,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] support,                    
                            np.ndarray[np.int32_t, ndim=1, mode='c'] label,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probA,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probB):
    """
    Predict values T given a model.

    For speed, all real work is done at the C level in function
    copy_predict (libsvm_helper.c).

    We have to reconstruct model and parameters to make sure we stay
    in sync with the python object.

    Parameters
    ----------
    X: array-like, dtype=float
    Y: array
        target vector

    Optional Parameters
    -------------------
    See scikits.learn.svm.predict for a complete list of parameters.

    Return
    ------
    dec_values : array
        predicted values.
    """
    cdef np.ndarray[np.float64_t, ndim=1, mode='c'] dec_values
    cdef svm_parameter *param
    cdef svm_model *model
    param = set_parameter(svm_type, kernel_type, degree, gamma,
                          coef0, nu, cache_size, C, eps, p, shrinking,
                          probability, <int> weight.shape[0], weight_label.data,
                          weight.data)

    model = set_model(param, <int> nSV.shape[0], SV.data, SV.shape,
                      support.data, support.shape, sv_coef.strides,
                      sv_coef.data, intercept.data, nSV.data,
                      label.data, probA.data, probB.data)
    
    #TODO: use check_model
    dec_values = np.empty(T.shape[0])
    if copy_predict(T.data, model, T.shape, dec_values.data) < 0:
        raise MemoryError("We've run out of of memory")
    free_model(model)
    free_param(param)
    return dec_values



def libsvm_predict_proba (np.ndarray[np.float64_t, ndim=2, mode='c'] T,
                            np.ndarray[np.float64_t, ndim=2, mode='c'] SV,
                            np.ndarray[np.float64_t, ndim=2, mode='c'] sv_coef,
                            np.ndarray[np.float64_t, ndim=1, mode='c']
                            intercept, int svm_type, int kernel_type, int
                            degree, double gamma, double coef0, double
                            eps, double C, 
                            np.ndarray[np.int32_t, ndim=1] weight_label,
                            np.ndarray[np.float_t, ndim=1] weight,
                            double nu, double cache_size, double p, int
                            shrinking, int probability,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] nSV,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] support,                          
                            np.ndarray[np.int32_t, ndim=1, mode='c'] label,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probA,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probB):
    """
    Predict probabilities

    svm_model stores all parameters needed to predict a given value.

    For speed, all real work is done at the C level in function
    copy_predict (libsvm_helper.c).

    We have to reconstruct model and parameters to make sure we stay
    in sync with the python object.

    Parameters
    ----------
    X: array-like, dtype=float
    Y: array
        target vector

    Optional Parameters
    -------------------
    See scikits.learn.svm.predict for a complete list of parameters.

    Return
    ------
    dec_values : array
        predicted values.
    """
    cdef np.ndarray[np.float64_t, ndim=2, mode='c'] dec_values
    cdef svm_parameter *param
    cdef svm_model *model
    param = set_parameter(svm_type, kernel_type, degree, gamma,
                          coef0, nu, cache_size, C, eps, p, shrinking,
                          probability, <int> weight.shape[0], weight_label.data,
                          weight.data)

    model = set_model(param, <int> nSV.shape[0], SV.data, SV.shape,
                      support.data, support.shape, sv_coef.strides,
                      sv_coef.data, intercept.data, nSV.data,
                      label.data, probA.data, probB.data)

    cdef np.npy_intp nr = get_nr(model)    
    dec_values = np.empty((T.shape[0], nr), dtype=np.float64)
    if copy_predict_proba(T.data, model, T.shape, dec_values.data) < 0:
        raise MemoryError("We've run out of of memory")
    # free model and param
    free_model(model)
    free_param(param)
    return dec_values


def libsvm_decision_function (np.ndarray[np.float64_t, ndim=2, mode='c'] T,
                            np.ndarray[np.float64_t, ndim=2, mode='c'] SV,
                            np.ndarray[np.float64_t, ndim=2, mode='c'] sv_coef,
                            np.ndarray[np.float64_t, ndim=1, mode='c']
                            intercept, int svm_type, int kernel_type, int
                            degree, double gamma, double coef0, double
                            eps, double C, 
                            np.ndarray[np.int32_t, ndim=1] weight_label,
                            np.ndarray[np.float_t, ndim=1] weight,
                            double nu, double cache_size, double p, int
                            shrinking, int probability,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] nSV,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] support,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] label,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probA,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probB):
    """
    Predict margin (libsvm name for this is predict_values)

    We have to reconstruct model and parameters to make sure we stay
    in sync with the python object.
    """
    cdef np.ndarray[np.float64_t, ndim=2, mode='c'] dec_values
    cdef svm_parameter *param
    cdef svm_model *model
    cdef np.npy_intp nr

    param = set_parameter(svm_type, kernel_type, degree, gamma,
                          coef0, nu, cache_size, C, eps, p, shrinking,
                          probability, <int> weight.shape[0], weight_label.data,
                          weight.data)

    model = set_model(param, <int> nSV.shape[0], SV.data, SV.shape,
                      support.data, support.shape, sv_coef.strides,
                      sv_coef.data, intercept.data, nSV.data,
                      label.data, probA.data, probB.data)

    if svm_type > 1:
        nr = 1
    else:
        nr = get_nr(model)
        nr = nr * (nr - 1) / 2
    
    dec_values = np.empty((T.shape[0], nr), dtype=np.float64)
    if copy_predict_values(T.data, model, T.shape, dec_values.data, nr) < 0:
        raise MemoryError("We've run out of of memory")
    # free model and param
    free_model(model)
    free_param(param)
    return dec_values

def set_verbosity_wrap(int verbosity):
    """
    Control verbosity of libsvm library
    """
    set_verbosity(verbosity)
