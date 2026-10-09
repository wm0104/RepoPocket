def while_list():
    """
    用while循环遍历列表
    :return:none
    """
    index = 0
    my_list = ["王建春", "郑雨欣", "wjc", "zyx"]
    while index < len(my_list):
        s1 = my_list[index]
        index += 1
        print(f"元素有: {s1}")
while_list()

print("-----"*10)

def for_list():
    """
    用for循环遍历列表
    :return:none
    """
    my_list = ["王建春", "郑雨欣", "wjc", "zyx"]
    for i in my_list:
        print(f"元素有: {i}")
for_list()