/*
 * MD_CUDABackend.cpp
 *
 *  Created on: 03/set/2010
 *      Author: lorenzo
 */

#include "MD_CUDABackend.h"

#include "CUDA_MD.cuh"
#include "../CUDA_base_interactions.h"
#include "../../Interactions/DNAInteraction.h"
#include "../../Observables/ObservableOutput.h"
#include "../Thermostats/CUDAThermostatFactory.h"

#include "../../Forces/COMForce.h"
#include "../../Forces/ConstantRateForce.h"
#include "../../Forces/ConstantRateTorque.h"
#include "../../Forces/ConstantTrap.h"
#include "../../Forces/LowdimMovingTrap.h"
#include "../../Forces/MovingTrap.h"
#include "../../Forces/MutualTrap.h"
#include "../../Forces/RepulsionPlane.h"
#include "../../Forces/RepulsionPlaneMoving.h"
#include "../../Forces/RepulsiveSphere.h"
#include "../../Forces/RepulsiveSphereSmooth.h"
#include "../../Forces/LJWall.h"
#include "../../Forces/GenericCentralForce.h"
#include "../../Forces/LJCone.h"

#include <thrust/sort.h>
#include <typeinfo>

// these pragma instructions remove a few nvcc warnings
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wvla"

MD_CUDABackend::MD_CUDABackend() : MDBackend(), CUDABaseBackend(), _max_ext_forces(0), _error_conf_file("error_conf.dat") {
	this->_is_CUDA_sim = true;
	_use_edge = false;
	_any_rigid_body = false;

	_d_vels = _d_Ls = _d_forces = _d_torques = _d_buff_vels = NULL;
	_h_vels = _h_Ls = _h_forces = _h_torques = _d_buff_Ls = NULL;
	_h_gpu_index = _h_cpu_index = NULL;

	_cuda_thermostat = NULL;

	_h_ext_forces = NULL;
	_d_ext_forces = NULL;

	_restart_step_counter = false;
	_avoid_cpu_calculations = false;

	_timer_sorting = NULL;

	_curr_step = -1;
	_barostat_attempts = _barostat_accepted = 0;

	_print_energy = false;

	_obs_output_error_conf = NULL;
}

MD_CUDABackend::~MD_CUDABackend() {
	if(_d_vels != NULL) {
		CUDA_SAFE_CALL( cudaFree(_d_vels) );
		CUDA_SAFE_CALL( cudaFree(_d_Ls) );
		CUDA_SAFE_CALL( cudaFree(_d_forces) );
		CUDA_SAFE_CALL( cudaFree(_d_torques) );
	}

	if(this->_sort_every > 0 && _d_buff_vels != NULL) {
		CUDA_SAFE_CALL( cudaFree(_d_buff_vels) );
		CUDA_SAFE_CALL( cudaFree(_d_buff_Ls) );
	}

	if(_h_gpu_index != NULL) {
		delete[] _h_gpu_index;
		delete[] _h_cpu_index;
	}

	if(this->_external_forces) {
		if(_h_ext_forces != NULL)
			delete[] _h_ext_forces;
		if(_d_ext_forces != NULL)
			CUDA_SAFE_CALL( cudaFree(_d_ext_forces) );
	}

	if(_h_vels != NULL) {
		delete[] _h_vels;
		delete[] _h_Ls;
		delete[] _h_forces;
		delete[] _h_torques;
	}

	if(_cuda_thermostat != NULL) delete _cuda_thermostat;

	if(_obs_output_error_conf != NULL) delete _obs_output_error_conf;
}

void MD_CUDABackend::_host_to_gpu() {
	CUDABaseBackend::_host_to_gpu();
	CUDA_SAFE_CALL( cudaMemcpy(_d_vels, _h_vels, this->_vec_size, cudaMemcpyHostToDevice) );
	CUDA_SAFE_CALL( cudaMemcpy(_d_Ls, _h_Ls, this->_vec_size, cudaMemcpyHostToDevice) );
}

void MD_CUDABackend::_gpu_to_host() {
	CUDABaseBackend::_gpu_to_host();
	CUDA_SAFE_CALL( cudaMemcpy(_h_vels, _d_vels, this->_vec_size, cudaMemcpyDeviceToHost) );
	CUDA_SAFE_CALL( cudaMemcpy(_h_Ls, _d_Ls, this->_vec_size, cudaMemcpyDeviceToHost) );
	CUDA_SAFE_CALL( cudaMemcpy(_h_forces, _d_forces, this->_vec_size, cudaMemcpyDeviceToHost) );
	CUDA_SAFE_CALL( cudaMemcpy(_h_torques, _d_torques, this->_vec_size, cudaMemcpyDeviceToHost) );
}

