-- 请先在工程文件属性窗口设置API文件夹
--@module ClassD

--@field #ClassB ClassD.inCB  字段ClassB类型

-- 声明一个函数
--@param #ClassB cb 函数参数1
--@return #ClassD
--@function ClassD:add(cb)

-- 重载一个函数，必须在函数声明之后
--@param #ClassB cb 函数参数1
--@param #number n 函数参数2
--@return #ClassD
--@overload ClassD:add(cb, n)