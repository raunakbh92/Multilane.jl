type IDMMOBILBehavior <: BehaviorModel
	p_idm::IDMParam
	p_mobil::MOBILParam
	idx::Int
end
==(a::IDMMOBILBehavior,b::IDMMOBILBehavior) = (a.p_idm==b.p_idm) && (a.p_mobil==b.p_mobil)
Base.hash(a::IDMMOBILBehavior,h::UInt64=zero(UInt64)) = hash(a.p_idm,hash(a.p_mobil,h))

function IDMMOBILBehavior(s::AbstractString,v0::Float64,s0::Float64,idx::Int)
	return IDMMOBILBehavior(IDMParam(s,v0,s0),MOBILParam(s),idx)
end

generate_accel(bmodel::BehaviorModel, dmodel::AbstractMLDynamicsModel, s::MLState, neighborhood::Array{Int,1}, idx::Int, rng::AbstractRNG) = error("Uninstantiated Behavior Model")

generate_lane_change(bmodel::BehaviorModel, dmodel::AbstractMLDynamicsModel, s::MLState,neighborhood::Array{Int,1}, idx::Int, rng::AbstractRNG) = error("Uninstantiated Behavior Model")


function generate_accel(bmodel::IDMMOBILBehavior, dmodel::AbstractMLDynamicsModel, s::MLState, neighborhood::Array{Int,1}, idx::Int, rng::AbstractRNG)
	pp = dmodel.phys_param
	dt = pp.dt
	car = s.env_cars[idx]
	vel = car.vel

	dv, ds = get_dv_ds(pp,s,neighborhood,idx,2)

	dvel = get_idm_dv(bmodel.p_idm,dt,vel,dv,ds) #call idm model
	#TODO: add gaussian noise
	dvel += randn(rng) * dmodel.vel_sigma
	dvel = min(max(dvel/dt,-bmodel.p_idm.b),bmodel.p_idm.a)

	return dvel
end

function generate_lane_change(bmodel::IDMMOBILBehavior, dmodel::AbstractMLDynamicsModel, s::MLState, neighborhood::Array{Int,1}, idx::Int, rng::AbstractRNG)

	pp = dmodel.phys_param
	dt = pp.dt
	car = s.env_cars[idx]
	lane_change = car.lane_change #this is a velocity in the y direction in LANES PER SECOND
	#lane_ = round(max(1,min(car.y+lane_change,2*pp.nb_lanes-1)))
	#if increment y in the same timestep as deciding to lanechange
	lane_ = car.y

	if mod(lane_-0.5,1) == 0. #in between lanes
        @assert lane_change != 0
		lanechange = lane_change

		if is_lanechange_dangerous(pp, s, neighborhood, idx, lanechange)
				lanechange *= -1
		end

		return lanechange
	end
	#sample normally
	lanechange_::Int = get_mobil_lane_change(pp, s, neighborhood, idx, rng)
	#gives +1, -1 or 0
	#if frnot neighbor is lanechanging, don't lane change
	nbr = neighborhood[2]
	ahead_dy = nbr != 0 ? s.env_cars[nbr].lane_change : 0
	if ahead_dy != 0
			lanechange_ = 0.
	end

    lanechange = lanechange_
	#NO LANECHANGING
	#lanechange = 0

	return lanechange * dmodel.lane_change_vel / dmodel.phys_param.w_lane
end

#############################################################################
#TODO How to make compatible with MOBIL?

type AvoidModel <: BehaviorModel
	jerk::Bool
end
AvoidModel() = AvoidModel(false)
# NOTE: JerkModel might be better modeled by a /very/ aggressive IDM car
JerkModel() = AvoidModel(true)
==(a::AvoidModel, b::AvoidModel) = (a.jerk == b.jerk)
Base.hash(a::AvoidModel, h::UInt64=zero(UInt64)) = hash(a.jerk,h)

function closest_car(dmodel::IDMMOBILModel, s::MLState, nbhd::Array{Int,1}, idx::Int, lookahead_only::Bool)
	x = s.env_cars[idx].x
    y = s.env_cars[idx].y
	dy = dmodel.phys_param.w_lane

	closest = 0
	min_dist = Inf

	for i = 1:3 #front cars
		if nbhd[i] == 0
			continue
		end
		dist = norm([x - car.x; (y - car.y)*dy])
		if dist < min_dist
			min_dist = dist
			closest = i
		end
	end

	if lookahead_only
		return closest
	end

	for i = 4:6 #rear cars
		if nbhd[i] == 0
			continue
		end
		car = s.env_cars[nbhd[i]]
		dists = norm([x - car.x; (y - car.y)*dy])
		if dist < min_dist
			min_dist = dist
			closest = i
		end
	end

	return closest

end

function generate_accel(bmodel::AvoidModel, dmodel::IDMMOBILModel, s::MLState, neighborhood::Array{Int,1}, idx::Int, rng::AbstractRNG)
	closest_car = closest_car(dmodel,s,neighborhood,idx,bmodel.jerk)
	if closest_car == 0
		return 0.
	end

	x = s.env_cars[idx].x
	cc = s.env_cars[closest_car]

	if p.jerk #TODO fix this so it doesn't always accelerate if there's no space
    accel = cs.x - x > 2*dmodel.phys_param.l_car ? 1 : -3. #slam brakes
  else
    accel = -sign(cs.x - x)
  end

	return accel*dmodel.phys_param.dt #XXX times accel interval?

end

function generate_lane_change(bmodel::AvoidModel, dmodel::IDMMOBILModel, s::MLState, neighborhood::Array{Int,1}, idx::Int, rng::AbstractRNG)
	closest_car = closest_car(dmodel,s,neighborhood,idx,bmodel.jerk)
	if closest_car == 0
		return 0.
	end

	pos = s.env_cars[idx].y
	cc = s.env_cars[closest_car]

	lanechange = -sign(cc.y - pos)
	#if same lane, go in direction with more room
	if lanechange == 0
		if pos >= 2*dmodel.phys_param.nb_lanes - 1 - pos >= pos #more room to left >= biases to left
			lanechange = 1
		else
			lanechange = -1
		end
	end
	if lanechange > 0 && pos >= 2*dmodel.phys_param.nb_lanes - 1
		lanechange = 0
	elseif lanechange < 0 && pos <= 1
		lanechange = 0
	end

	return lanechange
end