void MD_CUDABackend::_host_particles_to_gpu() {
	for(int i = 0; i < N(); i++) {
		int gpu_index = _h_gpu_index[i];
		BaseParticle *p = this->_particles[gpu_index];

		this->_h_poss[i].x = p->pos.x;
		this->_h_poss[i].y = p->pos.y;
		this->_h_poss[i].z = p->pos.z;

		// convert index and type into a float
		int msk = -1 << 22;// bynary mask: all 1's and 22 0's;
		// btype has a sign, and thus has to go first
		this->_h_poss[i].w = GpuUtils::int_as_float( (p->btype << 22) | ((~msk) & p->index) );
		// we immediately check that the index and base type that we read are sensible
		int mybtype = (GpuUtils::float_as_int(this->_h_poss[i].w)) >> 22;
		int myindex = (GpuUtils::float_as_int(this->_h_poss[i].w)) & (~msk);
		if (p->btype != mybtype) {
			throw oxDNAException ("Could not treat the type (A, C, G, T or something specific) of particle %d; On CUDA, the maximum \"unique\" identity is 512");
		}
		if (p->index != myindex) {
			throw oxDNAException ("Could not treat the index of particle %d; remember that on CUDA the maximum c_number of particles is 2^21", p->index);
		}

		if (p->n3 == P_VIRTUAL) this->_h_bonds[i].n3 = P_INVALID;
		else this->_h_bonds[i].n3 = _h_cpu_index[p->n3->index];
		if (p->n5 == P_VIRTUAL) this->_h_bonds[i].n5 = P_INVALID;
		else this->_h_bonds[i].n5 = _h_cpu_index[p->n5->index];

		_h_vels[i].x = p->vel.x;
		_h_vels[i].y = p->vel.y;
		_h_vels[i].z = p->vel.z;

		_h_Ls[i].x = p->L.x;
		_h_Ls[i].y = p->L.y;
		_h_Ls[i].z = p->L.z;
	
		c_number trace = p->orientation.v1.x+p->orientation.v2.y+p->orientation.v3.z;
		if(trace > 0) {
			c_number s = .5/sqrt(trace + 1);
			this->_h_orientations[i].w = .25/s;
			this->_h_orientations[i].x = (p->orientation.v3.y-p->orientation.v2.z)*s;
			this->_h_orientations[i].y = (p->orientation.v1.z-p->orientation.v3.x)*s;
			this->_h_orientations[i].z = (p->orientation.v2.x-p->orientation.v1.y)*s;
		}
		else {    //Finding largest diagonal element
			if ( (p->orientation.v1.x > p->orientation.v2.y) && (p->orientation.v1.x > p->orientation.v3.z) ) { 
				c_number s = .5/sqrt(1+p->orientation.v1.x-p->orientation.v2.y-p->orientation.v3.z);
				this->_h_orientations[i].w = (p->orientation.v3.y-p->orientation.v2.z)*s;
				this->_h_orientations[i].x = .25/s;
				this->_h_orientations[i].y = (p->orientation.v1.y+p->orientation.v2.x)*s;
				this->_h_orientations[i].z = (p->orientation.v1.z+p->orientation.v3.x)*s;
			}
			else if (p->orientation.v2.y > p->orientation.v3.z) {
				c_number s = .5/sqrt(1+p->orientation.v2.y-p->orientation.v1.x-p->orientation.v3.z);
				this->_h_orientations[i].w = (p->orientation.v1.z-p->orientation.v3.x)*s;
				this->_h_orientations[i].x = (p->orientation.v1.y+p->orientation.v2.x)*s;
				this->_h_orientations[i].y = .25/s;
				this->_h_orientations[i].z = (p->orientation.v2.z+p->orientation.v3.y)*s;
			}
			else {
				c_number s = .5/sqrt(1+p->orientation.v3.z-p->orientation.v1.x-p->orientation.v2.y);
				this->_h_orientations[i].w = (p->orientation.v2.x-p->orientation.v1.y)*s;
				this->_h_orientations[i].x = (p->orientation.v1.z+p->orientation.v3.x)*s;
				this->_h_orientations[i].y = (p->orientation.v2.z+p->orientation.v3.y)*s;
				this->_h_orientations[i].z = .25/s;
			}
		}
	} 
	this->_host_to_gpu();
}

