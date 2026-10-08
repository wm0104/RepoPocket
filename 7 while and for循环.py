# i = 1
# while i < 520:
#     print("我爱你 郑雨欣 ~")
#     i += 1


# while案例:计算1-100之间所有偶数的累加之和
# leijia = 0
# s1 = 1
# while  s1 <= 100:
#     s1 += 1
#     if s1 % 2 == 0:
#         leijia += s1
# print("1-100之间的累加之和是", leijia)


# for循环
# 遍历输入的字符串
# s1 = input("请输入内容")
# for s in s1:
#     print(f"元素是: {s}")
# else:
#     print("结束")

# range
# range(5) 代表从零开始到4结束不包含5, 0 1 2 3 4
# range(2, 8) 代表从2开始到8结束不包含8, 2 3 4 5 6 7
# range(0, 10, 2) 从0开始到10 加2递增 不包含10, 0 2 4 6 8

# 案例1
# 第一种写法
# 计算1-100之间的所有基数之和
# jisuzhihe = 0
# for s1 in range(1,101):
#     if s1 % 2== 1:
#         jisuzhihe += s1
# print("基数之和是",jisuzhihe)
#
# # 第二种方法, 使用 "range" 直接筛选
# jisuzhihe = 0
# for s1 in range(1,101,2): # 意思就是从1开始往2递增, 1 3 5 7 9
#     print(s1)
#     jisuzhihe += s1
# print("基数之和是",jisuzhihe)
#
# # 案例2
# # 计算100-500之间所有3倍数的数字之和
# shuzizhihe = 0
# for s1 in range(100,501):
#     print(s1)
#     if s1 % 3 == 0:
#         shuzizhihe += s1
# print("shuzizhihes是",shuzizhihe)


# 嵌套循环
# 以for循环为例
"""
  根据用户输入的长方形的长度 m 和宽度 n,在控制台上打印一个由 * 组成的长方形。
  
   示例 这是一个长10宽5的长方形
   
   *   *   *   *   *   *   *   *   *   *
   *   *   *   *   *   *   *   *   *   *
   *   *   *   *   *   *   *   *   *   *
   *   *   *   *   *   *   *   *   *   *
   *   *   *   *   *   *   *   *   *   *
   
"""
# print("*"):自带换行效果,每一次执行都会输出新的一行中;

# print("*", end=""):end表示的是每一次输出以什么结束;默认 \n,表示换行。

# 1. 接收键盘录入 m, n
# 长度

# 99乘法表
# for i in range(1, 10): #表示行 1-----9
#    for j in range(1,i+1): #表示列 1-----9	
#      print(f"{j} x {i} ={j*i}",end=' \t ')
#    print()


# 作业
# 需求1:
# 根据输入的直角边的边长,打印等腰直角三角形
# 获取用户输入的边长
# bc = int(input("请输入边长"))
# for i in range(bc+1): #行
#    for j in range(1,i+1): #列
#        print("*",end=" ") #打印三角形 
#    print() #和第一个for循环同一层级 用于换行
    


# 需求2:
# 根据输入的数字,打印对应的数字金字塔
# """
# sz = int(input("请输入数字"))
# for i in range(sz+1):
#     for j in range(1, i + 1):
#         print(j, end=" ")
#     print()
# """
#
# # 需求3:
# # 打印国际象棋棋盘
# for i in range(1, 9):
#     for j in range(1, 9):
#         if (i + j) % 2 == 0:
#             print("■", end=" ")
#         else:
#             print("□", end=" ")
#   print()


i = 0
while i < 10:
    i += 1
    print("人生苦短")
