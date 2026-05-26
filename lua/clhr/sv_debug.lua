local CLHR = CLHR

util.AddNetworkString("clhr_dbg_shot")
util.AddNetworkString("clhr_dbg_hbox")
util.AddNetworkString("clhr_dbg_reveal")
util.AddNetworkString("clhr_dbg_clhr")

local clhr_debug_rate = CreateConVar(
	"clhr_debug_rate", "16", FCVAR_ARCHIVE,
	"tick rate (Hz) at which periodic hitbox/reveal debug data is sent to subscribed clients"
)
local clhr_debug_reveal_dist = CreateConVar(
	"clhr_debug_reveal_dist", "1024", FCVAR_ARCHIVE,
	"max distance (units) a reveal target can be from the viewer"
)
local clhr_debug_reveal_cone = CreateConVar(
	"clhr_debug_reveal_cone", "15", FCVAR_ARCHIVE,
	"reveal/shot-report cone half-angle in degrees"
)
local clhr_debug_hitbox_limit = GetConVar("clhr_debug_hitbox_limit")
local clhr_debug_nearby_limit = GetConVar("clhr_debug_nearby_limit")

local ENT_INDEX_BITS = CLHR.ENT_INDEX_BITS

local rad, cos, floor, Clamp = math.rad, math.cos, math.floor, math.Clamp
local band = bit.band

local function is_valid_debug_target(e, viewer)
	if e == viewer or not e:IsSolid() or e:Health() < 1 then
		return false
	end

	local kind

	if e:IsPlayer() then
		kind = 1
		if IsValid(e:GetObserverTarget()) or e:Team() == TEAM_SPECTATOR then
			return false
		end
	elseif e:IsNextBot() then
		kind = 4
	elseif e:IsNPC() then
		kind = 2
	else
		return false
	end

	local bits = viewer:GetInfoNum("clhr_debug_targetbits", 7) -- player + npc + nextbot

	if band(bits, kind) == 0 then
		return false
	end

	local hgc = e:GetHitBoxGroupCount()
	return hgc and hgc > 0
end

