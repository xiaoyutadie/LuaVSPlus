

local classPath = {}
classPath.ClassA = "Intellisense.ClassA"
classPath.ClassB = "Intellisense.ClassB"
classPath.IntellisenseWithSource = "IntellisenseWithSource.IntellisenseWithSource"


local loadedModules = {}
setmetatable(_G, {__index = function(t, k)
		if not classPath[k] then return nil end
		table.insert(loadedModules, k)
		local mo = require(classPath[k])
		package.loaded[classPath[k]] = nil
		_G[k] = mo
		return mo
	end})

require "Intellisense.GlobleTable"
require "Intellisense.GlobleTableB"


function main()
	local clb = ClassB:create()
	local isva = clb:isValid(1)
	clb:addInClassA()
	local c, cla = clb:compare(ClassA, {name = "test"})
	local name = cla.name

	local clc = ClassC:create()
	clc.left:addInClassB()
	clc.right:isValid(1)
end

main()