void MD_CUDABackend::_gpu_to_host_particles() {
	this->_gpu_to_host();

	for(int i = 0; i < N(); i++) {
		// since we may have been sorted all the particles in a different order
		// we first take the particle index from the 4th component of its
		// position, and then use that index to access the right BaseParticle pointer
		int msk = (-1 << 22);
		int newindex = ((GpuUtils::float_as_int(this->_h_poss[i].w)) & (~msk));
		_h_gpu_index[i] = newindex;
		_h_cpu_index[newindex] = i;
		BaseParticle *p = this->_particles[newindex];
		assert(p->index == newindex);

		p->pos.x = this->_h_poss[i].x;
		p->pos.y = this->_h_poss[i].y;
		p->pos.z = this->_h_poss[i].z;
		// get index and type for the fourth component of the position
		p->btype = (GpuUtils::float_as_int(this->_h_poss[i].w)) >> 22;

		if (this->_h_bonds[i].n3 == P_INVALID) p->n3 = P_VIRTUAL;
		else {
			int n3index = ((GpuUtils::float_as_int(this->_h_poss[this->_h_bonds[i].n3].w)) & (~msk));
			p->n3 = this->_particles[n3index];
		}
		if (this->_h_bonds[i].n5 == P_INVALID) p->n5 = P_VIRTUAL;
		else {
			int n5index = ((GpuUtils::float_as_int(this->_h_poss[this->_h_bonds[i].n5].w)) & (~msk));
			p->n5 = this->_particles[n5index];
		}

		p->vel.x = _h_vels[i].x;
		p->vel.y = _h_vels[i].y;
		p->vel.z = _h_vels[i].z;

		p->L.x = _h_Ls[i].x;
		p->L.y = _h_Ls[i].y;
		p->L.z = _h_Ls[i].z;

		c_number sqx = this->_h_orientations[i].x*this->_h_orientations[i].x;
		c_number sqy = this->_h_orientations[i].y*this->_h_orientations[i].y;
		c_number sqz = this->_h_orientations[i].z*this->_h_orientations[i].z;
		c_number sqw = this->_h_orientations[i].w*this->_h_orientations[i].w;
		c_number xy = this->_h_orientations[i].x*this->_h_orientations[i].y;
		c_number xz = this->_h_orientations[i].x*this->_h_orientations[i].z;
		c_number xw = this->_h_orientations[i].x*this->_h_orientations[i].w;
		c_number yz = this->_h_orientations[i].y*this->_h_orientations[i].z;
		c_number yw = this->_h_orientations[i].y*this->_h_orientations[i].w;
		c_number zw = this->_h_orientations[i].z*this->_h_orientations[i].w;
		c_number invs = 1 / (sqx + sqy + sqz + sqw);

		p->orientation.v1.x = (sqx-sqy-sqz+sqw)*invs;
		p->orientation.v1.y = 2*(xy-zw)*invs;
		p->orientation.v1.z = 2*(xz+yw)*invs;
		p->orientation.v2.x = 2*(xy+zw)*invs;
		p->orientation.v2.y = (-sqx+sqy-sqz+sqw)*invs;
		p->orientation.v2.z = 2*(yz-xw)*invs;
		p->orientation.v3.x = 2*(xz-yw)*invs;
		p->orientation.v3.y = 2*(yz+xw)*invs;
		p->orientation.v3.z = (-sqx-sqy+sqz+sqw)*invs;

		p->orientationT = p->orientation.get_transpose();
		p->set_positions();
	}
}

void MD_CUDABackend::_init_CUDA_MD_symbols() {
	float f_copy = this->_sqr_verlet_skin;
	CUDA_SAFE_CALL( cudaMemcpyToSymbol(MD_sqr_verlet_skin, &f_copy, sizeof(float)) );
	f_copy = this->_dt;
	CUDA_SAFE_CALL( cudaMemcpyToSymbol(MD_dt, &f_copy, sizeof(float)) );
	int myN = N();
	CUDA_SAFE_CALL( cudaMemcpyToSymbol(MD_N, &myN, sizeof(int)) );
}

void MD_CUDABackend::_first_step() {
	first_step
		<<<this->_particles_kernel_cfg.blocks, this->_particles_kernel_cfg.threads_per_block>>>
		(this->_d_poss, this->_d_orientations, this->_d_list_poss, _d_vels, _d_Ls, _d_forces, _d_torques, this->_d_are_lists_old);
	CUT_CHECK_ERROR("_first_step error");
}

void MD_CUDABackend::_rescale_positions(c_number4 new_Ls, c_number4 old_Ls) {
	c_number4 ratio = {new_Ls.x/old_Ls.x, new_Ls.y/old_Ls.y, new_Ls.z/old_Ls.z, 0.};
	rescale_positions
		<<<this->_particles_kernel_cfg.blocks, this->_particles_kernel_cfg.threads_per_block>>>
		(this->_d_poss, ratio);
	CUT_CHECK_ERROR("_rescale_positions error");
}

