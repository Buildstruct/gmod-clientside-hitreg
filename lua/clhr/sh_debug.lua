local CLHR = CLHR

local clhr_debug_default_access = CreateConVar(
	"clhr_debug_default_access", "admin",
	FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"default access tier for the CLHR debugger when no admin mod overrides via CAMI, user / admin / superadmin."
)
CreateConVar(
	"clhr_debug_hitbox_limit", "32", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"maximum hitboxes streamed/rendered per entity"
)
CreateConVar(
	"clhr_debug_nearby_limit", "3", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"maximum nearby entities included in a shot snapshot"
)

CAMI.RegisterPrivilege({
	Name = "clhr.debugger",
	MinAccess = "admin",
	Description = "Access to the CLHR's debug overlay.",
	HasAccess = function(_, actor, _)
		if not IsValid(actor) then
			return true
		end

		local level = clhr_debug_default_access:GetString()

		if level == "user" then
			return true
		elseif level == "superadmin" then
			return actor:IsSuperAdmin()
		end

		return actor:IsAdmin()
	end,
})

local model_meta = {}
function CLHR.GetHitboxMeta(ent)
	local mdl = ent:GetModel()
	local cached = model_meta[mdl]
	if cached then return cached end

	local group_count = ent:GetHitBoxGroupCount() or 0
	local hitboxes = {}

	for group = 0, group_count - 1 do
		local hbox_count = ent:GetHitBoxCount(group) or 0

		for h = 0, hbox_count - 1 do
			local bone = ent:GetHitBoxBone(h, group)
			if not bone then continue end

			local mins, maxs = ent:GetHitBoxBounds(h, group)
			if not (mins and maxs) then continue end

			hitboxes[#hitboxes + 1] = {
				bone = bone,
				mins = Vector(mins),
				maxs = Vector(maxs),
				hg = ent:GetHitBoxHitGroup(h, group) or 0,
			}
		end
	end

	cached = {hitboxes = hitboxes}
	model_meta[mdl] = cached
	return cached
end

function CLHR.HasDebugAccess(ply)
	if not IsValid(ply) then
		return SERVER -- server console
	end

	if not ply:IsPlayer() then
		return false
	end

	if CAMI then
		local ok, has = pcall(CAMI.PlayerHasAccess, ply, "clhr.debugger", nil)
		if ok then
			return has and true or false
		end
	end

	local level = clhr_debug_default_access:GetString()
	if level == "user" then
		return true
	elseif level == "superadmin" then
		return ply:IsSuperAdmin()
	end
	return ply:IsAdmin()
end