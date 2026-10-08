# ========== 1. 列表的一般定义 ==========
print("列表的一般定义")
my_list = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
print(my_list)
print(type(my_list))
print("-----" * 15)

# ========== 2. 列表的嵌套定义 ==========
print("列表嵌套")
my_list = [[1,2,3,4,5,6,7,8,9], [9,8,7,4,5,6,1,2,3], [4,5,69,8,7,7]]
print(my_list[1] [0])
print(my_list)
print(type(my_list))
print("-----" * 15)

# ========== 3. 根据下标获取元素 ==========
print("根据下标获取元素")
my_list = ["王建春", "郑雨欣", 621390, ["Wjc@@0104"], ["WJC621390"], [1230], 789, 456]

# 正序取值
print("正序取值：")
print(my_list[0])   # 王建春
print(my_list[1])   # 郑雨欣
print(my_list[2])   # 621390
print("-----" * 15)

# 倒序取值
print("倒序取值：")
print(my_list[-1])  # 456
print(my_list[-2])  # 789
print(my_list[-3])  # [1230]
print("-----" * 15)

# 步长取值（切片）
print("步长取值：")
print(my_list[1:6:4])   # ['郑雨欣', [1230]]
print(my_list[0:7:2])   # ['王建春', 621390, ['WJC621390'], 789]


