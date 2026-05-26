local CLHR = CLHR

local sqrt, ceil, max = math.sqrt, math.ceil, math.max

local clhr_supertolerant = GetConVar("clhr_supertolerant")
local clhr_subtick = GetConVar("clhr_subtick")
local clhr_tolerance = GetConVar("clhr_tolerance")
local clhr_tolerance_nolc = GetConVar("clhr_tolerance_nolc")
local clhr_tolerance_ping = GetConVar("clhr_tolerance_ping")
local clhr_printshots = GetConVar("clhr_printshots")

local TICKINTERVAL = engine.TickInterval()
local TICKRATE = 1 / TICKINTERVAL

local DMGINFO_FIELDS = {}
for _, name in ipairs{
	"AmmoType",
	-- "Attacker",
	"BaseDamage",
	"Damage",
	"DamageBonus",
	"DamageCustom",
	"DamageForce",
	-- "DamagePosition",
	"DamageType",
	"Inflictor",
	"MaxDamage",
	"ReportedPosition",
	"Weapon",
} do
	DMGINFO_FIELDS["Get" .. name] = "Set" .. name
end
CLHR.DMGINFO_FIELDS = DMGINFO_FIELDS

local function dbg(ply, vic, info, fmt, ...)
	local wantPrint = clhr_printshots:GetBool()
	local wantEvent = CLHR.NotifyDebugEvent ~= nil

	if not (wantPrint or wantEvent) then
		return
	end

	local args = select("#", ...) > 0 and {...} or nil
	local msg = args and fmt:format(...) or fmt

	if wantPrint then
		print(("[CLHR] %s (%s, [%d]%s, %d)"):format(
			msg,
			ply:Nick(),
			IsValid(vic) and vic:EntIndex() or 0,
			IsValid(vic) and (vic:IsPlayer() and vic:Nick() or vic:GetClass()) or "NULL",
			isnumber(info) and info or info.cmd
		))
	end

	if wantEvent and msg:sub(1, 8) ~= "Success!" then
		local cmd = isnumber(info) and info or info.cmd
		CLHR.NotifyDebugEvent(ply, cmd, vic, false, msg, nil)
	end
end

CLHR.Debug = dbg

local function getinterp(p)
	return max(
		p:GetInfoNum("cl_interp", 0.1),
		p:GetInfoNum("cl_interp_ratio", 2) / p:GetInfoNum("cl_updaterate", 20)
	)
end

CLHR.GetInterp = getinterp

local function calctolerance(e, hbox, set, bone)
	if set and e:IsPlayer() then
		local crt = CurTime()
		local hitgroup = e:GetHitBoxHitGroup(hbox, set)

		if hitgroup == HITGROUP_RIGHTLEG then
			if TTT_FOF and crt < e:GetNW2Float("TTT_FOF_Kicking") then
				return 64
			end
		elseif hitgroup == HITGROUP_HEAD
			or hitgroup == HITGROUP_CHEST
			or hitgroup == HITGROUP_LEFTARM
			or hitgroup == HITGROUP_RIGHTARM
		then
			if crt < (e.CLHR_tttGesture or 0) then
				return 64
			end
		end

		if crt < (e.CLHR_airDuck or 0) then
			return 36
		end
	end

	if e:HasBoneManipulations() and (
		e:GetManipulateBonePosition(bone) ~= vector_origin
		or e:GetManipulateBoneAngles(bone) ~= angle_zero
		or e:GetManipulateBoneScale(bone) ~= vector_origin
		or e:GetManipulateBoneJiggle(bone) ~= 0
	) then
		return 64
	end
end

CLHR.CalcTolerance = calctolerance

local tracedata = {
	mask = MASK_SHOT,
	output = {},
}

