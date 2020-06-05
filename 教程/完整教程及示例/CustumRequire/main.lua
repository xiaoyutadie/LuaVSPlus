
_L = function(path)
	local a = {}
	setmetatable(a,{__index = _G})
	setfenv(0, a)
	require(path)
	setfenv(0, _G)
	package.loaded[path] = nil
	return a
end



function main()
	local gl = _L("GlFunc")
	local name = gl.GlName
	gl.add()
end

main()