AddCSLuaFile()
AddCSLuaFile("clhr/cami.lua")
AddCSLuaFile("clhr/sh_debug.lua")
AddCSLuaFile("clhr/cl_clhr.lua")
AddCSLuaFile("clhr/cl_subtick.lua")
AddCSLuaFile("clhr/cl_debug.lua")
include("clhr/cami.lua")
include("clhr/sh_debug.lua")

local CLHR = CLHR

CLHR.MAX_TRACE_LENGTH = 56756
CLHR.MAX_PENDING_HITS = 32
CLHR.MAX_SHOTGUN_PELLETS = 32
CLHR.ENT_INDEX_BITS = 13 -- MAX_EDICTS is 8192

CLHR.maxply_bits = math.ceil(math.log(math.max(2, game.MaxPlayers())) / math.log(2))
CLHR.maxplayers = 2 ^ CLHR.maxply_bits

local clhr_enabled = CreateConVar(
	"clhr_enabled", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"toggle for clientside hit registration."
)
local clhr_shotguns = CreateConVar(
	"clhr_shotguns", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"allow shotguns to use clientside hitreg"
)
local clhr_targetbits = CreateConVar(
	"clhr_targetbits", "255", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = players, 2 = npcs, 4 = nextbots, 8 = vehicles, 16 = weapons, 32 = ragdolls, 64 = props, 128 = other"
)
local clhr_subtick = CreateConVar(
	"clhr_subtick", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"subtick hitreg simulation (very experimental, not recommended)"
)
local clhr_subtick_aimcorrect = CreateConVar(
	"clhr_subtick_aimcorrect", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"also override bullet direction to track the predicted target's bone position at fire time."
)

local propclasses = {
	prop_physics = true,
	prop_physics_multiplayer = true,
	func_physbox = true,
	func_physbox_multiplayer = true,
	physics_cannister = true,
	combine_mine = true,
	gib = true,
}

function CLHR.GetTargetBit(ent)
	return ent:IsPlayer() and 1
		or ent:IsNPC() and 2
		or ent:IsNextBot() and 4
		or ent:IsVehicle() and 8
		or ent:IsWeapon() and 16
		or ent:IsRagdoll() and 32
		or propclasses[ent:GetClass()] and 64
		or 128
end

function CLHR.PassesTargetBits(ent)
	return bit.band(clhr_targetbits:GetInt(), CLHR.GetTargetBit(ent)) ~= 0
end

function CLHR.ReplaceCallback(old, new, arg)
	if old then
		return function(ply, trace, dmginfo)
			new(ply, trace, dmginfo, arg)
			return old(ply, trace, dmginfo)
		end
	end

	return function(ply, trace, dmginfo)
		return new(ply, trace, dmginfo, arg)
	end
end

if CLIENT then
	include("clhr/cl_clhr.lua")
	include("clhr/cl_subtick.lua")
	include("clhr/cl_debug.lua")
else
	include("clhr/sv_clhr.lua")
	include("clhr/sv_debug.lua")
end

-- prevent replay attacks
hook.Add("StartCommand", "CLHR_StartCommand", function(ply, ucmd)
	if ply:IsBot() then
		return
	end

	local cmd = ucmd:CommandNumber()

	if cmd > (ply.CLHR_lastCmd or 0) then
		ply.CLHR_lastCmd = cmd
	end

	local tick = ucmd:TickCount()

	if tick > (ply.CLHR_lastTick or 0) then
		ply.CLHR_lastTick = tick
	end
end)

hook.Add("SetupMove", "CLHR_SetupMove_ShootPos", function(ply, mv, ucmd)
	if ply:IsBot() then
		return
	end

	if ply:Alive() then
		ply.CLHR_fixedShootPos = ply:GetShootPos()
	end

	if CLHR.OnSetupMove then
		return CLHR.OnSetupMove(ply, mv, ucmd)
	end
end)

hook.Add("EntityFireBullets", "CLHR_EntityFireBullets", function(ply, data)
	if not clhr_enabled:GetBool() then
		return
	end

	if ply == GetPredictionPlayer() and not ply:IsBot() then
		if CLHR.IgnoreBulletPlayer == ply and CLHR.IgnoreBulletTime == CurTime() then
			return false
		end

		if CLHR.Subtick and clhr_subtick:GetBool() then
			CLHR.Subtick.OnFireBullets(ply, data)
		end

		if ply.CLHR_fixedShootPos and ply:Alive() and data.Src == ply:GetShootPos() then
			-- ValveSoftware/source-sdk-2013#442
			data.Src = ply.CLHR_fixedShootPos
		end

		if not IsFirstTimePredicted() then
			return
		end

		local ucmd = ply:GetCurrentCommand()

		if not ucmd then
			return
		end

		local cmd = ucmd:CommandNumber()
		local lastShotCmd = ply.CLHR_lastShotCmd or -1

		if cmd < lastShotCmd then
			return
		end

		ply.CLHR_lastShotCmd = cmd

		if SERVER and cmd < (ply.CLHR_lastCmd or -1) then
			return
		end

		ply.CLHR_lastCmd = cmd

		local tick = ucmd:TickCount()

		if tick < (ply.CLHR_lastTick or -1) then
			if SERVER then
				ply:LagCompensation(false) -- trolled

				print(("[CLHR] Player sent a tick count lower than previous %d < %d (%s %s)"):format(
					tick, ply.CLHR_lastTick or 0, ply:SteamID(), ply:Nick()
				))
			end

			return
		end

		ply.CLHR_lastTick = tick

		if (data.HullSize or 0) ~= 0 then
			-- TODO: support hull traces
			return
		end

		local fixedshotgun

		if (data.Num or 1) ~= 1 then
			if data.Num > CLHR.MAX_SHOTGUN_PELLETS or not clhr_shotguns:GetBool() then
				return
			end

			fixedshotgun = false
		end

		local wep = ply:GetActiveWeapon()

		if IsValid(wep) then
			if wep.CLHR_Disabled or CLHR.Exceptions[wep:GetClass()] then
				return
			end

			if (data.Num or 1) == 1 then
				if wep.Base == "weapon_ttt_fof_base" then -- fot shotguns
					if (wep.Primary and wep.Primary.NumShots or 1) ~= 1 then
						fixedshotgun = 1
					end
				elseif wep.Base == "weapon_tttbase" then -- tttwr shotguns
					if wep.ShotgunNumShots and wep.ShotgunSpread then
						fixedshotgun = 2
					end
				end

				if fixedshotgun and not clhr_shotguns:GetBool() then
					return
				end
			end
		end

		if hook.Run("CLHR.PreApply", ply, data) == false then
			return
		end

		return CLHR.OnFireBullets(ply, data, wep, fixedshotgun, cmd, lastShotCmd, tick)
	end
end, HOOK_LOW)