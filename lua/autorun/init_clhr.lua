if game.SinglePlayer() then
	return
end

CLHR = CLHR or {}
CLHR.Exceptions = CLHR.Exceptions or {
	weapon_zm_improvised = true,
}

include("clhr/sh_clhr.lua")

hook.Add("PreGamemodeLoaded", "CLHR_TTTFOFIntegration", function()
	if TTT_FOF then
		TTT_FOF.ClientsideHitreg = "CLHR"
	end
end)