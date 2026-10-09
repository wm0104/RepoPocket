# 先定义一个列表
mylist = ["王建春", "郑雨欣", "python"]
print("初始列表:", mylist)   # 初始列表: ['王建春', '郑雨欣', 'python']
print(" " * 10 + "=" * 10)

# 1.1 查找元素的下标索引
index = mylist.index("王建春")
print(f"王建春在列表中的下标索引值是: {index}")   # 王建春在列表中的下标索引值是: 0
print(" " * 10 + "=" * 10)

# 1.2 如果被查找的元素不存在,会报错(已注释掉)
# index = mylist.index("hello")
# print(f"hello在列表中的下标索引值是: {index}")

# 2. 修改特定下标索引的值
mylist[0] = "wjc"
print(f"列表被修改元素值后,结果是: {mylist}")   # 列表被修改元素值后,结果是: ['wjc', '郑雨欣', 'python']
print(" " * 10 + "=" * 10)

# 3. 在指定下标位置插入新元素
mylist.insert(1, "wjc@@0104")
print(f"列表插入元素后,结果是: {mylist}")   # 列表插入元素后,结果是: ['wjc', 'wjc@@0104', '郑雨欣', 'python']
print(" " * 10 + "=" * 10)

# 4. 在列表的尾部追加单个新元素
mylist.append("郑雨欣小宝贝")
print(f"列表在追加了元素后,结果是: {mylist}")   # 列表在追加了元素后,结果是: ['wjc', 'wjc@@0104', '郑雨欣', 'python', '郑雨欣小宝贝']
print(" " * 10 + "=" * 10)

# 5. 在列表的尾部追加一批新元素
mylist2 = [1, 2, 3]
mylist.extend(mylist2)
print(f"列表在追加了一个新的列表后,结果是: {mylist}")   # 列表在追加了一个新的列表后,结果是: ['wjc', 'wjc@@0104', '郑雨欣', 'python', '郑雨欣小宝贝', 1, 2, 3]
print(" " * 10 + "=" * 10)

# 6. 删除指定下标索引的元素 (2种方式)
# 6.1 方式1: del 列表[下标]
del mylist[0]
print(f"del删除后,结果是: {mylist}")   # del删除后,结果是: ['wjc@@0104', '郑雨欣', 'python', '郑雨欣小宝贝', 1, 2, 3]
print(" " * 10 + "=" * 10)

# 6.2 方式2: 列表.pop(下标)
mylist.pop(0)
print(f"pop删除后,结果是: {mylist}")   # pop删除后,结果是: ['郑雨欣', 'python', '郑雨欣小宝贝', 1, 2, 3]
print(" " * 10 + "=" * 10)

# 7. 删除列表中第一个匹配的元素 列表.remove(指定元素)
mylist1 = ["王建春", "郑雨欣", "wm0104", "王建春"]
mylist1.remove("王建春")
print(f"删除列表中第一个匹配的元素后是: {mylist1}")   # 删除列表中第一个匹配的元素后是: ['郑雨欣', 'wm0104', '王建春']
print(" " * 10 + "=" * 10)

# 8. 清空列表 列表.clear()
mylist1.clear()
print(f"列表被清空了: {mylist1}")   # 列表被清空了: []
print(" " * 10 + "=" * 10)

# 9. 统计列表元素出现次数 返回值 = 列表.count(要查询的元素)
mylist1 = ["王建春", "郑雨欣", "wm0104", "王建春"]
count = mylist1.count("王建春")
print(f"王建春出现了 {count} 次")   # 王建春出现了 2 次
print(" " * 10 + "=" * 10)

# 10. 统计列表所有元素的个数 返回值 = len()
length = len(mylist1)
print(f"列表所有元素的个数有 {length} 个")   # 列表所有元素的个数有 4 个
print(" " * 10 + "=" * 10)

# 本代码出现的所有方法
# --------------------
# 查找类
# mylist.index(x)       查找元素 x 第一次出现的下标,不存在会报错
# mylist.count(x)       统计元素 x 在列表中出现的次数
# --------------------
# 修改类
# mylist[i] = x         修改下标 i 处的元素为 x
# mylist.insert(i, x)   在下标 i 处插入元素 x
# --------------------
# 添加类
# mylist.append(x)      在列表尾部追加一个元素 x
# mylist.extend(列表)    在列表尾部追加一批元素
# --------------------
# 删除类
# del mylist[i]         删除下标 i 处的元素(语句,不是方法)
# mylist.pop(i)         删除下标 i 处的元素并返回(默认删末尾)
# mylist.remove(x)      删除第一个值为 x 的元素
# mylist.clear()        清空整个列表
# --------------------
# 统计类
# len(mylist)           返回列表中元素的个数(内置函数,不是方法)