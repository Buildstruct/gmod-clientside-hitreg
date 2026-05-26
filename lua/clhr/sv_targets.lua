local CLHR = CLHR

local max = math.max

local clhr_supertolerant = GetConVar("clhr_supertolerant")
local clhr_subtick = GetConVar("clhr_subtick")
local clhr_raybox = CreateConVar(
	"clhr_raybox", "384", FCVAR_ARCHIVE,
	"swept-box half-extent for the candidate search along the bullet ray"
)

local ray_mins, ray_maxs
local function update_raybox()
	local b = clhr_raybox:GetFloat()
	ray_mins = Vector(-b, -b, -b)
	ray_maxs = Vector(b, b, b)
end
update_raybox()
cvars.AddChangeCallback("clhr_raybox", update_raybox, "CLHR_RayBox")

local samepc = {}
for _, group in ipairs{
	{"arctic", "barney", "breen", "charple", "corpse1", "gasmask", "gman_high", "Group01/male_01", "Group01/male_02", "Group01/male_03", "Group01/male_04", "Group01/male_05", "Group01/male_06", "Group01/male_07", "Group01/male_08", "Group01/male_09", "Group02/male_02", "Group02/male_04", "Group02/male_06", "Group02/male_08", "Group03/male_01", "Group03/male_02", "Group03/male_03", "Group03/male_04", "Group03/male_05", "Group03/male_06", "Group03/male_07", "Group03/male_08", "Group03/male_09", "Group03m/male_01", "Group03m/male_02", "Group03m/male_03", "Group03m/male_04", "Group03m/male_05", "Group03m/male_06", "Group03m/male_07", "Group03m/male_08", "Group03m/male_09", "guerilla", "kleiner", "leet", "magnusson", "monk", "odessa", "phoenix", "riot", "skeleton", "swat", "urban"},
	{"Group01/female_01", "Group01/female_02", "Group01/female_03", "Group01/female_04", "Group01/female_05", "Group01/female_06", "Group03/female_01", "Group03/female_02", "Group03/female_03", "Group03/female_04", "Group03/female_05", "Group03/female_06", "Group03m/female_01", "Group03m/female_02", "Group03m/female_03", "Group03m/female_04", "Group03m/female_05", "Group03m/female_06", "mossman", "mossman_arctic", "p2_chell"},
	{"hostage/hostage_01", "hostage/hostage_02", "hostage/hostage_03", "hostage/hostage_04"},
	{"combine_soldier", "combine_soldier_prisonguard", "combine_super_soldier"},
	{"dod_american", "dod_german"},
} do
	local canonical = "models/player/" .. group[1] .. ".mdl"
	for _, name in ipairs(group) do
		samepc["models/player/" .. name .. ".mdl"] = canonical
	end
end

CLHR.SamePhysCollides = samepc
CLHR.PhysCollides = CLHR.PhysCollides or {}

local function newpc(mdl)
	local pc = CreatePhysCollidesFromModel(mdl)

	if not pc then
		CLHR.PhysCollides[mdl] = false
		return
	end

	if #pc == 1 then
		pc = pc[1]
	end

	CLHR.PhysCollides[samepc[mdl] or mdl] = pc

	return pc
end

function CLHR.GetPhysCollides(mdl, num)
	local pc = CLHR.PhysCollides[samepc[mdl] or mdl]

	if pc == false then
		return
	end

	if not pc then
		pc = newpc(mdl)

		if not pc then
			return
		end
	end

	if istable(pc) then
		if not num then
			return
		end

		pc = pc[num]

		if not IsValid(pc) then
			pc = newpc(mdl)

			if not istable(pc) then
				return
			end

			pc = pc[num]

			if not IsValid(pc) then
				return
			end
		end
	elseif not IsValid(pc) then
		pc = newpc(mdl)

		if not IsValid(pc) then
			return
		end
	end

	return pc
end

