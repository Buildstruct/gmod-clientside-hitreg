local CLHR = CLHR

local clhr_subtick = GetConVar("clhr_subtick")

local ENT_INDEX_BITS = CLHR.ENT_INDEX_BITS
local maxply_bits = CLHR.maxply_bits
local maxplayers = CLHR.maxplayers

local function send2server(head)
	net.Start("CLHR", true)

	net.WriteUInt(head.cmd, 31)

	if clhr_subtick:GetBool() then
		if head.subtick then
			net.WriteBool(true)
			net.WriteVector(head.subtick)
		else
			net.WriteBool(false)
		end
	end

	local lastvic, lasthbox
	local msg = head

	while msg do
		if msg.shots == 0 then
			net.WriteBool(false)
		else
			net.WriteBool(true)
			net.WriteUInt(msg.shots - 1, 5)
		end

		local vic = msg.vic
		local isply = vic < maxplayers

		if lastvic then
			net.WriteBool(vic == lastvic)
		end

		if vic ~= lastvic then
			if isply then
				net.WriteBool(false)
				net.WriteUInt(vic, maxply_bits)
			else
				net.WriteBool(true)
				net.WriteUInt(vic, ENT_INDEX_BITS)
			end

			lastvic = vic
		end

		local hbox = msg.hbox

		if lasthbox then
			net.WriteBool(hbox == lasthbox)
		end

		if hbox ~= lasthbox then
			if hbox < 32 then -- default playermodels have ~17 hitboxes
				net.WriteBool(false)
				net.WriteUInt(hbox, 5)
			else
				net.WriteBool(true)
				net.WriteUInt(hbox, 31)
			end

			lasthbox = hbox
		end

		net.WriteNormal(msg.norm)

		if not isply then
			if msg.dist then
				net.WriteBool(true)
				net.WriteFloat(msg.dist)
			else
				net.WriteBool(false)
			end
		end

		msg = msg.nxt

		net.WriteBool(msg ~= nil)
	end

	net.SendToServer()
end

local msg2send

local function flush()
	if msg2send then
		local m = msg2send
		msg2send = nil
		send2server(m)
	end
end

-- flush queued shotgun pellets as soon as possible after they're built
hook.Add("SetupMove", "CLHR_FlushQueue", flush)
hook.Add("StartCommand", "CLHR_FlushQueue", flush)
hook.Add("CreateMove", "CLHR_FlushQueue", flush)
hook.Add("PreRender", "CLHR_FlushQueue", flush)
hook.Add("Think", "CLHR_FlushQueue", flush)

local function processtrace(trace, nonorm)
	if trace.HitWorld or not trace.Hit then
		return
	end

	local vic = trace.Entity

	if not CLHR.PassesTargetBits(vic) then
		return
	end

	local rag = vic:IsRagdoll()

	if not rag and bit.band(trace.Contents, CONTENTS_HITBOX) == 0 then
		return
	end

	local convex = true
	local hbox, pos, ang

	if rag then
		hbox = trace.PhysicsBone

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
		convex = false
		hbox = 0
		pos, ang = vic:GetPos(), vic:GetAngles()
	else
		local set = vic:GetHitboxSet()

		if not set then
			return
		end

		hbox = trace.HitBox

		local bone = vic:GetHitBoxBone(hbox, set)

		-- calling GetBonePosition before GetBoneMatrix avoids some interp glitches
		if not (bone and vic:GetBonePosition(bone)) then
			return
		end

		local mat = vic:GetBoneMatrix(bone)

		if not mat then
			return
		end

		pos, ang = mat:GetTranslation(), mat:GetAngles()
	end

	local norm = WorldToLocal(trace.HitPos, angle_zero, pos, ang)

	if nonorm then
		return vic, hbox, norm
	end

	local dist

	if convex then
		-- the direction from the hitbox origin is all we need for convex hulls
		norm:Normalize()
	else
		-- we don't know if the vphys mesh is convex, so send the full local pos
		dist = norm:Length()
		norm:Div(dist)
	end

	return vic, hbox, norm, dist
end

CLHR.ProcessTrace = processtrace

local function callback(ply, trace, dmginfo, info)
	if hook.Run("CLHR.PostApply", ply, trace, dmginfo, info) == false then
		return
	end

	if trace.StartPos ~= info.src or ply ~= GetPredictionPlayer() then
		return
	end

	info.shots = info.shots + 1

	local vic, hbox, norm, dist = processtrace(trace)

	if not vic then
		return
	end

	local msg = {
		cmd = info.cmd,
		shots = info.shots,
		vic = vic:EntIndex() - 1,
		hbox = hbox,
		norm = norm,
		dist = dist,
		subtick = info.subtick,
	}

	if info.shotgun then
		msg.nxt = msg2send
		msg2send = msg
	else
		send2server(msg)
	end
end

local info

function CLHR.OnFireBullets(ply, data, wep, fixedshotgun, cmd, lastShotCmd)
	if cmd == lastShotCmd then
		if not fixedshotgun
			or not info
			or info.cmd ~= cmd
			or info.wep ~= wep
			or info.src ~= data.Src
		then
			return
		end
	else
		info = {
			cmd = cmd,
			shots = -1,
			wep = wep,
			src = data.Src or Vector(),
			shotgun = fixedshotgun ~= nil,
		}
	end

	if data.CLHR_Subtick then
		info.subtick = data.CLHR_Subtick
	end

	data.Callback = CLHR.ReplaceCallback(data.Callback, callback, info)
end