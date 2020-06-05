-- 作者 yulei 
-- 时间 2020/5/15 19:43:34
local ClassC = {
	--@type #ClassB
	left = nil,
	right = nil, --@type #ClassB 右侧
}


ClassC.__index = ClassC

--@return #ClassC
function ClassC:create()
	local o = {left = ClassB:create(),right = ClassB:create()}
	setmetatable(o, ClassC)
	return o
end


return ClassC