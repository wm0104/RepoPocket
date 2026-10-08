# match...case 模式匹配：工作日程安排
from unittest import case

# day = input("请输入星期几(1-7): ")
#
# match day:
#     case "1":
#         print("周一：工作会议日")
#     case "2":
#         print("周二：学习培训日")
#     case "3":
#         print("周三：项目开发日")
#     case "4":
#         print("周四：代码审查日")
#     case "5":
#         print("周五：总结规划日")
#     case "6" | "7":
#         print("周末：休息放松")
#     case _:
#         print("输入有误!!!")

#
# s1 = input("请输入对应的指令")
#
# match s1:
#     case "w":
#       print("角色向上移动")
#     case "s":
#       print("角色向下移动")
#     case "a":
#       print("角色向左移动")
#     case "d":
#       print("角色向右移动")
#     case " ":
#       print("角色跳跃")
#     case "j":
#       print("角色发起攻击")
#     case "esc":
#       print("角色退出游戏")
#     case _:
#       print("没找到指令")



s1 = float(input("请输入第一个数"))
s2 = float(input("请输入第二个数"))
YSF = input("请输入运算符: + - * / " )
match YSF:
    case  "+":
        print(f"{s1} + {s2} = {s1 + s2 }")
    case "-" :
        print(f"{s1} - {s2} = {s1 - s2 }")
    case "*" :
        print(f"{s1} * {s2} = {s1 * s2 }")
    case "/" if s2 != 0:
        print(f"{s1} / {s2} = {s1 / s2 }")
    case _:
        print("找不到指令 错误")





