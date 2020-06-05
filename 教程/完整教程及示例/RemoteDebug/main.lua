
require "LuaRemoteDebug"

function main()
	local a = 1
	for n = 1, 1000 do
		local b = a
		print(b)
		a = a + 1
	end
end

main()