-- Build (but don't send) a hitbox list for ent. hg is kept so we can patch the
-- per-hitbox `hit` flag later when the per-pellet hit info is known.
local function capture_hitboxes(ent, ref_pos)
	local meta = CLHR.GetHitboxMeta(ent)
	local meta_list = meta.hitboxes
	local total = #meta_list

	if total == 0 then return {} end

	local mscale = ent:GetModelScale()
	local has_manip = ent:HasBoneManipulations()
	local bone_cache = {}
	local hboxes = {}

	for i = 1, total do
		local m = meta_list[i]
		local bone = m.bone

		local bp = bone_cache[bone]
		if bp == nil then
			local pos, ang = ent:GetBonePosition(bone)
			bp = pos and ang and {pos = pos, ang = ang} or false
			bone_cache[bone] = bp
		end
		if not bp then continue end

		local sx, sy, sz = 1, 1, 1
		if has_manip then
			local bs = ent:GetManipulateBoneScale(bone)
			if bs ~= vector_origin then
				sx, sy, sz = bs.x, bs.y, bs.z
			end
		end

		local mins, maxs = m.mins, m.maxs
		hboxes[#hboxes + 1] = {
			hg = m.hg,
			hit = false,
			pos = bp.pos,
			ang = bp.ang,
			mins = Vector(mins.x * mscale * sx, mins.y * mscale * sy, mins.z * mscale * sz),
			maxs = Vector(maxs.x * mscale * sx, maxs.y * mscale * sy, maxs.z * mscale * sz),
			distsqr = ref_pos and bp.pos:DistToSqr(ref_pos) or 0,
		}
	end

	return hboxes
end

local function capture_entity_snapshot(ent, ref_pos)
	return {
		ent_idx = ent:EntIndex(),
		position = ent:GetPos(),
		mins = ent:OBBMins(),
		maxs = ent:OBBMaxs(),
		hitboxes = capture_hitboxes(ent, ref_pos or ent:WorldSpaceCenter()),
	}
end

local function write_captured_hitboxes(hboxes)
	local limit = Clamp(clhr_debug_hitbox_limit:GetInt(), 1, 255)
	local n = #hboxes

	if n > limit then
		table.sort(hboxes, function(a, b)
			if a.hit ~= b.hit then
				return a.hit
			end
			return a.distsqr < b.distsqr
		end)
		n = limit
	end

	net.WriteUInt(n, 8)

	for i = 1, n do
		local hb = hboxes[i]
		net.WriteBool(hb.hit)
		net.WriteVector(hb.pos)
		net.WriteAngle(hb.ang)
		net.WriteVector(hb.mins)
		net.WriteVector(hb.maxs)
	end
end

local function write_entity_snapshot(ent, was_hit, hit_group_set, ref_pos)
	net.WriteUInt(ent:EntIndex(), ENT_INDEX_BITS)
	net.WriteBool(was_hit and true or false)
	net.WriteVector(ent:GetPos())
	net.WriteVector(ent:OBBMins())
	net.WriteVector(ent:OBBMaxs())

	local hboxes = capture_hitboxes(ent, ref_pos or ent:WorldSpaceCenter())
	if was_hit and hit_group_set then
		for i = 1, #hboxes do
			local hb = hboxes[i]
			hb.hit = hit_group_set[hb.hg] or false
		end
	end
	write_captured_hitboxes(hboxes)
end

CLHR.Debug_WriteEntitySnapshot = write_entity_snapshot

local function find_entities(attacker, startPos, dir)
	local coneAng = cos(rad(clhr_debug_reveal_cone:GetFloat()))
	local cone = ents.FindInCone(startPos, dir, 10000, coneAng)
	local out = {}

	for i = 1, #cone do
		local e = cone[i]
		if not is_valid_debug_target(e, attacker) then continue end

		do
			local tr = util.TraceLine{
				start = startPos,
				endpos = e:WorldSpaceCenter(),
				filter = {attacker, e},
				mask = MASK_SHOT,
			}
			if tr.Hit then continue end
		end

		out[#out + 1] = {ent = e, distsqr = startPos:DistToSqr(e:WorldSpaceCenter())}
	end

	table.sort(out, function(a, b) return a.distsqr < b.distsqr end)

	return out
end

local MAX_PELLETS = 63 -- 6-bit field on the wire

local function capture_scene(attacker, start_pos, aim_dir)
	if attacker:GetInfoNum("clhr_debug_targethitbox", 0) == 0 then return {} end
	local nearby = find_entities(attacker, start_pos, aim_dir)
	local limit = Clamp(clhr_debug_nearby_limit:GetInt(), 0, 255)
	local count = #nearby
	if count > limit then count = limit end

	local scene = {}
	for i = 1, count do
		scene[i] = capture_entity_snapshot(nearby[i].ent, start_pos)
	end

	return scene
end

local function send_shot_report(attacker, cmd_num, bucket)
	if not (IsValid(attacker) and attacker:IsPlayer()) then return end
	if not CLHR.HasDebugAccess(attacker) then return end

	local ent_hits = {}

	for i = 1, #bucket.pellets do
		local p = bucket.pellets[i]
		if IsValid(p.ent) then
			local idx = p.ent:EntIndex()
			local rec = ent_hits[idx]
			if not rec then
				rec = {hit_groups = {}, first_hit_pos = p.hit_pos}
				ent_hits[idx] = rec
			end
			rec.hit_groups[p.group] = true
		end
	end

	net.Start("clhr_dbg_shot", true)
	net.WriteUInt(cmd_num or 0, 31)
	net.WriteVector(bucket.start_pos)

	local pellet_count = #bucket.pellets
	if pellet_count > MAX_PELLETS then pellet_count = MAX_PELLETS end
	net.WriteUInt(pellet_count, 6)

	for i = 1, pellet_count do
		local p = bucket.pellets[i]
		net.WriteVector(p.hit_pos)
		net.WriteUInt(IsValid(p.ent) and p.ent:EntIndex() or 0, ENT_INDEX_BITS)
		net.WriteUInt(Clamp(p.group, 0, 31), 5)
		net.WriteUInt(Clamp(floor(p.damage or 0), 0, 65535), 16)
	end

	local scene = bucket.scene or {}
	net.WriteUInt(#scene, 8)

	for i = 1, #scene do
		local snap = scene[i]
		local rec = ent_hits[snap.ent_idx]

		net.WriteUInt(snap.ent_idx, ENT_INDEX_BITS)
		net.WriteBool(rec ~= nil)
		net.WriteVector(snap.position)
		net.WriteVector(snap.mins)
		net.WriteVector(snap.maxs)

		if rec then
			local hit_groups = rec.hit_groups
			for h = 1, #snap.hitboxes do
				local hb = snap.hitboxes[h]
				hb.hit = hit_groups[hb.hg] or false
			end
		end

		write_captured_hitboxes(snap.hitboxes)
	end

	net.Send(attacker)
end

function CLHR.NotifyDebugEvent(ply, cmd, vic, success, reason, hitpos)
	if not (IsValid(ply) and ply:IsPlayer()) then
		return
	end

	if ply:GetInfoNum("clhr_debug", 0) < 1 then
		return
	end

	if not CLHR.HasDebugAccess(ply) then
		return
	end

	net.Start("clhr_dbg_clhr", true)
	net.WriteBool(success and true or false)
	net.WriteUInt(cmd or 0, 31)
	net.WriteUInt(IsValid(vic) and vic:EntIndex() or 0, ENT_INDEX_BITS)
	net.WriteBool(hitpos ~= nil)

	if hitpos then
		net.WriteVector(hitpos)
	end

	net.WriteString(reason or "")
	net.Send(ply)
end

hook.Add("PostEntityFireBullets", "CLHR_Debug_Snapshot", function(ent, data)
	if not ent:IsPlayer() or ent:IsBot() then return end
	if ent:GetInfoNum("clhr_debug", 0) < 1 then return end

	local cmd_num = 0
	local ucmd = ent:GetCurrentCommand()
	if ucmd then
		cmd_num = ucmd:CommandNumber()
	elseif ent.CLHR_lastCmd then
		cmd_num = ent.CLHR_lastCmd
	end

	local pending = ent.CLHR_dbgPending
	if not pending then
		pending = {}
		ent.CLHR_dbgPending = pending
	end

	local bucket = pending[cmd_num]
	if not bucket then
		local aim_dir = ent:GetAimVector()
		bucket = {
			start_pos = data.Trace.StartPos,
			aim_dir = aim_dir,
			pellets = {},
			scene = capture_scene(ent, data.Trace.StartPos, aim_dir),
		}
		pending[cmd_num] = bucket
	end

	bucket.pellets[#bucket.pellets + 1] = {
		hit_pos = data.Trace.HitPos,
		ent = data.Trace.Entity,
		group = data.Trace.HitGroup or 0,
		damage = data.Damage or 0,
	}
end)

hook.Add("PlayerPostThink", "CLHR_Debug_FlushSnapshots", function(ply)
	local pending = ply.CLHR_dbgPending
	if not pending then return end
	ply.CLHR_dbgPending = nil

	for cmd_num, bucket in pairs(pending) do
		send_shot_report(ply, cmd_num, bucket)
	end
end)

local last_send = 0
hook.Add("Tick", "CLHR_Debug_Periodic", function()
	local rate = clhr_debug_rate:GetFloat()

	if rate <= 0 then
		return
	end

	local now = CurTime()
	local interval = 1 / rate

	if now < last_send + interval then
		return
	end

	last_send = now

	local reveal_dist = clhr_debug_reveal_dist:GetFloat()
	local reveal_cone_ang = cos(rad(clhr_debug_reveal_cone:GetFloat()))

	for _, ply in player.Iterator() do
		if not ply:Alive()
			or IsValid(ply:GetObserverTarget())
			or ply:Team() == TEAM_SPECTATOR
			or not CLHR.HasDebugAccess(ply)
		then
			continue
		end

		if ply:GetInfoNum("clhr_debug_hitbox", 0) > 0 then
			net.Start("clhr_dbg_hbox", true)
			write_entity_snapshot(ply, false, nil, ply:WorldSpaceCenter())
			net.Send(ply)
		end

		if ply:GetInfoNum("clhr_debug_reveal", 0) > 0 then
			local eyes = ply:EyePos()
			local fwd = ply:EyeAngles():Forward()
			local cone = ents.FindInCone(eyes, fwd, reveal_dist, reveal_cone_ang)

			local closest, closest_dist = nil, math.huge

			for i = 1, #cone do
				local e = cone[i]

				if not is_valid_debug_target(e, ply) then
					continue
				end

				do
					local d = eyes:DistToSqr(e:WorldSpaceCenter())

					if d < closest_dist then
						closest = e
						closest_dist = d
					end
				end
			end

			if closest then
				net.Start("clhr_dbg_reveal", true)
				write_entity_snapshot(closest, false, nil, eyes)
				net.Send(ply)
			end
		end
	end
end)