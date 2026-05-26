local CLHR = CLHR

CreateConVar(
	"clhr_tolerance", "8", FCVAR_ARCHIVE,
	"hitpos tolerance for lag-compensated entities"
)
CreateConVar(
	"clhr_tolerance_nolc", "128", FCVAR_ARCHIVE,
	"hitpos tolerance for entities that are not lag-compensated"
)
CreateConVar(
	"clhr_tolerance_ping", "100", FCVAR_ARCHIVE,
	"when calculating hitpos tolerance, clamps ping to this max value"
)
CreateConVar(
	"clhr_supertolerant", "0", FCVAR_ARCHIVE,
	"the client is always right (not recommended for public servers)"
)
CreateConVar(
	"clhr_nofirebulletsincallback", "0", FCVAR_ARCHIVE,
	"prevent bullets from being fired inside the callbacks of client-registered hits"
)
CreateConVar(
	"clhr_printshots", "0"
)
local clhr_enabled = GetConVar("clhr_enabled")
local clhr_subtick = GetConVar("clhr_subtick")

util.AddNetworkString("CLHR")

include("clhr/sv_targets.lua")
include("clhr/sv_validate.lua")
include("clhr/sv_apply.lua")

local maxply_bits = CLHR.maxply_bits
local maxplayers = CLHR.maxplayers
local ENT_INDEX_BITS = CLHR.ENT_INDEX_BITS
local MAX_TRACE_LENGTH = CLHR.MAX_TRACE_LENGTH
local MAX_PENDING_HITS = CLHR.MAX_PENDING_HITS

local function setwanthit(ply, info, shots, vic, hbox, norm, normdist, subtick)
	local shotinfo = info[shots]
	info[shots] = nil

	local whit = ply.CLHR_wantHit
	local count = whit and whit.count or 0

	if count > MAX_PENDING_HITS then
		CLHR.Debug(ply, vic, info, "Fail: Too many wanted hits")
		return
	end

	ply.CLHR_wantHit = {
		tick = engine.TickCount(),
		info = info,
		shotinfo = shotinfo,
		vic = vic,
		hbox = hbox,
		norm = norm,
		normdist = normdist,
		nxt = ply.CLHR_wantHit,
		count = count + 1,
		subtick = subtick,
	}
end

local function callback(ply, trace, dmginfo, info)
	if hook.Run("CLHR.PostApply", ply, trace, dmginfo, info) == false then
		return
	end

	if trace.StartPos ~= info.src then
		return
	end

	info.shots = info.shots + 1

	if trace.HitNonWorld
		and bit.band(trace.Contents, CONTENTS_HITBOX) ~= 0
		and not CLHR.IsFrozenPhys(trace.Entity)
		or ply ~= GetPredictionPlayer()
	then
		return
	end

	local shotinfo = {}
	info[info.shots] = shotinfo

	shotinfo.origvic = trace.Entity
	shotinfo.targets = CLHR.GetPossibleTargets(ply, trace.StartPos, trace.Normal, info)
	shotinfo.origtrace = trace
	shotinfo.startpos = Vector(trace.StartPos)
	shotinfo.normal = Vector(trace.Normal)

	shotinfo.dmginfo = {SetAttacker = ply}

	for getter, setter in pairs(CLHR.DMGINFO_FIELDS) do
		if dmginfo[getter] then
			shotinfo.dmginfo[setter] = dmginfo[getter](dmginfo)
		end
	end

	-- CTakeDamageInfo:Get/SetWeapon was added in 2025.01.15 dev branch.
	-- yea I'm also gonna ignore this for now. - blue

	if shotinfo.dmginfo.SetInflictor == ply
		and IsValid(info.wep)
		and info.wep:GetOwner() == ply
	then
		shotinfo.dmginfo.SetInflictor = info.wep
	end

	if info.damage == 0 and not (info.ammotype and info.ammotype ~= "") then
		shotinfo.dmginfo.SetDamage = 0
	end

	-- if the net message arrived before this callback fired (rare but possible...)
	-- there's a pending early hit waiting to be promoted to a wanted hit
	local ehit, prev = ply.CLHR_earlyHit
	while ehit do
		if ehit.shots == info.shots and ehit.cmd == info.cmd then
			if prev then
				prev.nxt = ehit.nxt
			end
			setwanthit(ply, info, info.shots, ehit.vic, ehit.hbox, ehit.norm, ehit.normdist, ehit.subtick)
		end
		prev = ehit
		ehit = ehit.nxt
	end