void MD_CUDABackend::_apply_barostat(llint curr_step) {
	_barostat_attempts++;

	_set_external_forces();
	this->_cuda_interaction->compute_forces(this->_cuda_lists, this->_d_poss, this->_d_orientations, _d_forces, _d_torques, this->_d_bonds, this->_d_cuda_box);
	double old_energy = GpuUtils::sum_c_number4_to_double_on_GPU(this->_d_forces, N())/2.;
	c_number old_V = this->_h_cuda_box.V();
	c_number4 old_Ls = this->_h_cuda_box.box_sides();

	c_number4 new_Ls = old_Ls;
	if(this->_barostat_isotropic) {
		c_number dL = this->_delta_L*(drand48() - (c_number)0.5);
		new_Ls.x += dL;
		new_Ls.y += dL;
		new_Ls.z += dL;
		/*c_number newL = powf(expf(logf(old_V) + this->_delta_L*(drand48() - (c_number) 0.5)), 1./3.);
		  new_Ls.x = new_Ls.y = new_Ls.z = newL;*/
	}
	else {
		new_Ls.x += this->_delta_L*(drand48() - (c_number)0.5);
		new_Ls.y += this->_delta_L*(drand48() - (c_number)0.5);
		new_Ls.z += this->_delta_L*(drand48() - (c_number)0.5);
	}
	this->_h_cuda_box.change_sides(new_Ls.x, new_Ls.y, new_Ls.z);
	CUDA_SAFE_CALL( cudaMemcpy(this->_d_cuda_box, &this->_h_cuda_box, sizeof(CUDABox), cudaMemcpyHostToDevice) );
	_rescale_positions(new_Ls, old_Ls);
	this->_cuda_lists->update(this->_d_poss, this->_d_list_poss, this->_d_bonds);

	_set_external_forces();
	this->_cuda_interaction->compute_forces(this->_cuda_lists, this->_d_poss, this->_d_orientations, _d_forces, _d_torques, this->_d_bonds, this->_d_cuda_box);
	double new_energy = GpuUtils::sum_c_number4_to_double_on_GPU(this->_d_forces, N())/2.;
	c_number new_V = this->_h_cuda_box.V();

	// acceptance
	c_number dE = new_energy - old_energy;
	c_number dV = new_V - old_V;
	c_number acc = exp(-(dE + this->_P*dV - (N() + 1)*this->_T*log(new_V/old_V))/this->_T);
	// accepted
	if(acc > drand48()) {
		//printf("B %lld %lf ---- %lf %lf %lf %lf\n", curr_step, new_energy/N(), dE, dV, acc, this->_P*dV);
		_barostat_accepted++;
	}
	// rejected
	else {
		this->_h_cuda_box.change_sides(old_Ls.x, old_Ls.y, old_Ls.z);
		CUDA_SAFE_CALL( cudaMemcpy(this->_d_cuda_box, &this->_h_cuda_box, sizeof(CUDABox), cudaMemcpyHostToDevice) );
		_rescale_positions(old_Ls, new_Ls);
		this->_cuda_lists->update(this->_d_poss, this->_d_list_poss, this->_d_bonds);
	}
	this->_barostat_acceptance = _barostat_accepted/(c_number)_barostat_attempts;
}

void MD_CUDABackend::_forces_second_step() {
	_set_external_forces();
	this->_cuda_interaction->compute_forces(this->_cuda_lists, this->_d_poss, this->_d_orientations, _d_forces, _d_torques, this->_d_bonds, this->_d_cuda_box);

	second_step
		<<<this->_particles_kernel_cfg.blocks, this->_particles_kernel_cfg.threads_per_block>>>
		(this->_d_vels, this->_d_Ls, this->_d_forces, this->_d_torques);
		CUT_CHECK_ERROR("second_step");
}

void MD_CUDABackend::_set_external_forces() {
	set_external_forces
		<<<this->_particles_kernel_cfg.blocks, this->_particles_kernel_cfg.threads_per_block>>>
		(this->_d_poss, this->_d_orientations, _d_ext_forces, _d_forces, _d_torques, _curr_step, _max_ext_forces, this->_d_cuda_box);
	CUT_CHECK_ERROR("set_external_forces");
}

