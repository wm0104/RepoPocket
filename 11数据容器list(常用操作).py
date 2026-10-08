# 先定义一个列表
mylist = ["王建春", "郑雨欣", "python"]

# 1.1 查找元素的下标索引
index = mylist.index("王建春")
print(f"itheima在列表中的下标索引值是: {index}")

# 1.2 如果被查找的元素不存在，会报错
# index = mylist.index("hello")
# print(f"hello在列表中的下标索引值是: {index}")

# 2. 修改特定下标索引的值
mylist[0] = "wjc"
print(f"列表被修改元素值后，结果是: {mylist}")

# 3. 在指定下标位置插入新元素
mylist.insert(1, "wjc@@0104")
print(f"列表插入元素后，结果是: {mylist}")

# 4. 在列表的尾部追加```单个```新元素
mylist.append("郑雨欣小宝贝")
print(f"列表在追加了元素后，结果是: {mylist}")

# 5. 在列表的尾部追加```一批```新元素
mylist2 = [1, 2, 3]
mylist.extend(mylist2)
print(f"列表在追加了一个新的列表后，结果是: {mylist}")

# 6. 删除指定下标索引的元素 (2种方式)
# 6.1 方式1: del 列表[下标]
del mylist[0]
print(f"删除后，结果是: {mylist}")

# 6.2 方式2: 列表.pop(下标)
mylist.pop(2)
print(f"pop删除后，结果是: {mylist}")