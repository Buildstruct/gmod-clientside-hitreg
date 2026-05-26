local CLHR = CLHR

local convar_debug = CreateClientConVar(
	"clhr_debug", "0", true, true,
	"render CLHR debug overlays (shows hits, deviations, etc.)", 0, 1
)
local convar_duration = CreateClientConVar(
	"clhr_debug_duration", "5", true, false,
	"how long (seconds) each hit debug render lingers", 0, 30
)
local convar_hitbox = CreateClientConVar(
	"clhr_debug_hitbox", "0", true, true,
	"render the local player's hitbox continuously", 0, 1
)
local convar_hitbox_duration = CreateClientConVar(
	"clhr_debug_hitbox_duration", "0.25", true, false,
	"how long (seconds) each hitbox snapshot lingers", 0, 30
)
local convar_reveal = CreateClientConVar(
	"clhr_debug_reveal", "0", true, true,
	"render the nearest player in the local player's view cone", 0, 1
)
local convar_reveal_duration = CreateClientConVar(
	"clhr_debug_reveal_duration", "0.25", true, false,
	"how long (seconds) each reveal snapshot lingers", 0, 30
)
local convar_debug_targetbits = CreateClientConVar(
	"clhr_debug_targetbits", "7", true, true,
	"1 = players, 2 = npcs, 4 = nextbots", 0, 7
)
local convar_debug_targethitbox = CreateClientConVar(
	"clhr_debug_targethitbox", "0", true, true,
	"renders hitboxes on-shot for comparing client vs server hits", 0, 1
)

local clhr_enabled = GetConVar("clhr_enabled")
local timescale = GetConVar("host_timescale")

local ENT_INDEX_BITS = CLHR.ENT_INDEX_BITS

local function has_auth()
	return CLHR.HasDebugAccess(LocalPlayer())
end

cvars.AddChangeCallback("clhr_debug", function(_, _, new)
	if tonumber(new) and tonumber(new) > 0 and not has_auth() then
		MsgC(Color(255, 200, 80), "[CLHR] clhr_debug is on, but you lack the 'clhr.debugger' CAMI privilege.\nAsk an admin to enable it for you.\n")
	end
end, "CLHR.Hint")

local COLOR_HIT = Color(0, 255, 0) -- server-confirmed hit
local COLOR_CLIENT = Color(255, 0, 0) -- client-claimed hit
local COLOR_NEUTRAL = Color(255, 255, 255) -- non-hit boxes
local COLOR_DEVIATION = Color(255, 165, 0) -- deviation lines
local COLOR_CLHR_OK = Color(0, 255, 255) -- CLHR accepted (corrected hit)
local COLOR_CLHR_BAD = Color(255, 255, 0) -- CLHR rejected (with reason)

local registry = {}
local hitbox_snap = nil
local reveal_snap = nil

local function read_hitboxes()
	local n = net.ReadUInt(8)
	local out = {}

	for i = 1, n do
		out[i] = {
			hit = net.ReadBool(),
			pos = net.ReadVector(),
			ang = net.ReadAngle(),
			mins = net.ReadVector(),
			maxs = net.ReadVector(),
		}
	end

	return out
end

local function read_entity_snapshot()
	return {
		index = net.ReadUInt(ENT_INDEX_BITS),
		hit = net.ReadBool(),
		position = net.ReadVector(),
		mins = net.ReadVector(),
		maxs = net.ReadVector(),
		hitboxes = read_hitboxes(),
	}
end