void MD_CUDABackend::_sort_particles() {
	CUDABaseBackend::_sort_index();
	permute_particles
		<<<this->_particles_kernel_cfg.blocks, this->_particles_kernel_cfg.threads_per_block>>>
		(this->_d_sorted_hindex, this->_d_inv_sorted_hindex, this->_d_poss, _d_vels, _d_Ls, this->_d_orientations, this->_d_bonds, this->_d_buff_poss, _d_buff_vels, _d_buff_Ls, 				this->_d_buff_orientations, this->_d_buff_bonds);
		CUT_CHECK_ERROR("_permute_particles error");
		CUDA_SAFE_CALL( cudaMemcpy(this->_d_orientations, this->_d_buff_orientations, this->_orient_size, cudaMemcpyDeviceToDevice) );

	// copy back the sorted vectors
	CUDA_SAFE_CALL( cudaMemcpy(this->_d_poss, this->_d_buff_poss, this->_vec_size, cudaMemcpyDeviceToDevice) );
	CUDA_SAFE_CALL( cudaMemcpy(this->_d_bonds, this->_d_buff_bonds, this->_bonds_size, cudaMemcpyDeviceToDevice) );
	CUDA_SAFE_CALL( cudaMemcpy(_d_vels, _d_buff_vels, this->_vec_size, cudaMemcpyDeviceToDevice) );
	CUDA_SAFE_CALL( cudaMemcpy(_d_Ls, _d_buff_Ls, this->_vec_size, cudaMemcpyDeviceToDevice) );
}

void MD_CUDABackend::_thermalize(llint curr_step) {
	_cuda_thermostat->apply_cuda(this->_d_poss, this->_d_orientations, _d_vels, _d_Ls, curr_step);
}

void MD_CUDABackend::sim_step(llint curr_step) {
	this->_mytimer->resume();
	_curr_step = curr_step;

	this->_timer_first_step->resume();
	_first_step();
	cudaThreadSynchronize();
	this->_timer_first_step->pause();

	_timer_sorting->resume();
	if(this->_d_are_lists_old[0] && this->_sort_every > 0 && (this->_N_updates % this->_sort_every == 0)) {
		_sort_particles();
		cudaThreadSynchronize();
	}
	_timer_sorting->pause();

	this->_timer_lists->resume();
	if(this->_d_are_lists_old[0]) {
		try {
			this->_cuda_lists->update(this->_d_poss, this->_d_list_poss, this->_d_bonds);
		}
		catch (oxDNAException &e) {
			_gpu_to_host_particles();
			std::string filename("list_update_error.dat");
			_obs_output_error_conf->print_output(curr_step);
			OX_LOG(Logger::LOG_ERROR, "%s----> The last configuration has been printed to %s", e.error(), _error_conf_file.c_str());
			return;
		}
		this->_d_are_lists_old[0] = false;
		this->_N_updates++;
		cudaThreadSynchronize();
	}
	this->_timer_lists->pause();

	if(this->_is_barostat_active()) {
		this->_timer_barostat->resume();
		_apply_barostat(curr_step);
		this->_timer_barostat->pause();
	}

	this->_timer_forces->resume();
	_forces_second_step();
	if(_print_energy) {
		c_number energy = GpuUtils::sum_c_number4_to_double_on_GPU(_d_forces, N());
		this->_backend_info = Utils::sformat("\tCUDA_energy: %lf", energy / N());
	}
	cudaThreadSynchronize();
	this->_timer_forces->pause();

	this->_timer_thermostat->resume();
	_thermalize(curr_step);
	cudaThreadSynchronize();
	this->_timer_thermostat->pause();

	this->_mytimer->pause();
}

void MD_CUDABackend::get_settings(input_file &inp) {
	MDBackend::get_settings(inp);
	CUDABaseBackend::get_settings(inp);

	if(getInputBool(&inp, "use_edge", &_use_edge, 0) == KEY_FOUND) {
		if(_use_edge && sizeof(c_number) == sizeof(double)) throw oxDNAException("use_edge and double precision are not compatible");
		if(_use_edge && this->_use_barostat) throw oxDNAException("use_edge and use_barostat are not compatible");
	}
	
	getInputBool(&inp, "restart_step_counter", &_restart_step_counter, 1);
	getInputBool(&inp, "CUDA_avoid_cpu_calculations", &_avoid_cpu_calculations, 0);

	getInputBool(&inp, "CUDA_print_energy", &_print_energy, 0);

	_cuda_thermostat = CUDAThermostatFactory::make_thermostat(inp, _box.get());
	_cuda_thermostat->get_settings(inp);

	std::string init_string = Utils::sformat("{\n\tname = %s\n\tprint_every = 0\n\tonly_last = 1\n}\n", _error_conf_file.c_str());
	_obs_output_error_conf = new ObservableOutput(init_string);
	_obs_output_error_conf->add_observable("type = configuration");

	// if we want to limt the calculations done on CPU we clear the default ObservableOutputs and tell them to just print the timesteps (and, for constant-pressure, simulations, also the density)
	if(_avoid_cpu_calculations) {
		this->_obs_output_file->clear();
		this->_obs_output_file->add_observable("type = step\nunits = MD");
		if(this->_use_barostat) this->_obs_output_file->add_observable("type = density");

		bool no_stdout_energy = false;
		getInputBool(&inp, "no_stdout_energy", &no_stdout_energy, 0);
		if(!no_stdout_energy) {
			this->_obs_output_stdout->clear();
			this->_obs_output_stdout->add_observable("type = step");
			this->_obs_output_stdout->add_observable("type = step\nunits = MD");
			if(this->_use_barostat) this->_obs_output_stdout->add_observable("type = density");
		}
	}
}

