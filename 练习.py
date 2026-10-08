
# he = 0
# for i in range(1,101):
#     if(i % 2 == 1):
#         he += i
# print(he)
#
#
# he = 0
# for i in range(100,501):
#     if(i % 3 == 0):
#         he += i
# print(he)



# for i in range(1,11):
#     for j in range(1,i+1):
#          print(f"{j} x {i} = {j * i}" , end='\t')
#     print()



# # 外层循环：控制行数，i 从 1 到 8，一共 8 行
# for i in range(1, 9):
#
#     # 内层循环：控制列数，j 从 1 到 8，一共 8 列
#     for j in range(1, 9):
#
#         # 判断 i + j 的和是不是偶数
#         # 如果 (i + j) % 2 == 0，说明是偶数，就打印实心黑方块
#         if (i + j) % 2 == 0:
#             print("■", end='\t')
#
#         # 否则说明 i + j 是奇数，就打印空心白方块
#         else:
#             print("□", end='\t')
#
#     # 内层循环结束后换行，开始打印下一行
#     print()

# num = [78, 56, 92, 43, 65, 89, 51, 37, 74,
# 60]
# # 及格人数
# jige = 0
# bujige = 0
# for i in num:
#     if i >= 60:
#         jige += 1
#     elif i < 60:
#         bujige += 1
# print(f"及格人数是{jige}个, 不及格的人数是{bujige}个")






# 将用户输入的10个字符串, 反转后全部转为大写, 然后记录在列表中, 最后将列表内容遍历输出出来
# num = []
# for i in range(10):
#     s1 = input("请输入字符串: ")
#     # 字符串反转：用切片 [::-1]，再转大写 .upper()
#     new_s = s1[::-1].upper()
#     num.append(new_s)
#
# # 遍历输出列表内容
# for item in num:
#     print(item)


#
s = input("请输入一个字符串: ")

if s == s[::-1]:
    print("是回文")
else:
    print("不是回文")



# s = "abcd"
# print(s[::-1])