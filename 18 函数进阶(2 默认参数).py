# 函数 默认参数
# 自定义函数
def md(name , age , sg = 160  , cs= "武义县"):
    """
    :param name: 名字
    :param age: 年龄
    :param sg: 身高
    :param cs: 城市
    :return: 把以上封装到字典中
    """
    return {"name":name , "age":age , "sg":sg , "cs":cs}
s1 = md("王建春", 18) #
# 调用函数
print(s1)
print("----" *13)
# 调用函数
s2 = md("郑雨欣" ,18, sg = 168 , cs = "安徽省") # 如果指定参数传入就会修改
print(s2)
print()
