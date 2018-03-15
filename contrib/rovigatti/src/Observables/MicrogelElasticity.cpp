/*
 * MicrogelElasticity.cpp
 *
 *  Created on: Mar 13, 2018
 *      Author: Lorenzo
 */

#include "MicrogelElasticity.h"

#include "Utilities/Utils.h"

#include <sstream>

#define QUICKHULL_IMPLEMENTATION
#include "quickhull.h"
#include "diagonalise_3x3.h"

template<typename number>
MicrogelElasticity<number>::MicrogelElasticity() {

}

template<typename number>
MicrogelElasticity<number>::~MicrogelElasticity() {

}

template<typename number>
void MicrogelElasticity<number>::get_settings(input_file &my_inp, input_file &sim_inp) {
	string inter;
	getInputString(&sim_inp, "interaction_type", inter, 1);
	if(inter != "MGInteraction") throw oxDNAException("MicrogelElasticity is not compatible with the interaction '%s'", inter.c_str());
}

template<typename number>
void MicrogelElasticity<number>::init(ConfigInfo<number> &config_info) {

}

template<typename number>
LR_vector<number> MicrogelElasticity<number>::_com() {
	LR_vector<number> com;
	int N = *this->_config_info.N;
	for(int i = 0; i < N; i++) {
		BaseParticle<number> *p = this->_config_info.particles[i];
		com += this->_config_info.box->get_abs_pos(p);
	}
	return com / N;
}

