# 函数定义的时候并不会运行, 只有在调用的时候, 函数体的逻辑才会运行会运行 ; 函数必须先定义才能带调用
# 函数定义
"""

def out_line():
    print("---------------------------------")
    print("---------------------------------")

# 函数调用
out_line()

# 函数定义
def sey_hi():
    print("hi")
# 函数调用
sey_hi()

def cont(y, x):
    he = y + x
    return he
num = cont(100, 200)
print(num)

"""


# 定义一个函数: 根据传入的底和高计算三角形的面积 (底 * 高 / 2)
def SJX(d, g):
    """
    计算三角形的面积
    :param d: 三角形的底
    :param g: 三角形的高
    :return:  三角形的面积
    """
    return d * g / 2
print(SJX(100, 200))

# 定义一个函数: 计算传入的字符串元音字母的个数 (元音字母为 aeiou AEIOU)
def YY(s):
    """
    计算传入的字符串元音字母的个数
    :param s: 输入的字符串
    :return: 符串元音字母的个数
    """
    num = 0
    for i in s:
        if i in "aeiouAEIOU":
            num += 1
    return num
print(YY("hello world python ok "))

# 定义一个函数:  计算传入的班级高考成绩列表中的 最高分 最低分 平均分（保留一位小数）并返回
def fs_1(s):
    return max(s), min(s), round(sum(s) / len(s), 1)

fs_list = []

for i in range(5):
    fs = int(input("请输入成绩："))
    fs_list.append(fs)

zuigao, zuidi, pingjun = fs_1(fs_list)

print("最高分：", zuigao)
print("最低分：", zuidi)
print("平均分：", pingjun)

