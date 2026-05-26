local CLHR = CLHR

local clhr_nofirebulletsincallback = GetConVar("clhr_nofirebulletsincallback")

local pending
hook.Add("EntityTakeDamage", "CLHR_AccumulateDamage", function(vic, dmginfo)
	local info = pending
	if not info then return end

	pending = nil

	if vic ~= info.vic
		or dmginfo:GetAttacker() ~= info.ply
		or dmginfo:GetInflictor() ~= info.infl
		or CurTime() ~= info.crt
	then
		return
	end

	if info.add then
		info.add = nil

		info.multidmg = (info.multidmg or 0) + dmginfo:GetDamage()

		local frc = dmginfo:GetDamageForce()
		if info.multifrc then
			info.multifrc:Add(frc)
		else
			info.multifrc = frc
		end

		return true
	end

	if info.multidmg then
		dmginfo:AddDamage(info.multidmg)
		info.multidmg = nil
	end

	if info.multifrc then
		info.multifrc:Add(dmginfo:GetDamageForce())
		dmginfo:SetDamageForce(info.multifrc)
		info.multifrc = nil
	end
end)

local function dohits(ply, hit, lc)
	if not hit then
		if lc then
			ply:LagCompensation(false)
		end
		return
	end

	if clhr_nofirebulletsincallback:GetBool() then
		CLHR.IgnoreBulletPlayer = ply
		CLHR.IgnoreBulletTime = CurTime()
	end

	SuppressHostEvents(ply)

	while hit do
		local h = hit
		hit = h.nxt

		local dmginfo = DamageInfo()

		for setter, val in pairs(h.dmginfo) do
			if val ~= nil and (not isentity(val) or IsValid(val)) then
				dmginfo[setter](dmginfo, val)
			end
		end

		local trace = h.newtrace
		local info = h.info

		trace.CLHR_CommandNumber = info.cmd
		trace.CLHR_StoredData = h.origtrace and h.origtrace.CLHR_StoredData

		if info.cb then
			-- another addon's callback erroring must not leave SuppressHostEvents/LagCompensation in a bad state
			xpcall(info.cb, ErrorNoHaltWithStack, ply, trace, dmginfo)
		end

		local vic = trace.Entity
		local phys = vic:GetPhysicsObject()
		if IsValid(phys) and (vic:GetMoveType() == MOVETYPE_VPHYSICS or vic:IsNPC()) then
			local dir = trace.Normal
			if dir:LengthSqr() < 1e-6 then
				dir = (trace.HitPos - trace.StartPos):GetNormalized()
			end
			dmginfo:SetDamageForce(dir * (info.force or 0) * phys:GetMass())
		end

		info.ply = ply
		info.infl = dmginfo:GetInflictor()
		info.crt = CurTime()
		info.vic = vic
		info.add = h ~= info.lasthit[vic]

		pending = info
		vic:DispatchTraceAttack(dmginfo, trace)
		pending = nil

		if CLHR.NotifyDebugEvent then
			CLHR.NotifyDebugEvent(ply, info.cmd, vic, true, "Success!", trace.HitPos)
		end
	end

	CLHR.IgnoreBulletPlayer = nil
	CLHR.IgnoreBulletTime = nil

	SuppressHostEvents(NULL)

	if lc then
		ply:LagCompensation(false)
	end
end

function CLHR.OnSetupMove(ply, mv)
	if mv:KeyPressed(IN_DUCK) and not ply:OnGround() then
		local crt = CurTime()
		ply.CLHR_airDuck = math.Clamp(
			crt + 0.5, (ply.CLHR_airDuck or 0) + 0.5, crt + 2
		)
	end

	local wanthit = ply.CLHR_wantHit
	ply.CLHR_wantHit = nil

	local hit, lagcomp

	while wanthit do
		local whit = wanthit
		wanthit = whit.nxt

		local tick = engine.TickCount()

		if whit.tick ~= tick - 1 and whit.tick ~= tick then
			CLHR.Debug(ply, whit.vic, whit.info, "Fail: Bad tick count")
			continue
		end

		do
			local lc, h = CLHR.Validate(ply, whit, lagcomp)

			if lc then
				lagcomp = true
			end

			if h then
				h.nxt = hit
				hit = h
			end
		end
	end

	if hit or lagcomp then
		return dohits(ply, hit, lagcomp)
	end
end

local gesturetimes = {
	quick_yes = 3,
	quick_no = 3,
	quick_see = 4,
	quick_check = 2,
	quick_suspect = 2,
}

hook.Add("TTTPlayerRadioCommand", "CLHR_TTTRadio", function(ply, msg)
	local gtime = gesturetimes[msg]
	if gtime then
		ply.CLHR_tttGesture = CurTime() + gtime
	end
end)