template<typename number>
std::string MicrogelElasticity<number>::get_output_string(llint curr_step) {
	stringstream ss;

	// Convex hull
	LR_vector<number> com = _com();
	int N = *this->_config_info.N;

	vector<qh_vertex_t> vertices(N);
	for(int i = 0; i < N; i++) {
		BaseParticle<number> *p = this->_config_info.particles[i];
		LR_vector<number> p_pos = this->_config_info.box->get_abs_pos(p) - com;

		vertices[i].x = p_pos.x;
		vertices[i].y = p_pos.y;
		vertices[i].z = p_pos.z;
	}

	qh_mesh_t mesh = qh_quickhull3d(vertices.data(), N);

	number volume = 0.;
	LR_vector<number> ch_com;
	for(int i = 0, j = 0; i < (int)mesh.nindices; i += 3, j++) {
		LR_vector<number> p1(mesh.vertices[mesh.indices[i + 0]].x, mesh.vertices[mesh.indices[i + 0]].y, mesh.vertices[mesh.indices[i + 0]].z);
		LR_vector<number> p2(mesh.vertices[mesh.indices[i + 1]].x, mesh.vertices[mesh.indices[i + 1]].y, mesh.vertices[mesh.indices[i + 1]].z);
		LR_vector<number> p3(mesh.vertices[mesh.indices[i + 2]].x, mesh.vertices[mesh.indices[i + 2]].y, mesh.vertices[mesh.indices[i + 2]].z);

		volume += (p1 * (p2.cross(p3))) / 6.;

		ch_com += (p1 + p2 + p3);
	}
	ss << volume;
	ch_com /= mesh.nindices;

	// Gyration tensor
	double gyration_tensor[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
//	for(int i = 0; i < N; i++) {
//		BaseParticle<number> *p = this->_config_info.particles[i];
//		LR_vector<number> i_pos = this->_config_info.box->get_abs_pos(p) - com;
//
//		gyration_tensor[0][0] += SQR(i_pos[0]);
//		gyration_tensor[0][1] += i_pos[0] * i_pos[1];
//		gyration_tensor[0][2] += i_pos[0] * i_pos[2];
//
//		gyration_tensor[1][1] += SQR(i_pos[1]);
//		gyration_tensor[1][2] += i_pos[1] * i_pos[2];
//
//		gyration_tensor[2][2] += SQR(i_pos[2]);
//	}
	for(int i = 0, j = 0; i < (int)mesh.nindices; i += 3, j++) {
		LR_vector<number> p1(mesh.vertices[mesh.indices[i + 0]].x, mesh.vertices[mesh.indices[i + 0]].y, mesh.vertices[mesh.indices[i + 0]].z);
		LR_vector<number> p2(mesh.vertices[mesh.indices[i + 1]].x, mesh.vertices[mesh.indices[i + 1]].y, mesh.vertices[mesh.indices[i + 1]].z);
		LR_vector<number> p3(mesh.vertices[mesh.indices[i + 2]].x, mesh.vertices[mesh.indices[i + 2]].y, mesh.vertices[mesh.indices[i + 2]].z);
		LR_vector<number> triangle_com = (p1 + p2 + p3) / 3. - ch_com;

		gyration_tensor[0][0] += SQR(triangle_com[0]);
		gyration_tensor[0][1] += triangle_com[0] * triangle_com[1];
		gyration_tensor[0][2] += triangle_com[0] * triangle_com[2];

		gyration_tensor[1][1] += SQR(triangle_com[1]);
		gyration_tensor[1][2] += triangle_com[1] * triangle_com[2];

		gyration_tensor[2][2] += SQR(triangle_com[2]);
	}
	gyration_tensor[1][0] = gyration_tensor[0][1];
	gyration_tensor[2][0] = gyration_tensor[0][2];
	gyration_tensor[2][1] = gyration_tensor[1][2];
	for(int i = 0; i < 3; i++) {
		for(int j = 0; j < 3; j++) {
//			gyration_tensor[i][j] /= N;
			gyration_tensor[i][j] /= mesh.nindices / 3;
		}
	}

	double eigenvectors[3][3];
	double eigenvalues[3];
	eigen_decomposition(gyration_tensor, eigenvectors, eigenvalues);

	volume = 4 * M_PI * sqrt(3) * sqrt(eigenvalues[0]) * sqrt(eigenvalues[1]) * sqrt(eigenvalues[2]);
	ss << " " << volume;
	ss << " " << sqrt(eigenvalues[0]);
	ss << " " << sqrt(eigenvalues[1]);
	ss << " " << sqrt(eigenvalues[2]);

	LR_vector<number> EVs[3] = {
		LR_vector<number>(eigenvectors[0][0], eigenvectors[0][1], eigenvectors[0][2]),
		LR_vector<number>(eigenvectors[1][0], eigenvectors[1][1], eigenvectors[1][2]),
		LR_vector<number>(eigenvectors[2][0], eigenvectors[2][1], eigenvectors[2][2])
	};
	EVs[0].normalize();
	EVs[1].normalize();
	EVs[2].normalize();

	// now we find the largest distance along the three directions given by the eigenvectors
//	LR_vector<number> max_along_EVs(-1.e6, -1.e6, -1.e6);
//	LR_vector<number> min_along_EVs(1.e6, 1.e6, 1.e6);
//	LR_vector<number> max_dist_along_EVs(0., 0., 0.);
//	for(int i = 0; i < (int)mesh.nvertices; i++) {
//		LR_vector<number> p_pos(mesh.vertices[i].x, mesh.vertices[i].y, mesh.vertices[i].z);
//
//		for(int d = 0; d < 3; d++) {
//			number abs = p_pos*EVs[d];
//			if(abs > max_along_EVs[d]) max_along_EVs[d] = abs;
//			else if(abs < min_along_EVs[d]) min_along_EVs[d] = abs;
//		}
//
//		for(int j = i + 1; j < (int)mesh.nvertices; j++) {
//			LR_vector<number> q_pos(mesh.vertices[j].x, mesh.vertices[j].y, mesh.vertices[j].z);
//			LR_vector<number> dist = q_pos - p_pos;
//			number dist_mod = dist.module();
//
//			if(dist_mod > 1e-3) {
//				for(int d = 0; d < 3; d++) {
//					number abs = fabs(dist*EVs[d]);
//					number cos_theta = abs / dist_mod;
//					if(cos_theta > 0.99 && abs > max_dist_along_EVs[d]) max_dist_along_EVs[d] = abs;
//				}
//			}
//		}
//	}
//
//	LR_vector<number> axes(
//			max_along_EVs[0] - min_along_EVs[0],
//			max_along_EVs[1] - min_along_EVs[1],
//			max_along_EVs[2] - min_along_EVs[2]
//			);
//	axes /= 2.;
//	volume = 4. * M_PI / 3. * axes[0] * axes[1] * axes[2];
//	ss << " " << volume;
//	ss << " " << axes[0];
//	ss << " " << axes[1];
//	ss << " " << axes[2];
//
//	axes = LR_vector<number>(
//			max_dist_along_EVs[0],
//			max_dist_along_EVs[1],
//			max_dist_along_EVs[2]
//			);
//	axes /= 2.;
//	volume = 4. * M_PI / 3. * axes[0] * axes[1] * axes[2];
//	ss << " " << volume;
//	ss << " " << axes[0];
//	ss << " " << axes[1];
//	ss << " " << axes[2];

	qh_free_mesh(mesh);

	return ss.str();
}

template class MicrogelElasticity<float> ;
template class MicrogelElasticity<double> ;