end

function CLHR.OnFireBullets(ply, data, wep, fixedshotgun, cmd, lastShotCmd, tick)
	local crt = CurTime()
	local info = ply.CLHR_bulletInfo

	if fixedshotgun then
		if info and info.crt == crt and (
			info.cmd ~= cmd
			or info.wep ~= wep
			or info.src ~= data.Src
		) then
			return
		end
	else
		if info then
			if info.crt == crt then
				return
			end
			info = nil
		end

		if cmd == lastShotCmd then
			return
		end
	end

	local hasDistance = data.Distance and data.Distance > 0
	local distance = hasDistance and data.Distance or MAX_TRACE_LENGTH

	info = info or {
		cmd = cmd,
		crt = crt,
		wep = wep,
		src = data.Src or Vector(),
		cb = fixedshotgun ~= 2 and data.Callback,
		distance = distance,
		distsqr = distance * distance,
		ignore = data.IgnoreEntity,
		damage = data.Damage,
		force = data.Force,
		ammotype = data.AmmoType,
		shots = -1,
		ping = engine.TickCount() - tick,
	}

	ply.CLHR_bulletInfo = info

	data.Callback = CLHR.ReplaceCallback(data.Callback, callback, info)
end

hook.Add("PlayerPostThink", "CLHR_Cleanup", function(ply)
	local info = ply.CLHR_bulletInfo
	if info and info.crt < CurTime() then -- didn't arrive within 1 tick.
		ply.CLHR_expiredCmd = info.cmd
		ply.CLHR_bulletInfo = nil
	end

	local ehit = ply.CLHR_earlyHit
	if ehit and ehit.crt < CurTime() - 0.1 then -- >100ms before bullet info, likely an exploit attempt.
		ply.CLHR_earlyHit = nil
	end
end)

net.Receive("CLHR", function(_, ply)
	if not clhr_enabled:GetBool() then
		return
	end

	local cmd = net.ReadUInt(31)
	local info = ply.CLHR_bulletInfo
	local vic, lastidx, lasthbox
	local subtick

	if clhr_subtick:GetBool() and net.ReadBool() then
		subtick = net.ReadVector()
	end

	for _ = 1, MAX_PENDING_HITS do
		local shots = net.ReadBool() and 1 + net.ReadUInt(5) or 0

		local idx = lastidx and net.ReadBool() and lastidx
			or 1 + net.ReadUInt(net.ReadBool() and ENT_INDEX_BITS or maxply_bits)

		local hbox = lasthbox and net.ReadBool() and lasthbox
			or net.ReadUInt(net.ReadBool() and 31 or 5)

		local norm = net.ReadNormal()

		local normdist = idx > maxplayers and net.ReadBool() and net.ReadFloat() or nil

		vic = vic and idx == lastidx and vic or Entity(idx)

		if IsValid(vic) and not CLHR.IsDead(vic) then
			if info and info[shots] and info.cmd == cmd then
				setwanthit(ply, info, shots, vic, hbox, norm, normdist, subtick)
			elseif info or cmd > (ply.CLHR_expiredCmd or 0) then
				local ehit = ply.CLHR_earlyHit
				local count = ehit and ehit.count or 0

				if count > MAX_PENDING_HITS then
					CLHR.Debug(ply, vic, cmd, "Fail: Too many early hits")
				else
					ply.CLHR_earlyHit = {
						cmd = cmd,
						shots = shots,
						crt = CurTime(),
						vic = vic,
						hbox = hbox,
						norm = norm,
						normdist = normdist,
						nxt = ehit,
						count = count + 1,
						subtick = subtick,
					}
				end
			else
				CLHR.Debug(ply, vic, cmd, "Fail: Message arrived too late")
			end
		end

		if net.ReadBool() then
			lastidx = idx
			lasthbox = hbox
		else
			break
		end
	end
end)