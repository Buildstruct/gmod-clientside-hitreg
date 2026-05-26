local CLHR = CLHR

local clhr_subtick = GetConVar("clhr_subtick")
local clhr_subtick_aimcorrect = GetConVar("clhr_subtick_aimcorrect")
local host_timescale = GetConVar("host_timescale")

local TICKINTERVAL = engine.TickInterval()

local Subtick = {}
CLHR.Subtick = Subtick

local attackdown = false
local subcrt = 0
local subaim, subpos, subdata

local tracedata = {
	mask = MASK_SHOT,
	output = {},
}

hook.Add("CreateMove", "CLHR_Subtick_Sample", function(cmd)
	if not clhr_subtick:GetBool() then
		return
	end

	if not cmd:KeyDown(IN_ATTACK) then
		attackdown = false
		return
	end

	local attackheld = attackdown
	attackdown = true

	local ply = LocalPlayer()

	if not (IsValid(ply) and ply:Alive()) then
		return
	end

	local wep = ply:GetActiveWeapon()

	if not IsValid(wep)
		or wep.CLHR_Disabled
		or CLHR.Exceptions[wep:GetClass()]
		or wep:Clip1() <= 0
		or wep.Primary and not wep.Primary.Automatic and attackheld
	then
		return
	end

	local crt = CurTime()
	if crt < subcrt + TICKINTERVAL then
		return
	end

	subcrt = crt
	subpos = ply:GetShootPos()
	subaim = cmd:GetViewAngles():Forward()

	local td = tracedata
	td.start = subpos
	td.endpos = subpos + subaim * CLHR.MAX_TRACE_LENGTH
	td.filter = ply

	local vic, hbox, hpos = CLHR.ProcessTrace(util.TraceLine(td), true)

	if vic then
		subdata = {
			vic = vic,
			hbox = hbox,
			hpos = hpos,
		}
	else
		subdata = nil
	end
end)

function Subtick.OnFireBullets(ply, data)
	if not IsFirstTimePredicted() or ply ~= LocalPlayer() then
		return
	end

	if (data.Num or 1) > 1 then
		return
	end

	local scrt, spos, saim, sdata = subcrt, subpos, subaim, subdata
	subcrt, subpos, subaim, subdata = 0, nil, nil, nil

	local tscale = math.max(0.01, host_timescale:GetFloat() * game.GetTimeScale())

	if scrt == 0
		or data.Src ~= ply:GetShootPos()
		or data.Dir ~= ply:GetAimVector()
		or spos == data.Src and saim == data.Dir and not sdata
		or UnPredictedCurTime() > scrt + TICKINTERVAL / tscale
	then
		return
	end

	data.CLHR_Subtick = spos
	data.Src = spos
	data.Dir = saim

	if not sdata or not clhr_subtick_aimcorrect:GetBool() then
		return
	end

	local vic = sdata.vic

	if not IsValid(vic) or vic:IsPlayer() and not vic:Alive() then
		return
	end

	local hbox = sdata.hbox
	local pos, ang

	if vic:IsRagdoll() then
		local bone = vic:TranslatePhysBoneToBone(hbox)

		if not (bone and bone ~= -1) then
			return
		end

		local mat = vic:GetBoneMatrix(bone)

		if not mat then
			return
		end

		pos, ang = mat:GetTranslation(), mat:GetAngles()
	elseif vic:GetMoveType() == MOVETYPE_VPHYSICS and vic:GetSolid() == SOLID_VPHYSICS then
		pos, ang = vic:GetPos(), vic:GetAngles()
	else
		local set = vic:GetHitboxSet()

		if not set then
			return
		end

		local bone = vic:GetHitBoxBone(hbox, set)

		if not (bone and vic:GetBonePosition(bone)) then
			return
		end

		local mat = vic:GetBoneMatrix(bone)

		if not mat then
			return
		end

		pos, ang = mat:GetTranslation(), mat:GetAngles()
	end

	local lookat = LocalToWorld(sdata.hpos, angle_zero, pos, ang)
	lookat:Sub(data.Src)
	lookat:Normalize()

	data.Dir = lookat
end