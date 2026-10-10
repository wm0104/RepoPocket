# 先定义一个列表
mylist = ["王建春", "郑雨欣", "python"]
print("初始列表:", mylist)
print(" " * 10 + "=" * 10)

# 1.1 查找元素的下标索引
print("【操作】查找 '王建春' 的下标")
index = mylist.index("王建春")
print(f"结果:'王建春' 的下标是 {index}")
print(" " * 10 + "=" * 10)

# 2. 修改特定下标索引的值
print("【操作】把下标 0 的元素修改为 'wjc'")
print(f"修改前:下标 0 是 '{mylist[0]}'")
mylist[0] = "wjc"
print(f"修改后:列表变成 {mylist}")
print(" " * 10 + "=" * 10)

# 3. 在指定下标位置插入新元素
print("【操作】在下标 1 的位置插入 'wjc@@0104'")
print(f"插入前:{mylist}")
mylist.insert(1, "wjc@@0104")
print(f"插入后:{mylist}")
print(" " * 10 + "=" * 10)

# 4. 在列表的尾部追加单个新元素
print("【操作】在尾部追加一个元素 '郑雨欣小宝贝'")
print(f"追加前:{mylist}")
mylist.append("郑雨欣小宝贝")
print(f"追加后:{mylist}")
print(" " * 10 + "=" * 10)

# 5. 在列表的尾部追加一批新元素
print("【操作】在尾部追加一批元素 [1, 2, 3]")
print(f"追加前:{mylist}")
mylist2 = [1, 2, 3]
mylist.extend(mylist2)
print(f"追加后:{mylist}")
print(" " * 10 + "=" * 10)

# 6.1 删除指定下标索引的元素:del
print("【操作】用 del 删除下标 0 的元素")
print(f"删除前:下标 0 是 '{mylist[0]}'")
del mylist[0]
print(f"删除后:{mylist}")
print(" " * 10 + "=" * 10)

# 6.2 删除指定下标索引的元素:pop
print("【操作】用 pop(0) 删除下标 0 的元素")
print(f"删除前:下标 0 是 '{mylist[0]}'")
mylist.pop(0)
print(f"删除后:{mylist}")
print(" " * 10 + "=" * 10)

# 7. 删除列表中第一个匹配的元素
mylist1 = ["王建春", "郑雨欣", "wm0104", "王建春"]
print("【操作】用 remove 删除第一个 '王建春'")
print(f"删除前:{mylist1}")
mylist1.remove("王建春")
print(f"删除后:{mylist1}")
print(" " * 10 + "=" * 10)

# 8. 清空列表
print("【操作】用 clear 清空列表")
print(f"清空前:{mylist1}")
mylist1.clear()
print(f"清空后:{mylist1}")
print(" " * 10 + "=" * 10)

# 9. 统计元素出现次数
mylist1 = ["王建春", "郑雨欣", "wm0104", "王建春"]
print("【操作】统计 '王建春' 在列表中出现的次数")
print(f"列表:{mylist1}")
count = mylist1.count("王建春")
print(f"结果:'王建春' 出现了 {count} 次")
print(" " * 10 + "=" * 10)

# 10. 统计列表所有元素的个数
print("【操作】用 len() 统计列表元素总个数")
print(f"列表:{mylist1}")
length = len(mylist1)
print(f"结果:列表一共有 {length} 个元素")
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
# 统计类
# len(mylist)           返回列表中元素的个数