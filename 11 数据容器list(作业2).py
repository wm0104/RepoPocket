# 定义列表
my_list1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

# 定义函数
def while_list1(num_list):
    OS_list = []
    i = 0
    while i < len(num_list):        # 用索引遍历列表
        if num_list[i] % 2 == 0:    # 判断当前元素是否为偶数
            OS_list.append(num_list[i])
        i += 1
    return OS_list                  # 返回新列表

s1 = while_list1(my_list1)
print(f"其中的偶数有{s1}")

# 定义列表
my_list2 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

# 定义函数
def for_list2(num_list2):
    return [i for i in num_list2 if i % 2 == 0]

s2 = for_list2(my_list2)
print(f"其中的偶数有{s2}")


# 定义列表
my_list3 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

# 定义函数
def for_list3(num_list3):
	OS2 = []
	for i in num_list3:
		if i % 2 == 0:
			OS2.append(i)
	return OS2
s3 = for_list3(my_list3)
print(f"其中的偶数有{s3}")

