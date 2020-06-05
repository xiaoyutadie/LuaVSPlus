
local ClassA = {
}

ClassA.name = "ClassA"

ClassA.__index = ClassA

function ClassA:addInClassA()
end

-- ClassA 被注入到全局提示中
return ClassA