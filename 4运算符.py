# 逻辑运算符 and , or , not
# 并且 , 或者 ,逻辑非 (取反)
# 逻辑运算符 and, or, not
# 返回布尔值 True 或 False

a = 10
b = 20
c = 30

# and：所有条件都为 True，结果才为 True
print(a < b and b < c)   # True  (10<20 且 20<30)
print(a > b and b < c)   # False (10>20 为 False)

# or：只要有一个条件为 True，结果就为 True
print(a > b or b < c)    # True  (10>20 为 False，但 20<30 为 True)
print(a > b or b > c)    # False (两个都为 False)

# not：取反
print(not a < b)         # False (a<b 为 True，取反为 False)
print(not a > b)         # True  (a>b 为 False，取反为 True)