void MD_CUDABackend::init() {
	MDBackend::init();
	CUDABaseBackend::init_cuda();

	_timer_sorting = TimingManager::instance()->new_timer(std::string("Hilbert sorting"), std::string("SimBackend"));

	CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<c_number4>(&_d_vels, this->_vec_size) );
	CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<c_number4>(&_d_Ls, this->_vec_size) );
	CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<c_number4>(&_d_forces, this->_vec_size) );
	CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<c_number4>(&_d_torques, this->_vec_size) );

	CUDA_SAFE_CALL( cudaMemset(_d_forces, 0, this->_vec_size) );
	CUDA_SAFE_CALL( cudaMemset(_d_torques, 0, this->_vec_size) );

	_h_vels = new c_number4[N()];
	_h_Ls = new c_number4[N()];
	_h_forces = new c_number4[N()];
	_h_torques = new c_number4[N()];

	_obs_output_error_conf->init(*this->_config_info);

	if(this->_external_forces) {
		if(this->_sort_every > 0) throw oxDNAException("External forces and CUDA_sort_every > 0 are not compatible");
		_h_ext_forces = new CUDA_trap[N() * MAX_EXT_FORCES];
		CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<CUDA_trap >(&_d_ext_forces, N() * MAX_EXT_FORCES * sizeof(CUDA_trap)) );

		for(int i = 0; i < N()*MAX_EXT_FORCES; i++) {
			_h_ext_forces[i].type = -1;
		}

		ConstantRateForce const_force;
		MutualTrap mutual_trap;
		MovingTrap moving_trap;
		LowdimMovingTrap lowdim_moving_trap;
		RepulsionPlane repulsion_plane;
		RepulsionPlaneMoving repulsion_plane_moving;
		RepulsiveSphere repulsive_sphere;
		RepulsiveSphereSmooth repulsive_sphere_smooth;
		LJWall LJ_wall;
		ConstantRateTorque const_rate_torque;
		GenericCentralForce generic_central;
		LJCone LJ_cone;

		for(int i = 0; i < N(); i++) {
			BaseParticle *p = this->_particles[i];

			for(uint j = 0; j < p->ext_forces.size(); j++) {
				_max_ext_forces = max(_max_ext_forces, (int) p->ext_forces.size());

				CUDA_trap *force = &(_h_ext_forces[j*N() + i]);
				if(typeid(*(p->ext_forces[j].get())) == typeid(const_force) ) {
					ConstantRateForce *p_force = (ConstantRateForce *) p->ext_forces[j].get();
					force->type = CUDA_TRAP_CONSTANT;
					force->constant.F0 = p_force->_F0;
					force->constant.dir_as_centre = p_force->dir_as_centre;
					force->constant.rate = p_force->_rate;
					force->constant.x = p_force->_direction.x;
					force->constant.y = p_force->_direction.y;
					force->constant.z = p_force->_direction.z;
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(mutual_trap) ) {
					MutualTrap *p_force = (MutualTrap *) p->ext_forces[j].get();
					force->type = CUDA_TRAP_MUTUAL;
					force->mutual.rate = p_force->_rate;
					force->mutual.stiff = p_force->_stiff;
					force->mutual.r0 = p_force->_r0;
					force->mutual.p_ind = p_force->_p_ptr->index;
					force->mutual.PBC = p_force->PBC;
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(moving_trap) ) {
					MovingTrap *p_force = (MovingTrap *) p->ext_forces[j].get();
					force->type = CUDA_TRAP_MOVING;
					force->moving.stiff = p_force->_stiff;
					force->moving.rate = p_force->_rate;
					force->moving.pos0 = make_float3 (p_force->_pos0.x, p_force->_pos0.y, p_force->_pos0.z);
					force->moving.dir = make_float3 (p_force->_direction.x, p_force->_direction.y, p_force->_direction.z);
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(lowdim_moving_trap) ) {
					LowdimMovingTrap *p_force = (LowdimMovingTrap *) p->ext_forces[j].get();
					force->type = CUDA_TRAP_MOVING_LOWDIM;
					force->lowdim.stiff = p_force->_stiff;
					force->lowdim.rate = p_force->_rate;
					force->lowdim.pos0 = make_float3 (p_force->_pos0.x, p_force->_pos0.y, p_force->_pos0.z);
					force->lowdim.dir = make_float3 (p_force->_direction.x, p_force->_direction.y, p_force->_direction.z);
					force->lowdim.visX = p_force->_visX;
					force->lowdim.visY = p_force->_visY;
					force->lowdim.visZ = p_force->_visZ;
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(repulsion_plane) ) {
					RepulsionPlane *p_force = (RepulsionPlane *) p->ext_forces[j].get();
					force->type = CUDA_REPULSION_PLANE;
					force->repulsionplane.stiff = p_force->_stiff;
					force->repulsionplane.position = p_force->_position;
					force->repulsionplane.dir = make_float3 (p_force->_direction.x, p_force->_direction.y, p_force->_direction.z);
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(repulsion_plane_moving) ) {
					RepulsionPlaneMoving *p_force = (RepulsionPlaneMoving *) p->ext_forces[j].get();
					force->type = CUDA_REPULSION_PLANE_MOVING;
					force->repulsionplanemoving.stiff = p_force->_stiff;
					force->repulsionplanemoving.dir = make_float3 (p_force->_direction.x, p_force->_direction.y, p_force->_direction.z);
					force->repulsionplanemoving.low_idx = p_force->low_idx;
					force->repulsionplanemoving.high_idx = p_force->high_idx;
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(repulsive_sphere) ) {
					RepulsiveSphere *p_force = (RepulsiveSphere *) p->ext_forces[j].get();
					force->type = CUDA_REPULSIVE_SPHERE;
					force->repulsivesphere.stiff = p_force->_stiff;
					force->repulsivesphere.rate= p_force->_rate;
					force->repulsivesphere.r0 = p_force->_r0;
					force->repulsivesphere.r_ext = p_force->_r_ext;
					force->repulsivesphere.centre = make_float3 (p_force->_center.x, p_force->_center.y, p_force->_center.z);
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(repulsive_sphere_smooth) ) {
					RepulsiveSphereSmooth *p_force = (RepulsiveSphereSmooth *) p->ext_forces[j].get();
					force->type = CUDA_REPULSIVE_SPHERE_SMOOTH;
					force->repulsivespheresmooth.r0 = p_force->_r0;
					force->repulsivespheresmooth.r_ext = p_force->_r_ext;
					force->repulsivespheresmooth.smooth = p_force->_smooth;
					force->repulsivespheresmooth.alpha = p_force->_alpha;
					force->repulsivespheresmooth.stiff = p_force->_stiff;
					force->repulsivespheresmooth.centre = make_float3 (p_force->_center.x, p_force->_center.y, p_force->_center.z);
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(LJ_wall) ) {
					LJWall *p_force = (LJWall *) p->ext_forces[j].get();
					force->type = CUDA_LJ_WALL;
					force->ljwall.stiff = p_force->_stiff;
					force->ljwall.position = p_force->_position;
					force->ljwall.n = p_force->_n;
					force->ljwall.cutoff = p_force->_cutoff;
					force->ljwall.sigma = p_force->_sigma;
					force->ljwall.dir = make_float3(p_force->_direction.x, p_force->_direction.y, p_force->_direction.z);

				}
				else if(typeid(*(p->ext_forces[j].get())) == typeid(const_rate_torque) ) {
					ConstantRateTorque *p_force = (ConstantRateTorque *) p->ext_forces[j].get();
					force->type = CUDA_CONSTANT_RATE_TORQUE;
					force->constantratetorque.stiff = p_force->_stiff;
					force->constantratetorque.F0 = p_force->_F0;
					force->constantratetorque.rate = p_force->_rate;
					force->constantratetorque.center = make_float3(p_force->_center.x, p_force->_center.y, p_force->_center.z);
					force->constantratetorque.pos0 = make_float3(p_force->_pos0.x, p_force->_pos0.y, p_force->_pos0.z);
					force->constantratetorque.axis = make_float3(p_force->_axis.x, p_force->_axis.y, p_force->_axis.z);
					force->constantratetorque.mask = make_float3(p_force->_mask.x, p_force->_mask.y, p_force->_mask.z);
				}
				else if(typeid(*(p->ext_forces[j].get())) == typeid(generic_central) ) {
					GenericCentralForce *p_force = (GenericCentralForce *) p->ext_forces[j].get();
					force->type = CUDA_GENERIC_CENTRAL_FORCE;
					force->genericconstantforce.F0 = p_force->_F0;
					force->genericconstantforce.inner_cut_off_sqr = p_force->inner_cut_off_sqr;
					force->genericconstantforce.outer_cut_off_sqr = p_force->outer_cut_off_sqr;
					force->genericconstantforce.x = p_force->center.x;
					force->genericconstantforce.y = p_force->center.y;
					force->genericconstantforce.z = p_force->center.z;
				}
				else if(typeid (*(p->ext_forces[j].get())) == typeid(LJ_cone) ) {
					LJCone *p_force = (LJCone *) p->ext_forces[j].get();
					force->type = CUDA_LJ_CONE;
					force->ljcone.stiff = p_force->_stiff;
					force->ljcone.n = p_force->_n;
					force->ljcone.cutoff = p_force->_cutoff;
					force->ljcone.sigma = p_force->_sigma;
					force->ljcone.alpha = p_force->_alpha;
					force->ljcone.sin_alpha = p_force->_sin_alpha;
					force->ljcone.dir = make_float3(p_force->_direction.x, p_force->_direction.y, p_force->_direction.z);
					force->ljcone.pos0 = make_float3(p_force->_pos0.x, p_force->_pos0.y, p_force->_pos0.z);
				}
				else {
					throw oxDNAException ("Only ConstantRate, MutualTrap, MovingTrap, LowdimMovingTrap, RepulsionPlane, "
							"RepulsionPlaneMoving, RepulsiveSphere, LJWall, ConstantRateTorque and GenericCentralForce "
							"forces are supported on CUDA at the moment.\n");
				}
			}
		}

		CUDA_SAFE_CALL( cudaMemcpy(_d_ext_forces, _h_ext_forces, N() * MAX_EXT_FORCES * sizeof (CUDA_trap), cudaMemcpyHostToDevice) );
	}

	// used in the hilbert curve sorting
	if(this->_sort_every > 0)	{
		CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<c_number4>(&_d_buff_vels, this->_vec_size) );
		CUDA_SAFE_CALL( GpuUtils::LR_cudaMalloc<c_number4>(&_d_buff_Ls, this->_vec_size) );
	}

	// these values are changed only if the curve sorting is enabled
	_h_gpu_index = new int[N()];
	_h_cpu_index = new int[N()];
	for(int i = 0; i < N(); i++) {
		_h_gpu_index[i] = i;
		_h_cpu_index[i] = i;
	}

	for(int i = 0; i < N(); i++) {
		BaseParticle *p = this->_particles[i];
		if(p->is_rigid_body()) _any_rigid_body = true;
	}

	// copy all the particle related stuff and the constants to device memory
	_host_particles_to_gpu();
	_init_CUDA_MD_symbols();

	_cuda_thermostat->set_seed(lrand48());
	_cuda_thermostat->init(N());

	OX_LOG(Logger::LOG_INFO, "Allocated CUDA memory: %.2lf MBs", GpuUtils::get_allocated_mem_mb());

	// initialise lists and compute the forces for the first step
	this->_cuda_lists->update(this->_d_poss, this->_d_list_poss, this->_d_bonds);
	_curr_step = this->_read_conf_step;
	if (_restart_step_counter) _curr_step = 0;
	_set_external_forces();
	this->_cuda_interaction->compute_forces(this->_cuda_lists, this->_d_poss, this->_d_orientations, _d_forces, _d_torques, this->_d_bonds, this->_d_cuda_box);
}

void MD_CUDABackend::print_conf(llint curr_step, bool reduced, bool only_last) {
	_gpu_to_host_particles();
	MDBackend::print_conf(curr_step, reduced, only_last);
}

void MD_CUDABackend::_print_ready_observables(llint curr_step) {
	_gpu_to_host_particles();
	if(!_avoid_cpu_calculations) this->_lists->global_update(true);
	MDBackend::_print_ready_observables(curr_step);
	_host_particles_to_gpu();
}

void MD_CUDABackend::fix_diffusion() {
	_gpu_to_host_particles();
	if(!_avoid_cpu_calculations) this->_lists->global_update(true);
	MDBackend::fix_diffusion();
	_host_particles_to_gpu();
}

#pragma GCC diagnostic pop
