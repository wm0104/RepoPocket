# 不定长参数
# 不定长参数也叫可变参数, 用于函数定义以及调用时参数不确定有几个的场景
#用法
# 1 位置传递(*args (封装到一个元组当中))

# def calc_data(*args):
#     """
#     计算最大值, 最小值以及平均值
#     :param args: 不定长参数呵
#     :return: 返回最大值 最小值 平均值
#     """
#     min_data = min(args)
#     max_data = max(args)
#     avg_data = sum(args) / len(args)
#     return min_data, max_data, round(avg_data, 1) # (round 保留结果为多少位小数(结尾写几就是几))
#
# # 调用函数
# data = calc_data(10, 20, 30, 40, 50, 60, 70, 80, 90, 100)
# print(data)
#
# data = calc_data(100, 200, 300, 400, 500)
# print(data)



# 2关键字传递(**kwargs(封装到字典当中)) key:value
def calc_data(*args, **kwargs):
    """
    根据传入的这批数据，计算这批数据的最小值，最大值，平均值
    :param args: 不定长位置参数，需要计算的这批数据
    :param kwargs: 不定长关键字参数
        round: 保留的小数位个数
        print: 是否打印输出
    :return: 最小值，最大值，平均值
    """
    min_data = min(args)
    max_data = max(args)
    avg_data = sum(args) / len(args)

    if kwargs.get("round") is not None:
        avg_data = round(avg_data, kwargs.get("round"))

    if kwargs.get("print"):
        print(f"计算出来的最小值: {min_data}, 最大值: {max_data}, 平均值:{avg_data}")

    return min_data, max_data, avg_data

# 调用函数
#print(calc_data(2, 7, 9, 10, 45, round=3, print=True))

print(calc_data(2, 7, 9, 10, 45, 73, 37, 93, 92, 111, 222))