local function resolveHitbox(ply, whit, vic, hbox, info, shotinfo, mdl, tbl)
	local pos, ang = tbl.pos[1 + hbox], tbl.ang[1 + hbox]

	if not (pos and ang) then
		dbg(ply, vic, info, "Fail: Hitbox %d is non-solid", hbox)
		return
	end

	local rag = vic:IsRagdoll()
	local vphy = vic:GetMoveType() == MOVETYPE_VPHYSICS and vic:GetSolid() == SOLID_VPHYSICS

	local phys, set, bone, mins, maxs
	local vec = whit.normdist and whit.norm * whit.normdist

	if rag or vphy then
		if rag then
			bone = vic:TranslatePhysBoneToBone(hbox)

			if not bone or bone == -1 then
				dbg(ply, vic, info, "Fail: PhysObj %d out of range", hbox)
				return
			end
		else
			bone = 0
		end

		phys = rag and vic:GetPhysicsObjectNum(hbox) or vic:GetPhysicsObject()

		if not IsValid(phys) then
			dbg(ply, vic, info, "Fail: Invalid PhysObj")
			return
		end

		local pc = CLHR.GetPhysCollides(mdl, rag and hbox + 1 or nil)

		if not pc then
			dbg(ply, vic, info, "Fail: Invalid PhysCollides")
			return
		end

		mins, maxs = phys:GetAABB()

		vec = vec or pc:TraceBox(
			vector_origin, angle_zero, whit.norm * (
				1 + sqrt(max(mins:LengthSqr(), maxs:LengthSqr()))
			), vector_origin, vector_origin, vector_origin
		)
	else
		set = vic:GetHitboxSet()

		if not set then
			dbg(ply, vic, info, "Fail: No hitbox set")
			return
		end

		bone = vic:GetHitBoxBone(hbox, set)

		if not bone then
			dbg(ply, vic, info, "Fail: Hitbox %d out of range", hbox)
			return
		end

		mins, maxs = vic:GetHitBoxBounds(hbox, set)

		if not (mins and maxs) then
			dbg(ply, vic, info, "Fail: Hitbox %d has no bounds", hbox)
			return
		end

		local raydelt = whit.norm * (
			1000 + sqrt(max(mins:LengthSqr(), maxs:LengthSqr()))
		)

		vec = vec or util.IntersectRayWithOBB(
			raydelt, -raydelt, vector_origin, angle_zero, mins, maxs
		)
	end

	if not vec then
		dbg(ply, vic, info, "Fail: Hitpos unreproducible")
		return
	end

	if set then
		local mid = mins + maxs
		mid:Mul(0.5)

		vec:Sub(mid)

		local len = vec:Length()

		if len > 1 then
			vec:Mul((1 / len) * max(1, len - 1))
		end

		vec:Add(mid)
	end

	return vec, pos, ang, bone, set, phys, rag
end

