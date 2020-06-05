
local IntellisenseWithSource = {
}

--@param #(IntellisenseWithSource.TestA.Test)Test a
--@param #(IntellisenseWithSource.TestB.Test)Test b
function IntellisenseWithSource:show(a, b)
	local pa = a:getInTestA ()
	print(pa)
	local pb = b:getInTestB()
	print(pb)
end



return IntellisenseWithSource