local function isfrozenphys(e)
	if e:GetNoDraw() or e:GetInternalVariable("m_takedamage") == 0 then
		return true
	elseif e:GetInternalVariable("m_flNextAttack") == nil then
		-- no m_flNextAttack means it's not based on CBaseCombatCharacter
		local phys = e:GetPhysicsObject()

		if IsValid(phys) then
			return phys:IsAsleep()
		elseif e:GetSolid() == SOLID_VPHYSICS or e:GetMoveType() == MOVETYPE_VPHYSICS then
			return true
		end
	end
end

local function isdead(e)
	if e:IsPlayer() then
		if not e:Alive()
			or GAMEMODE_NAME == "terrortown" and not e:IsTerror() -- ttt spectators are "alive"
		then
			return true
		end
	elseif e:Health() <= 0
		and e:GetInternalVariable("m_takedamage") == 2
	then
		return true
	end
end

CLHR.IsFrozenPhys = isfrozenphys
CLHR.IsDead = isdead

local MAX_TRACE_LENGTH = CLHR.MAX_TRACE_LENGTH
local TICKINTERVAL = engine.TickInterval()

local function snapshot_entity(v)
	local pos_t, ang_t = {}, {}
	local any

	if v:IsRagdoll() then
		for i = 1, v:GetPhysicsObjectCount() do
			local pos, ang
			local phys = v:GetPhysicsObjectNum(i - 1)

			if IsValid(phys) and bit.band(phys:GetContents(), MASK_SHOT) ~= 0 then
				any = true
				pos, ang = phys:GetPos(), phys:GetAngles()
			else
				pos, ang = false, false
			end

			pos_t[i], ang_t[i] = pos, ang
		end
	elseif v:GetMoveType() == MOVETYPE_VPHYSICS and v:GetSolid() == SOLID_VPHYSICS then
		any = true
		pos_t[1], ang_t[1] = v:GetPos(), v:GetAngles()
	else
		local set = v:GetHitboxSet()
		if not set then return false end
		local hcount = v:GetHitBoxCount(set)
		if not hcount or hcount == 0 then return false end

		for i = 1, hcount do
			local pos, ang
			local bone = v:GetHitBoxBone(i - 1, set)

			if bone and bit.band(v:GetBoneContents(bone), MASK_SHOT) ~= 0 then
				pos, ang = v:GetBonePosition(bone)
			end

			if pos and ang then
				any = true
			else
				pos, ang = false, false
			end

			pos_t[i], ang_t[i] = pos, ang
		end
	end

	if not any then return false end

	return {pos = pos_t, ang = ang_t, mdl = v:GetModel()}
end

function CLHR.GetPossibleTargets(ply, start, dir, info)
	local out = {}
	local ndir = -dir
	local supertol = clhr_supertolerant:GetBool() or clhr_subtick:GetBool()

	local search_distance = (info and info.distance) or MAX_TRACE_LENGTH
	local search_endpos = start + dir * search_distance

	local ray_res = ents.FindAlongRay(start, search_endpos, ray_mins, ray_maxs)
	for i=1, #ray_res do
		local v = ray_res[i]
		if v == ply
			or not v:IsSolid()
			or isfrozenphys(v)
			or not CLHR.PassesTargetBits(v)
			or bit.band(v:GetSolidFlags(), FSOLID_NOT_SOLID) ~= 0
			or isdead(v)
		then continue end

		local wspos = v:WorldSpaceCenter()
		local planehit = util.IntersectRayWithPlane(start, dir, wspos, ndir)
		if not planehit then continue end

		if not supertol then
			local tol = max(128, v:BoundingRadius())
			if v:IsLagCompensated() then
				tol = tol * tol
			else
				local lag = (info and info.ping or 0) * TICKINTERVAL + 0.1
				local drift = v:GetVelocity():Length() * lag
				local eff = tol * 2 + drift
				tol = eff * eff
			end
			if planehit:DistToSqr(wspos) > tol then continue end
		end

		local tbl = snapshot_entity(v)
		if tbl then
			out[v] = tbl
		end
	end

	return out
end