function CLHR.Validate(ply, whit, lc)
	local info, vic = whit.info, whit.vic

	if not IsValid(vic) then
		dbg(ply, vic, info, "Fail: Invalid victim")
		return
	end

	local shotinfo = whit.shotinfo

	if vic == shotinfo.origvic then
		if clhr_printshots:GetInt() == 2 then
			dbg(ply, vic, info, "Fail: Already hit victim")
		end
		return
	end

	local tbl = shotinfo.targets[vic]

	if not tbl then
		dbg(ply, vic, info, "Fail: Bad victim")
		return
	end

	if CLHR.IsDead(vic) then
		dbg(ply, vic, info, "Fail: Dead victim")
		return
	end

	if not IsValid(shotinfo.dmginfo.SetInflictor) then
		dbg(ply, vic, info, "Fail: Invalid weapon")
		return
	end

	local mdl = vic:GetModel()

	if mdl ~= tbl.mdl then
		dbg(ply, vic, info, "Fail: Victim changed model")
		return
	end

	local hbox = whit.hbox

	local vec, pos, ang, bone, set, phys, rag = resolveHitbox(ply, whit, vic, hbox, info, shotinfo, mdl, tbl)

	if not vec then
		return
	end

	local start = shotinfo.startpos

	if whit.subtick then
		local vel = ply:GetVelocity()
		local maxdist = TICKINTERVAL * (
			vel:LengthSqr() > 1024 ^ 2 and vel:Length() or 1024
		)

		local td = tracedata
		td.start = start
		td.endpos = whit.subtick

		if td.start:DistToSqr(td.endpos) > maxdist * maxdist then
			td.endpos = td.endpos - td.start
			td.endpos:Normalize()
			td.endpos:Mul(maxdist)
			td.endpos:Add(start)
		end

		td.filter = ply
		-- TODO: should probably use a hull trace...?
		start = util.TraceLine(td).HitPos
	end

	local hitpos = LocalToWorld(vec, angle_zero, pos, ang)

	local tol, distsqr, lerp
	local viclagcomp = vic:IsLagCompensated()

	if not (clhr_supertolerant:GetBool() or clhr_subtick:GetBool()) then
		if start:DistToSqr(hitpos) > info.distsqr then
			dbg(ply, vic, info, "Fail: Hitpos too far %s > %s",
				math.Round(start:Distance(hitpos), 2),
				math.Round(info.distance, 2))
			return
		end

		if viclagcomp then
			if vic:IsNPC() then
				local lerp1 = CLHR.GetInterp(ply)
				local lerp2 = ply:GetInfoNum("cl_interp_npcs", 0)

				lerp = max(lerp1, lerp2)

				-- source's lagcomp doesn't account for cl_interp_npcs
				if ceil(lerp2 * TICKRATE) <= ceil(lerp1 * TICKRATE) then
					tol = true
				end
			else
				tol = true
			end
		end

		tol = tol and clhr_tolerance:GetFloat() or clhr_tolerance_nolc:GetFloat()
		tol = max(tol, CLHR.CalcTolerance(vic, hbox, set, bone) or tol)
	end

	local dolagcomp = viclagcomp

	if dolagcomp and not lc then
		ply:LagCompensation(true)
	end

	local bpos, bang

	if phys and not rag then
		bpos, bang = vic:GetPos(), vic:GetAngles()
	else
		bpos, bang = vic:GetBonePosition(bone)
	end

	if not (bpos and bang) then
		bpos, bang = pos, ang
	end

	local endpos = LocalToWorld(vec, angle_zero, bpos, bang)

	if tol then
		local planehit = util.IntersectRayWithPlane(
			start, shotinfo.normal, hitpos, -shotinfo.normal
		)

		if not planehit then
			dbg(ply, vic, info, "Fail: Hitpos is behind startpos")
			return dolagcomp
		end

		distsqr = planehit:DistToSqr(hitpos) -- cylinder check

		if distsqr > tol * tol then
			if not lerp then
				lerp = CLHR.GetInterp(ply)
				if vic:IsNPC() then
					lerp = max(lerp, ply:GetInfoNum("cl_interp_npcs", 0))
				end
			end

			-- expand tolerance by how far the bone moved since last tick
			tol = tol + endpos:Distance(hitpos) * (math.Clamp(
				info.ping, 1, TICKRATE * clhr_tolerance_ping:GetFloat() * 0.001
			) + TICKRATE * max(0.1, lerp))

			if distsqr > tol * tol then
				dbg(ply, vic, info, "Fail: Exceeded tolerance check %s > %s",
					math.Round(sqrt(distsqr), 2),
					math.Round(tol, 2))
				return dolagcomp
			end
		end
	end

	local td = tracedata
	td.start = start
	td.endpos = endpos - start
	td.endpos:Normalize()
	td.endpos:Mul(info.distance)
	td.endpos:Add(start)

	if IsValid(info.ignore) and info.ignore ~= ply then
		td.filter = {ply, info.ignore}
	else
		td.filter = ply
	end

	local trace = util.TraceLine(td)

	if vic ~= trace.Entity then
		local retried

		if trace.HitNonWorld and trace.Hit then
			-- ragdolls, dropped guns, dropped hats can block legitimate shots
			local tent = trace.Entity

			if tent:IsRagdoll()
				or tent:IsWeapon()
				or tent.Base == "base_ammo_ttt"
				or tent.Wearer == vic
				and tent.GetBeingWorn
				and not tent:GetBeingWorn()
			then
				if istable(td.filter) then
					table.insert(td.filter, tent)
				else
					td.filter = {ply, tent}
				end

				if vic == util.TraceLine(td).Entity then
					retried = true
				end
			end
		end

		-- TODO: trace sometimes fails for no apparent reason...
		if not retried and dolagcomp then
			ply:LagCompensation(false)
			dolagcomp = false

			bpos, bang = vic:GetBonePosition(bone)

			if bpos and bang then
				endpos = LocalToWorld(vec, angle_zero, bpos, bang)
				td.endpos = endpos - start
				td.endpos:Normalize()
				td.endpos:Mul(info.distance)
				td.endpos:Add(start)

				if vic == util.TraceLine(td).Entity then
					retried = true
				end
			end
		end

		if not retried then
			if clhr_printshots:GetBool() then
				local e = trace.Entity
				local reason
				if start:DistToSqr(trace.HitPos) > start:DistToSqr(endpos) then
					reason = "Fail: Trace missed"
				elseif trace.HitWorld then
					reason = "Fail: Trace obstructed by world"
				elseif trace.Hit then
					reason = ("Fail: Trace obstructed by [%d]%s"):format(
						e:EntIndex(), e:IsPlayer() and e:Nick() or e:GetClass()
					)
				else
					reason = "Fail: Trace hit nothing"
				end
				dbg(ply, vic, info, reason)
			end

			return dolagcomp
		end
	end

	-- At point-blank, the shooter's startpos can be inside the victim's collision.
	-- util.TraceLine then returns StartSolid = true with HitPos = StartPos (the shooter's
	-- eye), and the engine's bleed/impact code uses DamagePosition to place blood decals
	-- and splatter -- which would otherwise land on the shooter. Fall back to the
	-- bone-relative endpos so the splatter spawns on the victim.
	shotinfo.dmginfo.SetDamagePosition = trace.StartSolid and endpos or trace.HitPos
	shotinfo.newtrace = trace
	shotinfo.info = info

	if not info.lasthit then
		info.lasthit = {}
	end

	if not info.lasthit[vic] then
		info.lasthit[vic] = shotinfo
	end

	if distsqr then
		dbg(ply, vic, info, "Success! %s < %s",
			math.Round(sqrt(distsqr), 2),
			math.Round(tol, 2))
	else
		dbg(ply, vic, info, "Success!")
	end

	return dolagcomp, shotinfo
end