net.Receive("clhr_dbg_shot", function()
	if not (convar_debug:GetBool() and has_auth()) then
		return
	end

	local cmd_num = net.ReadUInt(31)
	local start_pos = net.ReadVector()
	local pellet_count = net.ReadUInt(6)
	local pellets = {}
	local total_damage = 0

	for i = 1, pellet_count do
		local hit_pos = net.ReadVector()
		local hit_idx = net.ReadUInt(ENT_INDEX_BITS)
		local hit_group = net.ReadUInt(5)
		local damage = net.ReadUInt(16)

		pellets[i] = {
			hitpos = hit_pos,
			hit_index = hit_idx ~= 0 and hit_idx or nil,
			hit_group = hit_group,
			damage = damage,
		}
		total_damage = total_damage + damage
	end

	local ent_count = net.ReadUInt(8)
	local entities = {}

	for i = 1, ent_count do
		entities[i] = read_entity_snapshot()
	end

	local first = pellets[1]
	local entry = {
		time = SysTime(),
		identity = cmd_num,
		startpos = start_pos,
		endpos = first and first.hitpos or start_pos,
		hit_index = first and first.hit_index,
		hit_group = first and first.hit_group or 0,
		damage = total_damage,
		pellets = pellets,
		entities = entities,
	}

	for i = 1, #registry do
		local other = registry[i]

		if other.client and other.identity == cmd_num and not other.link then
			entry.link = other
			other.link = entry
			break
		end
	end

	registry[#registry + 1] = entry
end)

net.Receive("clhr_dbg_clhr", function()
	if not (convar_debug:GetBool() and has_auth()) then
		return
	end

	local success = net.ReadBool()
	local cmdNum = net.ReadUInt(31)
	local vicIdx = net.ReadUInt(ENT_INDEX_BITS)
	local has_hitpos = net.ReadBool()
	local hitpos = has_hitpos and net.ReadVector() or nil
	local reason = net.ReadString()

	local clhrInfo = {
		success = success,
		vic_index = vicIdx ~= 0 and vicIdx or nil,
		hitpos = hitpos,
		reason = reason,
		time = SysTime(),
	}

	for i = #registry, 1, -1 do
		local entry = registry[i]
		if entry.client and entry.identity == cmdNum then
			entry.clhr = clhrInfo
			return
		end
	end
end)

net.Receive("clhr_dbg_hbox", function()
	if not (convar_debug:GetBool() and has_auth()) then
		return
	end

	hitbox_snap = {
		time = SysTime(),
		snap = read_entity_snapshot(),
	}
end)

net.Receive("clhr_dbg_reveal", function()
	if not (convar_debug:GetBool() and has_auth()) then
		return
	end

	reveal_snap = {
		time = SysTime(),
		snap = read_entity_snapshot(),
	}
end)

local clhr_debug_hitbox_limit = GetConVar("clhr_debug_hitbox_limit")
local clhr_debug_nearby_limit = GetConVar("clhr_debug_nearby_limit")

local band = bit.band

local function client_valid_target(e, attacker)
	if e == attacker or not e:IsSolid() or e:Health() < 1 then
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

	if band(convar_debug_targetbits:GetInt(), kind) == 0 then
		return false
	end

	local hgc = e:GetHitBoxGroupCount()
	return hgc and hgc > 0
end

local function collect_hitboxes(e, hit_group_set, ref_pos)
	local meta = CLHR.GetHitboxMeta(e)
	local meta_list = meta.hitboxes
	local total = #meta_list

	if total == 0 then return {} end

	local mscale = e:GetModelScale()
	local has_manip = e:HasBoneManipulations()
	local bone_cache = {}
	local hitboxes = {}

	for i = 1, total do
		local m = meta_list[i]
		local bone = m.bone

		local bp = bone_cache[bone]
		if bp == nil then
			local pos, ang = e:GetBonePosition(bone)
			bp = pos and ang and {pos = pos, ang = ang} or false
			bone_cache[bone] = bp
		end
		if not bp then continue end

		local sx, sy, sz = 1, 1, 1
		if has_manip then
			local bs = e:GetManipulateBoneScale(bone)
			if bs ~= vector_origin then
				sx = bs.x == 0 and 1 or bs.x
				sy = bs.y == 0 and 1 or bs.y
				sz = bs.z == 0 and 1 or bs.z
			end
		end

		local mins, maxs = m.mins, m.maxs
		hitboxes[#hitboxes + 1] = {
			hit = hit_group_set and hit_group_set[m.hg] or false,
			pos = bp.pos,
			ang = bp.ang,
			mins = Vector(mins.x * mscale * sx, mins.y * mscale * sy, mins.z * mscale * sz),
			maxs = Vector(maxs.x * mscale * sx, maxs.y * mscale * sy, maxs.z * mscale * sz),
			distsqr = ref_pos and bp.pos:DistToSqr(ref_pos) or 0,
		}
	end

	local limit = math.Clamp(clhr_debug_hitbox_limit:GetInt(), 1, 255)

	if #hitboxes > limit then
		table.sort(hitboxes, function(a, b)
			if a.hit ~= b.hit then
				return a.hit
			end
			return a.distsqr < b.distsqr
		end)

		for i = #hitboxes, limit + 1, -1 do
			hitboxes[i] = nil
		end
	end

	return hitboxes
end

local function scan_ents(attacker, start_pos, dir, ent_hits)
	if not convar_debug_targethitbox:GetBool() then return {} end
	local cone = ents.FindInCone(start_pos, dir, 10000, math.cos(math.rad(15)))
	local found = {}

	for i = 1, #cone do
		local e = cone[i]
		if not client_valid_target(e, attacker) then continue end
		found[#found + 1] = {ent = e, distsqr = start_pos:DistToSqr(e:WorldSpaceCenter())}
	end

	table.sort(found, function(a, b) return a.distsqr < b.distsqr end)

	local nearby_limit = math.Clamp(clhr_debug_nearby_limit:GetInt(), 0, 255)
	local count = #found
	if count > nearby_limit then count = nearby_limit end

	local out = {}
	for i = 1, count do
		local e = found[i].ent
		local idx = e:EntIndex()
		local rec = ent_hits and ent_hits[idx]
		local hit_group_set = rec and rec.hit_groups or nil
		local ref_pos = rec and rec.first_hit_pos or start_pos

		out[i] = {
			index = idx,
			hit = rec ~= nil,
			position = e:GetPos(),
			mins = e:OBBMins(),
			maxs = e:OBBMaxs(),
			hitboxes = collect_hitboxes(e, hit_group_set, ref_pos),
		}
	end

	return out
end

local pending_client = {}

local function flush_client_bucket(cmd_num, bucket)
	local ent_hits = {}
	local pellets = {}
	local total_damage = 0

	for i = 1, #bucket.pellets do
		local p = bucket.pellets[i]
		pellets[i] = {
			hitpos = p.hitpos,
			hit_index = IsValid(p.ent) and p.ent:EntIndex() or nil,
			hit_group = p.group,
			damage = p.damage,
		}
		total_damage = total_damage + p.damage

		if IsValid(p.ent) then
			local idx = p.ent:EntIndex()
			local rec = ent_hits[idx]
			if not rec then
				rec = {hit_groups = {}, first_hit_pos = p.hitpos}
				ent_hits[idx] = rec
			end
			rec.hit_groups[p.group] = true
		end
	end

	local entities = scan_ents(LocalPlayer(), bucket.start_pos, bucket.aim_dir, ent_hits)

	local first = pellets[1]
	local entry = {
		client = true,
		time = SysTime(),
		identity = cmd_num,
		startpos = bucket.start_pos,
		endpos = first and first.hitpos or bucket.start_pos,
		hit_index = first and first.hit_index,
		hit_group = first and first.hit_group or 0,
		damage = total_damage,
		pellets = pellets,
		entities = entities,
	}

	for i = 1, #registry do
		local other = registry[i]
		if not other.client and other.identity == cmd_num and not other.link then
			entry.link = other
			other.link = entry
			break
		end
	end

	registry[#registry + 1] = entry
end

hook.Add("Think", "CLHR_Debug_ClientFlush", function()
	if next(pending_client) == nil then return end
	local p = pending_client
	pending_client = {}
	for cmd_num, bucket in pairs(p) do
		flush_client_bucket(cmd_num, bucket)
	end
end)

hook.Add("PostEntityFireBullets", "CLHR_Debug_ClientCapture", function(attacker, data)
	if attacker ~= LocalPlayer() then return end
	if not (convar_debug:GetBool() and has_auth()) then return end
	if not IsFirstTimePredicted() then return end

	local cmd = attacker:GetCurrentCommand()
	local cmd_num = cmd and cmd:CommandNumber() or 0

	local bucket = pending_client[cmd_num]
	if not bucket then
		bucket = {
			start_pos = data.Trace.StartPos,
			aim_dir = attacker:GetAimVector(),
			pellets = {},
		}
		pending_client[cmd_num] = bucket
	end

	bucket.pellets[#bucket.pellets + 1] = {
		hitpos = data.Trace.HitPos,
		ent = data.Trace.Entity,
		group = data.Trace.HitGroup or 0,
		damage = data.Damage or 0,
	}
end)

local function colorAlpha(c, mul)
	return Color(c.r, c.g, c.b, math.max(0, math.min(255, c.a * mul)))
end

local function draw_entity_snapshot(snap, baseColor, alpha)
	for i = 1, #snap.hitboxes do
		local hb = snap.hitboxes[i]
		local col = hb.hit and COLOR_HIT or baseColor
		render.DrawWireframeBox(hb.pos, hb.ang, hb.mins, hb.maxs, colorAlpha(col, alpha))
	end

	render.DrawWireframeBox(snap.position, angle_zero, snap.mins, snap.maxs,
		colorAlpha(snap.hit and COLOR_HIT or baseColor, alpha))
end

local function draw3D2DText(pos, lines, baseColor, alpha)
	local angle = (pos - EyePos()):GetNormalized():Angle()
	angle = Angle(0, angle.y, 0)
	angle:RotateAroundAxis(angle:Up(), -90)
	angle:RotateAroundAxis(angle:Forward(), 90)

	local a = math.Clamp(alpha or 1, 0, 1)
	local fadedText = Color(COLOR_NEUTRAL.r, COLOR_NEUTRAL.g, COLOR_NEUTRAL.b, 255 * a)

	cam.Start3D2D(pos, angle, 0.075)
		surface.SetDrawColor(0, 0, 0, 100 * a)
		surface.DrawRect(-10, -10, 20, 20)
		surface.SetDrawColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a * a)
		surface.DrawRect(-1, -10, 1, 20)
		surface.DrawRect(-10, -1, 20, 1)

		surface.SetFont("DermaDefault")
		local offset = 20

		for i = 1, #lines do
			local text = lines[i]
			local tW, tH = surface.GetTextSize(text)
			local padX, padY = 5, 5

			surface.SetDrawColor(0, 0, 0, 150 * a)
			surface.DrawRect(-tW * 0.5 - padX, offset - padY, tW + padX * 2, tH + padY * 2)
			draw.SimpleText(text, "DermaDefault", -tW * 0.5, offset, fadedText)

			offset = offset + tH + padY * 2 + 2
		end
	cam.End3D2D()
end

local function client_snapshot_for_index(idx)
	local ent = Entity(idx)
	if not IsValid(ent) then return nil end

	return {
		index = idx,
		hit = false,
		position = ent:GetPos(),
		mins = ent:OBBMins(),
		maxs = ent:OBBMaxs(),
		hitboxes = collect_hitboxes(ent, nil, ent:WorldSpaceCenter()),
	}
end

hook.Add("PostDrawOpaqueRenderables", "CLHR_Debug_Render", function()
	if not (convar_debug:GetBool() and has_auth()) then
		return
	end

	local now = SysTime()
	local ts = math.max(0.01, timescale:GetFloat())

	if reveal_snap then
		local age = (now - reveal_snap.time) * ts
		local lifetime = convar_reveal_duration:GetFloat()

		if age > lifetime then
			reveal_snap = nil
		else
			local alpha = 1 - age / lifetime
			draw_entity_snapshot(reveal_snap.snap, COLOR_NEUTRAL, alpha)
			local live = client_snapshot_for_index(reveal_snap.snap.index)
			if live then
				draw_entity_snapshot(live, COLOR_CLIENT, alpha)
			end
		end
	end

	if hitbox_snap then
		local age = (now - hitbox_snap.time) * ts
		local lifetime = convar_hitbox_duration:GetFloat()

		if age > lifetime then
			hitbox_snap = nil
		else
			local alpha = 1 - age / lifetime
			draw_entity_snapshot(hitbox_snap.snap, COLOR_NEUTRAL, alpha)
			local live = client_snapshot_for_index(hitbox_snap.snap.index)
			if live then
				draw_entity_snapshot(live, COLOR_CLIENT, alpha)
			end
		end
	end

	local lifetime = convar_duration:GetFloat()
	local removed = 0

	for i = 1, #registry do
		local entry = registry[i - removed]
		local age = (now - entry.time) * ts

		if age > lifetime then
			table.remove(registry, i - removed)
			removed = removed + 1
			continue
		end

		do
			local alpha = 1 - age / lifetime
			local clhr = entry.clhr
			local clhr_accepted = clhr and clhr.success
			local clhr_rejected = clhr and not clhr.success

			local baseColor
			if not entry.client then
				baseColor = COLOR_NEUTRAL
			elseif clhr_rejected then
				baseColor = COLOR_CLHR_BAD
			elseif clhr_accepted then
				baseColor = COLOR_CLHR_OK
			else
				baseColor = COLOR_CLIENT
			end

			for j = 1, #entry.entities do
				local ent = entry.entities[j]

				for k = 1, #ent.hitboxes do
					local hb = ent.hitboxes[k]
					local col = hb.hit and COLOR_HIT or baseColor
					render.DrawWireframeBox(hb.pos, hb.ang, hb.mins, hb.maxs, colorAlpha(col, alpha))
				end

				render.DrawWireframeBox(ent.position, angle_zero, ent.mins, ent.maxs,
					colorAlpha(ent.hit and COLOR_HIT or baseColor, alpha))
			end

			if entry.pellets then
				for p = 1, #entry.pellets do
					render.DrawLine(entry.startpos, entry.pellets[p].hitpos, colorAlpha(baseColor, alpha))
				end
			else
				render.DrawLine(entry.startpos, entry.endpos, colorAlpha(baseColor, alpha))
			end

			if clhr_accepted and clhr.hitpos then
				render.DrawWireframeSphere(clhr.hitpos, 2, 6, 6, colorAlpha(COLOR_CLHR_OK, alpha), true)
				render.DrawLine(entry.endpos, clhr.hitpos, colorAlpha(COLOR_CLHR_OK, alpha))
			end

			if entry.client and entry.link then
				local ref = entry.link
				local upMid = ((entry.endpos - entry.startpos):GetNormalized():Angle():Up()
					+ (ref.endpos - ref.startpos):GetNormalized():Angle():Up()) * 0.5

				local cMark = upMid * 2 + entry.startpos + (entry.endpos - entry.startpos):GetNormalized() * 25
				local sMark = upMid * 2 + ref.startpos + (ref.endpos - ref.startpos):GetNormalized() * 25

				local deviation = cMark:Distance(sMark)

				if deviation > 1 then
					render.DrawLine(cMark, sMark, colorAlpha(COLOR_DEVIATION, alpha))
					render.DrawLine(entry.startpos, entry.endpos, colorAlpha(COLOR_DEVIATION, alpha))
				end
			end
		end
	end
end)

hook.Add("PostDrawTranslucentRenderables", "CLHR_Debug_Labels", function()
	if not (convar_debug:GetBool() and has_auth()) then
		return
	end

	local now = SysTime()
	local ts = math.max(0.01, timescale:GetFloat())
	local lifetime = convar_duration:GetFloat()

	local mostRecent
	local mostRecentTime = -1

	for i = 1, #registry do
		local e = registry[i]
		if e.time > mostRecentTime then
			mostRecent = e
			mostRecentTime = e.time
		end
	end

	if not mostRecent then
		return
	end

	local age = (now - mostRecent.time) * ts

	if age > lifetime then
		return
	end

	local alpha = 1 - age / lifetime
	local labelPos = mostRecent.startpos
		+ (mostRecent.endpos - mostRecent.startpos):GetNormalized() * 25

	local lines = {}

	if mostRecent.client then
		lines[#lines + 1] = "Client (predicted)"
	else
		lines[#lines + 1] = "Server (authoritative)"
	end

	if mostRecent.damage and mostRecent.damage > 0 then
		lines[#lines + 1] = "Damage: " .. mostRecent.damage
	end

	if mostRecent.link then
		local dev = mostRecent.endpos:Distance(mostRecent.link.endpos)
		lines[#lines + 1] = "Deviation: " .. math.Round(dev, 2)
	end

	local clhr = mostRecent.clhr or (mostRecent.link and mostRecent.link.clhr) or nil

	if clhr then
		if clhr.success then
			lines[#lines + 1] = "CLHR: accepted (corrected hit)"
		else
			lines[#lines + 1] = "CLHR rejected: " .. clhr.reason
		end
	elseif not clhr_enabled:GetBool() then
		lines[#lines + 1] = "CLHR: disabled (vanilla hitreg)"
	end

	local labelColor = COLOR_NEUTRAL
	if mostRecent.client then
		labelColor = clhr and (clhr.success and COLOR_CLHR_OK or COLOR_CLHR_BAD) or COLOR_CLIENT
	end

	draw3D2DText(labelPos, lines, labelColor, alpha)
end)