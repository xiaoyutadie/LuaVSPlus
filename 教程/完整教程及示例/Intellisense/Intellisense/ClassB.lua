
-- 声明ClassB继承于ClassA
--@extend #ClassA
local ClassB = {
}

ClassB.__index = ClassB
setmetatable(ClassB, ClassA)

ClassB.name = "ClassB"

function ClassB:addInClassB()
end

--@return #ClassB
function ClassB:create()
	local o = {}
	setmetatable(o, ClassB)
	return o
end

-- 辅助function提示
--@param #ClassA cla ClassA类型
--@param #{name = "custom"} cus 自定义类型
--@return #boolean 
--@return #ClassA 返回ClassA类型
function ClassB:compare(cla, cus)
	local ret = cla.name > cus.name
	return ret, cla
end

--参数提示没有类型
--@param va 任意类型，产生悬浮提示
function ClassB:isValid(va)
	return va ~= nil
end

return ClassB